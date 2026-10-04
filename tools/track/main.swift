// Live SAM on real footage, the app's code end to end (SAMSegmenter, LiveTracker,
// OutlineMath) over a folder of frames, the way the phone runs it, with no ARKit:
//
//   fixed      SAM asked at the same spot every frame, where the thing was at the start
//              (what a prompt pinned in place does when the thing moves)
//   tracked    SAM asked where the thing should be now (LiveTracker), cuts as they come
//   lensi      tracked, and blended (OutlineMath.smooth): what the phone draws
//   lensi@8    the same with SAM on every third frame (8 a second at 24 fps, about what a
//              phone manages); in between, the outline is carried along by its own motion
//
// With hand-drawn masks for every frame (DAVIS), each frame is scored: J (IoU with the mask)
// and wobble (how much the outline's shape changes from one frame to the next, the mask's
// own change for reference). Writes <out>/<name>.json for tools/track/render.py.
//
//   swiftc -O -o track tools/track/main.swift app/modules/lensi-ar/ios/{SAMSegmenter,OutlineMath,LiveTracker,Analyzer,Detector}.swift
//   LENSI_MODELS_DIR=<models> ./track <frames dir> <masks dir or -> <out dir> <name> [x,y,w,h seed box, 0-1]
import CoreGraphics
import Foundation
import ImageIO
import simd

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

/// One way of keeping an outline on the thing, run frame by frame.
final class Runner {
  let label: String
  let tracking: Bool
  let smoothing: OutlineMath.Smoothing?
  let every: Int
  var outline: [CGPoint]?
  var velocity = CGPoint.zero // per frame, 0-1 units
  var lastFrame = 0
  var misses = 0
  var cuts = 0
  var refused = 0
  var shown: [[CGPoint]] = []
  var j: [Double] = []
  var wobble: [Double] = []

  init(_ label: String, tracking: Bool, smoothing: OutlineMath.Smoothing?, every: Int) {
    self.label = label
    self.tracking = tracking
    self.smoothing = smoothing
    self.every = every
  }

  /// Where the outline is expected at frame f: the last one carried along by its motion.
  func predicted(at f: Int) -> [CGPoint]? {
    guard let outline else { return nil }
    let k = CGFloat(f - lastFrame)
    return outline.map { CGPoint(x: $0.x + velocity.x * k, y: $0.y + velocity.y * k) }
  }

  func centre(_ p: [CGPoint]) -> CGPoint {
    CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
  }

  /// Frame f: maybe ask SAM (on this runner's beat), then say what's shown.
  func step(_ f: Int, sam: SAMSegmenter, scale: CGSize, seedBox: CGRect, seedPoint: CGPoint) throws -> [CGPoint]? {
    if f % every == 0 {
      let prediction = predicted(at: f)
      var points = [seedPoint]
      var box: CGRect? = seedBox
      if tracking, let prediction, let p = LiveTracker.prompt(for: prediction, scale: scale) {
        points = [p.point]
        box = p.box
      }
      let mask = try sam.segment(id: "frame", points: points, labels: [1], box: box)
      cuts += 1
      var cut = mask.polygon.count > 2 && mask.score >= 0.5 ? OutlineMath.resample(mask.polygon, scale: scale) : nil
      if tracking, let c = cut, let prediction, !LiveTracker.accepts(c, predicted: prediction) {
        cut = nil
        refused += 1
      }
      if let c = cut {
        var next = c
        if let smoothing, let prediction {
          let px = { (p: CGPoint) in simd_float3(Float(p.x * scale.width), Float(p.y * scale.height), 0) }
          let blended = OutlineMath.smooth(prediction.map(px), c.map(px), smoothing)
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
      } else {
        // Nothing usable: keep showing where it should be, and slow down.
        if let prediction { outline = prediction }
        lastFrame = f
        velocity = CGPoint(x: velocity.x * 0.5, y: velocity.y * 0.5)
        misses += 1
        if misses > 6 { outline = nil }
      }
    }
    return predicted(at: f)
  }
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
// next to it so it can be chosen on real footage rather than guessed.
let runners = [
  Runner("fixed", tracking: false, smoothing: nil, every: 1),
  Runner("tracked", tracking: true, smoothing: nil, every: 1),
  Runner("lensi", tracking: true, smoothing: .standard, every: 1),
  Runner("light", tracking: true, smoothing: .light, every: 1),
  Runner("minimal", tracking: true, smoothing: .minimal, every: 1),
  Runner("tracked@8", tracking: true, smoothing: nil, every: 3),
  Runner("lensi@8", tracking: true, smoothing: .standard, every: 3),
  Runner("light@8", tracking: true, smoothing: .light, every: 3),
]
var truthWobble: [Double] = []
var prevTruth = truth0
var encodeMs: [Double] = []
var frameNames: [String] = []

for (f, url) in frames.enumerated() {
  guard let image = load(url) else { continue }
  frameNames.append(url.lastPathComponent)
  let t0 = Date()
  try sam.prepare(image: image, id: "frame", force: true)
  encodeMs.append(Date().timeIntervalSince(t0) * 1000)
  let truth = f < masks.count ? groundTruth(masks[f]) : nil
  for r in runners {
    let shown = try r.step(f, sam: sam, scale: scale, seedBox: seedBox, seedPoint: seedPoint) ?? []
    r.shown.append(shown)
    if let truth, truth.w == W {
      r.j.append(maskIoU(raster(shown, w: W, h: H), truth.bits))
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
  }
}

/// -1 when there's nothing to average (JSON has no NaN).
func mean(_ x: [Double]) -> Double { x.isEmpty ? -1 : x.reduce(0, +) / Double(x.count) }
func pct(_ x: Double) -> String { x < 0 ? "-" : String(format: "%.1f%%", x * 100) }

var summary: [String: Any] = [
  "name": name, "frames": frameNames.count, "width": W, "height": H,
  "encodeMs": mean(encodeMs), "truthWobble": mean(truthWobble),
  "seedBox": [seedBox.minX, seedBox.minY, seedBox.width, seedBox.height], "seedPoint": [seedPoint.x, seedPoint.y],
]
var lines: [String] = []
var runs: [[String: Any]] = []
for r in runners {
  runs.append([
    "label": r.label, "every": r.every, "J": mean(r.j), "wobble": mean(r.wobble), "cuts": r.cuts, "refused": r.refused,
    "jPerFrame": r.j, "outlines": r.shown.map { $0.flatMap { [Double($0.x), Double($0.y)] } },
  ])
  let label = r.label.padding(toLength: 10, withPad: " ", startingAt: 0)
  lines.append("  \(label) J \(pct(mean(r.j)))  wobble \(pct(mean(r.wobble)))  (\(r.cuts) cuts, \(r.refused) refused)")
}
summary["runs"] = runs
summary["frameNames"] = frameNames
print("\(name): encode \(Int(mean(encodeMs))) ms a frame; the mask's own wobble \(pct(mean(truthWobble)))")
lines.forEach { print($0) }
let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
try data.write(to: outDir.appendingPathComponent("\(name).json"))
