import Accelerate
import CoreGraphics
import CoreImage
import CoreML
import CoreVideo
import Foundation

enum EdgeTAMError: LocalizedError {
  case noModels
  case notStarted
  case badImage
  case pixelBuffer
  case badOutput(String)

  var errorDescription: String? {
    switch self {
    case .noModels: return "EdgeTAM: the models aren't in the app"
    case .notStarted: return "EdgeTAM: start(_:box:) first"
    case .badImage: return "EdgeTAM: empty picture"
    case .pixelBuffer: return "EdgeTAM: could not create a pixel buffer"
    case .badOutput(let name): return "EdgeTAM: unexpected model output (\(name))"
    }
  }
}

/// EdgeTAM, Meta's on-device SAM 2 (github.com/facebookresearch/EdgeTAM, Apache 2.0), following one
/// thing through a stream of pictures: tools/edgetam/parts.py's `Tracker`, step for step. Change
/// them together.
///
/// SAM on each frame by itself (SAMSegmenter) forgets the thing between frames, so its outline
/// jumps whenever the picture blurs, the thing turns, or only part of it is in view. EdgeTAM keeps a
/// memory of it: the frame it was pinned on, the last six frames, and an "object pointer" from each
/// of the last fifteen. Every new frame attends to that memory before its mask is decoded, which is
/// what holds it through close-ups, zooming out, turning and running off the edge of the picture.
///
///     let encoder = try EdgeTAMTracker.Encoder()      // one for the camera
///     let tracker = try EdgeTAMTracker()              // one for each thing followed
///     var cut = try tracker.start(encoder.encode(picture), box: box)  // its box, 0...1
///     cut = try tracker.step(encoder.encode(nextPicture))             // every frame after
///
/// A picture is encoded once however many things are followed in it. Pictures are upright
/// CIImages of any size and shape: SAM 2 stretches each to 1024 x 1024, so boxes and outlines are
/// fractions of the picture (top-left origin). Each encoder and tracker is used from one queue at
/// a time. The models load once for all of them (`Models.shared`), which takes seconds the first
/// time while Core ML compiles them: touch it off the main thread.
final class EdgeTAMTracker {
  static let side = 1024
  static let maskSide = 256
  static let numMem = 7 // memory frames: the pinned one and the last six
  static let memTokens = 512
  static let memDim = 64
  static let numPtrs = 16 // object pointers: the pinned frame's and the last fifteen
  static let ptrDim = 256

  /// The four models (tools/edgetam/convert.py), shared by every tracker.
  final class Models: @unchecked Sendable {
    static let shared: Models? = Models()

    let encoder: MLModel
    let prompt: MLModel
    let track: MLModel
    let memory: MLModel

    private init?() {
      let config = MLModelConfiguration()
      config.computeUnits = Models.computeUnits
      var loaded: [MLModel] = []
      for name in ["EdgeTAMEncoder", "EdgeTAMPrompt", "EdgeTAMTrack", "EdgeTAMMemory"] {
        guard let url = Models.url(name), let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        loaded.append(model)
      }
      encoder = loaded[0]
      prompt = loaded[1]
      track = loaded[2]
      memory = loaded[3]
    }

    /// As Detector's: the Neural Engine on a phone, leaving the GPU to the camera and the
    /// outlines; the CPU in the Simulator (it can't compile for anything else); a Mac uses all.
    static var computeUnits: MLComputeUnits {
      #if targetEnvironment(simulator)
      return .cpuOnly
      #elseif os(iOS)
      return .cpuAndNeuralEngine
      #else
      return .all
      #endif
    }

    static func url(_ name: String) -> URL? {
      if let dir = ProcessInfo.processInfo.environment["LENSI_MODELS_DIR"] {
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: url.path) { return url }
      }
      // Static frameworks copy resource bundles into the main app bundle.
      for host in [Bundle.main, Bundle(for: Models.self)] {
        if let bundleURL = host.url(forResource: "LensiARModels", withExtension: "bundle"),
           let bundle = Bundle(url: bundleURL),
           let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
          return url
        }
      }
      return nil
    }
  }

  /// What the tracker saw in one picture.
  struct Cut {
    /// The chosen mask's logits, 256 x 256 over the whole picture (row-major, top row first,
    /// above zero inside). -1024 everywhere when the thing isn't in view.
    let logits: [Float]
    /// The thing's outline (its largest region, holes filled), traced between the mask's cells
    /// and smoothed along its edge, so it moves smoothly; fractions of the picture, top-left
    /// origin. Empty when it isn't in view.
    let outline: [CGPoint]
    /// SAM 2's object score: above zero, the thing is in view.
    let score: Float
    /// The mask decoder's estimate of its own IoU.
    let iou: Float
    /// Fraction of the picture the mask covers.
    let area: Float
    /// Milliseconds each step took: draw and encoder (the picture's, shared), prompt or track,
    /// memory, outline.
    let ms: [String: Double]

    var visible: Bool { score > 0 && outline.count >= 3 }
  }

  /// A picture, encoded: what every tracker following something in it starts from.
  struct Encoded {
    let features: MLMultiArray
    let high0: MLMultiArray
    let high1: MLMultiArray
    let ms: [String: Double]
  }

  /// Draws pictures onto the encoder's canvas and encodes them.
  final class Encoder {
    private let models: Models
    private let context: CIContext
    private var canvas: CVPixelBuffer?
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    init(models: Models? = Models.shared, context: CIContext = CIContext(options: [.cacheIntermediates: false])) throws {
      guard let models else { throw EdgeTAMError.noModels }
      self.models = models
      self.context = context
    }

    /// The picture stretched onto the 1024 x 1024 canvas (as SAM 2 resizes video frames), encoded.
    func encode(_ picture: CIImage) throws -> Encoded {
      var ms: [String: Double] = [:]
      var start = CFAbsoluteTimeGetCurrent()
      let buffer = try draw(picture)
      ms["draw"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
      start = CFAbsoluteTimeGetCurrent()
      let out = try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]))
      ms["encoder"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
      guard let features = out.featureValue(for: "features")?.multiArrayValue,
            let high0 = out.featureValue(for: "high0")?.multiArrayValue,
            let high1 = out.featureValue(for: "high1")?.multiArrayValue else { throw EdgeTAMError.badOutput("encoder") }
      return Encoded(features: features, high0: high0, high1: high1, ms: ms)
    }

    private func draw(_ picture: CIImage) throws -> CVPixelBuffer {
      let e = picture.extent
      guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite else { throw EdgeTAMError.badImage }
      let side = EdgeTAMTracker.side
      if canvas == nil {
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true]
        var created: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &created) == kCVReturnSuccess
        else { throw EdgeTAMError.pixelBuffer }
        canvas = created
      }
      guard let buffer = canvas else { throw EdgeTAMError.pixelBuffer }
      let s = CGFloat(side)
      let sx = s / e.width, sy = s / e.height
      // Lanczos (it filters as it shrinks, like the resize SAM 2 was run with), edges clamped so
      // the border doesn't darken. A CVPixelBuffer's first row is the picture's top.
      let scaled = picture
        .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        .clampedToExtent()
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        .cropped(to: CGRect(x: 0, y: 0, width: s, height: s))
      context.render(scaled, to: buffer, bounds: CGRect(x: 0, y: 0, width: s, height: s), colorSpace: Encoder.srgb)
      return buffer
    }
  }

  private let models: Models
  /// Memories and pointers are kept as the models make them, half precision (raw bits:
  /// tools/edgetam/convert.py's models are float16 throughout), so they go back in without
  /// converting.
  private var cond: (memory: [UInt16], pointer: [UInt16])?
  private var recent: [[UInt16]] = [] // the last six frames' memories, oldest first
  private var pointers: [[UInt16]] = [] // the last fifteen frames' pointers, newest first
  private let memoryIn: MLMultiArray
  private let memoryValid: MLMultiArray
  private let pointersIn: MLMultiArray
  private let pointerValid: MLMultiArray
  private let maskIn: MLMultiArray
  private let binarizeIn: MLMultiArray
  private let boxIn: MLMultiArray
  private static let one: UInt16 = 0x3C00 // 1.0 in half precision

  /// Frames followed since `start`.
  private(set) var frames = 0
  var started: Bool { cond != nil }

  init(models: Models? = Models.shared) throws {
    guard let models else { throw EdgeTAMError.noModels }
    self.models = models
    let n = EdgeTAMTracker.self
    func array(_ shape: [Int]) throws -> MLMultiArray {
      let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float16)
      guard EdgeTAMTracker.contiguous(a) else { throw EdgeTAMError.badOutput("input layout") }
      a.withUnsafeMutableBytes { raw, _ in _ = raw.initializeMemory(as: UInt8.self, repeating: 0) }
      return a
    }
    memoryIn = try array([1, n.numMem * n.memTokens, n.memDim])
    memoryValid = try array([1, n.numMem])
    pointersIn = try array([1, n.numPtrs, n.ptrDim])
    pointerValid = try array([1, n.numPtrs])
    maskIn = try array([1, 1, n.maskSide, n.maskSide])
    binarizeIn = try array([1, 1])
    boxIn = try array([1, 4])
  }

  /// Pins the thing inside `box` (fractions of the picture) and forgets anything followed before.
  func start(_ picture: Encoded, box: CGRect) throws -> Cut {
    var ms = picture.ms
    let (features, high0, high1) = (picture.features, picture.high0, picture.high1)
    let s = CGFloat(EdgeTAMTracker.side)
    let corners = EdgeTAMTracker.halves([box.minX, box.minY, box.maxX, box.maxY].map { Float($0 * s) })
    EdgeTAMTracker.fill(boxIn) { p in
      for i in 0..<4 { p[i] = corners[i] }
    }
    let out = try timed("prompt", &ms) {
      try models.prompt.prediction(from: MLDictionaryFeatureProvider(dictionary: [
        "features": features, "high0": high0, "high1": high1, "box": boxIn,
      ]))
    }
    let heads = try Heads(out, candidates: 1)
    let k = heads.best
    // The pinned frame's mask goes into memory cut hard: what the person saw (parts.py).
    let memory = try remember(features, heads, k, binarize: true, &ms)
    cond = (memory, heads.pointer(k))
    recent = []
    pointers = []
    frames = 1
    return try cut(heads, k, &ms)
  }

  /// The thing in the next picture.
  func step(_ picture: Encoded) throws -> Cut {
    guard let cond else { throw EdgeTAMError.notStarted }
    var ms = picture.ms
    let (features, high0, high1) = (picture.features, picture.high0, picture.high1)
    let n = EdgeTAMTracker.self
    let slot = n.memTokens * n.memDim
    let recent = self.recent, pointers = self.pointers
    // Slot 0 the pinned frame; slot j (1...6) the frame 7 - j ago, so the newest is in slot 6.
    EdgeTAMTracker.fill(memoryIn) { p in
      EdgeTAMTracker.copy(cond.memory, into: p, at: 0)
      for (i, mem) in recent.reversed().enumerated() {
        EdgeTAMTracker.copy(mem, into: p, at: (n.numMem - 1 - i) * slot)
      }
    }
    EdgeTAMTracker.fill(memoryValid) { valid in
      for j in 0..<n.numMem { valid[j] = 0 }
      valid[0] = EdgeTAMTracker.one
      for i in 0..<recent.count { valid[n.numMem - 1 - i] = EdgeTAMTracker.one }
    }
    let used = [cond.pointer] + pointers.prefix(n.numPtrs - 1)
    EdgeTAMTracker.fill(pointersIn) { p in
      for (i, ptr) in used.enumerated() { EdgeTAMTracker.copy(ptr, into: p, at: i * n.ptrDim) }
    }
    EdgeTAMTracker.fill(pointerValid) { valid in
      for i in 0..<n.numPtrs { valid[i] = i < used.count ? EdgeTAMTracker.one : 0 }
    }
    let out = try timed("track", &ms) {
      try models.track.prediction(from: MLDictionaryFeatureProvider(dictionary: [
        "features": features, "high0": high0, "high1": high1,
        "memory": memoryIn, "memory_valid": memoryValid, "pointers_in": pointersIn, "pointer_valid": pointerValid,
      ]))
    }
    let heads = try Heads(out, candidates: 3)
    let k = heads.best
    self.recent.append(try remember(features, heads, k, binarize: false, &ms))
    if self.recent.count > n.numMem - 1 { self.recent.removeFirst() }
    self.pointers.insert(heads.pointer(k), at: 0)
    if self.pointers.count > n.numPtrs - 1 { self.pointers.removeLast() }
    frames += 1
    return try cut(heads, k, &ms)
  }

  // MARK: - Steps

  /// The memory of this frame with candidate `k` as its mask.
  private func remember(_ features: MLMultiArray, _ heads: Heads, _ k: Int, binarize: Bool, _ ms: inout [String: Double]) throws -> [UInt16] {
    let plane = EdgeTAMTracker.maskSide * EdgeTAMTracker.maskSide
    EdgeTAMTracker.fill(maskIn) { p in
      heads.masks.withUnsafeBufferPointer { src in
        _ = p.update(fromContentsOf: UnsafeBufferPointer(rebasing: src[(k * plane)..<((k + 1) * plane)]))
      }
    }
    EdgeTAMTracker.fill(binarizeIn) { p in p[0] = binarize ? EdgeTAMTracker.one : 0 }
    let out = try timed("memory", &ms) {
      try models.memory.prediction(from: MLDictionaryFeatureProvider(dictionary: [
        "features": features, "mask": maskIn, "binarize": binarizeIn,
      ]))
    }
    guard let memory = out.featureValue(for: "memory")?.multiArrayValue else { throw EdgeTAMError.badOutput("memory") }
    let halves = EdgeTAMTracker.halves(memory)
    guard halves.count == EdgeTAMTracker.memTokens * EdgeTAMTracker.memDim else { throw EdgeTAMError.badOutput("memory shape") }
    return halves
  }

  private func cut(_ heads: Heads, _ k: Int, _ ms: inout [String: Double]) throws -> Cut {
    let n = EdgeTAMTracker.maskSide
    let plane = n * n
    let start = CFAbsoluteTimeGetCurrent()
    let logits = heads.masks.withUnsafeBufferPointer {
      EdgeTAMTracker.floats(UnsafeBufferPointer(rebasing: $0[(k * plane)..<((k + 1) * plane)]))
    }
    var outline: [CGPoint] = []
    var area: Float = 0
    if heads.score > 0 {
      let (cells, fraction) = logits.withUnsafeBufferPointer {
        MaskContour.largest($0, offset: 0, stride: n, width: n, height: n)
      }
      area = fraction
      // Cell i's centre is i + 0.5 cells, and the 256 cells span the whole picture. Smoothed along
      // the edge (its points are about a cell apart) so the cells' stair-steps don't shimmer.
      let scale = 1 / CGFloat(n)
      outline = OutlineMath.blurred(cells, sigma: 2).map { CGPoint(x: min(max($0.x * scale, 0), 1), y: min(max($0.y * scale, 0), 1)) }
    }
    ms["outline"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
    return Cut(logits: logits, outline: outline, score: heads.score, iou: heads.ious[k], area: area, ms: ms)
  }

  // MARK: - Helpers

  /// The mask decoder's answer: `candidates` masks (256 x 256 each, half precision), their IoU
  /// estimates, their object pointers (half precision), and whether the thing is there at all.
  private struct Heads {
    let masks: [UInt16]
    let ious: [Float]
    let pointers: [UInt16]
    let score: Float

    init(_ out: MLFeatureProvider, candidates: Int) throws {
      guard let masks = out.featureValue(for: "masks")?.multiArrayValue,
            let ious = out.featureValue(for: "ious")?.multiArrayValue,
            let pointers = out.featureValue(for: "pointers")?.multiArrayValue,
            let score = out.featureValue(for: "score")?.multiArrayValue else { throw EdgeTAMError.badOutput("heads") }
      let n = EdgeTAMTracker.maskSide
      self.masks = EdgeTAMTracker.halves(masks)
      self.ious = EdgeTAMTracker.floats(ious)
      self.pointers = EdgeTAMTracker.halves(pointers)
      self.score = EdgeTAMTracker.floats(score).first ?? -1
      guard self.masks.count == candidates * n * n, self.ious.count == candidates,
            self.pointers.count == candidates * EdgeTAMTracker.ptrDim else { throw EdgeTAMError.badOutput("heads shape") }
    }

    /// The candidate the decoder thinks best (parts.py's `pick`: the first of equals).
    var best: Int {
      var k = 0
      for i in 1..<ious.count where ious[i] > ious[k] { k = i }
      return k
    }

    func pointer(_ k: Int) -> [UInt16] {
      let d = EdgeTAMTracker.ptrDim
      return Array(pointers[(k * d)..<((k + 1) * d)])
    }
  }

  private func timed<T>(_ name: String, _ ms: inout [String: Double], _ body: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let value = try body()
    ms[name, default: 0] += (CFAbsoluteTimeGetCurrent() - start) * 1000
    return value
  }

  // MARK: - Half precision

  /// Row-major with no gaps.
  static func contiguous(_ a: MLMultiArray) -> Bool {
    var expected = 1
    for (dim, stride) in zip(a.shape.reversed(), a.strides.reversed()) {
      if stride.intValue != expected { return false }
      expected *= dim.intValue
    }
    return true
  }

  /// An input array's values as half-precision bits, written by `body`.
  static func fill(_ a: MLMultiArray, _ body: (UnsafeMutableBufferPointer<UInt16>) -> Void) {
    a.withUnsafeMutableBytes { raw, _ in body(raw.bindMemory(to: UInt16.self)) }
  }

  static func copy(_ values: [UInt16], into p: UnsafeMutableBufferPointer<UInt16>, at offset: Int) {
    values.withUnsafeBufferPointer { src in
      _ = UnsafeMutableBufferPointer(rebasing: p[offset..<(offset + src.count)]).update(fromContentsOf: src)
    }
  }

  /// An array's values as half-precision bits (contiguous, row-major), whatever its type or strides.
  static func halves(_ a: MLMultiArray) -> [UInt16] {
    if a.dataType == .float16, contiguous(a) {
      return a.withUnsafeBytes { raw in Array(raw.bindMemory(to: UInt16.self).prefix(a.count)) }
    }
    return halves(floats(a))
  }

  /// A contiguous float32 copy, whatever the array's type or strides.
  static func floats(_ a: MLMultiArray) -> [Float] {
    if contiguous(a) {
      if a.dataType == .float32 {
        return a.withUnsafeBufferPointer(ofType: Float.self) { Array($0.prefix(a.count)) }
      }
      if a.dataType == .float16 {
        return a.withUnsafeBytes { raw in
          floats(UnsafeBufferPointer(rebasing: raw.bindMemory(to: UInt16.self).prefix(a.count)))
        }
      }
    }
    return MLShapedArray<Float>(converting: a).scalars
  }

  /// Half-precision bits to floats (vImage).
  static func floats(_ h: UnsafeBufferPointer<UInt16>) -> [Float] {
    let n = h.count
    var out = [Float](repeating: 0, count: n)
    guard n > 0, let base = h.baseAddress else { return out }
    let (rows, width) = layout(n)
    out.withUnsafeMutableBufferPointer { f in
      var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(rows),
                              width: vImagePixelCount(width), rowBytes: width * 2)
      var dst = vImage_Buffer(data: f.baseAddress!, height: vImagePixelCount(rows), width: vImagePixelCount(width), rowBytes: width * 4)
      _ = vImageConvert_Planar16FtoPlanarF(&src, &dst, vImage_Flags(kvImageNoFlags))
    }
    return out
  }

  /// Floats to half-precision bits (vImage).
  static func halves(_ f: [Float]) -> [UInt16] {
    let n = f.count
    var out = [UInt16](repeating: 0, count: n)
    guard n > 0 else { return out }
    let (rows, width) = layout(n)
    f.withUnsafeBufferPointer { s in
      out.withUnsafeMutableBufferPointer { h in
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s.baseAddress!), height: vImagePixelCount(rows),
                                width: vImagePixelCount(width), rowBytes: width * 4)
        var dst = vImage_Buffer(data: h.baseAddress!, height: vImagePixelCount(rows), width: vImagePixelCount(width), rowBytes: width * 2)
        _ = vImageConvert_PlanarFtoPlanar16F(&src, &dst, vImage_Flags(kvImageNoFlags))
      }
    }
    return out
  }

  /// `n` values as rows of 256 where they divide evenly, else one row.
  private static func layout(_ n: Int) -> (rows: Int, width: Int) {
    n % 256 == 0 ? (n / 256, 256) : (1, n)
  }
}
