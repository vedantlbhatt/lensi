import AVFoundation
import ExpoModulesCore
import UIKit

/// A pinned thing on the virtual camera's footage (the Simulator has no camera): which of the
/// clip's tracked things, in what colour, under what name.
struct DemoPin: Record {
  @Field var track: Int = -1
  @Field var color: String = "#ffffff"
  @Field var label: String = ""
}

/// A demo scene's footage for the virtual camera, with the things pinned in it outlined in the
/// same display frame as the picture they're on. Drawn from JavaScript, an outline came a few
/// frames after the picture it belonged to whenever the Simulator was busy, and sat beside a thing
/// that moved fast (a handheld clip); here each display frame asks the player which video frame is
/// about to be shown and draws that frame's outline, as the phone's own outlines are drawn with
/// the camera image. The tracks are tools/strip/pack.py's (and tools/edgetam/pack.py's) packed
/// outlines, frame by frame; the view is sized by JavaScript to where the footage is on screen.
final class DemoVideoView: ExpoView {
  let onFrame = EventDispatcher()

  private let player = AVQueuePlayer()
  private var looper: AVPlayerLooper?
  private let playerLayer = AVPlayerLayer()
  private var link: CADisplayLink?
  private var source = ""
  private var fps: Double = 15
  private var frameCount = 0
  private var points = 0
  private var things: [(start: Int, words: [UInt16])] = []
  private var pins: [DemoPin] = []
  private var highlight = -1
  private var highlightColor = UIColor.white
  private var outlines: [String: FlatOutline] = [:]
  private var tags: [Int: PinLabel] = [:]
  private var shownFrame = -1
  private var reportedFrame = -1

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = false
    player.isMuted = true
    playerLayer.player = player
    // JavaScript sizes this view to the footage's place on screen, so the picture fills it.
    playerLayer.videoGravity = .resize
    layer.addSublayer(playerLayer)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    CATransaction.commit()
    shownFrame = -1
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      if link == nil {
        let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
      }
      player.play()
    } else {
      link?.invalidate()
      link = nil
      player.pause()
    }
  }

  // MARK: - Props

  func setSource(_ uri: String) {
    guard uri != source, !uri.isEmpty else { return }
    source = uri
    let found: URL? = uri.hasPrefix("/") ? URL(fileURLWithPath: uri) : URL(string: uri)
    guard let url = found else { return }
    player.removeAllItems()
    looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
    if window != nil { player.play() }
  }

  /// The clip's packed tracks, as JSON: fps, frames, points, things[].start and .data (base64 of
  /// little-endian uint16 x,y pairs, 0-65535 across the picture).
  func setTracks(_ json: String) {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    fps = (obj["fps"] as? NSNumber)?.doubleValue ?? 15
    frameCount = (obj["frames"] as? NSNumber)?.intValue ?? 0
    points = (obj["points"] as? NSNumber)?.intValue ?? 0
    things = ((obj["things"] as? [[String: Any]]) ?? []).map { t in
      let start = (t["start"] as? NSNumber)?.intValue ?? 0
      let bytes = (t["data"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
      var words = [UInt16](repeating: 0, count: bytes.count / 2)
      bytes.withUnsafeBytes { raw in
        for i in 0..<words.count { words[i] = UInt16(raw[2 * i]) | UInt16(raw[2 * i + 1]) << 8 }
      }
      return (start: start, words: words)
    }
    shownFrame = -1
  }

  func setPins(_ list: [DemoPin]) {
    pins = list
    let keep = Set(list.map(\.track))
    for (track, tag) in tags where !keep.contains(track) {
      tag.removeFromSuperview()
      tags[track] = nil
    }
    for pin in list {
      let color = UIColor(hex: pin.color)
      if let tag = tags[pin.track] {
        if tag.text != pin.label { tag.text = pin.label }
        tag.color = color
      } else {
        let tag = PinLabel(text: pin.label, color: color, isCallout: false)
        tag.sizeToFitContent()
        tag.isHidden = true
        addSubview(tag)
        tags[pin.track] = tag
      }
    }
    shownFrame = -1
  }

  func setHighlight(_ track: Int, color: String) {
    highlight = track
    highlightColor = UIColor(hex: color)
    shownFrame = -1
  }

  // MARK: - Drawing

  /// Each display frame: the video frame the player is about to show, and that frame's outlines.
  @objc private func tick(_ link: CADisplayLink) {
    guard frameCount > 0, let item = player.currentItem else { return }
    var t = CMTimeGetSeconds(item.currentTime())
    guard t.isFinite else { return }
    // Where it will be when this display frame is on screen.
    if player.rate > 0 { t += max(0, link.targetTimestamp - CACurrentMediaTime()) * Double(player.rate) }
    let f = min(frameCount - 1, max(0, Int(t * fps)))
    if f != reportedFrame {
      reportedFrame = f
      onFrame(["frame": f])
    }
    guard f != shownFrame else { return }
    shownFrame = f
    draw(frame: f)
  }

  private func outline(_ track: Int, at f: Int) -> [CGPoint]? {
    guard things.indices.contains(track), points > 0 else { return nil }
    let thing = things[track]
    guard f >= thing.start else { return nil }
    let at = (f - thing.start) * points * 2
    guard at + points * 2 <= thing.words.count else { return nil }
    // All zeros: not in view at that frame (EdgeTAMVideo's tracks).
    guard thing.words[at..<(at + points * 2)].contains(where: { $0 != 0 }) else { return nil }
    let w = bounds.width, h = bounds.height
    return (0..<points).map { k in
      CGPoint(x: CGFloat(thing.words[at + 2 * k]) / 65535 * w, y: CGFloat(thing.words[at + 2 * k + 1]) / 65535 * h)
    }
  }

  private func draw(frame f: Int) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    var drawn = Set<String>()
    func stroke(_ key: String, _ pts: [CGPoint], _ color: UIColor, fill: CGFloat) {
      let flat: FlatOutline
      if let existing = outlines[key] {
        flat = existing
      } else {
        flat = FlatOutline()
        layer.insertSublayer(flat, above: playerLayer)
        outlines[key] = flat
      }
      flat.frame = bounds
      let path = CGMutablePath()
      path.addLines(between: pts)
      path.closeSubpath()
      flat.draw(path, color: color.cgColor, width: 2.5, fillOpacity: fill)
      flat.isHidden = false
      drawn.insert(key)
    }
    // The strip's highlighted thing, while a finger is on it (not one that's pinned).
    if highlight >= 0, !pins.contains(where: { $0.track == highlight }), let pts = outline(highlight, at: f) {
      stroke("highlight", pts, highlightColor, fill: 0.16)
    }
    for pin in pins {
      guard let pts = outline(pin.track, at: f) else {
        tags[pin.track]?.isHidden = true
        continue
      }
      stroke("pin-\(pin.track)", pts, UIColor(hex: pin.color), fill: 0.1)
      // Its tag just above it, as the phone places a pinned thing's.
      if let tag = tags[pin.track] {
        let box = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let half = tag.bounds.width / 2 + 8
        let screen = window?.bounds ?? bounds
        // Kept on screen: this view can be bigger than the screen (the footage covers it).
        let origin = convert(CGPoint.zero, to: window)
        let minX = -origin.x + half, maxX = -origin.x + screen.width - half
        let top = max(box.minY - tag.bounds.height / 2 - 6, -origin.y + 60 + tag.bounds.height / 2)
        tag.center = CGPoint(x: min(max(box.midX, minX), max(minX, maxX)), y: top)
        tag.isHidden = false
      }
    }
    for (key, flat) in outlines where !drawn.contains(key) { flat.isHidden = true }
  }
}
