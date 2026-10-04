import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Names what a live outline is around, on device: Vision's image classifier
/// (1,300+ labels, a few ms on the Neural Engine) on just the outlined thing,
/// with everything outside the outline greyed out. YOLO only knows 80 classes
/// and names nothing outside them; this names the swan, the drill, the valve.
enum Identify {
  /// Scene words: true of the backdrop, never the name of the thing.
  private static let scenery: Set<String> = ["outdoor", "indoor", "land", "structure", "sky", "grass", "liquid", "water", "underwater"]

  /// `image`: upright. `polygon`: the outline, normalized to `image` (top-left origin).
  static func label(_ image: CIImage, polygon: [CGPoint]) -> (name: String, confidence: Float)? {
    guard let subject = subject(image, polygon: polygon) else { return nil }
    let request = VNClassifyImageRequest()
    do {
      try VNImageRequestHandler(ciImage: subject, options: [:]).perform([request])
    } catch {
      return nil
    }
    return pick(request.results ?? [])
  }

  /// Just the outlined thing: its box (+8%), everything outside the outline mid-grey,
  /// moved to the origin (Vision reads a CIImage from there).
  static func subject(_ image: CIImage, polygon: [CGPoint]) -> CIImage? {
    let e = image.extent
    guard polygon.count >= 3, e.width > 0, e.height > 0 else { return nil }
    // Pixels, Core Image's bottom-left origin.
    let pts = polygon.map { CGPoint(x: e.minX + $0.x * e.width, y: e.minY + (1 - $0.y) * e.height) }
    var box = Poly.bounds(pts)
    box = box.insetBy(dx: -box.width * 0.08, dy: -box.height * 0.08).intersection(e).integral
    guard box.width >= 16, box.height >= 16 else { return nil }
    // The outline as a mask, at most 256 px across (it only has to cover the thing).
    let s = min(1, 256 / max(box.width, box.height))
    let mw = max(1, Int(box.width * s)), mh = max(1, Int(box.height * s))
    guard let ctx = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.scaleBy(x: s, y: s)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.addLines(between: pts)
    ctx.closePath()
    ctx.fillPath()
    guard let maskImage = ctx.makeImage() else { return nil }
    let mask = CIImage(cgImage: maskImage)
      .transformed(by: CGAffineTransform(scaleX: box.width / CGFloat(mw), y: box.height / CGFloat(mh)))
      .transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
      .applyingGaussianBlur(sigma: 2)
      .cropped(to: box)
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: box)
    return image.cropped(to: box).applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: grey, kCIInputMaskImageKey: mask,
    ]).transformed(by: CGAffineTransform(translationX: -box.minX, y: -box.minY))
  }

  /// The most specific label among the near-best: Vision scores a label and its parents
  /// alike ("animal 0.92, bird 0.92, swan 0.92") and lists the specific one last.
  static func pick(_ results: [VNClassificationObservation]) -> (name: String, confidence: Float)? {
    let useful = results.filter { $0.confidence >= 0.25 && !scenery.contains($0.identifier) }
    guard let top = useful.first?.confidence else { return nil }
    guard let best = useful.filter({ $0.confidence >= top - 0.03 }).last else { return nil }
    return (best.identifier.replacingOccurrences(of: "_", with: " "), best.confidence)
  }
}
