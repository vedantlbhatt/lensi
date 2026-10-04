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
    let fx = intrinsics[0][0], fy = intrinsics[1][1]
    let cx = intrinsics[2][0], cy = intrinsics[2][1]
    var out: [CGPoint] = []
    out.reserveCapacity(world.count)
    for w in world {
      let c = simd_mul(toCamera, simd_float4(w, 1))
      guard c.z < -0.02 else { return nil }
      let px = cx + fx * c.x / -c.z
      let py = cy - fy * c.y / -c.z
      out.append(CGPoint(x: 1 - CGFloat(py) / resolution.height, y: CGFloat(px) / resolution.width))
    }
    return out
  }

  /// An upright picture point laid on the plane (`withPlane`); nil when its ray misses it.
  func onPlane(_ upright: CGPoint) -> simd_float3? {
    let (origin, dir) = ray(upright)
    let denom = simd_dot(dir, planeNormal)
    guard abs(denom) > 1e-4 else { return nil }
    let t = simd_dot(planePoint - origin, planeNormal) / denom
    return t > 0 ? origin + dir * t : nil
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
  /// It follows its thing from frame to frame (a guide part, a tapped thing); the reticle's
  /// is just whatever is in the middle.
  let follows: Bool
  /// How far the flow has carried it, frame by frame (capture times, newest last, the last
  /// second): a SAM cut that lands after the flow has moved on is brought along the same way.
  var moves: [(t: CFTimeInterval, by: simd_float3)] = []
  /// What the last display frame drew, and when.
  var drawn: [simd_float3]?
  var drawnAt: CFTimeInterval = 0

  /// What's drawn eases onto where the outline is in about this long (seconds) instead of
  /// jumping when a cut lands: 60 ms was smoother still but fell 4-8 points of J behind on fast
  /// things (tools/track measured 30, 60 and adaptive).
  static let ease: Float = 0.03

  init(world: [simd_float3], at t: CFTimeInterval, follows: Bool) {
    self.world = world
    seen = t
    cut = t
    self.follows = follows
  }

  /// How fast the thing itself moves, in its own sizes a second (LiveTracker.asking).
  var sizesPerSecond: Float {
    simd_length(velocity) / max(OutlineMath.spread(world), 0.01)
  }

  /// Where it is at `t`: its outline carried along by its own motion (at most 0.3 s ahead).
  func placed(at t: CFTimeInterval) -> [simd_float3] {
    guard simd_length(velocity) >= 0.02 else { return world }
    let dt = Float(min(max(t - seen, 0), 0.3))
    return dt == 0 ? world : world.map { $0 + velocity * dt }
  }

  /// SAM's cut of it, laid in the world from a frame captured at `t`, blended into where it
  /// should be by then: a moving thing is followed, and its edge settles unless it's really
  /// changing shape (OutlineMath.steady). SAM takes a while: if the flow has carried the
  /// outline past `t`, the cut is brought along the same way first.
  mutating func take(_ fresh: [simd_float3], at t: CFTimeInterval, how: OutlineMath.Smoothing = .standard) {
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
    if dt > 0.01 {
      let v = (OutlineMath.centre(next) - OutlineMath.centre(world)) / dt
      velocity = velocity * 0.4 + v * 0.6
    }
    world = next
    seen = at
    cut = t
    misses = 0
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
    let by = OutlineMath.centre(laid) - OutlineMath.centre(then)
    let dt = Float(tb - ta)
    if dt > 0.005 { velocity = velocity * 0.5 + by / dt * 0.5 }
    world = laid
    seen = tb
    moves.append((t: tb, by: by))
    moves.removeAll { tb - $0.t > 1 }
    return true
  }

  /// What to draw at `now`: eased onto where it is now rather than jumping when a cut lands;
  /// carried along with the thing meanwhile, so the easing never lags its motion. A jump of
  /// more than its own size (something else) is taken at once.
  mutating func draw(at now: CFTimeInterval) -> [simd_float3] {
    let target = placed(at: now)
    var shown = target
    if let last = drawn, last.count == target.count, now - drawnAt < 0.25 {
      let dt = Float(now - drawnAt)
      let v = simd_length(velocity) >= 0.02 ? velocity : .zero
      let carried = last.map { $0 + v * dt }
      if simd_distance(OutlineMath.centre(carried), OutlineMath.centre(target)) < OutlineMath.spread(target) {
        let k = 1 - exp(-dt / LiveShape.ease)
        let lined = OutlineMath.align(target, to: carried).points
        shown = zip(carried, lined).map { $0 + ($1 - $0) * k }
      }
    }
    drawn = shown
    drawnAt = now
    return shown
  }
}
