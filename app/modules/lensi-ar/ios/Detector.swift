import CoreML
import CoreImage
import Vision

/// One object found by the on-device detector. `rect` is normalized to the
/// upright (portrait) camera image with a top-left origin.
struct Detection {
  let label: String
  let confidence: Float
  let rect: CGRect
}

/// Runs everything that has to be instant on the phone: YOLO object detection
/// on the Neural Engine and subject segmentation for the tap highlight.
final class Detector {
  /// The Neural Engine and GPU on a phone; CPU only in the Simulator, where a
  /// virtualised GPU can't compile Core ML networks ("On-device compilation
  /// within a VM only supports CPU").
  static var computeUnits: MLComputeUnits {
    #if targetEnvironment(simulator)
    return .cpuOnly
    #else
    return .all
    #endif
  }

  private var yolo: VNCoreMLRequest?
  let ciContext = CIContext(options: [.useSoftwareRenderer: false])

  init() {
    guard let url = Detector.modelURL() else { return }
    let config = MLModelConfiguration()
    config.computeUnits = Detector.computeUnits
    guard let model = try? MLModel(contentsOf: url, configuration: config),
          let vnModel = try? VNCoreMLModel(for: model) else { return }
    let request = VNCoreMLRequest(model: vnModel)
    request.imageCropAndScaleOption = .scaleFill
    yolo = request
  }

  private static func modelURL() -> URL? {
    if let dir = ProcessInfo.processInfo.environment["LENSI_MODELS_DIR"] {
      let url = URL(fileURLWithPath: dir).appendingPathComponent("yolo11n.mlmodelc")
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    // Static frameworks copy resource bundles into the main app bundle.
    for host in [Bundle.main, Bundle(for: Detector.self)] {
      if let bundleURL = host.url(forResource: "LensiARModels", withExtension: "bundle"),
         let bundle = Bundle(url: bundleURL),
         let url = bundle.url(forResource: "yolo11n", withExtension: "mlmodelc") {
        return url
      }
    }
    return nil
  }

  func detect(_ buffer: CVPixelBuffer) -> [Detection] {
    guard let request = yolo else { return [] }
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
    do { try handler.perform([request]) } catch { return [] }
    return Detector.detections(request)
  }

  /// Same detector on an already-upright still image.
  func detect(cgImage: CGImage) -> [Detection] {
    guard let request = yolo else { return [] }
    let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
    do { try handler.perform([request]) } catch { return [] }
    return Detector.detections(request)
  }

  private static func detections(_ request: VNCoreMLRequest) -> [Detection] {
    let results = request.results as? [VNRecognizedObjectObservation] ?? []
    return results.compactMap { obs in
      guard let top = obs.labels.first, top.confidence >= 0.35 else { return nil }
      let b = obs.boundingBox
      return Detection(
        label: top.identifier,
        confidence: top.confidence,
        rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
      )
    }
  }

  /// Outline of the subject under `point` (upright normalized, top-left origin),
  /// in the same coordinate space. Falls back to the instance that covers most
  /// of `hint` when the point lands on background.
  func subjectOutline(_ buffer: CVPixelBuffer, at point: CGPoint, hint: CGRect?) -> [CGPoint]? {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
    guard (try? handler.perform([request])) != nil,
          let observation = request.results?.first else { return nil }

    let mask = observation.instanceMask
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
    let w = CVPixelBufferGetWidth(mask)
    let h = CVPixelBufferGetHeight(mask)
    let stride = CVPixelBufferGetBytesPerRow(mask)
    let px = base.assumingMemoryBound(to: UInt8.self)
    // The mask should be in the oriented (portrait) space; if Vision hands it
    // back in landscape sensor space, convert between the two.
    let sensorSpace = w > h
    let toMask: (CGPoint) -> CGPoint = { sensorSpace ? CGPoint(x: $0.y, y: 1 - $0.x) : $0 }
    let fromMask: (CGPoint) -> CGPoint = { sensorSpace ? CGPoint(x: 1 - $0.y, y: $0.x) : $0 }
    guard point.x.isFinite, point.y.isFinite else { return nil }

    func label(_ x: Int, _ y: Int) -> UInt8 {
      px[min(max(y, 0), h - 1) * stride + min(max(x, 0), w - 1)]
    }

    let maskPoint = toMask(point)
    var instance = label(Int(maskPoint.x * CGFloat(w)), Int(maskPoint.y * CGFloat(h)))
    if instance == 0, let uprightHint = hint, uprightHint.minX.isFinite, !uprightHint.isEmpty {
      let a = toMask(CGPoint(x: uprightHint.minX, y: uprightHint.minY))
      let b = toMask(CGPoint(x: uprightHint.maxX, y: uprightHint.maxY))
      let hint = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
      var counts = [UInt8: Int]()
      let x0 = Int(hint.minX * CGFloat(w)), x1 = Int(hint.maxX * CGFloat(w))
      let y0 = Int(hint.minY * CGFloat(h)), y1 = Int(hint.maxY * CGFloat(h))
      for y in Swift.stride(from: y0, to: y1, by: 2) {
        for x in Swift.stride(from: x0, to: x1, by: 2) {
          let l = label(x, y)
          if l != 0 { counts[l, default: 0] += 1 }
        }
      }
      instance = counts.max(by: { $0.value < $1.value })?.key ?? 0
    }
    guard instance != 0 else { return nil }

    // Binary mask of just that instance, then trace its outline.
    var binary: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8, nil, &binary)
    guard let binary else { return nil }
    CVPixelBufferLockBaseAddress(binary, [])
    let outStride = CVPixelBufferGetBytesPerRow(binary)
    let out = CVPixelBufferGetBaseAddress(binary)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<h {
      for x in 0..<w {
        out[y * outStride + x] = px[y * stride + x] == instance ? 255 : 0
      }
    }
    CVPixelBufferUnlockBaseAddress(binary, [])

    let contours = VNDetectContoursRequest()
    contours.detectsDarkOnLight = false
    contours.maximumImageDimension = 512
    guard (try? VNImageRequestHandler(cvPixelBuffer: binary, orientation: .up).perform([contours])) != nil,
          let result = contours.results?.first else { return nil }

    let largest = result.topLevelContours.max { area($0) < area($1) }
    guard let contour = (try? largest?.polygonApproximation(epsilon: 0.003)) ?? largest,
          contour.pointCount > 4 else { return nil }
    return contour.normalizedPoints.map { fromMask(CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y))) }
  }

  private func area(_ contour: VNContour) -> Float {
    let p = contour.normalizedPoints
    guard p.count > 2 else { return 0 }
    var sum: Float = 0
    for i in 0..<p.count {
      let a = p[i], b = p[(i + 1) % p.count]
      sum += a.x * b.y - b.x * a.y
    }
    return abs(sum) / 2
  }

  /// JPEG of a region of the upright frame, longest side capped at `maxSide`.
  func jpeg(_ buffer: CVPixelBuffer, crop: CGRect, maxSide: CGFloat = 640) -> Data? {
    let image = CIImage(cvPixelBuffer: buffer).oriented(.right)
    let e = image.extent
    let r = CGRect(
      x: e.minX + crop.minX * e.width,
      y: e.minY + (1 - crop.maxY) * e.height,
      width: crop.width * e.width,
      height: crop.height * e.height
    ).integral
    let scale = min(1, maxSide / max(r.width, r.height))
    let out = image.cropped(to: r)
      .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
      .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return ciContext.jpegRepresentation(
      of: out,
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.72]
    )
  }
}
