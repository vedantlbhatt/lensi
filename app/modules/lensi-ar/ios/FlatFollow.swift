import CoreGraphics
import Foundation
import simd

/// Pinned things followed on a flat picture: 0.5x, where the ultra-wide runs on its own (no ARKit,
/// so no world to hold them in). EdgeTAM's answers come back late, each about its own frame. Each
/// one is glided into what was shown on that frame (OutlineMath.glide) and brought on to the newest
/// frame, and from one frame to the next every outline is bent with its thing by the picture's own
/// pixels (LiveFlow.bend), whether the phone moved, turned or zoomed or the thing itself moved.
/// Where the flow can't say (a blur, nothing to grip) `turn` moves it by how the phone turned
/// meanwhile (the gyro), which is all 0.5x had between answers before.
///
/// Upright 0…1 points throughout, frames by capture time. Only the frames still needed are kept:
/// the newest, and every one since the look an answer is still due for (`looking`), up to `maxFrames`.
///
/// tools/edgetrack plays the bottle video through it as the phone's camera (EdgeTAMVideo does the
/// same in the Simulator), and tools/walk runs it on handheld walk-arounds against the gyro alone.
final class FlatFollower {
  /// What's shown of one thing, as of the frame captured at `at`, and what was shown on recent
  /// frames: the next answer is glided into what was shown on its own frame.
  struct Thing {
    var shown: [CGPoint]
    var at: CFTimeInterval
    var history: [(t: CFTimeInterval, outline: [CGPoint])]
    /// Answers in a row that didn't find it.
    var misses = 0
  }

  /// Bent with its thing (LiveFlow.bend); false: moved whole (LiveFlow.carry).
  var bends = true
  var bending: LiveFlow.Bending = .standard
  /// Each answer glided into what was shown on its frame (OutlineMath.glide); false (the app): taken
  /// as it is. On the bottle, with `pinsEdges`, taken as it is was IoU 0.963 against 0.957, and no
  /// wobblier (3.07 px against 3.08).
  var glides = false
  /// Upright points seen at one capture time, moved to where they'd be seen at a later one by how
  /// the phone turned meanwhile (UltraWideCamera.warp). Nil: there's no gyro, and where the flow
  /// can't say, an outline stays where it is.
  var turn: ((_ points: [CGPoint], _ from: CFTimeInterval, _ to: CFTimeInterval) -> [CGPoint])?
  /// Whether the gyro moves outlines from one capture time to the next rather than the flow (the
  /// phone turned fast: the picture's a blur). Nil: the flow always tries first.
  var gyroFirst: ((_ from: CFTimeInterval, _ to: CFTimeInterval) -> Bool)?
  /// The flow starts looking where `turn` says each point went (LiveFlow's prior), rather than
  /// where it was: a fast turn is a long way for it to find on its own.
  var guided = false
  /// A thing that runs off the picture is outlined only up to its edge; moved with the thing, that
  /// side would come away from the edge and leave the rest of it outside the outline. Its points
  /// on the picture's edge stay on it, sliding along it with the thing (`pinned`). On the bottle's
  /// close-up its outline was 71% to 93% of the bottle's area without; overall IoU 0.954 -> 0.957,
  /// worst frame 0.69 -> 0.77, frames under 0.9 33 -> 25, shake 3.5 -> 3.2 px.
  var pinsEdges = true
  /// How near the picture's edge (0…1) a point counts as on it.
  static let edge: CGFloat = 0.006

  private(set) var things: [String: Thing] = [:]
  private var frames: [(t: CFTimeInterval, frame: LiveFlow.Frame?)] = []
  /// The capture time of the frame an answer is still due for.
  private var due: CFTimeInterval?
  /// How many of a thing's recent outlines are kept (an answer is due within a few frames).
  static let historyLength = 24
  /// At most this many frames are kept (a few MB each): an answer later than that is turned on
  /// to the oldest by the gyro, and bent on from there.
  static let maxFrames = 8
  /// Answers in a row that don't find a thing before it's let go: one look that misses it (small,
  /// a blur, half behind something) doesn't make it blink out. Followed by the flow meanwhile.
  static let maxMisses = 3

  /// The newest frame's capture time.
  var newest: CFTimeInterval? { frames.last?.t }

  /// The next frame (nil: it couldn't be read, and the gyro moves outlines across it): every
  /// outline is bent on to it.
  func add(_ frame: LiveFlow.Frame?, at t: CFTimeInterval) {
    if let last = frames.last, t <= last.t { return }
    let previous = frames.last
    for (key, var thing) in things where t > thing.at {
      if let previous, abs(previous.t - thing.at) < 1e-4 {
        thing.shown = step(thing.shown, from: previous, to: (t, frame))
      } else {
        thing.shown = turn?(thing.shown, thing.at, t) ?? thing.shown
      }
      thing.at = t
      remember(&thing)
      things[key] = thing
    }
    frames.append((t, frame))
    trim()
  }

  /// A look started on the frame captured at `t`: frames from it on are kept until it's answered.
  func looking(at t: CFTimeInterval) {
    due = t
    trim()
  }

  /// EdgeTAM's answers about the frame captured at `t`, each upright 0…1 (OutlineMath.count
  /// points) or nil where it isn't in view (after `maxMisses` of those in a row it's let go until
  /// it's found again). `size`: the picture in pixels, which `glide` works in. Things not named are
  /// left as they are.
  func answer(_ found: [String: [CGPoint]?], at t: CFTimeInterval, size: CGSize) {
    defer {
      if let d = due, d <= t + 1e-4 { due = nil }
      trim()
    }
    for (key, said) in found {
      guard let outline = said, outline.count >= 3 else {
        if var thing = things[key], thing.misses + 1 < FlatFollower.maxMisses {
          thing.misses += 1
          things[key] = thing
        } else {
          things[key] = nil
        }
        continue
      }
      var glided = outline
      if glides, let last = shown(key, at: t), last.count == outline.count {
        let w = Float(size.width), h = Float(size.height)
        let px = { (p: CGPoint) in simd_float3(Float(p.x) * w, Float(p.y) * h, 0) }
        glided = OutlineMath.glide(last.map(px), outline.map(px)).map { CGPoint(x: CGFloat($0.x / w), y: CGFloat($0.y / h)) }
      }
      settle(key, glided, at: t)
    }
  }

  /// A thing found on the frame captured at `t` (the strip's, a second or so before it's pinned):
  /// brought on to the newest frame and followed from there.
  func place(_ key: String, _ outline: [CGPoint], at t: CFTimeInterval) {
    guard outline.count >= 3 else { return }
    settle(key, outline, at: t)
    trim()
  }

  /// Only these are followed from now on.
  func keep(_ keys: Set<String>) {
    for key in things.keys where !keys.contains(key) { things[key] = nil }
  }

  func reset() {
    things = [:]
    frames = []
    due = nil
  }

  /// `outline`, as of the frame captured at `t`, brought on to the newest frame and shown.
  private func settle(_ key: String, _ outline: [CGPoint], at t: CFTimeInterval) {
    let (now, at) = bring(outline, from: t)
    var thing = things[key] ?? Thing(shown: now, at: at, history: [])
    thing.shown = now
    thing.at = at
    thing.misses = 0
    // What's shown on the newest frame is this now.
    thing.history.removeAll { $0.t >= at - 1e-4 }
    remember(&thing)
    things[key] = thing
  }

  private func remember(_ thing: inout Thing) {
    thing.history.append((thing.at, thing.shown))
    if thing.history.count > FlatFollower.historyLength { thing.history.removeFirst(thing.history.count - FlatFollower.historyLength) }
  }

  /// What was shown of `key` on the frame captured at `t` (the last shown before it, turned on to it).
  private func shown(_ key: String, at t: CFTimeInterval) -> [CGPoint]? {
    guard let thing = things[key], let before = thing.history.last(where: { $0.t <= t + 1e-4 }) else { return nil }
    return before.t < t - 1e-4 ? turn?(before.outline, before.t, t) ?? before.outline : before.outline
  }

  /// `outline`, as of capture time `t`, frame by frame on to the newest (turned across a gap the
  /// frames don't cover), and the time it's then as of.
  private func bring(_ outline: [CGPoint], from t: CFTimeInterval) -> ([CGPoint], CFTimeInterval) {
    var now = outline
    var at = t
    var previous = frames.last(where: { abs($0.t - t) < 1e-4 })
    for f in frames where f.t > t + 1e-4 {
      if let p = previous {
        now = step(now, from: p, to: f)
      } else {
        now = turn?(now, at, f.t) ?? now
      }
      previous = f
      at = f.t
    }
    return (now, at)
  }

  /// One frame to the next: bent with its thing, or turned where the flow can't say.
  private func step(_ outline: [CGPoint], from a: (t: CFTimeInterval, frame: LiveFlow.Frame?),
                    to b: (t: CFTimeInterval, frame: LiveFlow.Frame?)) -> [CGPoint] {
    if gyroFirst?(a.t, b.t) != true, let fa = a.frame, let fb = b.frame {
      var predict: (([CGPoint]) -> [CGPoint])?
      if guided, let turn { predict = { turn($0, a.t, b.t) } }
      if let moved = bends ? LiveFlow.bend(outline, from: fa, to: fb, bending, predict: predict)
        : LiveFlow.carry(outline, from: fa, to: fb, predict: predict) {
        return pinsEdges ? FlatFollower.pinned(moved, was: outline) : moved
      }
    }
    let turned = turn?(outline, a.t, b.t) ?? outline
    return pinsEdges ? FlatFollower.pinned(turned, was: outline) : turned
  }

  /// `moved` (the outline `was`, moved on) with the points that were on the picture's edge put back
  /// on it, and none past it.
  static func pinned(_ moved: [CGPoint], was: [CGPoint]) -> [CGPoint] {
    guard moved.count == was.count else { return moved }
    return zip(moved, was).map { m, w in
      var p = m
      if w.x <= edge { p.x = w.x } else if w.x >= 1 - edge { p.x = w.x }
      if w.y <= edge { p.y = w.y } else if w.y >= 1 - edge { p.y = w.y }
      p.x = min(max(p.x, 0), 1)
      p.y = min(max(p.y, 0), 1)
      return p
    }
  }

  /// Frames no answer can still need: all but the newest, and those since the look still due.
  private func trim() {
    guard frames.count > 1 else { return }
    let from = min(due ?? .infinity, frames[frames.count - 1].t)
    let keepFrom = max(frames.lastIndex(where: { $0.t <= from + 1e-4 }) ?? 0, frames.count - FlatFollower.maxFrames)
    if keepFrom > 0 { frames.removeFirst(keepFrom) }
  }
}
