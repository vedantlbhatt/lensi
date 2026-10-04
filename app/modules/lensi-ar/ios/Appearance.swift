import CoreGraphics
import CoreImage
import Foundation
import Vision

/// What a followed thing looks like, to tell it from whatever is found where it might be
/// after it's lost or while it may be drifting (so a lock never jumps to the tree behind
/// the player). A few looks are kept, taken while it was tracked well.
///
/// A look is a Vision feature print of just the outlined thing (the rest greyed out); where
/// Vision's models can't run (the Simulator) it's SAM's own features averaged over the
/// outline. Measured on DAVIS 2017 val (tools/livesam), at the cut-off used:
/// Vision keeps 71% of same-object pairs and lets 1% of other videos' objects through;
/// SAM features keep 69% and let 9% through. Distances come out normalized: < 1 = same.
final class AppearanceMemory {
  private struct Look {
    let print: VNFeaturePrintObservation?
    let sam: [Float]?
  }
  private var looks: [Look] = []
  static let limit = 8
  static let visionCut: Float = 0.75
  static let samCut: Float = 0.17

  var isEmpty: Bool { looks.isEmpty }

  func reset() { looks.removeAll() }

  /// Adds a look unless it's a near-duplicate of one already kept.
  func remember(_ image: CIImage, polygon: [CGPoint], sam: [Float]?) {
    let look = AppearanceMemory.look(image, polygon: polygon, sam: sam)
    guard look.print != nil || look.sam != nil else { return }
    if let d = distance(to: look), d < 0.2 { return }
    looks.append(look)
    if looks.count > AppearanceMemory.limit { looks.remove(at: 1) } // the first look stays
  }

  /// Normalized distance (< 1 = the same thing) to the closest kept look; nil when nothing's kept.
  func distance(_ image: CIImage, polygon: [CGPoint], sam: [Float]?) -> Float? {
    distance(to: AppearanceMemory.look(image, polygon: polygon, sam: sam))
  }

  private func distance(to look: Look) -> Float? {
    var best: Float?
    for q in looks {
      var d: Float?
      if let a = look.print, let b = q.print {
        var v: Float = 0
        if (try? a.computeDistance(&v, to: b)) != nil { d = v / AppearanceMemory.visionCut }
      } else if let a = look.sam, let b = q.sam, a.count == b.count {
        d = (1 - zip(a, b).map(*).reduce(0, +)) / AppearanceMemory.samCut
      }
      if let d { best = min(best ?? d, d) }
    }
    return best
  }

  private static func look(_ image: CIImage, polygon: [CGPoint], sam: [Float]?) -> Look {
    Look(print: visionPrint(image, polygon: polygon), sam: sam)
  }

  private static var visionWorks = true

  static func visionPrint(_ image: CIImage, polygon: [CGPoint]) -> VNFeaturePrintObservation? {
    guard visionWorks, let subject = Identify.subject(image, polygon: polygon) else { return nil }
    let request = VNGenerateImageFeaturePrintRequest()
    request.imageCropAndScaleOption = .scaleFit
    do {
      try VNImageRequestHandler(ciImage: subject, options: [:]).perform([request])
    } catch {
      // No feature print model here (the Simulator): stop asking, SAM's features stand in.
      visionWorks = false
      return nil
    }
    return request.results?.first
  }
}
