// The app's pinning on real handheld walk-arounds: Apple's ARKitScenes (people walking about
// rooms holding an iPad Pro, with ARKit's own pose and lens for every frame, its LiDAR depth,
// and 3D boxes drawn around the furniture by hand). tools/pin takes calm stretches where a thing
// stays wholly in view, and starts each outline at the thing's true depth. A phone gets neither:
// people walk up close (the thing runs off the picture) and back out, and how far the thing is
// was a guess (a raycast through it that hits the wall behind). This takes the stretch where
// the camera goes furthest from far to close and back, pins the thing as the strip does, at a
// depth that's right or guessed wrong, and runs the app's own code on it end to end
// (FrozenCamera and LiveShape, LiveTracker, LiveFlow, OutlineMath, SAMSegmenter), SAM's answer
// landing two frames after the frame it was asked about, the flow off while the camera moves
// fast, as on the phone:
//
//   arkit@true   cut once at its true depth, then ARKit alone
//   arkit@far    cut once 40% too far (a raycast that hit the wall behind), then ARKit alone
//   app@true     the app before, pinned at the true depth
//   app@far      the same, pinned 40% too far
//   lidar@far    ...its depth put right by LiDAR inside each cut, as on a Pro iPhone
//   steady@true  the app now, pinned at the true depth (as where LiDAR or ARKit's points put
//                it): a still thing whose depth is known isn't carried by the flow (ARKit holds
//                it), and seen from about where it was last cut takes only a cut that matches
//                it closely
//   steady@far   the same, pinned 40% too far (a raycast's guess: until something measures it,
//                just as before)
//   steadyl@far  ...and LiDAR, as on a Pro iPhone
//   clamp@*      steady, and partly off the picture one cut can make a still thing whose
//                depth is known only 10% bigger or smaller, not 40%
//   sight@far    steady, pinned 40% too far, its depth put right by where the lines of sight
//                through its whole cuts cross (LiveShape.sight): no LiDAR, no points on it
//   shift@true   edge, and from halfway on ARKit's world is somewhere else (paused at 0.5x and
//                resumed): the whole thing seen nowhere near where it should be is laid afresh
//   shiftn@true  the same without that: blended in through where it was
//   edge@*       the app now on a phone: followed by EdgeTAM (EdgeTAMTracker, Meta's on-device
//                SAM 2, from its memory of the thing: no prompts) every other frame, its cuts
//                laid in the world as above, up close the whole outline going where the part on
//                the picture went (a part that's plausibly it, through the loose gate, at most
//                10% bigger or smaller once its depth is known, never laid as the whole thing);
//                edge@far's depth from lines of sight, edgel@far's from LiDAR (with the EdgeTAM
//                models in LENSI_MODELS_DIR; left out without them)
//   edgeb@far    edge@far, and a cut from a frame taken while the phone moved fast (a blur) not taken
//                for a still thing whose depth is known (ARKit holds it)
//   edgeg@far    edge@far, the flow starting where the poses say the outline went (LiveShape.guided),
//                and carrying it while the phone moves fast too
//   edge2@far    edge@far again, unchanged: how far two identical runs drift apart
//   edgestd@far, edgelt@far  a still thing's cuts blended in as a moving one's (.standard) or lighter
//                (.light) rather than OutlineMath.Smoothing.still; edgeqk@far what's drawn of a still
//                thing eased in 50 ms rather than 150 (LiveShape.stillEase); edgelq@far both
//   flat-*       0.5x on the same walk (FlatFollower, as LensiARView follows pinned things on the
//                ultra-wide without ARKit): no world, EdgeTAM's answers on the picture at the phone's
//                timing, moved on between them by nothing (flat-none), by how the camera turned alone
//                (flat-gyro: the gyro, as the app did before), by the picture's own pixels (flat-flow),
//                or by them and by the gyro while the camera turns fast (flat-fast), or by them
//                starting from where the gyro says each point went (flat-guide)
//
// Each frame is scored against SAM asked with the thing's hand-drawn 3D box seen from that
// frame's pose (J, and how often it's below 0.5: lost), for how much of the outline is on the
// box at all, for slip (how far the outline moves against the box from one frame to the next,
// which is what a person sees as jitter), and for how far off its depth is.
//
//   swiftc -O -o walk tools/walk/main.swift app/modules/lensi-ar/ios/{EdgeTAMTracker,SAMSegmenter,OutlineMath,LiveTracker,LiveFlow,LiveWorld,LiveSeg,Analyzer,Detector,FlatFollow}.swift
//   LENSI_MODELS_DIR=<models> ./walk <scene dir> <out dir> <name> [frames, default 240]
//
// <scene dir> holds an ARKitScenes raw scan: vga_wide/*.png (640x480, 30 fps),
// vga_wide_intrinsics/*.pincam, lowres_wide.traj, lowres_depth/*.png and the annotation json.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

let args = CommandLine.arguments
guard args.count >= 4 else {
  print("usage: walk <scene dir> <out dir> <name> [frames]")
  exit(2)
}
let sceneDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let name = args[3]
let windowLength = args.count > 4 ? Int(args[4]) ?? 240 : 240
/// `select`: only say which stretch and thing it would take, and how good a walk up close and
/// back out it is (`PICK <name> <score> <thing>`), from the poses, lenses and boxes alone.
let selectOnly = args.count > 5 && args[5] == "select"
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
let lenses = listing(sceneDir.appendingPathComponent("vga_wide_intrinsics"), "pincam")
  .compactMap { url in timestamp(url).map { (url: url, t: $0) } }
  .sorted { $0.t < $1.t }
let pincams = Dictionary(lenses.map { (String(format: "%.3f", $0.t), $0.url) }, uniquingKeysWith: { a, _ in a })
/// When each frame was captured: the pictures', or with none here (`select`), their lenses'.
let times = pngs.isEmpty ? lenses.map { $0.t } : pngs.map { $0.t }
/// LiDAR's depth for the frames (lowres_depth: 256 x 192, millimetres in 16 bits), by time.
let depthFiles = listing(sceneDir.appendingPathComponent("lowres_depth"), "png")
  .compactMap { url in timestamp(url).map { (url: url, t: $0) } }
  .sorted { $0.t < $1.t }
print("\(name): \(pngs.count) frames, \(poses.count) poses, \(boxes.count) boxes, \(pincams.count) lenses, \(depthFiles.count) depth maps")
guard times.count > windowLength / 2, poses.count > 10, !boxes.isEmpty else {
  print(selectOnly ? "PICK \(name) 0 none" : "\(name): not enough to go on")
  exit(selectOnly ? 0 : 1)
}

/// Each frame's camera, as LensiARView makes one from an ARFrame.
var cameras: [FrozenCamera?] = []
var lastLens: (simd_float3x3, CGSize)?
for t in times {
  let lens = pincams[String(format: "%.3f", t)].flatMap(loadIntrinsics) ?? lastLens
  lastLens = lens
  guard let lens, let transform = pose(at: t, in: poses) else {
    cameras.append(nil)
    continue
  }
  cameras.append(FrozenCamera(transform: transform, intrinsics: lens.0, resolution: lens.1))
}

// MARK: - LiDAR

/// One of LiDAR's depth maps, in metres (0: none), lying on its side as the sensor image does.
struct DepthMap {
  let width: Int
  let height: Int
  let metres: [Float]

  /// The depth at an upright picture point (the nearest of its pixels); nil where there's none.
  func at(upright u: CGPoint) -> Float? {
    let s = FrozenCamera.sensor(u)
    let x = Int(s.x * CGFloat(width)), y = Int(s.y * CGFloat(height))
    guard x >= 0, y >= 0, x < width, y < height else { return nil }
    let d = metres[y * width + x]
    return d > 0 ? d : nil
  }
}

/// A lowres_depth PNG: one 16-bit channel of millimetres. ImageIO hands the bytes over as the
/// PNG has them or swapped; read the wrong way round, neighbours jump about, so whichever
/// reading is smooth is the depth.
func loadDepth(_ url: URL) -> DepthMap? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
        image.bitsPerComponent == 16, image.bitsPerPixel == 16,
        let provided = image.dataProvider?.data else { return nil }
  let data = provided as Data
  let w = image.width, h = image.height, row = image.bytesPerRow
  guard w > 1, h > 0, data.count >= row * (h - 1) + w * 2 else { return nil }
  var big = [Float](repeating: 0, count: w * h)
  var little = big
  data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    for y in 0..<h {
      for x in 0..<w {
        let i = y * row + x * 2
        let hi = UInt16(raw[i]), lo = UInt16(raw[i + 1])
        big[y * w + x] = Float((hi << 8) | lo) / 1000
        little[y * w + x] = Float((lo << 8) | hi) / 1000
      }
    }
  }
  func rough(_ v: [Float]) -> Float {
    var sum: Float = 0
    for y in 0..<h {
      for x in 1..<w { sum += abs(v[y * w + x] - v[y * w + x - 1]) }
    }
    return sum
  }
  return DepthMap(width: w, height: h, metres: rough(big) <= rough(little) ? big : little)
}

/// LiDAR's depth map nearest in time to `t` (within 50 ms).
func depthMap(at t: Double) -> DepthMap? {
  guard !depthFiles.isEmpty else { return nil }
  var lo = 0, hi = depthFiles.count - 1
  while hi - lo > 1 {
    let mid = (lo + hi) / 2
    if depthFiles[mid].t <= t { lo = mid } else { hi = mid }
  }
  let nearest = abs(depthFiles[lo].t - t) <= abs(depthFiles[hi].t - t) ? depthFiles[lo] : depthFiles[hi]
  return abs(nearest.t - t) < 0.05 ? loadDepth(nearest.url) : nil
}

// MARK: - Which thing, which stretch

func bounds(_ p: [CGPoint]) -> CGRect { LiveTracker.bounds(p) }

/// The convex hull of some points (monotone chain), counter-clockwise.
func hull(_ points: [CGPoint]) -> [CGPoint] {
  let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
  guard p.count > 2 else { return p }
  func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
  var lower: [CGPoint] = [], upper: [CGPoint] = []
  for q in p {
    while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
    lower.append(q)
  }
  for q in p.reversed() {
    while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
    upper.append(q)
  }
  return Array(lower.dropLast() + upper.dropLast())
}

/// The part of a box in front of a camera: its corners in front, and where each edge that runs
/// behind the camera crosses 5 cm in front of it (walked up close, part of a big thing can be
/// behind the phone).
func inFront(_ box: Box, _ camera: FrozenCamera) -> [simd_float3] {
  let toCamera = camera.transform.inverse
  let z = box.corners.map { simd_mul(toCamera, simd_float4($0, 1)).z }
  var out: [simd_float3] = []
  for i in 0..<box.corners.count where z[i] < -0.05 { out.append(box.corners[i]) }
  // Corners are numbered by which side of each of the box's three axes they're on (loadBoxes):
  // an edge joins two that differ on one.
  for i in 0..<box.corners.count {
    for side in [1, 2, 4] where i & side == 0 && (i | side) < box.corners.count {
      let j = i | side
      guard (z[i] < -0.05) != (z[j] < -0.05) else { continue }
      let f = (-0.05 - z[i]) / (z[j] - z[i])
      out.append(box.corners[i] + (box.corners[j] - box.corners[i]) * f)
    }
  }
  return out
}

/// A box as a camera sees it (upright 0...1, not cut to the picture): the hull of its part in front.
func picture(_ box: Box, _ camera: FrozenCamera?) -> [CGPoint]? {
  guard let camera else { return nil }
  let front = inFront(box, camera)
  guard front.count >= 3, let p = camera.upright(front) else { return nil }
  let h = hull(p)
  return h.count >= 3 ? h : nil
}

/// A box as a camera sees it: how much of it is on the picture, how much of the picture it
/// covers there, and how far it is.
func view(_ box: Box, _ camera: FrozenCamera?) -> (visible: CGFloat, area: CGFloat, distance: Float)? {
  guard let camera, let h = picture(box, camera) else { return nil }
  let whole = LiveTracker.area(h)
  guard whole > 0 else { return nil }
  let shown = LiveTracker.area(LiveTracker.clipped(h))
  return (visible: shown / whole, area: shown, distance: simd_distance(camera.position, box.centre))
}

/// How much of a box is in plain view, by LiDAR: of the depths measured where the box is on the
/// picture, the share no nearer than its nearest corner (less 10 cm). Something standing in
/// front of it (the table before a chair) is nearer.
func unhidden(_ box: Box, _ camera: FrozenCamera, _ map: DepthMap) -> Double? {
  guard let h = picture(box, camera) else { return nil }
  let shown = LiveTracker.clipped(h)
  guard shown.count >= 3 else { return nil }
  let toCamera = camera.transform.inverse
  let nearest = box.corners.map { -simd_mul(toCamera, simd_float4($0, 1)).z }.min() ?? 0
  let r = bounds(shown)
  var n = 0, clear = 0
  for gy in 0..<16 {
    for gx in 0..<16 {
      let p = CGPoint(x: r.minX + (CGFloat(gx) + 0.5) / 16 * r.width, y: r.minY + (CGFloat(gy) + 0.5) / 16 * r.height)
      guard LiveTracker.contains(shown, p), let d = map.at(upright: p) else { continue }
      n += 1
      if d >= nearest - 0.1 { clear += 1 }
    }
  }
  return n >= 20 ? Double(clear) / Double(n) : nil
}

// The stretch, and the thing, where the camera goes furthest from far to close and back while
// the thing stays at least partly in view, starting with all of it in view (that's when it's
// pinned); solid fixtures first, as tools/pin. A shorter stretch if no long one will do.
let solid: Set<String> = ["sink", "toilet", "washer", "dishwasher", "oven", "stove", "refrigerator", "cabinet",
                          "bathtub", "tv_monitor", "fireplace", "shelf", "bed", "sofa"]
struct Candidate {
  let start: Int
  let length: Int
  let box: Int
  let ratio: Float
  let close: Int
  let score: Float
}
var candidates: [Candidate] = []
for length in [windowLength, windowLength * 3 / 4, windowLength / 2] where candidates.isEmpty && times.count > length {
  for start in stride(from: 0, to: times.count - length, by: 10) {
    for (i, box) in boxes.enumerated() {
      guard let first = view(box, cameras[start]), first.visible >= 0.9, first.area >= 0.03, first.area <= 0.5 else { continue }
      var near = Float.greatestFiniteMagnitude, far: Float = 0, close = 0, fits = true
      for f in start..<(start + length) {
        guard let v = view(box, cameras[f]), v.visible >= 0.15, v.area >= 0.005 else {
          fits = false
          break
        }
        near = min(near, v.distance)
        far = max(far, v.distance)
        if v.visible < 0.9 || v.area > 0.45 { close += 1 }
      }
      guard fits, near > 0.1 else { continue }
      let ratio = far / near
      guard ratio >= 1.3 else { continue }
      let label = box.label.lowercased().replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: "/", with: "_")
      let score = ratio * (1 + Float(close) / Float(length) * 3) * (solid.contains(label) ? 1.5 : 1)
      candidates.append(Candidate(start: start, length: length, box: i, ratio: ratio, close: close, score: score))
    }
  }
}
candidates.sort { $0.score > $1.score }
// The best of them where, as it's pinned, nothing stands in front of the thing (LiDAR).
var bestChoice: Candidate?
var looked = 0
for c in candidates {
  guard !depthFiles.isEmpty else {
    bestChoice = c
    break
  }
  guard looked < 80 else { break }
  looked += 1
  guard let camera = cameras[c.start], let map = depthMap(at: times[c.start]) else { continue }
  if let clear = unhidden(boxes[c.box], camera, map), clear >= 0.6 {
    bestChoice = c
    break
  }
}
guard let best = bestChoice else {
  print(selectOnly ? "PICK \(name) 0 none" : "\(name): no thing goes from far to close and back while staying in plain view")
  exit(selectOnly ? 0 : 1)
}
if selectOnly {
  print(String(format: "PICK %@ %.2f %@", name, best.score, boxes[best.box].label.replacingOccurrences(of: " ", with: "_")))
  exit(0)
}
let thing = boxes[best.box]
let window = Array(best.start..<(best.start + best.length))
var travel: Float = 0, turn: Float = 0
for f in window.dropFirst() {
  guard let a = cameras[f - 1], let b = cameras[f] else { continue }
  travel += simd_distance(a.position, b.position)
  let za = simd_normalize(simd_make_float3(a.transform.columns.2)), zb = simd_normalize(simd_make_float3(b.transform.columns.2))
  turn += acos(min(max(simd_dot(za, zb), -1), 1))
}
let distances = window.map { view(thing, cameras[$0])?.distance ?? 0 }
let visibles = window.map { view(thing, cameras[$0])?.visible ?? 0 }
print(String(format: "%@: the %@, frames %ld-%ld (%.1f s); %.2f m to %.2f m away (x%.1f), partly off the picture or close up in %ld frames; the camera travels %.0f cm and turns %.0f degrees",
             name, thing.label, window.first!, window.last!, times[window.last!] - times[window.first!],
             distances.min() ?? 0, distances.max() ?? 0, best.ratio, best.close, travel * 100, turn * 180 / .pi))

/// Up, in the recording's world: the axis the hand-drawn boxes stand along (they're drawn
/// upright), pointing from the things to the camera.
func worldUp() -> simd_float3 {
  let axes = [simd_float3(1, 0, 0), simd_float3(0, 1, 0), simd_float3(0, 0, 1)]
  var votes = [0, 0, 0]
  for box in boxes {
    // Edges from corner 0: the box's three axes.
    for k in [1, 2, 4] where k < box.corners.count {
      let e = simd_normalize(box.corners[k] - box.corners[0])
      for (i, a) in axes.enumerated() where abs(simd_dot(e, a)) > 0.99 { votes[i] += 1 }
    }
  }
  let up = axes[votes.firstIndex(of: votes.max() ?? 0) ?? 1]
  let above = window.compactMap { cameras[$0] }.reduce(Float(0)) { $0 + simd_dot($1.position - thing.centre, up) }
  return above >= 0 ? up : -up
}
let up = worldUp()
/// Which way up points in the recorded (sideways) image: (right, up) in the camera's x and y.
let upInImage = window.compactMap { cameras[$0] }.reduce(simd_float2.zero) { sum, camera in
  let r = simd_float3x3(columns: (simd_make_float3(camera.transform.columns.0), simd_make_float3(camera.transform.columns.1),
                                  simd_make_float3(camera.transform.columns.2)))
  let c = r.transpose * up
  return sum + simd_float2(c.x, c.y)
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

/// How much of `bits` lies inside `inside` (0...1; 1 when it's empty).
func share(_ bits: [UInt8], inside: [UInt8]) -> Double {
  var n = 0, hit = 0
  for i in 0..<min(bits.count, inside.count) where bits[i] != 0 {
    n += 1
    if inside[i] != 0 { hit += 1 }
  }
  return n == 0 ? 1 : Double(hit) / Double(n)
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

/// How far `c` moves against `against` from one frame to the next (px): an outline sliding
/// about on a thing that stands still.
func slip(_ c: [CGPoint?], against: [CGPoint?]) -> Double {
  var sum = 0.0, n = 0
  for i in 1..<max(c.count, 1) {
    guard let a = c[i - 1], let b = c[i], let p = against[i - 1], let q = against[i] else { continue }
    sum += Double(hypot((b.x - q.x) - (a.x - p.x), (b.y - q.y) - (a.y - p.y)))
    n += 1
  }
  return n == 0 ? -1 : sum / Double(n)
}

func mean(_ x: [Double]) -> Double { x.isEmpty ? -1 : x.reduce(0, +) / Double(x.count) }

// MARK: - The runs

/// What the thing looks like from here, as SAM cuts it asked with its hand-drawn 3D box as this
/// pose sees it (the part of the box on the picture, and a point well inside that): the outline
/// it should have, near or far, whole or partly off the picture.
func truthPrompt(_ camera: FrozenCamera, scale: CGSize) -> (point: CGPoint, box: CGRect)? {
  guard let p = picture(thing, camera) else { return nil }
  let shown = LiveTracker.clipped(p)
  guard shown.count >= 3, LiveTracker.area(shown) > 0.002 else { return nil }
  let r = bounds(shown)
  let grown = r.insetBy(dx: -r.width * 0.05, dy: -r.height * 0.05).intersection(LiveTracker.picture)
  guard !grown.isNull, grown.width > 0.01, grown.height > 0.01 else { return nil }
  return (point: LiveTracker.interiorPoint(shown, scale: scale), box: grown)
}

/// A cut on its way back from SAM: made from frame `t`'s picture, it lands at frame `due`.
struct Cut {
  let due: Int
  let t: Double
  let camera: FrozenCamera
  /// The outline to take; nil when SAM found nothing that fits where the thing should be.
  let world: [simd_float3]?
  let depth: Float?
  let smoothing: OutlineMath.Smoothing
  /// The middle of a cut of the whole thing (none of it off the picture), upright.
  var middle: CGPoint? = nil
  /// Laid afresh rather than blended in: the whole thing seen nowhere near where it should be.
  var replace = false
  /// Made from a frame taken while the phone moved fast (a blur).
  var blurred = false
}

final class Run {
  let label: String
  /// Where it's pinned: its true depth times this (1.4: a raycast through it that hit the wall
  /// behind; 0.7: ARKit's points on something in front of it).
  let start: Float
  /// Cut once, then ARKit alone: no SAM after, no flow.
  let once: Bool
  /// Its depth put right by LiDAR inside each cut (LiveShape.setDepth).
  let lidar: Bool
  /// A still thing whose depth is known isn't carried by the flow between cuts (ARKit holds it).
  let noflow: Bool
  /// A still thing seen from about where it was last cut is asked about with the tight gate
  /// (LiveTracker.asking(still:turned:)).
  let tight: Bool
  /// Partly off the picture, one cut can make a still thing whose depth is known only 10% bigger
  /// or smaller (ARKit already scales it as the phone comes closer), not 40%.
  let clamp: Bool
  /// Its depth put right by where the lines of sight through its whole cuts cross (LiveShape.sight).
  let sight: Bool
  /// Followed by EdgeTAM instead of asking SAM (LensiARView.followEdge).
  let edge: Bool
  /// From halfway on, the phone's poses are in a world shifted by `worldShift`: ARKit paused (at
  /// 0.5x) and resumed with its world somewhere else.
  let shift: Bool
  /// The whole thing seen by EdgeTAM nowhere near where it should be is laid afresh where it's
  /// seen (LensiARView.followEdge), as is its first cut once the world has moved (as back at 1x
  /// from 0.5x); off: blended in through where it was, as before.
  let replace: Bool
  /// Carried by the flow moved whole (LiveFlow.carry) rather than bent with its thing (the app).
  let whole: Bool
  /// A cut from a frame taken while the phone moved fast (a blur) isn't taken for a still thing
  /// whose depth is known: ARKit holds that, and a blurred cut can only add its own errors.
  let skipBlur: Bool
  /// The flow starts looking where ARKit's poses say the outline went (LiveShape.guided), and so
  /// keeps carrying it while the phone moves fast.
  let guided: Bool
  /// How a still thing's cuts are blended in, rather than LiveTracker.asking's (OutlineMath.Smoothing.still).
  let stillSmoothing: OutlineMath.Smoothing?
  /// How long what's drawn of a still thing eases onto where it is (LiveShape.stillEase), rather than 0.15 s.
  let stillEase: Float?
  /// The world has just moved and it hasn't been cut since (LensiARView.returning).
  var returning = false
  var tracker: EdgeTAMTracker?
  var shape: LiveShape?
  var pending: Cut?
  var shown: [[CGPoint]] = []
  var j: [Double] = []
  var onBox: [Double] = []
  var middles: [CGPoint?] = []
  var depthRatio: [Double] = []
  var cuts = 0, refused = 0, carried = 0, measured = 0, replaced = 0

  init(_ label: String, start: Float, once: Bool = false, lidar: Bool = false, noflow: Bool = false, tight: Bool = false,
       clamp: Bool = false, sight: Bool = false, edge: Bool = false, shift: Bool = false, replace: Bool = true, whole: Bool = false,
       skipBlur: Bool = false, guided: Bool = false, stillSmoothing: OutlineMath.Smoothing? = nil, stillEase: Float? = nil) {
    self.label = label
    self.whole = whole
    self.skipBlur = skipBlur
    self.guided = guided
    self.stillSmoothing = stillSmoothing
    self.stillEase = stillEase
    self.start = start
    self.once = once
    self.lidar = lidar
    self.noflow = noflow
    self.tight = tight
    self.clamp = clamp
    self.sight = sight
    self.edge = edge
    self.shift = shift
    self.replace = replace
  }
}

let runs = [
  Run("arkit@true", start: 1, once: true),
  Run("arkit@far", start: 1.4, once: true),
  Run("app@true", start: 1),
  Run("app@far", start: 1.4),
  Run("whole@far", start: 1.4, whole: true),
  Run("lidar@far", start: 1.4, lidar: true),
  Run("steady@true", start: 1, noflow: true, tight: true),
  Run("steady@far", start: 1.4, noflow: true, tight: true),
  Run("steadyl@far", start: 1.4, lidar: true, noflow: true, tight: true),
  Run("clamp@true", start: 1, noflow: true, tight: true, clamp: true),
  Run("clampl@far", start: 1.4, lidar: true, noflow: true, tight: true, clamp: true),
  Run("sight@far", start: 1.4, noflow: true, tight: true, sight: true),
  Run("sight@near", start: 0.7, noflow: true, tight: true, sight: true),
] + (EdgeTAMTracker.Models.shared == nil ? [] : [
  Run("edge@true", start: 1, noflow: true, sight: true, edge: true),
  Run("edge@far", start: 1.4, noflow: true, sight: true, edge: true),
  // edge@far again, unchanged: how far two identical runs drift apart within one run.
  Run("edge2@far", start: 1.4, noflow: true, sight: true, edge: true),
  // A still thing's cuts blended in as a moving one's are, or lighter, and what's drawn eased quicker.
  Run("edgestd@far", start: 1.4, noflow: true, sight: true, edge: true, stillSmoothing: .standard),
  Run("edgelt@far", start: 1.4, noflow: true, sight: true, edge: true, stillSmoothing: .light),
  Run("edgeqk@far", start: 1.4, noflow: true, sight: true, edge: true, stillEase: 0.05),
  Run("edgelq@far", start: 1.4, noflow: true, sight: true, edge: true, stillSmoothing: .light, stillEase: 0.05),
  Run("edgel@far", start: 1.4, lidar: true, noflow: true, edge: true),
  // Settled: bent rather than moved whole (edgew), blurred cuts left out (edgeb), the flow guided by
  // the poses (edgeg). Their switches stay for another look.
  Run("shift@true", start: 1, noflow: true, sight: true, edge: true, shift: true),
  Run("shiftn@true", start: 1, noflow: true, sight: true, edge: true, shift: true, replace: false),
])
/// ARKit's world, resumed somewhere else after a pause (shift@*): turned 8 degrees about the
/// vertical and moved 25 cm across and 15 cm along.
let worldShift: simd_float4x4 = {
  let a: Float = 8 * .pi / 180
  var m = matrix_identity_float4x4
  m.columns.0 = simd_float4(cos(a), 0, -sin(a), 0)
  m.columns.2 = simd_float4(sin(a), 0, cos(a), 0)
  m.columns.3 = simd_float4(0.25, 0, -0.15, 1)
  return m
}()

extension FrozenCamera {
  /// The same camera as a world moved by `m` sees it.
  func shifted(_ m: simd_float4x4) -> FrozenCamera {
    FrozenCamera(transform: m * transform, intrinsics: intrinsics, resolution: resolution, crop: crop)
  }
}
/// EdgeTAM every other frame (15 times a second: LensiARView asks it up to 20).
let edgeEvery = 2
let edgeEncoder = EdgeTAMTracker.Models.shared.flatMap { try? EdgeTAMTracker.Encoder(models: $0) }
/// SAM asked every 4th frame (7.5 times a second; LensiARView asks as often as the phone keeps
/// up, at least 80 ms apart), its answer landing two frames (66 ms) after the frame it was asked about.
let every = 4
let latency = 2

// MARK: - 0.5x on the same walk-around

/// Every frame's camera, by capture time (the flat runs' gyro).
var flatCameras: [Double: FrozenCamera] = [:]

/// How far the camera turned from `a` to `b` (radians), whichever way.
func turnAngle(_ a: FrozenCamera, _ b: FrozenCamera) -> Float {
  let ra = simd_float3x3(simd_make_float3(a.transform.columns.0), simd_make_float3(a.transform.columns.1),
                         simd_make_float3(a.transform.columns.2))
  let rb = simd_float3x3(simd_make_float3(b.transform.columns.0), simd_make_float3(b.transform.columns.1),
                         simd_make_float3(b.transform.columns.2))
  let r = ra.transpose * rb
  return acos(min(max((r[0][0] + r[1][1] + r[2][2] - 1) / 2, -1), 1))
}

/// Upright points seen by `a`, where `b` sees them had the camera only turned: each one's line of
/// sight, far off. What the gyro says at 0.5x (UltraWideCamera.warp); the camera's moving isn't in it.
func turnedOnly(_ points: [CGPoint], from a: FrozenCamera, to b: FrozenCamera) -> [CGPoint] {
  let far = points.map { p -> simd_float3 in
    let (_, dir) = a.ray(p)
    return b.position + dir * 100
  }
  return b.upright(far) ?? points
}

/// 0.5x on the same walk (LensiARView.wideFrame, FlatFollower): no world, EdgeTAM's answers on the
/// picture at the phone's timing (one tracker for all of these: what it finds doesn't depend on how
/// it's drawn), each glided into what was shown on its frame and moved on between answers by
///
///   flat-none   nothing: held where the last answer put it
///   flat-gyro   how the camera turned (its poses' rotation alone: what the gyro says), the app before
///   flat-flow   the picture's own pixels (LiveFlow.bend), turned where the flow can't say
///   flat-fast   the same, turned while the camera turns fast (LiveShape.fastTurn: a blur)
///   flat-guide  flat-flow with the flow starting where the gyro says each point went
final class FlatRun {
  let label: String
  let follower = FlatFollower()
  /// Its frames go to the follower (the flow can bend it).
  let flow: Bool
  var shown: [[CGPoint]] = []
  var j: [Double] = []
  var onBox: [Double] = []
  var middles: [CGPoint?] = []

  init(_ label: String, flow: Bool, gyro: Bool, fast: Bool = false, guided: Bool = false) {
    self.label = label
    self.flow = flow
    follower.guided = guided
    if gyro {
      follower.turn = { points, a, b in
        guard let ca = flatCameras[a], let cb = flatCameras[b] else { return points }
        return turnedOnly(points, from: ca, to: cb)
      }
    }
    if !flow {
      follower.gyroFirst = { _, _ in true }
    } else if fast {
      follower.gyroFirst = { a, b in
        guard b > a, let ca = flatCameras[a], let cb = flatCameras[b] else { return false }
        return turnAngle(ca, cb) / Float(b - a) > LiveShape.fastTurn
      }
    }
  }
}

let flatRuns: [FlatRun] = EdgeTAMTracker.Models.shared == nil ? [] : [
  FlatRun("flat-none", flow: false, gyro: false),
  FlatRun("flat-gyro", flow: false, gyro: true),
  FlatRun("flat-flow", flow: true, gyro: true),
  // Settled, no different from flat-flow in two runs: the gyro while turning fast (flat-fast), the
  // gyro telling the flow where to look (flat-guide).
]
var flatTracker: EdgeTAMTracker?
var flatPending: (due: Int, t: Double, cut: EdgeTAMTracker.Cut)?
var flatCuts = 0

var reference: [[CGPoint]] = []
var boxMiddles: [CGPoint?] = []
var frameNames: [String] = []
var lidarCheck: [Double] = []
var fastFrames = 0
var previous: (frame: LiveFlow.Frame, camera: FrozenCamera, t: Double)?
var lastPose: (transform: simd_float4x4, t: Double)?
var phoneTurn: Float = 0, phoneMove: Float = 0
var size = CGSize(width: 480, height: 640)

for (k, f) in window.enumerated() {
  guard let camera = cameras[f], let image = upright(pngs[f].url) else { continue }
  frameNames.append(pngs[f].url.lastPathComponent)
  size = CGSize(width: image.width, height: image.height)
  let w = Int(size.width), h = Int(size.height)
  let t = times[f]
  try sam.prepare(image: image, id: "frame", force: true)
  let flowFrame = LiveFlow.frame(image)
  // EdgeTAM's encoder, once for every run that follows with it, on the frames it looks at.
  let edgeFrame = (k == 0 || k % edgeEvery == 0) ? edgeEncoder.flatMap { try? $0.encode(CIImage(cgImage: image)) } : nil

  // How fast the phone itself turns and moves (LensiARView.trackPhone).
  if let last = lastPose {
    let dt = Float(t - last.t)
    if dt > 0.001, dt < 0.5 {
      let a = last.transform, m = camera.transform
      let r = simd_float3x3(simd_make_float3(a.columns.0), simd_make_float3(a.columns.1), simd_make_float3(a.columns.2)).transpose
        * simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
      let turned = acos(min(max((r[0][0] + r[1][1] + r[2][2] - 1) / 2, -1), 1))
      let moved = simd_distance(simd_make_float3(a.columns.3), simd_make_float3(m.columns.3))
      phoneTurn = phoneTurn * 0.6 + turned / dt * 0.4
      phoneMove = phoneMove * 0.6 + moved / dt * 0.4
    }
  }
  lastPose = (transform: camera.transform, t: t)
  let fast = phoneTurn > LiveShape.fastTurn || phoneMove > LiveShape.fastMove
  if fast { fastFrames += 1 }

  // What it should look like from here.
  let truthAsk = truthPrompt(camera, scale: size)
  var truth: [CGPoint] = []
  if let truthAsk {
    let m = try sam.segment(id: "frame", points: [truthAsk.point], labels: [1], box: truthAsk.box)
    if m.polygon.count > 2 { truth = OutlineMath.resample(m.polygon, scale: size) }
  }
  reference.append(truth)
  let truthBits = raster(truth, w: w, h: h)
  let boxBits = picture(thing, camera).map { raster($0, w: w, h: h) }
  boxMiddles.append(camera.upright([thing.centre])?.first.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
  let trueAhead = -simd_mul(camera.transform.inverse, simd_float4(thing.centre, 1)).z
  let lidarMap = depthMap(at: t)
  if let lidarMap, !truth.isEmpty, trueAhead > 0.05,
     let d = LiveShape.depthInside(truth, depth: { lidarMap.at(upright: $0) }) {
    lidarCheck.append(Double(d / trueAhead))
  }

  let shiftFrom = window.count / 2
  let trueCamera = camera
  for run in runs {
    // The phone as this run's ARKit sees itself (shift@*: in a world moved halfway through).
    let camera = run.shift && k >= shiftFrom ? trueCamera.shifted(worldShift) : trueCamera
    if run.shift, k == shiftFrom { run.returning = true }
    // Between cuts, its own pixels (LensiARView.flowLive), not while the phone moves fast.
    if !run.once, !run.shift, !fast || run.guided, var shape = run.shape, shape.misses < 2, !(run.noflow && shape.still && shape.depthKnown), let previous, let flowFrame {
      if shape.carry(from: previous.frame, previous.camera, at: previous.t, to: flowFrame, camera, at: t) { run.carried += 1 }
      run.shape = shape
    }
    // A cut back from SAM (LensiARView.takeLive): blended in, and what it says about how far
    // the thing is.
    if let cut = run.pending, cut.due <= k {
      run.pending = nil
      if var shape = run.shape {
        // A blur's cut of a thing ARKit holds: not taken, nor measured from (edgeb@far).
        let skip = run.skipBlur && cut.blurred && shape.still && shape.depthKnown && !cut.replace
        if let world = cut.world, cut.replace {
          // Laid afresh where it was seen (LensiARView.takeLive), still pinned.
          shape = LiveShape(world: world, at: cut.t, follows: true)
          shape.bends = !run.whole
          shape.guided = run.guided
          if let e = run.stillEase { shape.stillEase = e }
          shape.pinned = true
          shape.depthKnown = cut.depth != nil
        } else if skip {
        } else if let world = cut.world {
          shape.take(world, at: cut.t, how: cut.smoothing, measure: !fast, seenFrom: cut.camera.position)
        } else {
          shape.misses += 1
          shape.velocity *= 0.5
        }
        if skip {
        } else if let depth = cut.depth {
          shape.setDepth(depth, seenBy: cut.camera, weight: LiveShape.lidarWeight)
          run.measured += 1
        } else if run.sight, let middle = cut.middle, shape.sight(middle, seenBy: cut.camera, at: cut.t) {
          run.measured += 1
        }
        run.shape = shape
      }
    }
    if k == 0 {
      // Pinned from the strip (LensiARView.scrubLay): SAM's cut, laid on a plane facing the
      // camera at the depth the phone took it to be, through a point well inside it.
      guard truth.count > 2, trueAhead > 0.05 else {
        print("\(name): SAM found nothing to pin in the first frame")
        exit(1)
      }
      let middle = LiveTracker.interiorPoint(truth, scale: size)
      let (origin, dir) = camera.ray(middle)
      let plane = camera.withPlane(through: origin + dir * camera.range(depth: trueAhead * run.start, through: middle))
      let laid = truth.compactMap { plane.onPlane($0) }
      guard laid.count == truth.count else {
        print("\(name): the first cut couldn't be laid in the world")
        exit(1)
      }
      var shape = LiveShape(world: laid, at: t, follows: true)
      shape.bends = !run.whole
      shape.guided = run.guided
      if let e = run.stillEase { shape.stillEase = e }
      shape.pinned = true
      // Pinned at its true depth: as the app pins where LiDAR or ARKit's points put it.
      shape.depthKnown = run.start == 1
      run.shape = shape
      // EdgeTAM started from the pinned cut's box (LensiARView.followEdge's first step).
      if run.edge, let edgeFrame, let models = EdgeTAMTracker.Models.shared {
        let tracker = try EdgeTAMTracker(models: models)
        _ = try tracker.start(edgeFrame, box: LiveTracker.bounds(truth))
        run.tracker = tracker
      }
    } else if run.edge, run.pending == nil, k % edgeEvery == 0, let shape = run.shape, let tracker = run.tracker, let edgeFrame {
      // EdgeTAM's step (LensiARView.followEdge): what it finds is laid in the world, up close the
      // whole outline going where the part on the picture went.
      let cut = try tracker.step(edgeFrame)
      run.cuts += 1
      var world: [simd_float3]?
      var depth: Float?
      var middle: CGPoint?
      var replace = false
      let now = shape.placed(at: t)
      if cut.visible {
        let seen = OutlineMath.resample(cut.outline, scale: size)
        var ring = seen
        let edgeOf = { (p: [CGPoint]) in p.contains { $0.x < 0.006 || $0.x > 0.994 || $0.y < 0.006 || $0.y > 0.994 } }
        // Up close the part on the picture moves a still thing whose depth is known only a little,
        // and is taken only if it's plausibly the thing (as LensiARView.segmentLive asks).
        var taken = true
        // The whole thing on the picture, nowhere near where it should be (or where it should be is
        // behind the phone): the world moved under it. Laid afresh where it's seen, as far off as it
        // was along its line of sight (or where LiDAR puts it).
        let predictedNow = camera.upright(now)
        let whole = !edgeOf(seen)
        let astray = run.returning || (whole && (predictedNow.map { LiveTracker.iou(seen, LiveTracker.clipped($0)) < 0.05 } ?? true))
        if run.replace, astray {
          // Up close, the whole outline as it should be, moved onto the part on the picture however
          // far that is from where it should be (that's what's stale).
          if !whole, let predicted = predictedNow, LiveTracker.visibleFraction(predicted) < LiveTracker.wholeVisible,
             let moved = LiveTracker.follow(cut: seen, predicted: predicted, gate: .any, scaleLimit: shape.still && shape.depthKnown ? 1.1 : 1.4) {
            ring = moved
          }
          let inside = CGPoint(x: ring.map(\.x).reduce(0, +) / CGFloat(ring.count), y: ring.map(\.y).reduce(0, +) / CGFloat(ring.count))
          let (origin, dir) = camera.ray(inside)
          var range = min(max(simd_distance(camera.position, OutlineMath.centre(now)), 0.2), 6)
          if run.lidar, let lidarMap, let d = LiveShape.depthInside(seen, depth: { lidarMap.at(upright: $0) }) {
            depth = d
            range = camera.range(depth: d, through: inside)
          }
          let plane = camera.withPlane(through: origin + dir * range)
          let laid = ring.compactMap { plane.onPlane($0) }
          if laid.count == ring.count { world = laid }
          replace = true
          run.replaced += 1
          run.returning = false
        } else {
          if edgeOf(seen), let predicted = predictedNow, LiveTracker.visibleFraction(predicted) < LiveTracker.wholeVisible {
            let limit: CGFloat = shape.still && shape.depthKnown ? 1.1 : 1.4
            if let followed = LiveTracker.follow(cut: seen, predicted: predicted, gate: .loose, scaleLimit: limit) {
              ring = followed
            } else {
              taken = false
              run.refused += 1
            }
          }
          if taken {
            let plane = camera.withPlane(through: OutlineMath.centre(now))
            let laid = ring.compactMap { plane.onPlane($0) }
            if laid.count == ring.count { world = laid }
            if run.lidar, let lidarMap { depth = LiveShape.depthInside(seen, depth: { lidarMap.at(upright: $0) }) }
            if LiveShape.sightable(seen) {
              middle = CGPoint(x: seen.map(\.x).reduce(0, +) / CGFloat(seen.count), y: seen.map(\.y).reduce(0, +) / CGFloat(seen.count))
            }
          }
        }
      }
      let asking = LiveTracker.asking(still: shape.still)
      let smoothing = shape.still ? run.stillSmoothing ?? asking.smoothing : asking.smoothing
      var pending = Cut(due: k + latency, t: t, camera: camera, world: world, depth: depth, smoothing: smoothing)
      pending.middle = middle
      pending.replace = replace
      pending.blurred = fast
      run.pending = pending
    } else if !run.edge, !run.once, run.pending == nil, k % every == 0, let shape = run.shape {
      // SAM asked where it should be now (LensiARView.segmentLive's follow): up close, about the
      // part on the picture, and the whole outline goes where that part went.
      let now = shape.placed(at: t)
      let still = shape.misses >= 2 || shape.still
      let turned = run.tight && shape.depthKnown ? shape.turned(from: camera.position) : nil
      let asking = LiveTracker.asking(still: still, turned: turned)
      if let predicted = camera.upright(now), LiveTracker.visibleFraction(predicted) >= LiveTracker.minVisible,
         let prompt = LiveTracker.prompt(for: predicted, scale: size, grow: asking.grow) {
        let m = try sam.segment(id: "frame", points: [prompt.point], labels: [1], box: prompt.box, prior: predicted)
        run.cuts += 1
        var world: [simd_float3]?
        var depth: Float?
        if m.score >= 0.5, m.polygon.count > 2 {
          let cut = OutlineMath.resample(m.polygon, scale: size)
          let limit: CGFloat = run.clamp && still && shape.depthKnown ? 1.1 : 1.4
          if let ring = LiveTracker.follow(cut: cut, predicted: predicted, gate: asking.gate, scaleLimit: limit) {
            let plane = camera.withPlane(through: OutlineMath.centre(now))
            let laid = ring.compactMap { plane.onPlane($0) }
            if laid.count == ring.count { world = laid }
            if run.lidar, let lidarMap { depth = LiveShape.depthInside(cut, depth: { lidarMap.at(upright: $0) }) }
          } else {
            run.refused += 1
          }
        }
        var pending = Cut(due: k + latency, t: t, camera: camera, world: world, depth: depth, smoothing: asking.smoothing)
        if world != nil, m.polygon.count > 2, LiveShape.sightable(m.polygon) {
          // A cut of the whole thing: its middle's line of sight (LiveShape.sight).
          let ring = OutlineMath.resample(m.polygon, scale: size)
          pending.middle = CGPoint(x: ring.map(\.x).reduce(0, +) / CGFloat(ring.count), y: ring.map(\.y).reduce(0, +) / CGFloat(ring.count))
        }
        run.pending = pending
      }
    }
    // What the screen shows (LensiARView.layoutLive): eased onto where it is.
    var outline: [CGPoint] = []
    var centre: simd_float3?
    if var shape = run.shape {
      let drawn = run.once ? shape.world : shape.draw(at: t)
      run.shape = shape
      outline = camera.upright(drawn) ?? []
      centre = OutlineMath.centre(drawn)
    }
    run.shown.append(outline)
    let bits = raster(outline, w: w, h: h)
    if !truth.isEmpty { run.j.append(maskIoU(bits, truthBits)) }
    if let boxBits, !outline.isEmpty { run.onBox.append(share(bits, inside: boxBits)) }
    run.middles.append(centre.flatMap { camera.upright([$0])?.first }.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
    if let centre, trueAhead > 0.05 {
      let ahead = -simd_mul(camera.transform.inverse, simd_float4(centre, 1)).z
      if ahead > 0 { run.depthRatio.append(Double(ahead / trueAhead)) }
    }
  }
  if let flowFrame { previous = (frame: flowFrame, camera: camera, t: t) }

  // 0.5x (FlatFollower): the frame, then an answer that's due, then a look, as LensiARView has them.
  if !flatRuns.isEmpty {
    flatCameras[t] = camera
    flatCameras = flatCameras.filter { t - $0.key < 3 }
    for run in flatRuns { run.follower.add(run.flow ? flowFrame : nil, at: t) }
    if let p = flatPending, p.due <= k {
      flatPending = nil
      let ring: [CGPoint]? = p.cut.visible ? OutlineMath.resample(p.cut.outline, scale: size) : nil
      for run in flatRuns { run.follower.answer(["": ring], at: p.t, size: size) }
    }
    if k == 0 {
      // Pinned from the strip: its cut is there at once, and EdgeTAM starts from its box.
      if let edgeFrame, let models = EdgeTAMTracker.Models.shared, truth.count > 2 {
        let tracker = try EdgeTAMTracker(models: models)
        _ = try tracker.start(edgeFrame, box: LiveTracker.bounds(truth))
        flatTracker = tracker
        for run in flatRuns { run.follower.place("", truth, at: t) }
      }
    } else if flatPending == nil, k % edgeEvery == 0, let tracker = flatTracker, let edgeFrame {
      let cut = try tracker.step(edgeFrame)
      flatCuts += 1
      flatPending = (due: k + latency, t: t, cut: cut)
      for run in flatRuns { run.follower.looking(at: t) }
    }
    for run in flatRuns {
      let outline = run.follower.things[""]?.shown ?? []
      run.shown.append(outline)
      let bits = raster(outline, w: w, h: h)
      if !truth.isEmpty { run.j.append(maskIoU(bits, truthBits)) }
      if let boxBits, !outline.isEmpty { run.onBox.append(share(bits, inside: boxBits)) }
      run.middles.append(outline.isEmpty ? nil : CGPoint(x: outline.map(\.x).reduce(0, +) / CGFloat(outline.count) * size.width,
                                                         y: outline.map(\.y).reduce(0, +) / CGFloat(outline.count) * size.height))
    }
  }
}

let lidarRatio = lidarCheck.isEmpty ? -1 : lidarCheck.sorted()[lidarCheck.count / 2]
print(String(format: "%@: the phone moved fast in %ld of %ld frames; the 3D box's own lurch %.1f px; LiDAR inside the cut / the box's middle: %.2f (%ld frames)",
             name, fastFrames, frameNames.count, jerk(boxMiddles), lidarRatio, lidarCheck.count))
var runsOut: [[String: Any]] = []
for run in runs {
  let lost = run.j.isEmpty ? -1 : Double(run.j.filter { $0 < 0.5 }.count) / Double(run.j.count)
  let depthOff = mean(run.depthRatio.map { abs(log($0)) })
  let lastDepth = run.depthRatio.last ?? -1
  let slipped = slip(run.middles, against: boxMiddles)
  print(String(format: "  %@ J %.1f%%  lost %.0f%%  on the box %.1f%%  slip %.1f px  lurch %.1f px  depth off %.0f%% (ends x%.2f)  (%ld cuts, %ld refused, %ld carried, %ld measured, %ld laid afresh)",
               run.label.padding(toLength: 11, withPad: " ", startingAt: 0), mean(run.j) * 100, lost * 100, mean(run.onBox) * 100,
               slipped, jerk(run.middles), (exp(depthOff) - 1) * 100, lastDepth, run.cuts, run.refused, run.carried, run.measured, run.replaced))
  runsOut.append(["label": run.label, "J": mean(run.j), "lost": lost, "onBox": mean(run.onBox), "slip": slipped, "jerk": jerk(run.middles),
                  "depthOff": depthOff, "lastDepth": lastDepth, "cuts": run.cuts, "refused": run.refused, "carried": run.carried,
                  "measured": run.measured, "jPerFrame": run.j, "depthPerFrame": run.depthRatio,
                  "outlines": run.shown.map { $0.flatMap { [Double($0.x), Double($0.y)] } }])
}
for run in flatRuns {
  let lost = run.j.isEmpty ? -1 : Double(run.j.filter { $0 < 0.5 }.count) / Double(run.j.count)
  let slipped = slip(run.middles, against: boxMiddles)
  print(String(format: "  %@ J %.1f%%  lost %.0f%%  on the box %.1f%%  slip %.1f px  lurch %.1f px  (%ld cuts, flat)",
               run.label.padding(toLength: 11, withPad: " ", startingAt: 0), mean(run.j) * 100, lost * 100, mean(run.onBox) * 100,
               slipped, jerk(run.middles), flatCuts))
  runsOut.append(["label": run.label, "J": mean(run.j), "lost": lost, "onBox": mean(run.onBox), "slip": slipped, "jerk": jerk(run.middles),
                  "cuts": flatCuts, "flat": true, "jPerFrame": run.j,
                  "outlines": run.shown.map { $0.flatMap { [Double($0.x), Double($0.y)] } }])
}
let summary: [String: Any] = [
  "name": name, "thing": thing.label, "frames": frameNames.count, "frameNames": frameNames,
  "first": window.first!, "seconds": times[window.last!] - times[window.first!],
  "nearest": Double(distances.min() ?? 0), "furthest": Double(distances.max() ?? 0), "closeFrames": best.close,
  "distances": distances.map { Double($0) }, "visible": visibles.map { Double($0) },
  "travelCm": Double(travel * 100), "turnDegrees": Double(turn * 180 / .pi), "fastFrames": fastFrames,
  "lidarRatio": lidarRatio, "truthJerk": jerk(boxMiddles), "width": Int(size.width), "height": Int(size.height),
  "upInImage": [Double(upInImage.x), Double(upInImage.y)],
  "reference": reference.map { $0.flatMap { [Double($0.x), Double($0.y)] } }, "runs": runsOut,
]
let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
try data.write(to: outDir.appendingPathComponent("\(name).json"))
