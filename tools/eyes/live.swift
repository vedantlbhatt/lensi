// The live camera's SAM path, checked on a Mac against the photo path it replaces:
// each picture is handed over the way ARKit hands over a frame (a YCbCr buffer lying on its
// side) through SAMSegmenter.prepare(pixelBuffer:orientation:), and the outlines it gives
// for the same prompts must match prepare(image:)'s. Also OutlineMath, which keeps a live
// outline steady. Returns false when something is wrong.
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import simd

private let context = CIContext(options: [.useSoftwareRenderer: false])
private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// `upright` as the camera's sensor delivers it: on its side, so that `.right` stands it up.
private func sensorBuffer(_ upright: CGImage, format: OSType) -> CVPixelBuffer? {
  let image = CIImage(cgImage: upright).oriented(.left)
  let e = image.extent
  var created: CVPixelBuffer?
  let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
  guard CVPixelBufferCreate(nil, Int(e.width), Int(e.height), format, attrs as CFDictionary, &created) == kCVReturnSuccess,
        let buffer = created else { return nil }
  context.render(image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)), to: buffer,
                 bounds: CGRect(origin: .zero, size: e.size), colorSpace: srgb)
  return buffer
}

/// Intersection over union of two polygons (0…1 space), on a 256 grid.
private func iou(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
  let n = 256
  func raster(_ poly: [CGPoint]) -> [UInt8] {
    var bits = [UInt8](repeating: 0, count: n * n)
    guard poly.count > 2 else { return bits }
    bits.withUnsafeMutableBytes { raw in
      guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
      ctx.setFillColor(gray: 1, alpha: 1)
      ctx.move(to: CGPoint(x: poly[0].x * CGFloat(n), y: poly[0].y * CGFloat(n)))
      for p in poly.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * CGFloat(n), y: p.y * CGFloat(n))) }
      ctx.closePath()
      ctx.fillPath()
    }
    return bits
  }
  let ra = raster(a), rb = raster(b)
  var inter = 0, union = 0
  for i in 0..<(n * n) {
    let x = ra[i] > 127, y = rb[i] > 127
    if x && y { inter += 1 }
    if x || y { union += 1 }
  }
  return union == 0 ? 1 : Double(inter) / Double(union)
}

private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

private func clock() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

/// The live path on up to `limit` pictures. Prompts: the middle and two off-middle points.
func checkLivePath(_ urls: [URL], limit: Int = 5) -> Bool {
  guard let sam = SAMSegmenter.shared else {
    print("live path: SAM models not found, skipped")
    return true
  }
  var ok = true
  var ious: [String: [Double]] = [:]
  var photoMs: [Double] = [], liveMs: [String: [Double]] = [:]
  let prompts = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.35, y: 0.6), CGPoint(x: 0.65, y: 0.4)]
  for url in urls.prefix(limit) {
    guard let upright = try? Analyzer.loadUpright(uri: url.absoluteString) else { continue }
    let name = url.deletingPathExtension().lastPathComponent
    do {
      var t = clock()
      try sam.prepare(image: upright, id: "photo", force: true)
      photoMs.append(clock() - t)
      let photo = try prompts.map { try sam.segment(id: "photo", points: [$0], labels: [1], box: nil) }
      for (format, tag) in [(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, "420f"), (kCVPixelFormatType_32BGRA, "bgra")] {
        guard let buffer = sensorBuffer(upright, format: format) else {
          print("live path \(tag): could not make a \(tag) buffer, skipped")
          continue
        }
        // A few runs: the first one pays for building the GPU pipeline.
        var times: [Double] = []
        for _ in 0..<4 {
          t = clock()
          try sam.prepare(pixelBuffer: buffer, orientation: .right, id: "live")
          times.append(clock() - t)
        }
        liveMs[tag, default: []].append(median(times))
        for (i, p) in prompts.enumerated() {
          let live = try sam.segment(id: "live", points: [p], labels: [1], box: nil)
          let score = iou(photo[i].polygon, live.polygon)
          ious[tag, default: []].append(score)
          if score < 0.8 {
            print(String(format: "live path %@: %@ prompt %ld IoU %.2f against the photo path (%ld vs %ld points)",
                         tag, name, i, score, photo[i].polygon.count, live.polygon.count))
          }
        }
      }
    } catch {
      print("live path: \(name): \(error.localizedDescription)")
      ok = false
    }
  }
  for (tag, list) in ious.sorted(by: { $0.key < $1.key }) {
    let mean = list.reduce(0, +) / Double(max(list.count, 1))
    print(String(format: "live path %@: mean IoU %.3f, worst %.3f over %ld prompts; encode %.0f ms (photo path %.0f ms)",
                 tag, mean, list.min() ?? 0, list.count, median(liveMs[tag] ?? [0]), median(photoMs.isEmpty ? [0] : photoMs)))
    // The same picture through either door must give the same outlines.
    if mean < 0.9 {
      print("FAIL live path \(tag): outlines differ from the photo path")
      ok = false
    }
  }
  if ious.isEmpty {
    print("FAIL live path: nothing compared")
    ok = false
  }
  return ok
}

/// OutlineMath on shapes with known answers.
func checkOutlineMath() -> Bool {
  var failures: [String] = []
  func expect(_ condition: Bool, _ what: String) { if !condition { failures.append(what) } }

  // A unit square, 8 points: every half side.
  let square = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
  let even = OutlineMath.resample(square, count: 8)
  let want: [CGPoint] = [
    CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.5),
    CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5),
  ]
  expect(even.count == 8 && zip(even, want).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-6 }, "resample square: \(even)")
  // Measured in pixels: on a 2:1 image a unit square's sides aren't equal.
  let wide = OutlineMath.resample(square, count: 6, scale: CGSize(width: 2, height: 1))
  expect(abs(wide[1].x - 1) < 1e-6 && abs(wide[1].y) < 1e-6, "resample in pixels: \(wide)")

  // A circle, started 17 points later, lines back up with no gap.
  let circle: [simd_float3] = (0..<64).map {
    let a = Float($0) / 64 * 2 * .pi
    return simd_float3(cos(a) * 0.1, sin(a) * 0.1, -0.5)
  }
  let turned = Array(circle[17...] + circle[..<17])
  let (aligned, gap) = OutlineMath.align(turned, to: circle)
  expect(gap < 1e-5 && simd_distance(aligned[0], circle[0]) < 1e-6, "align: gap \(gap)")
  expect(abs(OutlineMath.spread(circle) - 0.1) < 1e-4, "spread: \(OutlineMath.spread(circle))")

  // Nudged a hair: blended (moves only part way). Somewhere else: replaced outright.
  let nudged = turned.map { $0 + simd_float3(0.004, 0, 0) }
  let blended = OutlineMath.smooth(circle, nudged)
  let moved = blended[0].x - circle[0].x
  expect(moved > 0.0005 && moved < 0.0035, "smooth nudge moved \(moved)")
  let elsewhere = circle.map { $0 + simd_float3(0.3, 0, 0) }
  let replaced = OutlineMath.smooth(circle, elsewhere)
  expect(zip(replaced, elsewhere).allSatisfy { simd_distance($0, $1) < 1e-6 } || OutlineMath.align(replaced, to: elsewhere).gap < 1e-6,
         "smooth elsewhere should replace")
  expect(OutlineMath.smooth(nil, circle) == circle, "smooth with nothing before")

  if failures.isEmpty {
    print("outline math: ok")
    return true
  }
  for f in failures { print("FAIL outline math: \(f)") }
  return false
}
