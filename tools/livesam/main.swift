// Replays videos with ground-truth masks (DAVIS 2017 layout) through Lensi's
// live segmentation and scores what would be on screen every frame.
//
//   swiftc -O -o livesam tools/livesam/main.swift \
//     app/modules/lensi-ar/ios/{LiveSeg,SAMSegmenter,Detector}.swift
//   LENSI_MODELS_DIR=<dir with LensiSAM*.mlmodelc> ./livesam --davis ~/DAVIS --seqs bear,dogs-jump \
//     --mode ours --encoder-ms 25 --decoder-ms 8 [--render out/]
//
// SAM really runs (Core ML, this Mac); its answer is only used once the
// simulated phone latency (encoder + decoder per prompt) has passed, which is
// what the phone does: the camera keeps moving while SAM thinks.
//
// Modes:
//   baseline  what camera-first did: SAM at a point, outline held where it was
//             found until the next answer. Prompted with the true centre of each
//             object every pass (an oracle, so it's a generous baseline).
//   ours      LiveSegTracker: optical flow moves outlines every frame, SAM answers
//             are carried forward and blended; prompts come from the track itself.
//
// Scores, per object and frame from the first frame on:
//   J       IoU of what's on screen with the true mask (0 before the first answer)
//   jitter  how much the outline changes frame to frame beyond how much the
//           true mask changes: mean of max(0, (1-IoU(d_t,d_t-1)) - (1-IoU(g_t,g_t-1)))
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Args

var opts: [String: String] = [:]
let argv = Array(CommandLine.arguments.dropFirst())
for i in stride(from: 0, to: argv.count - 1, by: 2) where argv[i].hasPrefix("--") {
  opts[String(argv[i].dropFirst(2))] = argv[i + 1]
}
let davis = URL(fileURLWithPath: (opts["davis"] ?? "~/lensi-data/DAVIS").replacingOccurrences(of: "~", with: NSHomeDirectory()))
let mode = opts["mode"] ?? "ours"
let encoderMs = Double(opts["encoder-ms"] ?? "25")!
let decoderMs = Double(opts["decoder-ms"] ?? "8")!
let fps = Double(opts["fps"] ?? "30")!
let stepFrames = Int(opts["step"] ?? "1")!
let maxObjects = Int(opts["objects"] ?? "4")!
let maxFrames = Int(opts["frames"] ?? "1000")!
let seed = opts["seed"] ?? "box"
let flowSide = Int(opts["flow-side"] ?? "480")!
/// > 0: instead of the video, a handheld camera moving over the sequence's first frame
/// for this many frames (the scene is still; only the camera moves).
let synthetic = Int(opts["synthetic"] ?? "0")!
/// Synthetic only: emulate guide tags, whose spot ARKit knows in every frame (here: the true
/// camera motion applied to each object's inner point in the still). Tracks are prompted
/// there and re-seeded there when lost, as LensiARView does.
let anchored = opts["anchors"] == "1"
/// Render every Nth frame; "demo" style draws like the app (smoothed, no truth).
let renderEvery = Int(opts["render-every"] ?? "3")!
let demoStyle = opts["style"] == "demo"
let renderDir = opts["render"].map { URL(fileURLWithPath: $0) }
let seqs: [String] = {
  if let s = opts["seqs"] { return s.split(separator: ",").map(String.init) }
  let list = (try? String(contentsOf: davis.appendingPathComponent("ImageSets/2017/val.txt"), encoding: .utf8)) ?? ""
  return list.split(separator: "\n").map(String.init)
}()

guard let sam = SAMSegmenter.shared else {
  print("SAM models not found: set LENSI_MODELS_DIR")
  exit(2)
}

// MARK: - IO

func loadImage(_ url: URL) -> CGImage? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
  return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
  var px = [UInt8](repeating: 0, count: width * height * 4)
  px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  return px
}

func flowFrame(_ image: CGImage) -> FlowFrame {
  let s = Double(flowSide) / Double(max(image.width, image.height))
  let w = Int(Double(image.width) * s), h = Int(Double(image.height) * s)
  var px = [UInt8](repeating: 0, count: w * h)
  px.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  return FlowFrame(width: w, height: h, pixels: px.map { Float($0) })
}

/// DAVIS palette: object id -> RGB (the VOC colour map).
func paletteColor(_ id: Int) -> (UInt8, UInt8, UInt8) {
  var r = 0, g = 0, b = 0, c = id
  for j in 0..<8 {
    r |= ((c >> 0) & 1) << (7 - j)
    g |= ((c >> 1) & 1) << (7 - j)
    b |= ((c >> 2) & 1) << (7 - j)
    c >>= 3
  }
  return (UInt8(r), UInt8(g), UInt8(b))
}

/// Ground truth at the metric grid: one label byte per cell.
let gridW = 214, gridH = 120
func labels(_ url: URL) -> [UInt8]? {
  guard let img = loadImage(url) else { return nil }
  let px = rgba(img, width: gridW, height: gridH)
  var lut: [Int: UInt8] = [:]
  for id in 0..<32 {
    let (r, g, b) = paletteColor(id)
    lut[Int(r) << 16 | Int(g) << 8 | Int(b)] = UInt8(id)
  }
  var out = [UInt8](repeating: 0, count: gridW * gridH)
  for i in 0..<(gridW * gridH) {
    out[i] = lut[Int(px[4 * i]) << 16 | Int(px[4 * i + 1]) << 8 | Int(px[4 * i + 2])] ?? 0
  }
  return out
}

func rasterNorm(_ poly: [CGPoint]) -> [Bool] {
  guard poly.count >= 3 else { return [Bool](repeating: false, count: gridW * gridH) }
  var buf = [UInt8](repeating: 0, count: gridW * gridH)
  buf.withUnsafeMutableBytes { b in
    let ctx = CGContext(data: b.baseAddress, width: gridW, height: gridH, bitsPerComponent: 8, bytesPerRow: gridW,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(gridH))
    ctx.scaleBy(x: CGFloat(gridW), y: -CGFloat(gridH))
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.addLines(between: poly)
    ctx.closePath()
    ctx.fillPath()
  }
  return buf.map { $0 > 127 }
}

func iou(_ a: [Bool], _ b: [Bool]) -> Double {
  var i = 0, u = 0
  for k in 0..<a.count {
    if a[k] && b[k] { i += 1 }
    if a[k] || b[k] { u += 1 }
  }
  return u == 0 ? 1 : Double(i) / Double(u)
}

func bbox(_ m: [Bool]) -> CGRect? {
  var minX = gridW, minY = gridH, maxX = -1, maxY = -1
  for y in 0..<gridH { for x in 0..<gridW where m[y * gridW + x] {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
  } }
  guard maxX >= 0 else { return nil }
  return CGRect(x: CGFloat(minX) / CGFloat(gridW), y: CGFloat(minY) / CGFloat(gridH),
                width: CGFloat(maxX - minX + 1) / CGFloat(gridW), height: CGFloat(maxY - minY + 1) / CGFloat(gridH))
}

/// The mask cell farthest inside (a cheap distance transform by erosion).
func innerPoint(_ m: [Bool]) -> CGPoint? {
  var cur = m
  var last: [Bool]? = nil
  while cur.contains(true) {
    last = cur
    var next = cur
    for y in 0..<gridH { for x in 0..<gridW where cur[y * gridW + x] {
      if x == 0 || y == 0 || x == gridW - 1 || y == gridH - 1 || !cur[y * gridW + x - 1] || !cur[y * gridW + x + 1]
        || !cur[(y - 1) * gridW + x] || !cur[(y + 1) * gridW + x] { next[y * gridW + x] = false }
    } }
    cur = next
  }
  guard let l = last, let i = l.firstIndex(of: true) else { return nil }
  return CGPoint(x: (CGFloat(i % gridW) + 0.5) / CGFloat(gridW), y: (CGFloat(i / gridW) + 0.5) / CGFloat(gridH))
}

func writePNG(_ image: CGImage, _ url: URL) {
  guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
  CGImageDestinationAddImage(d, image, nil)
  CGImageDestinationFinalize(d)
}

let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.35, 0.3), (0.18, 0.6, 1), (0.08, 0.72, 0.54), (0.55, 0.42, 1)]

func render(_ image: CGImage, outlines: [(Int, [CGPoint])], truth: [(Int, [Bool])], to url: URL) {
  let w = image.width, h = image.height
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  ctx.translateBy(x: 0, y: CGFloat(h))
  ctx.scaleBy(x: 1, y: -1)
  // Truth: faint dots on the mask's edge cells.
  for (obj, m) in demoStyle ? [] : truth {
    let c = colors[(obj - 1) % colors.count]
    ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 0.9)
    for y in 1..<(gridH - 1) { for x in 1..<(gridW - 1) where m[y * gridW + x] {
      if !m[y * gridW + x - 1] || !m[y * gridW + x + 1] || !m[(y - 1) * gridW + x] || !m[(y + 1) * gridW + x] {
        let cx = (CGFloat(x) + 0.5) / CGFloat(gridW) * CGFloat(w), cy = (CGFloat(y) + 0.5) / CGFloat(gridH) * CGFloat(h)
        ctx.fill(CGRect(x: cx - 1, y: cy - 1, width: 2, height: 2))
      }
    } }
  }
  for (obj, poly) in outlines where poly.count >= 3 {
    let c = colors[(obj - 1) % colors.count]
    let pts = (demoStyle ? Poly.smoothed(poly) : poly).map { CGPoint(x: $0.x * CGFloat(w), y: $0.y * CGFloat(h)) }
    ctx.addLines(between: pts)
    ctx.closePath()
    ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 0.18)
    ctx.setStrokeColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    ctx.setLineWidth(2.5)
    ctx.drawPath(using: .fillStroke)
  }
  if let out = ctx.makeImage() { writePNG(out, url) }
}

/// Handheld camera at frame f: pixel transform from the still scene to the frame.
func handheld(_ f: Int, _ w: Int, _ h: Int) -> CGAffineTransform {
  let t = Double(f) / 30
  var rng = UInt64(f &* 2654435761 &+ 12345)
  func noise() -> Double {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
    return Double(rng % 10000) / 10000 - 0.5
  }
  let tx = 0.06 * sin(2 * .pi * 0.23 * t) + 0.02 * sin(2 * .pi * 1.7 * t + 1) + 0.004 * noise()
  let ty = 0.05 * sin(2 * .pi * 0.31 * t + 0.5) + 0.015 * sin(2 * .pi * 2.3 * t) + 0.004 * noise()
  let rot = 0.06 * sin(2 * .pi * 0.19 * t)
  let zoom = 1.25 + 0.12 * sin(2 * .pi * 0.13 * t)
  let c = CGPoint(x: Double(w) / 2, y: Double(h) / 2)
  return CGAffineTransform(translationX: -c.x, y: -c.y)
    .concatenating(CGAffineTransform(rotationAngle: rot))
    .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
    .concatenating(CGAffineTransform(translationX: c.x + tx * Double(w), y: c.y + ty * Double(h)))
}

func warpImage(_ image: CGImage, _ m: CGAffineTransform) -> CGImage {
  let w = image.width, h = image.height
  let src = rgba(image, width: w, height: h)
  var dst = [UInt8](repeating: 0, count: w * h * 4)
  let inv = m.inverted()
  src.withUnsafeBufferPointer { s in
    for y in 0..<h {
      for x in 0..<w {
        let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5).applying(inv)
        let fx = min(max(Double(p.x) - 0.5, 0), Double(w) - 1.001), fy = min(max(Double(p.y) - 0.5, 0), Double(h) - 1.001)
        let x0 = Int(fx), y0 = Int(fy), ax = fx - Double(x0), ay = fy - Double(y0)
        for c in 0..<3 {
          let i = (y0 * w + x0) * 4 + c
          let top = Double(s[i]) * (1 - ax) + Double(s[i + 4]) * ax
          let bot = Double(s[i + w * 4]) * (1 - ax) + Double(s[i + w * 4 + 4]) * ax
          dst[(y * w + x) * 4 + c] = UInt8(min(255, max(0, top * (1 - ay) + bot * ay)))
        }
        dst[(y * w + x) * 4 + 3] = 255
      }
    }
  }
  let ctx = dst.withUnsafeMutableBytes { b in
    CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
  }
  return ctx
}

/// Labels on the metric grid, moved like the image (nearest).
func warpLabels(_ l: [UInt8], _ m: CGAffineTransform, imageW: Int, imageH: Int) -> [UInt8] {
  let inv = m.inverted()
  var out = [UInt8](repeating: 0, count: gridW * gridH)
  for y in 0..<gridH {
    for x in 0..<gridW {
      let p = CGPoint(x: (Double(x) + 0.5) / Double(gridW) * Double(imageW), y: (Double(y) + 0.5) / Double(gridH) * Double(imageH)).applying(inv)
      let gx = Int(Double(p.x) / Double(imageW) * Double(gridW)), gy = Int(Double(p.y) / Double(imageH) * Double(gridH))
      if gx >= 0, gy >= 0, gx < gridW, gy < gridH { out[y * gridW + x] = l[gy * gridW + gx] }
    }
  }
  return out
}

// MARK: - Run

struct SeqScore { var missing = 0; var shownJ: [Double] = []; var j: [Double] = []; var jitter: [Double] = []; var samMs: [Double] = []; var flowMs: [Double] = [] }
var all = SeqScore()
let ciContext = CIContext()
var smallJ: [Double] = []
var boxIoU: [Double] = [], samJ: [Double] = [], gtJ: [Double] = []
var perSeq: [[String: Any]] = []
let frameMs = 1000 / fps

for seq in seqs {
  let imgDir = davis.appendingPathComponent("JPEGImages/480p/\(seq)")
  let annDir = davis.appendingPathComponent("Annotations/480p/\(seq)")
  let names = ((try? FileManager.default.contentsOfDirectory(atPath: imgDir.path)) ?? []).filter { $0.hasSuffix(".jpg") }.sorted()
  guard !names.isEmpty else { print("no frames: \(seq)"); continue }
  let frames = synthetic > 0 ? Array(repeating: names[0], count: synthetic)[...]
    : stride(from: 0, to: names.count, by: stepFrames).map { names[$0] }.prefix(maxFrames)
  guard let first = labels(annDir.appendingPathComponent(frames[0].replacingOccurrences(of: ".jpg", with: ".png"))) else { continue }
  let objects = Array(Set(first.filter { $0 > 0 }).map(Int.init).sorted().prefix(maxObjects))

  let tracker = LiveSegTracker()
  var stillPoints: [Int: CGPoint]? = nil
  if anchored, let still = labels(annDir.appendingPathComponent(frames[0].replacingOccurrences(of: ".jpg", with: ".png"))) {
    stillPoints = Dictionary(uniqueKeysWithValues: objects.compactMap { o in innerPoint(still.map { Int($0) == o }).map { (o, $0) } })
  }
  var shown: [Int: [CGPoint]] = [:] // baseline: last answer
  var inflight: (ready: Int, results: [SegResult], baseline: [(Int, [CGPoint])])? = nil
  var prevShown: [Int: [Bool]] = [:]
  var prevTruth: [Int: [Bool]] = [:]
  var score = SeqScore()

  for (f, name) in frames.enumerated() {
    guard var image = loadImage(imgDir.appendingPathComponent(name)),
          var gt = labels(annDir.appendingPathComponent(name.replacingOccurrences(of: ".jpg", with: ".png"))) else { continue }
    if synthetic > 0 {
      let m = handheld(f, image.width, image.height)
      gt = warpLabels(gt, m, imageW: image.width, imageH: image.height)
      image = warpImage(image, m)
    }
    let truth = Dictionary(uniqueKeysWithValues: objects.map { o in (o, gt.map { Int($0) == o }) })

    var anchors: [String: CGPoint] = [:]
    if anchored, synthetic > 0, let still = stillPoints {
      let m = handheld(f, image.width, image.height)
      for (o, p) in still {
        let q = CGPoint(x: p.x * CGFloat(image.width), y: p.y * CGFloat(image.height)).applying(m)
        anchors["\(o)"] = CGPoint(x: q.x / CGFloat(image.width), y: q.y / CGFloat(image.height))
      }
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    let flow = flowFrame(image)
    if mode == "ours" {
      tracker.step(flow)
      if anchored, f > 0 {
        for (k, a) in anchors where !tracker.has(k) && a.x > 0.01 && a.x < 0.99 && a.y > 0.01 && a.y < 0.99 {
          tracker.remove(key: k)
          tracker.add(key: k, point: a, preferPart: false)
        }
      }
    }
    score.flowMs.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    if f == 0, mode == "ours" {
      for o in objects {
        guard let m = truth[o] else { continue }
        if seed == "box", let b = bbox(m) { tracker.add(key: "\(o)", box: b) }
        else if let p = innerPoint(m) { tracker.add(key: "\(o)", point: p) }
      }
    }

    // A SAM answer that is ready by now.
    if let job = inflight, job.ready <= f {
      if mode == "ours" { tracker.apply(job.results, current: flow) }
      else { for (o, p) in job.baseline { shown[o] = p } }
      inflight = nil
    }
    // Start the next SAM pass on this frame.
    if inflight == nil {
      let s0 = CFAbsoluteTimeGetCurrent()
      try? sam.prepare(image: image, id: "live", force: true)
      var results: [SegResult] = []
      var baseline: [(Int, [CGPoint])] = []
      var prompts = 0
      var crops = 0
      if mode == "ours" {
        let jobs = tracker.jobs(anchors: anchors)
        prompts = jobs.count
        crops = min(1, jobs.filter { SegRunner.cropRegion($0, size: CGSize(width: image.width, height: image.height)) != nil }.count)
        results = SegRunner.run(jobs, image: CIImage(cgImage: image), sam: sam, context: ciContext)
      } else if mode == "oracle" {
        for o in objects {
          guard let m = truth[o], let b = bbox(m) else { continue }
          if let mask = try? sam.segment(id: "live", points: [], labels: [], box: b), mask.polygon.count > 2 {
            baseline.append((o, mask.polygon))
          }
        }
      } else {
        for o in objects {
          guard let m = truth[o], let p = innerPoint(m) else { continue }
          prompts += 1
          if let mask = try? sam.segment(id: "live", points: [p], labels: [1], box: nil), mask.score >= 0.6, mask.polygon.count > 2 {
            baseline.append((o, mask.polygon))
          }
        }
      }
      score.samMs.append((CFAbsoluteTimeGetCurrent() - s0) * 1000)
      let latency = encoderMs * Double(1 + crops) + decoderMs * Double(prompts)
      inflight = (mode == "oracle" ? f : f + max(1, Int(ceil(latency / frameMs))), results, baseline)
      if mode == "oracle" { for (o, p) in baseline { shown[o] = p }; inflight = nil }
    }

    // What's on screen now.
    var drawn: [(Int, [CGPoint])] = []
    for o in objects {
      let poly: [CGPoint] = mode == "ours" ? (tracker.polygon("\(o)") ?? []) : (shown[o] ?? [])
      drawn.append((o, poly))
      let d = rasterNorm(poly)
      guard let g = truth[o] else { continue }
      if g.contains(true) {
        score.j.append(iou(d, g))
        if Double(g.filter { $0 }.count) < 0.02 * Double(g.count) { smallJ.append(iou(d, g)) }
        if poly.count < 3 { score.missing += 1 } else { score.shownJ.append(iou(d, g)) }
      }
      if let pd = prevShown[o], let pg = prevTruth[o], pd.contains(true) || d.contains(true) {
        let dc = 1 - iou(d, pd), gc = 1 - iou(g, pg)
        score.jitter.append(max(0, dc - gc))
      }
      prevShown[o] = d
      prevTruth[o] = g
    }
    if let dir = renderDir, f % renderEvery == 0 {
      let d = dir.appendingPathComponent("\(seq)-\(mode)")
      try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
      render(image, outlines: drawn, truth: objects.compactMap { o in truth[o].map { (o, $0) } },
             to: d.appendingPathComponent(String(format: "%04d.png", f)))
    }
  }
  func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
  print(String(format: "%-20@ objs %d  J %.3f  jitter %.4f  missing %.2f  J-shown %.3f  sam %.0f ms  flow %.1f ms", seq as NSString, objects.count,
               mean(score.j), mean(score.jitter), Double(score.missing) / Double(max(1, score.j.count)), mean(score.shownJ), mean(score.samMs), mean(score.flowMs)))
  perSeq.append(["seq": seq, "objects": objects.count, "J": mean(score.j), "jitter": mean(score.jitter)])
  all.missing += score.missing; all.shownJ += score.shownJ
  all.j += score.j; all.jitter += score.jitter; all.samMs += score.samMs; all.flowMs += score.flowMs
}
func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
print(String(format: "small objects (< 2%% of the frame): J %.3f over %d object-frames", mean(smallJ), smallJ.count))
print(String(format: "prompt box IoU %.3f  SAM answer J %.3f  SAM with true box J %.3f", mean(boxIoU), mean(samJ), mean(gtJ)))
print(String(format: "missing %.3f J-shown %.3f", Double(all.missing) / Double(max(1, all.j.count)), mean(all.shownJ)))
print(String(format: "ALL mode=%@ seed=%@ enc=%.0f dec=%.0f step=%d  J %.3f  jitter %.4f  (sam %.0f ms, flow %.1f ms on this Mac)",
             mode, seed, encoderMs, decoderMs, stepFrames, mean(all.j), mean(all.jitter), mean(all.samMs), mean(all.flowMs)))
if let out = opts["json"] {
  let data = try JSONSerialization.data(withJSONObject: ["mode": mode, "J": mean(all.j), "jitter": mean(all.jitter), "seqs": perSeq], options: .prettyPrinted)
  try data.write(to: URL(fileURLWithPath: out))
}
