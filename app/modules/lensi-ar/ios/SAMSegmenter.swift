import CoreGraphics
import CoreImage
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
  /// The encoder input `prepare(ciImage:)` reuses: one 1024x1024 BGRA buffer.
  private var canvas: CVPixelBuffer?

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
  /// an id that is still cached is not encoded again, unless `force` (the live camera reuses
  /// one id for every frame).
  func prepare(image: CGImage, id: String, force: Bool = false) throws {
    lock.lock()
    defer { lock.unlock() }
    if !force, cache[id] != nil {
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

  /// `prepare(image:)` for a Core Image source, e.g. the camera buffer turned upright: drawn
  /// into the encoder's canvas by `context` (on the GPU), without a CGImage in between.
  func prepare(ciImage: CIImage, context: CIContext, id: String) throws {
    lock.lock()
    defer { lock.unlock() }
    let e = ciImage.extent
    guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite else { throw SAMError.badImage }
    let side = SAMSegmenter.side
    let scale = Double(side) / Double(max(e.width, e.height))
    let resizedWidth = Int(Double(e.width) * scale + 0.5)
    let resizedHeight = Int(Double(e.height) * scale + 0.5)
    if canvas == nil {
      let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
      var created: CVPixelBuffer?
      guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &created) == kCVReturnSuccess
      else { throw SAMError.pixelBuffer }
      canvas = created
    }
    guard let buffer = canvas else { throw SAMError.pixelBuffer }
    // Core Image's origin is bottom-left, so the image goes at y = side - height to land in
    // the buffer's top rows. Padding: the mean colour, like makeCanvas.
    let sx = CGFloat(resizedWidth) / e.width, sy = CGFloat(resizedHeight) / e.height
    let placed = ciImage
      .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
      .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
      .transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(side - resizedHeight)))
    let pad = SAMSegmenter.padBGRA
    let background = CIImage(color: CIColor(red: CGFloat(pad[2]) / 255, green: CGFloat(pad[1]) / 255, blue: CGFloat(pad[0]) / 255))
      .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    context.render(placed.composited(over: background), to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side), colorSpace: srgb)
    let input = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
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
  ///
  /// `preferPart`: for a single tap, take the best candidate that is part-sized (a headlamp,
  /// not the whole car filling the photo) when there is one. SAM scores the whole object
  /// highest more often than not, which is the wrong answer to "what's this?".
  ///
  /// `prior`: the outline this prompt is following (normalized, a live track's shape in this
  /// frame). Then the candidate that overlaps it most wins, so a tracked outline doesn't flip
  /// between "the handle" and "the whole mug" from one frame to the next.
  func segment(id: String, points: [CGPoint], labels: [Int], box: CGRect?, preferPart: Bool = false,
               prior: [CGPoint]? = nil) throws -> SAMMask {
    lock.lock()
    defer { lock.unlock() }
    guard let prepared = cache[id] else { throw SAMError.notPrepared(id) }
    touch(id)

    let used = Array(zip(points, labels).prefix(SAMSegmenter.slots - (box == nil ? 0 : 2)))
    guard !used.isEmpty || box != nil else { throw SAMError.noPrompt }
    let (masks, scores) = try decode(used, box: box, prepared: prepared)
    var k = SAMSegmenter.chooseMask(scores, labels: used.map { $0.1 }, hasBox: box != nil)
    if let prior, prior.count >= 3 {
      k = SAMSegmenter.closestCandidate(masks, scores: scores, prior: prior, prepared: prepared) ?? k
    } else if preferPart, box == nil, used.count == 1, used[0].1 == 1,
              let part = SAMSegmenter.partCandidate(masks, scores: scores, prepared: prepared) {
      k = part
    }
    return try outline(masks, candidate: k, score: scores[k], prepared: prepared)
  }

  /// Of all four candidates, the one with the highest IoU with `prior` (normalized polygon),
  /// among those scoring at least half the best score. Nil when none overlaps it at all.
  private static func closestCandidate(_ masks: [Float], scores: [Float], prior: [CGPoint], prepared: Prepared) -> Int? {
    let n = maskSide
    let plane = n * n
    let validW = min(n, max(1, Int((Double(prepared.resizedWidth) / 4).rounded(.up))))
    let validH = min(n, max(1, Int((Double(prepared.resizedHeight) / 4).rounded(.up))))
    var priorBits = [UInt8](repeating: 0, count: validW * validH)
    priorBits.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: validW, height: validH, bitsPerComponent: 8, bytesPerRow: validW,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
      ctx.translateBy(x: 0, y: CGFloat(validH))
      ctx.scaleBy(x: CGFloat(validW), y: -CGFloat(validH))
      ctx.setFillColor(gray: 1, alpha: 1)
      ctx.addLines(between: prior)
      ctx.closePath()
      ctx.fillPath()
    }
    let top = scores.max() ?? 0
    var best: (k: Int, iou: Float)?
    for k in 0...3 where scores[k] >= top * 0.5 {
      var inter = 0, union = 0
      let base = k * plane
      for y in 0..<validH {
        let row = base + y * n
        for x in 0..<validW {
          let a = masks[row + x] > 0, b = priorBits[y * validW + x] > 127
          if a && b { inter += 1 }
          if a || b { union += 1 }
        }
      }
      let iou = union > 0 ? Float(inter) / Float(union) : 0
      if iou > (best?.iou ?? 0) { best = (k, iou) }
    }
    return best?.k
  }

  /// The best-scoring multimask candidate (1...3) whose area is part-sized: not a speck, and
  /// not most of the photo. Nil when none is, e.g. a tap on the sky.
  private static func partCandidate(_ masks: [Float], scores: [Float], prepared: Prepared,
                                    minArea: Float = 0.0015, maxArea: Float = 0.35, minScore: Float = 0.75) -> Int? {
    let n = maskSide
    let plane = n * n
    let validW = min(n, max(1, Int((Double(prepared.resizedWidth) / 4).rounded(.up))))
    let validH = min(n, max(1, Int((Double(prepared.resizedHeight) / 4).rounded(.up))))
    let cells = Float(validW * validH)
    var best: (k: Int, score: Float)?
    for k in 1...3 where scores[k] >= minScore && scores[k] > (best?.score ?? -1) {
      var on = 0
      let base = k * plane
      for y in 0..<validH {
        let row = base + y * n
        for x in 0..<validW where masks[row + x] > 0 { on += 1 }
      }
      let area = Float(on) / cells
      guard area >= minArea, area <= maxArea else { continue }
      best = (k: k, score: scores[k])
    }
    return best?.k
  }

  /// Part proposals for set-of-marks prompting: single positive points on a grid over `region`
  /// (normalized, upright, top-left origin). From each prompt it keeps the multimask candidate
  /// that looks like a part (confident, between `minArea` and `maxArea` of the image), drops
  /// candidates that mostly overlap a part already kept, and stops at `maxParts` or when
  /// `budget` runs out. Best first. Call `prepare` first.
  func proposeParts(id: String, region: CGRect, grid: Int = 5, maxParts: Int = 8,
                    minArea: Float = 0.002, maxArea: Float = 0.2, minScore: Float = 0.8,
                    budget: TimeInterval = 0.9) throws -> [SAMMask] {
    lock.lock()
    defer { lock.unlock() }
    guard let prepared = cache[id] else { throw SAMError.notPrepared(id) }
    touch(id)
    let started = Date()
    let n = SAMSegmenter.maskSide
    let plane = n * n
    // The image fills the top-left resized/4 cells of each 256x256 plane.
    let validW = min(n, max(1, Int((Double(prepared.resizedWidth) / 4).rounded(.up))))
    let validH = min(n, max(1, Int((Double(prepared.resizedHeight) / 4).rounded(.up))))
    let cells = Float(validW * validH)
    var keptMasks: [SAMMask] = []
    var keptBits: [[Bool]] = []
    let g = max(1, grid)
    scan: for gy in 0..<g {
      for gx in 0..<g {
        if keptMasks.count >= maxParts || Date().timeIntervalSince(started) > budget { break scan }
        let p = CGPoint(x: region.minX + (CGFloat(gx) + 0.5) / CGFloat(g) * region.width,
                        y: region.minY + (CGFloat(gy) + 0.5) / CGFloat(g) * region.height)
        guard p.x > 0, p.x < 1, p.y > 0, p.y < 1 else { continue }
        let (masks, scores) = try decode([(p, 1)], box: nil, prepared: prepared)
        // Candidates 1...3 are the multimask outputs (roughly: subpart, part, whole).
        var best: (k: Int, bits: [Bool], score: Float)?
        for k in 1...3 where scores[k] >= minScore && scores[k] > (best?.score ?? -1) {
          var bits = [Bool](repeating: false, count: validW * validH)
          var on = 0
          let base = k * plane
          for y in 0..<validH {
            let row = base + y * n
            for x in 0..<validW where masks[row + x] > 0 {
              bits[y * validW + x] = true
              on += 1
            }
          }
          let area = Float(on) / cells
          guard area >= minArea, area <= maxArea else { continue }
          best = (k: k, bits: bits, score: scores[k])
        }
        guard let chosen = best else { continue }
        let duplicate = keptBits.contains { (other: [Bool]) -> Bool in
          var inter = 0
          var union = 0
          for i in 0..<other.count {
            let a = other[i], b = chosen.bits[i]
            if a && b { inter += 1 }
            if a || b { union += 1 }
          }
          return union > 0 && Float(inter) / Float(union) > 0.6
        }
        if duplicate { continue }
        let mask = try outline(masks, candidate: chosen.k, score: chosen.score, prepared: prepared)
        guard mask.polygon.count >= 3 else { continue }
        keptMasks.append(mask)
        keptBits.append(chosen.bits)
      }
    }
    return keptMasks.sorted { $0.score > $1.score }
  }

  /// One decoder pass: four 256x256 logit planes (row-major) and their predicted IoUs.
  private func decode(_ used: [(CGPoint, Int)], box: CGRect?, prepared: Prepared) throws -> (masks: [Float], scores: [Float]) {
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
    let masks = SAMSegmenter.floats(masksArray)
    let scores = SAMSegmenter.floats(scoresArray)
    let plane = SAMSegmenter.maskSide * SAMSegmenter.maskSide
    guard scores.count == 4, masks.count == 4 * plane else { throw SAMError.badOutput("shape") }
    return (masks: masks, scores: scores)
  }

  /// A contiguous float32 copy. The fast path is a memcpy; MLShapedArray's converting copy
  /// takes ~12 ms for the 4x256x256 masks.
  private static func floats(_ a: MLMultiArray) -> [Float] {
    var contiguous = true
    var expected = 1
    for (dim, stride) in zip(a.shape.reversed(), a.strides.reversed()) {
      if stride.intValue != expected { contiguous = false }
      expected *= dim.intValue
    }
    if contiguous, a.dataType == .float32 {
      return a.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(a.count)) }
    }
    return MLShapedArray<Float>(converting: a).scalars
  }

  /// One candidate's largest region as a simplified outline, normalized to the prepared image.
  private func outline(_ masks: [Float], candidate k: Int, score: Float, prepared: Prepared) throws -> SAMMask {
    let n = SAMSegmenter.maskSide
    // The image fills the top-left resized/4 cells of each 256x256 plane.
    let validW = min(n, max(1, Int((Double(prepared.resizedWidth) / 4).rounded(.up))))
    let validH = min(n, max(1, Int((Double(prepared.resizedHeight) / 4).rounded(.up))))
    let (contour, area) = masks.withUnsafeBufferPointer {
      MaskContour.largest($0, offset: k * n * n, stride: n, width: validW, height: validH)
    }
    guard contour.count >= 3 else { return SAMMask(polygon: [], score: score, area: area) }
    let simplified = SAMSegmenter.simplifyClosed(
      contour, epsilon: SAMSegmenter.simplifyFraction * SAMSegmenter.perimeter(contour))
    guard simplified.count >= 3 else { return SAMMask(polygon: [], score: score, area: area) }
    // Cell units -> normalized: a cell is 4 canvas pixels; the image is resized wide.
    let sx = 4 / CGFloat(prepared.resizedWidth), sy = 4 / CGFloat(prepared.resizedHeight)
    let polygon = simplified.map { CGPoint(x: min(max($0.x * sx, 0), 1), y: min(max($0.y * sy, 0), 1)) }
    return SAMMask(polygon: polygon, score: score, area: area)
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
