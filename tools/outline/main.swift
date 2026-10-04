// The app's outlines (OutlineNode: SceneKit draws them in the world, with the camera image)
// rendered on a Mac, offscreen, as the camera view would draw them: known outlines in front of
// a known camera, and the picture checked where their lines, their insides and the outside are.
// The Simulator has no ARKit, so this is the only place they're drawn before a phone does.
//
//   swiftc -O -o outline tools/outline/main.swift app/modules/lensi-ar/ios/{OutlineNode,OutlineMath}.swift
//   ./outline <out dir>
import AppKit
import Metal
import SceneKit
import simd

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out/outline")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// A phone's camera view: 390 x 844 points, drawn at 2 pixels a point.
let points = CGSize(width: 390, height: 844)
let w = 780, h = 1688
let perPoint: Float = 2
let fovY: CGFloat = 60
let focalPoints = Float(points.height / 2 / tan(fovY * .pi / 360))

let cameraNode = SCNNode()
let camera = SCNCamera()
camera.fieldOfView = fovY
camera.projectionDirection = .vertical
camera.zNear = 0.01
camera.zFar = 100
cameraNode.camera = camera
let scene = SCNScene()
// Mid grey, so a dark halo and a tinted inside both show.
scene.background.contents = NSColor(calibratedWhite: 0.5, alpha: 1)
scene.rootNode.addChildNode(cameraNode)
let eye = OutlineEye(transform: cameraNode.simdTransform, pointsPerMetre: focalPoints, zoom: 1)

/// Where a world point is in the picture (pixels, top-left origin).
func pixel(_ p: simd_float3) -> (x: Int, y: Int) {
  let f = focalPoints * perPoint
  return (Int((Float(w) / 2 + f * p.x / -p.z).rounded()), Int((Float(h) / 2 - f * p.y / -p.z).rounded()))
}

func ring(centre c: simd_float3, radius r: Float, count n: Int = 64) -> [simd_float3] {
  (0..<n).map { i in
    let a = Float(i) / Float(n) * 2 * .pi
    return c + simd_float3(r * cos(a), r * sin(a), 0)
  }
}

let orange = NSColor(srgbRed: 1, green: 0.55, blue: 0.1, alpha: 1)
// A ring 1 m away, and one 3 m away three times bigger (the same size on screen): their lines
// must be the same width on screen. A U whose notch must stay empty.
let near = ring(centre: simd_float3(-0.1, 0.25, -1), radius: 0.08)
let far = ring(centre: simd_float3(-0.3, -0.15, -3), radius: 0.24)
let u: [simd_float3] = [[0.04, 0.12], [0.08, 0.12], [0.08, 0.2], [0.16, 0.2], [0.16, 0.12], [0.2, 0.12], [0.2, 0.28], [0.04, 0.28]]
  .map { simd_float3($0[0], -$0[1] - 0.05, -1) }
for (outline, fill) in [(near, CGFloat(0.16)), (far, CGFloat(0.16)), (u, CGFloat(0.3))] {
  let node = OutlineNode()
  node.style(orange, width: 2.5, stroke: 1, fill: fill)
  node.setOutline(outline, eye: eye)
  scene.rootNode.addChildNode(node)
}

guard let device = MTLCreateSystemDefaultDevice() else {
  print("FAIL outline: no Metal device here")
  exit(1)
}
let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.pointOfView = cameraNode
let image = renderer.snapshot(atTime: 0, with: CGSize(width: w, height: h), antialiasingMode: .multisampling4X)
guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  print("FAIL outline: no picture")
  exit(1)
}
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
try png?.write(to: outDir.appendingPathComponent("outline.png"))

func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
  let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
  return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]))
}
func isLine(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 200 && c.g > 90 && c.g < 190 && c.b < 90 }
func isGrey(_ c: (r: Int, g: Int, b: Int)) -> Bool { abs(c.r - c.g) < 6 && abs(c.g - c.b) < 6 }

var failures: [String] = []
func expect(_ ok: Bool, _ what: String) { if !ok { failures.append(what) } }

/// The line's width across, in pixels, at a ring's right-hand side (scanning along x).
func lineWidth(_ outline: [simd_float3]) -> Int {
  let (x0, y0) = pixel(outline[0])
  return (x0 - 12...x0 + 12).filter { isLine(rgb($0, y0)) }.count
}
// The line is on the outline all the way round.
for (name, outline) in [("near", near), ("far", far)] {
  let on = stride(from: 0, to: outline.count, by: 4).filter { i in
    let (x, y) = pixel(outline[i])
    return (-1...1).contains { dx in (-1...1).contains { dy in isLine(rgb(x + dx, y + dy)) } }
  }.count
  expect(on == outline.count / 4, "\(name) ring: the line is on \(on) of \(outline.count / 4) points")
}
let wn = lineWidth(near), wf = lineWidth(far)
// 2.5 points at 2 pixels a point: 5 pixels, give or take the edges' smoothing.
expect((3...8).contains(wn) && abs(wn - wf) <= 1, "line width on screen: \(wn) px near, \(wf) px far")
// Inside: grey tinted towards orange. Outside: the grey untouched.
let (cx, cy) = pixel(simd_float3(-0.1, 0.25, -1))
let inside = rgb(cx, cy), outside = rgb(w / 2 + 300, 60)
expect(inside.r > inside.g + 8 && inside.g > inside.b + 8 && inside.r < 200, "inside is tinted: \(inside)")
expect(isGrey(outside) && abs(outside.r - 128) < 10, "outside is untouched: \(outside)")
// The U: its arms are filled, its notch isn't.
let arm = rgb(pixel(simd_float3(0.06, -0.25, -1)).x, pixel(simd_float3(0.06, -0.25, -1)).y)
let notch = rgb(pixel(simd_float3(0.12, -0.2, -1)).x, pixel(simd_float3(0.12, -0.2, -1)).y)
expect(arm.r > arm.b + 20, "the U's arm is filled: \(arm)")
expect(isGrey(notch), "the U's notch is empty: \(notch)")
// A dark halo just outside the line (the line still reads on a pale part).
let (hx, hy) = pixel(near[0])
let halo = (hx + 3...hx + 8).map { rgb($0, hy) }.min { $0.r < $1.r }!
expect(halo.r < 120 && isGrey(halo), "a dark halo outside the line: \(halo)")

print(String(format: "outline: line %d px near, %d px far; inside %@, notch %@, halo %@",
             wn, wf, "\(inside)", "\(notch)", "\(halo)"))
if failures.isEmpty {
  print("outline: ok (\(outDir.appendingPathComponent("outline.png").path))")
} else {
  for f in failures { print("FAIL outline: \(f)") }
  exit(1)
}
