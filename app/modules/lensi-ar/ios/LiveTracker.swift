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

  /// The SAM prompt for a thing predicted to be at `predicted` (a closed outline). Up close
  /// part of it can be off the picture: the point is then well inside the part that's on it.
  static func prompt(for predicted: [CGPoint], scale: CGSize, grow: CGFloat = LiveTracker.grow) -> Prompt? {
    guard predicted.count >= 3 else { return nil }
    let r = bounds(predicted)
    guard r.width > 0, r.height > 0 else { return nil }
    let box = r.insetBy(dx: -r.width * grow, dy: -r.height * grow).intersection(picture)
    guard !box.isNull, box.width > 0.004, box.height > 0.004 else { return nil }
    let visible = clipped(predicted)
    guard visible.count >= 3 else { return nil }
    return Prompt(point: interiorPoint(visible, scale: scale), box: box)
  }

  /// The whole picture, in the normalized space everything here is in.
  static let picture = CGRect(x: 0, y: 0, width: 1, height: 1)

  /// Less than this much of a thing on the picture (by area), SAM isn't asked about it: what's
  /// left is too little to say where the rest went. ARKit keeps it where it was meanwhile.
  static let minVisible: CGFloat = 0.12

  /// A thing whose outline is at least this much on the picture is taken as wholly in view.
  static let wholeVisible: CGFloat = 0.95

  /// What a cut says about a thing predicted at `predicted`: the outline to take (upright,
  /// like both), or nil when the cut is something else. Up close only part of a thing is on the
  /// picture, and SAM can only cut that part: it's judged against the part of the prediction
  /// that's on the picture, and rather than shrinking the thing to what's in view, the whole
  /// prediction moves the way the cut's own edges moved (the ones not on the picture's edge).
  /// `scaleLimit`: how much bigger or smaller one cut can make it.
  /// `splice`: what's on the picture is the cut itself, and only what's off it is the moved
  /// prediction (`spliced`); false, the moved prediction throughout, its shape as it was when it was
  /// last seen whole. `scale`: the picture's size, for the splice's evenly spaced points.
  static func follow(cut: [CGPoint], predicted: [CGPoint], gate: Gate = .loose, scaleLimit: CGFloat = 1.4,
                     splice: Bool = LiveTracker.splices, scale: CGSize = CGSize(width: 1, height: 1)) -> [CGPoint]? {
    guard cut.count >= 3, predicted.count >= 3 else { return nil }
    let visible = clipped(predicted)
    guard visible.count >= 3, accepts(cut, predicted: visible, gate: gate) else { return nil }
    guard visibleFraction(predicted) < wholeVisible else { return cut }
    let fit = edgeFit(from: bounds(visible), to: bounds(cut), limit: scaleLimit)
    let moved = predicted.map { CGPoint(x: fit.to.x + ($0.x - fit.from.x) * fit.scale, y: fit.to.y + ($0.y - fit.from.y) * fit.scale) }
    return splice ? spliced(cut, onto: moved, scale: scale) : moved
  }

  /// Whether `follow` splices a cut that's only part of its thing onto the rest of it (`spliced`).
  static let splices = false

  /// `cut`, the part of a thing on the picture (its points on the picture's edge where the thing
  /// runs off it), joined to the part of `whole` (the whole outline, where it should be) that's off
  /// the picture: on the picture it's the cut's own shape, and only past the edge is it as the thing
  /// was last seen. Each stretch of the cut along the picture's edge gives way to the stretch of
  /// `whole` that goes out past the edge near it, joined to the cut along the edge (the outline of
  /// the two together); one with no such stretch near it stays on the edge, and a stretch of `whole`
  /// out past an edge the cut doesn't reach is left off (the cut says it ends before it).
  /// As many points as `whole`, evenly spaced in `scale`.
  static func spliced(_ cut: [CGPoint], onto whole: [CGPoint], scale: CGSize = CGSize(width: 1, height: 1),
                      margin: CGFloat = 0.006) -> [CGPoint] {
    guard cut.count >= 3, whole.count >= 3 else { return cut }
    let onEdge = { (p: CGPoint) in p.x < margin || p.x > 1 - margin || p.y < margin || p.y > 1 - margin }
    let off = { (p: CGPoint) in p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1 }
    // The same way round as the cut.
    let outline = signedArea(cut).sign == signedArea(whole).sign ? whole : Array(whole.reversed())
    guard let edges = runs(cut.map(onEdge)), !edges.runs.isEmpty, let offs = runs(outline.map(off)), !offs.runs.isEmpty else {
      return OutlineMath.resample(cut, count: whole.count, scale: scale)
    }
    let (cs, edgeRuns) = edges
    let (ws, offRuns) = offs
    let n = cut.count, m = outline.count
    let c = { (i: Int) in cut[(cs + i) % n] }
    let w = { (j: Int) in outline[(ws + j + m) % m] }
    // Where each stretch of `whole` leaves the picture and comes back on to it.
    let out = offRuns.map { r in (run: r, leaves: leaving(w(r.0 - 1), w(r.0)), returns: leaving(w(r.1 + 1), w(r.1))) }
    let longest = max(scale.width, scale.height)
    let gap = { (a: CGPoint, b: CGPoint) in hypot((a.x - b.x) * scale.width, (a.y - b.y) * scale.height) / longest }
    // Nearest first: the cut reaches the edge where `whole` leaves the picture, and leaves it where
    // `whole` comes back (both run the same way round). Only along the same edges: off a corner, a cut
    // along one edge and `whole` out past the other don't meet, and joined they'd draw a line along
    // the picture's edge.
    let sides = edgeRuns.map { r in Set((r.0...r.1).map { side(c($0)) }) }
    var pairs: [(cost: CGFloat, e: Int, o: Int)] = []
    for (e, r) in edgeRuns.enumerated() {
      for (o, x) in out.enumerated() where sides[e].contains(side(x.leaves)) && sides[e].contains(side(x.returns)) {
        pairs.append((gap(c(r.0), x.leaves) + gap(c(r.1), x.returns), e, o))
      }
    }
    var matched: [Int: Int] = [:]
    var used = Set<Int>()
    for p in pairs.sorted(by: { $0.cost < $1.cost }) where p.cost <= 0.5 && matched[p.e] == nil && !used.contains(p.o) {
      matched[p.e] = p.o
      used.insert(p.o)
    }
    var ring: [CGPoint] = []
    var starts: [Int: Int] = [:]
    for (e, r) in edgeRuns.enumerated() { starts[r.0] = e }
    var i = 0
    while i < n {
      guard let e = starts[i] else {
        ring.append(c(i))
        i += 1
        continue
      }
      let r = edgeRuns[e]
      if let o = matched[e] {
        let x = out[o]
        ring.append(c(r.0))
        ring += border(from: c(r.0), to: x.leaves)
        ring.append(x.leaves)
        for j in x.run.0...x.run.1 { ring.append(w(j)) }
        ring.append(x.returns)
        ring += border(from: x.returns, to: c(r.1))
        ring.append(c(r.1))
      } else {
        for j in r.0...r.1 { ring.append(c(j)) }
      }
      i = r.1 + 1
    }
    return OutlineMath.resample(ring, count: whole.count, scale: scale)
  }

  /// Twice a ring's area, signed by which way round it runs.
  static func signedArea(_ poly: [CGPoint]) -> CGFloat {
    var s: CGFloat = 0
    for i in 0..<poly.count {
      let a = poly[i], b = poly[(i + 1) % poly.count]
      s += a.x * b.y - b.x * a.y
    }
    return s
  }

  /// The longest stretches of true in a ring of flags, as first and last index counted from
  /// `start` (a false one); nil when they're all true or all false.
  private static func runs(_ flags: [Bool]) -> (start: Int, runs: [(Int, Int)])? {
    guard let start = flags.firstIndex(of: false), flags.contains(true) else { return nil }
    let n = flags.count
    var out: [(Int, Int)] = []
    var i = 0
    while i < n {
      if flags[(start + i) % n] {
        let first = i
        while i + 1 < n, flags[(start + i + 1) % n] { i += 1 }
        out.append((first, i))
      }
      i += 1
    }
    return (start, out)
  }

  /// Where the segment from `p` (on the picture) to `q` (off it) leaves the picture.
  private static func leaving(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
    var t: CGFloat = 1
    let dx = q.x - p.x, dy = q.y - p.y
    if q.x < 0, dx != 0 { t = min(t, -p.x / dx) }
    if q.x > 1, dx != 0 { t = min(t, (1 - p.x) / dx) }
    if q.y < 0, dy != 0 { t = min(t, -p.y / dy) }
    if q.y > 1, dy != 0 { t = min(t, (1 - p.y) / dy) }
    t = max(t, 0)
    return CGPoint(x: p.x + dx * t, y: p.y + dy * t)
  }

  /// Which of the picture's edges a point is nearest: 0 the top, 1 the right, 2 the bottom, 3 the left.
  private static func side(_ p: CGPoint) -> Int {
    let x = min(max(p.x, 0), 1), y = min(max(p.y, 0), 1)
    let nearest = [y, 1 - x, 1 - y, x]
    return nearest.firstIndex(of: nearest.min()!)!
  }

  /// The picture's corners passed going from `p` to `q` (both on its edge) the shorter way round.
  private static func border(from p: CGPoint, to q: CGPoint) -> [CGPoint] {
    // How far round the edge: 0 at the top left, 1 at the top right, 2 bottom right, 3 bottom left.
    func around(_ p: CGPoint) -> CGFloat {
      let x = min(max(p.x, 0), 1), y = min(max(p.y, 0), 1)
      switch side(p) {
      case 0: return x
      case 1: return 1 + y
      case 2: return 2 + (1 - x)
      default: return 3 + (1 - y)
      }
    }
    let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    let a = around(p), b = around(q)
    let forward = (b - a).truncatingRemainder(dividingBy: 4) + ((b - a) < 0 ? 4 : 0)
    var out: [CGPoint] = []
    if forward <= 2 {
      var k = Int(a.rounded(.down)) + 1
      while CGFloat(k) - a < forward, out.count < 4 {
        out.append(corners[k % 4])
        k += 1
      }
    } else {
      let back = 4 - forward
      var k = Int(a.rounded(.up)) - 1
      while a - CGFloat(k) < back, out.count < 4 {
        out.append(corners[((k % 4) + 4) % 4])
        k -= 1
      }
    }
    return out
  }

  /// How a box moved and grew, from the sides of it that are really its own: a side on the
  /// picture's edge is where the picture ends, not where the thing does. A point of `a` (the
  /// middle of an axis with both sides free, else its free side; along an axis with neither,
  /// it didn't move as far as this can tell), where it went in `b`, and how much bigger `b` is
  /// (from an axis with both sides free; getting closer, a thing grows the same both ways).
  static func edgeFit(from a: CGRect, to b: CGRect, margin: CGFloat = 0.01, limit: CGFloat = 1.4) -> (from: CGPoint, to: CGPoint, scale: CGFloat) {
    func free(_ v: CGFloat, low: Bool) -> Bool { low ? v > margin : v < 1 - margin }
    let lx = free(a.minX, low: true) && free(b.minX, low: true), hx = free(a.maxX, low: false) && free(b.maxX, low: false)
    let ly = free(a.minY, low: true) && free(b.minY, low: true), hy = free(a.maxY, low: false) && free(b.maxY, low: false)
    var scales: [CGFloat] = []
    if lx, hx, a.width > 0.005 { scales.append(b.width / a.width) }
    if ly, hy, a.height > 0.005 { scales.append(b.height / a.height) }
    let scale = scales.isEmpty ? 1 : min(max(scales.reduce(0, +) / CGFloat(scales.count), 1 / limit), limit)
    func matched(_ lo: Bool, _ hi: Bool, _ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> (CGFloat, CGFloat) {
      if lo && hi { return ((a0 + a1) / 2, (b0 + b1) / 2) }
      if lo { return (a0, b0) }
      if hi { return (a1, b1) }
      return ((a0 + a1) / 2, (a0 + a1) / 2)
    }
    let (ax, bx) = matched(lx, hx, a.minX, a.maxX, b.minX, b.maxX)
    let (ay, by) = matched(ly, hy, a.minY, a.maxY, b.minY, b.maxY)
    return (CGPoint(x: ax, y: ay), CGPoint(x: bx, y: by), scale)
  }

  /// The part of a closed outline on the picture (Sutherland-Hodgman against its four edges).
  static func clipped(_ poly: [CGPoint]) -> [CGPoint] {
    guard poly.count >= 3 else { return [] }
    if poly.allSatisfy({ $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1 }) { return poly }
    // Each edge of the picture: which side of it is in, and where a segment crosses it.
    let edges: [(inside: (CGPoint) -> Bool, cross: (CGPoint, CGPoint) -> CGPoint)] = [
      ({ $0.x >= 0 }, { a, b in CGPoint(x: 0, y: a.y + (b.y - a.y) * (0 - a.x) / (b.x - a.x)) }),
      ({ $0.x <= 1 }, { a, b in CGPoint(x: 1, y: a.y + (b.y - a.y) * (1 - a.x) / (b.x - a.x)) }),
      ({ $0.y >= 0 }, { a, b in CGPoint(x: a.x + (b.x - a.x) * (0 - a.y) / (b.y - a.y), y: 0) }),
      ({ $0.y <= 1 }, { a, b in CGPoint(x: a.x + (b.x - a.x) * (1 - a.y) / (b.y - a.y), y: 1) }),
    ]
    var out = poly
    for edge in edges {
      let input = out
      out = []
      guard var a = input.last else { break }
      for b in input {
        let ina = edge.inside(a), inb = edge.inside(b)
        if inb {
          if !ina { out.append(edge.cross(a, b)) }
          out.append(b)
        } else if ina {
          out.append(edge.cross(a, b))
        }
        a = b
      }
    }
    return out.count >= 3 ? out : []
  }

  /// How much of an outline is on the picture, by area.
  static func visibleFraction(_ poly: [CGPoint]) -> CGFloat {
    let whole = area(poly)
    guard whole > 0 else { return 0 }
    return min(area(clipped(poly)) / whole, 1)
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
    /// A close match only: for a still thing seen from about where it was last cut. Its outline
    /// can only change as the view of it does, so a cut that's grown onto a neighbour (a towel
    /// hanging beside a trolley, the strict gate let it in and each cut after crept further)
    /// is refused (tools/walk).
    static let tight = Gate(minIoU: 0.7, areaRatio: 0.8...1.25)
    /// Anything: where it should be is what's stale (ARKit's world moved under it).
    static let any = Gate(minIoU: -1, areaRatio: 0...CGFloat.greatestFiniteMagnitude)
  }

  /// A still thing (its depth known) seen from within this angle (radians) of where its last
  /// cut was taken from is asked about with the tight gate (`Gate.tight`).
  static let tightTurn: Float = 0.15

  /// How to ask about a thing (`asking(still:)`), with the tight gate for a still one seen from
  /// about where it was last cut (`turned`: radians since; nil when unknown).
  static func asking(still: Bool, turned: Float?) -> (grow: CGFloat, gate: Gate, smoothing: OutlineMath.Smoothing) {
    var how = asking(still: still)
    if still, let turned, turned < tightTurn { how.gate = .tight }
    return how
  }

  /// Below this speed (in its own sizes a second) a thing counts as still. ARKit takes the
  /// phone's motion out, so for the app it's the thing's own: a part on an engine is still
  /// however the phone moves.
  static let stillBelow: CGFloat = 0.5

  /// How to ask SAM about a thing, which cut to take, and how to blend it in: a still thing
  /// barely changes between cuts, so a cut that strays from where it should be is something
  /// else (strict, within a tight box), and ARKit already says where it is (blended in gently);
  /// a thing that moves or bends really changes, and the strict gate would refuse it (loose,
  /// within a wider box, as OutlineMath.steady's standard). tools/pin and tools/track measure both.
  static func asking(sizesPerSecond speed: CGFloat) -> (grow: CGFloat, gate: Gate, smoothing: OutlineMath.Smoothing) {
    asking(still: speed < stillBelow)
  }

  /// The same for a thing already judged still or moving (LiveShape.still, which doesn't
  /// flip back and forth on one noisy cut).
  static func asking(still: Bool) -> (grow: CGFloat, gate: Gate, smoothing: OutlineMath.Smoothing) {
    still ? (0.1, .strict, .still) : (grow, .loose, .standard)
  }

  /// A still thing counts as moving from this speed (its own sizes a second), and a moving one
  /// as still again under `stillBelow`: in between it stays as it was, so one noisy cut
  /// doesn't swap how it's asked about, blended and drawn.
  static let movingAbove: CGFloat = 0.8

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
