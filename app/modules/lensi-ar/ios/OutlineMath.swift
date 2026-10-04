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

  /// The outline to show next. Where it is and what shape it is are settled separately, so a
  /// thing that moves is followed without lag while its edge noise is damped:
  /// - Position follows the new cut: most of the way when it has clearly moved, half way
  ///   when it's only jitter. A jump of more than its own size is something else: replaced.
  /// - Shape (both outlines centred on their middles and lined up) is blended: mostly the
  ///   old one when they barely differ (that's the shimmer), mostly the new one when they
  ///   clearly do, the new one outright when it's a different shape.
  static func smooth(_ old: [simd_float3]?, _ new: [simd_float3]) -> [simd_float3] {
    guard let old, old.count == new.count, !new.isEmpty else { return new }
    let size = max(spread(old), 1e-6)
    let co = centre(old), cn = centre(new)
    let jump = simd_distance(co, cn) / size
    guard jump < 1 else { return new }
    let (shape, gap) = align(new.map { $0 - cn }, to: old.map { $0 - co })
    let relative = gap / size
    let t: Float = relative < 0.1 ? 0.35 : relative < 0.25 ? 0.6 : relative < 0.45 ? 0.85 : 1
    let follow: Float = jump > 0.15 ? 0.9 : 0.5
    let middle = co + (cn - co) * follow
    return zip(old, shape).map { o, n in middle + (o - co) + (n - (o - co)) * t }
  }
}
