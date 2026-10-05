import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import UIKit
import simd

/// The app's EdgeTAMTracker on a video file: pinned with a box on its first frame and followed
/// through every `every`-th frame after, with the models the app ships (LensiARModels). It's what
/// tools/edgetrack does on CI's Mac with the models loose; in the app it shows the models load
/// and follow from the app's own bundle (a scripted run's `edgetam=`, in the Simulator on its CPU).
/// The clip is taken as stored (upright), as CI's are.
///
/// Each outline is glided into the last as the phone draws a pinned thing on a flat picture
/// (OutlineMath.glide, in pixels, as at 0.5x); frames between steps keep the last. What's drawn
/// comes back as the virtual camera's tracks (`tracks`, tools/strip/pack.py's format), and with
/// `render` the app also writes the clip with it drawn on every frame, as the phone draws it.
///
/// `every` 0 plays the clip as the phone's camera instead (tools/edgetrack's EDGETRACK_LIVE_MS):
/// a look starts on a frame only once the last answer is in and 50 ms after the last start (the
/// app's limit), each answer is ready `latency` seconds after its frame and drawn from the first
/// frame after that, and between answers the outline is bent with the thing by the picture's own
/// pixels: FlatFollower, as the app follows a pinned thing at 0.5x (where the phone also has the
/// gyro for when the flow can't say).
enum EdgeTAMVideo {
  /// How long an answer is assumed to take on a phone (`every` 0).
  static let latency: Double = 0.06

  static func track(url: URL, box: CGRect, every: Int, render: URL? = nil, color: UIColor = .white) throws -> [String: Any] {
    let started = CFAbsoluteTimeGetCurrent()
    guard let models = EdgeTAMTracker.Models.shared else { throw EdgeTAMError.noModels }
    let loadMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { throw EdgeTAMError.badImage }
    let rate = Double(track.nominalFrameRate)
    let fps = rate > 0 ? rate : 15
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? EdgeTAMError.badImage }
    let encoder = try EdgeTAMTracker.Encoder(models: models)
    let tracker = try EdgeTAMTracker(models: models)
    let live = every == 0
    let step = max(1, every)
    var film: Film?
    // Live: the answer on its way and when the last look started; the outline followed as the app
    // follows a pinned thing at 0.5x (FlatFollower: each answer glided into what was shown on its
    // frame, bent with the thing by the picture's own pixels between answers).
    var pending: (t: Double, ready: Double, cut: EdgeTAMTracker.Cut)?
    var lastStart = -Double.infinity
    let follower = FlatFollower()
    let flowContext = CIContext(options: [.cacheIntermediates: false])
    var frames: [[String: Any]] = []
    var times: [Double] = []
    var seen = 0
    var index = 0
    var size = CGSize.zero
    // What's drawn: in pixels while it's followed, nil while it isn't in view.
    var shown: [simd_float3]?
    var packed: [UInt16] = []
    while let sample = output.copyNextSampleBuffer() {
      defer { index += 1 }
      guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
      let picture = CIImage(cvPixelBuffer: buffer)
      if index == 0 {
        size = picture.extent.size
        if let render { film = try Film(url: render, size: size) }
      }
      if live {
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        let scale = CGFloat(LiveFlow.width) / max(size.width, 1)
        let small = picture.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        follower.add(flowContext.createCGImage(small, from: small.extent).flatMap { LiveFlow.frame($0) }, at: t)
        let px = { (p: CGPoint) in simd_float3(Float(p.x * size.width), Float(p.y * size.height), 0) }
        if let p = pending, p.ready <= t + 1e-6 {
          pending = nil
          follower.answer(["": p.cut.visible ? OutlineMath.resample(p.cut.outline, scale: size) : nil], at: p.t, size: size)
        }
        if index == 0 || (pending == nil && t - lastStart > 0.05) {
          let t0 = CFAbsoluteTimeGetCurrent()
          let encoded = try encoder.encode(picture)
          let cut = try index == 0 ? tracker.start(encoded, box: box) : tracker.step(encoded)
          let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
          times.append(ms)
          if cut.visible { seen += 1 }
          frames.append([
            "frame": index, "score": Double(cut.score), "area": Double(cut.area), "ms": ms,
            "outline": (cut.visible ? OutlineMath.resample(cut.outline, count: 32) : []).flatMap { [Double($0.x), Double($0.y)] },
          ])
          lastStart = t
          if index == 0 {
            // Pinned on this frame: the strip's outline is there at once.
            if cut.visible { follower.place("", OutlineMath.resample(cut.outline, scale: size), at: t) }
          } else {
            pending = (t, t + latency, cut)
            follower.looking(at: t)
          }
        }
        shown = follower.things[""].map { $0.shown.map(px) }
      } else if index % step == 0 {
        let t0 = CFAbsoluteTimeGetCurrent()
        let encoded = try encoder.encode(picture)
        let cut = try frames.isEmpty ? tracker.start(encoded, box: box) : tracker.step(encoded)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        times.append(ms)
        if cut.visible {
          seen += 1
          let ring = OutlineMath.resample(cut.outline, scale: size).map {
            simd_float3(Float($0.x * size.width), Float($0.y * size.height), 0)
          }
          shown = OutlineMath.glide(shown, ring)
        } else {
          shown = nil
        }
        let ring = cut.visible ? OutlineMath.resample(cut.outline, count: 32) : []
        frames.append([
          "frame": index,
          "score": Double(cut.score),
          "area": Double(cut.area),
          "ms": ms,
          "outline": ring.flatMap { [Double($0.x), Double($0.y)] },
        ])
      }
      // This frame's outline as fractions of the picture (none: not in view).
      let drawn: [CGPoint]? = shown.map { ring in
        ring.map { CGPoint(x: CGFloat($0.x) / size.width, y: CGFloat($0.y) / size.height) }
      }
      // The tracks keep OutlineMath.count points a frame; all zeros where nothing's drawn.
      if let drawn, drawn.count == OutlineMath.count {
        for p in drawn {
          packed.append(UInt16((min(max(p.x, 0), 1) * 65535).rounded()))
          packed.append(UInt16((min(max(p.y, 0), 1) * 65535).rounded()))
        }
      } else {
        packed.append(contentsOf: [UInt16](repeating: 0, count: OutlineMath.count * 2))
      }
      try film?.add(picture, outline: drawn, color: color, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }
    if reader.status == .failed { throw reader.error ?? EdgeTAMError.badImage }
    try film?.finish()
    let sorted = times.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    NSLog("[lensi] EdgeTAM in the app: followed in %ld of %ld frames (every %ld), median %.0f ms a frame, models loaded in %.0f ms",
          seen, frames.count, step, median, loadMs)
    let data = packed.withUnsafeBufferPointer { words -> Data in
      var bytes = Data(capacity: words.count * 2)
      for w in words {
        bytes.append(UInt8(w & 0xFF))
        bytes.append(UInt8(w >> 8))
      }
      return bytes
    }
    let thing: [String: Any] = ["label": NSNull(), "start": 0, "data": data.base64EncodedString()]
    let tracks: [String: Any] = [
      "clip": url.deletingPathExtension().lastPathComponent,
      "fps": fps,
      "frames": index,
      "size": [Double(size.width), Double(size.height)],
      "every": 1,
      "points": OutlineMath.count,
      "things": [thing],
    ]
    var result: [String: Any] = [
      "frames": frames, "seen": seen, "count": frames.count, "every": live ? 0 : step, "medianMs": median, "loadMs": loadMs,
      "tracks": tracks,
    ]
    if let render { result["video"] = render.path }
    return result
  }

  /// The clip written again with what was followed drawn on it, as the phone draws a pinned
  /// thing (OutlineNode's look: a faint fill, a dark halo, the line), at twice its size.
  private final class Film {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let size: CGSize
    let scale: CGFloat = 2
    let context = CIContext()
    var startedAt: CMTime?

    init(url: URL, size: CGSize) throws {
      try? FileManager.default.removeItem(at: url)
      writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
      self.size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
      input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(self.size.width),
        AVVideoHeightKey: Int(self.size.height),
      ])
      input.expectsMediaDataInRealTime = false
      adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(self.size.width),
        kCVPixelBufferHeightKey as String: Int(self.size.height),
      ])
      guard writer.canAdd(input) else { throw EdgeTAMError.badImage }
      writer.add(input)
      guard writer.startWriting() else { throw writer.error ?? EdgeTAMError.badImage }
    }

    func add(_ picture: CIImage, outline: [CGPoint]?, color: UIColor, at time: CMTime) throws {
      if startedAt == nil {
        writer.startSession(atSourceTime: time)
        startedAt = time
      }
      guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? EdgeTAMError.badImage }
      var made: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
      guard let out = made else { throw EdgeTAMError.badImage }
      let sx = size.width / picture.extent.width, sy = size.height / picture.extent.height
      context.render(picture.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: out)
      CVPixelBufferLockBaseAddress(out, [])
      if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out), width: Int(size.width), height: Int(size.height),
                             bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
        // Top-left origin, as the outline's fractions are.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        if let outline, outline.count >= 3 {
          let path = OutlineMath.curvePath(outline.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) })
          let width = 2.5 * scale
          ctx.setLineJoin(.round)
          ctx.setLineCap(.round)
          ctx.addPath(path)
          ctx.setFillColor(color.withAlphaComponent(0.1).cgColor)
          ctx.fillPath()
          ctx.addPath(path)
          ctx.setStrokeColor(UIColor(white: 0, alpha: 0.32).cgColor)
          ctx.setLineWidth(width + 3 * scale)
          ctx.strokePath()
          ctx.addPath(path)
          ctx.setStrokeColor(color.cgColor)
          ctx.setLineWidth(width)
          ctx.strokePath()
        }
      }
      CVPixelBufferUnlockBaseAddress(out, [])
      while !input.isReadyForMoreMediaData {
        if writer.status == .failed { throw writer.error ?? EdgeTAMError.badImage }
        Thread.sleep(forTimeInterval: 0.005)
      }
      guard adaptor.append(out, withPresentationTime: time) else { throw writer.error ?? EdgeTAMError.badImage }
    }

    func finish() throws {
      input.markAsFinished()
      let done = DispatchSemaphore(value: 0)
      writer.finishWriting { done.signal() }
      done.wait()
      if writer.status != .completed { throw writer.error ?? EdgeTAMError.badImage }
    }
  }
}
