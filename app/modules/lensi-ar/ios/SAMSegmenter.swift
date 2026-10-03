import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// Outline of one segmented object.
struct SAMMask {
  /// Largest region's outline, normalized to the image given to `prepare` (upright, top-left
  /// origin), simplified to 0.3% of its perimeter. Empty when the mask is empty.
  let polygon: [CGPoint]
  /// The decoder's predicted IoU for the chosen mask.
  let score: Float
  /// Fraction of the image the mask covers (every region, not just the outlined one).
  let area: Float

  /// Bounding box of `polygon` in the same normalized space (`Segment.box` on the JS side);
  /// `.zero` when there is no polygon.
  var bounds: CGRect {
    guard let first = polygon.first else { return .zero }
    var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
    for p in polygon.dropFirst() {
      minX = min(minX, p.x)
      minY = min(minY, p.y)
      maxX = max(maxX, p.x)
      maxY = max(maxY, p.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

enum SAMError: LocalizedError {
  case notPrepared(String)
  case noPrompt
  case badImage
  case pixelBuffer
  case badOutput(String)

  var errorDescription: String? {
    switch self {
    case .notPrepared(let id): return "SAM: no embedding cached for \(id); call prepare first"
    case .noPrompt: return "SAM: needs at least one point or a box"
    case .badImage: return "SAM: empty image"
    case .pixelBuffer: return "SAM: could not create a pixel buffer"
    case .badOutput(let name): return "SAM: unexpected model output (\(name))"
    }
  }
}

/// On-device Segment Anything (MobileSAM, converted by tools/sam/convert.py): one encoder pass
/// per image, cached by id, then one decoder pass per prompt.
///
///     // Upright, like Detector's "upright" space (the sensor image rotated by .right).
///     let upright = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
///     guard let image = ciContext.createCGImage(upright, from: upright.extent) else { return }
///     try SAMSegmenter.shared?.prepare(image: image, id: pinId)
///     let mask = try SAMSegmenter.shared?.segment(id: pinId, points: [tapUpright], labels: [1], box: nil)
///
/// Mirrors tools/sam/sam_common.py step for step: `makeCanvas` = preprocess, `packPrompt` =
/// pack_prompt, `chooseMask` = choose_mask, `binaryMask` = upsample_logits + threshold,
/// `simplifyClosed` = simplify_closed. Change them together. Calls are serialized by a lock, so
/// any queue works; the first access to `shared` loads both models (can take seconds while
/// Core ML compiles for the Neural Engine), so touch it off the main thread.
/// (`@unchecked Sendable`: every mutable member is only touched under `lock`.)
final class SAMSegmenter: @unchecked Sendable {
  /// nil when the compiled models are not in the LensiARModels resource bundle.
  static let shared: SAMSegmenter? = SAMSegmenter()

  private static let side = 1024 // encoder input; the image's long side is resized to this
  private static let maskSide = 256 // decoder low-res masks cover the whole 1024 canvas
  private static let slots = 5 // fixed prompt slots in LensiSAMDecoder
  private static let workDivisor = 2 // outline is traced at half the 1024 resolution
  private static let simplifyFraction: CGFloat = 0.003
  /// SAM normalizes with mean (123.675, 116.28, 103.53) and then zero-pads; padding with the
  /// rounded mean color gets within 0.008 of that. Bytes in BGRA order.
  private static let padBGRA: [UInt8] = [104, 116, 124, 255]
  private static let cacheLimit = 3 // embeddings are 4 MB each

  private struct Prepared {
    let embeddings: MLMultiArray
    let resizedWidth: Int
    let resizedHeight: Int
  }

  private let encoder: MLModel
  private let decoder: MLModel
  private let lock = NSLock()
  private var cache: [String: Prepared] = [:]
  private var recent: [String] = []

  private init?() {
    guard let encoderURL = SAMSegmenter.modelURL("LensiSAMEncoder"),
          let decoderURL = SAMSegmenter.modelURL("LensiSAMDecoder") else { return nil }
    let config = MLModelConfiguration()
    config.computeUnits = Detector.computeUnits
    guard let encoder = try? MLModel(contentsOf: encoderURL, configuration: config),
          let decoder = try? MLModel(contentsOf: decoderURL, configuration: config) else { return nil }
    self.encoder = encoder
    self.decoder = decoder
  }

  private static func modelURL(_ name: String) -> URL? {
    if let dir = ProcessInfo.processInfo.environment["LENSI_MODELS_DIR"] {
      let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).mlmodelc")
      if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    // Static frameworks copy resource bundles into the main app bundle.
    for host in [Bundle.main, Bundle(for: SAMSegmenter.self)] {
      if let bundleURL = host.url(forResource: "LensiARModels", withExtension: "bundle"),
         let bundle = Bundle(url: bundleURL),
         let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
        return url
      }
    }
    return nil
  }

  // MARK: - API

  /// Runs the encoder once per image (cache by an id string). `image` must already be upright;
  /// an id that is still cached is not encoded again.
  func prepare(image: CGImage, id: String) throws {
    lock.lock()
    defer { lock.unlock() }
    if cache[id] != nil {
      touch(id)
      return
    }
    let w = image.width, h = image.height
    guard w > 0, h > 0 else { throw SAMError.badImage }
    // SAM's ResizeLongestSide.get_preprocess_shape.
    let scale = Double(SAMSegmenter.side) / Double(max(w, h))
    let resizedWidth = Int(Double(w) * scale + 0.5)
    let resizedHeight = Int(Double(h) * scale + 0.5)
    let canvas = try makeCanvas(image, width: resizedWidth, height: resizedHeight)
    let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: canvas)])
    let output = try encoder.prediction(from: input)
    guard let embeddings = output.featureValue(for: "image_embeddings")?.multiArrayValue else {
      throw SAMError.badOutput("image_embeddings")
    }
    cache[id] = Prepared(embeddings: embeddings, resizedWidth: resizedWidth, resizedHeight: resizedHeight)
    touch(id)
    while recent.count > SAMSegmenter.cacheLimit {
      cache[recent.removeFirst()] = nil
    }
  }

  /// points/box are normalized 0...1 in the image's own (upright) space, top-left origin.
  /// labels: 1 = on the object, 0 = not on it. At most 5 points (3 with a box) are used.
  /// A single positive point picks the best of SAM's three candidate masks; anything else
  /// uses the single-mask output.
  func segment(id: String, points: [CGPoint], labels: [Int], box: CGRect?) throws -> SAMMask {
    lock.lock()
    defer { lock.unlock() }
    guard let prepared = cache[id] else { throw SAMError.notPrepared(id) }
    touch(id)

    let used = Array(zip(points, labels).prefix(SAMSegmenter.slots - (box == nil ? 0 : 2)))
    guard !used.isEmpty || box != nil else { throw SAMError.noPrompt }
    let (coords, slotLabels) = try packPrompt(used, box: box, prepared: prepared)
    let input = try MLDictionaryFeatureProvider(dictionary: [
      "image_embeddings": MLFeatureValue(multiArray: prepared.embeddings),
      "point_coords": MLFeatureValue(multiArray: coords),
      "point_labels": MLFeatureValue(multiArray: slotLabels),
    ])
    let output = try decoder.prediction(from: input)
    guard let masksArray = output.featureValue(for: "masks")?.multiArrayValue,
          let scoresArray = output.featureValue(for: "scores")?.multiArrayValue else {
      throw SAMError.badOutput("masks/scores")
    }
    // Contiguous row-major copies, whatever the output's dtype or strides: [1,4,256,256], [1,4].
    let masks = MLShapedArray<Float>(converting: masksArray).scalars
    let scores = MLShapedArray<Float>(converting: scoresArray).scalars
    let plane = SAMSegmenter.maskSide * SAMSegmenter.maskSide
    guard scores.count == 4, masks.count == 4 * plane else { throw SAMError.badOutput("shape") }

    let k = SAMSegmenter.chooseMask(scores, labels: used.map { $0.1 }, hasBox: box != nil)
    let (binary, area) = try binaryMask(masks, offset: k * plane, prepared: prepared)
    let workWidth = CGFloat(CVPixelBufferGetWidth(binary))
    let workHeight = CGFloat(CVPixelBufferGetHeight(binary))
    let contour = try largestContour(binary)
    guard contour.count >= 3 else { return SAMMask(polygon: [], score: scores[k], area: area) }
    let simplified = SAMSegmenter.simplifyClosed(
      contour, epsilon: SAMSegmenter.simplifyFraction * SAMSegmenter.perimeter(contour))
    guard simplified.count >= 3 else { return SAMMask(polygon: [], score: scores[k], area: area) }
    let polygon = simplified.map { CGPoint(x: $0.x / workWidth, y: $0.y / workHeight) }
    return SAMMask(polygon: polygon, score: scores[k], area: area)
  }

  private func touch(_ id: String) {
    recent.removeAll { $0 == id }
    recent.append(id)
  }

  // MARK: - Preprocess

  /// 1024x1024 BGRA canvas: mean color everywhere, the image resized into the top-left
  /// resizedWidth x resizedHeight. LensiSAMEncoder normalizes the raw 0-255 RGB itself.
  private func makeCanvas(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
    let side = SAMSegmenter.side
    let attrs: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
    ]
    var created: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &created) == kCVReturnSuccess,
          let buffer = created else { throw SAMError.pixelBuffer }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw SAMError.pixelBuffer }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    SAMSegmenter.padBGRA.withUnsafeBytes { pattern in
      memset_pattern4(base, pattern.baseAddress!, bytesPerRow * side)
    }
    guard let context = CGContext(
      data: base, width: side, height: side, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: srgb,
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { throw SAMError.pixelBuffer }
    context.interpolationQuality = .high
    // Quartz's origin is bottom-left, and the buffer's first row is the top of the image, so
    // y = side - height lands the image in the top rows.
    context.draw(image, in: CGRect(x: 0, y: side - height, width: width, height: height))
    return buffer
  }

  /// Decoder inputs: points (x, y scaled into the resized image, i.e. 1024-input pixels), then the
  /// box corners (labels 2, 3), then padding slots at (0, 0) with label -1.
  private func packPrompt(_ used: [(CGPoint, Int)], box: CGRect?,
                          prepared: Prepared) throws -> (MLMultiArray, MLMultiArray) {
    let sx = Double(prepared.resizedWidth), sy = Double(prepared.resizedHeight)
    var slots: [(x: Double, y: Double, label: Double)] = used.map {
      (x: Double($0.0.x) * sx, y: Double($0.0.y) * sy, label: Double($0.1))
    }
    if let box {
      slots.append((x: Double(box.minX) * sx, y: Double(box.minY) * sy, label: 2))
      slots.append((x: Double(box.maxX) * sx, y: Double(box.maxY) * sy, label: 3))
    }
    while slots.count < SAMSegmenter.slots {
      slots.append((x: 0, y: 0, label: -1))
    }
    let count = NSNumber(value: SAMSegmenter.slots)
    let coords = try MLMultiArray(shape: [1, count, 2], dataType: .float32)
    let labels = try MLMultiArray(shape: [1, count], dataType: .float32)
    for (i, slot) in slots.enumerated() {
      let index = NSNumber(value: i)
      coords[[0, index, 0]] = NSNumber(value: Float(slot.x))
      coords[[0, index, 1]] = NSNumber(value: Float(slot.y))
      labels[[0, index]] = NSNumber(value: Float(slot.label))
    }
    return (coords, labels)
  }

  /// Best of the three multimask outputs for one positive click and nothing else; otherwise 0.
  private static func chooseMask(_ scores: [Float], labels: [Int], hasBox: Bool) -> Int {
    guard !hasBox, labels.count == 1, labels[0] == 1 else { return 0 }
    var best = 1
    for i in 2...3 where scores[i] > scores[best] {
      best = i
    }
    return best
  }

  // MARK: - Postprocess

  /// The valid (non-padding) part of one 256x256 logit plane, bilinearly resampled onto the
  /// work grid (half-pixel centers, edge clamp, like torch's align_corners=False) and
  /// thresholded at 0, as a 0/255 OneComponent8 buffer. Also returns the foreground fraction.
  private func binaryMask(_ logits: [Float], offset: Int, prepared: Prepared) throws -> (CVPixelBuffer, Float) {
    let n = SAMSegmenter.maskSide
    let outW = max(1, Int(Double(prepared.resizedWidth) / Double(SAMSegmenter.workDivisor) + 0.5))
    let outH = max(1, Int(Double(prepared.resizedHeight) / Double(SAMSegmenter.workDivisor) + 0.5))

    func taps(_ count: Int, valid: Double) -> (lo: [Int], hi: [Int], frac: [Float]) {
      let step = Float(valid / Double(count))
      var lo = [Int](repeating: 0, count: count)
      var hi = [Int](repeating: 0, count: count)
      var frac = [Float](repeating: 0, count: count)
      for i in 0..<count {
        let s = min(max((Float(i) + 0.5) * step - 0.5, 0), Float(n - 1))
        let i0 = Int(s)
        lo[i] = i0
        hi[i] = min(i0 + 1, n - 1)
        frac[i] = s - Float(i0)
      }
      return (lo, hi, frac)
    }
    // The image covers resized/4 cells of the 256 grid; the rest is canvas padding.
    let xs = taps(outW, valid: Double(prepared.resizedWidth) / 4)
    let ys = taps(outH, valid: Double(prepared.resizedHeight) / 4)

    var created: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, outW, outH, kCVPixelFormatType_OneComponent8, nil,
                              &created) == kCVReturnSuccess,
          let buffer = created else { throw SAMError.pixelBuffer }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SAMError.pixelBuffer }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let out = base.assumingMemoryBound(to: UInt8.self)
    var on = 0
    logits.withUnsafeBufferPointer { lg in
      for v in 0..<outH {
        let r0 = offset + ys.lo[v] * n, r1 = offset + ys.hi[v] * n, fy = ys.frac[v]
        for u in 0..<outW {
          let fx = xs.frac[u]
          let top = lg[r0 + xs.lo[u]] * (1 - fx) + lg[r0 + xs.hi[u]] * fx
          let bottom = lg[r1 + xs.lo[u]] * (1 - fx) + lg[r1 + xs.hi[u]] * fx
          let inside = top * (1 - fy) + bottom * fy > 0
          out[v * stride + u] = inside ? 255 : 0
          if inside { on += 1 }
        }
      }
    }
    return (buffer, Float(on) / Float(outW * outH))
  }

  /// Largest top-level contour of the 0/255 mask, in work-grid pixels with a top-left origin.
  private func largestContour(_ mask: CVPixelBuffer) throws -> [CGPoint] {
    let width = CVPixelBufferGetWidth(mask), height = CVPixelBufferGetHeight(mask)
    let request = VNDetectContoursRequest()
    request.detectsDarkOnLight = false
    request.maximumImageDimension = max(width, height) // the work grid is <= 512: no resampling
    try VNImageRequestHandler(cvPixelBuffer: mask, orientation: .up, options: [:]).perform([request])
    guard let observation = request.results?.first,
          let largest = observation.topLevelContours.max(by: { SAMSegmenter.area($0) < SAMSegmenter.area($1) })
    else { return [] }
    // Vision points are normalized with a bottom-left origin.
    return largest.normalizedPoints.map {
      CGPoint(x: CGFloat($0.x) * CGFloat(width), y: (1 - CGFloat($0.y)) * CGFloat(height))
    }
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

  static func perimeter(_ points: [CGPoint]) -> CGFloat {
    guard points.count > 1 else { return 0 }
    var total: CGFloat = 0
    for i in 0..<points.count {
      let a = points[i], b = points[(i + 1) % points.count]
      total += hypot(b.x - a.x, b.y - a.y)
    }
    return total
  }

  /// Douglas-Peucker on a closed ring: split at the point farthest from the first one, simplify
  /// both halves, join them.
  static func simplifyClosed(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
    guard points.count >= 4 else { return points }
    var far = 0
    var farDistance: CGFloat = -1
    for (i, p) in points.enumerated() {
      let d = (p.x - points[0].x) * (p.x - points[0].x) + (p.y - points[0].y) * (p.y - points[0].y)
      if d > farDistance {
        farDistance = d
        far = i
      }
    }
    guard far > 0 else { return [points[0]] }
    let first = douglasPeucker(Array(points[0...far]), epsilon: epsilon)
    let second = douglasPeucker(Array(points[far...]) + [points[0]], epsilon: epsilon)
    return Array(first.dropLast()) + Array(second.dropLast())
  }

  /// Open-chain Douglas-Peucker with an explicit stack; keeps both endpoints.
  static func douglasPeucker(_ chain: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
    guard chain.count > 2 else { return chain }
    var keep = [Bool](repeating: false, count: chain.count)
    keep[0] = true
    keep[chain.count - 1] = true
    var stack = [(0, chain.count - 1)]
    while let range = stack.popLast() {
      let (i, j) = range
      guard j > i + 1 else { continue }
      var best = i + 1
      var bestDistance: CGFloat = -1
      for m in (i + 1)..<j {
        let d = segmentDistance(chain[m], chain[i], chain[j])
        if d > bestDistance {
          bestDistance = d
          best = m
        }
      }
      if bestDistance > epsilon {
        keep[best] = true
        stack.append((i, best))
        stack.append((best, j))
      }
    }
    return chain.indices.filter { keep[$0] }.map { chain[$0] }
  }

  private static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x, aby = b.y - a.y
    let denom = abx * abx + aby * aby
    guard denom > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / denom, 0), 1)
    return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
  }
}
