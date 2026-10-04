import ARKit
import AVFoundation
import CoreImage
import ExpoModulesCore
import ImageIO
import SceneKit
import UIKit
import Vision

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
  let onGuideChange = EventDispatcher()
  let onZoomRange = EventDispatcher()

  var showDetections = true
  /// SAM on the live camera feed (outlines instead of corner brackets).
  var liveSegments = true {
    didSet { if !liveSegments { clearLiveOutlines() } }
  }
  private let samQueue = DispatchQueue(label: "lensi.sam-live", qos: .userInitiated)
  private var samBusy = false
  private var lastSamTime: TimeInterval = 0
  private var samMs: Double = 0
  private var samEncodeMs: Double = 0
  private var lastSamLog: TimeInterval = 0
  /// Which of the other tags' parts gets re-cut next (one a frame, besides the current step's).
  private var samTurn = 0
  /// Where the phone was for SAM's last frame: a still phone needs fewer.
  private var lastSamPose: simd_float4x4?
  /// SAM once it has loaded (nil until then, and on a phone without the models).
  private var sam: SAMSegmenter?
  /// What a tap asked to have outlined (when taps don't pin): a point in the world, so the
  /// outline stays on it as the phone moves. Nil: whatever is in the middle of the screen.
  private var tapTarget: simd_float3?
  /// Live outlines by what they're of: a guide tag's pin id, or `centreKey`.
  private var liveShapes: [String: LiveShape] = [:]
  /// Between SAM's cuts, followed outlines ride their own pixels (`flowLive`).
  private let flowQueue = DispatchQueue(label: "lensi.flow", qos: .userInitiated)
  private var flowBusy = false
  private var lastFlowTime: TimeInterval = 0
  private var flowMs: Double = 0
  /// Only touched on `flowQueue`: the last frame the flow saw (as LiveFlow sees it, with its
  /// camera and capture time), and what makes the small copies.
  private var flowPrevious: (frame: LiveFlow.Frame, camera: Selection, t: CFTimeInterval)?
  private lazy var flowContext = CIContext(options: [.useSoftwareRenderer: false])
  private static let centreKey = "centre"
  /// Taps pin things in space only in live mode; otherwise the camera is just a viewfinder.
  var livePins = false
  /// Room the app's own chrome takes (the guide panel below, the top bar):
  /// guide tags keep clear of it.
  var pinInsets: UIEdgeInsets = .zero
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
  /// Loaded on first use, on `visionQueue` (where it is only ever touched):
  /// loading Core ML here would stall the main thread as the camera appears.
  private lazy var detector = Detector()
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

  // Live guide: frames the plan was made from (pose frozen), the part being
  // watched for a change, and the state of that watch.
  static let guideParent = "guide"
  private var guideFrames: [String: GuideFrameContext] = [:]
  private var guideFrameOrder: [String] = []
  private var guideWatchId: String?
  private var watch = ChangeWatch()
  private var watchBusy = false
  private var lastWatchTime: TimeInterval = 0
  private var lastWatchTransform: simd_float4x4?

  private var paused = false
  private var configuration: ARWorldTrackingConfiguration?

  // Zoom. 0.5 is the ultra-wide camera, when ARKit offers it for world
  // tracking on this phone; above 1 is a crop of the main camera, applied to
  // the camera view about its centre. Every camera-to-screen mapping below
  // goes through `zoomed`, so tags, outlines, brackets and taps stay on target.
  static let maxZoom: CGFloat = 10
  /// What the user asked for: 0.5…maxZoom.
  private var zoomFactor: CGFloat = 1
  /// The crop part of it, on whichever camera is running.
  private var zoom: CGFloat = 1
  private var onUltraWide = false
  private lazy var ultraWideFormat: ARConfiguration.VideoFormat? =
    ARWorldTrackingConfiguration.supportedVideoFormats.first { $0.captureDeviceType == .builtInUltraWideCamera }
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
    // Load SAM off the main thread now. Nothing on the main thread touches
    // `SAMSegmenter.shared` itself: while it loads, that would wait for it.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let started = CACurrentMediaTime()
      let loaded = SAMSegmenter.shared
      if loaded == nil {
        NSLog("[lensi] SAM isn't available (models missing from the app?): no live outlines")
      } else {
        NSLog("[lensi] SAM loaded in %.1f s", CACurrentMediaTime() - started)
      }
      DispatchQueue.main.async { self?.sam = loaded }
    }

    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // bounds + center, not frame: the camera view carries the zoom as a transform.
    sceneView.bounds = CGRect(origin: .zero, size: bounds.size)
    sceneView.center = CGPoint(x: bounds.midX, y: bounds.midY)
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
    // Say so up front rather than showing a black camera.
    let auth = AVCaptureDevice.authorizationStatus(for: .video)
    if auth == .denied || auth == .restricted {
      onTrackingChange(["state": "failed", "reason": "cameraDenied"])
      return
    }
    running = true
    let config = configuration ?? makeConfiguration()
    configuration = config
    sceneView.session.run(config)
    onZoomRange(["min": ultraWideFormat != nil ? 0.5 : 1, "max": Double(Self.maxZoom), "zoom": Double(zoomFactor)])
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

  // MARK: - Live segmentation
  //
  // SAM on the camera feed, as often as the phone keeps up (the encoder on the
  // Neural Engine, then one decoder pass per prompt). Prompts: where each guide
  // tag's part is in this frame, so its outline is re-cut from wherever the
  // phone is now; with no tags, the tracked object under the reticle; with
  // nothing tracked, whatever is in the middle of the screen.
  //
  // Each outline SAM finds is laid in the world (on a plane through its part,
  // facing the camera that saw it) and redrawn from there every display frame,
  // so it stays on the part while the phone moves between SAM's frames; new
  // cuts of the same shape are blended in rather than swapped (OutlineMath).

  private struct LivePrompt {
    let key: String
    let point: CGPoint?
    let box: CGRect?
    let part: Bool
    /// Where in the world the thing is (its tag, its outline's middle, or the depth found
    /// under the prompt): the cut is laid on a plane through it.
    let anchor: simd_float3
    /// Where the thing should be in this frame (its outline carried along, seen from here):
    /// a cut that doesn't fit it is something else and is refused. Nil for a first look.
    let predicted: [CGPoint]?
    /// The shape follows its thing from frame to frame (a guide part, a tapped thing);
    /// the reticle's is just whatever is in the middle.
    let follows: Bool
  }

  private struct LiveShape {
    let layer: OutlineLayer
    /// OutlineMath.count points, in the world, as of `seen`.
    var world: [simd_float3]
    /// When the frame they were cut from (or the flow last carried them to) was captured,
    /// on the same clock as CACurrentMediaTime.
    var seen: CFTimeInterval
    /// When SAM last cut it (an outline the flow carries still needs SAM to say it's right).
    var cut: CFTimeInterval = 0
    /// Asked for since it was last found, and not found.
    var misses = 0
    /// How the thing itself moves (metres a second, steadied): between SAM's frames it's drawn
    /// carried along, and SAM is asked where it should be next.
    var velocity = simd_float3.zero
    /// A guide tag rides with its part: where it sits from the outline's middle.
    var tagOffset: simd_float3?
    /// Its last change of shape, so the next tells real turning or bending from edge noise.
    var lastChange: [simd_float3]?
    let follows: Bool
    /// How far the flow has carried it, frame by frame (capture times, newest last, the last
    /// second): a SAM cut that lands after the flow has moved on is brought along the same way.
    var moves: [(t: CFTimeInterval, by: simd_float3)] = []
    /// What the last display frame drew, and when: what's drawn eases onto where the outline
    /// is (in about 60 ms) instead of jumping when a cut lands.
    var drawn: [simd_float3]?
    var drawnAt: CFTimeInterval = 0

    /// Where it is at `t`: its outline carried along by its own motion (at most 0.3 s ahead).
    func placed(at t: CFTimeInterval) -> [simd_float3] {
      guard simd_length(velocity) >= 0.02 else { return world }
      let dt = Float(min(max(t - seen, 0), 0.3))
      return dt == 0 ? world : world.map { $0 + velocity * dt }
    }
  }

  private func segmentLive(_ frame: ARFrame) {
    // Not while a photo is being analysed: a plan or an answer is waiting on that.
    guard liveSegments, !samBusy, bounds.width > 0, let sam, !Analyzer.analyzing else { return }
    // As often as the phone keeps up; less often once it runs hot, or while it's propped up
    // and still with nothing moving in front of it (then 4 times a second is plenty).
    var gap: TimeInterval
    switch ProcessInfo.processInfo.thermalState {
    case .critical: gap = 0.6
    case .serious: gap = 0.25
    default: gap = 0.08
    }
    let pose = frame.camera.transform
    let moving = liveShapes.values.contains { simd_length($0.velocity) >= 0.02 }
    if gap < 0.25, !moving, let last = lastSamPose {
      let moved = simd_distance(simd_make_float3(pose.columns.3), simd_make_float3(last.columns.3))
      let facing = simd_dot(simd_normalize(simd_make_float3(pose.columns.2)), simd_normalize(simd_make_float3(last.columns.2)))
      if moved < 0.01, facing > 0.99985 { gap = 0.25 }
    }
    guard frame.timestamp - lastSamTime > gap else { return }
    let res = frame.camera.imageResolution
    let upright = CGSize(width: res.height, height: res.width)
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    var prompts: [LivePrompt] = []
    // Depth under a prompt: a raycast, or the tracked points near its ray.
    func depth(at p: CGPoint) -> simd_float3 {
      GuideFrameContext(selection: Selection(frame: frame, crop: unit), points: frame.rawFeaturePoints?.points ?? [])
        .anchor(at: p, session: sceneView.session)
    }
    // A shape that follows its thing: SAM is asked where it should be in this frame (its
    // outline carried along by its own motion, seen from where the phone is now).
    func follow(_ key: String) -> LivePrompt? {
      guard let shape = liveShapes[key], shape.follows, shape.misses < 2 else { return nil }
      let now = shape.placed(at: frame.timestamp)
      guard let predicted = uprightPoints(now, camera: frame.camera, upright: upright),
            predicted.contains(where: { unit.contains($0) }),
            let p = LiveTracker.prompt(for: predicted, scale: upright) else { return nil }
      return LivePrompt(key: key, point: p.point, box: p.box, part: false, anchor: OutlineMath.centre(now), predicted: predicted, follows: true)
    }
    let guidePins = pinOrder.compactMap { pins[$0] }.filter { $0.parentId == Self.guideParent }
    if !guidePins.isEmpty {
      let toCamera = frame.camera.transform.inverse
      // Tags whose part is on screen, in front of the phone (a tag rides with a moving part).
      let inView: [(pin: Pin, at: CGPoint)] = guidePins.compactMap { (pin: Pin) -> (pin: Pin, at: CGPoint)? in
        let w = tagWorld(pin, at: frame.timestamp)
        guard !pin.label.isHidden, pin.label.pointing == nil,
              simd_mul(toCamera, simd_float4(w, 1)).z < -0.05 else { return nil }
        let q = frame.camera.projectPoint(w, orientation: .portrait, viewportSize: upright)
        let p = CGPoint(x: q.x / upright.width, y: q.y / upright.height)
        return p.x > 0.01 && p.x < 0.99 && p.y > 0.01 && p.y < 0.99 ? (pin, p) : nil
      }
      // The current step's part every frame; the others take turns, one a frame.
      let focused = inView.filter { $0.pin.label.emphasis == .focused }
      let others = inView.filter { $0.pin.label.emphasis != .focused }
      var chosen = Array(focused.prefix(1))
      let extra = focused.isEmpty ? 2 : 1
      for i in 0..<min(extra, others.count) { chosen.append(others[(samTurn + i) % others.count]) }
      samTurn += extra
      for (pin, at) in chosen {
        if let p = follow(pin.id) {
          prompts.append(p)
          continue
        }
        // A first look: the plan's own outline of the part, seen from here, keeps SAM on the same part.
        let box = uprightBox(pin.guideOutline, camera: frame.camera, upright: upright)
        prompts.append(LivePrompt(key: pin.id, point: at, box: box, part: box == nil, anchor: pin.world, predicted: nil, follows: true))
      }
    } else if let p = follow(Self.centreKey) {
      // The tapped thing, wherever it has gone.
      prompts.append(p)
    } else {
      // A tapped thing's last known place, in this frame (in front of the phone, in the picture).
      var tapped: CGPoint?
      if let target = tapTarget {
        if simd_mul(frame.camera.transform.inverse, simd_float4(target, 1)).z < -0.05 {
          let q = frame.camera.projectPoint(target, orientation: .portrait, viewportSize: upright)
          let p = CGPoint(x: q.x / upright.width, y: q.y / upright.height)
          if p.x > 0.01, p.x < 0.99, p.y > 0.01, p.y < 0.99 { tapped = p }
        }
        if tapped == nil { tapTarget = nil }
      }
      if let tapped, let target = tapTarget {
        prompts.append(LivePrompt(key: Self.centreKey, point: tapped, box: nil, part: true, anchor: target, predicted: nil, follows: true))
      } else if let t = tracked.first(where: { $0.id == focusedId }) {
        let box = viewRectToUpright(t.shown, frame: frame).intersection(unit)
        if !box.isNull, box.width > 0.01, box.height > 0.01 {
          let middle = CGPoint(x: box.midX, y: box.midY)
          prompts.append(LivePrompt(key: Self.centreKey, point: nil, box: box, part: false, anchor: depth(at: middle), predicted: nil, follows: false))
        }
      } else {
        let middle = viewToUpright(CGPoint(x: bounds.midX, y: bounds.midY * 0.92), frame: frame)
        if unit.contains(middle) {
          // Part-sized, like a tap: pointed at an engine, the part in the middle, not the whole bay.
          prompts.append(LivePrompt(key: Self.centreKey, point: middle, box: nil, part: true, anchor: depth(at: middle), predicted: nil, follows: false))
        }
      }
    }
    guard !prompts.isEmpty else { return }
    samBusy = true
    lastSamTime = frame.timestamp
    lastSamPose = pose
    let buffer = frame.capturedImage
    let captured = frame.timestamp
    let camera = Selection(frame: frame, crop: unit)
    samQueue.async { [weak self] in
      let started = CACurrentMediaTime()
      var encodeMs: Double = 0
      var found: [String: [simd_float3]] = [:]
      var refused = 0
      var failure: String?
      do {
        try sam.prepare(pixelBuffer: buffer, orientation: .right, id: "live")
        encodeMs = (CACurrentMediaTime() - started) * 1000
        for p in prompts {
          let mask = try sam.segment(
            id: "live", points: p.point.map { [$0] } ?? [], labels: p.point == nil ? [] : [1], box: p.box, preferPart: p.part)
          guard mask.score >= (p.predicted == nil ? 0.6 : 0.5), mask.polygon.count > 2 else { continue }
          // Evenly spaced (in pixels).
          let ring = OutlineMath.resample(mask.polygon, scale: upright)
          // Following a thing: a cut that doesn't fit where it should be is something else.
          if let predicted = p.predicted, !LiveTracker.accepts(ring, predicted: predicted) {
            refused += 1
            continue
          }
          // Onto the thing's plane in the world.
          let plane = camera.withPlane(through: p.anchor)
          let world = ring.compactMap { plane.onPlane($0) }
          if world.count == ring.count { found[p.key] = world }
        }
      } catch {
        failure = error.localizedDescription
      }
      let ms = (CACurrentMediaTime() - started) * 1000
      let results = found, encoded = encodeMs, failed = failure, refusals = refused
      DispatchQueue.main.async {
        guard let self else { return }
        self.samBusy = false
        self.samMs = self.samMs == 0 ? ms : self.samMs * 0.8 + ms * 0.2
        self.samEncodeMs = self.samEncodeMs == 0 ? encoded : self.samEncodeMs * 0.8 + encoded * 0.2
        let now = CACurrentMediaTime()
        // At most every 3 s (a failure would otherwise be logged a dozen times a second).
        if now - self.lastSamLog > 3 {
          self.lastSamLog = now
          if let failed {
            NSLog("[lensi] live SAM failed: %@", failed)
          } else {
            let fastest = self.liveShapes.values.map { simd_length($0.velocity) }.max() ?? 0
            NSLog("[lensi] live SAM %.0f ms a frame (encoder %.0f ms), %ld of %ld prompts found, %ld refused, fastest thing %.2f m/s, optical flow %.0f ms, thermal %ld",
                  self.samMs, self.samEncodeMs, results.count, prompts.count, refusals, fastest, self.flowMs, ProcessInfo.processInfo.thermalState.rawValue)
          }
        }
        guard self.liveSegments else { return }
        self.takeLive(results, asked: prompts, at: captured)
      }
    }
  }

  /// World points as this camera sees them (upright 0…1); nil when any is behind the phone.
  private func uprightPoints(_ world: [simd_float3], camera: ARCamera, upright: CGSize) -> [CGPoint]? {
    guard !world.isEmpty else { return nil }
    let toCamera = camera.transform.inverse
    var points: [CGPoint] = []
    points.reserveCapacity(world.count)
    for w in world {
      guard simd_mul(toCamera, simd_float4(w, 1)).z < -0.02 else { return nil }
      let q = camera.projectPoint(w, orientation: .portrait, viewportSize: upright)
      points.append(CGPoint(x: q.x / upright.width, y: q.y / upright.height))
    }
    return points
  }

  /// The box around `world` (a part's outline) as this camera sees it, a little grown,
  /// upright 0…1; nil when it's behind the phone, a speck, or most of the picture.
  private func uprightBox(_ world: [simd_float3], camera: ARCamera, upright: CGSize) -> CGRect? {
    guard world.count >= 3, let points = uprightPoints(world, camera: camera, upright: upright) else { return nil }
    let r = bounding(points)
    let grown = r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !grown.isNull, grown.width > 0.02, grown.height > 0.02, grown.area < 0.6 else { return nil }
    return grown
  }

  /// Where a guide tag is now: on its part, wherever the part has gone.
  private func tagWorld(_ pin: Pin, at t: CFTimeInterval = CACurrentMediaTime()) -> simd_float3 {
    guard let shape = liveShapes[pin.id], let offset = shape.tagOffset else { return pin.world }
    return OutlineMath.centre(shape.placed(at: t)) + offset
  }

  /// SAM's answers for one frame (captured at `t`): found shapes are blended into what's
  /// shown and their motion measured; asked-for ones it didn't find, or whose cut didn't fit,
  /// count a miss (two in a row and they go).
  private func takeLive(_ found: [String: [simd_float3]], asked: [LivePrompt], at t: CFTimeInterval) {
    for prompt in asked {
      let key = prompt.key
      if let world = found[key] {
        if var shape = liveShapes[key], t - shape.seen < 2 {
          // SAM takes a while: if the flow has carried the outline past this cut's frame, the
          // cut is brought along the same way first.
          var fresh = world
          var at = t
          if shape.seen > t {
            let since = shape.moves.filter { $0.t > t }.reduce(simd_float3.zero) { $0 + $1.by }
            fresh = world.map { $0 + since }
            at = shape.seen
          }
          // Blended into where it should be by now: a moving thing is followed, and its edge
          // settles unless it's really changing shape (tools/track measures this on real footage).
          let steadied = OutlineMath.steady(shape.placed(at: at), fresh, previous: shape.lastChange)
          let next = steadied.outline
          shape.lastChange = steadied.change
          // Its speed, when the flow isn't measuring it.
          let dt = Float(at - shape.seen)
          if dt > 0.01 {
            let v = (OutlineMath.centre(next) - OutlineMath.centre(shape.world)) / dt
            shape.velocity = shape.velocity * 0.4 + v * 0.6
          }
          shape.world = next
          shape.seen = at
          shape.cut = t
          shape.misses = 0
          liveShapes[key] = shape
        } else {
          // New, or not seen for a while: start over.
          liveShapes[key]?.layer.removeFromSuperlayer()
          let layer = OutlineLayer()
          layer.isHidden = true
          // Under the tags.
          pinLayer.layer.insertSublayer(layer, at: 0)
          var shape = LiveShape(layer: layer, world: world, seen: t, follows: prompt.follows)
          shape.cut = t
          if let pin = pins[key] {
            let offset = pin.world - OutlineMath.centre(world)
            shape.tagOffset = simd_length(offset) < 0.5 ? offset : .zero
          }
          liveShapes[key] = shape
        }
        // A tapped thing is wherever its outline is now (so a lost one is looked for there).
        if key == Self.centreKey, prompt.follows, let shape = liveShapes[key] { tapTarget = OutlineMath.centre(shape.world) }
      } else if var shape = liveShapes[key] {
        shape.misses += 1
        shape.velocity *= 0.5
        liveShapes[key] = shape
      }
    }
    layoutLive()
  }

  /// Between SAM's cuts each followed outline rides its own pixels: up to 30 times a second a
  /// small grey copy of the frame is made, and every followed outline is moved the way the
  /// points inside it moved since the last one (LiveFlow: Lucas-Kanade, their median). Without
  /// it an outline coasts at the speed of SAM's last cut and jumps at the next, and a thing that
  /// moves its own width between cuts (a bolt on a belt) is lost (tools/track measures both).
  private func flowLive(_ frame: ARFrame) {
    guard liveSegments, sam != nil, !flowBusy, frame.timestamp - lastFlowTime >= 1.0 / 30,
          liveShapes.values.contains(where: { $0.follows }) else { return }
    flowBusy = true
    lastFlowTime = frame.timestamp
    let buffer = frame.capturedImage
    let camera = Selection(frame: frame, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
    let t = frame.timestamp
    flowQueue.async { [weak self] in
      guard let self else { return }
      let started = CACurrentMediaTime()
      // Upright and LiveFlow.width across.
      let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
      let scale = CGFloat(LiveFlow.width) / upright.extent.width
      let small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let now = self.flowContext.createCGImage(small, from: small.extent).flatMap { LiveFlow.frame($0) }
      let previous = self.flowPrevious
      self.flowPrevious = now.map { (frame: $0, camera: camera, t: t) }
      let ms = (CACurrentMediaTime() - started) * 1000
      DispatchQueue.main.async {
        self.flowBusy = false
        self.flowMs = self.flowMs == 0 ? ms : self.flowMs * 0.8 + ms * 0.2
        guard let now, let previous, t - previous.t < 0.25, self.liveSegments else { return }
        self.carryLive(from: previous.frame, previous.camera, at: previous.t, to: now, camera, at: t)
      }
    }
  }

  /// One frame to the next (`a`, seen by camera `ca` at `ta`; `b`, by `cb` at `tb`), applied
  /// to each followed outline: seen from `ca`, carried on the picture, laid back in the world
  /// on a plane through its middle as `cb` sees it. The phone's own motion is in the picture's
  /// too and cancels out in the round trip; what's left is the thing's.
  private func carryLive(from a: LiveFlow.Frame, _ ca: Selection, at ta: CFTimeInterval,
                         to b: LiveFlow.Frame, _ cb: Selection, at tb: CFTimeInterval) {
    for (key, var shape) in liveShapes where shape.follows && shape.misses < 2 {
      // A cut from a later frame already says where it is.
      guard shape.seen <= ta + 0.001 else { continue }
      let then = shape.placed(at: ta)
      guard let seen = ca.upright(then), let moved = LiveFlow.carry(seen, from: a, to: b) else { continue }
      let plane = cb.withPlane(through: OutlineMath.centre(then))
      let world = moved.compactMap { plane.onPlane($0) }
      guard world.count == moved.count else { continue }
      let by = OutlineMath.centre(world) - OutlineMath.centre(then)
      let dt = Float(tb - ta)
      if dt > 0.005 { shape.velocity = shape.velocity * 0.5 + by / dt * 0.5 }
      shape.world = world
      shape.seen = tb
      shape.moves.append((t: tb, by: by))
      shape.moves.removeAll { tb - $0.t > 1 }
      liveShapes[key] = shape
    }
  }

  /// Every display frame: each live outline drawn where its thing is now (carried along by
  /// its own motion between SAM's frames; the phone's is ARKit's). The current step's in the
  /// lens colour, the rest thin and white. It goes (fading) once SAM has missed it twice in
  /// a row or its tag goes; one that's simply not been asked about lately (out of view, or
  /// waiting its turn) stays where it is in the world for up to `liveStale`.
  private func layoutLive() {
    guard !liveShapes.isEmpty else { return }
    let now = CACurrentMediaTime()
    let toCamera = sceneView.session.currentFrame?.camera.transform.inverse
    let guiding = pins.values.contains { $0.parentId == Self.guideParent }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for (key, var shape) in liveShapes {
      let pin = pins[key]
      let gone = key == Self.centreKey ? guiding : pin == nil
      let age = now - shape.cut
      if gone || shape.misses >= 2 || age > Self.liveStale {
        retire(shape.layer)
        liveShapes[key] = nil
        continue
      }
      guard let toCamera, pin.map({ !$0.label.isHidden && $0.label.pointing == nil }) ?? true else {
        shape.layer.isHidden = true
        continue
      }
      // Eased onto where it is now rather than jumping when a cut lands; carried along with
      // the thing meanwhile, so the easing never lags its motion. A jump of more than its own
      // size (something else) is taken at once.
      let target = shape.placed(at: now)
      var drawn = target
      if let last = shape.drawn, last.count == target.count, now - shape.drawnAt < 0.25 {
        let dt = Float(now - shape.drawnAt)
        let v = simd_length(shape.velocity) >= 0.02 ? shape.velocity : .zero
        let carried = last.map { $0 + v * dt }
        if simd_distance(OutlineMath.centre(carried), OutlineMath.centre(target)) < OutlineMath.spread(target) {
          let k = 1 - exp(-dt / 0.06)
          let lined = OutlineMath.align(target, to: carried).points
          drawn = zip(carried, lined).map { $0 + ($1 - $0) * k }
        }
      }
      shape.drawn = drawn
      shape.drawnAt = now
      liveShapes[key] = shape
      let path = UIBezierPath()
      var behind = false
      for (i, w) in drawn.enumerated() {
        guard simd_mul(toCamera, simd_float4(w, 1)).z < -0.02 else {
          behind = true
          break
        }
        let q = sceneView.projectPoint(SCNVector3(w.x, w.y, w.z))
        let v = zoomed(CGPoint(x: CGFloat(q.x), y: CGFloat(q.y)))
        if i == 0 { path.move(to: v) } else { path.addLine(to: v) }
      }
      guard !behind else {
        shape.layer.isHidden = true
        continue
      }
      path.close()
      let focused = pin?.label.emphasis == .focused
      let strong = focused || key == Self.centreKey
      let color: UIColor = focused ? accent : .white
      shape.layer.setOutline(path.cgPath)
      shape.layer.style(color, width: focused ? 2.5 : strong ? 2 : 1.5, stroke: strong ? 1 : 0.75, fill: focused ? 0.14 : 0.07)
      shape.layer.isHidden = false
    }
  }

  /// Not re-cut for this long (seconds), an outline is let go even if nothing said it's wrong.
  private static let liveStale: CFTimeInterval = 4

  /// A live outline SAM has lost fades out rather than blinking off.
  private func retire(_ layer: CALayer) {
    CATransaction.begin()
    CATransaction.setDisableActions(false)
    CATransaction.setAnimationDuration(0.2)
    CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
    layer.opacity = 0
    CATransaction.commit()
  }

  private func clearLiveOutlines() {
    for shape in liveShapes.values { shape.layer.removeFromSuperlayer() }
    liveShapes.removeAll()
  }

  /// A live outline is being kept up for this pin, so its frozen one steps aside (never both:
  /// `layoutLive` drops a live one that's lost or stale, and the frozen one comes back).
  private func hasLiveOutline(_ pin: Pin) -> Bool {
    liveShapes[pin.id] != nil
  }

  // MARK: - Zoom

  func setZoom(_ requested: Double) {
    guard requested.isFinite else { return }
    let lowest: CGFloat = ultraWideFormat != nil ? 0.5 : 1
    let z = min(max(CGFloat(requested), lowest), Self.maxZoom)
    zoomFactor = z
    let ultra = z < 1 && ultraWideFormat != nil
    if ultra != onUltraWide { useUltraWide(ultra) }
    // The ultra-wide sees twice as wide: 0.5 is its whole picture, 0.7 a 1.4x crop.
    zoom = ultra ? z / 0.5 : z
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sceneView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
    CATransaction.commit()
    layoutPins()
  }

  /// Swaps the camera under the same session; the world (and every pin) carries on.
  private func useUltraWide(_ ultra: Bool) {
    guard let config = configuration else { return }
    if ultra, let format = ultraWideFormat {
      config.videoFormat = format
    } else if let format = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
      config.videoFormat = format
    } else if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first {
      config.videoFormat = format
    }
    onUltraWide = ultra
    if running { sceneView.session.run(config) }
  }

  /// A point in the unzoomed camera view, where it is on screen now.
  private func zoomed(_ p: CGPoint) -> CGPoint {
    CGPoint(x: bounds.midX + (p.x - bounds.midX) * zoom, y: bounds.midY + (p.y - bounds.midY) * zoom)
  }

  private func unzoomed(_ p: CGPoint) -> CGPoint {
    CGPoint(x: bounds.midX + (p.x - bounds.midX) / zoom, y: bounds.midY + (p.y - bounds.midY) / zoom)
  }

  // MARK: - Coordinate spaces
  //
  // "upright" = normalized portrait camera image, top-left origin (what Vision
  // returns with .right orientation). "raw" = normalized sensor image.

  private func uprightToView(_ p: CGPoint, frame: ARFrame) -> CGPoint {
    let raw = CGPoint(x: p.y, y: 1 - p.x)
    let t = frame.displayTransform(for: .portrait, viewportSize: bounds.size)
    let n = raw.applying(t)
    return zoomed(CGPoint(x: n.x * bounds.width, y: n.y * bounds.height))
  }

  private func viewToUpright(_ p: CGPoint, frame: ARFrame) -> CGPoint {
    let t = frame.displayTransform(for: .portrait, viewportSize: bounds.size).inverted()
    let v = unzoomed(p)
    let raw = CGPoint(x: v.x / bounds.width, y: v.y / bounds.height).applying(t)
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
    if guideWatchId != nil { watchGuide(frame) }
    segmentLive(frame)
    flowLive(frame)
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

  func session(_ session: ARSession, didFailWithError error: Error) {
    let code = (error as? ARError)?.code
    let reason = code == .cameraUnauthorized ? "cameraDenied" : "failed"
    NSLog("[lensi] AR session failed: %@", error.localizedDescription)
    DispatchQueue.main.async {
      self.stop()
      self.onTrackingChange(["state": "failed", "reason": reason])
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    onTrackingChange(["state": "limited", "reason": "interrupted"])
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    onTrackingChange(["state": "normal", "reason": ""])
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

    if showDetections && !(liveSegments && sam != nil) {
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
    layoutLive()
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
    return (zoomed(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))), -local.z)
  }

  private func layoutPins() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    // Where a tag can be read: clear of the app's own panel and top bar.
    let visible = bounds.inset(by: pinInsets)
    for id in pinOrder {
      guard let pin = pins[id] else { continue }
      // A guide tag rides with its part when the part moves (its live outline says where).
      let anchor = pin.parentId == Self.guideParent ? tagWorld(pin) : pin.world
      let projected = project(anchor)
      if pin.parentId == Self.guideParent {
        // A little hysteresis, so a part right on the edge doesn't flicker between the two.
        let slack = pin.label.pointing == nil ? CGSize(width: -pin.label.bounds.width / 4, height: -6) : CGSize(width: 10, height: 10)
        let inView = projected.map { visible.insetBy(dx: slack.width, dy: slack.height).contains($0.0) } ?? false
        if !inView {
          // Out of view: the current step's tag waits on the edge, pointing the
          // way to its part; the others keep out of the way.
          if pin.label.emphasis == .focused, placeOnEdge(pin, in: visible) {
            pin.guideShape?.isHidden = true
            continue
          }
          pin.label.pointing = nil
          pin.setHidden(true)
          continue
        }
        pin.label.pointing = nil
      }
      guard let (p, dist) = projected else { pin.setHidden(true); continue }
      pin.setHidden(false)
      // The tag sits on the thing itself: no dot, no leader line. A part near
      // the edge keeps its whole tag on screen.
      let half = pin.label.bounds.width / 2 + 8
      let y = pin.parentId == Self.guideParent ? min(max(p.y, visible.minY + 13), visible.maxY - 13) : p.y
      pin.label.center = CGPoint(x: min(max(p.x, half), bounds.width - half), y: y)
      if pin.parentId == Self.guideParent { drawGuideOutline(pin) }

      if let outline = pin.outline {
        let s = CGFloat(pin.outlineDistance / max(dist, 0.05)) * zoom / pin.outlineZoom
        outline.setAffineTransform(
          CGAffineTransform(translationX: p.x, y: p.y)
            .scaledBy(x: s, y: s)
            .translatedBy(x: -pin.outlineScreenOrigin.x, y: -pin.outlineScreenOrigin.y)
        )
      }
    }
  }

  /// Puts a tag on the edge of `area`, on the line from its middle towards
  /// the tag's part, with its arrow pointing that way. A part behind the phone
  /// is mirrored in front first, so its side still says which way to turn.
  private func placeOnEdge(_ pin: Pin, in area: CGRect) -> Bool {
    guard let camera = sceneView.session.currentFrame?.camera else { return false }
    var local = simd_mul(camera.transform.inverse, simd_float4(tagWorld(pin), 1))
    local.z = -max(abs(local.z), 0.05)
    let ahead = simd_mul(camera.transform, local)
    let projected = sceneView.projectPoint(SCNVector3(ahead.x, ahead.y, ahead.z))
    let q = zoomed(CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y)))
    let middle = CGPoint(x: area.midX, y: area.midY)
    var d = CGVector(dx: q.x - middle.x, dy: q.y - middle.y)
    // Dead behind: say "turn around" by pointing down, where the panel is.
    if abs(d.dx) + abs(d.dy) < 1 { d = CGVector(dx: 0, dy: 1) }
    pin.label.pointing = atan2(d.dy, d.dx)
    let size = pin.label.bounds.size
    let r = area.insetBy(dx: size.width / 2 + 8, dy: size.height / 2 + 6)
    guard r.width > 0, r.height > 0 else { return false }
    let tx = d.dx > 0 ? (r.maxX - middle.x) / d.dx : d.dx < 0 ? (r.minX - middle.x) / d.dx : .infinity
    let ty = d.dy > 0 ? (r.maxY - middle.y) / d.dy : d.dy < 0 ? (r.minY - middle.y) / d.dy : .infinity
    let t = min(tx, ty)
    guard t.isFinite else { return false }
    pin.setHidden(false)
    pin.label.center = CGPoint(x: middle.x + d.dx * t, y: middle.y + d.dy * t)
    return true
  }

  // MARK: - Selection

  @objc private func handleTap(_ g: UITapGestureRecognizer) {
    let p = g.location(in: self)
    for id in pinOrder.reversed() {
      guard let pin = pins[id], !pin.label.isHidden else { continue }
      if pin.label.frame.insetBy(dx: -10, dy: -10).contains(p) {
        // Guide tags report their own part; other callouts report their pin.
        let id = pin.parentId == Self.guideParent ? String(pin.id.dropFirst(Self.guideParent.count + 1)) : (pin.parentId ?? pin.id)
        onPinTap(["id": id])
        return
      }
    }
    guard livePins else {
      outlineTapped(p)
      return
    }
    select(at: p)
  }

  /// A tap with nothing to pin: outline what's under the finger, live, until another tap or
  /// it leaves the picture (then it's the middle of the screen again).
  private func outlineTapped(_ point: CGPoint) {
    guard liveSegments, let frame = sceneView.session.currentFrame else { return }
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let at = viewToUpright(point, frame: frame)
    guard unit.contains(at) else { return }
    let look = GuideFrameContext(selection: Selection(frame: frame, crop: unit), points: frame.rawFeaturePoints?.points ?? [])
    tapTarget = look.anchor(at: at, session: sceneView.session)
    // What's outlined now is something else: let it go, and cut the new one on the next frame.
    if let old = liveShapes[Self.centreKey] {
      retire(old.layer)
      liveShapes[Self.centreKey] = nil
    }
    lastSamTime = 0
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
    pin.outlineZoom = zoom

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
    pinLayer.addSubview(pin.label)
    layoutPins()
    pin.popIn()
    UIImpactFeedbackGenerator(style: pin.parentId == nil ? .medium : .light).impactOccurred()
  }

  // MARK: - Photo, video, torch

  /// Full-resolution still (when the format allows it), written upright as JPEG.
  func takePhoto(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    let session = sceneView.session
    // The JS shutter waits on this promise, so it must settle exactly once,
    // even if ARKit never calls back (a session paused mid-capture).
    var settled = false
    let finish: (ARFrame?) -> Void = { [weak self] frame in
      guard !settled else { return }
      settled = true
      guard let self, let frame = frame ?? session.currentFrame else {
        done(.failure(LensiError.unavailable("The camera isn't ready yet.")))
        return
      }
      let buffer = frame.capturedImage
      self.visionQueue.async {
        let result = self.writePhoto(buffer, maxSide: 3024)
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
    // Fall back to the current frame if the high-resolution one never arrives.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
  }

  /// High-res frames can be 48 MP on Pro phones; 12 MP (3024) is plenty to read labels.
  /// `crop` is in upright 0…1 coordinates, top-left origin.
  private func writePhoto(_ buffer: CVPixelBuffer, maxSide: CGFloat, crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> Result<[String: Any], Error> {
    var image = CIImage(cvPixelBuffer: buffer).oriented(.right)
    if crop != CGRect(x: 0, y: 0, width: 1, height: 1) {
      let e = image.extent
      let r = CGRect(
        x: e.minX + crop.minX * e.width,
        y: e.minY + (1 - crop.maxY) * e.height,
        width: crop.width * e.width,
        height: crop.height * e.height
      ).integral
      image = image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }
    let longest = max(image.extent.width, image.extent.height)
    if longest > maxSide {
      let scale = maxSide / longest
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
  /// Returns whether the torch is now on.
  func setTorch(_ on: Bool) -> Bool {
    guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera, device.hasTorch,
          (try? device.lockForConfiguration()) != nil else {
      return false
    }
    // Always unlock: a camera left locked stays locked for the whole session.
    defer { device.unlockForConfiguration() }
    guard on else {
      device.torchMode = .off
      return false
    }
    // A hot phone makes the torch unavailable; setTorchModeOn throws then.
    guard device.isTorchAvailable, device.isTorchModeSupported(.on),
          (try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)) != nil else {
      return false
    }
    return true
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

  // MARK: - Live guide

  /// Grabs the current frame as an upright JPEG and freezes its camera pose,
  /// so parts found in it can be pinned in 3D once the brain answers, even if
  /// the phone has moved by then.
  func guideCapture(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    guard let frame = sceneView.session.currentFrame else {
      done(.failure(LensiError.unavailable("The camera isn't ready yet.")))
      return
    }
    // Only what's on screen: the camera image is wider than the screen (and
    // zoom crops it further), and the plan should be made from what you see.
    let full = CGRect(x: 0, y: 0, width: 1, height: 1)
    let shown = viewRectToUpright(bounds, frame: frame).intersection(full)
    let crop = shown.isNull || shown.width < 0.05 || shown.height < 0.05 ? full : shown
    let id = UUID().uuidString
    guideFrames[id] = GuideFrameContext(
      selection: Selection(frame: frame, crop: crop),
      points: frame.rawFeaturePoints?.points ?? [],
      crop: crop
    )
    guideFrameOrder.append(id)
    // The plan's look (the first) stays for the whole job: its parts' outlines
    // can arrive late. Later looks (checks, questions) take turns.
    while guideFrameOrder.count > 6 { guideFrames[guideFrameOrder.remove(at: 1)] = nil }
    let buffer = frame.capturedImage
    visionQueue.async { [weak self] in
      guard let self else { return }
      let result = self.writePhoto(buffer, maxSide: 1600, crop: crop)
      DispatchQueue.main.async {
        switch result {
        case .success(var info):
          info["frameId"] = id
          done(.success(info))
        case .failure(let error):
          done(.failure(error))
        }
      }
    }
  }

  /// A tag in the world for a part found at x, y (0…1, upright) in a guide frame.
  func guidePin(frameId: String, id: String, x: Double, y: Double, label: String) {
    guard let ctx = guideFrames[frameId] else { return }
    let pinId = "\(Self.guideParent):\(id)"
    if let existing = pins[pinId] {
      existing.label.text = label
      return
    }
    let world = ctx.anchor(at: CGPoint(x: x, y: y), session: sceneView.session)
    addPin(Pin(id: pinId, parentId: Self.guideParent, world: world, text: label, color: accent))
  }

  /// A part's shape (flat x,y pairs, upright 0…1 in its frame), laid on a
  /// plane through its pin facing the camera that took the frame, so it stays
  /// on the part as the phone moves. Drawn while its step is up.
  func guideOutline(frameId: String, id: String, points: [Double]) {
    guard let ctx = guideFrames[frameId], let pin = pins["\(Self.guideParent):\(id)"], points.count >= 6 else { return }
    let plane = ctx.selection.withPlane(through: pin.world)
    var world: [simd_float3] = []
    var i = 0
    while i + 1 < points.count {
      if let w = plane.onPlane(ctx.full(CGPoint(x: points[i], y: points[i + 1]))) { world.append(w) }
      i += 2
    }
    guard world.count >= 3 else { return }
    pin.guideOutline = world
    if pin.guideShape == nil {
      let shape = OutlineLayer()
      shape.isHidden = true
      // Under the tags.
      pinLayer.layer.insertSublayer(shape, at: 0)
      pin.guideShape = shape
    }
    layoutPins()
  }

  /// A part's outline where it is now: the current step's in the lens colour,
  /// the rest thin and white; none while any corner is behind the phone.
  private func drawGuideOutline(_ pin: Pin) {
    guard let shape = pin.guideShape else { return }
    guard pin.label.pointing == nil, !pin.label.isHidden, !hasLiveOutline(pin),
          let camera = sceneView.session.currentFrame?.camera else {
      shape.isHidden = true
      return
    }
    let toCamera = camera.transform.inverse
    let path = UIBezierPath()
    for (i, w) in pin.guideOutline.enumerated() {
      guard simd_mul(toCamera, simd_float4(w, 1)).z < -0.02 else {
        shape.isHidden = true
        return
      }
      let q = sceneView.projectPoint(SCNVector3(w.x, w.y, w.z))
      let p = zoomed(CGPoint(x: CGFloat(q.x), y: CGFloat(q.y)))
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.close()
    shape.setOutline(path.cgPath)
    let focused = pin.label.emphasis == .focused
    shape.style(focused ? accent : .white, width: focused ? 2.5 : 1.5, stroke: focused ? 1 : 0.75, fill: focused ? 0.14 : 0.06)
    shape.isHidden = false
  }

  /// The current step's part stands out in the lens colour; the rest step back.
  func guideFocus(_ id: String?) {
    let target = id.map { "\(Self.guideParent):\($0)" }
    for pin in pins.values where pin.parentId == Self.guideParent {
      pin.label.color = accent
      pin.label.emphasis = target == nil ? .normal : (pin.id == target ? .focused : .dimmed)
    }
  }

  func guideWatch(_ id: String?) {
    guideWatchId = id.map { "\(Self.guideParent):\($0)" }
    watch.reset()
    lastWatchTransform = nil
  }

  func guideClear() {
    for pin in pins.values where pin.parentId == Self.guideParent {
      pin.removeFromSuperview()
      pins[pin.id] = nil
    }
    pinOrder.removeAll { pins[$0] == nil }
    guideFrames.removeAll()
    guideFrameOrder.removeAll()
    guideWatchId = nil
    watch.reset()
    tapTarget = nil
  }

  /// Twice a second, while the phone is steady and the watched part is in
  /// view, compare a crop around it with how it looked before.
  private func watchGuide(_ frame: ARFrame) {
    guard let id = guideWatchId, let pin = pins[id], !watchBusy, frame.timestamp - lastWatchTime > 0.5 else { return }
    let transform = frame.camera.transform
    let previous = lastWatchTransform
    lastWatchTransform = transform
    lastWatchTime = frame.timestamp
    // A moving phone changes every crop; only a steady one can see a change.
    if let previous {
      let moved = simd_distance(simd_make_float3(transform.columns.3), simd_make_float3(previous.columns.3))
      let facing = simd_dot(simd_normalize(simd_make_float3(transform.columns.2)), simd_normalize(simd_make_float3(previous.columns.2)))
      if moved > 0.02 || facing < 0.9986 {
        watch.unsettle()
        return
      }
    }
    let local = simd_mul(transform.inverse, simd_float4(pin.world, 1))
    guard local.z < -0.05 else {
      watch.unsettle()
      return
    }
    let res = frame.camera.imageResolution
    let upright = CGSize(width: res.height, height: res.width)
    let p = frame.camera.projectPoint(pin.world, orientation: .portrait, viewportSize: upright)
    let point = CGPoint(x: p.x / upright.width, y: p.y / upright.height)
    guard point.x > 0.08, point.x < 0.92, point.y > 0.08, point.y < 0.92 else {
      watch.unsettle()
      return
    }
    watchBusy = true
    let distance = -local.z
    let buffer = frame.capturedImage
    let now = frame.timestamp
    visionQueue.async { [weak self] in
      let fp = ChangeWatch.featurePrint(buffer, around: point, distance: distance, upright: upright)
      DispatchQueue.main.async {
        guard let self else { return }
        self.watchBusy = false
        guard let fp, self.guideWatchId == id else { return }
        if let d = self.watch.add(fp, now: now) {
          self.onGuideChange(["id": String(id.dropFirst(Self.guideParent.count + 1)), "distance": d])
        }
      }
    }
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

/// A guide frame: its frozen pose plus the feature points ARKit had tracked,
/// which give a depth when a raycast finds no surface (a pipe in mid-air).
private struct GuideFrameContext {
  let selection: Selection
  let points: [simd_float3]
  /// The part of the camera image the guide photo shows (upright 0…1).
  var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

  /// A point in the guide photo, in the whole camera image.
  func full(_ p: CGPoint) -> CGPoint {
    CGPoint(x: crop.minX + p.x * crop.width, y: crop.minY + p.y * crop.height)
  }

  func anchor(at point: CGPoint, session: ARSession) -> simd_float3 {
    let (origin, dir) = selection.ray(full(point))
    let query = ARRaycastQuery(origin: origin, direction: dir, allowing: .estimatedPlane, alignment: .any)
    if let hit = session.raycast(query).first {
      let p = simd_make_float3(hit.worldTransform.columns.3)
      if simd_distance(p, origin) < 4 { return p }
    }
    // Tracked points within ~3.5 degrees of the ray: their median depth.
    var depths: [Float] = []
    for q in points {
      let v = q - origin
      let t = simd_dot(v, dir)
      guard t > 0.05, t < 4 else { continue }
      if simd_length(v - dir * t) / t < 0.06 { depths.append(t) }
    }
    if !depths.isEmpty {
      depths.sort()
      return origin + dir * depths[depths.count / 2]
    }
    return origin + dir * 0.55
  }
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

  /// Where world points land in this camera's upright picture (0…1, the inverse of `ray`);
  /// nil when any is behind it.
  func upright(_ world: [simd_float3]) -> [CGPoint]? {
    let toCamera = transform.inverse
    let fx = intrinsics[0][0], fy = intrinsics[1][1]
    let cx = intrinsics[2][0], cy = intrinsics[2][1]
    var out: [CGPoint] = []
    out.reserveCapacity(world.count)
    for w in world {
      let c = simd_mul(toCamera, simd_float4(w, 1))
      guard c.z < -0.02 else { return nil }
      let px = cx + fx * c.x / -c.z
      let py = cy - fy * c.y / -c.z
      out.append(CGPoint(x: 1 - CGFloat(py) / resolution.height, y: CGFloat(px) / resolution.width))
    }
    return out
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
