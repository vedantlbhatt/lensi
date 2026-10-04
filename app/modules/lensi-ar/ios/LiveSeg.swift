import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

// Live segmentation that stays on the thing: SAM says what the outline is,
// a few times a second and always a frame or more late; optical flow says
// where it went, every frame. Each tracked outline is moved with its object
// by Lucas-Kanade flow on the frames in between, and every SAM answer is
// carried forward through that same motion to the frame on screen before it
// is blended in, so the outline neither lags nor snaps.
//
// Pure CoreGraphics + Accelerate: the same code runs in the app and in
// tools/livesam, which replays videos through it and scores it.

/// One grayscale frame and its pyramid, for optical flow. Pixel coordinates.
final class FlowFrame {
  struct Level {
    let width: Int
    let height: Int
    var pixels: [Float]
    var gx: [Float]
    var gy: [Float]
  }

  let levels: [Level]
  var width: Int { levels[0].width }
  var height: Int { levels[0].height }

  /// `pixels`: row-major 0...255 luminance.
  static var defaultLevels = Int(ProcessInfo.processInfo.environment["LENSI_LEVELS"] ?? "") ?? 3

  init(width: Int, height: Int, pixels: [Float], levels count: Int = FlowFrame.defaultLevels) {
    var levels: [Level] = []
    var w = width, h = height, px = pixels
    for i in 0..<count {
      if i > 0 {
        let nw = w / 2, nh = h / 2
        guard nw >= 16, nh >= 16 else { break }
        var next = [Float](repeating: 0, count: nw * nh)
        px.withUnsafeBufferPointer { s in
          for y in 0..<nh {
            let r0 = 2 * y * w, r1 = r0 + w
            for x in 0..<nw {
              next[y * nw + x] = (s[r0 + 2 * x] + s[r0 + 2 * x + 1] + s[r1 + 2 * x] + s[r1 + 2 * x + 1]) * 0.25
            }
          }
        }
        w = nw; h = nh; px = next
      }
      let (gx, gy) = FlowFrame.gradients(px, w, h)
      levels.append(Level(width: w, height: h, pixels: px, gx: gx, gy: gy))
    }
    self.levels = levels
  }

  /// Scharr-ish central differences (3x3), zero at the border.
  private static func gradients(_ p: [Float], _ w: Int, _ h: Int) -> ([Float], [Float]) {
    var gx = [Float](repeating: 0, count: w * h)
    var gy = [Float](repeating: 0, count: w * h)
    p.withUnsafeBufferPointer { s in
      for y in 1..<(h - 1) {
        let r = y * w
        for x in 1..<(w - 1) {
          let i = r + x
          gx[i] = (3 * (s[i - w + 1] - s[i - w - 1]) + 10 * (s[i + 1] - s[i - 1]) + 3 * (s[i + w + 1] - s[i + w - 1])) / 32
          gy[i] = (3 * (s[i + w - 1] - s[i - w - 1]) + 10 * (s[i + w] - s[i - w]) + 3 * (s[i + w + 1] - s[i - w + 1])) / 32
        }
      }
    }
    return (gx, gy)
  }

  /// From a camera pixel buffer's luma: 420 biplanar (ARKit) plane 0, or BGRA.
  /// `rotateRight` turns the landscape sensor image upright (portrait), like
  /// `CIImage.oriented(.right)`. The long side is scaled to `longSide`.
  static func from(_ buffer: CVPixelBuffer, longSide: Int, rotateRight: Bool) -> FlowFrame? {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let planar = CVPixelBufferIsPlanar(buffer)
    let srcW = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
    let srcH = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
    guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
    else { return nil }
    let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
    let scale = Double(longSide) / Double(max(srcW, srcH))
    let dw = max(16, Int(Double(srcW) * scale)), dh = max(16, Int(Double(srcH) * scale))
    var small = [UInt8](repeating: 0, count: dw * dh)
    if planar {
      var src = vImage_Buffer(data: base, height: vImagePixelCount(srcH), width: vImagePixelCount(srcW), rowBytes: rowBytes)
      let ok = small.withUnsafeMutableBytes { d -> Bool in
        var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dw)
        return vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
      }
      guard ok else { return nil }
    } else {
      // BGRA: nearest-neighbour luma; only the tests' still images come this way.
      let p = base.assumingMemoryBound(to: UInt8.self)
      for y in 0..<dh {
        let sy = min(srcH - 1, Int(Double(y) / scale))
        for x in 0..<dw {
          let sx = min(srcW - 1, Int(Double(x) / scale))
          let o = sy * rowBytes + sx * 4
          small[y * dw + x] = UInt8((Int(p[o]) * 29 + Int(p[o + 1]) * 150 + Int(p[o + 2]) * 77) >> 8)
        }
      }
    }
    if !rotateRight {
      return FlowFrame(width: dw, height: dh, pixels: small.map { Float($0) })
    }
    // Rotate 90 degrees clockwise: upright(x, y) = sensor(y, H - 1 - x).
    let uw = dh, uh = dw
    var up = [Float](repeating: 0, count: uw * uh)
    small.withUnsafeBufferPointer { s in
      for y in 0..<uh {
        for x in 0..<uw {
          up[y * uw + x] = Float(s[(dh - 1 - x) * dw + y])
        }
      }
    }
    return FlowFrame(width: uw, height: uh, pixels: up)
  }
}

/// Pyramidal Lucas-Kanade with a forward-backward check.
enum OpticalFlow {
  static let radius = 6
  static let iterations = 12

  @inline(__always)
  private static func sample(_ a: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
    let xc = min(max(x, 0), Float(w - 1) - 0.001), yc = min(max(y, 0), Float(h - 1) - 0.001)
    let x0 = Int(xc), y0 = Int(yc)
    let fx = xc - Float(x0), fy = yc - Float(y0)
    let i = y0 * w + x0
    let top = a[i] + (a[i + 1] - a[i]) * fx
    let bottom = a[i + w] + (a[i + w + 1] - a[i + w]) * fx
    return top + (bottom - top) * fy
  }

  /// Where each point of `prev` went in `next` (nil when lost).
  /// `guess`: where each point probably went (e.g. the object's last motion), so fast
  /// movement doesn't have to be found from zero. The backward check starts from the
  /// original points.
  static func track(_ pts: [CGPoint], from prev: FlowFrame, to next: FlowFrame, guess: [CGPoint]? = nil, check: Bool = true) -> [CGPoint?] {
    let forward = trackOneWay(pts, prev, next, guess: guess)
    guard check else { return forward }
    let found = forward.compactMap { $0 }
    let backGuess = guess == nil ? nil : zip(pts, forward).compactMap { p, f in f == nil ? nil : p }
    let back = trackOneWay(found, next, prev, guess: backGuess)
    var out: [CGPoint?] = []
    var j = 0
    for (i, f) in forward.enumerated() {
      guard let f else { out.append(nil); continue }
      defer { j += 1 }
      guard let b = back[j], hypot(b.x - pts[i].x, b.y - pts[i].y) < 0.8 else { out.append(nil); continue }
      out.append(f)
    }
    return out
  }

  private static func trackOneWay(_ pts: [CGPoint], _ prev: FlowFrame, _ next: FlowFrame, guess: [CGPoint]? = nil) -> [CGPoint?] {
    let levels = min(prev.levels.count, next.levels.count)
    let r = radius
    let n = (2 * r + 1) * (2 * r + 1)
    var tmpl = [Float](repeating: 0, count: n)
    var gxs = [Float](repeating: 0, count: n)
    var gys = [Float](repeating: 0, count: n)
    var out: [CGPoint?] = []
    out.reserveCapacity(pts.count)
    for (index, p0) in pts.enumerated() {
      // Guess, in the coarsest level's pixels.
      let top = Float(1 << (levels - 1))
      var gx: Float = 0, gy: Float = 0
      if let guess, index < guess.count {
        gx = Float(guess[index].x - p0.x) / top
        gy = Float(guess[index].y - p0.y) / top
      }
      var lost = false
      for L in stride(from: levels - 1, through: 0, by: -1) {
        let A = prev.levels[L], B = next.levels[L]
        let s = Float(1 << L)
        let px = Float(p0.x) / s, py = Float(p0.y) / s
        if px < 1 || py < 1 || px > Float(A.width - 2) || py > Float(A.height - 2) {
          if L == 0 { lost = true }
          gx *= 2; gy *= 2
          continue
        }
        var g11: Float = 0, g12: Float = 0, g22: Float = 0
        A.pixels.withUnsafeBufferPointer { a in
          A.gx.withUnsafeBufferPointer { ax in
            A.gy.withUnsafeBufferPointer { ay in
              var k = 0
              for dy in -r...r {
                for dx in -r...r {
                  let x = px + Float(dx), y = py + Float(dy)
                  tmpl[k] = sample(a, A.width, A.height, x, y)
                  let ix = sample(ax, A.width, A.height, x, y), iy = sample(ay, A.width, A.height, x, y)
                  gxs[k] = ix; gys[k] = iy
                  g11 += ix * ix; g12 += ix * iy; g22 += iy * iy
                  k += 1
                }
              }
            }
          }
        }
        let det = g11 * g22 - g12 * g12
        let minEig = (g11 + g22 - ((g11 - g22) * (g11 - g22) + 4 * g12 * g12).squareRoot()) / 2
        if det < 1e-6 || minEig / Float(n) < 0.6 {
          if L == 0 { lost = true }
          gx *= 2; gy *= 2
          continue
        }
        var dxs: Float = 0, dys: Float = 0
        B.pixels.withUnsafeBufferPointer { b in
          for _ in 0..<iterations {
            var b1: Float = 0, b2: Float = 0
            var k = 0
            let cx = px + gx + dxs, cy = py + gy + dys
            for dy in -r...r {
              for dx in -r...r {
                let diff = tmpl[k] - sample(b, B.width, B.height, cx + Float(dx), cy + Float(dy))
                b1 += diff * gxs[k]; b2 += diff * gys[k]
                k += 1
              }
            }
            let ux = (g22 * b1 - g12 * b2) / det
            let uy = (g11 * b2 - g12 * b1) / det
            dxs += ux; dys += uy
            if ux * ux + uy * uy < 0.0004 { break }
          }
        }
        gx += dxs; gy += dys
        if L > 0 { gx *= 2; gy *= 2 }
      }
      let q = CGPoint(x: p0.x + CGFloat(gx), y: p0.y + CGFloat(gy))
      if lost || !q.x.isFinite || !q.y.isFinite || q.x < 0 || q.y < 0 || q.x > CGFloat(prev.width - 1) || q.y > CGFloat(prev.height - 1) {
        out.append(nil)
      } else {
        out.append(q)
      }
    }
    return out
  }

  static var edgeMargin = CGFloat(Double(ProcessInfo.processInfo.environment["LENSI_MARGIN"] ?? "") ?? 0)

  /// Up to `count` well-textured points inside `polygon` (pixels), spread out.
  static func features(in frame: FlowFrame, polygon: [CGPoint], count: Int = 48) -> [CGPoint] {
    guard polygon.count >= 3 else { return [] }
    let box = Poly.bounds(polygon)
    let A = frame.levels[0]
    let area = Double(box.width * box.height)
    guard area > 16 else { return [] }
    // One candidate per cell of a grid sized for ~4 candidates per wanted point.
    let cell = max(3.0, (area / Double(count * 4)).squareRoot())
    let path = CGMutablePath()
    path.addLines(between: polygon)
    path.closeSubpath()
    var scored: [(CGPoint, Float)] = []
    let r = 3
    // Keep off the edge: points there are as likely to be background (and
    // follow it) as object. The margin is a share of how thick the shape is.
    let thickness = Poly.interiorPoint(polygon).map { p in
      (0..<polygon.count).map { Poly.segmentDistance(p, polygon[$0], polygon[($0 + 1) % polygon.count]) }.min() ?? 0
    } ?? 0
    let margin = thickness * edgeMargin
    A.gx.withUnsafeBufferPointer { ax in
      A.gy.withUnsafeBufferPointer { ay in
        var y = Double(box.minY) + cell / 2
        while y < Double(box.maxY) {
          var x = Double(box.minX) + cell / 2
          while x < Double(box.maxX) {
            let p = CGPoint(x: x, y: y)
            let xi = Int(x), yi = Int(y)
            if xi > r + 1, yi > r + 1, xi < A.width - r - 2, yi < A.height - r - 2, path.contains(p),
               margin <= 0 || (0..<polygon.count).allSatisfy({ Poly.segmentDistance(p, polygon[$0], polygon[($0 + 1) % polygon.count]) >= margin }) {
              var g11: Float = 0, g12: Float = 0, g22: Float = 0
              for dy in -r...r {
                for dx in -r...r {
                  let i = (yi + dy) * A.width + xi + dx
                  g11 += ax[i] * ax[i]; g12 += ax[i] * ay[i]; g22 += ay[i] * ay[i]
                }
              }
              let e = (g11 + g22 - ((g11 - g22) * (g11 - g22) + 4 * g12 * g12).squareRoot()) / 2
              scored.append((p, e))
            }
            x += cell
          }
          y += cell
        }
      }
    }
    let minScore: Float = 49 * 4 // a 7x7 window with some texture
    return scored.filter { $0.1 > minScore }.sorted { $0.1 > $1.1 }.prefix(count).map(\.0)
  }
}

/// A 2D similarity transform fitted robustly to point motions.
enum MotionFit {
  /// q = [a -b; b a] p + t. Least squares (Umeyama, no reflection).
  static func similarity(_ p: [CGPoint], _ q: [CGPoint]) -> CGAffineTransform? {
    guard p.count >= 2 else { return nil }
    let n = CGFloat(p.count)
    let mp = CGPoint(x: p.map(\.x).reduce(0, +) / n, y: p.map(\.y).reduce(0, +) / n)
    let mq = CGPoint(x: q.map(\.x).reduce(0, +) / n, y: q.map(\.y).reduce(0, +) / n)
    var sa: CGFloat = 0, sb: CGFloat = 0, ss: CGFloat = 0
    for i in 0..<p.count {
      let px = p[i].x - mp.x, py = p[i].y - mp.y
      let qx = q[i].x - mq.x, qy = q[i].y - mq.y
      sa += px * qx + py * qy
      sb += px * qy - py * qx
      ss += px * px + py * py
    }
    guard ss > 1e-6 else { return CGAffineTransform(translationX: mq.x - mp.x, y: mq.y - mp.y) }
    var a = sa / ss, b = sb / ss
    // At most 8% scale and ~5 degrees per frame: anything more is a bad fit.
    let s = hypot(a, b)
    if s > 0 {
      let clamped = min(max(s, 0.92), 1.08)
      var angle = atan2(b, a)
      angle = min(max(angle, -0.09), 0.09)
      a = clamped * cos(angle); b = clamped * sin(angle)
    }
    let tx = mq.x - (a * mp.x - b * mp.y)
    let ty = mq.y - (b * mp.x + a * mp.y)
    return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
  }

  /// RANSAC over 2-point samples, then a refit on the inliers. Returns the
  /// transform and which pairs were inliers. Deterministic (fixed seed).
  static func robust(_ p: [CGPoint], _ q: [CGPoint], threshold: CGFloat = 1.5) -> (CGAffineTransform, [Bool])? {
    let n = p.count
    guard n >= 3 else {
      guard n >= 1 else { return nil }
      let dx = zip(p, q).map { $1.x - $0.x }.sorted()[n / 2]
      let dy = zip(p, q).map { $1.y - $0.y }.sorted()[n / 2]
      return (CGAffineTransform(translationX: dx, y: dy), [Bool](repeating: true, count: n))
    }
    var rng = UInt64(0x9E3779B97F4A7C15)
    func next() -> Int {
      rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
      return Int(rng % UInt64(n))
    }
    var bestCount = -1
    var bestMask = [Bool](repeating: false, count: n)
    let t2 = threshold * threshold
    for _ in 0..<min(48, n * (n - 1) / 2 + 1) {
      let i = next(), j = next()
      guard i != j, hypot(p[i].x - p[j].x, p[i].y - p[j].y) > 3,
            let t = similarity([p[i], p[j]], [q[i], q[j]]) else { continue }
      var mask = [Bool](repeating: false, count: n)
      var count = 0
      for k in 0..<n {
        let m = p[k].applying(t)
        if (m.x - q[k].x) * (m.x - q[k].x) + (m.y - q[k].y) * (m.y - q[k].y) < t2 {
          mask[k] = true
          count += 1
        }
      }
      if count > bestCount { bestCount = count; bestMask = mask }
    }
    guard bestCount >= 3 else {
      // No consensus: plain median translation.
      let dx = zip(p, q).map { $1.x - $0.x }.sorted()[n / 2]
      let dy = zip(p, q).map { $1.y - $0.y }.sorted()[n / 2]
      return (CGAffineTransform(translationX: dx, y: dy), [Bool](repeating: true, count: n))
    }
    let ip = (0..<n).filter { bestMask[$0] }.map { p[$0] }
    let iq = (0..<n).filter { bestMask[$0] }.map { q[$0] }
    guard let t = similarity(ip, iq) else { return nil }
    return (t, bestMask)
  }
}

/// Closed polygons with a fixed number of vertices, so two outlines of the
/// same thing can be blended vertex by vertex.
enum Poly {
  static let vertices = 72

  static func bounds(_ p: [CGPoint]) -> CGRect {
    guard let f = p.first else { return .null }
    var minX = f.x, minY = f.y, maxX = f.x, maxY = f.y
    for q in p {
      minX = min(minX, q.x); maxX = max(maxX, q.x)
      minY = min(minY, q.y); maxY = max(maxY, q.y)
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  static func signedArea(_ p: [CGPoint]) -> CGFloat {
    guard p.count > 2 else { return 0 }
    var s: CGFloat = 0
    for i in 0..<p.count {
      let a = p[i], b = p[(i + 1) % p.count]
      s += a.x * b.y - b.x * a.y
    }
    return s / 2
  }

  /// `n` points evenly spaced along the outline, clockwise on screen (y down).
  static func resample(_ poly: [CGPoint], _ n: Int = vertices) -> [CGPoint] {
    guard poly.count >= 3 else { return poly }
    var p = poly
    if signedArea(p) < 0 { p.reverse() }
    var lengths: [CGFloat] = [0]
    for i in 0..<p.count {
      let a = p[i], b = p[(i + 1) % p.count]
      lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y))
    }
    let total = lengths.last!
    guard total > 0 else { return [CGPoint](repeating: p[0], count: n) }
    var out: [CGPoint] = []
    out.reserveCapacity(n)
    var seg = 0
    for k in 0..<n {
      let d = total * CGFloat(k) / CGFloat(n)
      while seg < p.count - 1 && lengths[seg + 1] < d { seg += 1 }
      let a = p[seg], b = p[(seg + 1) % p.count]
      let l = lengths[seg + 1] - lengths[seg]
      let t = l > 0 ? (d - lengths[seg]) / l : 0
      out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }
    return out
  }

  /// `b` rotated so its vertices line up with `a`'s (least squared distance).
  static func aligned(_ b: [CGPoint], to a: [CGPoint]) -> [CGPoint] {
    let n = a.count
    guard b.count == n, n > 0 else { return b }
    var best = 0
    var bestCost = CGFloat.greatestFiniteMagnitude
    for shift in 0..<n {
      var cost: CGFloat = 0
      for i in 0..<n {
        let q = b[(i + shift) % n]
        cost += (q.x - a[i].x) * (q.x - a[i].x) + (q.y - a[i].y) * (q.y - a[i].y)
        if cost >= bestCost { break }
      }
      if cost < bestCost { bestCost = cost; best = shift }
    }
    return (0..<n).map { b[($0 + best) % n] }
  }

  static func blend(_ a: [CGPoint], _ b: [CGPoint], _ t: CGFloat) -> [CGPoint] {
    zip(a, b).map { CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t) }
  }

  /// IoU of two polygons, rasterised on a small grid over both.
  static func iou(_ a: [CGPoint], _ b: [CGPoint], grid: Int = 64) -> CGFloat {
    guard a.count >= 3, b.count >= 3 else { return 0 }
    let box = bounds(a).union(bounds(b))
    guard box.width > 0, box.height > 0 else { return 0 }
    let ma = raster(a, box: box, grid: grid), mb = raster(b, box: box, grid: grid)
    var inter = 0, union = 0
    for i in 0..<ma.count {
      let x = ma[i] > 127, y = mb[i] > 127
      if x && y { inter += 1 }
      if x || y { union += 1 }
    }
    return union > 0 ? CGFloat(inter) / CGFloat(union) : 0
  }

  /// A grid x grid 0/255 mask of `poly` over `box`.
  static func raster(_ poly: [CGPoint], box: CGRect, grid: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: grid * grid)
    out.withUnsafeMutableBytes { buf in
      guard let ctx = CGContext(data: buf.baseAddress, width: grid, height: grid, bitsPerComponent: 8, bytesPerRow: grid,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
      // Row 0 of the buffer is the top: flip so y grows down like the polygon.
      ctx.translateBy(x: 0, y: CGFloat(grid))
      ctx.scaleBy(x: CGFloat(grid) / box.width, y: -CGFloat(grid) / box.height)
      ctx.translateBy(x: -box.minX, y: -box.minY)
      ctx.setFillColor(gray: 1, alpha: 1)
      ctx.addLines(between: poly)
      ctx.closePath()
      ctx.fillPath()
    }
    return out
  }

  /// A point well inside the polygon: of a coarse grid over it, the inside
  /// point farthest from every edge.
  static func interiorPoint(_ poly: [CGPoint]) -> CGPoint? {
    guard poly.count >= 3 else { return nil }
    let box = bounds(poly)
    let path = CGMutablePath()
    path.addLines(between: poly)
    path.closeSubpath()
    var best: CGPoint?
    var bestD: CGFloat = -1
    let steps = 12
    for gy in 0..<steps {
      for gx in 0..<steps {
        let p = CGPoint(x: box.minX + (CGFloat(gx) + 0.5) / CGFloat(steps) * box.width,
                        y: box.minY + (CGFloat(gy) + 0.5) / CGFloat(steps) * box.height)
        guard path.contains(p) else { continue }
        var d = CGFloat.greatestFiniteMagnitude
        for i in 0..<poly.count {
          d = min(d, segmentDistance(p, poly[i], poly[(i + 1) % poly.count]))
        }
        if d > bestD { bestD = d; best = p }
      }
    }
    return best
  }

  static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let abx = b.x - a.x, aby = b.y - a.y
    let denom = abx * abx + aby * aby
    guard denom > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = min(max(((p.x - a.x) * abx + (p.y - a.y) * aby) / denom, 0), 1)
    return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
  }

  /// Chaikin corner cutting, for drawing: round, not jagged.
  static func smoothed(_ p: [CGPoint], passes: Int = 2) -> [CGPoint] {
    var cur = p
    for _ in 0..<passes {
      guard cur.count >= 3 else { return cur }
      var next: [CGPoint] = []
      next.reserveCapacity(cur.count * 2)
      for i in 0..<cur.count {
        let a = cur[i], b = cur[(i + 1) % cur.count]
        next.append(CGPoint(x: 0.75 * a.x + 0.25 * b.x, y: 0.75 * a.y + 0.25 * b.y))
        next.append(CGPoint(x: 0.25 * a.x + 0.75 * b.x, y: 0.25 * a.y + 0.75 * b.y))
      }
      cur = next
    }
    return cur
  }
}

/// What to ask SAM about one track, in normalized image coordinates
/// (0...1, top-left origin) of the frame `frame`.
struct SegJob {
  let key: String
  let frame: Int
  let points: [CGPoint]
  let labels: [Int]
  let box: CGRect?
  /// The track's outline at `frame`, to pick the SAM candidate that matches it.
  let prior: [CGPoint]?
  /// First look at a guide part: prefer a part-sized candidate.
  let preferPart: Bool
  /// First look at a tapped thing: which reading (0 whole, 1 part, 2 detail).
  var level: Int? = nil
}

struct SegResult {
  let key: String
  let frame: Int
  /// Normalized outline in the job's frame, or empty when SAM found nothing.
  let polygon: [CGPoint]
  let score: Float
}

/// Every live outline: moved by optical flow each frame, corrected by SAM.
final class LiveSegTracker {
  final class Track {
    let key: String
    /// Pixels of the flow frames. Empty until SAM's first answer. What's drawn: SAM's
    /// answers blended over time.
    var polygon: [CGPoint] = []
    /// SAM's latest answer as it is, carried along with the object: what the next prompt
    /// is made from, so the display's smoothing never feeds back into what SAM is asked.
    var raw: [CGPoint] = []
    /// Seed prompt before the first answer (pixels).
    var seedPoint: CGPoint?
    var seedBox: CGRect?
    var preferPart = false
    var level: Int?
    var features: [CGPoint] = []
    /// Cumulative motion since the track began, per frame index.
    var history: [Int: CGAffineTransform] = [:]
    var motion = CGAffineTransform.identity
    /// The last frame's motion: where to start looking in the next.
    var lastStep = CGAffineTransform.identity
    var misses = 0
    var answers = 0
    var lastAnswerFrame = -1
    var born: Int
    /// 0...1, eased toward 1 while found and toward 0 once lost.
    var opacity: CGFloat = 0
    var lost = false
    /// Frames in a row where optical flow found nothing to follow.
    var blind = 0

    init(key: String, frame: Int) {
      self.key = key
      born = frame
    }

    var hasShape: Bool { polygon.count >= 3 }
  }

  private(set) var tracks: [String: Track] = [:]
  private(set) var frameIndex = -1
  private var previous: FlowFrame?
  /// Size of the flow frames (pixels); polygons are normalized by it.
  private(set) var size = CGSize(width: 1, height: 1)

  /// How much of a SAM answer is taken when it agrees with the track (IoU >= 0.75).
  var gain: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["LENSI_GAIN"] ?? "") ?? 0.5)
  var maxMisses = 4
  /// How a settled track asks SAM: "box+point", "point" or "box".
  var promptStyle = ProcessInfo.processInfo.environment["LENSI_PROMPT"] ?? "box+point"
  /// Box prompts are the outline's bounds grown by this fraction of its size,
  /// so SAM can take back a part it dropped last time.
  /// Frames in a row with nothing to follow (a cut, or it's gone) before a track is dropped.
  var blindLimit = Int(ProcessInfo.processInfo.environment["LENSI_BLIND"] ?? "") ?? 4
  var growthLimit = CGFloat(Double(ProcessInfo.processInfo.environment["LENSI_GROWTH"] ?? "") ?? 1.6)
  var negatives = (ProcessInfo.processInfo.environment["LENSI_NEG"] ?? "0") == "1"
  var velocityGuess = (ProcessInfo.processInfo.environment["LENSI_VEL"] ?? "0") == "1"
  var rawPrompts = (ProcessInfo.processInfo.environment["LENSI_RAW"] ?? "1") == "1"
  var seedFlow = (ProcessInfo.processInfo.environment["LENSI_SEEDFLOW"] ?? "0") == "1"
  var boxPad: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["LENSI_BOXPAD"] ?? "") ?? 0.1)

  init() {}

  // MARK: Tracks

  /// `point` / `box` normalized in the current frame.
  func add(key: String, point: CGPoint? = nil, box: CGRect? = nil, preferPart: Bool = false, level: Int? = nil) {
    let t = Track(key: key, frame: frameIndex)
    t.level = level
    t.seedPoint = point.map { denorm($0) }
    t.seedBox = box.map { denorm($0) }
    t.preferPart = preferPart
    t.history[frameIndex] = .identity
    // A seed box is mostly background, so its points would follow the
    // background: before SAM's first answer the seed stays put (it arrives
    // within a few frames). Opt-in for experiments.
    if seedFlow, let previous {
      let region: [CGPoint]
      if let b = t.seedBox {
        region = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
      } else if let p = t.seedPoint {
        let r = 0.06 * min(size.width, size.height)
        region = [CGPoint(x: p.x - r, y: p.y - r), CGPoint(x: p.x + r, y: p.y - r), CGPoint(x: p.x + r, y: p.y + r), CGPoint(x: p.x - r, y: p.y + r)]
      } else {
        region = []
      }
      t.features = OpticalFlow.features(in: previous, polygon: region, count: 32)
    }
    tracks[key] = t
  }

  func remove(key: String) { tracks[key] = nil }

  func has(_ key: String) -> Bool { tracks[key].map { !$0.lost } ?? false }

  var keys: [String] { Array(tracks.keys) }

  func removeAll() { tracks.removeAll() }

  // MARK: Per frame

  /// Moves every track with the flow from the last frame to this one.
  func step(_ frame: FlowFrame) {
    frameIndex += 1
    let newSize = CGSize(width: frame.width, height: frame.height)
    if newSize != size, previous != nil {
      // Another camera (0.5x) or format: nothing carries over.
      previous = nil
      tracks.removeAll()
    }
    size = newSize
    defer { previous = frame }
    for t in tracks.values {
      var m = CGAffineTransform.identity
      if let prev = previous, !t.features.isEmpty {
        let moved = OpticalFlow.track(t.features, from: prev, to: frame,
                                      guess: velocityGuess ? t.features.map { $0.applying(t.lastStep) } : nil)
        var p: [CGPoint] = [], q: [CGPoint] = []
        for (a, b) in zip(t.features, moved) {
          if let b { p.append(a); q.append(b) }
        }
        t.blind = p.count < 3 ? t.blind + 1 : 0
        if let fit = MotionFit.robust(p, q) {
          m = fit.0
          // Keep the points that moved with the thing.
          t.features = zip(q, fit.1).filter { $0.1 }.map(\.0)
        } else {
          t.features = q
        }
      }
      t.lastStep = m
      t.motion = t.motion.concatenating(m)
      t.history[frameIndex] = t.motion
      t.history = t.history.filter { $0.key > frameIndex - 90 }
      if t.hasShape {
        t.polygon = t.polygon.map { $0.applying(m) }
        t.raw = t.raw.map { $0.applying(m) }
        // Thin out: top the points back up from inside the outline.
        if t.features.count < 12 {
          t.features = OpticalFlow.features(in: frame, polygon: t.polygon)
        }
      } else {
        t.seedPoint = t.seedPoint?.applying(m)
        t.seedBox = t.seedBox?.applying(m)
      }
      if t.hasShape {
        // Gone off the edge, or nothing left to follow for a few frames and
        // SAM hasn't confirmed it since: let it go.
        let b = Poly.bounds(t.polygon)
        let visible = b.intersection(CGRect(origin: .zero, size: size))
        let onScreen = visible.isNull ? 0 : (visible.width * visible.height) / max(1, b.width * b.height)
        if onScreen < 0.35 || t.blind >= blindLimit { t.lost = true }
      }
      t.opacity += ((t.lost || !t.hasShape ? 0 : 1) - t.opacity) * 0.25
    }
    tracks = tracks.filter { !($0.value.lost && $0.value.opacity < 0.02) }
  }

  // MARK: SAM

  /// What SAM should look at in the current frame.
  /// `anchors`: a better point to prompt with for some tracks (normalized),
  /// e.g. where ARKit says a guide tag's part is in this frame.
  /// `softAnchors`: used only while they're inside the track's shape (a thing that may move:
  /// its last known spot is a good prompt only while the outline agrees).
  func jobs(anchors: [String: CGPoint] = [:], softAnchors: [String: CGPoint] = [:]) -> [SegJob] {
    tracks.values.sorted { $0.key < $1.key }.compactMap { t -> SegJob? in
      guard !t.lost else { return nil }
      if t.hasShape {
        let shape = rawPrompts && t.raw.count >= 3 ? t.raw : t.polygon
        let box = Poly.bounds(shape)
        let b = norm(box.insetBy(dx: -boxPad * box.width, dy: -boxPad * box.height)).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !b.isNull, b.width > 0.005, b.height > 0.005 else { return nil }
        var anchor = anchors[t.key].flatMap { a in a.x > 0 && a.x < 1 && a.y > 0 && a.y < 1 ? a : nil }
        if anchor == nil, let soft = softAnchors[t.key] {
          let path = CGMutablePath()
          path.addLines(between: shape)
          path.closeSubpath()
          if path.contains(denorm(soft)) { anchor = soft }
        }
        let inner = promptStyle == "box" ? nil : anchor ?? Poly.interiorPoint(shape).map { norm($0) }
        if promptStyle == "point", inner == nil { return nil }
        var points = inner.map { [$0] } ?? []
        var labels = inner == nil ? [] : [1]
        if negatives {
          // Neighbours inside this box: "not that one", so two tracks don't merge.
          for o in tracks.values where o !== t && o.hasShape && !o.lost && points.count < 3 {
            guard let q = Poly.interiorPoint(o.polygon).map({ norm($0) }), b.contains(q) else { continue }
            let path = CGMutablePath()
            path.addLines(between: shape)
            path.closeSubpath()
            if path.contains(denorm(q)) { continue }
            points.append(q)
            labels.append(0)
          }
        }
        return SegJob(key: t.key, frame: frameIndex, points: points, labels: labels,
                      box: promptStyle == "point" ? nil : b, prior: shape.map { norm($0) }, preferPart: false)
      }
      if let b = t.seedBox {
        return SegJob(key: t.key, frame: frameIndex, points: [], labels: [], box: norm(b), prior: nil, preferPart: false)
      }
      if let p = t.seedPoint {
        let n = norm(p)
        guard n.x > 0, n.x < 1, n.y > 0, n.y < 1 else { return nil }
        return SegJob(key: t.key, frame: frameIndex, points: [n], labels: [1], box: nil, prior: nil, preferPart: t.preferPart, level: t.level)
      }
      return nil
    }
  }

  /// SAM's answers for frame `results[i].frame`, carried to the current frame
  /// along each track's motion and blended into its outline.
  func apply(_ results: [SegResult], current: FlowFrame? = nil) {
    for r in results {
      guard let t = tracks[r.key], !t.lost else { continue }
      guard r.polygon.count >= 3 else {
        t.misses += 1
        if t.misses > maxMisses || (!t.hasShape && t.misses > 2) { t.lost = true }
        continue
      }
      // Motion from the job's frame to now.
      let then = t.history[r.frame] ?? t.history[t.born] ?? .identity
      let carry = then.inverted().concatenating(t.motion)
      let sam = Poly.resample(r.polygon.map { denorm($0).applying(carry) })
      if !t.hasShape {
        t.polygon = sam
        t.raw = sam
      } else {
        let fresh = Poly.aligned(sam, to: t.polygon)
        let agreement = Poly.iou(t.polygon, fresh)
        let growth = abs(Poly.signedArea(fresh)) / max(1, abs(Poly.signedArea(t.polygon)))
        // Ballooning into the background (the thing is leaving the frame, and SAM fills
        // its box with what's behind): a few in a row before it's believed.
        if growth > growthLimit && agreement < 0.6 && t.answers > 1 {
          t.misses += 1
          if t.misses <= 3 { continue }
        }
        if agreement < 0.3 && t.answers > 1 {
          // A wild answer for a settled track (SAM grabbed the background, or
          // the table under the cup). Skip it; several in a row = take it.
          t.misses += 1
          if t.misses <= 2 { continue }
        }
        let g: CGFloat = agreement >= 0.75 ? gain : agreement >= 0.5 ? max(gain, 0.75) : 1
        t.polygon = Poly.blend(t.polygon, fresh, g)
        t.raw = fresh
      }
      t.misses = 0
      t.answers += 1
      t.lastAnswerFrame = r.frame
      let frame = current ?? previous
      if let frame {
        // Fresh points from inside the new outline, keeping some old ones.
        let fresh = OpticalFlow.features(in: frame, polygon: t.polygon, count: 48)
        t.features = fresh.isEmpty ? t.features : fresh
      }
      if Poly.bounds(t.polygon).width < 3 || Poly.bounds(t.polygon).height < 3 { t.lost = true }
    }
  }

  // MARK: Output

  /// Normalized outlines to draw, with their opacity.
  func outlines() -> [(key: String, polygon: [CGPoint], opacity: CGFloat)] {
    tracks.values.filter { $0.hasShape && $0.opacity > 0.02 }.sorted { $0.key < $1.key }
      .map { ($0.key, $0.polygon.map { norm($0) }, $0.opacity) }
  }

  func polygon(_ key: String) -> [CGPoint]? {
    guard let t = tracks[key], t.hasShape else { return nil }
    return t.polygon.map { norm($0) }
  }

  private func norm(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x / size.width, y: p.y / size.height) }
  private func denorm(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
  private func norm(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
  }
  private func denorm(_ r: CGRect) -> CGRect {
    CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
  }
}

/// The outline of a mask straight from SAM's logits: marching squares on the
/// zero level, so edges land between cells (sub-pixel) and move smoothly from
/// one frame to the next instead of stepping a whole cell. Takes the largest
/// 4-connected region with its holes filled. ~1 ms on a 256x192 grid.
enum MaskContour {
  /// `logits`: row-major with row stride `stride`; the region used is
  /// `width` x `height` from `offset`. Returns the outline in cell units
  /// (cell i's centre is i + 0.5) and the fraction of cells above zero.
  static func largest(_ logits: UnsafeBufferPointer<Float>, offset: Int, stride: Int, width W: Int, height H: Int) -> ([CGPoint], Float) {
    guard W > 1, H > 1 else { return ([], 0) }
    var inside = [Bool](repeating: false, count: W * H)
    var on = 0
    for y in 0..<H {
      let row = offset + y * stride
      for x in 0..<W where logits[row + x] > 0 {
        inside[y * W + x] = true
        on += 1
      }
    }
    guard on > 0 else { return ([], 0) }

    // Largest 4-connected component.
    var label = [Int32](repeating: 0, count: W * H)
    var bestLabel: Int32 = 0, bestSize = 0, next: Int32 = 0
    var stack: [Int] = []
    for start in 0..<(W * H) where inside[start] && label[start] == 0 {
      next += 1
      label[start] = next
      stack.append(start)
      var size = 0
      while let i = stack.popLast() {
        size += 1
        let x = i % W, y = i / W
        if x > 0, inside[i - 1], label[i - 1] == 0 { label[i - 1] = next; stack.append(i - 1) }
        if x < W - 1, inside[i + 1], label[i + 1] == 0 { label[i + 1] = next; stack.append(i + 1) }
        if y > 0, inside[i - W], label[i - W] == 0 { label[i - W] = next; stack.append(i - W) }
        if y < H - 1, inside[i + W], label[i + W] == 0 { label[i + W] = next; stack.append(i + W) }
      }
      if size > bestSize { bestSize = size; bestLabel = next }
    }
    var comp = label.map { $0 == bestLabel }
    // Fill holes: whatever the outside can't reach is part of it.
    var outside = [Bool](repeating: false, count: W * H)
    for x in 0..<W {
      for i in [x, (H - 1) * W + x] where !comp[i] && !outside[i] { outside[i] = true; stack.append(i) }
    }
    for y in 0..<H {
      for i in [y * W, y * W + W - 1] where !comp[i] && !outside[i] { outside[i] = true; stack.append(i) }
    }
    while let i = stack.popLast() {
      let x = i % W, y = i / W
      for j in [x > 0 ? i - 1 : -1, x < W - 1 ? i + 1 : -1, y > 0 ? i - W : -1, y < H - 1 ? i + W : -1]
      where j >= 0 && !comp[j] && !outside[j] {
        outside[j] = true
        stack.append(j)
      }
    }
    for i in 0..<(W * H) where !outside[i] { comp[i] = true }

    // Corner values on a grid padded by one cell of "outside".
    let CW = W + 2, CH = H + 2
    var v = [Float](repeating: -1, count: CW * CH)
    for y in 0..<H {
      let row = offset + y * stride
      for x in 0..<W {
        let l = logits[row + x]
        v[(y + 1) * CW + x + 1] = comp[y * W + x] ? max(l, 0.01) : min(l, -0.01)
      }
    }
    // Edge ids: horizontal (x,y)-(x+1,y) = 2*(y*CW+x), vertical (x,y)-(x,y+1) = 2*(y*CW+x)+1.
    var links: [Int: (Int, Int)] = [:]
    func link(_ a: Int, _ b: Int) {
      if let e = links[a] { links[a] = (e.0, b) } else { links[a] = (b, -1) }
      if let e = links[b] { links[b] = (e.0, a) } else { links[b] = (a, -1) }
    }
    for cy in 0..<(CH - 1) {
      for cx in 0..<(CW - 1) {
        let a = v[cy * CW + cx], b = v[cy * CW + cx + 1], c = v[(cy + 1) * CW + cx + 1], d = v[(cy + 1) * CW + cx]
        let code = (a > 0 ? 1 : 0) | (b > 0 ? 2 : 0) | (c > 0 ? 4 : 0) | (d > 0 ? 8 : 0)
        if code == 0 || code == 15 { continue }
        let T = 2 * (cy * CW + cx), B = 2 * ((cy + 1) * CW + cx)
        let L = 2 * (cy * CW + cx) + 1, R = 2 * (cy * CW + cx + 1) + 1
        let centre = (a + b + c + d) > 0
        switch code {
        case 1, 14: link(L, T)
        case 2, 13: link(T, R)
        case 3, 12: link(L, R)
        case 4, 11: link(R, B)
        case 6, 9: link(T, B)
        case 7, 8: link(L, B)
        case 5: if centre { link(T, R); link(B, L) } else { link(L, T); link(R, B) }
        case 10: if centre { link(L, T); link(R, B) } else { link(T, R); link(B, L) }
        default: break
        }
      }
    }
    func position(_ e: Int) -> CGPoint {
      let base = e / 2
      let x = base % CW, y = base / CW
      let (x2, y2) = e % 2 == 0 ? (x + 1, y) : (x, y + 1)
      let va = v[y * CW + x], vb = v[y2 * CW + x2]
      let t = va == vb ? 0.5 : CGFloat(va / (va - vb))
      // Corner (x, y) is cell (x - 1, y - 1), whose centre is at x - 0.5.
      return CGPoint(x: CGFloat(x) - 0.5 + CGFloat(x2 - x) * t, y: CGFloat(y) - 0.5 + CGFloat(y2 - y) * t)
    }
    var seen = Set<Int>()
    var best: [CGPoint] = []
    var bestArea: CGFloat = 0
    for start in links.keys where !seen.contains(start) {
      var loop: [CGPoint] = []
      var prev = -1, cur = start
      while !seen.contains(cur) {
        seen.insert(cur)
        loop.append(position(cur))
        guard let n = links[cur] else { break }
        let nxt = n.0 != prev ? n.0 : n.1
        if nxt < 0 { break }
        prev = cur
        cur = nxt
      }
      let area = abs(Poly.signedArea(loop))
      if area > bestArea { bestArea = area; best = loop }
    }
    return (best, Float(on) / Float(W * H))
  }
}
