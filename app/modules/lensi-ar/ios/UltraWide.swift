import AVFoundation
import CoreMedia
import QuartzCore

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
