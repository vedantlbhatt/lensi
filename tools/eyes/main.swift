// Runs Lensi's on-device "eyes" (app/modules/lensi-ar/ios/Analyzer.swift with
// Detector and SAMSegmenter) over a folder of images on macOS, and writes one
// JSON and one overlay PNG per image. Built and run by CI:
//
//   swiftc -O -o eyes tools/eyes/main.swift tools/eyes/live.swift \
//     app/modules/lensi-ar/ios/{Analyzer,Detector,SAMSegmenter,OutlineMath}.swift
//   LENSI_MODELS_DIR=<dir with *.mlmodelc> ./eyes <images dir> <out dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("usage: eyes <images dir> <out dir>")
  exit(2)
}
let inDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let analyzer = Analyzer()
let files = (try? FileManager.default.contentsOfDirectory(at: inDir, includingPropertiesForKeys: nil)) ?? []
let images = files.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
print("SAM models: \(SAMSegmenter.shared == nil ? "not found (Vision fallback)" : "loaded")")

var summary: [[String: Any]] = []

func pts(_ any: Any?) -> [CGPoint] {
  (any as? [[String: Any]] ?? []).compactMap { p in
    guard let x = p["x"] as? Double, let y = p["y"] as? Double else { return nil }
    return CGPoint(x: x, y: y)
  }
}

func rect(_ any: Any?) -> CGRect? {
  guard let b = any as? [String: Any], let x = b["x"] as? Double, let y = b["y"] as? Double,
        let w = b["w"] as? Double, let h = b["h"] as? Double else { return nil }
  return CGRect(x: x, y: y, width: w, height: h)
}

for url in images {
  let name = url.deletingPathExtension().lastPathComponent
  let started = Date()
  do {
    let result = try analyzer.analyze(uri: url.absoluteString)
    let image = try Analyzer.loadUpright(uri: url.absoluteString)
    let W = CGFloat(image.width), H = CGFloat(image.height)

    // Point-prompt the segmenter at the middle of each detected object and text line.
    var parts: [[String: Any]] = []
    var prompts: [CGPoint] = []
    for o in (result["objects"] as? [[String: Any]] ?? []).prefix(3) { if let r = rect(o["box"]) { prompts.append(CGPoint(x: r.midX, y: r.midY)) } }
    for t in (result["text"] as? [[String: Any]] ?? []).prefix(2) { if let r = rect(t["box"]) { prompts.append(CGPoint(x: r.midX, y: r.midY)) } }
    for p in prompts {
      if let seg = try analyzer.segment(uri: url.absoluteString, at: p) {
        parts.append(["at": ["x": Double(p.x), "y": Double(p.y)], "engine": seg["engine"] ?? "", "points": (seg["polygon"] as? [Any])?.count ?? 0, "polygon": seg["polygon"] ?? []])
      }
    }

    // Overlay: subject (yellow), other instances (white), SAM parts at prompts (magenta), SAM part
    // proposals from analyze() (green), text boxes (cyan), objects (orange).
    let proposals = result["parts"] as? [[String: Any]] ?? []
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    // Flip so normalized top-left coordinates draw correctly.
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    let lw = max(2, min(W, H) / 220)
    func stroke(_ poly: [CGPoint], _ color: CGColor, _ width: CGFloat) {
      guard poly.count > 2 else { return }
      ctx.beginPath()
      ctx.move(to: CGPoint(x: poly[0].x * W, y: poly[0].y * H))
      for q in poly.dropFirst() { ctx.addLine(to: CGPoint(x: q.x * W, y: q.y * H)) }
      ctx.closePath()
      ctx.setStrokeColor(color)
      ctx.setLineWidth(width)
      ctx.strokePath()
    }
    func box(_ r: CGRect, _ color: CGColor) {
      ctx.setStrokeColor(color)
      ctx.setLineWidth(lw)
      ctx.stroke(CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H))
    }
    for inst in result["instances"] as? [[String: Any]] ?? [] { stroke(pts(inst["polygon"]), CGColor(red: 1, green: 1, blue: 1, alpha: 0.8), lw) }
    if let s = result["subject"] as? [String: Any] { stroke(pts(s["polygon"]), CGColor(red: 0.89, green: 1, blue: 0.31, alpha: 1), lw * 2) }
    for t in result["text"] as? [[String: Any]] ?? [] { if let r = rect(t["box"]) { box(r, CGColor(red: 0.2, green: 0.9, blue: 1, alpha: 0.9)) } }
    for o in result["objects"] as? [[String: Any]] ?? [] { if let r = rect(o["box"]) { box(r, CGColor(red: 1, green: 0.6, blue: 0.24, alpha: 0.9)) } }
    for p in proposals { stroke(pts(p["polygon"]), CGColor(red: 0.36, green: 0.95, blue: 0.65, alpha: 1), lw) }
    for p in parts { stroke(pts(p["polygon"]), CGColor(red: 1, green: 0.3, blue: 0.85, alpha: 1), lw * 1.5) }

    if let out = ctx.makeImage(),
       let dest = CGImageDestinationCreateWithURL(outDir.appendingPathComponent("\(name).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
      CGImageDestinationAddImage(dest, out, nil)
      CGImageDestinationFinalize(dest)
    }

    var full = result
    full["prompted"] = parts
    let json = try JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: outDir.appendingPathComponent("\(name).json"))

    let texts = (result["text"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    let objects = (result["objects"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
    let labels = (result["labels"] as? [[String: Any]] ?? []).prefix(3).compactMap { $0["label"] as? String }
    let line: [String: Any] = [
      "image": name,
      "ms": Int(Date().timeIntervalSince(started) * 1000),
      "subject": result["subject"] is NSNull ? "none" : "\(pts((result["subject"] as? [String: Any])?["polygon"]).count) pts",
      "instances": (result["instances"] as? [Any])?.count ?? 0,
      "text": texts.prefix(4).joined(separator: " | "),
      "objects": objects.joined(separator: ", "),
      "labels": labels.joined(separator: ", "),
      "parts": parts.map { "\($0["engine"] ?? "?"):\($0["points"] ?? 0)" }.joined(separator: " "),
      "proposals": proposals.map { String(format: "%.2f", ($0["score"] as? Double) ?? 0) }.joined(separator: " "),
    ]
    summary.append(line)
    print(line)
  } catch {
    print("\(name): \(error.localizedDescription)")
    summary.append(["image": name, "error": error.localizedDescription])
  }
}

let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
try data.write(to: outDir.appendingPathComponent("summary.json"))

// The live camera's path into SAM, and the math that keeps live outlines steady (live.swift).
let liveOK = checkLivePath(images)
let mathOK = checkOutlineMath()
let trackerOK = checkTracker()
let shapeOK = checkShape()
let depthOK = checkDepth()
let flowOK = checkFlow(images)
let cameraOK = checkCamera()
if !liveOK || !mathOK || !trackerOK || !shapeOK || !depthOK || !flowOK || !cameraOK { exit(1) }
