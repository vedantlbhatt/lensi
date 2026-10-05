import CoreGraphics
import simd

/// What keeps a live SAM outline steady. SAM's polygon changes its corner count and starting
/// corner from one frame to the next, so each new one is resampled to the same number of
/// evenly spaced points, turned to line up with the last one, and blended into it: the same
/// shape a little moved settles instead of shimmering, and a different shape replaces it.
/// The points are in the world, so the phone moving changes nothing here; only the part does.
enum OutlineMath {
  static let count = 64

  /// `count` points evenly spaced along a closed ring. `scale` turns the ring's units into
  /// ones where x and y measure the same (normalized image points times the image's size).
  static func resample(_ ring: [CGPoint], count: Int = OutlineMath.count, scale: CGSize = CGSize(width: 1, height: 1)) -> [CGPoint] {
    let n = ring.count
    guard n >= 3, count >= 3 else { return ring }
    var along = [CGFloat](repeating: 0, count: n + 1)
    for i in 0..<n {
      let a = ring[i], b = ring[(i + 1) % n]
      along[i + 1] = along[i] + hypot((b.x - a.x) * scale.width, (b.y - a.y) * scale.height)
    }
    let total = along[n]
    guard total > 0 else { return ring }
    var out: [CGPoint] = []
    out.reserveCapacity(count)
    var edge = 0
    for k in 0..<count {
      let d = total * CGFloat(k) / CGFloat(count)
      while edge < n - 1, along[edge + 1] < d { edge += 1 }
      let length = along[edge + 1] - along[edge]
      let t = length > 0 ? (d - along[edge]) / length : 0
      let a = ring[edge], b = ring[(edge + 1) % n]
      out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }
    return out
  }

  /// `new` started at whichever point lines it up best with `old` (same count), run the same way
  /// round as `old`, and the RMS gap between them once lined up. SAM's contours don't always run
  /// the same way round: lined up only by where they start, a cut that ran the other way paired
  /// each point with one across the shape, and blending the two (`steady`, LiveShape.draw)
  /// collapsed the outline towards its middle (tools/pin: J fell from 98% to 3% for a few frames).
  static func align(_ new: [simd_float3], to old: [simd_float3]) -> (points: [simd_float3], gap: Float) {
    let n = new.count
    guard n > 0, n == old.count else { return (new, .greatestFiniteMagnitude) }
    let reversed = Array(new.reversed())
    var best = (ring: new, shift: 0)
    var bestCost = Float.greatestFiniteMagnitude
    for ring in [new, reversed] {
      for shift in 0..<n {
        var cost: Float = 0
        for i in 0..<n {
          cost += simd_distance_squared(ring[(i + shift) % n], old[i])
          if cost >= bestCost { break }
        }
        if cost < bestCost {
          bestCost = cost
          best = (ring, shift)
        }
      }
    }
    return ((0..<n).map { best.ring[($0 + best.shift) % n] }, (bestCost / Float(n)).squareRoot())
  }

  /// RMS distance of the points from their middle: how big the outline is, to judge a gap by.
  static func spread(_ points: [simd_float3]) -> Float {
    guard !points.isEmpty else { return 0 }
    let middle = points.reduce(simd_float3.zero, +) / Float(points.count)
    let sum = points.reduce(Float(0)) { $0 + simd_distance_squared($1, middle) }
    return (sum / Float(points.count)).squareRoot()
  }

  static func centre(_ points: [simd_float3]) -> simd_float3 {
    points.isEmpty ? .zero : points.reduce(simd_float3.zero, +) / Float(points.count)
  }

  /// How hard an outline is steadied. Shape: when a new cut differs from the last (both
  /// centred, lined up) by less than `quiet` of its size, that's noise and `keepQuiet` of the
  /// old shape is kept; under `small`, `keepSmall`; past that the new shape stands. Position:
  /// a move under `still` of its size is jitter and the outline goes `followStill` of the way;
  /// otherwise `followMoving`. A jump of more than its own size is something else: replaced.
  /// tools/track measures these against hand-drawn masks on real footage.
  struct Smoothing {
    var quiet: Float
    var keepQuiet: Float
    var small: Float
    var keepSmall: Float
    var still: Float
    var followStill: Float
    var followMoving: Float

    /// What the app uses (through `steady`, which lets real change through).
    static let standard = Smoothing(quiet: 0.1, keepQuiet: 0.65, small: 0.25, keepSmall: 0.4, still: 0.03, followStill: 0.6, followMoving: 1)
    /// The first setting: steady, but it lags anything that bends or turns quickly.
    static let strong = Smoothing(quiet: 0.1, keepQuiet: 0.65, small: 0.25, keepSmall: 0.4, still: 0.15, followStill: 0.5, followMoving: 0.9)
    /// Only the edge noise of a thing that holds its shape; motion and real shape change pass straight through.
    static let light = Smoothing(quiet: 0.05, keepQuiet: 0.5, small: 0.1, keepSmall: 0.25, still: 0.03, followStill: 0.6, followMoving: 1)
    static let minimal = Smoothing(quiet: 0.04, keepQuiet: 0.4, small: 0.04, keepSmall: 0, still: 0, followStill: 1, followMoving: 1)
    /// A thing that's still in the world: ARKit already says where it is, so a cut mostly
    /// refines its shape (as the view turns) and its edge noise is held down harder.
    static let still = Smoothing(quiet: 0.15, keepQuiet: 0.8, small: 0.3, keepSmall: 0.6, still: 0.1, followStill: 0.35, followMoving: 0.8)
  }

  /// The outline to show next. Where it is and what shape it is are settled separately, so a
  /// thing that moves is followed while its edge noise is damped (see `Smoothing`).
  static func smooth(_ old: [simd_float3]?, _ new: [simd_float3], _ how: Smoothing = .standard) -> [simd_float3] {
    guard let old, old.count == new.count, !new.isEmpty else { return new }
    let size = max(spread(old), 1e-6)
    let co = centre(old), cn = centre(new)
    let jump = simd_distance(co, cn) / size
    guard jump < 1 else { return new }
    let (shape, gap) = align(new.map { $0 - cn }, to: old.map { $0 - co })
    let relative = gap / size
    let keep: Float = relative < how.quiet ? how.keepQuiet : relative < how.small ? how.keepSmall : 0
    let follow: Float = jump < how.still ? how.followStill : how.followMoving
    let middle = co + (cn - co) * follow
    return zip(old, shape).map { o, n in middle + (o - co) * keep + n * (1 - keep) }
  }

  /// `smooth`, telling the thing's own change from edge noise by whether it keeps going the
  /// same way. `previous` is the last change (per point, centred, in this outline's order):
  /// when this one runs the same way (they correlate), the thing really is turning or bending
  /// and the change passes straight through; when it doesn't (noise flickers back and forth),
  /// it's damped as `how` says. Returns the outline and this change, for next time.
  static func steady(_ old: [simd_float3]?, _ new: [simd_float3], previous: [simd_float3]?,
                     _ how: Smoothing = .standard) -> (outline: [simd_float3], change: [simd_float3]?) {
    guard let old, old.count == new.count, !new.isEmpty else { return (new, nil) }
    let size = max(spread(old), 1e-6)
    let co = centre(old), cn = centre(new)
    let jump = simd_distance(co, cn) / size
    guard jump < 1 else { return (new, nil) }
    let (shape, gap) = align(new.map { $0 - cn }, to: old.map { $0 - co })
    let change = zip(shape, old).map { $0 - ($1 - co) }
    let relative = gap / size
    var keep: Float = relative < how.quiet ? how.keepQuiet : relative < how.small ? how.keepSmall : 0
    if let previous, previous.count == change.count, keep > 0 {
      var dot: Float = 0, a: Float = 0, b: Float = 0
      for i in 0..<change.count {
        dot += simd_dot(change[i], previous[i])
        a += simd_length_squared(change[i])
        b += simd_length_squared(previous[i])
      }
      if a > 0, b > 0, dot / (a.squareRoot() * b.squareRoot()) > 0.3 { keep = 0 }
    }
    let follow: Float = jump < how.still ? how.followStill : how.followMoving
    let middle = co + (cn - co) * follow
    return (zip(old, shape).map { o, n in middle + (o - co) * keep + n * (1 - keep) }, change)
  }

  /// The outline to show next on a flat picture (the ultra-wide at 0.5x, with no world to hold it
  /// in): the last one carried onto the new one by the affine map that fits it best, so motion,
  /// zoom and the view turning pass straight through, and only what's left over (mostly the
  /// mask's edge noise) let in `alpha` of the way a frame; all of it once that's more than `fast`
  /// of the outline's size, a real change of shape. Points in pixels, z unused. On the bottle clip
  /// (tools/edgetam/smooth.py) it shook less than `steady` at the same overlap with the reference.
  static func glide(_ old: [simd_float3]?, _ new: [simd_float3], alpha: Float = 0.5, fast: Float = 0.08) -> [simd_float3] {
    guard let old, old.count == new.count, new.count >= 3 else { return new }
    let size = max(spread(old), 1e-6)
    let co = centre(old), cn = centre(new)
    guard simd_distance(co, cn) / size < 1 else { return new }
    let lined = align(new.map { $0 - cn }, to: old.map { $0 - co }).points.map { $0 + cn }
    guard let moved = affine(old, onto: lined) else { return new }
    var sum: Float = 0
    for i in 0..<new.count { sum += simd_distance_squared(lined[i], moved[i]) }
    let left = (sum / Float(new.count)).squareRoot() / size
    let a: Float = left < fast ? alpha : 1
    return zip(moved, lined).map { $0 + ($1 - $0) * a }
  }

  /// `a` mapped onto `b` (paired points, x and y) by the affine map that fits best (least
  /// squares); nil when `a` is degenerate (all on a line).
  static func affine(_ a: [simd_float3], onto b: [simd_float3]) -> [simd_float3]? {
    // Normal equations in double: sum of [x y 1]^T [x y 1], and of [x y 1]^T times b's x and y.
    var m = simd_double3x3()
    var bx = simd_double3.zero, by = simd_double3.zero
    let c = centre(a)
    for (p, q) in zip(a, b) {
      let v = simd_double3(Double(p.x - c.x), Double(p.y - c.y), 1)
      m += simd_double3x3(v * v.x, v * v.y, v * v.z)
      bx += v * Double(q.x)
      by += v * Double(q.y)
    }
    guard abs(m.determinant) > 1e-9 else { return nil }
    let inv = m.inverse
    let mx = inv * bx, my = inv * by
    return a.map { p in
      let v = simd_double3(Double(p.x - c.x), Double(p.y - c.y), 1)
      return simd_float3(Float(simd_dot(mx, v)), Float(simd_dot(my, v)), p.z)
    }
  }

  /// Rings at least this dense are drawn as a curve (`curve`, `curvePath`); a coarser one (a box,
  /// a few corners) keeps its corners.
  static let curveFrom = 24

  /// A closed ring drawn as a smooth curve: the quadratic B-spline through the midpoints of its
  /// sides, each corner its control point, `per` points a side. Drawn straight from point to
  /// point, a ring of 64 shows its corners up close; this has none, and stays within a fraction
  /// of a side of the ring (it never overshoots, as a curve through the points can).
  static func curve(_ ring: [simd_float3], per: Int = 4) -> [simd_float3] {
    let n = ring.count
    guard n >= curveFrom, per >= 2 else { return ring }
    var out: [simd_float3] = []
    out.reserveCapacity(n * per)
    for i in 0..<n {
      let a = (ring[(i + n - 1) % n] + ring[i]) * 0.5
      let c = ring[i]
      let b = (ring[i] + ring[(i + 1) % n]) * 0.5
      for k in 0..<per {
        let t = Float(k) / Float(per), u = 1 - t
        out.append(a * (u * u) + c * (2 * u * t) + b * (t * t))
      }
    }
    return out
  }

  /// The same curve as a closed path on a flat picture (Core Graphics draws its quadratic
  /// segments exactly); a coarse ring straight from corner to corner.
  static func curvePath(_ ring: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    let n = ring.count
    guard n >= 3 else { return path }
    guard n >= curveFrom else {
      path.addLines(between: ring)
      path.closeSubpath()
      return path
    }
    func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
    path.move(to: mid(ring[n - 1], ring[0]))
    for i in 0..<n { path.addQuadCurve(to: mid(ring[i], ring[(i + 1) % n]), control: ring[i]) }
    path.closeSubpath()
    return path
  }

  /// A closed ring's points smoothed along it (a Gaussian `sigma` points wide): the stair-steps of
  /// a mask's edge, not its shape.
  static func blurred(_ ring: [CGPoint], sigma: CGFloat) -> [CGPoint] {
    let n = ring.count
    guard sigma > 0, n >= 5 else { return ring }
    let r = Int(3 * sigma + 0.5)
    var weights: [CGFloat] = []
    for k in -r...r {
      let z = CGFloat(k) / sigma
      weights.append(exp(-0.5 * z * z))
    }
    let total = weights.reduce(0, +)
    return (0..<n).map { i in
      var x: CGFloat = 0, y: CGFloat = 0
      for (j, w) in weights.enumerated() {
        let p = ring[((i + j - r) % n + n) % n]
        x += p.x * w
        y += p.y * w
      }
      return CGPoint(x: x / total, y: y / total)
    }
  }

  /// Triangles covering a simple polygon (indices into `p`, three a triangle), by clipping ears;
  /// a fan from the first point if the polygon crosses itself and runs out of ears.
  static func triangulate(_ p: [SIMD2<Float>]) -> [Int] {
    let n = p.count
    guard n >= 3 else { return [] }
    var area: Float = 0
    for i in 0..<n {
      let a = p[i], b = p[(i + 1) % n]
      area += a.x * b.y - b.x * a.y
    }
    // Counter-clockwise from here on.
    var left = area >= 0 ? Array(0..<n) : Array((0..<n).reversed())
    func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    func inTriangle(_ q: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
      cross(a, b, q) > 0 && cross(b, c, q) > 0 && cross(c, a, q) > 0
    }
    var out: [Int] = []
    out.reserveCapacity(3 * (n - 2))
    var k = 0
    var sinceEar = 0
    while left.count > 3 {
      if sinceEar > left.count {
        // No ear left: the polygon crosses itself. Fan the rest.
        for i in 1..<(left.count - 1) { out += [left[0], left[i], left[i + 1]] }
        return out
      }
      let m = left.count
      let i0 = left[(k + m - 1) % m], i1 = left[k % m], i2 = left[(k + 1) % m]
      let a = p[i0], b = p[i1], c = p[i2]
      var ear = cross(a, b, c) > 0
      if ear {
        for j in left where j != i0 && j != i1 && j != i2 {
          if inTriangle(p[j], a, b, c) {
            ear = false
            break
          }
        }
      }
      if ear {
        out += [i0, i1, i2]
        left.remove(at: k % m)
        sinceEar = 0
        k = k % max(left.count, 1)
      } else {
        k = (k + 1) % m
        sinceEar += 1
      }
    }
    out += left
    return out
  }
}
