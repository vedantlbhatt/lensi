// The strip (slide to pick, hold to pin) on real moving footage, with the app's own code. At a
// few moments of a clip it finds what a finger landing on the strip would find there (YOLO's
// objects cut by SAM from their boxes, and SAM's part proposals over the picture, as
// LensiARView.scrubStart does), and from then on follows each one the way the app follows a
// pinned thing:
//
//   - every frame it rides its own pixels (LiveFlow, LiveShape.carry: LensiARView.flowLive);
//   - every few frames SAM is asked where it should be (LiveTracker.prompt), the candidate that
//     overlaps that wins, a cut that doesn't fit is refused, and how hard to look goes by its
//     own speed (LiveTracker.asking: LensiARView.segmentLive's follow, takeLive);
//   - what's drawn eases onto each cut (LiveShape.draw: layoutLive);
//   - it's never let go (LiveShape.pinned): lost, it stays where it was.
//
// The footage is from a still camera, so the world is the picture: a FrozenCamera that doesn't
// move, its plane a metre ahead. The app's virtual camera plays the clip with these tracks
// under its strip, so slide-to-pin can be tried on moving footage in the web preview and the
// Simulator (app/assets/demo/video).
//
//   swiftc -O -o strip tools/strip/main.swift \
//     app/modules/lensi-ar/ios/{SAMSegmenter,OutlineMath,LiveTracker,LiveFlow,LiveWorld,LiveSeg,Detector}.swift
//   LENSI_MODELS_DIR=<models> ./strip <frames dir> <out.json> [fps, 15] [frames between SAM's cuts, 4]
import CoreGraphics
import Foundation
import ImageIO
import simd

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("usage: strip <frames dir> <out.json> [fps] [every]")
  exit(2)
}
let framesDir = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let fps = args.count > 3 ? Double(args[3]) ?? 15 : 15
let every = max(1, args.count > 4 ? Int(args[4]) ?? 4 : 4)
let name = framesDir.lastPathComponent

let files = ((try? FileManager.default.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil)) ?? [])
  .filter { $0.pathExtension.lowercased() == "jpg" }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else {
  print("no frames in \(framesDir.path)")
  exit(1)
}
guard let sam = SAMSegmenter.shared else {
  print("SAM models not found")
  exit(1)
}
let detector = Detector()

func load(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// A camera that doesn't move and sees the picture as it is: upright points to a plane a metre
/// ahead and back. (FrozenCamera's sensor lies on its side, so its width is the picture's height.)
func stillCamera(_ size: CGSize) -> FrozenCamera {
  let f = Float(max(size.width, size.height))
  let lens = simd_float3x3(columns: (simd_float3(f, 0, 0), simd_float3(0, f, 0),
                                     simd_float3(Float(size.height) / 2, Float(size.width) / 2, 1)))
  return FrozenCamera(transform: matrix_identity_float4x4, intrinsics: lens, resolution: CGSize(width: size.height, height: size.width))
    .withPlane(through: simd_float3(0, 0, -1))
}

final class Thing {
  let label: String?
  let start: Int
  var shape: LiveShape
  var outlines: [[CGPoint]?]
  var cuts = 0
  var refused = 0
  init(label: String?, start: Int, shape: LiveShape, frames: Int) {
    self.label = label
    self.start = start
    self.shape = shape
    outlines = Array(repeating: nil, count: frames)
  }
}

let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
let landings: Set<Int> = [0, files.count / 3, 2 * files.count / 3]
let maxThings = 12
var things: [Thing] = []
var previous: (frame: LiveFlow.Frame, t: Double)?
var camera: FrozenCamera?
var size = CGSize.zero
var encodeMs: [Double] = []

for (f, url) in files.enumerated() {
  guard let image = load(url) else { continue }
  size = CGSize(width: image.width, height: image.height)
  let cam = camera ?? stillCamera(size)
  camera = cam
  let t = Double(f) / fps
  let flowFrame = LiveFlow.frame(image)

  // Every frame, each thing rides its own pixels.
  if let previous, let flowFrame {
    for thing in things where thing.shape.misses < 2 {
      _ = thing.shape.carry(from: previous.frame, cam, at: previous.t, to: flowFrame, cam, at: t)
    }
  }

  let recut = f % every == 0
  let landing = landings.contains(f)
  if recut || landing {
    let t0 = Date()
    try sam.prepare(image: image, id: "frame", force: true)
    encodeMs.append(Date().timeIntervalSince(t0) * 1000)
  }

  // SAM where each thing should be now; a cut that doesn't fit it is refused.
  if recut {
    for thing in things {
      let now = thing.shape.placed(at: t)
      let speed = thing.shape.misses < 2 ? CGFloat(thing.shape.sizesPerSecond) : 0
      let asking = LiveTracker.asking(sizesPerSecond: speed)
      guard let predicted = cam.upright(now), predicted.contains(where: { unit.contains($0) }),
            let p = LiveTracker.prompt(for: predicted, scale: size, grow: asking.grow) else { continue }
      let m = try sam.segment(id: "frame", points: [p.point], labels: [1], box: p.box, prior: predicted)
      thing.cuts += 1
      var world: [simd_float3]?
      if m.score >= 0.5, m.polygon.count > 2 {
        let ring = OutlineMath.resample(m.polygon, scale: size)
        if LiveTracker.accepts(ring, predicted: predicted, gate: asking.gate) {
          let laid = ring.compactMap { cam.onPlane($0) }
          if laid.count == ring.count { world = laid }
        } else {
          thing.refused += 1
        }
      }
      if let world {
        thing.shape.take(world, at: t, how: asking.smoothing)
      } else {
        thing.shape.misses += 1
        thing.shape.velocity *= 0.5
      }
    }
  }

  // What a finger landing on the strip now would find: YOLO's objects, then SAM's parts.
  if landing, things.count < maxThings {
    var found: [(polygon: [CGPoint], label: String?)] = []
    for d in detector.detect(cgImage: image).filter({ $0.confidence >= 0.4 }).prefix(6) {
      let m = try sam.segment(id: "frame", points: [], labels: [], box: d.rect)
      if m.score >= 0.6, m.polygon.count > 2 { found.append((m.polygon, d.label)) }
    }
    let parts = try sam.proposeParts(id: "frame", region: unit, grid: 6, maxParts: 10,
                                     minArea: 0.003, maxArea: 0.3, minScore: 0.8, budget: 60)
    found += parts.map { (polygon: $0.polygon, label: String?.none) }
    for (polygon, label) in found where things.count < maxThings {
      let ring = OutlineMath.resample(polygon, scale: size)
      // Already followed, or found twice: one thing.
      let taken = things.contains { thing in
        guard let now = cam.upright(thing.shape.placed(at: t)) else { return false }
        return LiveTracker.iou(now, ring) > 0.5
      }
      guard !taken else { continue }
      let world = ring.compactMap { cam.onPlane($0) }
      guard world.count == ring.count else { continue }
      var shape = LiveShape(world: world, at: t, follows: true)
      shape.pinned = true
      things.append(Thing(label: label, start: f, shape: shape, frames: files.count))
    }
  }

  // What the screen shows.
  for thing in things where thing.start <= f {
    if let shown = cam.upright(thing.shape.draw(at: t)) {
      thing.outlines[f] = OutlineMath.resample(shown, count: 32, scale: size)
    }
  }
  if let flowFrame { previous = (frame: flowFrame, t: t) }
}

func r3(_ v: CGFloat) -> Double { (Double(v) * 1000).rounded() / 1000 }
let mean = encodeMs.isEmpty ? 0 : encodeMs.reduce(0, +) / Double(encodeMs.count)
print(String(format: "%@: %ld frames %.0fx%.0f, %ld things, SAM encode %.0f ms", name, files.count, size.width, size.height, things.count, mean))
for (i, th) in things.enumerated() {
  let shown = th.outlines.compactMap { $0 }.count
  print(String(format: "  %2ld %-12@ from frame %3ld, drawn %3ld frames, %3ld cuts, %ld refused, still missing at the end: %@",
               i, (th.label ?? "-") as NSString, th.start, shown, th.cuts, th.refused, th.shape.misses >= 2 ? "yes" : "no"))
}
let out: [String: Any] = [
  "clip": name,
  "fps": fps,
  "frames": files.count,
  "size": [Int(size.width), Int(size.height)],
  "every": every,
  "things": things.map { th -> [String: Any] in
    [
      "label": th.label.map { $0 as Any } ?? NSNull(),
      "start": th.start,
      "outlines": th.outlines.map { o -> Any in o.map { pts -> Any in pts.flatMap { [r3($0.x), r3($0.y)] } } ?? NSNull() },
    ]
  },
]
let data = try JSONSerialization.data(withJSONObject: out, options: [])
try data.write(to: outURL)
print("wrote \(outURL.path) (\(data.count / 1024) KB)")
