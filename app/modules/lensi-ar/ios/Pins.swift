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

/// How the camera view sees the world this frame, for drawing outlines in it: where the eye
/// is, and how many points on screen one metre across makes one metre away (a lens's focal
/// length in points), so a line can be the same width on screen at any distance.
struct OutlineEye {
  let position: simd_float3
  let toCamera: simd_float4x4
  let pointsPerMetre: Float
  /// The camera view's zoom (a transform on the whole view, outlines included).
  let zoom: Float

  init(transform: simd_float4x4, pointsPerMetre: Float, zoom: Float) {
    position = simd_make_float3(transform.columns.3)
    toCamera = transform.inverse
    self.pointsPerMetre = pointsPerMetre
    self.zoom = max(zoom, 0.01)
  }

  /// How many metres across `points` on screen are at world point `p`.
  func metres(_ points: Float, at p: simd_float3) -> Float {
    let depth = max(-simd_mul(toCamera, simd_float4(p, 1)).z, 0.05)
    return points / zoom * depth / max(pointsPerMetre, 1)
  }
}

/// A part's outline, drawn by SceneKit in the camera view's own render, in the world: it's on
/// its thing in the very frame the camera image shows, however fast the phone moves. (Drawn as
/// UIKit layers over the camera view, outlines were a frame early or late whenever the two drew
/// in turn, and slid about as the phone moved.) A faint fill, a dark halo so the outline still
/// reads where the part is as pale as the line (a white outline on a white door), and the line
/// on top, the same width on screen at any distance.
final class OutlineNode: SCNNode {
  private let fillNode = SCNNode()
  private let haloNode = SCNNode()
  private let lineNode = SCNNode()
  private let fillMaterial = OutlineNode.material()
  private let haloMaterial = OutlineNode.material()
  private let lineMaterial = OutlineNode.material()
  private var width: Float = 1.5

  override init() {
    super.init()
    // Over the camera image in this order, whatever else is in the scene.
    for (node, order) in [(fillNode, 1_000), (haloNode, 1_001), (lineNode, 1_002)] {
      node.renderingOrder = order
      addChildNode(node)
    }
    haloMaterial.diffuse.contents = UIColor.black
    haloMaterial.transparency = 0.32
    style(.white, width: 1.5, stroke: 0.75, fill: 0.07)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  private static func material() -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.isDoubleSided = true
    m.readsFromDepthBuffer = false
    m.writesToDepthBuffer = false
    m.blendMode = .alpha
    return m
  }

  /// The current step's part in the lens colour; the rest thin and white. `width` is the
  /// line's on screen, in points; `stroke` and `fill` how opaque the line and the inside are.
  func style(_ color: UIColor, width: CGFloat, stroke: CGFloat, fill: CGFloat) {
    self.width = Float(width)
    lineMaterial.diffuse.contents = color
    lineMaterial.transparency = stroke
    fillMaterial.diffuse.contents = color
    fillMaterial.transparency = fill
    fillNode.isHidden = fill <= 0.001
  }

  /// Draws the closed ring `world` (points in the world) as `eye` sees it.
  func setOutline(_ world: [simd_float3], eye: OutlineEye) {
    guard world.count >= 3 else {
      fillNode.geometry = nil
      haloNode.geometry = nil
      lineNode.geometry = nil
      return
    }
    let halo = world.map { eye.metres(width + 2.5, at: $0) }
    let line = world.map { eye.metres(width, at: $0) }
    haloNode.geometry = OutlineNode.band(world, widths: halo, eye: eye.position, material: haloMaterial)
    lineNode.geometry = OutlineNode.band(world, widths: line, eye: eye.position, material: lineMaterial)
    fillNode.geometry = fillNode.isHidden ? nil : OutlineNode.inside(world, material: fillMaterial)
  }

  /// A band along the closed ring, `widths[i]` across at point i (metres), turned to face the eye.
  private static func band(_ ring: [simd_float3], widths: [Float], eye: simd_float3, material: SCNMaterial) -> SCNGeometry {
    let n = ring.count
    var vertices: [SCNVector3] = []
    vertices.reserveCapacity(2 * n)
    for i in 0..<n {
      let p = ring[i]
      let before = p - ring[(i + n - 1) % n], after = ring[(i + 1) % n] - p
      let lb = simd_length(before), la = simd_length(after)
      var along = (lb > 1e-7 ? before / lb : .zero) + (la > 1e-7 ? after / la : .zero)
      let l = simd_length(along)
      along = l > 1e-6 ? along / l : (la > 1e-7 ? after / la : simd_float3(1, 0, 0))
      var across = simd_cross(along, eye - p)
      let c = simd_length(across)
      across = c > 1e-9 ? across / c : simd_float3(0, 1, 0)
      // Mitred at a corner, but never more than twice as wide.
      let miter: Float = la > 1e-7 ? 1 / max(simd_dot(along, after / la), 0.5) : 1
      let h = widths[i] * 0.5 * miter
      vertices.append(SCNVector3(p + across * h))
      vertices.append(SCNVector3(p - across * h))
    }
    var indices: [UInt16] = []
    indices.reserveCapacity(6 * n)
    for i in 0..<n {
      let j = (i + 1) % n
      let a = UInt16(2 * i), b = UInt16(2 * i + 1), c = UInt16(2 * j), d = UInt16(2 * j + 1)
      indices += [a, b, c, b, d, c]
    }
    let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)],
                        elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    g.materials = [material]
    return g
  }

  /// The inside of the ring, in triangles (ear clipping, flat in the ring's own plane).
  private static func inside(_ ring: [simd_float3], material: SCNMaterial) -> SCNGeometry? {
    let n = ring.count
    // Newell's normal: the ring's plane, facing the way it winds.
    var normal = simd_float3.zero
    for i in 0..<n {
      let a = ring[i], b = ring[(i + 1) % n]
      normal.x += (a.y - b.y) * (a.z + b.z)
      normal.y += (a.z - b.z) * (a.x + b.x)
      normal.z += (a.x - b.x) * (a.y + b.y)
    }
    let length = simd_length(normal)
    guard length > 1e-12 else { return nil }
    normal /= length
    let other: simd_float3 = abs(normal.x) < 0.9 ? simd_float3(1, 0, 0) : simd_float3(0, 1, 0)
    let u = simd_normalize(simd_cross(normal, other)), v = simd_cross(normal, u)
    let middle = ring.reduce(simd_float3.zero, +) / Float(n)
    let flat = ring.map { SIMD2<Float>(simd_dot($0 - middle, u), simd_dot($0 - middle, v)) }
    let triangles = OutlineMath.triangulate(flat)
    guard !triangles.isEmpty else { return nil }
    let g = SCNGeometry(sources: [SCNGeometrySource(vertices: ring.map { SCNVector3($0) })],
                        elements: [SCNGeometryElement(indices: triangles.map { UInt16($0) }, primitiveType: .triangles)])
    g.materials = [material]
    return g
  }

  /// Fades out, then goes.
  func retire() {
    removeAllActions()
    runAction(.sequence([.fadeOut(duration: 0.2), .removeFromParentNode()]))
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
    guideShape?.removeFromParentNode()
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
