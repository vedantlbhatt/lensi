import CoreGraphics
import CoreML
import ImageIO
import QuartzCore
import Vision

enum LensiError: LocalizedError {
  case badImage(String)
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .badImage(let uri): return "Couldn't read the image at \(uri)."
    case .unavailable(let what): return what
    }
  }
}

/// The still-image "eyes": everything Lensi can learn about a photo without a
/// language model. All coordinates leave here normalized to the upright image
/// with a top-left origin, which is what the JS side expects.
final class Analyzer {
  let queue = DispatchQueue(label: "lensi.analyze", qos: .userInitiated)
  /// Loaded on first use, on `queue`: the module is created on the JS thread
  /// at launch, and compiling Core ML there would hold up the splash screen.
  private lazy var detector = Detector()
  private var cachedImage: (uri: String, image: CGImage)?
  private var cachedMask: (uri: String, observation: VNInstanceMaskObservation?)?

  // MARK: Loading

  /// Decodes a file URI into an upright CGImage (EXIF orientation applied),
  /// downsampled so the longest side is at most `maxSide`.
  static func loadUpright(uri: String, maxSide: Int = 2048) throws -> CGImage {
    let url: URL
    if let u = URL(string: uri), u.isFileURL {
      url = u
    } else {
      url = URL(fileURLWithPath: uri.replacingOccurrences(of: "file://", with: ""))
    }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw LensiError.badImage(uri) }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxSide,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw LensiError.badImage(uri)
    }
    return image
  }

  private func image(for uri: String) throws -> CGImage {
    if let c = cachedImage, c.uri == uri { return c.image }
    let image = try Analyzer.loadUpright(uri: uri)
    cachedImage = (uri, image)
    cachedMask = nil
    return image
  }

  private func maskObservation(for uri: String, image: CGImage) -> VNInstanceMaskObservation? {
    if let c = cachedMask, c.uri == uri { return c.observation }
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    let observation: VNInstanceMaskObservation?
    do {
      try handler.perform([request])
      observation = request.results?.first
    } catch {
      // Not supported in the Simulator; everything else still works.
      observation = nil
    }
    cachedMask = (uri, observation)
    return observation
  }

  // MARK: Analysis

  func analyze(uri: String) throws -> [String: Any] {
    let started = CACurrentMediaTime()
    let image = try image(for: uri)
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])

    // Foreground instances: the subject and its neighbours, as outlines.
    var instances: [Outline.Instance] = []
    if let observation = maskObservation(for: uri, image: image) {
      instances = Outline.instances(from: observation, maxCount: 6)
    }
    let subject = instances.max { Outline.prominence($0) < Outline.prominence($1) }

    // Each request runs on its own so one failure (e.g. in the Simulator)
    // doesn't take the rest down with it.
    let text = VNRecognizeTextRequest()
    text.recognitionLevel = .accurate
    text.usesLanguageCorrection = true
    text.minimumTextHeight = 0.012
    try? handler.perform([text])

    let codes = VNDetectBarcodesRequest()
    try? handler.perform([codes])

    let classify = VNClassifyImageRequest()
    try? handler.perform([classify])

    let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
    try? handler.perform([saliency])

    let objects = detector.detect(cgImage: image)

    let textOut: [[String: Any]] = (text.results ?? []).compactMap { obs in
      guard let top = obs.topCandidates(1).first, top.confidence >= 0.3 else { return nil }
      return ["text": top.string, "confidence": Double(top.confidence), "box": Analyzer.box(vision: obs.boundingBox)]
    }
    let codeOut: [[String: Any]] = (codes.results ?? []).compactMap { obs in
      guard let payload = obs.payloadStringValue, !payload.isEmpty else { return nil }
      return ["payload": payload, "symbology": obs.symbology.rawValue, "box": Analyzer.box(vision: obs.boundingBox)]
    }
    let labels: [[String: Any]] = (classify.results ?? [])
      .filter { $0.confidence >= 0.12 }
      .sorted { $0.confidence > $1.confidence }
      .prefix(6)
      .map { ["label": $0.identifier.replacingOccurrences(of: "_", with: " "), "confidence": Double($0.confidence)] }
    let salient: [[String: Any]] = (saliency.results?.first?.salientObjects ?? []).map { Analyzer.box(vision: $0.boundingBox) }
    let objectOut: [[String: Any]] = objects.map {
      ["label": $0.label, "confidence": Double($0.confidence), "box": Analyzer.box(upright: $0.rect)]
    }

    return [
      "width": image.width,
      "height": image.height,
      "subject": subject.map { Outline.json($0) as Any } ?? NSNull(),
      "instances": instances.map(Outline.json),
      "text": textOut,
      "barcodes": codeOut,
      "objects": objectOut,
      "labels": labels,
      "salient": salient,
      "ms": Int((CACurrentMediaTime() - started) * 1000),
    ]
  }

  /// The part under a point: SAM when its models are bundled, otherwise the
  /// Vision foreground instance under the point.
  func segment(uri: String, at point: CGPoint) throws -> [String: Any]? {
    let image = try image(for: uri)
    if let sam = SAMSegmenter.shared {
      do {
        try sam.prepare(image: image, id: uri)
        let mask = try sam.segment(id: uri, points: [point], labels: [1], box: nil)
        if mask.polygon.count > 2 {
          return [
            "polygon": mask.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
            "box": Analyzer.box(upright: Outline.bounds(mask.polygon)),
            "score": Double(mask.score),
            "engine": "sam",
          ]
        }
      } catch {
        NSLog("[lensi] SAM failed, falling back to Vision: \(error.localizedDescription)")
      }
    }
    guard let observation = maskObservation(for: uri, image: image),
          let inst = Outline.instance(at: point, in: observation) else { return nil }
    var out = Outline.json(inst)
    out["score"] = 0.5
    out["engine"] = "vision"
    return out
  }

  // MARK: Coordinates

  /// Vision rects are normalized with a bottom-left origin.
  static func box(vision r: CGRect) -> [String: Any] {
    ["x": Double(r.minX), "y": Double(1 - r.maxY), "w": Double(r.width), "h": Double(r.height)]
  }

  static func box(upright r: CGRect) -> [String: Any] {
    ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
  }
}

/// Mask → outline polygons, shared by the analyzer and the live view.
enum Outline {
  struct Instance {
    let index: UInt8
    let polygon: [CGPoint]
    let box: CGRect
    let area: CGFloat
  }

  static func prominence(_ i: Instance) -> CGFloat {
    let c = CGPoint(x: i.box.midX, y: i.box.midY)
    let off = hypot(c.x - 0.5, c.y - 0.5)
    return i.area * max(0.2, 1 - off * 1.3)
  }

  static func json(_ i: Instance) -> [String: Any] {
    [
      "box": Analyzer.box(upright: i.box),
      "polygon": i.polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
    ]
  }

  static func bounds(_ pts: [CGPoint]) -> CGRect {
    guard let first = pts.first else { return .zero }
    var r = CGRect(origin: first, size: .zero)
    for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
    return r
  }

  /// Every instance in the mask, largest first.
  static func instances(from observation: VNInstanceMaskObservation, maxCount: Int) -> [Instance] {
    let mask = observation.instanceMask
    var found: [Instance] = []
    for index in observation.allInstances {
      guard index > 0, index < 256 else { continue }
      if let inst = outline(mask: mask, instance: UInt8(index)) { found.append(inst) }
    }
    return Array(found.sorted { $0.area > $1.area }.prefix(maxCount))
  }

  static func instance(at point: CGPoint, in observation: VNInstanceMaskObservation) -> Instance? {
    let mask = observation.instanceMask
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    let w = CVPixelBufferGetWidth(mask)
    let h = CVPixelBufferGetHeight(mask)
    let stride = CVPixelBufferGetBytesPerRow(mask)
    var label: UInt8 = 0
    if let base = CVPixelBufferGetBaseAddress(mask) {
      let px = base.assumingMemoryBound(to: UInt8.self)
      let x = min(max(Int(point.x * CGFloat(w)), 0), w - 1)
      let y = min(max(Int(point.y * CGFloat(h)), 0), h - 1)
      label = px[y * stride + x]
    }
    CVPixelBufferUnlockBaseAddress(mask, .readOnly)
    guard label != 0 else { return nil }
    return outline(mask: mask, instance: label)
  }

  /// One instance of a label mask → its largest outer contour, simplified.
  static func outline(mask: CVPixelBuffer, instance: UInt8) -> Instance? {
    CVPixelBufferLockBaseAddress(mask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
    let w = CVPixelBufferGetWidth(mask)
    let h = CVPixelBufferGetHeight(mask)
    let stride = CVPixelBufferGetBytesPerRow(mask)
    let px = base.assumingMemoryBound(to: UInt8.self)

    var binary: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_OneComponent8, nil, &binary)
    guard let binary else { return nil }
    CVPixelBufferLockBaseAddress(binary, [])
    guard let outBase = CVPixelBufferGetBaseAddress(binary) else {
      CVPixelBufferUnlockBaseAddress(binary, [])
      return nil
    }
    let outStride = CVPixelBufferGetBytesPerRow(binary)
    let out = outBase.assumingMemoryBound(to: UInt8.self)
    var count = 0
    var minX = w, minY = h, maxX = 0, maxY = 0
    for y in 0..<h {
      for x in 0..<w {
        let on = px[y * stride + x] == instance
        out[y * outStride + x] = on ? 255 : 0
        if on {
          count += 1
          if x < minX { minX = x }
          if x > maxX { maxX = x }
          if y < minY { minY = y }
          if y > maxY { maxY = y }
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(binary, [])
    guard count > 24 else { return nil }

    let contours = VNDetectContoursRequest()
    contours.detectsDarkOnLight = false
    contours.maximumImageDimension = 512
    guard (try? VNImageRequestHandler(cvPixelBuffer: binary, orientation: .up, options: [:]).perform([contours])) != nil,
          let result = contours.results?.first else { return nil }
    let largest = result.topLevelContours.max { area($0) < area($1) }
    guard let contour = (try? largest?.polygonApproximation(epsilon: 0.0025)) ?? largest,
          contour.pointCount > 4 else { return nil }
    let polygon = contour.normalizedPoints.map { CGPoint(x: CGFloat($0.x), y: 1 - CGFloat($0.y)) }
    let box = CGRect(
      x: CGFloat(minX) / CGFloat(w),
      y: CGFloat(minY) / CGFloat(h),
      width: CGFloat(maxX - minX + 1) / CGFloat(w),
      height: CGFloat(maxY - minY + 1) / CGFloat(h)
    )
    return Instance(index: instance, polygon: polygon, box: box, area: CGFloat(count) / CGFloat(w * h))
  }

  private static func area(_ contour: VNContour) -> Float {
    let p = contour.normalizedPoints
    guard p.count > 2 else { return 0 }
    var sum: Float = 0
    for i in 0..<p.count {
      let a = p[i], b = p[(i + 1) % p.count]
      sum += a.x * b.y - b.x * a.y
    }
    return abs(sum) / 2
  }
}
