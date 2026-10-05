import CoreGraphics
import Foundation
import simd

/// A camera as ARKit reports one frame of it, frozen: where it is (`transform`, camera to
/// world, ARKit's axes: x right along the sensor image, y up, z towards the viewer), its lens
/// (`intrinsics`, in pixels of the sensor image, which lies on its side) and that image's
/// size. "Upright" points are 0...1 in the picture as the phone shows it held upright (the
/// sensor image turned `.right`), top-left origin. With a plane it lays picture points in the
/// world. Frozen at the moment of a selection, callouts that arrive from the cloud a second
/// later still land where they were in that frame.
///
/// No ARKit in here (LensiARView makes these from ARFrames), so tools/pin runs the same code
/// on ARKit's recorded poses.
struct FrozenCamera {
  let transform: simd_float4x4
  let intrinsics: simd_float3x3
  let resolution: CGSize
  let crop: CGRect
  var planePoint = simd_float3.zero
  var planeNormal = simd_float3(0, 0, 1)

  init(transform: simd_float4x4, intrinsics: simd_float3x3, resolution: CGSize,
       crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) {
    self.transform = transform
    self.intrinsics = intrinsics
    self.resolution = resolution
    self.crop = crop
  }

  /// The ray from the camera through an upright picture point: origin and direction, world.
  func ray(_ upright: CGPoint) -> (simd_float3, simd_float3) {
    let px = Float(upright.y * resolution.width)
    let py = Float((1 - upright.x) * resolution.height)
    let fx = intrinsics[0][0], fy = intrinsics[1][1]
    let cx = intrinsics[2][0], cy = intrinsics[2][1]
    let dirCam = simd_float4((px - cx) / fx, -(py - cy) / fy, -1, 0)
    let dir = simd_normalize(simd_make_float3(simd_mul(transform, dirCam)))
    let origin = simd_make_float3(transform.columns.3)
    return (origin, dir)
  }

  /// A plane through the anchor facing the camera: callouts sit on the object's
  /// front face instead of punching through to the table behind it.
  func withPlane(through point: simd_float3) -> FrozenCamera {
    var s = self
    s.planePoint = point
    s.planeNormal = simd_normalize(-simd_make_float3(transform.columns.2))
    return s
  }

  /// Where world points land in this camera's upright picture (0…1, the inverse of `ray`);
  /// nil when any is behind it.
  func upright(_ world: [simd_float3]) -> [CGPoint]? {
    let toCamera = transform.inverse
    var out: [CGPoint] = []
    out.reserveCapacity(world.count)
    for w in world {
      let c = simd_mul(toCamera, simd_float4(w, 1))
      guard c.z < -0.02 else { return nil }
      out.append(picture(c))
    }
    return out
  }

  /// A point in the camera's own space (in front of it: z < 0) where it lands in the upright picture.
  private func picture(_ c: simd_float4) -> CGPoint {
    let fx = intrinsics[0][0], fy = intrinsics[1][1]
    let cx = intrinsics[2][0], cy = intrinsics[2][1]
    let px = cx + fx * c.x / -c.z
    let py = cy - fy * c.y / -c.z
    return CGPoint(x: 1 - CGFloat(py) / resolution.height, y: CGFloat(px) / resolution.width)
  }

  /// An upright picture point laid on the plane (`withPlane`); nil when its ray misses it.
  func onPlane(_ upright: CGPoint) -> simd_float3? {
    let (origin, dir) = ray(upright)
    let denom = simd_dot(dir, planeNormal)
    guard abs(denom) > 1e-4 else { return nil }
    let t = simd_dot(planePoint - origin, planeNormal) / denom
    return t > 0 ? origin + dir * t : nil
  }

  /// Where the camera is, in the world.
  var position: simd_float3 { simd_make_float3(transform.columns.3) }

  /// An upright picture point in the sensor image's own 0...1 space (lying on its side, top-left
  /// origin), where ARKit's depth maps are.
  static func sensor(_ upright: CGPoint) -> CGPoint { CGPoint(x: upright.y, y: 1 - upright.x) }

  /// How far from the camera, along the line of sight through upright point `middle`, a thing
  /// is whose depth (straight ahead of the camera, metres: what LiDAR measures) is `depth`.
  func range(depth: Float, through middle: CGPoint) -> Float {
    let (_, dir) = ray(middle)
    let ahead = simd_normalize(-simd_make_float3(transform.columns.2))
    return depth / max(simd_dot(dir, ahead), 0.2)
  }

  /// The median depth (straight ahead, metres) of the world points (ARKit's feature points) this
  /// camera sees inside the upright outline `ring`; nil when fewer than `minimum` are. Points ARKit
  /// found in a frame are ones it saw in it: inside a thing's outline, they're on the thing.
  func medianDepth(of points: [simd_float3], inside ring: [CGPoint], minimum: Int = 8) -> Float? {
    let visible = LiveTracker.clipped(ring)
    guard visible.count >= 3 else { return nil }
    let toCamera = transform.inverse
    let box = LiveTracker.bounds(visible)
    var depths: [Float] = []
    for p in points {
      let c = simd_mul(toCamera, simd_float4(p, 1))
      guard c.z < -0.05 else { continue }
      let u = picture(c)
      guard box.contains(u), LiveTracker.contains(visible, u) else { continue }
      depths.append(-c.z)
    }
    guard depths.count >= minimum else { return nil }
    depths.sort()
    return depths[depths.count / 2]
  }
}

/// One live outline as the app keeps it: OutlineMath.count points in the world, on a plane
/// through its part facing the camera that saw it, redrawn from there every display frame.
/// SAM's cuts are blended in (`take`), between them it rides its own pixels (`carry`), and
/// what's drawn eases onto each new cut (`draw`). Times are frame captures, on the clock of
/// CACurrentMediaTime (ARFrame.timestamp). tools/pin runs this on ARKit's recorded poses.
struct LiveShape {
  /// OutlineMath.count points, in the world, as of `seen`.
  var world: [simd_float3]
  /// When the frame they were cut from (or the flow last carried them to) was captured.
  var seen: CFTimeInterval
  /// When SAM last cut it (an outline the flow carries still needs SAM to say it's right).
  var cut: CFTimeInterval
  /// Asked for since it was last found, and not found.
  var misses = 0
  /// How the thing itself moves (metres a second, steadied): between SAM's frames it's drawn
  /// carried along, and SAM is asked where it should be next.
  var velocity = simd_float3.zero
  /// A guide tag rides with its part: where it sits from the outline's middle.
  var tagOffset: simd_float3?
  /// Its last change of shape, so the next tells real turning or bending from edge noise.
  var lastChange: [simd_float3]?
  /// It follows its thing from frame to frame (a guide part, a pinned thing).
  let follows: Bool
  /// Pinned by the user (the strip): never let go, however long SAM loses it (behind a hand,
  /// out of view). It stays where it was in the world, and only a cut that fits it there
  /// takes it back.
  var pinned = false
  /// How far the flow has carried it, frame by frame (capture times, newest last, the last
  /// second): a SAM cut that lands after the flow has moved on is brought along the same way.
  var moves: [(t: CFTimeInterval, by: simd_float3)] = []
  /// What the last display frame drew, and when.
  var drawn: [simd_float3]?
  var drawnAt: CFTimeInterval = 0
  /// Still in the world, as last judged (`judge`): it starts still, counts as moving past
  /// LiveTracker.movingAbove and as still again under LiveTracker.stillBelow, so one noisy
  /// cut doesn't swap how it's asked about, blended and drawn.
  private(set) var still = true
  /// Which way it was seen from (from its middle, unit) when the last cut was taken: a still
  /// thing seen from about there again is asked about with the tight gate (`turned`).
  private(set) var lastView: simd_float3?

  /// What's drawn eases onto where the outline is in about this long (seconds) instead of
  /// jumping when a cut lands: 60 ms was smoother still but fell 4-8 points of J behind on fast
  /// things (tools/track measured 30, 60 and adaptive). That's for a thing that moves.
  static let ease: Float = 0.03
  /// A still thing's: ARKit already holds it where it is however the phone moves (that isn't
  /// eased at all: the points are in the world), so all a cut or the flow can add is its own
  /// noise, and on ARKit recordings that tripled how much a still outline lurched from frame to
  /// frame (tools/pin).
  static let easeStill: Float = 0.15
  /// A still thing the flow says moved less than this much of its size in one step (about half
  /// its size a second) didn't: that's the flow's noise (tools/pin).
  static let stillFlow: Float = 0.015

  init(world: [simd_float3], at t: CFTimeInterval, follows: Bool) {
    self.world = world
    seen = t
    cut = t
    self.follows = follows
  }

  /// Still or moving again, by its own speed now (`still`).
  mutating func judge() {
    let speed = CGFloat(sizesPerSecond)
    if still {
      if speed > LiveTracker.movingAbove { still = false }
    } else if speed < LiveTracker.stillBelow {
      still = true
    }
  }

  /// How fast the thing itself moves, in its own sizes a second (LiveTracker.asking).
  var sizesPerSecond: Float {
    simd_length(velocity) / max(OutlineMath.spread(world), 0.01)
  }

  /// Where it is at `t`: a moving thing's outline carried along by its own motion (at most
  /// 0.3 s ahead). A still one is where it is: carried by a speed that's only noise, it swung.
  func placed(at t: CFTimeInterval) -> [simd_float3] {
    guard !still, simd_length(velocity) >= 0.02 else { return world }
    let dt = Float(min(max(t - seen, 0), 0.3))
    return dt == 0 ? world : world.map { $0 + velocity * dt }
  }

  /// SAM's cut of it, laid in the world from a frame captured at `t` by a camera at `origin`,
  /// blended into where it should be by then: a moving thing is followed, and its edge settles
  /// unless it's really changing shape (OutlineMath.steady). SAM takes a while: if the flow has
  /// carried the outline past `t`, the cut is brought along the same way first. `measure` false
  /// (the phone itself was moving fast, so where the cut landed says little about the thing's
  /// own speed): its speed only fades.
  mutating func take(_ fresh: [simd_float3], at t: CFTimeInterval, how: OutlineMath.Smoothing = .standard, measure: Bool = true,
                     seenFrom origin: simd_float3? = nil) {
    var forwarded = fresh
    var at = t
    if seen > t {
      let since = moves.filter { $0.t > t }.reduce(simd_float3.zero) { $0 + $1.by }
      forwarded = fresh.map { $0 + since }
      at = seen
    }
    let steadied = OutlineMath.steady(placed(at: at), forwarded, previous: lastChange, how)
    let next = steadied.outline
    lastChange = steadied.change
    // Its speed, when the flow isn't measuring it.
    let dt = Float(at - seen)
    if !measure {
      velocity *= 0.7
    } else if dt > 0.01 {
      let v = (OutlineMath.centre(next) - OutlineMath.centre(world)) / dt
      velocity = velocity * 0.4 + v * 0.6
    }
    judge()
    world = next
    seen = at
    cut = t
    misses = 0
    if let origin {
      let v = origin - OutlineMath.centre(world)
      let d = simd_length(v)
      if d > 0.01 { lastView = v / d }
    }
  }

  /// A cut of a still thing that agrees with where it's drawn (LiveTracker.agrees) is SAM's
  /// noise, not news: it isn't blended in. Blending such cuts in made an outline that ARKit alone
  /// holds dead still on its thing slip against it seven times as much, in a jump each time a cut
  /// landed (tools/walk). It still says the thing is there.
  mutating func confirmed(at t: CFTimeInterval) {
    misses = 0
    cut = t
    velocity *= 0.5
    judge()
  }

  /// How far round (radians) the view of it from `origin` has turned since its last cut; nil
  /// when there's been no cut from a known place.
  func turned(from origin: simd_float3) -> Float? {
    guard let lastView else { return nil }
    let v = origin - OutlineMath.centre(world)
    let d = simd_length(v)
    guard d > 0.01 else { return nil }
    return acos(min(max(simd_dot(v / d, lastView), -1), 1))
  }

  // MARK: How far away it is
  //
  // Where a thing is laid starts as a guess (ARKit's points on it, or a raycast through it that
  // can hit the wall behind), and every cut is laid at the depth it already has. At the wrong
  // depth an outline slides off its thing whenever the phone moves, by the phone's step times
  // how wrong the depth is. Moving it nearer or further along the lines of sight from the camera
  // that just cut it changes nothing from there, so whatever measures how far it is inside a cut
  // (LiDAR on a phone that has it, ARKit's points on it) puts it right as it's followed
  // (`setDepth`). tools/walk measures it on handheld walk-arounds.

  /// How far each depth measured inside a cut moves it there: LiDAR's, and ARKit's points'
  /// (sparser, and only where there's texture).
  static let lidarWeight: Float = 0.6
  static let pointsWeight: Float = 0.3
  /// The phone itself turning (radians a second) or moving (metres a second) faster than this:
  /// the picture is a blur, and where a cut or the flow puts a thing says little about its own
  /// motion (LensiARView.phoneFast, tools/walk).
  static let fastTurn: Float = 1.0
  static let fastMove: Float = 0.5

  /// The median of `depth` (metres straight ahead; nil where it has none) over a grid inside an
  /// upright outline, the part of it on the picture: what a depth map (LiDAR) says about the
  /// thing a cut found. Nil when too little of it has a depth.
  static func depthInside(_ ring: [CGPoint], grid: Int = 14, depth: (CGPoint) -> Float?) -> Float? {
    let visible = LiveTracker.clipped(ring)
    guard visible.count >= 3 else { return nil }
    let r = LiveTracker.bounds(visible)
    var found: [Float] = []
    for gy in 0..<grid {
      for gx in 0..<grid {
        let p = CGPoint(x: r.minX + (CGFloat(gx) + 0.5) / CGFloat(grid) * r.width,
                        y: r.minY + (CGFloat(gy) + 0.5) / CGFloat(grid) * r.height)
        guard LiveTracker.contains(visible, p), let d = depth(p), d.isFinite, d > 0.1 else { continue }
        found.append(d)
      }
    }
    guard found.count >= 8 else { return nil }
    found.sort()
    return found[found.count / 2]
  }

  /// Puts it `depth` metres straight ahead of `camera` (measured inside a cut: LiDAR, or ARKit's
  /// points on it), along the lines of sight from that camera, `weight` of the way (`setRange`).
  mutating func setDepth(_ depth: Float, seenBy camera: FrozenCamera, weight: Float) {
    let middle = OutlineMath.centre(world)
    let ahead = -simd_mul(camera.transform.inverse, simd_float4(middle, 1)).z
    guard ahead > 0.05, depth > 0.05, depth.isFinite else { return }
    setRange(simd_distance(middle, camera.position) * depth / ahead, from: camera.position, weight: weight)
  }

  /// Puts it `range` metres from `origin`, along the lines of sight from there (so from there it
  /// looks just the same), `weight` of the way, and at most twice or half as far in one go.
  mutating func setRange(_ range: Float, from origin: simd_float3, weight: Float) {
    let current = simd_distance(OutlineMath.centre(world), origin)
    guard current > 0.05, range > 0.1, range < 10, range.isFinite else { return }
    let f = 1 + (min(max(range / current, 0.5), 2) - 1) * min(max(weight, 0), 1)
    guard abs(f - 1) > 0.002 else { return }
    world = world.map { origin + ($0 - origin) * f }
    if let d = drawn { drawn = d.map { origin + ($0 - origin) * f } }
    if let d = lastChange { lastChange = d.map { $0 * f } }
    moves = moves.map { (t: $0.t, by: $0.by * f) }
    velocity *= f
  }

  /// One frame to the next (`a`, seen by camera `ca` at `ta`; `b`, by `cb` at `tb`): the
  /// outline seen from `ca`, carried on the picture by its own pixels (LiveFlow), laid back in
  /// the world on a plane through its middle as `cb` sees it. The phone's own motion is in the
  /// picture's too and cancels out in the round trip; what's left is the thing's. False when
  /// it couldn't be carried (it's behind the camera, or too little of it could be followed),
  /// or a cut from a later frame already says where it is.
  @discardableResult
  mutating func carry(from a: LiveFlow.Frame, _ ca: FrozenCamera, at ta: CFTimeInterval,
                      to b: LiveFlow.Frame, _ cb: FrozenCamera, at tb: CFTimeInterval) -> Bool {
    guard seen <= ta + 0.001 else { return false }
    let then = placed(at: ta)
    guard let seenFrom = ca.upright(then), let moved = LiveFlow.carry(seenFrom, from: a, to: b) else { return false }
    let plane = cb.withPlane(through: OutlineMath.centre(then))
    let laid = moved.compactMap { plane.onPlane($0) }
    guard laid.count == moved.count else { return false }
    var by = OutlineMath.centre(laid) - OutlineMath.centre(then)
    let dt = Float(tb - ta)
    if still, simd_length(by) < LiveShape.stillFlow * OutlineMath.spread(then) {
      // Still, and the flow says it barely moved: that's the flow's noise. It stays put.
      by = .zero
      velocity *= 0.8
      world = then
    } else {
      if dt > 0.005 { velocity = velocity * 0.5 + by / dt * 0.5 }
      world = laid
    }
    judge()
    seen = tb
    moves.append((t: tb, by: by))
    moves.removeAll { tb - $0.t > 1 }
    return true
  }

  /// What to draw at `now`: eased onto where it is now rather than jumping when a cut lands;
  /// carried along with the thing meanwhile, so the easing never lags its motion. A jump of
  /// more than its own size (something else) is taken at once. A still thing eases slower
  /// (`easeStill`): the phone's motion isn't in this at all, only the thing's.
  mutating func draw(at now: CFTimeInterval) -> [simd_float3] {
    let target = placed(at: now)
    var shown = target
    if let last = drawn, last.count == target.count, now - drawnAt < 0.25 {
      let dt = Float(now - drawnAt)
      let v = !still && simd_length(velocity) >= 0.02 ? velocity : .zero
      let carried = last.map { $0 + v * dt }
      if simd_distance(OutlineMath.centre(carried), OutlineMath.centre(target)) < OutlineMath.spread(target) {
        let k = 1 - exp(-dt / (still ? LiveShape.easeStill : LiveShape.ease))
        let lined = OutlineMath.align(target, to: carried).points
        shown = zip(carried, lined).map { $0 + ($1 - $0) * k }
      }
    }
    drawn = shown
    drawnAt = now
    return shown
  }
}
