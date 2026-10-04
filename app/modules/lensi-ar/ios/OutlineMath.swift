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

  /// `new` started at whichever point lines it up best with `old` (same count, same winding),
  /// and the RMS gap between them once lined up.
  static func align(_ new: [simd_float3], to old: [simd_float3]) -> (points: [simd_float3], gap: Float) {
    let n = new.count
    guard n > 0, n == old.count else { return (new, .greatestFiniteMagnitude) }
    var best = 0
    var bestCost = Float.greatestFiniteMagnitude
    for shift in 0..<n {
      var cost: Float = 0
      for i in 0..<n {
        cost += simd_distance_squared(new[(i + shift) % n], old[i])
        if cost >= bestCost { break }
      }
      if cost < bestCost {
        bestCost = cost
        best = shift
      }
    }
    return ((0..<n).map { new[($0 + best) % n] }, (bestCost / Float(n)).squareRoot())
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
}
