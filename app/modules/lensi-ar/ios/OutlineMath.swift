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

  /// The outline to show next: `new` blended into `old` when it's the same shape (a little
  /// moved, a little different at the edges), `new` alone when it isn't.
  static func smooth(_ old: [simd_float3]?, _ new: [simd_float3]) -> [simd_float3] {
    guard let old, old.count == new.count, !new.isEmpty else { return new }
    let (aligned, gap) = align(new, to: old)
    let relative = gap / max(spread(old), 1e-4)
    guard relative < 0.45 else { return aligned }
    // Barely different: mostly keep what's there (that's the shimmer). Clearly moved: follow.
    let t: Float = relative < 0.1 ? 0.35 : relative < 0.25 ? 0.6 : 0.85
    return zip(old, aligned).map { $0 + ($1 - $0) * t }
  }
}
