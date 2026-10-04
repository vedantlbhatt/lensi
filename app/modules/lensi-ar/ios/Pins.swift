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
    alpha = emphasis == .dimmed ? 0.55 : 1
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
  var guideShape: CAShapeLayer?
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
    if hidden { guideShape?.isHidden = true }
  }

  func removeFromSuperview() {
    label.removeFromSuperview()
    dot.removeFromSuperlayer()
    line.removeFromSuperlayer()
    outline?.removeFromSuperlayer()
    guideShape?.removeFromSuperlayer()
  }

  /// Fades in from slightly small and stops: no spring, no overshoot.
  func popIn() {
    label.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
    label.alpha = 0
    UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
      self.label.transform = .identity
      self.label.alpha = 1
    }
  }
}
