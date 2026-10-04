// ARKit pinning on real ARKit recordings: Apple's ARKitScenes (iPad Pro captures with ARKit's
// own camera pose and lens for every frame, and 3D boxes drawn around the furniture by hand).
// It runs the app's own code end to end, with ARKit's recorded poses where the app has live
// ones: FrozenCamera and LiveShape (LiveWorld.swift), LiveTracker, LiveFlow, OutlineMath and
// SAMSegmenter. A still thing in view the whole time is outlined at the first frame, while the
// camera moves:
//
//   fixed     no ARKit: SAM asked at the same place in the picture every frame
//   arkit     cut once, laid in the world, redrawn every frame from ARKit's pose alone
//   coast@8   the app before LiveFlow: re-cut 7.5 times a second where ARKit and the
//             thing's last motion say it is
//   lensi@8   the app now: the same, carried on its own pixels between cuts (LiveFlow, the
//             round trip through two cameras), drawn eased onto each cut
//
// Each frame is scored against SAM asked with the thing's hand-drawn 3D box seen from that
// frame's pose (J), and for lurch: how far the outline's middle jumps from one frame to the
// next, next to the 3D box's own (which is all camera motion: the thing is still).
//
//   swiftc -O -o pin tools/pin/main.swift app/modules/lensi-ar/ios/{SAMSegmenter,OutlineMath,LiveTracker,LiveFlow,LiveWorld,Analyzer,Detector}.swift
//   LENSI_MODELS_DIR=<models> ./pin <scene dir> <out dir> <name> [frames, default 150]
//
// <scene dir> holds an ARKitScenes raw scan: vga_wide/*.png (640x480, 30 fps),
// vga_wide_intrinsics/*.pincam, lowres_wide.traj and <video>_3dod_annotation.json.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

let args = CommandLine.arguments
guard args.count >= 4 else {
  print("usage: pin <scene dir> <out dir> <name> [frames]")
  exit(2)
}
let sceneDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let name = args[3]
let windowLength = args.count > 4 ? Int(args[4]) ?? 150 : 150
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - The recording

/// ARKitScenes' camera: world-to-camera rotation (axis-angle) and translation, OpenCV axes
/// (x right, y down, z forward). As ARKit reports it: camera to world, x right, y up, z back.
func arkitTransform(axisAngle a: simd_float3, translation t: simd_float3) -> simd_float4x4 {
  let angle = simd_length(a)
  let worldToCamera = angle > 1e-9 ? simd_float3x3(simd_quatf(angle: angle, axis: a / angle)) : matrix_identity_float3x3
  let r = worldToCamera.transpose
  let position = -(r * t)
  return simd_float4x4(columns: (simd_float4(r.columns.0, 0), simd_float4(-r.columns.1, 0),
                                 simd_float4(-r.columns.2, 0), simd_float4(position, 1)))
}

struct Pose {
  let t: Double
  let transform: simd_float4x4
}

/// lowres_wide.traj: one line per pose, `timestamp ax ay az tx ty tz`.
func loadTrajectory(_ url: URL) -> [Pose] {
  guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
  return text.split(separator: "\n").compactMap { line in
    let v = line.split(separator: " ").compactMap { Double($0) }
    guard v.count == 7 else { return nil }
    return Pose(t: v[0], transform: arkitTransform(axisAngle: simd_float3(Float(v[1]), Float(v[2]), Float(v[3])),
                                                    translation: simd_float3(Float(v[4]), Float(v[5]), Float(v[6]))))
  }.sorted { $0.t < $1.t }
}

/// The pose at `t`, between the two recorded around it (rotation slerped, position lerped).
func pose(at t: Double, in poses: [Pose]) -> simd_float4x4? {
  guard let first = poses.first, let last = poses.last else { return nil }
  if t <= first.t { return first.transform }
  if t >= last.t { return last.transform }
  var lo = 0, hi = poses.count - 1
  while hi - lo > 1 {
    let mid = (lo + hi) / 2
    if poses[mid].t <= t { lo = mid } else { hi = mid }
  }
  let a = poses[lo], b = poses[hi]
  let f = Float((t - a.t) / max(b.t - a.t, 1e-9))
  let ra = simd_float3x3(columns: (simd_make_float3(a.transform.columns.0), simd_make_float3(a.transform.columns.1), simd_make_float3(a.transform.columns.2)))
  let rb = simd_float3x3(columns: (simd_make_float3(b.transform.columns.0), simd_make_float3(b.transform.columns.1), simd_make_float3(b.transform.columns.2)))
  let r = simd_float3x3(simd_slerp(simd_quatf(ra), simd_quatf(rb), f))
  let p = simd_make_float3(a.transform.columns.3) * (1 - f) + simd_make_float3(b.transform.columns.3) * f
  return simd_float4x4(columns: (simd_float4(r.columns.0, 0), simd_float4(r.columns.1, 0), simd_float4(r.columns.2, 0), simd_float4(p, 1)))
}

/// A .pincam: `width height fx fy cx cy`, in pixels of the (sideways) sensor image.
func loadIntrinsics(_ url: URL) -> (simd_float3x3, CGSize)? {
  guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
  let v = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { Float($0) }
  guard v.count >= 6 else { return nil }
  let k = simd_float3x3(columns: (simd_float3(v[2], 0, 0), simd_float3(0, v[3], 0), simd_float3(v[4], v[5], 1)))
  return (k, CGSize(width: CGFloat(v[0]), height: CGFloat(v[1])))
}

struct Box {
  let label: String
  let centre: simd_float3
  let corners: [simd_float3]
}

/// The hand-drawn 3D boxes: `data[].segments.obbAligned` (centroid, axesLengths, normalizedAxes
/// as rows), in the trajectory's world.
func loadBoxes(_ url: URL) -> [Box] {
  guard let data = try? Data(contentsOf: url),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let items = json["data"] as? [[String: Any]] else { return [] }
  return items.compactMap { item in
    guard let label = item["label"] as? String,
          let obb = (item["segments"] as? [String: Any])?["obbAligned"] as? [String: Any],
          let c = (obb["centroid"] as? [NSNumber])?.map({ $0.floatValue }), c.count == 3,
          let size = (obb["axesLengths"] as? [NSNumber])?.map({ $0.floatValue }), size.count == 3,
          let axes = (obb["normalizedAxes"] as? [NSNumber])?.map({ $0.floatValue }), axes.count == 9 else { return nil }
    let centre = simd_float3(c[0], c[1], c[2])
    let rows = (0..<3).map { i in simd_float3(axes[3 * i], axes[3 * i + 1], axes[3 * i + 2]) * (size[i] / 2) }
    var corners: [simd_float3] = []
    for sx in [Float(1), -1] { for sy in [Float(1), -1] { for sz in [Float(1), -1] {
      corners.append(centre + rows[0] * sx + rows[1] * sy + rows[2] * sz)
    } } }
    return Box(label: label, centre: centre, corners: corners)
  }
}

func listing(_ dir: URL, _ ext: String) -> [URL] {
  ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension.lowercased() == ext }
}

/// `<video>_<timestamp>.png` -> timestamp.
func timestamp(_ url: URL) -> Double? {
  url.deletingPathExtension().lastPathComponent.split(separator: "_").last.flatMap { Double($0) }
}

let poses = loadTrajectory(sceneDir.appendingPathComponent("lowres_wide.traj"))
let boxes = listing(sceneDir, "json").first.map(loadBoxes) ?? []
let pngs = listing(sceneDir.appendingPathComponent("vga_wide"), "png")
  .compactMap { url in timestamp(url).map { (url: url, t: $0) } }
  .sorted { $0.t < $1.t }
let pincams = Dictionary(listing(sceneDir.appendingPathComponent("vga_wide_intrinsics"), "pincam")
  .compactMap { url in timestamp(url).map { (String(format: "%.3f", $0), url) } }, uniquingKeysWith: { a, _ in a })
print("\(name): \(pngs.count) frames, \(poses.count) poses, \(boxes.count) boxes, \(pincams.count) lenses")
guard pngs.count > windowLength, poses.count > 10, !boxes.isEmpty else {
  print("\(name): not enough to go on")
  exit(1)
}

/// Each frame's camera, as LensiARView makes one from an ARFrame.
var cameras: [FrozenCamera?] = []
var lastLens: (simd_float3x3, CGSize)?
for f in pngs {
  let lens = pincams[String(format: "%.3f", f.t)].flatMap(loadIntrinsics) ?? lastLens
  lastLens = lens
  guard let lens, let transform = pose(at: f.t, in: poses) else {
    cameras.append(nil)
    continue
  }
  cameras.append(FrozenCamera(transform: transform, intrinsics: lens.0, resolution: lens.1))
}

// MARK: - Which thing, which stretch

func bounds(_ p: [CGPoint]) -> CGRect { LiveTracker.bounds(p) }

/// A box as this camera sees it (upright 0...1), when all of it is in front and in the picture.
func seen(_ box: Box, by camera: FrozenCamera?) -> CGRect? {
  guard let camera, let p = camera.upright(box.corners) else { return nil }
  let r = bounds(p)
  guard r.minX > 0.02, r.minY > 0.02, r.maxX < 0.98, r.maxY < 0.98 else { return nil }
  return r
}

// The stretch of `windowLength` frames, and the thing, where the camera moves the most while
// one thing stays wholly in view at a workable size.
var bestChoice: (start: Int, box: Int, travel: Float, turn: Float)?
for start in stride(from: 0, to: pngs.count - windowLength, by: 15) {
  var travel: Float = 0, turn: Float = 0
  var ok = true
  for f in (start + 1)..<(start + windowLength) {
    guard let a = cameras[f - 1], let b = cameras[f] else { ok = false; break }
    travel += simd_distance(simd_make_float3(a.transform.columns.3), simd_make_float3(b.transform.columns.3))
    let za = simd_normalize(simd_make_float3(a.transform.columns.2)), zb = simd_normalize(simd_make_float3(b.transform.columns.2))
    turn += acos(min(max(simd_dot(za, zb), -1), 1))
  }
  guard ok else { continue }
  for (i, box) in boxes.enumerated() {
    var fits = true
    for f in start..<(start + windowLength) {
      guard let r = seen(box, by: cameras[f]), r.width * r.height > 0.04, r.width * r.height < 0.4 else {
        fits = false
        break
      }
    }
    let score = travel + turn * 0.5
    if fits, score > (bestChoice.map { $0.travel + $0.turn * 0.5 } ?? -1) {
      bestChoice = (start: start, box: i, travel: travel, turn: turn)
    }
  }
}
guard let best = bestChoice else {
  print("\(name): no thing stays in view for \(windowLength) frames")
  exit(1)
}
let thing = boxes[best.box]
let window = Array(best.start..<(best.start + windowLength))
print(String(format: "%@: the %@, frames %ld-%ld (%.1f s); the camera travels %.0f cm and turns %.0f degrees",
             name, thing.label, window.first!, window.last!, pngs[window.last!].t - pngs[window.first!].t,
             best.travel * 100, best.turn * 180 / .pi))

// The pose convention, checked against the dataset's own projection (OpenCV axes, landscape
// pixels): the app's FrozenCamera must put the box's corners on the same pixels.
do {
  let f = window[0]
  guard let camera = cameras[f], let upright = camera.upright(thing.corners) else { exit(1) }
  let lines = (try? String(contentsOf: sceneDir.appendingPathComponent("lowres_wide.traj"), encoding: .utf8)) ?? ""
  // The recorded pose nearest this frame, read the dataset's way.
  var nearest: [Double] = []
  var gap = Double.greatestFiniteMagnitude
  for line in lines.split(separator: "\n") {
    let v = line.split(separator: " ").compactMap { Double($0) }
    if v.count == 7, abs(v[0] - pngs[f].t) < gap { gap = abs(v[0] - pngs[f].t); nearest = v }
  }
  let aa = simd_float3(Float(nearest[1]), Float(nearest[2]), Float(nearest[3]))
  let rot = simd_float3x3(simd_quatf(angle: simd_length(aa), axis: simd_normalize(aa)))
  let tr = simd_float3(Float(nearest[4]), Float(nearest[5]), Float(nearest[6]))
  let k = camera.intrinsics
  var worst: Float = 0
  for (c, u) in zip(thing.corners, upright) {
    let x = rot * c + tr
    let px = k[0][0] * x.x / x.z + k[2][0], py = k[1][1] * x.y / x.z + k[2][1]
    // Upright back to the sideways sensor image's pixels.
    let qx = Float(u.y) * Float(camera.resolution.width), qy = (1 - Float(u.x)) * Float(camera.resolution.height)
    worst = max(worst, hypot(px - qx, py - qy))
  }
  print(String(format: "%@: pose check: FrozenCamera puts the box's corners within %.2f px of the dataset's own projection (nearest pose %.0f ms away)",
               name, worst, gap * 1000))
}

// MARK: - Frames as the app sees them

let ci = CIContext(options: [.useSoftwareRenderer: false])
/// The sensor image turned upright, as LensiARView turns ARKit's buffer (`.right`).
func upright(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
  let turned = CIImage(cgImage: image).oriented(.right)
  return ci.createCGImage(turned, from: turned.extent)
}

guard let sam = SAMSegmenter.shared else {
  print("SAM models not found")
  exit(1)
}

/// A polygon (0-1) filled into a w x h 0/1 mask, row 0 at the top.
func raster(_ poly: [CGPoint], w: Int, h: Int) -> [UInt8] {
  var bits = [UInt8](repeating: 0, count: w * h)
  guard poly.count > 2 else { return bits }
  bits.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
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

func middle(_ bits: [UInt8], w: Int) -> CGPoint? {
  var sx = 0.0, sy = 0.0, n = 0
  for i in 0..<bits.count where bits[i] != 0 { sx += Double(i % w); sy += Double(i / w); n += 1 }
  return n == 0 ? nil : CGPoint(x: sx / Double(n), y: sy / Double(n))
}

func jerk(_ c: [CGPoint?]) -> Double {
  var sum = 0.0, n = 0
  for i in 2..<max(c.count, 2) {
    guard let a = c[i - 2], let b = c[i - 1], let d = c[i] else { continue }
    sum += Double(hypot(d.x - 2 * b.x + a.x, d.y - 2 * b.y + a.y))
    n += 1
  }
  return n == 0 ? -1 : sum / Double(n)
}

func mean(_ x: [Double]) -> Double { x.isEmpty ? -1 : x.reduce(0, +) / Double(x.count) }

// MARK: - The runs

/// The app's first look at a guide part: SAM at the point where its pin lands, within the box
/// of its outline seen from here (grown 10%, as LensiARView.uprightBox).
func firstLook(_ camera: FrozenCamera) -> (point: CGPoint, box: CGRect)? {
  guard let r = seen(thing, by: camera), let c = camera.upright([thing.centre])?.first else { return nil }
  let grown = r.insetBy(dx: -r.width * 0.1, dy: -r.height * 0.1).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  return (point: c, box: grown)
}

final class Run {
  let label: String
  /// SAM every `every` frames (0: only the first), LiveFlow between, ARKit at all.
  let every: Int
  let flow: Bool
  let arkit: Bool
  var shape: LiveShape?
  var fixedPrompt: (point: CGPoint, box: CGRect)?
  var shown: [[CGPoint]] = []
  var j: [Double] = []
  var middles: [CGPoint?] = []
  var cuts = 0, refused = 0, carried = 0

  init(_ label: String, every: Int, flow: Bool = false, arkit: Bool = true) {
    self.label = label
    self.every = every
    self.flow = flow
    self.arkit = arkit
  }
}

let runs = [
  Run("fixed", every: 1, arkit: false),
  Run("arkit", every: 0),
  Run("coast@8", every: 4),
  Run("lensi@8", every: 4, flow: true),
]

var reference: [[CGPoint]] = []
var boxMiddles: [CGPoint?] = []
var frameNames: [String] = []
var encodeMs: [Double] = []
var previous: (frame: LiveFlow.Frame, camera: FrozenCamera, t: Double)?
var size = CGSize(width: 480, height: 640)

for (k, f) in window.enumerated() {
  guard let camera = cameras[f], let image = upright(pngs[f].url) else { continue }
  frameNames.append(pngs[f].url.lastPathComponent)
  size = CGSize(width: image.width, height: image.height)
  let t = pngs[f].t
  let t0 = Date()
  try sam.prepare(image: image, id: "frame", force: true)
  encodeMs.append(Date().timeIntervalSince(t0) * 1000)
  let flowFrame = LiveFlow.frame(image)

  // What the thing looks like from here: SAM asked with its 3D box as this pose sees it.
  let look = firstLook(camera)
  var truth: [CGPoint] = []
  if let look {
    let m = try sam.segment(id: "frame", points: [look.point], labels: [1], box: look.box)
    if m.polygon.count > 2 { truth = OutlineMath.resample(m.polygon, scale: size) }
  }
  reference.append(truth)
  let w = Int(size.width), h = Int(size.height)
  let truthBits = raster(truth, w: w, h: h)
  boxMiddles.append(look == nil ? nil : camera.upright([thing.centre])?.first.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })

  for run in runs {
    var outline: [CGPoint] = []
    if !run.arkit {
      // SAM where the thing was in the picture at the start, every frame.
      if run.fixedPrompt == nil { run.fixedPrompt = look }
      if let p = run.fixedPrompt {
        let m = try sam.segment(id: "frame", points: [p.point], labels: [1], box: p.box)
        run.cuts += 1
        if m.polygon.count > 2 { outline = OutlineMath.resample(m.polygon, scale: size) }
      }
    } else {
      // Between cuts, its own pixels (the round trip through the last frame's camera and this one's).
      if run.flow, var shape = run.shape, let previous, let flowFrame {
        if shape.carry(from: previous.frame, previous.camera, at: previous.t, to: flowFrame, camera, at: t) { run.carried += 1 }
        run.shape = shape
      }
      let due = run.shape == nil || (run.every > 0 && k % run.every == 0)
      if due {
        // Asked where it should be now (LensiARView.segmentLive's follow), or a first look.
        var point: CGPoint?, box: CGRect?, anchor: simd_float3?, predicted: [CGPoint]?
        if let shape = run.shape, shape.misses < 2 {
          let now = shape.placed(at: t)
          if let p = camera.upright(now), p.contains(where: { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0) }),
             let prompt = LiveTracker.prompt(for: p, scale: size) {
            point = prompt.point
            box = prompt.box
            anchor = OutlineMath.centre(now)
            predicted = p
          }
        }
        if point == nil, let look {
          point = look.point
          box = look.box
          anchor = thing.centre
        }
        if let point, let anchor {
          let m = try sam.segment(id: "frame", points: [point], labels: [1], box: box)
          run.cuts += 1
          var world: [simd_float3]?
          if m.score >= (predicted == nil ? 0.6 : 0.5), m.polygon.count > 2 {
            let ring = OutlineMath.resample(m.polygon, scale: size)
            if let predicted, !LiveTracker.accepts(ring, predicted: predicted) {
              run.refused += 1
            } else {
              let plane = camera.withPlane(through: anchor)
              let laid = ring.compactMap { plane.onPlane($0) }
              if laid.count == ring.count { world = laid }
            }
          }
          // LensiARView.takeLive.
          if let world {
            if var shape = run.shape, t - shape.seen < 2, shape.misses < 2 {
              shape.take(world, at: t)
              run.shape = shape
            } else {
              run.shape = LiveShape(world: world, at: t, follows: true)
            }
          } else if var shape = run.shape {
            shape.misses += 1
            shape.velocity *= 0.5
            run.shape = shape
          }
        }
      }
      if var shape = run.shape {
        // What the screen shows: eased (the app now) or as it stands.
        let drawn = run.flow ? shape.draw(at: t) : shape.placed(at: t)
        run.shape = shape
        outline = camera.upright(drawn) ?? []
      }
    }
    run.shown.append(outline)
    let bits = raster(outline, w: w, h: h)
    run.middles.append(middle(bits, w: w))
    if !truth.isEmpty { run.j.append(maskIoU(bits, truthBits)) }
  }
  if let flowFrame { previous = (frame: flowFrame, camera: camera, t: t) }
}

let truthJerk = jerk(boxMiddles)
print(String(format: "%@: encode %.0f ms a frame; the 3D box's own lurch (all camera motion) %.1f px",
             name, mean(encodeMs), truthJerk))
var runsOut: [[String: Any]] = []
for run in runs {
  print(String(format: "  %@ J %.1f%%  lurch %.1f px  (%ld cuts, %ld refused, %ld carried)",
               run.label.padding(toLength: 8, withPad: " ", startingAt: 0), mean(run.j) * 100, jerk(run.middles),
               run.cuts, run.refused, run.carried))
  runsOut.append(["label": run.label, "J": mean(run.j), "jerk": jerk(run.middles), "cuts": run.cuts, "refused": run.refused,
                  "jPerFrame": run.j, "outlines": run.shown.map { $0.flatMap { [Double($0.x), Double($0.y)] } }])
}
let summary: [String: Any] = [
  "name": name, "thing": thing.label, "frames": frameNames.count, "frameNames": frameNames,
  "travelCm": Double(best.travel * 100), "turnDegrees": Double(best.turn * 180 / .pi),
  "truthJerk": truthJerk, "encodeMs": mean(encodeMs), "width": Int(size.width), "height": Int(size.height),
  "reference": reference.map { $0.flatMap { [Double($0.x), Double($0.y)] } }, "runs": runsOut,
]
let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
try data.write(to: outDir.appendingPathComponent("\(name).json"))
