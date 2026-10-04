import CoreGraphics
import simd

/// Keeps SAM on one thing as it moves, frame after frame.
///
/// Each frame SAM is asked about where the thing should be now, its last outline carried
/// along by the phone's motion (ARKit, in the app) and by its own: a point well inside
/// that outline, within the outline's box grown a little. The cut that comes back is kept
/// only if it's plausibly the same thing (it overlaps the prediction and is about its
/// size); otherwise the prediction stands and the frame counts as a miss.
///
/// Everything here is in one frame's normalized image space (0...1, upright, top-left
/// origin), with `scale` the frame's size in pixels so x and y measure the same.
/// tools/track runs the same code over videos with hand-drawn masks for every frame.
enum LiveTracker {
  /// The box prompt is the predicted outline's box grown this much on each side.
  static let grow: CGFloat = 0.2

  struct Prompt {
    let point: CGPoint
    let box: CGRect
  }

  /// The SAM prompt for a thing predicted to be at `predicted` (a closed outline).
  static func prompt(for predicted: [CGPoint], scale: CGSize, grow: CGFloat = LiveTracker.grow) -> Prompt? {
    guard predicted.count >= 3 else { return nil }
    let r = bounds(predicted)
    guard r.width > 0, r.height > 0 else { return nil }
    let box = r.insetBy(dx: -r.width * grow, dy: -r.height * grow).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !box.isNull, box.width > 0.004, box.height > 0.004 else { return nil }
    return Prompt(point: interiorPoint(predicted, scale: scale), box: box)
  }

  /// How closely a cut must match where the thing should be to be taken as it.
  struct Gate {
    var minIoU: CGFloat
    var areaRatio: ClosedRange<CGFloat>
    /// Anything plausibly the same thing.
    static let loose = Gate(minIoU: 0.25, areaRatio: 0.4...2.5)
    /// Only a close match: a see-through or same-coloured neighbour (the floor seen through a
    /// glass table top, the wooden floor under a wooden table) creeps in a little each cut
    /// past the loose gate (tools/pin, on ARKit recordings).
    static let strict = Gate(minIoU: 0.5, areaRatio: 0.6...1.67)
  }

  /// Whether `cut` is the same thing as `predicted`: it overlaps it, and it's about the
  /// same size (it hasn't swallowed the background or shrunk to a speck).
  static func accepts(_ cut: [CGPoint], predicted: [CGPoint], gate: Gate = .loose) -> Bool {
    guard cut.count >= 3, predicted.count >= 3 else { return false }
    let a = area(cut), b = area(predicted)
    guard b > 0, gate.areaRatio.contains(a / b) else { return false }
    return iou(cut, predicted) > gate.minIoU
  }

  /// A point well inside the outline: of a grid over its box, the inside point farthest
  /// from every edge. Inside even for a crescent or a ring, whose box middle isn't.
  static func interiorPoint(_ poly: [CGPoint], scale: CGSize = CGSize(width: 1, height: 1), grid: Int = 15) -> CGPoint {
    let r = bounds(poly)
    var best = CGPoint(x: r.midX, y: r.midY)
    var bestDepth: CGFloat = -1
    for gy in 0..<grid {
      for gx in 0..<grid {
        let p = CGPoint(x: r.minX + (CGFloat(gx) + 0.5) / CGFloat(grid) * r.width,
                        y: r.minY + (CGFloat(gy) + 0.5) / CGFloat(grid) * r.height)
        guard contains(poly, p) else { continue }
        let d = edgeDistance(poly, p, scale: scale)
        if d > bestDepth {
          bestDepth = d
          best = p
        }
      }
    }
    return best
  }

  // MARK: - Polygon geometry

  static func bounds(_ poly: [CGPoint]) -> CGRect {
    guard let first = poly.first else { return .zero }
    var x0 = first.x, y0 = first.y, x1 = first.x, y1 = first.y
    for p in poly.dropFirst() {
      x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y)
    }
    return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
  }

  static func area(_ poly: [CGPoint]) -> CGFloat {
    guard poly.count > 2 else { return 0 }
    var s: CGFloat = 0
    for i in 0..<poly.count {
      let a = poly[i], b = poly[(i + 1) % poly.count]
      s += a.x * b.y - b.x * a.y
    }
    return abs(s) / 2
  }

  static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
    var inside = false
    var j = poly.count - 1
    for i in 0..<poly.count {
      let a = poly[i], b = poly[j]
      if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
      j = i
    }
    return inside
  }

  /// Distance from `p` to the nearest edge, in `scale` units.
  static func edgeDistance(_ poly: [CGPoint], _ p: CGPoint, scale: CGSize) -> CGFloat {
    var best = CGFloat.greatestFiniteMagnitude
    let q = CGPoint(x: p.x * scale.width, y: p.y * scale.height)
    for i in 0..<poly.count {
      let a = CGPoint(x: poly[i].x * scale.width, y: poly[i].y * scale.height)
      let b = CGPoint(x: poly[(i + 1) % poly.count].x * scale.width, y: poly[(i + 1) % poly.count].y * scale.height)
      let abx = b.x - a.x, aby = b.y - a.y
      let len = abx * abx + aby * aby
      let t = len > 0 ? min(max(((q.x - a.x) * abx + (q.y - a.y) * aby) / len, 0), 1) : 0
      best = min(best, hypot(q.x - (a.x + t * abx), q.y - (a.y + t * aby)))
    }
    return best
  }

  /// Intersection over union of two outlines, counted on a grid over both their boxes.
  static func iou(_ a: [CGPoint], _ b: [CGPoint], grid: Int = 64) -> CGFloat {
    let r = bounds(a).union(bounds(b))
    guard r.width > 0, r.height > 0 else { return 0 }
    var inter = 0, union = 0
    for gy in 0..<grid {
      for gx in 0..<grid {
        let p = CGPoint(x: r.minX + (CGFloat(gx) + 0.5) / CGFloat(grid) * r.width,
                        y: r.minY + (CGFloat(gy) + 0.5) / CGFloat(grid) * r.height)
        let ia = contains(a, p), ib = contains(b, p)
        if ia && ib { inter += 1 }
        if ia || ib { union += 1 }
      }
    }
    return union == 0 ? 0 : CGFloat(inter) / CGFloat(union)
  }
}
