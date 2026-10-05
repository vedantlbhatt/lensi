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
  /// Every 3 s while EdgeTAM follows something: how often it really looks on this phone and how
  /// late its answers are (from the frame it looked at to the answer landing), so what the
  /// footage tools assume (tools/edgetrack's EDGETRACK_LIVE_MS) can be checked on the phone.
  let onLiveStats = EventDispatcher()

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
  /// EdgeTAM (Meta's on-device SAM 2, EdgeTAMTracker) once it has loaded: it follows every pinned
  /// thing every frame from its memory of it (the frame it was pinned on and the last few), which
  /// holds on through close-ups, zooming out, blur and turning where a fresh SAM cut each frame
  /// jumps about (tools/edgetam, on a handheld clip of a bottle). Nil until then, and on a phone
  /// without its models: then SAM re-cuts pinned things, as it does guide parts.
  private var edgeTAM: EdgeTAMTracker.Models?
  /// Only touched on `samQueue`: the camera's encoder for EdgeTAM, and each pinned thing's tracker.
  private var edgeEncoder: EdgeTAMTracker.Encoder?
  private var edgeTrackers: [String: EdgeTAMTracker] = [:]
  private var edgeLogTime: CFTimeInterval = 0
  /// The last EdgeTAM step's milliseconds (written on `samQueue`, read once its answer lands).
  private var edgeStepMs: [String: Double] = [:]
  /// EdgeTAM's answers over the last 3 s: when the frame it looked at was taken, when the answer
  /// landed (onLiveStats).
  private var edgeAnswers: [(taken: CFTimeInterval, landed: CFTimeInterval)] = []
  private var edgeStatsTime: CFTimeInterval = 0
  /// Live outlines by what they're of: a guide tag's pin id, or a pinned thing's. Their state
  /// is LiveShape (LiveWorld.swift, which tools/pin runs on ARKit's recorded poses); their
  /// layers are here, and where each was last drawn on screen (a pinned thing's tag sits above it).
  private var liveShapes: [String: LiveShape] = [:]
  private var liveLayers: [String: OutlineNode] = [:]
  private var liveBoxes: [String: CGRect] = [:]
  /// Every outline (live ones, the strip's, guide parts'), drawn by SceneKit in the world with
  /// the camera image, so they never slide against it (OutlineNode).
  private let outlines = SCNNode()
  /// How fast the phone itself turns (radians a second) and moves (metres a second), steadied:
  /// past LiveShape.fastTurn or fastMove the picture is a blur and what the flow and SAM say
  /// about a thing's own motion is mostly the phone's, so it isn't taken as the thing's (ARKit
  /// already keeps every outline where it is in the world).
  private var phoneTurn: Float = 0
  private var phoneMove: Float = 0
  private var lastPhonePose: (transform: simd_float4x4, t: TimeInterval)?
  private var phoneFast: Bool { phoneTurn > LiveShape.fastTurn || phoneMove > LiveShape.fastMove }
  /// Which pinned things SAM re-cuts next (one or two a frame, in turns).
  private var pinTurn = 0
  /// Between SAM's cuts, followed outlines ride their own pixels (`flowLive`).
  private let flowQueue = DispatchQueue(label: "lensi.flow", qos: .userInitiated)
  private var flowBusy = false
  private var lastFlowTime: TimeInterval = 0
  private var flowMs: Double = 0
  /// Only touched on `flowQueue`: the last frame the flow saw (as LiveFlow sees it, with its
  /// camera and capture time), and what makes the small copies.
  private var flowPrevious: (frame: LiveFlow.Frame, camera: FrozenCamera, t: CFTimeInterval)?
  private lazy var flowContext = CIContext(options: [.useSoftwareRenderer: false])
  /// Taps pin things in space only in live mode; otherwise a tap on the camera does nothing
  /// (things are picked and pinned on the strip: `scrubStart`).
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
  private var contexts: [String: FrozenCamera] = [:]

  // The strip (slide to pick, hold to pin): the things in view when the finger landed.
  private var scrubThings: [ScrubThing] = []
  private var scrubIndex: Int?
  /// Bumped by every landing and lift: a search that answers after its finger has gone is dropped.
  private var scrubSession = 0
  /// The strip's search is on SAM's queue: the live outlines wait for it.
  private var scrubBusy = false

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
  /// 0.5x on a phone whose ARKit has no ultra-wide format (UltraWideCamera): ARKit pauses, and
  /// pinned things are followed on the ultra-wide's picture by EdgeTAM alone, drawn flat over it,
  /// until the zoom is back at 1x (then ARKit picks up its world, and every pin, where it was).
  private var wide: UltraWideCamera?
  private var wideMode = false
  private var lastWideTime: CFTimeInterval = 0
  /// Each pinned thing's outline on the ultra-wide picture (upright 0…1, OutlineMath.count
  /// points, glided from one cut to the next: OutlineMath.glide), and the layer drawing it.
  private var wideOutlines: [String: [CGPoint]] = [:]
  private var wideLayers: [String: FlatOutline] = [:]
  /// When the frame each one was found in was captured, and the ultra-wide picture's upright
  /// size: drawn, it's moved on by how the phone has turned since (UltraWideCamera.warp).
  private var wideTimes: [String: CFTimeInterval] = [:]
  private var wideSize = CGSize(width: 1080, height: 1920)
  /// Where each one is, as FlatFollower keeps it: EdgeTAM's answers, each glided into what was shown
  /// on its frame and brought on to the newest, and between answers every outline bent with its
  /// thing frame to frame by the ultra-wide's own pixels (LiveFlow.bend), the gyro moving it where
  /// they can't say. Before, only the gyro moved it between answers: how the phone turned, not how
  /// it moved or how the thing did. Only touched on `wideFlowQueue`; `wideOutlines` and `wideTimes`
  /// are what it last said (`showWide`).
  private let wideFollower = FlatFollower()
  private let wideFlowQueue = DispatchQueue(label: "lensi.wide-flow", qos: .userInitiated)
  private let wideFlowContext = CIContext(options: [.cacheIntermediates: false])
  private var wideFlowBusy = false
  /// Counts the times 0.5x has started: what the follower said about an earlier time is dropped.
  private var wideSession = 0
  /// Things pinned at 0.5x, where there's no world to lay them in: followed on the ultra-wide by
  /// EdgeTAM from the frame they were found in, and laid in the world from their first cut once
  /// ARKit is back at 1x (where they're at, measured inside the cut, or a guess its lines of
  /// sight put right: LiveShape.sight). Hidden at 1x until then.
  private var flatPins: Set<String> = []
  /// Pinned things back at 1x from 0.5x, not cut since: ARKit was paused, and its world can come
  /// back somewhere else, so where they should be isn't trusted for their first cut (followEdge).
  private var returning: Set<String> = []
  /// The strip at 0.5x: the frame its things were found in (their outlines are on it), and the
  /// highlighted one's layer.
  private var wideScrubFrame: (buffer: CVPixelBuffer, t: CFTimeInterval)?
  private var wideScrubLayer: FlatOutline?
  /// Callouts the brain put on a thing pinned at 0.5x before it was in the world: placed with
  /// it once it is (`takeLive`).
  private var flatCallouts: [String: [(id: String, x: Double, y: Double, text: String)]] = [:]
  /// 0.5x is there: ARKit's own ultra-wide, or the ultra-wide camera on its own.
  private var hasUltraWide: Bool { ultraWideFormat != nil || UltraWideCamera.available }
  private var recorder: Recorder?
  private let photoContext = CIContext(options: [.useSoftwareRenderer: false])

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black

    sceneView.session.delegate = self
    sceneView.automaticallyUpdatesLighting = false
    sceneView.rendersCameraGrain = false
    // Outlines are drawn in the scene (OutlineNode): smooth edges on their thin lines.
    sceneView.antialiasingMode = .multisampling4X
    let scene = SCNScene()
    scene.rootNode.addChildNode(outlines)
    sceneView.scene = scene
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
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let started = CACurrentMediaTime()
      let loaded = EdgeTAMTracker.Models.shared
      if loaded == nil {
        NSLog("[lensi] EdgeTAM isn't available (models missing from the app?): SAM re-cuts pinned things")
      } else {
        NSLog("[lensi] EdgeTAM loaded in %.1f s", CACurrentMediaTime() - started)
      }
      DispatchQueue.main.async { self?.edgeTAM = loaded }
    }

    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // bounds + center, not frame: the camera view carries the zoom as a transform.
    sceneView.bounds = CGRect(origin: .zero, size: bounds.size)
    sceneView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    if let preview = wide?.preview {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      preview.bounds = CGRect(origin: .zero, size: bounds.size)
      preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
      CATransaction.commit()
    }
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
    if wideMode {
      wide?.start()
    } else {
      sceneView.session.run(config)
    }
    onZoomRange(["min": hasUltraWide ? 0.5 : 1, "max": Double(Self.maxZoom), "zoom": Double(zoomFactor)])
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
    wide?.stop()
  }

  private func makeConfiguration() -> ARWorldTrackingConfiguration {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      config.sceneReconstruction = .mesh
    }
    // LiDAR's depth with every frame, on a phone that has one: how far a pinned thing is,
    // measured inside each cut of it (LiveShape.setDepth).
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
      config.frameSemantics.insert(.smoothedSceneDepth)
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
  // tag's part, and each thing pinned from the strip, is in this frame, so its
  // outline is re-cut from wherever the phone is now. Nothing else is outlined
  // by itself, so moving the phone never changes what is.
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
    /// The shape follows its thing from frame to frame (a guide part, a pinned thing).
    let follows: Bool
    /// Which cut to take as the thing, and how to blend it in (LiveTracker.asking: strict and
    /// gentle for a still thing).
    var gate: LiveTracker.Gate = .loose
    var smoothing: OutlineMath.Smoothing = .standard
    /// Followed by EdgeTAM (`box` starts it; after that it needs no prompt), not cut by SAM.
    var edge = false
    /// Pinned at 0.5x and not yet in the world: its first cut at 1x is laid where it's measured
    /// to be (`anchor` means nothing yet).
    var unplaced = false
    /// Up close, how much bigger or smaller the part on the picture can make the whole outline
    /// in one cut (LiveTracker.follow).
    var scaleLimit: CGFloat = 1.4
    /// Back at 1x from 0.5x: where it should be may be stale (ARKit's world can come back
    /// elsewhere); its cut is laid afresh where it's seen.
    var returning = false
  }

  private func segmentLive(_ frame: ARFrame) {
    // Not while a photo is being analysed: a plan or an answer is waiting on that.
    guard liveSegments, !samBusy, !scrubBusy, bounds.width > 0, let sam, !Analyzer.analyzing else { return }
    // As often as the phone keeps up; less often once it runs hot, or while it's propped up
    // and still with nothing moving in front of it (then 4 times a second is plenty).
    var gap: TimeInterval
    switch ProcessInfo.processInfo.thermalState {
    case .critical: gap = 0.6
    case .serious: gap = 0.25
    // Only pinned things, followed by EdgeTAM (one encoder pass and a step each): up to 20 times
    // a second, so what's drawn between its outlines (ARKit, the flow) has less to cover.
    default: gap = edgeTAM != nil && !pins.values.contains(where: { $0.parentId == Self.guideParent }) ? 0.05 : 0.08
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
    // A shape that follows its thing: SAM is asked where it should be in this frame (its
    // outline carried along by its own motion, seen from where the phone is now).
    func follow(_ key: String) -> LivePrompt? {
      guard let shape = liveShapes[key], shape.follows, shape.misses < 2 || shape.pinned else { return nil }
      let now = shape.placed(at: frame.timestamp)
      // A pinned thing SAM has lost (behind a hand, out of view) is only taken back where it
      // was and as it was: asked for as a still thing, strictly.
      // A still thing whose depth is known, seen from about where it was last cut, takes only a
      // cut that matches it closely: one that's grown onto a neighbour is refused. (At a guessed
      // depth where it should be is off as the phone moves, and that would refuse good cuts.)
      let still = shape.misses >= 2 || shape.still
      let turned = shape.depthKnown ? shape.turned(from: simd_make_float3(frame.camera.transform.columns.3)) : nil
      let asking = LiveTracker.asking(still: still, turned: turned)
      // Up close only part of it is on the picture: SAM is asked about that part (and the rest
      // goes where that part goes: LiveTracker.follow), unless too little of it is left to say.
      guard let predicted = uprightPoints(now, camera: frame.camera, upright: upright),
            LiveTracker.visibleFraction(predicted) >= LiveTracker.minVisible,
            let p = LiveTracker.prompt(for: predicted, scale: upright, grow: asking.grow) else { return nil }
      return LivePrompt(key: key, point: p.point, box: p.box, part: false, anchor: OutlineMath.centre(now), predicted: predicted,
                        follows: true, gate: asking.gate, smoothing: asking.smoothing)
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
    }
    // Pinned things (the strip). EdgeTAM follows every one every frame, from its memory of it:
    // its box where it is now only starts it. Without EdgeTAM, SAM re-cuts one or two a frame, in
    // turns, each where it should be now.
    let held = pinOrder.filter { liveShapes[$0]?.pinned == true }
    if edgeTAM != nil {
      for key in held {
        guard let shape = liveShapes[key] else { continue }
        let now = shape.placed(at: frame.timestamp)
        let predicted = uprightPoints(now, camera: frame.camera, upright: upright)
        let visible = predicted.map { LiveTracker.clipped($0) } ?? []
        let box = visible.count >= 3 ? LiveTracker.bounds(visible) : nil
        // Up close, the part of it on the picture moves a still thing whose depth is known only a
        // little (ARKit already scales it as the phone comes closer), and is taken only if it's
        // plausibly the same thing (the loose gate: on walk-arounds the strict one SAM's cuts use
        // refused EdgeTAM's good cuts and lost a TV in 65% of frames, against 33%; tools/walk).
        let asking = LiveTracker.asking(still: shape.still)
        prompts.append(LivePrompt(key: key, point: nil, box: box, part: false, anchor: OutlineMath.centre(now), predicted: predicted,
                                  follows: true, gate: .loose, smoothing: asking.smoothing, edge: true,
                                  scaleLimit: shape.still && shape.depthKnown ? 1.1 : 1.4, returning: returning.contains(key)))
      }
      // Pinned at 0.5x: EdgeTAM is already following them; their first cut here lays them in the world.
      for key in pinOrder where flatPins.contains(key) {
        prompts.append(LivePrompt(key: key, point: nil, box: nil, part: false, anchor: .zero, predicted: nil,
                                  follows: true, edge: true, unplaced: true))
      }
    } else if !held.isEmpty {
      let ask = min(prompts.isEmpty ? 2 : 1, held.count)
      var asked = 0
      for i in 0..<held.count where asked < ask {
        if let p = follow(held[(pinTurn + i) % held.count]) {
          prompts.append(p)
          asked += 1
        }
      }
      pinTurn += 1
    }
    guard !prompts.isEmpty else { return }
    samBusy = true
    lastSamTime = frame.timestamp
    lastSamPose = pose
    let buffer = frame.capturedImage
    let captured = frame.timestamp
    let camera = FrozenCamera(frame: frame, crop: unit)
    // What says how far each thing is: LiDAR's depth, or ARKit's points.
    let measured = DepthSample(frame)
    let points = frame.rawFeaturePoints?.points ?? []
    let edge = edgeTAM
    samQueue.async { [weak self] in
      let started = CACurrentMediaTime()
      var encodeMs: Double = 0
      var found: [String: LiveCut] = [:]
      var refused = 0
      var failure: String?
      do {
        let samPrompts = prompts.filter { !$0.edge }
        if !samPrompts.isEmpty {
          try sam.prepare(pixelBuffer: buffer, orientation: .right, id: "live")
          encodeMs = (CACurrentMediaTime() - started) * 1000
        }
        if let edge, let self {
          let followed = prompts.filter(\.edge)
          found = try self.followEdge(followed, models: edge, buffer: buffer, camera: camera, upright: upright,
                                      measured: measured, points: points)
        }
        for p in samPrompts {
          // Following a thing: of SAM's candidates, the one that overlaps where it should be wins,
          // so the outline doesn't flip between "the handle" and "the whole mug" (from smooth-seg).
          let mask = try sam.segment(
            id: "live", points: p.point.map { [$0] } ?? [], labels: p.point == nil ? [] : [1], box: p.box, preferPart: p.part,
            prior: p.predicted)
          guard mask.score >= (p.predicted == nil ? 0.6 : 0.5), mask.polygon.count > 2 else { continue }
          // Evenly spaced (in pixels).
          let cut = OutlineMath.resample(mask.polygon, scale: upright)
          var ring = cut
          // Following a thing: a cut that doesn't fit where it should be is something else. Up
          // close the cut is only the part on the picture, and the whole outline goes where it went.
          if let predicted = p.predicted {
            guard let taken = LiveTracker.follow(cut: cut, predicted: predicted, gate: p.gate) else {
              refused += 1
              continue
            }
            ring = taken
          }
          // Onto the thing's plane in the world.
          let plane = camera.withPlane(through: p.anchor)
          let world = ring.compactMap { plane.onPlane($0) }
          guard world.count == ring.count else { continue }
          // How far it really is, measured inside the cut: LiDAR's depth, else ARKit's points on it.
          var depth: (metres: Float, weight: Float)?
          if let d = measured?.inside(cut) {
            depth = (d, LiveShape.lidarWeight)
          } else if let d = camera.medianDepth(of: points, inside: cut) {
            depth = (d, LiveShape.pointsWeight)
          }
          found[p.key] = LiveCut(world: world, depth: depth, middle: LiveShape.sightable(cut) ? Self.middle(cut) : nil)
        }
      } catch {
        failure = error.localizedDescription
      }
      let ms = (CACurrentMediaTime() - started) * 1000
      let results = found, encoded = encodeMs, failed = failure, refusals = refused
      let edgeMs = edge != nil && prompts.contains(where: \.edge) ? self?.edgeStepMs : nil
      DispatchQueue.main.async {
        guard let self else { return }
        self.samBusy = false
        if let edgeMs, failed == nil { self.edgeAnswered(taken: captured, stepMs: edgeMs, things: prompts.filter(\.edge).count) }
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
        self.takeLive(results, asked: prompts, at: captured, seenBy: camera)
      }
      // The answers are on their way: each tracker's frame goes into its memory now, while the
      // next frame is awaited (EdgeTAMTracker.commit).
      if edge != nil { self?.rememberEdge() }
    }
  }

  /// On `samQueue`: each tracker's last frame into its memory (EdgeTAMTracker.commit), once its
  /// answer has been handed over, so no answer waits for the memory model.
  private func rememberEdge() {
    for tracker in edgeTrackers.values {
      do {
        try tracker.commit()
      } catch {
        NSLog("[lensi] EdgeTAM's memory failed: %@", error.localizedDescription)
      }
    }
  }

  /// An EdgeTAM answer landed (main thread); every 3 s, how often they land and how late (onLiveStats).
  private func edgeAnswered(taken: CFTimeInterval, stepMs: [String: Double], things: Int) {
    let now = CACurrentMediaTime()
    edgeAnswers.append((taken, now))
    edgeAnswers.removeAll { now - $0.landed > 3 }
    guard now - edgeStatsTime > 3, edgeAnswers.count >= 3, let first = edgeAnswers.first else { return }
    edgeStatsTime = now
    let late = edgeAnswers.map { ($0.landed - $0.taken) * 1000 }.sorted()
    let rate = Double(edgeAnswers.count - 1) / max(now - first.landed, 1e-3)
    onLiveStats([
      "looksPerSecond": rate, "latencyMs": late[late.count / 2], "stepMs": stepMs, "things": things,
      "thermal": ProcessInfo.processInfo.thermalState.rawValue,
    ])
  }

  /// EdgeTAM's step for each pinned thing in `buffer` (on `samQueue`, the only place its state is
  /// touched): one encoder pass for them all, then each thing's own tracker, started from its box
  /// the first time. Each outline it finds is laid in the world like a SAM cut (on a plane through
  /// the thing, at the depth measured inside it); a thing it says isn't in view isn't found, and
  /// counts a miss. Trackers of things no longer pinned go.
  private func followEdge(_ asked: [LivePrompt], models: EdgeTAMTracker.Models, buffer: CVPixelBuffer, camera: FrozenCamera,
                          upright: CGSize, measured: DepthSample?, points: [simd_float3]) throws -> [String: LiveCut] {
    let keys = Set(asked.map(\.key))
    for key in edgeTrackers.keys where !keys.contains(key) { edgeTrackers[key] = nil }
    guard !asked.isEmpty else { return [:] }
    let encoder = try edgeEncoder ?? EdgeTAMTracker.Encoder(models: models)
    edgeEncoder = encoder
    let picture = try encoder.encode(CIImage(cvPixelBuffer: buffer).oriented(.right))
    var found: [String: LiveCut] = [:]
    for p in asked {
      let cut: EdgeTAMTracker.Cut
      if let tracker = edgeTrackers[p.key], tracker.started {
        cut = try tracker.step(picture)
      } else {
        // Not started until its box is on the picture.
        guard let box = p.box, box.width > 0.01, box.height > 0.01 else { continue }
        let tracker = try EdgeTAMTracker(models: models)
        cut = try tracker.start(picture, box: box)
        edgeTrackers[p.key] = tracker
      }
      let now = CACurrentMediaTime()
      edgeStepMs = cut.ms.merging(["memory": edgeTrackers[p.key]?.lastMemoryMs ?? 0]) { a, _ in a }
      if now - edgeLogTime > 3 {
        edgeLogTime = now
        let ms = cut.ms.sorted { $0.key < $1.key }.map { String(format: "%@ %.0f", $0.key, $0.value) }.joined(separator: ", ")
        NSLog("[lensi] EdgeTAM: %ld things, score %.1f, ms: %@", asked.count, cut.score, ms)
      }
      guard cut.visible else { continue }
      let seen = OutlineMath.resample(cut.outline, scale: upright)
      var ring = seen
      var anchor = p.anchor
      // The whole thing on the picture, nowhere near where it should be (or where it should be is
      // behind the phone): ARKit's world moved under it (paused at 0.5x, it can come back with its
      // world somewhere else), or it moved further than it was followed. Laid through where it
      // was, it'd stay wrong, or never be laid at all; it's laid afresh where it's seen.
      let whole = !Self.touchesEdge(seen)
      let astray = !p.unplaced && (p.returning || (whole && (p.predicted.map { LiveTracker.iou(seen, LiveTracker.clipped($0)) < 0.05 } ?? true)))
      if p.unplaced || astray {
        // Up close, the whole outline as it should be, moved onto the part of it on the picture
        // however far that is from where it should be (that's what's stale).
        if !whole, let predicted = p.predicted, LiveTracker.visibleFraction(predicted) < LiveTracker.wholeVisible,
           let moved = LiveTracker.follow(cut: seen, predicted: predicted, gate: .any, scaleLimit: p.scaleLimit) {
          ring = moved
        }
        // Where it's measured to be (LiDAR, ARKit's points on it), else as far off as it was along
        // its middle's line of sight (pinned at 0.5x: a metre), which its lines of sight put right
        // as it's followed (LiveShape.sight).
        let middle = Self.middle(ring)
        let (origin, dir) = camera.ray(middle)
        if let d = measured?.inside(seen) ?? camera.medianDepth(of: points, inside: seen) {
          anchor = origin + dir * camera.range(depth: d, through: middle)
        } else if astray {
          anchor = origin + dir * min(max(simd_distance(camera.position, p.anchor), 0.2), 6)
        } else {
          anchor = origin + dir
        }
      } else if Self.touchesEdge(seen), let predicted = p.predicted, LiveTracker.visibleFraction(predicted) < LiveTracker.wholeVisible {
        // Up close it runs off the picture, and EdgeTAM can only outline the part on it: the whole
        // outline goes where that part went, rather than stopping at the picture's edge. A part
        // that doesn't fit where the thing should be isn't taken (ARKit holds it meanwhile): laid
        // as the whole thing, or carried far by it, it threw the whole outline about a close-up
        // sink and washer (tools/walk).
        guard let followed = LiveTracker.follow(cut: seen, predicted: predicted, gate: p.gate, scaleLimit: p.scaleLimit) else { continue }
        ring = followed
      }
      let plane = camera.withPlane(through: anchor)
      let world = ring.compactMap { plane.onPlane($0) }
      guard world.count == ring.count else { continue }
      var depth: (metres: Float, weight: Float)?
      if let d = measured?.inside(seen) {
        depth = (d, LiveShape.lidarWeight)
      } else if let d = camera.medianDepth(of: points, inside: seen) {
        depth = (d, LiveShape.pointsWeight)
      }
      found[p.key] = LiveCut(world: world, depth: depth, middle: LiveShape.sightable(seen) ? Self.middle(seen) : nil, replace: astray)
    }
    return found
  }

  /// The middle of an outline's points (evenly spaced: OutlineMath.resample).
  private static func middle(_ ring: [CGPoint]) -> CGPoint {
    let n = CGFloat(max(ring.count, 1))
    return CGPoint(x: ring.reduce(0) { $0 + $1.x } / n, y: ring.reduce(0) { $0 + $1.y } / n)
  }

  /// An outline (upright 0…1) that reaches the picture's edge: the thing runs off it.
  private static func touchesEdge(_ outline: [CGPoint], margin: CGFloat = 0.006) -> Bool {
    outline.contains { $0.x < margin || $0.x > 1 - margin || $0.y < margin || $0.y > 1 - margin }
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

  /// One of SAM's cuts, laid in the world, and how far away its thing is as measured inside it
  /// (and how much to go by that), if anything did.
  private struct LiveCut {
    let world: [simd_float3]
    let depth: (metres: Float, weight: Float)?
    /// The middle of a cut of the whole thing (none of it off the picture), upright: its line of
    /// sight says how far it is once the phone has moved (LiveShape.sight).
    var middle: CGPoint? = nil
    /// Laid afresh rather than blended in: EdgeTAM saw the whole thing nowhere near where it
    /// should be (followEdge).
    var replace = false
  }

  /// SAM's answers for one frame (captured at `t`, by `camera`): found shapes are blended into
  /// what's shown, their motion measured and their depth put right (LiveShape: a cut is laid at
  /// the depth the outline already had, a guess to start with); asked-for ones it didn't find, or
  /// whose cut didn't fit, count a miss (two in a row and they go).
  private func takeLive(_ found: [String: LiveCut], asked: [LivePrompt], at t: CFTimeInterval, seenBy camera: FrozenCamera) {
    for prompt in asked {
      let key = prompt.key
      if let cut = found[key] {
        let world = cut.world
        returning.remove(key)
        if cut.replace, let old = liveShapes[key] {
          // Seen nowhere near where it should be (ARKit's world moved under it): where it was
          // goes, and it's laid afresh where it was seen, still pinned.
          var shape = LiveShape(world: world, at: t, follows: old.follows)
          shape.pinned = old.pinned
          shape.tagOffset = old.tagOffset
          shape.depthKnown = cut.depth != nil
          if let depth = cut.depth { shape.setDepth(depth.metres, seenBy: camera, weight: depth.weight) }
          liveShapes[key] = shape
          if let pin = pins[key] { pin.world = OutlineMath.centre(world) + (old.tagOffset ?? .zero) }
        } else if var shape = liveShapes[key], shape.pinned || t - shape.seen < 2 {
          // A pinned thing is blended back however long it was lost: its cut was asked for where
          // it should be, and had to fit it there.
          // While the phone itself moves fast, where the cut landed says little about the
          // thing's own speed.
          shape.take(world, at: t, how: prompt.smoothing, measure: !phoneFast, seenFrom: camera.position)
          if let depth = cut.depth { shape.setDepth(depth.metres, seenBy: camera, weight: depth.weight) }
          // Without LiDAR, where its lines of sight cross says how far it is (a black bottle has
          // no ARKit points on it).
          if let middle = cut.middle, (cut.depth?.weight ?? 0) < LiveShape.lidarWeight {
            shape.sight(middle, seenBy: camera, at: t)
          }
          liveShapes[key] = shape
        } else {
          // New, or not seen for a while: start over.
          liveLayers[key]?.removeFromParentNode()
          let node = OutlineNode()
          node.isHidden = true
          outlines.addChildNode(node)
          liveLayers[key] = node
          var shape = LiveShape(world: world, at: t, follows: prompt.follows)
          if prompt.unplaced, let pin = pins[key] {
            // Pinned at 0.5x: in the world now, a pinned thing like any other.
            shape.pinned = true
            shape.tagOffset = .zero
            shape.depthKnown = cut.depth != nil
            pin.world = OutlineMath.centre(world)
            flatPins.remove(key)
            // Its callouts were put on a crop of it from the ultra-wide; the box round it here
            // stands in for that crop.
            if let seen = camera.upright(world) {
              let r = LiveTracker.bounds(seen)
              let crop = r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
              if !crop.isNull, crop.width > 0.02, crop.height > 0.02 {
                contexts[key] = FrozenCamera(transform: camera.transform, intrinsics: camera.intrinsics, resolution: camera.resolution,
                                             crop: crop).withPlane(through: pin.world)
              }
            }
            for c in flatCallouts.removeValue(forKey: key) ?? [] {
              addCallout(parentId: key, id: c.id, x: c.x, y: c.y, text: c.text)
            }
          } else if let pin = pins[key] {
            let offset = pin.world - OutlineMath.centre(world)
            shape.tagOffset = simd_length(offset) < 0.5 ? offset : .zero
          }
          if let depth = cut.depth { shape.setDepth(depth.metres, seenBy: camera, weight: depth.weight) }
          liveShapes[key] = shape
        }
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
          liveShapes.values.contains(where: { $0.follows && !Self.heldByARKit($0) }) else { return }
    flowBusy = true
    lastFlowTime = frame.timestamp
    let buffer = frame.capturedImage
    let camera = FrozenCamera(frame: frame, crop: CGRect(x: 0, y: 0, width: 1, height: 1))
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
        // Not while the phone itself moves fast: the picture is a blur, and what moved in it is
        // mostly the phone, which ARKit has already taken care of.
        guard let now, let previous, t - previous.t < 0.25, self.liveSegments, !self.phoneFast else { return }
        self.carryLive(from: previous.frame, previous.camera, at: previous.t, to: now, camera, at: t)
      }
    }
  }

  /// One frame to the next (`a`, seen by camera `ca` at `ta`; `b`, by `cb` at `tb`), applied
  /// to each followed outline: seen from `ca`, carried on the picture, laid back in the world
  /// on a plane through its middle as `cb` sees it. The phone's own motion is in the picture's
  /// too and cancels out in the round trip; what's left is the thing's.
  private func carryLive(from a: LiveFlow.Frame, _ ca: FrozenCamera, at ta: CFTimeInterval,
                         to b: LiveFlow.Frame, _ cb: FrozenCamera, at tb: CFTimeInterval) {
    for (key, var shape) in liveShapes where shape.follows && shape.misses < 2 && !Self.heldByARKit(shape) {
      if shape.carry(from: a, ca, at: ta, to: b, cb, at: tb) { liveShapes[key] = shape }
    }
  }

  /// A still thing whose depth has been measured isn't carried by the flow: ARKit already holds
  /// it where it is, and the flow could add only its own noise. On handheld walk-arounds that
  /// took the outline's wobble against its thing from 8 px to 3 (tools/walk). Laid at a depth
  /// that's only a guess, the flow keeps it on its thing as the phone moves.
  private static func heldByARKit(_ shape: LiveShape) -> Bool {
    shape.still && shape.depthKnown
  }

  /// Every display frame: each live outline drawn where its thing is now (carried along by
  /// its own motion between SAM's frames; the phone's is ARKit's). The current step's part and
  /// every pinned thing bold in their colour, other parts thin and white. A guide part's goes
  /// (fading) once SAM has missed it twice in a row or its tag goes; one that's simply not been
  /// asked about lately (out of view, or waiting its turn) stays where it is in the world for up
  /// to `liveStale`. A pinned thing's goes only with its pin: lost, it stays where it was.
  private func layoutLive() {
    guard !liveShapes.isEmpty else { return }
    let now = CACurrentMediaTime()
    let eye = outlineEye()
    for (key, var shape) in liveShapes {
      let pin = pins[key]
      let age = now - shape.cut
      guard let node = liveLayers[key] else {
        liveShapes[key] = nil
        continue
      }
      if pin == nil || (!shape.pinned && (shape.misses >= 2 || age > Self.liveStale)) {
        node.retire()
        liveShapes[key] = nil
        liveLayers[key] = nil
        liveBoxes[key] = nil
        continue
      }
      guard let eye, pin.map({ !$0.label.isHidden && $0.label.pointing == nil }) ?? true else {
        node.isHidden = true
        liveBoxes[key] = nil
        continue
      }
      let drawn = shape.draw(at: now)
      liveShapes[key] = shape
      guard let box = screenBounds(drawn, toCamera: eye.toCamera) else {
        node.isHidden = true
        liveBoxes[key] = nil
        continue
      }
      let focused = pin?.label.emphasis == .focused
      let strong = focused || shape.pinned
      let color: UIColor = shape.pinned ? (pin?.label.color ?? accent) : focused ? accent : .white
      node.style(color, width: strong ? 2.5 : 1.5, stroke: strong ? 1 : 0.75, fill: focused ? 0.14 : shape.pinned ? 0.1 : 0.07)
      node.setOutline(drawn, eye: eye)
      node.isHidden = false
      liveBoxes[key] = box
    }
  }

  /// How the camera view sees the world now, for drawing outlines in it (OutlineNode); nil
  /// before the first frame.
  private func outlineEye() -> OutlineEye? {
    guard bounds.width > 0, let camera = sceneView.session.currentFrame?.camera else { return nil }
    // The camera image fills the view (aspect fill), upright: its pixels to the view's points.
    let res = camera.imageResolution
    let scale = max(bounds.width / res.height, bounds.height / res.width)
    return OutlineEye(transform: camera.transform, pointsPerMetre: camera.intrinsics[0][0] * Float(scale), zoom: Float(zoom))
  }

  /// Where world points are on screen, as the box around them; nil when any is behind the phone.
  private func screenBounds(_ world: [simd_float3], toCamera: simd_float4x4) -> CGRect? {
    var x0 = CGFloat.greatestFiniteMagnitude, y0 = CGFloat.greatestFiniteMagnitude
    var x1 = -CGFloat.greatestFiniteMagnitude, y1 = -CGFloat.greatestFiniteMagnitude
    for w in world {
      guard simd_mul(toCamera, simd_float4(w, 1)).z < -0.02 else { return nil }
      let q = sceneView.projectPoint(SCNVector3(w.x, w.y, w.z))
      let v = zoomed(CGPoint(x: CGFloat(q.x), y: CGFloat(q.y)))
      x0 = min(x0, v.x); y0 = min(y0, v.y); x1 = max(x1, v.x); y1 = max(y1, v.y)
    }
    return world.isEmpty ? nil : CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  /// Not re-cut for this long (seconds), an outline is let go even if nothing said it's wrong.
  private static let liveStale: CFTimeInterval = 4

  /// How fast the phone itself is turning and moving (`phoneTurn`, `phoneMove`), from ARKit's
  /// poses one frame to the next.
  private func trackPhone(_ frame: ARFrame) {
    let m = frame.camera.transform
    defer { lastPhonePose = (transform: m, t: frame.timestamp) }
    guard let last = lastPhonePose else { return }
    let dt = Float(frame.timestamp - last.t)
    guard dt > 0.001, dt < 0.5 else { return }
    let a = last.transform
    let r = simd_float3x3(simd_make_float3(a.columns.0), simd_make_float3(a.columns.1), simd_make_float3(a.columns.2)).transpose
      * simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
    let turned = acos(min(max((r[0][0] + r[1][1] + r[2][2] - 1) / 2, -1), 1))
    let moved = simd_distance(simd_make_float3(a.columns.3), simd_make_float3(m.columns.3))
    phoneTurn = phoneTurn * 0.6 + turned / dt * 0.4
    phoneMove = phoneMove * 0.6 + moved / dt * 0.4
  }

  /// Live outlines off (or the camera paused under a capture): what SAM was keeping up goes,
  /// but a pinned thing stays pinned (drawn where it was, followed again once they're back on).
  private func clearLiveOutlines() {
    for key in Array(liveShapes.keys) where liveShapes[key]?.pinned != true {
      liveShapes[key] = nil
    }
    for (key, node) in liveLayers where liveShapes[key] == nil {
      node.removeFromParentNode()
      liveLayers[key] = nil
      liveBoxes[key] = nil
    }
  }

  /// A live outline is being kept up for this pin, so its frozen one steps aside (never both:
  /// `layoutLive` drops a live one that's lost or stale, and the frozen one comes back).
  private func hasLiveOutline(_ pin: Pin) -> Bool {
    liveShapes[pin.id] != nil
  }

  // MARK: - Zoom

  func setZoom(_ requested: Double) {
    guard requested.isFinite else { return }
    var z = min(max(CGFloat(requested), hasUltraWide ? 0.5 : 1), Self.maxZoom)
    // A recording keeps the camera it started on (its frames are that camera's size).
    if recorder != nil, ultraWideFormat == nil { z = wideMode ? min(z, 0.99) : max(z, 1) }
    zoomFactor = z
    let ultra = z < 1
    if ultraWideFormat != nil {
      if ultra != onUltraWide { useUltraWide(ultra) }
    } else if ultra != wideMode {
      setWideMode(ultra)
    }
    // The ultra-wide sees twice as wide: 0.5 is its whole picture, 0.7 a 1.4x crop.
    zoom = ultra ? z / 0.5 : z
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    sceneView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
    wide?.preview.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
    CATransaction.commit()
    layoutPins()
  }

  /// Into or out of 0.5x on the ultra-wide camera on its own (ARKit has no ultra-wide format
  /// here): ARKit pauses, keeping its world, and resumes with it (pins and all) at 1x.
  private func setWideMode(_ on: Bool) {
    wideMode = on
    if on {
      let camera = wide ?? UltraWideCamera()
      if wide == nil {
        wide = camera
        camera.preview.bounds = CGRect(origin: .zero, size: bounds.size)
        camera.preview.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.insertSublayer(camera.preview, above: sceneView.layer)
        camera.onFrame = { [weak self] buffer, t in
          DispatchQueue.main.async {
            self?.wideFrame(buffer, at: t)
            self?.wideFlow(buffer, at: t)
          }
        }
      }
      wideSession += 1
      let follower = wideFollower
      wideFlowQueue.async { follower.reset() }
      sceneView.session.pause()
      sceneView.isHidden = true
      camera.preview.isHidden = false
      if running { camera.start() }
    } else {
      for (_, l) in wideLayers { l.removeFromSuperlayer() }
      wideLayers = [:]
      // ARKit was paused: where pinned things were may not be where its world puts them now.
      returning = Set(pinOrder.filter { liveShapes[$0]?.pinned == true })
      wideScrubLayer?.removeFromSuperlayer()
      wideScrubLayer = nil
      wideScrubFrame = nil
      wideOutlines = [:]
      wideTimes = [:]
      let follower = wideFollower
      wideFlowQueue.async { follower.reset() }
      // Pinned things' tags go back to SceneKit, with their outlines.
      for (_, pin) in pins where pin.tagNode != nil { pin.label.drawnElsewhere = true }
      // ARKit once the ultra-wide has let go of the camera.
      let camera = wide
      camera?.stop { [weak self] in
        guard let self, !self.wideMode else { return }
        camera?.preview.isHidden = true
        self.sceneView.isHidden = false
        if self.running, let config = self.configuration { self.sceneView.session.run(config) }
      }
      if camera == nil {
        sceneView.isHidden = false
        if running, let config = configuration { sceneView.session.run(config) }
      }
    }
  }

  /// A frame from the ultra-wide (0.5x without ARKit): EdgeTAM takes every pinned thing it's
  /// following one step further on it, as often as it keeps up, and each outline it finds is
  /// glided into what was shown on this frame and brought on to the newest (FlatFollower), for
  /// drawing (`layoutWide`).
  private func wideFrame(_ buffer: CVPixelBuffer, at t: CFTimeInterval) {
    guard wideMode, liveSegments, !samBusy, !scrubBusy, let edge = edgeTAM, t - lastWideTime > 0.05 else { return }
    let held = pinOrder.filter { liveShapes[$0]?.pinned == true || flatPins.contains($0) }
    guard !held.isEmpty else { return }
    samBusy = true
    lastWideTime = t
    let session = wideSession
    let follower = wideFollower
    // The frames from this one on are kept until its answer is in.
    wideFlowQueue.async { follower.looking(at: t) }
    let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer)) // upright
    samQueue.async { [weak self] in
      guard let self else { return }
      var found: [String: [CGPoint]] = [:]
      var asked: [String] = []
      do {
        let stepped = try self.followWide(held, models: edge, buffer: buffer)
        found = stepped.found
        asked = stepped.asked
      } catch {
        NSLog("[lensi] EdgeTAM on the ultra-wide failed: %@", error.localizedDescription)
      }
      DispatchQueue.main.async {
        self.samBusy = false
        guard self.wideMode, session == self.wideSession else { return }
        self.wideSize = size
        // Each thing EdgeTAM was asked about: where it is, or nil where it isn't in view (no
        // outline: it's drawn again once EdgeTAM finds it).
        var answers: [String: [CGPoint]?] = [:]
        for key in asked { answers.updateValue(found[key].map { OutlineMath.resample($0, scale: size) }, forKey: key) }
        let keep = Set(self.pinOrder.filter { self.liveShapes[$0]?.pinned == true || self.flatPins.contains($0) })
        self.wideFlowQueue.async { [weak self] in
          follower.keep(keep)
          follower.answer(answers.filter { keep.contains($0.key) }, at: t, size: size)
          self?.showWide(follower, session: session)
        }
      }
      self.rememberEdge()
    }
  }

  /// Every ultra-wide frame while something's pinned (on `wideFlowQueue`, skipping frames while it's
  /// behind): a small grey copy for the flow, and every outline bent on to it (FlatFollower).
  private func wideFlow(_ buffer: CVPixelBuffer, at t: CFTimeInterval) {
    guard wideMode, liveSegments, !wideFlowBusy, let camera = wide else { return }
    let keep = Set(pinOrder.filter { liveShapes[$0]?.pinned == true || flatPins.contains($0) })
    guard !keep.isEmpty else { return }
    wideFlowBusy = true
    let session = wideSession
    let follower = wideFollower
    let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer)) // upright
    wideFlowQueue.async { [weak self] in
      guard let self else { return }
      // Where the flow can't say, by how the phone turned (and while it turns fast, if
      // `wideGyroWhenFast`: the picture's a blur).
      follower.turn = { points, a, b in camera.warp(points, from: a, to: b, size: size) }
      if Self.wideGyroWhenFast {
        follower.gyroFirst = { a, b in b > a && simd_length(camera.turned(from: a, to: b)) / Float(b - a) > LiveShape.fastTurn }
      } else {
        follower.gyroFirst = nil
      }
      let upright = CIImage(cvPixelBuffer: buffer).oriented(.right)
      let scale = CGFloat(LiveFlow.width) / max(upright.extent.width, 1)
      let small = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      follower.keep(keep)
      follower.add(self.wideFlowContext.createCGImage(small, from: small.extent).flatMap { LiveFlow.frame($0) }, at: t)
      self.showWide(follower, session: session)
      DispatchQueue.main.async { self.wideFlowBusy = false }
    }
  }

  /// Whether the gyro rather than the flow moves 0.5x outlines while the phone turns fast.
  static let wideGyroWhenFast = false

  /// What `follower` says (on `wideFlowQueue`) is where each pinned thing is on the ultra-wide's
  /// picture, as of which frame: drawn from then on (`layoutWide`), unless 0.5x has ended since.
  private func showWide(_ follower: FlatFollower, session: Int) {
    let said = follower.things
    DispatchQueue.main.async { [weak self] in
      guard let self, self.wideMode, session == self.wideSession else { return }
      self.wideOutlines = said.mapValues { $0.shown }
      self.wideTimes = said.mapValues { $0.at }
    }
  }

  /// EdgeTAM's step for each pinned thing on an ultra-wide frame (on `samQueue`): its outline
  /// (upright 0…1) where it's in view, and which things it stepped. Only things it was already
  /// following: without ARKit there's no knowing where anything else is in this picture.
  private func followWide(_ keys: [String], models: EdgeTAMTracker.Models,
                          buffer: CVPixelBuffer) throws -> (found: [String: [CGPoint]], asked: [String]) {
    let following = keys.filter { edgeTrackers[$0]?.started == true }
    guard !following.isEmpty else { return ([:], []) }
    let encoder = try edgeEncoder ?? EdgeTAMTracker.Encoder(models: models)
    edgeEncoder = encoder
    let picture = try encoder.encode(CIImage(cvPixelBuffer: buffer).oriented(.right))
    var found: [String: [CGPoint]] = [:]
    var asked: [String] = []
    for key in following {
      guard let tracker = edgeTrackers[key] else { continue }
      let cut = try tracker.step(picture)
      asked.append(key)
      if cut.visible { found[key] = cut.outline }
    }
    return (found, asked)
  }

  /// Every display frame at 0.5x without ARKit: each pinned thing's outline flat over the
  /// ultra-wide's picture, its tag just above it, and the strip's highlighted thing.
  private func layoutWide() {
    layoutWideScrub()
    guard let wide else { return }
    let held = Set(pinOrder.filter { liveShapes[$0]?.pinned == true || flatPins.contains($0) })
    for (key, l) in wideLayers where !held.contains(key) {
      l.removeFromSuperlayer()
      wideLayers[key] = nil
    }
    let visible = bounds.inset(by: pinInsets)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for id in pinOrder {
      guard let pin = pins[id] else { continue }
      guard held.contains(id), let outline = wideOutlines[id], outline.count >= 3 else {
        wideLayers[id]?.isHidden = true
        pin.setHidden(true)
        continue
      }
      let flat: FlatOutline
      if let existing = wideLayers[id] {
        flat = existing
      } else {
        flat = FlatOutline()
        layer.insertSublayer(flat, above: wide.preview)
        wideLayers[id] = flat
      }
      flat.frame = bounds
      // Where it is on the picture now: moved on from its frame by how the phone has turned since.
      let now = wide.latest?.t ?? CACurrentMediaTime()
      let moved = wide.warp(outline, from: wideTimes[id] ?? now, to: now, size: wideSize)
      let points = moved.map { zoomed(wide.layerPoint($0)) }
      let path = OutlineMath.curvePath(points)
      flat.draw(path, color: pin.label.color.cgColor, width: 2.5, fillOpacity: 0.1)
      flat.isHidden = false
      // Its tag just above it, as at 1x.
      let box = path.boundingBox
      pin.label.drawnElsewhere = false
      pin.setHidden(false)
      pin.tagNode?.isHidden = true
      let half = pin.label.bounds.width / 2 + 8
      let h = pin.label.bounds.height / 2
      pin.label.center = CGPoint(x: min(max(box.midX, half), bounds.width - half),
                                 y: min(max(box.minY - h - 6, visible.minY + h), max(visible.minY + h, visible.maxY - h)))
    }
  }

  /// The strip's highlighted thing at 0.5x, bold in the lens colour, moved on from the frame it
  /// was found in by how the phone has turned since (a pinned one is drawn as its pin).
  private func layoutWideScrub() {
    guard wideMode, let wide, let found = wideScrubFrame, let i = scrubIndex, scrubThings.indices.contains(i),
          scrubThings[i].pinId == nil, let flat = scrubThings[i].flat else {
      wideScrubLayer?.isHidden = true
      return
    }
    let highlight: FlatOutline
    if let existing = wideScrubLayer {
      highlight = existing
    } else {
      highlight = FlatOutline()
      layer.insertSublayer(highlight, above: wide.preview)
      wideScrubLayer = highlight
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    highlight.frame = bounds
    let now = wide.latest?.t ?? CACurrentMediaTime()
    let moved = wide.warp(flat, from: found.t, to: now, size: wideSize)
    highlight.draw(OutlineMath.curvePath(moved.map { zoomed(wide.layerPoint($0)) }), color: accent.cgColor, width: 2.5, fillOpacity: 0.16)
    highlight.isHidden = false
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
    trackPhone(frame)
    if guideWatchId != nil { watchGuide(frame) }
    segmentLive(frame)
    flowLive(frame)
    // Not while a finger is on the strip: the things it offers were found when it landed, and
    // the Neural Engine and GPU are better spent keeping the camera and the outlines smooth.
    guard showDetections, scrubThings.isEmpty, !scrubBusy, !visionBusy, frame.timestamp - lastVisionTime > 0.066 else { return }
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
    // No name follows the reticle: what the camera is "on" would change every time the phone
    // moved. Things are named once they're pinned.
    focusTag.isHidden = true
    CATransaction.commit()

    if newFocus?.label != focusedLabel {
      focusedLabel = newFocus?.label
      onFocusChange(["label": focusedLabel as Any])
    }
    focusedId = newFocus?.id

    // At 0.5x without ARKit there's no world to draw in: pinned things are drawn flat.
    if wideMode {
      layoutWide()
      return
    }
    // Outlines first: a pinned thing's tag sits above where its outline is drawn.
    layoutLive()
    layoutPins()
    layoutScrub()
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
    if wideMode {
      layoutWide()
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    // Where a tag can be read: clear of the app's own panel and top bar.
    let visible = bounds.inset(by: pinInsets)
    for id in pinOrder {
      guard let pin = pins[id] else { continue }
      // Pinned at 0.5x and not yet in the world.
      if flatPins.contains(id) {
        pin.setHidden(true)
        continue
      }
      // A guide tag rides with its part when the part moves, and a pinned thing's with the
      // thing (their live outlines say where).
      let held = liveShapes[id]?.pinned == true
      let anchor = pin.parentId == Self.guideParent || held ? tagWorld(pin) : pin.world
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
      // A pinned thing's tag sits just above its outline: it names the thing without covering it.
      if held, let box = liveBoxes[id] {
        let h = pin.label.bounds.height / 2
        let top = box.minY - h - 6
        pin.label.center = CGPoint(x: min(max(box.midX, half), bounds.width - half),
                                   y: min(max(top, visible.minY + h), max(visible.minY + h, visible.maxY - h)))
        placeTag(pin)
        continue
      }
      // Its outline isn't drawn (out of view): nor is its tag.
      if held { pin.tagNode?.isHidden = true }
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

  /// A pinned thing's tag as SceneKit draws it (TagNode), where its UIKit copy is on screen: in
  /// the world at the depth of its outline, so it's drawn with the outline in the camera's frame.
  private func placeTag(_ pin: Pin) {
    guard let tag = pin.tagNode else { return }
    guard let eye = outlineEye(), let shape = liveShapes[pin.id] else {
      tag.isHidden = true
      return
    }
    let middle = OutlineMath.centre(shape.drawn ?? shape.world)
    let depth = sceneView.projectPoint(SCNVector3(middle.x, middle.y, middle.z)).z
    let at = unzoomed(pin.label.center)
    let w = sceneView.unprojectPoint(SCNVector3(Float(at.x), Float(at.y), depth))
    tag.show(pin.label)
    tag.place(at: simd_float3(w.x, w.y, w.z), eye: eye)
    tag.isHidden = false
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
    // Otherwise a tap on the camera does nothing: things are picked on the strip.
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
    let selection = FrozenCamera(frame: frame, crop: crop)
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

  // MARK: - The strip: slide to pick, hold to pin
  //
  // A finger landing on the strip asks for the things in view: SAM's part proposals on the
  // frame on screen, and YOLO's whole objects cut from their boxes, each laid in the world on
  // a plane through it at the depth under its middle. Sliding moves the highlight from one to
  // the next in the order they were across the screen, and holding still pins the highlighted
  // one (JS times the hold). They're fixed in the world when the finger lands, so moving the
  // phone never changes which one is highlighted; a pinned one is then followed like a guide
  // part, and never let go.

  private struct ScrubThing {
    /// OutlineMath.count points in the world, on a plane through it facing the camera.
    let world: [simd_float3]
    /// YOLO's name for it, when it's one of YOLO's things.
    let label: String?
    let confidence: Float
    /// Laid where LiDAR or ARKit's points put it, rather than where a raycast guessed.
    let depthKnown: Bool
    /// Its pin once it's pinned (holding on it again does nothing).
    var pinId: String?
    /// At 0.5x: its outline on the ultra-wide's picture (upright 0…1), and no world.
    var flat: [CGPoint]? = nil
  }

  /// The strip's highlighted thing, the only one drawn while a finger is on it.
  private var scrubNode: OutlineNode?

  /// One thing found in the picture (upright 0…1).
  private struct ScrubFind {
    let polygon: [CGPoint]
    let label: String?
    let confidence: Float
  }

  /// The things in view, between `top` and `bottom` on screen (points: clear of the app's
  /// chrome). Answers each one's name (or none) and where its middle is on screen (0…1), left
  /// to right; none when there's no frame or nothing found.
  func scrubStart(top: Double, bottom: Double, done: @escaping ([[String: Any]]) -> Void) {
    scrubEnd()
    let session = scrubSession
    guard bounds.width > 0 else {
      done([])
      return
    }
    // At 0.5x without ARKit: things on the ultra-wide's picture.
    if wideMode {
      scrubStartWide(top: top, bottom: bottom, session: session, done: done)
      return
    }
    guard let frame = sceneView.session.currentFrame else {
      done([])
      return
    }
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let lo = CGFloat(max(0, top))
    let hi = min(bounds.height, CGFloat(bottom))
    let region = viewRectToUpright(CGRect(x: 0, y: lo, width: bounds.width, height: max(1, hi - lo)), frame: frame).intersection(unit)
    guard !region.isNull, region.width > 0.05, region.height > 0.05 else {
      done([])
      return
    }
    // YOLO's things in view: whole objects, with names.
    let objects: [ScrubFind] = tracked.compactMap { (t: Tracked) -> ScrubFind? in
      guard t.missed == 0 else { return nil }
      let b = viewRectToUpright(t.shown, frame: frame).intersection(region)
      guard !b.isNull, b.width > 0.03, b.height > 0.03 else { return nil }
      return ScrubFind(polygon: [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                                 CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)],
                       label: t.label, confidence: t.confidence)
    }
    let camera = FrozenCamera(frame: frame, crop: unit)
    let points = frame.rawFeaturePoints?.points ?? []
    let measured = DepthSample(frame)
    let res = frame.camera.imageResolution
    let upright = CGSize(width: res.height, height: res.width)
    guard let sam else {
      // No SAM on this phone: YOLO's boxes are the things.
      done(scrubLay(objects, camera: camera, points: points, depth: measured, upright: upright))
      return
    }
    let buffer = frame.capturedImage
    scrubBusy = true
    samQueue.async { [weak self] in
      let started = CACurrentMediaTime()
      var found: [ScrubFind] = []
      do {
        try sam.prepare(pixelBuffer: buffer, orientation: .right, id: "scrub")
        for o in objects.prefix(4) {
          let b = LiveTracker.bounds(o.polygon)
          let m = try sam.segment(id: "scrub", points: [], labels: [], box: b)
          if m.score >= 0.6, m.polygon.count > 2 { found.append(ScrubFind(polygon: m.polygon, label: o.label, confidence: o.confidence)) }
        }
        let parts = try sam.proposeParts(id: "scrub", region: region, grid: 6, maxParts: 12,
                                         minArea: 0.002, maxArea: 0.3, minScore: 0.8, budget: 0.6)
        found += parts.map { ScrubFind(polygon: $0.polygon, label: nil, confidence: 0) }
      } catch {
        NSLog("[lensi] strip: SAM failed: %@", error.localizedDescription)
      }
      let ms = (CACurrentMediaTime() - started) * 1000
      DispatchQueue.main.async {
        guard let self else { return }
        self.scrubBusy = false
        guard session == self.scrubSession else {
          done([])
          return
        }
        let things = self.scrubLay(found, camera: camera, points: points, depth: measured, upright: upright)
        NSLog("[lensi] strip: %ld things in view (%ld found) in %.0f ms", things.count, found.count, ms)
        done(things)
      }
    }
  }

  /// The strip's finds laid in the world, the same thing found twice kept once, in order across
  /// the screen; each gets a layer (drawn by `layoutScrub`).
  private func scrubLay(_ found: [ScrubFind], camera: FrozenCamera, points: [simd_float3], depth: DepthSample?,
                        upright: CGSize) -> [[String: Any]] {
    let look = GuideFrameContext(selection: camera, points: points)
    var kept: [ScrubFind] = []
    for f in found where !kept.contains(where: { LiveTracker.iou($0.polygon, f.polygon) > 0.6 }) {
      kept.append(f)
    }
    var laid: [(world: [simd_float3], find: ScrubFind, at: CGPoint, depthKnown: Bool)] = []
    for f in kept {
      let ring = OutlineMath.resample(f.polygon, scale: upright)
      let middle = LiveTracker.interiorPoint(f.polygon, scale: upright)
      // How far it is: LiDAR's depth inside it, else ARKit's points on it, else a raycast through
      // its middle (which can hit the wall behind it: LiveShape puts that right as it's followed).
      let anchor: simd_float3
      let measured = depth?.inside(ring) ?? camera.medianDepth(of: points, inside: ring)
      if let d = measured {
        let (origin, dir) = camera.ray(middle)
        anchor = origin + dir * camera.range(depth: d, through: middle)
      } else {
        anchor = look.anchor(at: middle, session: sceneView.session)
      }
      let plane = camera.withPlane(through: anchor)
      let world = ring.compactMap { plane.onPlane($0) }
      guard world.count == ring.count, let (p, _) = project(OutlineMath.centre(world)), bounds.contains(p) else { continue }
      laid.append((world: world, find: f, at: p, depthKnown: measured != nil))
    }
    // Left to right as they are on screen.
    laid.sort { ($0.at.x, $0.at.y) < ($1.at.x, $1.at.y) }
    laid = Array(laid.prefix(14))
    scrubThings = laid.map { l in
      ScrubThing(world: l.world, label: l.find.label, confidence: l.find.confidence, depthKnown: l.depthKnown, pinId: nil)
    }
    scrubIndex = nil
    scrubNode?.removeFromParentNode()
    let node = OutlineNode()
    node.isHidden = true
    outlines.addChildNode(node)
    scrubNode = node
    layoutScrub()
    return laid.map { l in
      let name: Any = l.find.label.map { $0 as Any } ?? NSNull()
      return ["label": name, "x": Double(l.at.x / bounds.width), "y": Double(l.at.y / bounds.height)]
    }
  }

  /// The highlighted thing (out of range: none).
  func scrubTo(_ index: Int) {
    scrubIndex = scrubThings.indices.contains(index) ? index : nil
    layoutScrub()
  }

  /// Pins thing `index`: a tag, an outline SAM keeps on it from now on, and its picture to JS
  /// (onSelect) to be named, as a tap's was. Answers its pin's id.
  func scrubPin(_ index: Int) -> String? {
    guard scrubThings.indices.contains(index) else { return nil }
    if let id = scrubThings[index].pinId { return id }
    if scrubThings[index].flat != nil { return scrubPinWide(index) }
    guard let frame = sceneView.session.currentFrame else { return nil }
    let thing = scrubThings[index]
    let id = UUID().uuidString
    let centre = OutlineMath.centre(thing.world)
    // Where it is in the picture now (the phone may have moved since the finger landed): the
    // crop that names it, and where callouts in that crop land.
    let res = frame.camera.imageResolution
    let upright = CGSize(width: res.height, height: res.width)
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    var crop = uprightPoints(thing.world, camera: frame.camera, upright: upright).map { bounding($0) } ?? unit
    crop = crop.insetBy(dx: -crop.width * 0.15, dy: -crop.height * 0.15).intersection(unit)
    if crop.isNull || crop.width < 0.02 || crop.height < 0.02 { crop = unit }
    contexts[id] = FrozenCamera(frame: frame, crop: crop).withPlane(through: centre)
    var shape = LiveShape(world: thing.world, at: frame.timestamp, follows: true)
    shape.pinned = true
    shape.depthKnown = thing.depthKnown
    shape.tagOffset = .zero
    liveShapes[id] = shape
    let node = OutlineNode()
    node.isHidden = true
    outlines.addChildNode(node)
    liveLayers[id] = node
    // Its tag is drawn by SceneKit with its outline, so the two move as one (TagNode).
    let pin = Pin(id: id, parentId: nil, world: centre, text: thing.label ?? "Looking", color: accent)
    pin.label.drawnElsewhere = true
    let tag = TagNode()
    tag.isHidden = true
    outlines.addChildNode(tag)
    pin.tagNode = tag
    addPin(pin)
    scrubThings[index].pinId = id
    // Drawn as its pin from now on.
    layoutScrub()
    layoutLive()
    layoutPins()
    let buffer = frame.capturedImage
    let label = thing.label
    let confidence = thing.confidence
    visionQueue.async { [weak self] in
      guard let self else { return }
      let jpeg = self.detector.jpeg(buffer, crop: crop)
      DispatchQueue.main.async {
        self.onSelect(["id": id, "label": label as Any, "confidence": confidence, "image": jpeg?.base64EncodedString() ?? ""])
      }
    }
    return id
  }

  /// The finger left the strip: the highlighted thing fades (a pinned one stays, as its pin).
  func scrubEnd() {
    scrubSession += 1
    scrubNode?.retire()
    scrubNode = nil
    scrubThings = []
    scrubIndex = nil
    wideScrubLayer?.isHidden = true
    wideScrubFrame = nil
  }

  /// The strip at 0.5x without ARKit: SAM's parts on the ultra-wide's picture, between `top` and
  /// `bottom` on screen, outlines on that picture (there's no world to lay them in), in order
  /// across the screen. Pinned, one is followed there by EdgeTAM (`scrubPinWide`).
  private func scrubStartWide(top: Double, bottom: Double, session: Int, done: @escaping ([[String: Any]]) -> Void) {
    guard let wide, let latest = wide.latest, let sam else {
      done([])
      return
    }
    let buffer = latest.buffer
    let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer)) // upright
    let lo = CGFloat(max(0, top))
    let hi = max(lo + 1, min(bounds.height, CGFloat(bottom)))
    let a = wide.uprightPoint(unzoomed(CGPoint(x: 0, y: lo)))
    let b = wide.uprightPoint(unzoomed(CGPoint(x: bounds.width, y: hi)))
    let region = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !region.isNull, region.width > 0.05, region.height > 0.05 else {
      done([])
      return
    }
    scrubBusy = true
    samQueue.async { [weak self] in
      let started = CACurrentMediaTime()
      var found: [[CGPoint]] = []
      do {
        try sam.prepare(pixelBuffer: buffer, orientation: .right, id: "scrub")
        let parts = try sam.proposeParts(id: "scrub", region: region, grid: 6, maxParts: 12,
                                         minArea: 0.002, maxArea: 0.3, minScore: 0.8, budget: 0.6)
        found = parts.map(\.polygon)
      } catch {
        NSLog("[lensi] strip at 0.5x: SAM failed: %@", error.localizedDescription)
      }
      let ms = (CACurrentMediaTime() - started) * 1000
      DispatchQueue.main.async {
        guard let self else { return }
        self.scrubBusy = false
        guard session == self.scrubSession, self.wideMode, let wide = self.wide else {
          done([])
          return
        }
        var kept: [[CGPoint]] = []
        for f in found where !kept.contains(where: { LiveTracker.iou($0, f) > 0.6 }) {
          kept.append(f)
        }
        var laid: [(flat: [CGPoint], at: CGPoint)] = []
        for f in kept {
          let at = self.zoomed(wide.layerPoint(LiveTracker.interiorPoint(f, scale: size)))
          guard self.bounds.contains(at) else { continue }
          laid.append((flat: OutlineMath.resample(f, scale: size), at: at))
        }
        laid.sort { ($0.at.x, $0.at.y) < ($1.at.x, $1.at.y) }
        laid = Array(laid.prefix(14))
        self.scrubThings = laid.map {
          ScrubThing(world: [], label: nil, confidence: 0, depthKnown: false, pinId: nil, flat: $0.flat)
        }
        self.scrubIndex = nil
        self.wideScrubFrame = (buffer: buffer, t: latest.t)
        self.wideSize = size
        NSLog("[lensi] strip at 0.5x: %ld things in view (%ld found) in %.0f ms", laid.count, found.count, ms)
        let width = self.bounds.width, height = self.bounds.height
        done(laid.map { l -> [String: Any] in
          ["label": NSNull(), "x": Double(l.at.x / width), "y": Double(l.at.y / height)]
        })
      }
    }
  }

  /// Pins thing `index` at 0.5x: a tag, and EdgeTAM started on it from the frame it was found in,
  /// following it on the ultra-wide (`wideFrame`); it's laid in the world from its first cut
  /// once ARKit is back at 1x. Its picture goes to JS (onSelect) to be named, as at 1x.
  private func scrubPinWide(_ index: Int) -> String? {
    // Without EdgeTAM (still loading, or missing) nothing could follow it here.
    guard let edge = edgeTAM, let flat = scrubThings[index].flat, let found = wideScrubFrame else { return nil }
    let id = UUID().uuidString
    let pin = Pin(id: id, parentId: nil, world: .zero, text: "Looking", color: accent)
    let tag = TagNode()
    tag.isHidden = true
    outlines.addChildNode(tag)
    pin.tagNode = tag
    addPin(pin)
    flatPins.insert(id)
    scrubThings[index].pinId = id
    // Followed from the frame it was found in (a second or so ago), brought on to the newest.
    let follower = wideFollower
    let session = wideSession
    wideFlowQueue.async { [weak self] in
      follower.place(id, flat, at: found.t)
      self?.showWide(follower, session: session)
    }
    // EdgeTAM starts on it on samQueue, where its trackers live; if it can't, it's unpinned
    // rather than left with nothing to follow it.
    let box = LiveTracker.bounds(flat)
    let start = found.buffer
    samQueue.async { [weak self] in
      guard let self else { return }
      do {
        let encoder = try self.edgeEncoder ?? EdgeTAMTracker.Encoder(models: edge)
        self.edgeEncoder = encoder
        let tracker = try EdgeTAMTracker(models: edge)
        _ = try tracker.start(encoder.encode(CIImage(cvPixelBuffer: start).oriented(.right)), box: box)
        self.edgeTrackers[id] = tracker
      } catch {
        NSLog("[lensi] EdgeTAM couldn't start on a thing pinned at 0.5x: %@", error.localizedDescription)
        DispatchQueue.main.async { self.removePin(id: id) }
      }
    }
    layoutWide()
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let r = LiveTracker.bounds(flat)
    var crop = r.insetBy(dx: -r.width * 0.15, dy: -r.height * 0.15).intersection(unit)
    if crop.isNull || crop.width < 0.02 || crop.height < 0.02 { crop = unit }
    let buffer = found.buffer
    visionQueue.async { [weak self] in
      guard let self else { return }
      let jpeg = self.detector.jpeg(buffer, crop: crop)
      DispatchQueue.main.async {
        self.onSelect(["id": id, "label": NSNull(), "confidence": 0, "image": jpeg?.base64EncodedString() ?? ""])
      }
    }
    return id
  }

  /// Unpins every pinned thing, and whatever the brain added to it.
  func scrubClear() {
    for id in pinOrder where pins[id]?.parentId == nil { removePin(id: id) }
  }

  /// The strip's highlighted thing where it is now, bold in the lens colour; nothing else is
  /// drawn (the strip's ticks say how many there are). A pinned one is drawn as its pin instead.
  private func layoutScrub() {
    if wideMode {
      layoutWideScrub()
      return
    }
    guard let node = scrubNode else { return }
    guard let i = scrubIndex, scrubThings.indices.contains(i), scrubThings[i].pinId == nil,
          let eye = outlineEye(), screenBounds(scrubThings[i].world, toCamera: eye.toCamera) != nil else {
      node.isHidden = true
      return
    }
    node.style(accent, width: 2.5, stroke: 1, fill: 0.16)
    node.setOutline(scrubThings[i].world, eye: eye)
    node.isHidden = false
  }

  // MARK: - Photo, video, torch

  /// Full-resolution still (when the format allows it), written upright as JPEG.
  func takePhoto(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    if wideMode {
      guard let buffer = wide?.latest?.buffer else {
        done(.failure(LensiError.unavailable("The camera isn't ready yet.")))
        return
      }
      visionQueue.async {
        let result = self.writePhoto(buffer, maxSide: 3024)
        DispatchQueue.main.async { done(result) }
      }
      return
    }
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
    guard !wideMode else {
      done(LensiError.unavailable("Video records at 1x and up."))
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
    // On a thing pinned at 0.5x and not yet in the world: placed with it.
    if flatPins.contains(parentId), pins[parentId] != nil, pins[id] == nil {
      flatCallouts[parentId, default: []].append((id: id, x: x, y: y, text: text))
      return
    }
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
      flatPins.remove(pid)
      flatCallouts[pid] = nil
      returning.remove(pid)
    }
    pinOrder.removeAll { pins[$0] == nil }
  }

  func clearPins() {
    pins.values.forEach { $0.removeFromSuperview() }
    pins.removeAll()
    pinOrder.removeAll()
    contexts.removeAll()
    flatPins.removeAll()
    flatCallouts.removeAll()
    returning.removeAll()
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
      selection: FrozenCamera(frame: frame, crop: crop),
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
      let shape = OutlineNode()
      shape.isHidden = true
      outlines.addChildNode(shape)
      pin.guideShape = shape
    }
    layoutPins()
  }

  /// A part's outline where it is now: the current step's in the lens colour,
  /// the rest thin and white; none while any corner is behind the phone.
  private func drawGuideOutline(_ pin: Pin) {
    guard let shape = pin.guideShape else { return }
    guard pin.label.pointing == nil, !pin.label.isHidden, !hasLiveOutline(pin), let eye = outlineEye(),
          pin.guideOutline.allSatisfy({ simd_mul(eye.toCamera, simd_float4($0, 1)).z < -0.02 }) else {
      shape.isHidden = true
      return
    }
    let focused = pin.label.emphasis == .focused
    shape.style(focused ? accent : .white, width: focused ? 2.5 : 1.5, stroke: focused ? 1 : 0.75, fill: focused ? 0.14 : 0.06)
    shape.setOutline(pin.guideOutline, eye: eye)
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

/// LiDAR's depth with one frame (ARFrame.smoothedSceneDepth: metres, lying on its side as the
/// camera image does, at a fraction of its size) and how sure of it LiDAR is.
private struct DepthSample {
  let depth: CVPixelBuffer
  let confidence: CVPixelBuffer?

  /// Nil on a phone without LiDAR.
  init?(_ frame: ARFrame) {
    guard let d = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
    depth = d.depthMap
    confidence = d.confidenceMap
  }

  /// The median depth inside an upright outline (LiveShape.depthInside), leaving out what LiDAR
  /// isn't sure of; nil when too little of it has a depth.
  func inside(_ ring: [CGPoint]) -> Float? {
    guard CVPixelBufferGetPixelFormatType(depth) == kCVPixelFormatType_DepthFloat32 else { return nil }
    CVPixelBufferLockBaseAddress(depth, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depth, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(depth) else { return nil }
    let w = CVPixelBufferGetWidth(depth), h = CVPixelBufferGetHeight(depth)
    let row = CVPixelBufferGetBytesPerRow(depth)
    var sure: UnsafeMutableRawPointer?
    var sureRow = 0
    if let confidence {
      CVPixelBufferLockBaseAddress(confidence, .readOnly)
      sure = CVPixelBufferGetBaseAddress(confidence)
      sureRow = CVPixelBufferGetBytesPerRow(confidence)
    }
    defer { if let confidence { CVPixelBufferUnlockBaseAddress(confidence, .readOnly) } }
    let medium = UInt8(ARConfidenceLevel.medium.rawValue)
    return LiveShape.depthInside(ring) { p in
      let s = FrozenCamera.sensor(p)
      let x = min(max(Int(s.x * CGFloat(w)), 0), w - 1)
      let y = min(max(Int(s.y * CGFloat(h)), 0), h - 1)
      if let sure, sure.load(fromByteOffset: y * sureRow + x, as: UInt8.self) < medium { return nil }
      return base.load(fromByteOffset: y * row + x * 4, as: Float32.self)
    }
  }
}

/// A guide frame: its frozen pose plus the feature points ARKit had tracked,
/// which give a depth when a raycast finds no surface (a pipe in mid-air).
private struct GuideFrameContext {
  let selection: FrozenCamera
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

/// What only ARKit can give a FrozenCamera (LiveWorld.swift): one from a frame, and a raycast.
private extension FrozenCamera {
  init(frame: ARFrame, crop: CGRect) {
    self.init(transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
              resolution: frame.camera.imageResolution, crop: crop)
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
