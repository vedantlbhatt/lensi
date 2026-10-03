import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Decides when a watched part has changed and then settled: different from
/// how it looked when watching began (or since the last change), and steady
/// across consecutive samples. A hand passing through is not steady, so it
/// doesn't count; a cap left off, a valve turned or a cover removed does.
///
/// Distances are Vision feature-print distances between crops around the
/// part. The thresholds are a first guess for revision-2 prints and are logged
/// on every sample so they can be tuned on a device.
struct ChangeWatch {
  /// Different enough from the baseline to count as a change.
  static let change: Float = 0.42
  /// Close enough to the previous sample to count as settled.
  static let steady: Float = 0.22
  /// Changed and settled samples in a row before it fires (~1.5 s at 2 Hz).
  static let need = 3
  /// After firing, stay quiet this long so one change is checked once.
  static let cooldown: TimeInterval = 4

  private var baseline: VNFeaturePrintObservation?
  private var previous: VNFeaturePrintObservation?
  private var streak = 0
  private var quietUntil: TimeInterval = 0

  mutating func reset() {
    baseline = nil
    previous = nil
    streak = 0
    quietUntil = 0
  }

  /// The camera moved or the part left the frame: start the streak over.
  mutating func unsettle() {
    previous = nil
    streak = 0
  }

  /// Returns the distance from the baseline when a settled change is found.
  mutating func add(_ fp: VNFeaturePrintObservation, now: TimeInterval) -> Float? {
    defer { previous = fp }
    guard let base = baseline else {
      baseline = fp
      return nil
    }
    let fromBase = Self.distance(fp, base)
    let fromPrevious = previous.map { Self.distance(fp, $0) } ?? .infinity
    NSLog("[lensi] watch base %.2f prev %.2f", fromBase, fromPrevious.isFinite ? fromPrevious : -1)
    if fromBase > Self.change && fromPrevious < Self.steady {
      streak += 1
    } else {
      streak = 0
    }
    guard streak >= Self.need, now >= quietUntil else { return nil }
    streak = 0
    baseline = fp
    quietUntil = now + Self.cooldown
    return fromBase
  }

  private static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
    var d: Float = 0
    do {
      try a.computeDistance(&d, to: b)
    } catch {
      return 0
    }
    return d
  }

  /// A feature print of the square around `point` (upright, 0…1, top-left
  /// origin) in a camera buffer. The square is about 15 cm across at the
  /// part's distance, so it holds the part and a little around it.
  static func featurePrint(_ buffer: CVPixelBuffer, around point: CGPoint, distance: Float, upright: CGSize) -> VNFeaturePrintObservation? {
    guard upright.width > 0, upright.height > 0 else { return nil }
    // A portrait iPhone frame is ~0.93 m wide at 1 m, so 15 cm is ~0.16/d of the width.
    let w = CGFloat(min(0.5, max(0.14, 0.16 / max(distance, 0.15))))
    let h = w * upright.width / upright.height
    // Vision's region of interest is normalized with a bottom-left origin.
    let roi = CGRect(x: point.x - w / 2, y: 1 - (point.y + h / 2), width: w, height: h)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !roi.isNull, roi.width > 0.05, roi.height > 0.05 else { return nil }
    let request = VNGenerateImageFeaturePrintRequest()
    request.regionOfInterest = roi
    request.imageCropAndScaleOption = .scaleFill
    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right)
    do {
      try handler.perform([request])
    } catch {
      return nil
    }
    return request.results?.first
  }
}
