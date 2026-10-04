import SceneKit
import UIKit
import simd

extension UIColor {
  convenience init(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.hasPrefix("#") { s.removeFirst() }
    var v: UInt64 = 0
    Scanner(string: s).scanHexInt64(&v)
    self.init(
      red: CGFloat((v >> 16) & 0xFF) / 255,
      green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255,
      alpha: 1
    )
  }
}

/// The tag that sits on an anchored point. Title only: the detail lives in the
/// app's sheet so the camera view stays readable.
final class PinLabel: UIView {
  /// Live guide: the current step's part stands out; the others step back.
  enum Emphasis { case normal, focused, dimmed }

  private let label = UILabel()
  /// Live guide, the part out of view: an arrow on the tag points the way to it.
  private let arrow = UIImageView(image: UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .heavy)))
  var color: UIColor { didSet { apply() } }
  var emphasis: Emphasis = .normal { didSet { if emphasis != oldValue { apply() } } }
  let isCallout: Bool
  /// SceneKit draws this tag (TagNode, from `picture()`), with its thing's outline in the camera's
  /// own frame: the view stays where the tag is, for taps, but shows nothing.
  var drawnElsewhere = false { didSet { if drawnElsewhere != oldValue { apply() } } }
  /// How opaque the view is when nothing's animating it.
  private var restingAlpha: CGFloat { drawnElsewhere ? 0 : emphasis == .dimmed ? 0.55 : 1 }

  /// Screen-space direction to the part, in radians (0 = right, π/2 = down);
  /// nil while the part is in view.
  var pointing: CGFloat? {
    didSet {
      if (pointing == nil) != (oldValue == nil) { sizeToFitContent() }
      if let a = pointing { arrow.transform = CGAffineTransform(rotationAngle: a + .pi / 2) }
    }
  }

  init(text: String, color: UIColor, isCallout: Bool) {
    self.color = color
    self.isCallout = isCallout
    super.init(frame: .zero)
    layer.cornerRadius = isCallout ? 7 : 10
    layer.cornerCurve = .continuous
    layer.shadowColor = UIColor.black.cgColor
    layer.shadowOpacity = 0.3
    layer.shadowRadius = 8
    layer.shadowOffset = CGSize(width: 0, height: 3)
    label.font = isCallout ? UIFont.systemFont(ofSize: 13, weight: .semibold) : UIFont.systemFont(ofSize: 16, weight: .bold)
    label.text = text
    addSubview(label)
    arrow.tintColor = .black
    arrow.contentMode = .center
    arrow.isHidden = true
    addSubview(arrow)
    apply()
  }

  required init?(coder: NSCoder) { fatalError() }

  /// Titles sit on the lens pen; callouts are white tags (the focused one on
  /// the pen). Text is always black.
  private func apply() {
    backgroundColor = !isCallout || emphasis == .focused ? color : .white
    label.textColor = .black
    alpha = restingAlpha
  }

  /// Room around `picture()` for the tag's shadow.
  static let pictureMargin: CGFloat = 12

  /// The tag as a picture, its shadow included (`pictureMargin` all round), as it looks on screen.
  func picture() -> UIImage {
    let m = PinLabel.pictureMargin
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let size = CGSize(width: bounds.width + 2 * m, height: bounds.height + 2 * m)
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      let cg = ctx.cgContext
      let pill = UIBezierPath(roundedRect: CGRect(x: m, y: m, width: bounds.width, height: bounds.height), cornerRadius: layer.cornerRadius)
      cg.saveGState()
      cg.setShadow(offset: layer.shadowOffset, blur: layer.shadowRadius,
                   color: UIColor.black.withAlphaComponent(CGFloat(layer.shadowOpacity)).cgColor)
      (backgroundColor ?? color).setFill()
      pill.fill()
      cg.restoreGState()
      let style = NSMutableParagraphStyle()
      style.lineBreakMode = .byTruncatingTail
      let text = NSAttributedString(string: label.text ?? "", attributes: [
        .font: label.font ?? UIFont.systemFont(ofSize: 16, weight: .bold),
        .foregroundColor: label.textColor ?? UIColor.black,
        .paragraphStyle: style,
      ])
      let line = text.size().height
      text.draw(with: CGRect(x: m + label.frame.minX, y: m + (bounds.height - line) / 2, width: label.frame.width, height: line + 2),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }
  }

  var text: String {
    get { label.text ?? "" }
    set {
      label.text = newValue
      UIView.transition(with: label, duration: 0.18, options: .transitionCrossDissolve) {}
      sizeToFitContent()
    }
  }

  func sizeToFitContent() {
    let pad: CGFloat = isCallout ? 9 : 12
    let size = label.sizeThatFits(CGSize(width: 220, height: 40))
    let w = min(size.width, 220)
    let h: CGFloat = isCallout ? 26 : 32
    // Room for the arrow ahead of the name while it points off screen.
    let lead: CGFloat = pointing == nil ? 0 : 17
    bounds = CGRect(x: 0, y: 0, width: w + pad * 2 + lead, height: h)
    arrow.isHidden = pointing == nil
    arrow.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
    arrow.center = CGPoint(x: pad + 6, y: h / 2)
    label.frame = CGRect(x: pad + lead, y: 0, width: w, height: h)
  }
}

/// A world-anchored annotation: a tag on the thing, and its outline when it has one.
final class Pin {
  let id: String
  let parentId: String?
  let world: simd_float3
  let label: PinLabel
  let dot = CALayer()
  let line = CAShapeLayer()
  /// Segmentation outline captured at creation, in view space.
  var outline: CAShapeLayer?
  /// Live guide: the part's shape laid in the world, and the layer that draws
  /// it (only while its step is up).
  var guideOutline: [simd_float3] = []
  var guideShape: OutlineNode?
  /// A pinned thing's tag as SceneKit draws it, with its outline (TagNode).
  var tagNode: TagNode?
  var outlineScreenOrigin: CGPoint = .zero
  var outlineDistance: Float = 1
  /// The zoom it was drawn at; it scales with the zoom from there.
  var outlineZoom: CGFloat = 1
  var side: CGFloat = 1

  init(id: String, parentId: String?, world: simd_float3, text: String, color: UIColor) {
    self.id = id
    self.parentId = parentId
    self.world = world
    label = PinLabel(text: text, color: color, isCallout: parentId != nil)
    label.sizeToFitContent()

    let r: CGFloat = parentId == nil ? 6 : 4.5
    dot.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
    dot.cornerRadius = r
    dot.backgroundColor = (parentId == nil ? color : UIColor.white).cgColor
    dot.borderColor = UIColor.white.cgColor
    dot.borderWidth = parentId == nil ? 2 : 0

    line.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
    line.lineWidth = 1.5
    line.fillColor = nil
  }

  func setColor(_ color: UIColor) {
    label.color = color
    if parentId == nil { dot.backgroundColor = color.cgColor }
    outline?.strokeColor = color.cgColor
    outline?.fillColor = color.withAlphaComponent(0.18).cgColor
  }

  func setHidden(_ hidden: Bool) {
    label.isHidden = hidden
    dot.isHidden = hidden
    line.isHidden = hidden
    outline?.isHidden = hidden
    if hidden {
      guideShape?.isHidden = true
      tagNode?.isHidden = true
    }
  }

  func removeFromSuperview() {
    label.removeFromSuperview()
    dot.removeFromSuperlayer()
    line.removeFromSuperlayer()
    outline?.removeFromSuperlayer()
    guideShape?.removeFromParentNode()
    tagNode?.removeFromParentNode()
  }

  /// Fades in from slightly small and stops: no spring, no overshoot.
  func popIn() {
    guard !label.drawnElsewhere else { return }
    label.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
    label.alpha = 0
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.label.transform = .identity
      self.label.alpha = 1
    }
  }
}

/// A pinned thing's tag, drawn by SceneKit like its outline (OutlineNode), so the two move as one
/// with the camera image however fast the phone moves: a picture of the tag (PinLabel.picture),
/// facing the camera, the same size on screen at any distance. The UIKit tag stays where it is,
/// for taps, and shows nothing.
final class TagNode: SCNNode {
  private let plane = SCNPlane(width: 0.1, height: 0.04)
  /// What the picture shows (text, colour, size): it's redrawn only when that changes.
  private var drawnFor = ""
  private var size = CGSize.zero

  override init() {
    super.init()
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.isDoubleSided = true
    m.readsFromDepthBuffer = false
    m.writesToDepthBuffer = false
    m.blendMode = .alpha
    plane.materials = [m]
    geometry = plane
    // Over the outlines.
    renderingOrder = 2_000
    let facing = SCNBillboardConstraint()
    facing.freeAxes = .all
    constraints = [facing]
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  /// Shows `label` as it looks now.
  func show(_ label: PinLabel) {
    let key = "\(label.text)|\(label.color.description)|\(label.bounds.width)x\(label.bounds.height)"
    guard key != drawnFor else { return }
    drawnFor = key
    let picture = label.picture()
    plane.firstMaterial?.diffuse.contents = picture
    size = picture.size
  }

  /// Its middle at `world`, its size on screen the picture's, as `eye` sees it.
  func place(at world: simd_float3, eye: OutlineEye) {
    simdPosition = world
    plane.width = CGFloat(eye.metres(Float(size.width), at: world))
    plane.height = CGFloat(eye.metres(Float(size.height), at: world))
  }
}
