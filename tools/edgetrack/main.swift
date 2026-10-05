// The app's EdgeTAMTracker (app/modules/lensi-ar/ios/EdgeTAMTracker.swift) on a folder of frames,
// exactly as the phone runs it on the camera: pinned with a box on the first frame, followed
// through the rest. CI runs it on the bottle video (tools/edgetam/ci.sh).
//
//   edgetrack <frames dir> <out.json> <x0,y0,x1,y1 in the first frame's pixels> [frames]
//
// With LENSI_MODELS_DIR holding the four compiled models. Writes every frame's outline
// (fractions of the frame), object score, IoU estimate and milliseconds per step.
import CoreImage
import Foundation

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

func r(_ v: Double, _ places: Double = 100000) -> Double { (v * places).rounded() / places }

var frames: [[String: Any]] = []
var totals: [String: [Double]] = [:]
for (i, name) in names.enumerated() {
  guard let picture = CIImage(contentsOf: framesDir.appendingPathComponent(name)) else {
    print("can't read \(name)")
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
  frames.append([
    "name": name,
    "outline": cut.outline.flatMap { [r(Double($0.x)), r(Double($0.y))] },
    "score": r(Double(cut.score), 1000),
    "iou": r(Double(cut.iou), 1000),
    "area": r(Double(cut.area)),
    "ms": cut.ms.mapValues { r($0, 10) }.merging(["total": r(total, 10)]) { a, _ in a },
  ])
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
