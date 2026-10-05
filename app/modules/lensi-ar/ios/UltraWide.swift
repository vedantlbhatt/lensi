import AVFoundation
import CoreMedia
import CoreMotion
import QuartzCore
import simd

/// The ultra-wide camera on its own: 0.5x on a phone whose ARKit has no ultra-wide format to track
/// the world with (an iPhone 17 offers none). ARKit pauses while it runs (one app can't run both
/// cameras' sessions at once), so there's no world tracking: LensiARView follows pinned things on
/// its picture with EdgeTAM alone and draws them flat over it, until the zoom is back at 1x.
///
/// Its frames lie on their side like ARKit's (`.right` turns them upright), so the picture
/// EdgeTAM sees and every upright point mean the same as on ARKit's frames.
final class UltraWideCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  static var device: AVCaptureDevice? {
    AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
  }

  static let available: Bool = device != nil

  let session = AVCaptureSession()
  /// The picture as it comes, filling the view (aspect fill, upright).
  let preview: AVCaptureVideoPreviewLayer
  private let output = AVCaptureVideoDataOutput()
  private let queue = DispatchQueue(label: "lensi.ultra-wide", qos: .userInitiated)
  private var configured = false
  private let lock = NSLock()
  private var latestFrame: (buffer: CVPixelBuffer, t: CFTimeInterval)?

  /// Every frame and when it was captured (CACurrentMediaTime's clock), on the camera's queue.
  var onFrame: ((CVPixelBuffer, CFTimeInterval) -> Void)?

  /// The gyro while it runs: how far the phone has turned since a frame, so an outline EdgeTAM
  /// found in it can be moved to where its thing is on the picture now (`warp`). There's no ARKit
  /// at 0.5x to hold it in the world, and without this it trails its thing by however long
  /// EdgeTAM took whenever the phone turns.
  private let motion = CMMotionManager()
  private let motionQueue = OperationQueue()
  private var turns: [(t: CFTimeInterval, rate: simd_float3)] = []
  /// The lens across the picture's long side (radians), once the camera is set up.
  private var fieldOfView: Float = 0

  /// The newest frame, for a photo.
  var latest: (buffer: CVPixelBuffer, t: CFTimeInterval)? {
    lock.lock()
    defer { lock.unlock() }
    return latestFrame
  }

  override init() {
    preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    super.init()
  }

  /// Starts it. ARKit lets go of the camera a moment after it pauses, so a start that doesn't
  /// take is tried again a few times.
  func start(attempt: Int = 0) {
    if attempt == 0, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive {
      motion.deviceMotionUpdateInterval = 1.0 / 100
      motionQueue.maxConcurrentOperationCount = 1
      motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] m, _ in
        guard let self, let m else { return }
        let r = m.rotationRate
        self.lock.lock()
        self.turns.append((t: m.timestamp, rate: simd_float3(Float(r.x), Float(r.y), Float(r.z))))
        if self.turns.count > 300 { self.turns.removeFirst(self.turns.count - 300) }
        self.lock.unlock()
      }
    }
    queue.async { [self] in
      wanted = true
      if !configured { configure() }
      if configured, !session.isRunning { session.startRunning() }
      if !session.isRunning, attempt < 8 {
        queue.asyncAfter(deadline: .now() + 0.15) { [self] in
          if wanted { start(attempt: attempt + 1) }
        }
      }
    }
  }

  /// Stops it, then calls `done` on the main queue (ARKit can have the camera back then).
  func stop(_ done: (() -> Void)? = nil) {
    motion.stopDeviceMotionUpdates()
    lock.lock()
    turns = []
    lock.unlock()
    queue.async { [self] in
      wanted = false
      if session.isRunning { session.stopRunning() }
      lock.lock()
      latestFrame = nil
      lock.unlock()
      if let done { DispatchQueue.main.async(execute: done) }
    }
  }

  /// Only touched on `queue`: started and not stopped since.
  private var wanted = false

  private func configure() {
    guard let device = UltraWideCamera.device, let input = try? AVCaptureDeviceInput(device: device) else { return }
    session.beginConfiguration()
    // 16:9 shows as much across a tall screen as the full 4:3 sensor does (the screen crops
    // that harder), at less to draw and encode.
    if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
    guard session.canAddInput(input) else {
      session.commitConfiguration()
      return
    }
    session.addInput(input)
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(output) { session.addOutput(output) }
    session.commitConfiguration()
    fieldOfView = device.activeFormat.videoFieldOfView * .pi / 180
    if let connection = preview.connection {
      if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
    }
    configured = true
  }

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    // Capture time on the host clock, which is CACurrentMediaTime's (and ARKit's timestamps').
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let t = pts.isValid ? CMTimeGetSeconds(pts) : CACurrentMediaTime()
    lock.lock()
    latestFrame = (buffer, t)
    lock.unlock()
    onFrame?(buffer, t)
  }

  /// How far the phone turned from `t0` to `t1` (the gyro's rate summed over the time between;
  /// radians about the phone's own axes: x to the right of the screen, y up it, z out of it).
  func turned(from t0: CFTimeInterval, to t1: CFTimeInterval) -> simd_float3 {
    guard t1 > t0 else { return .zero }
    lock.lock()
    defer { lock.unlock() }
    var total = simd_float3.zero
    var last = t0
    for s in turns where s.t > t0 {
      let end = min(s.t, t1)
      if end > last { total += s.rate * Float(end - last) }
      last = max(last, end)
      if s.t >= t1 { break }
    }
    return total
  }

  /// Upright picture points (0…1) seen at `t0`, where they'd be seen at `t1` given how the phone
  /// turned meanwhile: each one's line of sight from the lens turned back by that much. The phone
  /// moving (not turning) isn't in it; over a tenth of a second that's small at 0.5x. Up to 2 s
  /// back (the strip's things are found on a frame from a second or so before they're drawn).
  /// `size`: the upright picture in pixels.
  func warp(_ points: [CGPoint], from t0: CFTimeInterval, to t1: CFTimeInterval, size: CGSize) -> [CGPoint] {
    let fov = fieldOfView
    guard fov > 0.1, t1 > t0, t1 - t0 < 2, size.width > 0, size.height > 0 else { return points }
    let theta = turned(from: t0, to: t1)
    let angle = simd_length(theta)
    guard angle > 1e-4, angle < 0.6 else { return points }
    // The phone turned by `theta`, so what it sees turned the other way.
    let back = simd_quatf(angle: -angle, axis: theta / angle)
    // Square pixels; the lens's field of view is across the picture's long side.
    let long = Float(max(size.width, size.height))
    let f = long / 2 / tan(fov / 2)
    let cx = Float(size.width) / 2, cy = Float(size.height) / 2
    return points.map { p in
      // The back camera held upright: picture right is the phone's x, picture down its -y, and it
      // looks along -z.
      let x = (Float(p.x) * Float(size.width) - cx) / f
      let y = (Float(p.y) * Float(size.height) - cy) / f
      let seen = back.act(simd_float3(x, -y, -1))
      guard seen.z < -0.05 else { return p }
      let u = cx + f * seen.x / -seen.z
      let v = cy + f * -seen.y / -seen.z
      return CGPoint(x: CGFloat(u) / size.width, y: CGFloat(v) / size.height)
    }
  }

  /// Where an upright picture point (0…1, top-left origin) is in the preview layer's own space.
  func layerPoint(_ upright: CGPoint) -> CGPoint {
    // Capture-device points are the sensor's (lying on its side), 0…1 from its top-left.
    preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: upright.y, y: 1 - upright.x))
  }

  /// An upright picture point (0…1) under a point of the preview layer.
  func uprightPoint(_ layerPoint: CGPoint) -> CGPoint {
    let p = preview.captureDevicePointConverted(fromLayerPoint: layerPoint)
    return CGPoint(x: 1 - p.y, y: p.x)
  }
}

/// A pinned thing's outline drawn flat over the ultra-wide's picture, with OutlineNode's look: a
/// faint fill, a dark halo so it still reads where the thing is as pale as the line, the line on
/// top.
final class FlatOutline: CALayer {
  private let fill = CAShapeLayer()
  private let halo = CAShapeLayer()
  private let line = CAShapeLayer()

  override init() {
    super.init()
    for l in [fill, halo, line] {
      l.lineJoin = .round
      l.lineCap = .round
      addSublayer(l)
    }
    fill.strokeColor = nil
    halo.fillColor = nil
    halo.strokeColor = CGColor(gray: 0, alpha: 0.32)
    line.fillColor = nil
  }

  override init(layer: Any) {
    super.init(layer: layer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// `path` in this layer's space; `width` the line's, in points.
  func draw(_ path: CGPath, color: CGColor, width: CGFloat, fillOpacity: CGFloat) {
    for l in [fill, halo, line] {
      l.frame = bounds
      l.path = path
    }
    fill.fillColor = color.copy(alpha: fillOpacity)
    halo.lineWidth = width + 3
    line.strokeColor = color
    line.lineWidth = width
  }
}
