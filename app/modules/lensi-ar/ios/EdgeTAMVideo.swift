import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// The app's EdgeTAMTracker on a video file: pinned with a box on its first frame and followed
/// through every `every`-th frame after, with the models the app ships (LensiARModels). It's what
/// tools/edgetrack does on CI's Mac with the models loose; in the app it shows the models load
/// and follow from the app's own bundle (a scripted run's `edgetam=`, in the Simulator on its CPU).
/// The clip is taken as stored (upright), as CI's are.
enum EdgeTAMVideo {
  static func track(url: URL, box: CGRect, every: Int) throws -> [String: Any] {
    let started = CFAbsoluteTimeGetCurrent()
    guard let models = EdgeTAMTracker.Models.shared else { throw EdgeTAMError.noModels }
    let loadMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else { throw EdgeTAMError.badImage }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? EdgeTAMError.badImage }
    let encoder = try EdgeTAMTracker.Encoder(models: models)
    let tracker = try EdgeTAMTracker(models: models)
    var frames: [[String: Any]] = []
    var times: [Double] = []
    var seen = 0
    var index = 0
    while let sample = output.copyNextSampleBuffer() {
      defer { index += 1 }
      guard index % max(1, every) == 0, let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
      let picture = CIImage(cvPixelBuffer: buffer)
      let t0 = CFAbsoluteTimeGetCurrent()
      let encoded = try encoder.encode(picture)
      let cut = try frames.isEmpty ? tracker.start(encoded, box: box) : tracker.step(encoded)
      let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
      times.append(ms)
      if cut.visible { seen += 1 }
      let ring = cut.visible ? OutlineMath.resample(cut.outline, count: 32) : []
      frames.append([
        "frame": index,
        "score": Double(cut.score),
        "area": Double(cut.area),
        "ms": ms,
        "outline": ring.flatMap { [Double($0.x), Double($0.y)] },
      ])
    }
    let sorted = times.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    NSLog("[lensi] EdgeTAM in the app: followed in %ld of %ld frames (every %ld), median %.0f ms a frame, models loaded in %.0f ms",
          seen, frames.count, every, median, loadMs)
    return ["frames": frames, "seen": seen, "count": frames.count, "every": every, "medianMs": median, "loadMs": loadMs]
  }
}
