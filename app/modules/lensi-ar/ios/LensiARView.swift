import ARKit
import AVFoundation
import CoreImage
import ExpoModulesCore
import ImageIO
import SceneKit
import UIKit

/// Live camera with world tracking. Every ~66 ms the newest frame goes through
/// YOLO on the Neural Engine; boxes are smoothed at display rate. In live-pin
/// mode a tap freezes the camera pose, crops the subject, emits it to JS and
/// drops a world anchor so annotations stay on the object as the phone moves.
/// The same session also takes full-resolution photos and records video.
final class LensiARView: ExpoView, ARSessionDelegate {
  let onSelect = EventDispatcher()
  let onFocusChange = EventDispatcher()
  let onTrackingChange = EventDispatcher()
  let onPinTap = EventDispatcher()

  var showDetections = true
  /// Taps pin things in space only in live mode; otherwise the camera is just a viewfinder.
  var livePins = false
  /// The current lens pen: focused bracket, its tag and new pins.
  var accent: UIColor = .white {
    didSet {
      focusLayer.strokeColor = accent.cgColor
      focusTag.color = accent
    }
  }

  private let sceneView = ARSCNView()
  private let boxLayer = CAShapeLayer()
  private let focusLayer = CAShapeLayer()
  private let focusTag = PinLabel(text: "", color: .white, isCallout: true)
  private let pinLayer = UIView()
  private let detector = Detector()
  private let visionQueue = DispatchQueue(label: "lensi.vision", qos: .userInitiated)

  private var visionBusy = false
  private var selecting = false
  private var lastVisionTime: TimeInterval = 0
  private var displayLink: CADisplayLink?
  private var running = false

  private var tracked: [Tracked] = []
  private var nextTrackId = 0
  private var focusedId: Int?
  private var focusedLabel: String?

  private var pins: [String: Pin] = [:]
  private var pinOrder: [String] = []
  private var contexts: [String: Selection] = [:]

  private var paused = false
  private var configuration: ARWorldTrackingConfiguration?
  private var recorder: Recorder?
  private let photoContext = CIContext(options: [.useSoftwareRenderer: false])

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black

    sceneView.session.delegate = self
    sceneView.automaticallyUpdatesLighting = false
    sceneView.rendersCameraGrain = false
    addSubview(sceneView)

    boxLayer.fillColor = nil
    boxLayer.strokeColor = UIColor.white.withAlphaComponent(0.55).cgColor
    boxLayer.lineWidth = 2
    boxLayer.lineCap = .round
    focusLayer.fillColor = nil
    focusLayer.strokeColor = UIColor.white.cgColor
    focusLayer.lineWidth = 3.5
    focusLayer.lineCap = .round
    layer.addSublayer(boxLayer)
    layer.addSublayer(focusLayer)
    focusTag.isHidden = true
    addSubview(focusTag)

    pinLayer.isUserInteractionEnabled = false
    addSubview(pinLayer)

    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    sceneView.frame = bounds
    pinLayer.frame = bounds
    boxLayer.frame = bounds
    focusLayer.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    window == nil ? stop() : start()
  }

  func start() {
    guard !running, !paused, ARWorldTrackingConfiguration.isSupported else { return }
    running = true
    let config = configuration ?? makeConfiguration()
    configuration = config
    sceneView.session.run(config)
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    guard running else { return }
    running = false
    displayLink?.invalidate()
    displayLink = nil
    if recorder != nil { stopRecording { _ in } }
    sceneView.session.pause()
  }

  private func makeConfiguration() -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      config.sceneReconstruction = .mesh
    }
    // A format that can also deliver full-resolution stills on demand.
    if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
      config.videoFormat = format
    }
    return config
  }

  /// Pausing keeps the world map, so pins are still there when we come back.
  func setPaused(_ value: Bool) {
    guard value != paused else { return }
    paused = value
    if value {
      stop()
    } else if window != nil {
      start()
    }
  }

  // MARK: - Coordinate spaces
  //
  // "upright" = normalized portrait camera image, top-left origin (what Vision
  // returns with .right orientation). "raw" = normalized sensor image.

  private func uprightToView(_ p: CGPoint, frame: ARFrame) -> CGPoint {
    let raw = CGPoint(x: p.y, y: 1 - p.x)
    let t = frame.displayTransform(for: .portrait, viewportSize: bounds.size)
    let n = raw.applying(t)
    return CGPoint(x: n.x * bounds.width, y: n.y * bounds.height)
  }

  private func viewToUpright(_ p: CGPoint, frame: ARFrame) -> CGPoint {
    let t = frame.displayTransform(for: .portrait, viewportSize: bounds.size).inverted()
    let raw = CGPoint(x: p.x / bounds.width, y: p.y / bounds.height).applying(t)
    return CGPoint(x: 1 - raw.y, y: raw.x)
  }

  private func uprightRectToView(_ r: CGRect, frame: ARFrame) -> CGRect {
    let corners = [
      CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
    ].map { uprightToView($0, frame: frame) }
    return bounding(corners)
  }

  private func viewRectToUpright(_ r: CGRect, frame: ARFrame) -> CGRect {
    let corners = [
      CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
      CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
    ].map { viewToUpright($0, frame: frame) }
    return bounding(corners)
  }

  private func bounding(_ pts: [CGPoint]) -> CGRect {
    let xs = pts.map(\.x), ys = pts.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
  }

  // MARK: - Live detection

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    recorder?.append(pixelBuffer: frame.capturedImage, time: frame.timestamp)
    guard showDetections, !visionBusy, frame.timestamp - lastVisionTime > 0.066 else { return }
    visionBusy = true
    lastVisionTime = frame.timestamp
    let buffer = frame.capturedImage
    visionQueue.async { [weak self] in
      guard let self else { return }
      let found = self.detector.detect(buffer)
      DispatchQueue.main.async {
        self.visionBusy = false
        guard let current = self.sceneView.session.currentFrame else { return }
        self.merge(found.map { ($0, self.uprightRectToView($0.rect, frame: current)) })
      }
    }
  }

  private func merge(_ found: [(Detection, CGRect)]) {
    var unmatched = Set(tracked.indices)
    for (det, rect) in found {
      var best: Int?
      var bestIoU: CGFloat = 0.25
      for i in unmatched where tracked[i].label == det.label {
        let iou = tracked[i].target.iou(rect)
        if iou > bestIoU { bestIoU = iou; best = i }
      }
      if let i = best {
        unmatched.remove(i)
        tracked[i].target = rect
        tracked[i].confidence = det.confidence
        tracked[i].missed = 0
      } else {
        nextTrackId += 1
        tracked.append(Tracked(id: nextTrackId, label: det.label, confidence: det.confidence, target: rect, shown: rect))
      }
    }
    for i in unmatched { tracked[i].missed += 1 }
    tracked.removeAll { $0.missed > 4 }
  }

  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    var state = "normal", reason = ""
    switch camera.trackingState {
    case .notAvailable: state = "unavailable"
    case .normal: break
    case .limited(let r):
      state = "limited"
      switch r {
      case .excessiveMotion: reason = "excessiveMotion"
      case .insufficientFeatures: reason = "insufficientFeatures"
      case .initializing: reason = "initializing"
      case .relocalizing: reason = "relocalizing"
      @unknown default: reason = "unknown"
      }
    }
    onTrackingChange(["state": state, "reason": reason])
  }

  // MARK: - Per-frame drawing

  @objc private func tick() {
    let center = CGPoint(x: bounds.midX, y: bounds.midY * 0.92)
    let boxes = UIBezierPath()
    let focus = UIBezierPath()
    var newFocus: Tracked?
    var bestScore = CGFloat.greatestFiniteMagnitude

    for i in tracked.indices {
      tracked[i].shown = tracked[i].shown.lerp(tracked[i].target, 0.32)
      let r = tracked[i].shown
      // Prefer the smallest box under the reticle; otherwise the nearest one.
      let score = r.contains(center)
        ? r.width * r.height
        : 1e7 + hypot(r.midX - center.x, r.midY - center.y) * 1e3
      if score < bestScore && (r.contains(center) || hypot(r.midX - center.x, r.midY - center.y) < 120) {
        bestScore = score
        newFocus = tracked[i]
      }
    }

    if showDetections {
      for t in tracked where t.id != newFocus?.id && t.missed == 0 {
        boxes.append(brackets(t.shown, length: 14))
      }
      if let f = newFocus { focus.append(brackets(f.shown.insetBy(dx: -4, dy: -4), length: 22)) }
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    boxLayer.path = boxes.cgPath
    focusLayer.path = focus.cgPath
    if showDetections, let f = newFocus {
      focusTag.isHidden = false
      if focusTag.text != f.label { focusTag.text = f.label }
      focusTag.center = CGPoint(x: f.shown.minX + focusTag.bounds.width / 2, y: f.shown.minY - 20)
    } else {
      focusTag.isHidden = true
    }
    CATransaction.commit()

    if newFocus?.label != focusedLabel {
      focusedLabel = newFocus?.label
      onFocusChange(["label": focusedLabel as Any])
    }
    focusedId = newFocus?.id

    layoutPins()
  }

  private func brackets(_ r: CGRect, length: CGFloat) -> UIBezierPath {
    let p = UIBezierPath()
    let l = min(length, r.width / 3, r.height / 3)
    p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
    p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
    p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
    p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
    return p
  }

  private func project(_ world: simd_float3) -> (CGPoint, Float)? {
    guard let camera = sceneView.session.currentFrame?.camera else { return nil }
    let local = simd_mul(camera.transform.inverse, simd_float4(world, 1))
    guard local.z < -0.02 else { return nil }
    let p = sceneView.projectPoint(SCNVector3(world.x, world.y, world.z))
    return (CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), -local.z)
  }

  private func layoutPins() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for id in pinOrder {
      guard let pin = pins[id] else { continue }
      guard let (p, dist) = project(pin.world) else { pin.setHidden(true); continue }
      pin.setHidden(false)
      pin.dot.position = p

      let labelCenter: CGPoint
      if pin.parentId == nil {
        labelCenter = CGPoint(x: p.x, y: p.y - 46)
      } else {
        let w = pin.label.bounds.width
        labelCenter = CGPoint(x: p.x + pin.side * (w / 2 + 26), y: p.y - 18)
      }
      pin.label.center = labelCenter
      let path = UIBezierPath()
      path.move(to: p)
      if pin.parentId == nil {
        path.addLine(to: CGPoint(x: p.x, y: labelCenter.y + pin.label.bounds.height / 2))
      } else {
        let edge = CGPoint(x: labelCenter.x - pin.side * pin.label.bounds.width / 2, y: labelCenter.y)
        path.addLine(to: CGPoint(x: edge.x - pin.side * 8, y: edge.y))
        path.addLine(to: edge)
      }
      pin.line.path = path.cgPath

      if let outline = pin.outline {
        let s = CGFloat(pin.outlineDistance / max(dist, 0.05))
        outline.setAffineTransform(
          CGAffineTransform(translationX: p.x, y: p.y)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -pin.outlineScreenOrigin.x, y: -pin.outlineScreenOrigin.y)
        )
      }
    }
  }

  // MARK: - Selection

  @objc private func handleTap(_ g: UITapGestureRecognizer) {
    let p = g.location(in: self)
    for id in pinOrder.reversed() {
      guard let pin = pins[id], !pin.label.isHidden else { continue }
      if pin.label.frame.insetBy(dx: -10, dy: -10).contains(p) {
        onPinTap(["id": pin.parentId ?? pin.id])
        return
      }
    }
    guard livePins else { return }
    select(at: p)
  }

  /// Picks the tracked object under `point` (or the focused one), freezes the
  /// camera pose, anchors a pin and sends the crop to JS.
  func select(at point: CGPoint?) {
    guard !selecting, bounds.width > 0, let frame = sceneView.session.currentFrame else { return }
    let target: Tracked? = {
      if let point {
        return tracked.filter { $0.shown.contains(point) }.min { $0.shown.area < $1.shown.area }
      }
      return tracked.first { $0.id == focusedId }
    }()
    let tapPoint = point ?? target.map { CGPoint(x: $0.shown.midX, y: $0.shown.midY) }
      ?? CGPoint(x: bounds.midX, y: bounds.midY * 0.92)
    let viewRect = target?.shown ?? CGRect(x: tapPoint.x - 130, y: tapPoint.y - 130, width: 260, height: 260)

    var crop = viewRectToUpright(viewRect, frame: frame)
    crop = crop.insetBy(dx: -crop.width * 0.15, dy: -crop.height * 0.15)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !crop.isNull, crop.width > 0.01, crop.height > 0.01 else { return }
    let tapUpright = viewToUpright(tapPoint, frame: frame)

    let id = UUID().uuidString
    let selection = Selection(frame: frame, crop: crop)
    let world = selection.anchor(at: tapUpright, session: sceneView.session)
    contexts[id] = selection.withPlane(through: world)
    let tapDistance = -simd_mul(frame.camera.transform.inverse, simd_float4(world, 1)).z

    let pin = Pin(id: id, parentId: nil, world: world, text: target?.label ?? "Looking", color: accent)
    addPin(pin)

    for old in pins.values where old.parentId == nil && old.id != id {
      if let o = old.outline { fade(o, to: 0) }
    }

    let buffer = frame.capturedImage
    let label = target?.label
    let confidence = target?.confidence ?? 0
    let hint = target.map { viewRectToUpright($0.shown, frame: frame) }
    let display = frame.displayTransform(for: .portrait, viewportSize: bounds.size)
    selecting = true
    visionQueue.async { [weak self] in
      guard let self else { return }
      let jpeg = self.detector.jpeg(buffer, crop: crop)
      DispatchQueue.main.async {
        self.onSelect([
          "id": id,
          "label": label as Any,
          "confidence": confidence,
          "image": jpeg?.base64EncodedString() ?? "",
        ])
      }
      let outline = self.detector.subjectOutline(buffer, at: tapUpright, hint: hint)
      DispatchQueue.main.async {
        self.selecting = false
        self.attachOutline(outline, frame: display,
                           fallback: viewRect, origin: tapPoint, distance: max(tapDistance, 0.05), to: id)
      }
    }
  }

  /// `transform` is the display transform of the frame the outline came from,
  /// and `origin`/`distance` are the anchor's screen point and depth in that
  /// same frame, so camera motion during segmentation doesn't offset it.
  private func attachOutline(_ upright: [CGPoint]?, frame transform: CGAffineTransform, fallback: CGRect,
                             origin: CGPoint, distance dist: Float, to id: String) {
    guard let pin = pins[id] else { return }
    let toView = { (p: CGPoint) -> CGPoint in
      let n = CGPoint(x: p.y, y: 1 - p.x).applying(transform)
      return CGPoint(x: n.x * self.bounds.width, y: n.y * self.bounds.height)
    }
    let path: UIBezierPath
    if let upright, upright.count > 4 {
      path = UIBezierPath()
      path.move(to: toView(upright[0]))
      for p in upright.dropFirst() { path.addLine(to: toView(p)) }
      path.close()
    } else {
      path = UIBezierPath(roundedRect: fallback, cornerRadius: 18)
    }
    let shape = CAShapeLayer()
    // Transform around the view origin, not the layer center, so layoutPins
    // can map screen points directly.
    shape.anchorPoint = .zero
    shape.frame = bounds
    shape.path = path.cgPath
    shape.lineWidth = 3
    shape.lineJoin = .round
    shape.strokeColor = pin.label.color.cgColor
    shape.fillColor = pin.label.color.withAlphaComponent(0.18).cgColor
    pinLayer.layer.insertSublayer(shape, at: 0)
    pin.outline = shape
    pin.outlineScreenOrigin = origin
    pin.outlineDistance = dist

    let draw = CABasicAnimation(keyPath: "strokeEnd")
    draw.fromValue = 0
    draw.toValue = 1
    draw.duration = 0.55
    draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
    shape.add(draw, forKey: "draw")
    let fill = CABasicAnimation(keyPath: "fillColor")
    fill.fromValue = pin.label.color.withAlphaComponent(0.45).cgColor
    fill.toValue = pin.label.color.withAlphaComponent(0.18).cgColor
    fill.duration = 0.9
    shape.add(fill, forKey: "fill")
    layoutPins()
  }

  private func fade(_ layer: CALayer, to opacity: Float) {
    let a = CABasicAnimation(keyPath: "opacity")
    a.fromValue = layer.opacity
    a.toValue = opacity
    a.duration = 0.4
    layer.opacity = opacity
    layer.add(a, forKey: "fade")
  }

  private func addPin(_ pin: Pin) {
    pins[pin.id] = pin
    pinOrder.append(pin.id)
    pinLayer.layer.addSublayer(pin.line)
    pinLayer.layer.addSublayer(pin.dot)
    pinLayer.addSubview(pin.label)
    layoutPins()
    pin.popIn()
    UIImpactFeedbackGenerator(style: pin.parentId == nil ? .medium : .light).impactOccurred()
  }

  // MARK: - Photo, video, torch

  /// Full-resolution still (when the format allows it), written upright as JPEG.
  func takePhoto(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    let session = sceneView.session
    let finish: (ARFrame?) -> Void = { [weak self] frame in
      guard let self else { return }
      guard let frame = frame ?? session.currentFrame else {
        done(.failure(LensiError.unavailable("The camera isn't ready yet.")))
        return
      }
      let buffer = frame.capturedImage
      self.visionQueue.async {
        let result = self.writePhoto(buffer)
        DispatchQueue.main.async { done(result) }
      }
    }
    guard running else {
      finish(session.currentFrame)
      return
    }
    session.captureHighResolutionFrame { frame, _ in
      DispatchQueue.main.async { finish(frame) }
    }
  }

  private func writePhoto(_ buffer: CVPixelBuffer) -> Result<[String: Any], Error> {
    var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
    // High-res frames can be 48 MP on Pro phones; 12 MP is plenty to read labels.
    let longest = max(image.extent.width, image.extent.height)
    if longest > 3024 {
      let scale = 3024 / longest
      image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }
    let extent = image.extent
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lensi-\(UUID().uuidString).jpg")
    guard let data = photoContext.jpegRepresentation(
      of: image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)),
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
    ) else {
      return .failure(LensiError.unavailable("Couldn't encode the photo."))
    }
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      return .failure(error)
    }
    return .success(["uri": url.absoluteString, "width": Int(extent.width.rounded()), "height": Int(extent.height.rounded())])
  }

  func startRecording(_ done: @escaping (Error?) -> Void) {
    guard recorder == nil else {
      done(nil)
      return
    }
    guard running, let frame = sceneView.session.currentFrame else {
      done(LensiError.unavailable("The camera isn't ready yet."))
      return
    }
    let withAudio: Bool
    switch AVAudioApplication.shared.recordPermission {
    case .undetermined:
      // Never start recording behind a permission alert: the finger has
      // usually left the shutter by the time it's answered.
      AVAudioApplication.requestRecordPermission { _ in }
      done(LensiError.unavailable("Allow the microphone, then hold the shutter again."))
      return
    case .granted:
      withAudio = true
    default:
      withAudio = false
    }
    let width = CVPixelBufferGetWidth(frame.capturedImage)
    let height = CVPixelBufferGetHeight(frame.capturedImage)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("lensi-\(UUID().uuidString).mov")
    do {
      recorder = try Recorder(url: url, sensorWidth: width, sensorHeight: height, withAudio: withAudio)
      if withAudio, let config = configuration {
        // Ask the session for microphone buffers only while recording.
        config.providesAudioData = true
        sceneView.session.run(config)
      }
      done(nil)
    } catch {
      done(error)
    }
  }

  func stopRecording(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    guard let r = recorder else {
      done(.failure(LensiError.unavailable("Not recording.")))
      return
    }
    recorder = nil
    if let config = configuration, config.providesAudioData {
      config.providesAudioData = false
      if running { sceneView.session.run(config) }
    }
    r.finish { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let (url, seconds)):
          done(.success([
            "uri": url.absoluteString,
            "width": Int(r.size.width),
            "height": Int(r.size.height),
            "durationMs": Int(seconds * 1000),
          ]))
        case .failure(let error):
          done(.failure(error))
        }
      }
    }
  }

  func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
    recorder?.append(audio: audioSampleBuffer)
  }

  /// Returns whether the torch is now on.
  func setTorch(_ on: Bool) -> Bool {
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera, device.hasTorch else {
      return false
    }
    do {
      try device.lockForConfiguration()
      if on, device.isTorchModeSupported(.on) {
        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
      } else {
        device.torchMode = .off
      }
      device.unlockForConfiguration()
      return on
    } catch {
      return false
    }
  }

  // MARK: - Commands from JS

  func setPin(id: String, title: String, color: String?) {
    guard let pin = pins[id] else { return }
    pin.label.text = title
    if let color { pin.setColor(UIColor(hex: color)) }
  }

  /// `x`/`y` are 0...1 inside the crop that was sent with onSelect.
  func addCallout(parentId: String, id: String, x: Double, y: Double, text: String) {
    guard pins[id] == nil, let parent = pins[parentId], let ctx = contexts[parentId] else { return }
    let upright = CGPoint(
      x: ctx.crop.minX + CGFloat(x) * ctx.crop.width,
      y: ctx.crop.minY + CGFloat(y) * ctx.crop.height
    )
    let world = ctx.onPlane(upright) ?? parent.world
    let pin = Pin(id: id, parentId: parentId, world: world, text: text, color: parent.label.color)
    pin.side = x < 0.5 ? -1 : 1
    addPin(pin)
  }

  func removePin(id: String) {
    for pid in pinOrder where pid == id || pins[pid]?.parentId == id {
      pins[pid]?.removeFromSuperview()
      pins[pid] = nil
      contexts[pid] = nil
    }
    pinOrder.removeAll { pins[$0] == nil }
  }

  func clearPins() {
    pins.values.forEach { $0.removeFromSuperview() }
    pins.removeAll()
    pinOrder.removeAll()
    contexts.removeAll()
  }

  static let palette: [UIColor] = [
    UIColor(hex: "#FF5A4E"), UIColor(hex: "#2E9BFF"), UIColor(hex: "#14B88A"),
    UIColor(hex: "#8B6CFF"), UIColor(hex: "#FF7FB6"), UIColor(hex: "#0FB5C9"),
  ]
}

// MARK: - Support types

private struct Tracked {
  let id: Int
  let label: String
  var confidence: Float
  var target: CGRect
  var shown: CGRect
  var missed = 0
}

/// Camera pose frozen at the moment of selection, so callouts that arrive from
/// the cloud a second later still land where they were in that frame.
private struct Selection {
  let transform: simd_float4x4
  let intrinsics: simd_float3x3
  let resolution: CGSize
  let crop: CGRect
  var planePoint = simd_float3.zero
  var planeNormal = simd_float3(0, 0, 1)

  init(frame: ARFrame, crop: CGRect) {
    transform = frame.camera.transform
    intrinsics = frame.camera.intrinsics
    resolution = frame.camera.imageResolution
    self.crop = crop
  }

  func ray(_ upright: CGPoint) -> (simd_float3, simd_float3) {
    let px = Float(upright.y * resolution.width)
    let py = Float((1 - upright.x) * resolution.height)
    let fx = intrinsics[0][0], fy = intrinsics[1][1]
    let cx = intrinsics[2][0], cy = intrinsics[2][1]
    let dirCam = simd_float4((px - cx) / fx, -(py - cy) / fy, -1, 0)
    let dir = simd_normalize(simd_make_float3(simd_mul(transform, dirCam)))
    let origin = simd_make_float3(transform.columns.3)
    return (origin, dir)
  }

  func anchor(at upright: CGPoint, session: ARSession) -> simd_float3 {
    let (origin, dir) = ray(upright)
    let query = ARRaycastQuery(origin: origin, direction: dir, allowing: .estimatedPlane, alignment: .any)
    if let hit = session.raycast(query).first {
      let p = simd_make_float3(hit.worldTransform.columns.3)
      if simd_distance(p, origin) < 4 { return p }
    }
    return origin + dir * 0.55
  }

  /// A plane through the anchor facing the camera: callouts sit on the object's
  /// front face instead of punching through to the table behind it.
  func withPlane(through point: simd_float3) -> Selection {
    var s = self
    s.planePoint = point
    s.planeNormal = simd_normalize(-simd_make_float3(transform.columns.2))
    return s
  }

  func onPlane(_ upright: CGPoint) -> simd_float3? {
    let (origin, dir) = ray(upright)
    let denom = simd_dot(dir, planeNormal)
    guard abs(denom) > 1e-4 else { return nil }
    let t = simd_dot(planePoint - origin, planeNormal) / denom
    return t > 0 ? origin + dir * t : nil
  }
}

private extension CGRect {
  var area: CGFloat { width * height }

  func iou(_ o: CGRect) -> CGFloat {
    let i = intersection(o)
    guard !i.isNull else { return 0 }
    return i.area / (area + o.area - i.area)
  }

  func lerp(_ o: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(
      x: minX + (o.minX - minX) * t, y: minY + (o.minY - minY) * t,
      width: width + (o.width - width) * t, height: height + (o.height - height) * t
    )
  }
}
