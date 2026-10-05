// Live SAM on real footage, the app's code end to end (SAMSegmenter, LiveTracker,
// OutlineMath) over a folder of frames, the way the phone runs it, with no ARKit:
//
//   fixed      SAM asked at the same spot every frame, where the thing was at the start
//              (what a prompt pinned in place does when the thing moves)
//   tracked    SAM asked where the thing should be now (LiveTracker), cuts as they come
//   lensi      tracked and steadied (OutlineMath.steady), SAM on every frame
//   coast@8    the same with SAM on every third frame (8 a second at 24 fps, about what a
//              phone manages); in between, the outline coasts at its last cut's speed
//              (what the app did before LiveFlow)
//   flow@8     in between, carried on its own pixels instead (LiveFlow: points inside it
//              followed frame to frame, their median motion, turn and scale)
//   loose@8    flow@8, and what's shown eased onto each new cut (three quarters of the way
//              a frame, 30 ms) instead of jumping, any plausible cut taken
//   lensi@8    the same, SAM asked by how fast the thing moves (LiveTracker.asking: strict
//              for a still thing, loose for a moving one): what the phone draws
//   strict@8   loose@8 with SAM asked within a tighter box and only a close match taken
//              (LiveTracker.Gate.strict, which tools/pin's ARKit recordings called for)
//   coast@4, lensi@4: SAM on every sixth frame (a hot phone, a guide part waiting its turn)
//   edgetam    the app's pinned things now: EdgeTAM (EdgeTAMTracker, Meta's on-device SAM 2)
//              from its memory of the thing, started from the seed box, every frame; what's
//              shown glides from one outline to the next (OutlineMath.glide)
//   edgetam@8  the same on every third frame, carried on its own pixels in between (the flow)
//   (both only with the EdgeTAM models in LENSI_MODELS_DIR)
//
// With hand-drawn masks for every frame (DAVIS), each frame is scored: J (IoU with the mask),
// wobble (how much the outline's shape changes from one frame to the next) and jerk (how much
// its middle lurches rather than glides), each with the mask's own for reference. Writes
// <out>/<name>.json for tools/track/render.py.
//
//   swiftc -O -o track tools/track/main.swift app/modules/lensi-ar/ios/{SAMSegmenter,OutlineMath,LiveTracker,LiveFlow,Analyzer,Detector}.swift
//   LENSI_MODELS_DIR=<models> ./track <frames dir> <masks dir or -> <out dir> <name> [x,y,w,h seed box, 0-1]
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import Vision

let args = CommandLine.arguments
guard args.count >= 5 else {
  print("usage: track <frames dir> <masks dir or -> <out dir> <name> [seed box x,y,w,h]")
  exit(2)
}
let framesDir = URL(fileURLWithPath: args[1])
let masksDir: URL? = args[2] == "-" ? nil : URL(fileURLWithPath: args[2])
let outDir = URL(fileURLWithPath: args[3])
let name = args[4]
let seedArg: CGRect? = args.count > 5 ? {
  let v = args[5].split(separator: ",").compactMap { Double($0) }
  return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
}() : nil
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard let sam = SAMSegmenter.shared else {
  print("SAM models not found")
  exit(1)
}

func listing(_ dir: URL, _ ext: Set<String>) -> [URL] {
  ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    .filter { ext.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

func load(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// A hand-drawn mask as 0/1 bytes, object 1 only (DAVIS draws object 1 in RGB 128,0,0).
func groundTruth(_ url: URL) -> (bits: [UInt8], w: Int, h: Int)? {
  guard let img = load(url) else { return nil }
  let w = img.width, h = img.height
  var rgba = [UInt8](repeating: 0, count: w * h * 4)
  let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  guard ok else { return nil }
  var bits = [UInt8](repeating: 0, count: w * h)
  for i in 0..<(w * h) where rgba[i * 4] > 90 && rgba[i * 4 + 1] < 60 && rgba[i * 4 + 2] < 60 { bits[i] = 1 }
  return (bits, w, h)
}

/// A polygon (0-1) filled into a w x h 0/1 mask.
func raster(_ poly: [CGPoint], w: Int, h: Int) -> [UInt8] {
  var bits = [UInt8](repeating: 0, count: w * h)
  guard poly.count > 2 else { return bits }
  bits.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
    // Row 0 of the buffer is the top of the image.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.move(to: CGPoint(x: poly[0].x * CGFloat(w), y: poly[0].y * CGFloat(h)))
    for p in poly.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * CGFloat(w), y: p.y * CGFloat(h))) }
    ctx.closePath()
    ctx.fillPath()
  }
  return bits.map { $0 > 127 ? 1 : 0 }
}

func maskIoU(_ a: [UInt8], _ b: [UInt8]) -> Double {
  var inter = 0, union = 0
  for i in 0..<min(a.count, b.count) {
    if a[i] != 0 && b[i] != 0 { inter += 1 }
    if a[i] != 0 || b[i] != 0 { union += 1 }
  }
  return union == 0 ? 1 : Double(inter) / Double(union)
}

func maskCentre(_ m: [UInt8], w: Int) -> (Double, Double, Int) {
  var sx = 0.0, sy = 0.0, n = 0
  for i in 0..<m.count where m[i] != 0 {
    sx += Double(i % w); sy += Double(i / w); n += 1
  }
  return n == 0 ? (0, 0, 0) : (sx / Double(n), sy / Double(n), n)
}

/// How much a mask's shape changed from the last frame: 1 - IoU with the last one moved onto it.
func maskWobble(_ prev: [UInt8], _ cur: [UInt8], w: Int, h: Int) -> Double {
  let (px, py, pn) = maskCentre(prev, w: w), (cx, cy, cn) = maskCentre(cur, w: w)
  guard pn > 0, cn > 0 else { return 0 }
  let dx = Int((cx - px).rounded()), dy = Int((cy - py).rounded())
  var moved = [UInt8](repeating: 0, count: w * h)
  for i in 0..<prev.count where prev[i] != 0 {
    let x = i % w + dx, y = i / w + dy
    if x >= 0, x < w, y >= 0, y < h { moved[y * w + x] = 1 }
  }
  return 1 - maskIoU(moved, cur)
}

/// The seed: a box and a point well inside the thing, from the first frame's mask.
func seed(from m: [UInt8], w: Int, h: Int) -> (CGRect, CGPoint)? {
  var x0 = w, y0 = h, x1 = -1, y1 = -1
  for i in 0..<m.count where m[i] != 0 {
    x0 = min(x0, i % w); x1 = max(x1, i % w); y0 = min(y0, i / w); y1 = max(y1, i / w)
  }
  guard x1 >= x0, y1 >= y0 else { return nil }
  // Chamfer distance to the background: the deepest pixel is the point.
  var d = m.map { $0 != 0 ? Int.max / 4 : 0 }
  for y in 0..<h { for x in 0..<w where d[y * w + x] > 0 {
    var v = d[y * w + x]
    if x > 0 { v = min(v, d[y * w + x - 1] + 3) }
    if y > 0 { v = min(v, d[(y - 1) * w + x] + 3) }
    d[y * w + x] = v
  } }
  var best = (0, x0, y0)
  for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) where d[y * w + x] > 0 {
    var v = d[y * w + x]
    if x < w - 1 { v = min(v, d[y * w + x + 1] + 3) }
    if y < h - 1 { v = min(v, d[(y + 1) * w + x] + 3) }
    d[y * w + x] = v
    if v > best.0 { best = (v, x, y) }
  } }
  let box = CGRect(x: Double(x0) / Double(w), y: Double(y0) / Double(h),
                   width: Double(x1 - x0 + 1) / Double(w), height: Double(y1 - y0 + 1) / Double(h))
  return (box, CGPoint(x: (Double(best.1) + 0.5) / Double(w), y: (Double(best.2) + 0.5) / Double(h)))
}

/// Vision's box tracker, run on every frame: between SAM's frames it says how the thing's box
/// moved and grew, and the outline is carried along with it (instead of at constant speed).
final class BoxFollower {
  private var request: VNTrackObjectRequest?
  private let handler = VNSequenceRequestHandler()
  private(set) var box: CGRect?

  /// Start (again) from `box` (0-1, top-left origin).
  func reset(_ box: CGRect) {
    let r = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(
      boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
    r.trackingLevel = .fast
    request = r
    self.box = box
  }

  /// The box in this frame, nil when Vision has lost it.
  func track(_ image: CGImage) -> CGRect? {
    guard let request else { return nil }
    do {
      try handler.perform([request], on: image)
    } catch {
      return nil
    }
    guard let o = request.results?.first as? VNDetectedObjectObservation, o.confidence > 0.3 else { return nil }
    request.inputObservation = o
    let b = o.boundingBox
    box = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    return box
  }
}

/// The app's LiveFlow fed frame by frame: each frame as LiveFlow sees it (grey, 360 across),
/// shared by every runner that carries its outline from the last frame to this one.
final class PixelFlow {
  private var previous: LiveFlow.Frame?
  private(set) var current: LiveFlow.Frame?
  /// Milliseconds to make each frame, and for each carry.
  var frameMs: [Double] = []
  var carryMs: [Double] = []

  func feed(_ image: CGImage) {
    let t0 = Date()
    previous = current
    current = LiveFlow.frame(image)
    frameMs.append(Date().timeIntervalSince(t0) * 1000)
  }

  /// `outline` (last frame) carried to this one, as the app carries it.
  func carry(_ outline: [CGPoint], scaling: Bool) -> [CGPoint]? {
    guard let previous, let current else { return nil }
    let t0 = Date()
    defer { carryMs.append(Date().timeIntervalSince(t0) * 1000) }
    return LiveFlow.carry(outline, from: previous, to: current, scaling: scaling, turning: scaling)
  }
}

/// One way of keeping an outline on the thing, run frame by frame.
class Runner {
  let label: String
  let tracking: Bool
  let smoothing: OutlineMath.Smoothing?
  let every: Int
  /// Smooth with `OutlineMath.steady` (real change passes) rather than `smooth`.
  let adaptive: Bool
  var lastChange: [simd_float3]?
  /// Carry the outline between SAM's frames with Vision's box tracker.
  let follower: BoxFollower?
  /// Only move it with the box (its size is noisy); otherwise move and scale.
  let moveOnly: Bool
  /// Carry the outline from each frame to the next on its own pixels (optical flow), and
  /// with `scaling` let it grow and shrink with them.
  let flow: PixelFlow?
  let scaling: Bool
  /// Ease what's shown this much of the way to the outline each frame, rather than jumping
  /// when SAM's cut lands (what's shown rides the flow too, so it doesn't lag the motion).
  let glide: CGFloat?
  /// How SAM is asked (LiveTracker.prompt's box growth) and which cuts are taken.
  let grow: CGFloat
  let gate: LiveTracker.Gate
  /// Ask as the app does, by how fast the thing moves (LiveTracker.asking). With no ARKit
  /// here the camera's motion is in it too: its speed in the picture stands in.
  let bySpeed: Bool
  /// How far its middle moves a frame, in pixels, steadied.
  var speedPx: CGFloat = 0
  /// Ease a small correction (edge noise) more than a big one (it's really somewhere else):
  /// the share taken each frame grows with how far off what's shown is, for its size.
  let adaptiveGlide: Bool
  var display: [CGPoint]?
  /// The outline as SAM last left it, and its box then (what the follower's box is compared to).
  var anchorOutline: [CGPoint]?
  var anchorBox: CGRect?
  var outline: [CGPoint]?
  var velocity = CGPoint.zero // per frame, 0-1 units
  var lastFrame = 0
  var misses = 0
  var cuts = 0
  var refused = 0
  var shown: [[CGPoint]] = []
  var j: [Double] = []
  var wobble: [Double] = []
  /// Where what's shown sits each frame (its filled middle, in pixels), for how smoothly it moves.
  var centres: [CGPoint?] = []

  init(_ label: String, tracking: Bool, smoothing: OutlineMath.Smoothing?, every: Int, follow: Bool = false, adaptive: Bool = false,
       moveOnly: Bool = false, flow: PixelFlow? = nil, scaling: Bool = false, glide: CGFloat? = nil, adaptiveGlide: Bool = false,
       grow: CGFloat = LiveTracker.grow, gate: LiveTracker.Gate = .loose, bySpeed: Bool = false) {
    self.moveOnly = moveOnly
    self.label = label
    self.tracking = tracking
    self.smoothing = smoothing
    self.every = every
    self.adaptive = adaptive
    follower = follow ? BoxFollower() : nil
    self.flow = flow
    self.scaling = scaling
    self.glide = glide
    self.adaptiveGlide = adaptiveGlide
    self.grow = grow
    self.gate = gate
    self.bySpeed = bySpeed
  }

  /// Where the outline is expected at frame f: the last one carried along by its motion
  /// (by Vision's box tracker when there is one and it still has the thing).
  func predicted(at f: Int) -> [CGPoint]? {
    guard let outline else { return nil }
    if let follower, let a = anchorBox, let b = follower.box, let from = anchorOutline, a.width > 0, a.height > 0 {
      if moveOnly {
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        return from.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
      }
      return from.map {
        CGPoint(x: b.minX + ($0.x - a.minX) * b.width / a.width, y: b.minY + ($0.y - a.minY) * b.height / a.height)
      }
    }
    let k = CGFloat(f - lastFrame)
    return outline.map { CGPoint(x: $0.x + velocity.x * k, y: $0.y + velocity.y * k) }
  }

  func centre(_ p: [CGPoint]) -> CGPoint {
    CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
  }

  /// Frame f: maybe ask SAM (on this runner's beat), then say what's shown.
  func step(_ f: Int, image: CGImage, sam: SAMSegmenter, scale: CGSize, seedBox: CGRect, seedPoint: CGPoint) throws -> [CGPoint]? {
    try stepSAM(f, image: image, sam: sam, scale: scale, seedBox: seedBox, seedPoint: seedPoint)
  }

  final func stepSAM(_ f: Int, image: CGImage, sam: SAMSegmenter, scale: CGSize, seedBox: CGRect, seedPoint: CGPoint) throws -> [CGPoint]? {
    // The box tracker sees every frame, as it would on the phone.
    if let follower, follower.box != nil, f > 0, follower.track(image) == nil { anchorBox = nil }
    // So does the flow: the outline (and what's shown) move with the thing's pixels.
    if let flow, f > 0, let o = outline, let carried = flow.carry(o, scaling: scaling) {
      let a = centre(o), b = centre(carried)
      speedPx = speedPx * 0.7 + hypot((b.x - a.x) * scale.width, (b.y - a.y) * scale.height) * 0.3
      outline = carried
      lastFrame = f
      if let d = display { display = flow.carry(d, scaling: scaling) ?? carried }
    }
    if f % every == 0 {
      let prediction = predicted(at: f)
      var points = [seedPoint]
      var box: CGRect? = seedBox
      var grow = self.grow, gate = self.gate, how = smoothing
      if bySpeed, let prediction {
        // Its speed in its own sizes a second (24 fps footage).
        let c = centre(prediction)
        let size = (prediction.map { pow(($0.x - c.x) * scale.width, 2) + pow(($0.y - c.y) * scale.height, 2) }
          .reduce(0, +) / CGFloat(prediction.count)).squareRoot()
        let perFrame = flow != nil ? speedPx : hypot(velocity.x * scale.width, velocity.y * scale.height)
        let asking = LiveTracker.asking(sizesPerSecond: perFrame * 24 / max(size, 1))
        grow = asking.grow
        gate = asking.gate
        how = asking.smoothing
      }
      if tracking, let prediction, let p = LiveTracker.prompt(for: prediction, scale: scale, grow: grow) {
        points = [p.point]
        box = p.box
      }
      // As the app asks: following, the candidate that overlaps where it should be wins.
      let mask = try sam.segment(id: "frame", points: points, labels: [1], box: box, prior: tracking ? prediction : nil)
      cuts += 1
      var cut = mask.polygon.count > 2 && mask.score >= 0.5 ? OutlineMath.resample(mask.polygon, scale: scale) : nil
      if tracking, let c = cut, let prediction {
        // As the app takes it (LensiARView.segmentLive): up close, the whole outline goes where
        // the part on the picture went.
        cut = LiveTracker.follow(cut: c, predicted: prediction, gate: gate)
        if cut == nil { refused += 1 }
      }
      if let c = cut {
        var next = c
        if let smoothing = how, let prediction {
          let px = { (p: CGPoint) in simd_float3(Float(p.x * scale.width), Float(p.y * scale.height), 0) }
          let blended: [simd_float3]
          if adaptive {
            let r = OutlineMath.steady(prediction.map(px), c.map(px), previous: lastChange, smoothing)
            blended = r.outline
            lastChange = r.change
          } else {
            blended = OutlineMath.smooth(prediction.map(px), c.map(px), smoothing)
          }
          next = blended.map { CGPoint(x: CGFloat($0.x) / scale.width, y: CGFloat($0.y) / scale.height) }
        }
        if let old = outline, f > lastFrame {
          // The thing's own motion, a frame's worth, steadied.
          let a = centre(old), b = centre(next)
          let k = CGFloat(f - lastFrame)
          let v = CGPoint(x: (b.x - a.x) / k, y: (b.y - a.y) / k)
          velocity = CGPoint(x: velocity.x * 0.4 + v.x * 0.6, y: velocity.y * 0.4 + v.y * 0.6)
        }
        outline = next
        lastFrame = f
        misses = 0
        if let follower {
          let b = LiveTracker.bounds(next)
          follower.reset(b)
          anchorBox = b
          anchorOutline = next
        }
      } else {
        // Nothing usable: keep showing where it should be, and slow down.
        if let prediction { outline = prediction }
        lastFrame = f
        velocity = CGPoint(x: velocity.x * 0.5, y: velocity.y * 0.5)
        misses += 1
        if misses > 6 { outline = nil }
      }
    }
    let now = predicted(at: f)
    guard let glide, let now else { return now }
    display = eased(display, toward: now, by: glide, scale: scale)
    return display
  }

  /// `shown` moved `k` of the way to `target`, point for point once they're lined up; a
  /// target more than its own size away is jumped to.
  func eased(_ shown: [CGPoint]?, toward target: [CGPoint], by k: CGFloat, scale: CGSize) -> [CGPoint] {
    guard let shown, shown.count == target.count else { return target }
    let px = { (p: CGPoint) in simd_float3(Float(p.x * scale.width), Float(p.y * scale.height), 0) }
    let a = shown.map(px), b = target.map(px)
    let size = max(OutlineMath.spread(b), 1e-6)
    guard simd_distance(OutlineMath.centre(a), OutlineMath.centre(b)) < size else { return target }
    let lined = OutlineMath.align(b, to: a).points
    var share = Float(k)
    if adaptiveGlide {
      let off = (zip(a, lined).reduce(Float(0)) { $0 + simd_distance_squared($1.0, $1.1) } / Float(a.count)).squareRoot()
      share = min(1, share + 2.5 * off / size)
    }
    return zip(a, lined).map { s, t in
      let p = s + (t - s) * share
      return CGPoint(x: CGFloat(p.x) / scale.width, y: CGFloat(p.y) / scale.height)
    }
  }
}

/// How much something's middle lurches from frame to frame: the mean size, in pixels, of its
/// second difference (a steady glide is 0, however fast; a stop-and-jump is not).
func jerk(_ c: [CGPoint?]) -> Double {
  var sum = 0.0, n = 0
  for i in 2..<max(c.count, 2) {
    guard let a = c[i - 2], let b = c[i - 1], let d = c[i] else { continue }
    sum += Double(hypot(d.x - 2 * b.x + a.x, d.y - 2 * b.y + a.y))
    n += 1
  }
  return n == 0 ? -1 : sum / Double(n)
}

let frames = listing(framesDir, ["jpg", "jpeg", "png"])
let masks = masksDir.map { listing($0, ["png"]) } ?? []
guard let first = frames.first.flatMap(load) else {
  print("\(name): no frames")
  exit(1)
}
let W = first.width, H = first.height
let scale = CGSize(width: W, height: H)
var seedBox: CGRect
var seedPoint: CGPoint
var truth0: [UInt8]?
if let m0 = masks.first.flatMap(groundTruth), m0.w == W, m0.h == H, let s = seed(from: m0.bits, w: W, h: H) {
  (seedBox, seedPoint) = s
  truth0 = m0.bits
} else if let box = seedArg {
  seedBox = box
  seedPoint = CGPoint(x: box.midX, y: box.midY)
} else {
  print("\(name): no mask for frame 0 and no seed box")
  exit(1)
}
print("\(name): \(frames.count) frames \(W)x\(H), seed box \(seedBox), point \(seedPoint), masks \(masks.count)")

// The app's own setting is OutlineMath.Smoothing.standard ("lensi"); the others are measured
// next to it so it can be chosen on real footage rather than guessed. @8 is SAM on every third
// frame (8 a second at 24 fps, about what a phone manages); @4 every sixth (a hot phone, or a
// guide part waiting its turn).
/// The frame EdgeTAM's encoder made, for every EdgeTAM runner that looks at this frame.
var edgeFrame: EdgeTAMTracker.Encoded?

/// The app's pinned things now (LensiARView.followEdge): EdgeTAM from its memory of the thing,
/// every `every`-th frame; in between, the outline rides its own pixels (the flow); each new
/// outline glides into the last (OutlineMath.glide, in pixels).
final class EdgeRunner: Runner {
  let tracker: EdgeTAMTracker

  init(_ label: String, every: Int, flow: PixelFlow?, tracker: EdgeTAMTracker) {
    self.tracker = tracker
    super.init(label, tracking: true, smoothing: nil, every: every, flow: flow, scaling: true)
  }

  override func step(_ f: Int, image: CGImage, sam: SAMSegmenter, scale: CGSize, seedBox: CGRect, seedPoint: CGPoint) throws -> [CGPoint]? {
    let looks = f == 0 || f % every == 0
    if looks, let picture = edgeFrame {
      let cut = try f == 0 ? tracker.start(picture, box: seedBox) : tracker.step(picture)
      cuts += 1
      if cut.visible {
        let px = { (p: CGPoint) in simd_float3(Float(p.x * scale.width), Float(p.y * scale.height), 0) }
        let ring = OutlineMath.resample(cut.outline, scale: scale).map(px)
        outline = OutlineMath.glide(outline?.map(px), ring).map { CGPoint(x: CGFloat($0.x) / scale.width, y: CGFloat($0.y) / scale.height) }
      } else {
        outline = nil
      }
    } else if let flow, let o = outline, let carried = flow.carry(o, scaling: scaling) {
      outline = carried
    }
    return outline
  }
}

let flow = PixelFlow()
let edgeModels = EdgeTAMTracker.Models.shared
let edgeEncoder = edgeModels.flatMap { try? EdgeTAMTracker.Encoder(models: $0) }
let runners = [
  Runner("fixed", tracking: false, smoothing: nil, every: 1),
  Runner("tracked", tracking: true, smoothing: nil, every: 1),
  Runner("lensi", tracking: true, smoothing: .standard, every: 1, adaptive: true),
  Runner("coast@8", tracking: true, smoothing: .standard, every: 3, adaptive: true),
  Runner("flow@8", tracking: true, smoothing: .standard, every: 3, adaptive: true, flow: flow, scaling: true),
  Runner("loose@8", tracking: true, smoothing: .standard, every: 3, adaptive: true, flow: flow, scaling: true, glide: 0.75),
  Runner("strict@8", tracking: true, smoothing: .standard, every: 3, adaptive: true, flow: flow, scaling: true, glide: 0.75,
         grow: 0.1, gate: .strict),
  Runner("lensi@8", tracking: true, smoothing: .standard, every: 3, adaptive: true, flow: flow, scaling: true, glide: 0.75,
         bySpeed: true),
  Runner("coast@4", tracking: true, smoothing: .standard, every: 6, adaptive: true),
  Runner("lensi@4", tracking: true, smoothing: .standard, every: 6, adaptive: true, flow: flow, scaling: true, glide: 0.75,
         bySpeed: true),
] + (edgeModels.flatMap { models -> [Runner]? in
  guard let a = try? EdgeTAMTracker(models: models), let b = try? EdgeTAMTracker(models: models) else { return nil }
  return [EdgeRunner("edgetam", every: 1, flow: flow, tracker: a), EdgeRunner("edgetam@8", every: 3, flow: flow, tracker: b)]
} ?? [])
var truthWobble: [Double] = []
var truthCentres: [CGPoint?] = []
var prevTruth = truth0
var encodeMs: [Double] = []
var frameNames: [String] = []

for (f, url) in frames.enumerated() {
  guard let image = load(url) else { continue }
  frameNames.append(url.lastPathComponent)
  let t0 = Date()
  try sam.prepare(image: image, id: "frame", force: true)
  encodeMs.append(Date().timeIntervalSince(t0) * 1000)
  flow.feed(image)
  // EdgeTAM's encoder once a frame, for its runners (the one on every frame looks at all).
  edgeFrame = edgeEncoder.flatMap { try? $0.encode(CIImage(cgImage: image)) }
  let truth = f < masks.count ? groundTruth(masks[f]) : nil
  for r in runners {
    let shown = try r.step(f, image: image, sam: sam, scale: scale, seedBox: seedBox, seedPoint: seedPoint) ?? []
    r.shown.append(shown)
    let filled = raster(shown, w: W, h: H)
    let (cx, cy, n) = maskCentre(filled, w: W)
    r.centres.append(n > 0 ? CGPoint(x: cx, y: cy) : nil)
    if let truth, truth.w == W {
      r.j.append(maskIoU(filled, truth.bits))
    }
    if r.shown.count > 1, let prev = r.shown.dropLast().last, prev.count > 2, shown.count > 2 {
      let cp = r.centre(prev), cs = r.centre(shown)
      let a = prev.map { CGPoint(x: $0.x - cp.x, y: $0.y - cp.y) }
      let b = shown.map { CGPoint(x: $0.x - cs.x, y: $0.y - cs.y) }
      r.wobble.append(Double(1 - LiveTracker.iou(a, b, grid: 96)))
    }
  }
  if let truth, truth.w == W {
    if let p = prevTruth, f > 0 { truthWobble.append(maskWobble(p, truth.bits, w: W, h: H)) }
    prevTruth = truth.bits
    let (cx, cy, n) = maskCentre(truth.bits, w: W)
    truthCentres.append(n > 0 ? CGPoint(x: cx, y: cy) : nil)
  }
}

/// -1 when there's nothing to average (JSON has no NaN).
func mean(_ x: [Double]) -> Double { x.isEmpty ? -1 : x.reduce(0, +) / Double(x.count) }
func pct(_ x: Double) -> String { x < 0 ? "-" : String(format: "%.1f%%", x * 100) }
func px(_ x: Double) -> String { x < 0 ? "-" : String(format: "%.1fpx", x) }

var summary: [String: Any] = [
  "name": name, "frames": frameNames.count, "width": W, "height": H,
  "encodeMs": mean(encodeMs), "flowFrameMs": mean(flow.frameMs), "flowCarryMs": mean(flow.carryMs), "truthWobble": mean(truthWobble), "truthJerk": jerk(truthCentres),
  "seedBox": [seedBox.minX, seedBox.minY, seedBox.width, seedBox.height], "seedPoint": [seedPoint.x, seedPoint.y],
]
var lines: [String] = []
var runs: [[String: Any]] = []
for r in runners {
  runs.append([
    "label": r.label, "every": r.every, "J": mean(r.j), "wobble": mean(r.wobble), "jerk": jerk(r.centres), "cuts": r.cuts, "refused": r.refused,
    "jPerFrame": r.j, "outlines": r.shown.map { $0.flatMap { [Double($0.x), Double($0.y)] } },
  ])
  let label = r.label.padding(toLength: 10, withPad: " ", startingAt: 0)
  lines.append("  \(label) J \(pct(mean(r.j)))  wobble \(pct(mean(r.wobble)))  jerk \(px(jerk(r.centres)))  (\(r.cuts) cuts, \(r.refused) refused)")
}
summary["runs"] = runs
summary["frameNames"] = frameNames
print("\(name): encode \(Int(mean(encodeMs))) ms a frame; flow \(String(format: "%.1f", mean(flow.frameMs))) ms a frame + \(String(format: "%.1f", mean(flow.carryMs))) ms a carry; the mask's own wobble \(pct(mean(truthWobble))), jerk \(px(jerk(truthCentres)))")
lines.forEach { print($0) }
let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
try data.write(to: outDir.appendingPathComponent("\(name).json"))
