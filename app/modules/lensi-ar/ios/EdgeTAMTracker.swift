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
    /// and smoothed along its edge, so it moves smoothly (`plain`), or that edge put on the
    /// picture's own (EdgeSnap, when `snap` is set); fractions of the picture, top-left origin.
    /// Empty when it isn't in view.
    let outline: [CGPoint]
    /// The same region's edge as traced from the mask, unsmoothed, in cells (cell i's centre is
    /// i + 0.5): what `outline` is made from.
    let cells: [CGPoint]
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
    /// The 1024 x 1024 picture it was encoded from (BGRA), for putting a mask's edge on the
    /// picture's own (EdgeSnap). Each encoded picture keeps its own.
    var canvas: CVPixelBuffer? = nil
  }

  /// Draws pictures onto the encoder's canvas and encodes them.
  final class Encoder {
    private let models: Models
    private let context: CIContext
    /// Canvases, one per encoded picture still about (a picture's mask is snapped to it later).
    private var canvases: CVPixelBufferPool?
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
      return Encoded(features: features, high0: high0, high1: high1, ms: ms, canvas: buffer)
    }

    private func draw(_ picture: CIImage) throws -> CVPixelBuffer {
      let e = picture.extent
      guard e.width >= 1, e.height >= 1, e.width.isFinite, e.height.isFinite else { throw EdgeTAMError.badImage }
      let side = EdgeTAMTracker.side
      if canvases == nil {
        let attrs: [CFString: Any] = [
          kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey: side, kCVPixelBufferHeightKey: side,
          kCVPixelBufferIOSurfacePropertiesKey: [String: Any](), kCVPixelBufferMetalCompatibilityKey: true,
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &canvases) == kCVReturnSuccess
        else { throw EdgeTAMError.pixelBuffer }
      }
      var made: CVPixelBuffer?
      guard let pool = canvases, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made) == kCVReturnSuccess,
            let buffer = made else { throw EdgeTAMError.pixelBuffer }
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
    return try cut(heads, k, &ms, canvas: picture.canvas)
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
    return try cut(heads, k, &ms, canvas: picture.canvas)
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

  /// Whether (and how) outlines are put on the picture's own edges (EdgeSnap); nil: the mask's.
  static var snap: EdgeSnap.Settings? = nil

  /// The mask's own outline from its traced edge (`Cut.cells`): cell i's centre is i + 0.5 cells,
  /// and the 256 cells span the whole picture. Smoothed along the edge (its points are about a
  /// cell apart) so the cells' stair-steps don't shimmer.
  static func plain(_ cells: [CGPoint]) -> [CGPoint] {
    let scale = 1 / CGFloat(maskSide)
    return OutlineMath.blurred(cells, sigma: 2).map { CGPoint(x: min(max($0.x * scale, 0), 1), y: min(max($0.y * scale, 0), 1)) }
  }

  private func cut(_ heads: Heads, _ k: Int, _ ms: inout [String: Double], canvas: CVPixelBuffer?) throws -> Cut {
    let n = EdgeTAMTracker.maskSide
    let plane = n * n
    let start = CFAbsoluteTimeGetCurrent()
    let logits = heads.masks.withUnsafeBufferPointer {
      EdgeTAMTracker.floats(UnsafeBufferPointer(rebasing: $0[(k * plane)..<((k + 1) * plane)]))
    }
    var outline: [CGPoint] = []
    var traced: [CGPoint] = []
    var area: Float = 0
    if heads.score > 0 {
      let (cells, fraction) = logits.withUnsafeBufferPointer {
        MaskContour.largest($0, offset: 0, stride: n, width: n, height: n)
      }
      area = fraction
      traced = cells
      outline = EdgeTAMTracker.plain(cells)
      ms["outline"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
      if let snap = EdgeTAMTracker.snap, let canvas, !cells.isEmpty {
        let snapStart = CFAbsoluteTimeGetCurrent()
        if let snapped = EdgeSnap.outline(logits: logits, cells: cells, canvas: canvas, settings: snap) { outline = snapped }
        ms["snap"] = (CFAbsoluteTimeGetCurrent() - snapStart) * 1000
      }
    } else {
      ms["outline"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
    return Cut(logits: logits, outline: outline, cells: traced, score: heads.score, iou: heads.ious[k], area: area, ms: ms)
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

// MARK: - Edge snapping

/// EdgeTAM's mask is 256 x 256 over the whole picture: a cell to every 4 x 4 pixels of the 1024
/// canvas it was made from, and several of the camera's, so the edge traced from it can sit most
/// of a cell off the thing's. Here that edge is moved onto the picture's own: the mask's
/// probabilities are filtered with the picture as the guide (He, Sun & Tang's guided filter, which
/// keeps an edge only where the guide has one), on the canvas round the thing, and traced there
/// at four times the mask's resolution. Where the picture has no edge to offer (a blur, a thing the
/// colour of what's behind it), the mask's own edge stays where it was.
enum EdgeSnap {
  struct Settings {
    /// The filter's window, canvas pixels either side: about a cell.
    var radius = 4
    /// How much contrast (0...1 a channel, squared) the picture needs before the edge follows it.
    var eps: Float = 1e-3
    /// The picture's colours as the guide; false: its brightness only (a third of the work).
    var colour = true
    /// The working grid's longest side: a bigger crop is sampled every second (third...) canvas
    /// pixel, so a thing filling the picture costs what a 512 square does.
    var maxSide = 512
    /// Smoothing along the traced edge, in its points (about a working pixel apart).
    var sigma: CGFloat = 1.5

    static let standard = Settings()
  }

  /// `cells`: the mask's own edge (MaskContour on `logits`, cell units); `logits`: 256 x 256,
  /// row-major; `canvas`: the 1024 x 1024 BGRA picture they were made from. The snapped outline
  /// as fractions of the picture, or nil when there's nothing to trace.
  static func outline(logits: [Float], cells: [CGPoint], canvas: CVPixelBuffer, settings s: Settings = .standard) -> [CGPoint]? {
    let side = EdgeTAMTracker.side, n = EdgeTAMTracker.maskSide, cell = side / n
    guard cells.count >= 3, logits.count == n * n, CVPixelBufferGetWidth(canvas) == side, CVPixelBufferGetHeight(canvas) == side,
          CVPixelBufferGetPixelFormatType(canvas) == kCVPixelFormatType_32BGRA else { return nil }
    // The thing's box on the canvas, with six cells' room for its edge to move.
    var lo = cells[0], hi = cells[0]
    for p in cells {
      lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
      hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
    }
    let margin = 6 * cell, size = CGFloat(cell)
    let x0 = max(0, Int((lo.x * size).rounded(.down)) - margin), x1 = min(side, Int((hi.x * size).rounded(.up)) + margin)
    let y0 = max(0, Int((lo.y * size).rounded(.down)) - margin), y1 = min(side, Int((hi.y * size).rounded(.up)) + margin)
    let step = max(1, (max(x1 - x0, y1 - y0) + s.maxSide - 1) / s.maxSide)
    let w = (x1 - x0) / step, h = (y1 - y0) / step
    let r = max(1, s.radius / step)
    guard w > 2 * r + 2, h > 2 * r + 2 else { return nil }
    let count = w * h

    // The picture, 0...1 a channel: each working pixel the mean of its step x step canvas pixels.
    var red = [Float](repeating: 0, count: count), green = red, blue = red
    guard CVPixelBufferLockBaseAddress(canvas, .readOnly) == kCVReturnSuccess else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(canvas, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(canvas) else { return nil }
    let bytes = base.assumingMemoryBound(to: UInt8.self), rowBytes = CVPixelBufferGetBytesPerRow(canvas)
    let unit = 1 / (255 * Float(step * step))
    red.withUnsafeMutableBufferPointer { rp in
      green.withUnsafeMutableBufferPointer { gp in
        blue.withUnsafeMutableBufferPointer { bp in
          for y in 0..<h {
            for x in 0..<w {
              var sr = 0, sg = 0, sb = 0
              for j in 0..<step {
                let line = bytes + (y0 + y * step + j) * rowBytes + (x0 + x * step) * 4
                for i in 0..<step {
                  sb += Int(line[4 * i]); sg += Int(line[4 * i + 1]); sr += Int(line[4 * i + 2])
                }
              }
              let at = y * w + x
              rp[at] = Float(sr) * unit; gp[at] = Float(sg) * unit; bp[at] = Float(sb) * unit
            }
          }
        }
      }
    }

    // The mask at each working pixel's centre: its logits bilinear between cell centres (cell i's
    // at i + 0.5 cells), squashed to 0...1.
    var p = [Float](repeating: 0, count: count)
    let toCell = Float(step) / Float(cell), last = Float(n - 1)
    logits.withUnsafeBufferPointer { l in
      p.withUnsafeMutableBufferPointer { pp in
        for y in 0..<h {
          let cy = min(max(Float(y0) / Float(cell) + (Float(y) + 0.5) * toCell - 0.5, 0), last)
          let iy = min(Int(cy), n - 2), fy = cy - Float(iy)
          for x in 0..<w {
            let cx = min(max(Float(x0) / Float(cell) + (Float(x) + 0.5) * toCell - 0.5, 0), last)
            let ix = min(Int(cx), n - 2), fx = cx - Float(ix)
            let a = l[iy * n + ix], b = l[iy * n + ix + 1], c = l[(iy + 1) * n + ix], d = l[(iy + 1) * n + ix + 1]
            let v = (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy
            pp[y * w + x] = 1 / (1 + exp(-v))
          }
        }
      }
    }

    var level = s.colour ? guidedColour(red, green, blue, p, w, h, r, s.eps) : guidedGrey(red, green, blue, p, w, h, r, s.eps)
    for i in 0..<count { level[i] -= 0.5 }
    let (pts, _) = level.withUnsafeBufferPointer { MaskContour.largest($0, offset: 0, stride: w, width: w, height: h) }
    guard pts.count >= 3 else { return nil }
    // Working pixel i's centre is (i + 0.5) x step canvas pixels from the crop's corner.
    let k = CGFloat(step) / CGFloat(side), ox = CGFloat(x0) / CGFloat(side), oy = CGFloat(y0) / CGFloat(side)
    return OutlineMath.blurred(pts, sigma: s.sigma).map {
      CGPoint(x: min(max(ox + $0.x * k, 0), 1), y: min(max(oy + $0.y * k, 0), 1))
    }
  }

  /// The guided filter with the picture's brightness as the guide.
  static func guidedGrey(_ r: [Float], _ g: [Float], _ b: [Float], _ p: [Float], _ w: Int, _ h: Int, _ rad: Int, _ eps: Float) -> [Float] {
    let n = w * h
    var guide = [Float](repeating: 0, count: n), gp = guide, gg = guide
    for i in 0..<n {
      let v = 0.299 * r[i] + 0.587 * g[i] + 0.114 * b[i]
      guide[i] = v; gp[i] = v * p[i]; gg[i] = v * v
    }
    let mI = mean(guide, w, h, rad), mp = mean(p, w, h, rad), mIp = mean(gp, w, h, rad), mII = mean(gg, w, h, rad)
    var a = [Float](repeating: 0, count: n), bias = a
    for i in 0..<n {
      let ai = (mIp[i] - mI[i] * mp[i]) / (mII[i] - mI[i] * mI[i] + eps)
      a[i] = ai; bias[i] = mp[i] - ai * mI[i]
    }
    let ma = mean(a, w, h, rad), mb = mean(bias, w, h, rad)
    var q = [Float](repeating: 0, count: n)
    for i in 0..<n { q[i] = ma[i] * guide[i] + mb[i] }
    return q
  }

  /// The guided filter with the picture's colours as the guide (a 3 x 3 covariance a pixel).
  static func guidedColour(_ r: [Float], _ g: [Float], _ b: [Float], _ p: [Float], _ w: Int, _ h: Int, _ rad: Int, _ eps: Float) -> [Float] {
    let n = w * h
    func times(_ x: [Float], _ y: [Float]) -> [Float] {
      var o = [Float](repeating: 0, count: n)
      for i in 0..<n { o[i] = x[i] * y[i] }
      return o
    }
    let mr = mean(r, w, h, rad), mg = mean(g, w, h, rad), mb = mean(b, w, h, rad), mp = mean(p, w, h, rad)
    let mrp = mean(times(r, p), w, h, rad), mgp = mean(times(g, p), w, h, rad), mbp = mean(times(b, p), w, h, rad)
    let mrr = mean(times(r, r), w, h, rad), mrg = mean(times(r, g), w, h, rad), mrb = mean(times(r, b), w, h, rad)
    let mgg = mean(times(g, g), w, h, rad), mgb = mean(times(g, b), w, h, rad), mbb = mean(times(b, b), w, h, rad)
    var ar = [Float](repeating: 0, count: n), ag = ar, ab = ar, bias = ar
    for i in 0..<n {
      let cr = mrp[i] - mr[i] * mp[i], cg = mgp[i] - mg[i] * mp[i], cb = mbp[i] - mb[i] * mp[i]
      let vrr = mrr[i] - mr[i] * mr[i] + eps, vrg = mrg[i] - mr[i] * mg[i], vrb = mrb[i] - mr[i] * mb[i]
      let vgg = mgg[i] - mg[i] * mg[i] + eps, vgb = mgb[i] - mg[i] * mb[i], vbb = mbb[i] - mb[i] * mb[i] + eps
      // The symmetric covariance inverted by its cofactors.
      let i00 = vgg * vbb - vgb * vgb, i01 = vgb * vrb - vrg * vbb, i02 = vrg * vgb - vgg * vrb
      let i11 = vrr * vbb - vrb * vrb, i12 = vrb * vrg - vrr * vgb, i22 = vrr * vgg - vrg * vrg
      let inv = 1 / (vrr * i00 + vrg * i01 + vrb * i02)
      let a0 = (i00 * cr + i01 * cg + i02 * cb) * inv
      let a1 = (i01 * cr + i11 * cg + i12 * cb) * inv
      let a2 = (i02 * cr + i12 * cg + i22 * cb) * inv
      ar[i] = a0; ag[i] = a1; ab[i] = a2
      bias[i] = mp[i] - a0 * mr[i] - a1 * mg[i] - a2 * mb[i]
    }
    let mar = mean(ar, w, h, rad), mag = mean(ag, w, h, rad), mab = mean(ab, w, h, rad), mbias = mean(bias, w, h, rad)
    var q = [Float](repeating: 0, count: n)
    for i in 0..<n { q[i] = mar[i] * r[i] + mag[i] * g[i] + mab[i] * b[i] + mbias[i] }
    return q
  }

  /// The mean over the (2 rad + 1)-pixel square round each pixel, the square cut at the edges
  /// (running sums along the rows, then down the columns).
  static func mean(_ a: [Float], _ w: Int, _ h: Int, _ rad: Int) -> [Float] {
    var rows = [Float](repeating: 0, count: w * h)
    var out = rows
    a.withUnsafeBufferPointer { src in
      rows.withUnsafeMutableBufferPointer { dst in
        for y in 0..<h {
          let o = y * w
          var sum: Float = 0
          for x in 0..<min(rad, w) { sum += src[o + x] }
          for x in 0..<w {
            if x + rad < w { sum += src[o + x + rad] }
            if x - rad - 1 >= 0 { sum -= src[o + x - rad - 1] }
            dst[o + x] = sum / Float(min(w - 1, x + rad) - max(0, x - rad) + 1)
          }
        }
      }
    }
    var sums = [Float](repeating: 0, count: w)
    rows.withUnsafeBufferPointer { src in
      out.withUnsafeMutableBufferPointer { dst in
        sums.withUnsafeMutableBufferPointer { sum in
          for y in 0..<min(rad, h) {
            for x in 0..<w { sum[x] += src[y * w + x] }
          }
          for y in 0..<h {
            if y + rad < h {
              let o = (y + rad) * w
              for x in 0..<w { sum[x] += src[o + x] }
            }
            if y - rad - 1 >= 0 {
              let o = (y - rad - 1) * w
              for x in 0..<w { sum[x] -= src[o + x] }
            }
            let inv = 1 / Float(min(h - 1, y + rad) - max(0, y - rad) + 1)
            let o = y * w
            for x in 0..<w { dst[o + x] = sum[x] * inv }
          }
        }
      }
    }
    return out
  }
}
