// The app's EdgeTAMTracker (app/modules/lensi-ar/ios/EdgeTAMTracker.swift) on a folder of frames,
// exactly as the phone runs it on the camera: pinned with a box on the first frame, followed
// through the rest. CI runs it on the bottle video (tools/edgetam/ci.sh).
//
//   edgetrack <frames dir> <out.json> <x0,y0,x1,y1 in the first frame's pixels> [frames]
//
// With LENSI_MODELS_DIR holding the four compiled models. Writes every frame's outline
// (fractions of the frame), object score, IoU estimate and milliseconds per step, and "shown":
// the outline as the phone draws it on a flat picture, each cut glided into the last as
// LensiARView does at 0.5x (OutlineMath.glide, in pixels). EDGETRACK_EVERY=n runs EdgeTAM on every n-th frame
// only, as a phone that keeps up with 30/n frames a second would; the frames between show the
// last outline.
//
// EDGETRACK_LIVE_MS=<ms> plays the clip as the phone's camera instead (`live` below): its frames
// at their own times (EDGETRACK_FPS, 30), EdgeTAM started on a frame only when the app would
// start it, each answer ready that many milliseconds after its frame and drawn from the first
// frame after that, and the outline moved between answers. Writes each frame's "live" outline.
// Between answers the outline is bent with the thing (LiveFlow.bend, FlatFollower: as the app follows
// a pinned thing at 0.5x); EDGETRACK_BEND=0 moves it whole instead (LiveFlow.carry); EDGETRACK_GLIDE=0
// takes each answer as it is rather than gliding into it.
import CoreImage
import Foundation
import ImageIO
import simd

let args = CommandLine.arguments
guard args.count >= 4 else {
  print("usage: edgetrack <frames dir> <out.json> <x0,y0,x1,y1> [frames]")
  exit(2)
}
let framesDir = URL(fileURLWithPath: args[1])
let outPath = args[2]
let box = args[3].split(separator: ",").compactMap { Double($0) }
let limit = args.count > 4 ? Int(args[4]) ?? Int.max : Int.max
guard box.count == 4 else { print("box: x0,y0,x1,y1"); exit(2) }

let names = ((try? FileManager.default.contentsOfDirectory(atPath: framesDir.path)) ?? [])
  .filter { $0.hasSuffix(".jpg") }.sorted().prefix(limit)
let loadStart = CFAbsoluteTimeGetCurrent()
guard let models = EdgeTAMTracker.Models.shared else {
  print("EdgeTAM models not found (LENSI_MODELS_DIR)")
  exit(1)
}
let loadSeconds = CFAbsoluteTimeGetCurrent() - loadStart
print(String(format: "models loaded in %.1f s", loadSeconds))
let encoder = try EdgeTAMTracker.Encoder(models: models)
let tracker = try EdgeTAMTracker(models: models)
/// How many levels the flow's pyramid has (LiveFlow.levels; EDGETRACK_FLOW_LEVELS to try others).
let flowDepth = Int(ProcessInfo.processInfo.environment["EDGETRACK_FLOW_LEVELS"] ?? "") ?? LiveFlow.levels

func r(_ v: Double, _ places: Double = 100000) -> Double { (v * places).rounded() / places }

/// The clip as the phone's camera, followed as the app follows a pinned thing at 0.5x (LensiARView's
/// wideFrame through FlatFollower). A look starts on a frame only once the last answer is in and
/// 50 ms have passed since the last one started (the app's limit: up to 20 a second); its answer is
/// ready `latency` seconds after that frame, and is used from the first frame shown after that:
/// glided into what was shown on its own frame (OutlineMath.glide, in pixels), then brought on to
/// the frame being shown, and between answers the outline is bent with its thing frame to frame by
/// the picture's own pixels (LiveFlow.bend). A clip has no gyro: where the flow can't say, the
/// outline stays where it is (the phone turns it by the gyro).
func live(latency: Double, fps: Double, bends: Bool, glides: Bool, bending: LiveFlow.Bending = .standard) throws -> [String: Any] {
  struct Pending {
    let frame: Int
    let t: Double
    let ready: Double
    let cut: EdgeTAMTracker.Cut
  }
  let follower = FlatFollower()
  follower.bends = bends
  follower.glides = glides
  follower.bending = bending
  follower.pinsEdges = ProcessInfo.processInfo.environment["EDGETRACK_EDGE_PIN"] == "1"
  var out: [[String: Any]] = []
  var pending: Pending?
  var lastStart = -Double.infinity
  var looks = 0, answers = 0
  var stepMs: [Double] = []
  for (g, name) in names.enumerated() {
    let url = framesDir.appendingPathComponent(name)
    guard let picture = CIImage(contentsOf: url), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
      print("can't read \(name)")
      continue
    }
    let t = Double(g) / fps
    let w = picture.extent.width, h = picture.extent.height
    let size = CGSize(width: w, height: h)
    follower.add(LiveFlow.frame(image, depth: flowDepth), at: t)
    var answered = -1
    if let p = pending, p.ready <= t + 1e-9 {
      pending = nil
      answers += 1
      answered = p.frame
      follower.answer(["": p.cut.visible ? OutlineMath.resample(p.cut.outline, scale: size) : nil], at: p.t, size: size)
    }
    var looked = false
    if g == 0 {
      // Pinned on this frame: the outline the strip showed is there at once.
      let b = CGRect(x: box[0] / w, y: box[1] / h, width: (box[2] - box[0]) / w, height: (box[3] - box[1]) / h)
      let cut = try tracker.start(encoder.encode(picture), box: b)
      if cut.visible { follower.place("", OutlineMath.resample(cut.outline, scale: size), at: t) }
      lastStart = t
      looked = true
    } else if pending == nil, t - lastStart > 0.05 {
      let wall = CFAbsoluteTimeGetCurrent()
      let cut = try tracker.step(encoder.encode(picture))
      stepMs.append((CFAbsoluteTimeGetCurrent() - wall) * 1000)
      pending = Pending(frame: g, t: t, ready: t + latency, cut: cut)
      follower.looking(at: t)
      lastStart = t
      looks += 1
      looked = true
    }
    out.append([
      "name": name,
      "live": (follower.things[""]?.shown ?? []).flatMap { [r(Double($0.x)), r(Double($0.y))] },
      "answer": answered,
      "look": looked,
    ])
  }
  let seconds = Double(names.count) / fps
  print(String(format: "live at %.0f ms: %ld looks over %.1f s (%.1f a second), each answer %.0f ms after its frame", latency * 1000, looks,
               seconds, Double(looks) / max(seconds, 1e-9), latency * 1000))
  return ["frames": out, "box": box, "latencyMs": latency * 1000, "fps": fps, "looks": looks, "answers": answers,
          "macStepMs": r(stepMs.sorted().dropFirst(stepMs.count / 2).first ?? 0, 10)]
}

if let ms = Double(ProcessInfo.processInfo.environment["EDGETRACK_LIVE_MS"] ?? "") {
  let fps = Double(ProcessInfo.processInfo.environment["EDGETRACK_FPS"] ?? "") ?? 30
  let env = ProcessInfo.processInfo.environment
  // LiveFlow.bend's settings, to try others (EDGETRACK_BEND_INSET, _MOST, _SIGMA, _HOME).
  var bending = LiveFlow.Bending.standard
  if let v = Float(env["EDGETRACK_BEND_INSET"] ?? "") { bending.inset = v }
  if let v = Float(env["EDGETRACK_BEND_MOST"] ?? "") { bending.most = v }
  if let v = Float(env["EDGETRACK_BEND_SIGMA"] ?? "") { bending.sigma = v }
  if let v = Float(env["EDGETRACK_BEND_HOME"] ?? "") { bending.home = v }
  if env["EDGETRACK_BEND_SEEDED"] == "1" { bending.seeded = true }
  let result = try live(latency: ms / 1000, fps: fps, bends: env["EDGETRACK_BEND"] != "0", glides: env["EDGETRACK_GLIDE"] != "0", bending: bending)
  try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: outPath))
  exit(0)
}

let every = max(1, Int(ProcessInfo.processInfo.environment["EDGETRACK_EVERY"] ?? "") ?? 1)
var frames: [[String: Any]] = []
var totals: [String: [Double]] = [:]
var shown: [simd_float3]?
var last: [String: Any]?
for (i, name) in names.enumerated() {
  guard let picture = CIImage(contentsOf: framesDir.appendingPathComponent(name)) else {
    print("can't read \(name)")
    continue
  }
  if i % every != 0, var held = last {
    held["name"] = name
    held["held"] = true
    frames.append(held)
    continue
  }
  let w = picture.extent.width, h = picture.extent.height
  let wall = CFAbsoluteTimeGetCurrent()
  let cut: EdgeTAMTracker.Cut
  if i == 0 {
    let b = CGRect(x: box[0] / w, y: box[1] / h, width: (box[2] - box[0]) / w, height: (box[3] - box[1]) / h)
    cut = try tracker.start(encoder.encode(picture), box: b)
  } else {
    cut = try tracker.step(encoder.encode(picture))
  }
  let total = (CFAbsoluteTimeGetCurrent() - wall) * 1000
  for (k, v) in cut.ms { totals[k, default: []].append(v) }
  totals["total", default: []].append(total)
  // As the phone draws it on a flat picture: glided from the last one, in pixels
  // (LensiARView.wideFrame).
  if cut.visible {
    let size = CGSize(width: w, height: h)
    let ring = OutlineMath.resample(cut.outline, scale: size).map { simd_float3(Float($0.x * w), Float($0.y * h), 0) }
    shown = OutlineMath.glide(shown, ring)
  } else {
    shown = nil
  }
  let drawn = (shown ?? []).flatMap { [r(Double($0.x) / Double(w)), r(Double($0.y) / Double(h))] }
  frames.append([
    "name": name,
    "shown": drawn,
    "outline": cut.outline.flatMap { [r(Double($0.x)), r(Double($0.y))] },
    "score": r(Double(cut.score), 1000),
    "iou": r(Double(cut.iou), 1000),
    "area": r(Double(cut.area)),
    "ms": cut.ms.mapValues { r($0, 10) }.merging(["total": r(total, 10)]) { a, _ in a },
  ])
  last = frames.last
  if i % 25 == 0 || !cut.visible {
    print(String(format: "frame %ld: score %.2f, IoU estimate %.3f, area %.4f, %ld outline points, %.0f ms", i, cut.score, cut.iou, cut.area,
                 cut.outline.count, total))
  }
}

func median(_ v: [Double]) -> Double {
  let s = v.sorted()
  return s.isEmpty ? 0 : s[s.count / 2]
}
var timing: [String: Double] = [:]
// The first frames include Core ML's warm-up; the medians don't care.
for (k, v) in totals { timing[k] = r(median(v), 10) }
let summary = timing.keys.sorted().map { "\($0) \(timing[$0]!) ms" }.joined(separator: ", ")
print("\(frames.count) frames; median per frame: \(summary)")
let result: [String: Any] = ["frames": frames, "box": box, "medianMs": timing, "loadSeconds": r(loadSeconds, 10)]
let data = try JSONSerialization.data(withJSONObject: result)
try data.write(to: URL(fileURLWithPath: outPath))
