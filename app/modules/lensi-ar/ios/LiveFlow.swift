import CoreGraphics
import Foundation
import simd

/// Carries an outline from one frame to the next on its own pixels, between SAM's cuts.
///
/// Points well inside the outline are followed into the next frame with pyramidal
/// Lucas-Kanade. The outline's edge is left out, because the background shows through there
/// and moves differently. Each point is checked by following it back again: one that doesn't
/// return to where it started was lost or covered, and is dropped. The outline then moves by
/// the survivors' median motion, turns by their median turn, and grows or shrinks by their
/// median spread (MedianFlow; Kalal, Mikolajczyk and Matas, 2010).
///
/// The result moves the way the thing moves, rather than at the speed SAM's last cut gave it,
/// so SAM's next prompt lands on the thing. It runs on the CPU, on a grey copy of the frame
/// `width` pixels across, and costs a few milliseconds.
///
/// Normalized upright image space (0...1, top-left origin) throughout. tools/track runs the
/// same code over real footage, and tools/eyes checks it against known shifts.
enum LiveFlow {
  static let width = 360
  static let levels = 4
  /// Half the side of the window a point is matched by: 9 x 9 pixels.
  static let window = 4
  static let iterations = 20
  /// A window with less texture than this (the smaller eigenvalue of its gradient matrix,
  /// per pixel, 0-255 intensities) can't say where it went: flat paint, a blank wall.
  static let minTexture: Float = 0.5

  /// One frame, grey, as a pyramid (each level half the size of the last) with its gradients.
  struct Frame {
    struct Level {
      let w: Int, h: Int
      let pixels: [Float], gx: [Float], gy: [Float]
    }
    let levels: [Level]
    var w: Int { levels[0].w }
    var h: Int { levels[0].h }
  }

  /// `image` as a Frame, `width` pixels across.
  static func frame(_ image: CGImage, width: Int = LiveFlow.width) -> Frame? {
    let w = width, h = max(Int((Double(image.height) * Double(width) / Double(image.width)).rounded()), 1)
    var grey = [UInt8](repeating: 0, count: w * h)
    let drawn = grey.withUnsafeMutableBytes { raw -> Bool in
      // Row 0 of the buffer is the top of the picture.
      guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
      ctx.interpolationQuality = .medium
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
      return true
    }
    guard drawn else { return nil }
    var level = Frame.Level(w: w, h: h, pixels: grey.map { Float($0) }, gx: [], gy: [])
    var out: [Frame.Level] = []
    for i in 0..<levels {
      let (gx, gy) = gradients(level.pixels, w: level.w, h: level.h)
      out.append(Frame.Level(w: level.w, h: level.h, pixels: level.pixels, gx: gx, gy: gy))
      if i < levels - 1 {
        guard level.w >= 8, level.h >= 8 else { break }
        level = half(level)
      }
    }
    return Frame(levels: out)
  }

  /// Blurred ([1 2 1] / 4 each way) and every other pixel kept.
  private static func half(_ l: Frame.Level) -> Frame.Level {
    let w = l.w, h = l.h
    var across = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        let a = l.pixels[y * w + max(x - 1, 0)], b = l.pixels[y * w + x], c = l.pixels[y * w + min(x + 1, w - 1)]
        across[y * w + x] = (a + 2 * b + c) * 0.25
      }
    }
    let hw = (w + 1) / 2, hh = (h + 1) / 2
    var out = [Float](repeating: 0, count: hw * hh)
    for y in 0..<hh {
      for x in 0..<hw {
        let sx = 2 * x, sy = 2 * y
        let a = across[max(sy - 1, 0) * w + sx], b = across[sy * w + sx], c = across[min(sy + 1, h - 1) * w + sx]
        out[y * hw + x] = (a + 2 * b + c) * 0.25
      }
    }
    return Frame.Level(w: hw, h: hh, pixels: out, gx: [], gy: [])
  }

  /// Central differences, the edge repeated.
  private static func gradients(_ p: [Float], w: Int, h: Int) -> ([Float], [Float]) {
    var gx = [Float](repeating: 0, count: w * h), gy = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        gx[y * w + x] = (p[y * w + min(x + 1, w - 1)] - p[y * w + max(x - 1, 0)]) * 0.5
        gy[y * w + x] = (p[min(y + 1, h - 1) * w + x] - p[max(y - 1, 0) * w + x]) * 0.5
      }
    }
    return (gx, gy)
  }

  /// Bilinear, clamped to the picture.
  @inline(__always)
  private static func sample(_ p: UnsafeBufferPointer<Float>, _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
    let cx = min(max(x, 0), Float(w) - 1.0001), cy = min(max(y, 0), Float(h) - 1.0001)
    let x0 = Int(cx), y0 = Int(cy)
    let fx = cx - Float(x0), fy = cy - Float(y0)
    let i = y0 * w + x0
    return p[i] * (1 - fx) * (1 - fy) + p[i + 1] * fx * (1 - fy) + p[i + w] * (1 - fx) * fy + p[i + w + 1] * fx * fy
  }

  /// Where each point (pixels of `a`'s first level) is in `b`; nil where it can't be told.
  static func track(_ points: [SIMD2<Float>], from a: Frame, to b: Frame) -> [SIMD2<Float>?] {
    let n = points.count
    var guess = [SIMD2<Float>](repeating: .zero, count: n)
    var lost = [Bool](repeating: false, count: n)
    let side = 2 * window + 1, count = side * side
    var ia = [Float](repeating: 0, count: count), wx = [Float](repeating: 0, count: count), wy = [Float](repeating: 0, count: count)
    let top = min(a.levels.count, b.levels.count) - 1
    for lev in stride(from: top, through: 0, by: -1) {
      let la = a.levels[lev], lb = b.levels[lev]
      let s = Float(1 << lev)
      la.pixels.withUnsafeBufferPointer { I in
        la.gx.withUnsafeBufferPointer { IX in
          la.gy.withUnsafeBufferPointer { IY in
            lb.pixels.withUnsafeBufferPointer { J in
              for k in 0..<n where !lost[k] {
                let px = points[k].x / s, py = points[k].y / s
                var gxx: Float = 0, gxy: Float = 0, gyy: Float = 0
                var i = 0
                for oy in -window...window {
                  for ox in -window...window {
                    let x = px + Float(ox), y = py + Float(oy)
                    ia[i] = sample(I, la.w, la.h, x, y)
                    let dx = sample(IX, la.w, la.h, x, y), dy = sample(IY, la.w, la.h, x, y)
                    wx[i] = dx
                    wy[i] = dy
                    gxx += dx * dx
                    gxy += dx * dy
                    gyy += dy * dy
                    i += 1
                  }
                }
                let det = gxx * gyy - gxy * gxy
                let smaller = (gxx + gyy) / 2 - (((gxx - gyy) / 2) * ((gxx - gyy) / 2) + gxy * gxy).squareRoot()
                guard det > 0, smaller / Float(count) >= minTexture else {
                  // Too flat to say at this scale: carry the guess down and let the finer levels try.
                  if lev == 0 { lost[k] = true } else { guess[k] *= 2 }
                  continue
                }
                var v = SIMD2<Float>.zero
                for _ in 0..<iterations {
                  var bx: Float = 0, by: Float = 0
                  var i = 0
                  for oy in -window...window {
                    for ox in -window...window {
                      let d = ia[i] - sample(J, lb.w, lb.h, px + Float(ox) + guess[k].x + v.x, py + Float(oy) + guess[k].y + v.y)
                      bx += d * wx[i]
                      by += d * wy[i]
                      i += 1
                    }
                  }
                  let step = SIMD2<Float>((gyy * bx - gxy * by) / det, (gxx * by - gxy * bx) / det)
                  v += step
                  if abs(step.x) < 0.01, abs(step.y) < 0.01 { break }
                }
                guess[k] = lev > 0 ? 2 * (guess[k] + v) : guess[k] + v
              }
            }
          }
        }
      }
    }
    let w = Float(a.w - 1), h = Float(a.h - 1)
    return (0..<n).map { k in
      let p = points[k] + guess[k]
      return lost[k] || !p.x.isFinite || !p.y.isFinite || p.x < 0 || p.x > w || p.y < 0 || p.y > h ? nil : p
    }
  }

  /// `outline` in frame `a`, carried into frame `b`; nil when too few points inside it could
  /// be followed to say (it's mostly off the picture, or flat, or covered).
  static func carry(_ outline: [CGPoint], from a: Frame, to b: Frame, scaling: Bool = true, turning: Bool = true) -> [CGPoint]? {
    guard outline.count >= 3 else { return nil }
    let size = CGSize(width: a.w, height: a.h)
    let r = LiveTracker.bounds(outline)
    guard r.width > 0, r.height > 0 else { return nil }
    // A grid over it; the points well inside (the deepest 70%) are the ones followed.
    let grid = 12
    var inside: [(p: CGPoint, depth: CGFloat)] = []
    for gy in 0..<grid {
      for gx in 0..<grid {
        let p = CGPoint(x: r.minX + (CGFloat(gx) + 0.5) / CGFloat(grid) * r.width,
                        y: r.minY + (CGFloat(gy) + 0.5) / CGFloat(grid) * r.height)
        guard p.x >= 0, p.x <= 1, p.y >= 0, p.y <= 1, LiveTracker.contains(outline, p) else { continue }
        inside.append((p, LiveTracker.edgeDistance(outline, p, scale: size)))
      }
    }
    let deepest = inside.map { $0.depth }.max() ?? 0
    let from = inside.filter { $0.depth >= deepest * 0.3 }.map { SIMD2<Float>(Float($0.p.x * size.width), Float($0.p.y * size.height)) }
    guard from.count >= 5 else { return nil }
    let there = track(from, from: a, to: b)
    let found = there.compactMap { $0 }
    guard found.count >= 5 else { return nil }
    let back = track(found, from: b, to: a)
    // Forward and back: a point that doesn't come home was lost; keep the better half.
    var pairs: [(a: SIMD2<Float>, b: SIMD2<Float>, error: Float)] = []
    var j = 0
    for (k, t) in there.enumerated() {
      guard let t else { continue }
      defer { j += 1 }
      guard let home = back[j] else { continue }
      pairs.append((a: from[k], b: t, error: simd_distance(home, from[k])))
    }
    guard pairs.count >= 4 else { return nil }
    let cut = max(median(pairs.map { $0.error }), 0.3)
    let kept = pairs.filter { $0.error <= cut }
    guard kept.count >= 4 else { return nil }
    let tx = median(kept.map { $0.b.x - $0.a.x }), ty = median(kept.map { $0.b.y - $0.a.y })
    // Spread and turn, from pairs of points far enough apart to say.
    var ratios: [Float] = [], turns: [Float] = []
    if scaling || turning {
      for m in 0..<kept.count {
        for n in (m + 1)..<kept.count {
          let da = kept[n].a - kept[m].a, db = kept[n].b - kept[m].b
          let la = simd_length(da)
          guard la > 4 else { continue }
          if scaling { ratios.append(simd_length(db) / la) }
          if turning {
            var t = atan2(db.y, db.x) - atan2(da.y, da.x)
            if t > .pi { t -= 2 * .pi } else if t < -.pi { t += 2 * .pi }
            turns.append(t)
          }
        }
      }
    }
    let s = ratios.count >= 3 ? min(max(median(ratios), 0.92), 1.08) : 1
    let turn = turns.count >= 3 ? min(max(median(turns), -0.17), 0.17) : 0
    let c = kept.reduce(SIMD2<Float>.zero) { $0 + $1.a } / Float(kept.count)
    let cr = cos(turn), sr = sin(turn)
    return outline.map { q in
      let dx = (Float(q.x * size.width) - c.x) * s, dy = (Float(q.y * size.height) - c.y) * s
      return CGPoint(x: CGFloat(c.x + dx * cr - dy * sr + tx) / size.width,
                     y: CGFloat(c.y + dx * sr + dy * cr + ty) / size.height)
    }
  }

  /// How `bend` bends (tools/track measures the settings at the phone's timing).
  struct Bending {
    /// How far inside the edge each point is followed, pixels (of `width`).
    var inset: Float = 3
    /// How far a point may move beyond the whole outline's carry, of the outline's size.
    var most: Float = 0.2
    /// How far along the edge the points' own moves are smoothed (Gaussian, points).
    var sigma: Float = 2
    /// How near where it started a point must come back (tracked back again) to be believed, pixels.
    var home: Float = 1

    static let standard = Bending()
  }

  /// `outline` in frame `a` carried into frame `b` bending with the thing: carried whole first
  /// (`carry`: moved, turned, scaled as one), then each point follows a point `inset` pixels
  /// inside the edge there, tracked on its own (and back again, to be sure of it), so an arm or a
  /// leg that moves differently from the body takes its part of the outline with it. What each
  /// point moves beyond the whole outline's carry is smoothed along the edge and kept within
  /// `most` of the outline's size; a point that couldn't be followed keeps the whole carry. An
  /// outline that runs off the picture is carried whole: its points there can't be followed, and
  /// bent from the rest its shape drifted until EdgeTAM's cuts no longer fitted it (a sink up
  /// close on tools/walk's walk-arounds, lost in 42% of frames against 1% carried whole). Nil
  /// when the outline can't be carried at all.
  static func bend(_ outline: [CGPoint], from a: Frame, to b: Frame, _ how: Bending = .standard) -> [CGPoint]? {
    let inset = how.inset, most = how.most
    guard let whole = carry(outline, from: a, to: b) else { return nil }
    let n = outline.count
    guard n >= 8, whole.count == n else { return whole }
    let sw = Float(a.w), sh = Float(a.h)
    let p = outline.map { SIMD2<Float>(Float($0.x) * sw, Float($0.y) * sh) }
    // Wholly on the picture, with room for the window round each point followed.
    let margin = inset + Float(window) + 1
    guard p.allSatisfy({ $0.x > margin && $0.x < sw - margin && $0.y > margin && $0.y < sh - margin }) else { return whole }
    let c = whole.map { SIMD2<Float>(Float($0.x) * sw, Float($0.y) * sh) }
    let middle = p.reduce(SIMD2<Float>.zero, +) / Float(n)
    let size = (p.map { simd_length_squared($0 - middle) }.reduce(0, +) / Float(n)).squareRoot()
    // Too small to bend (a few pixels across here): carried whole.
    guard size > 4 * inset else { return whole }
    var area: Float = 0
    for i in 0..<n {
      let q = p[(i + 1) % n]
      area += p[i].x * q.y - q.x * p[i].y
    }
    let inward: Float = area > 0 ? 1 : -1
    let inner: [SIMD2<Float>] = (0..<n).map { i in
      let t = p[(i + 1) % n] - p[(i + n - 1) % n]
      let len = simd_length(t)
      return len > 1e-3 ? p[i] + SIMD2<Float>(-t.y, t.x) / len * inward * inset : p[i]
    }
    let there = track(inner, from: a, to: b)
    var found: [Int] = []
    var ahead: [SIMD2<Float>] = []
    for (i, q) in there.enumerated() {
      if let q {
        found.append(i)
        ahead.append(q)
      }
    }
    guard found.count >= n / 4 else { return whole }
    let back = track(ahead, from: b, to: a)
    // Each point's move beyond the whole outline's, where it came home again.
    var extra = [SIMD2<Float>](repeating: .zero, count: n)
    var sure = [Float](repeating: 0, count: n)
    for (j, i) in found.enumerated() {
      guard let home = back[j], simd_distance(home, inner[i]) < how.home else { continue }
      extra[i] = (ahead[j] - inner[i]) - (c[i] - p[i])
      sure[i] = 1
    }
    // Smoothed along the edge (Gaussian, two points either way), only from the points that were sure.
    let sigma = max(how.sigma, 0.5), r = Int(3 * sigma + 0.5)
    let cap = most * size
    return (0..<n).map { i in
      var sum = SIMD2<Float>.zero, weight: Float = 0
      for k in -r...r {
        let j = ((i + k) % n + n) % n
        let w = exp(-0.5 * Float(k * k) / (sigma * sigma)) * sure[j]
        sum += extra[j] * w
        weight += w
      }
      var e = weight > 0.5 ? sum / weight : .zero
      let len = simd_length(e)
      if len > cap { e *= cap / len }
      let q = c[i] + e
      return CGPoint(x: CGFloat(q.x / sw), y: CGFloat(q.y / sh))
    }
  }

  static func median(_ v: [Float]) -> Float {
    guard !v.isEmpty else { return 0 }
    let s = v.sorted()
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
  }
}
