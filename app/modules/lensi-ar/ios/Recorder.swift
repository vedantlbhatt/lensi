import AVFoundation
import CoreVideo

/// Writes ARKit's camera frames (and, when allowed, the session's audio) to an
/// H.264 .mov. Frames arrive in sensor (landscape) orientation; the track is
/// tagged with a 90° transform so it plays upright.
final class Recorder {
  let url: URL
  /// Upright output size (portrait).
  let size: CGSize
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let audio: AVAssetWriterInput?
  private var startTime: CMTime?
  private var lastTime: CMTime = .zero
  private var finished = false
  /// The writer refused to start; never call it again (a second startWriting raises).
  private var failed = false
  private let lock = NSLock()

  init(url: URL, sensorWidth: Int, sensorHeight: Int, withAudio: Bool) throws {
    self.url = url
    size = CGSize(width: sensorHeight, height: sensorWidth)
    try? FileManager.default.removeItem(at: url)
    writer = try AVAssetWriter(outputURL: url, fileType: .mov)

    let bitrate = max(6_000_000, sensorWidth * sensorHeight * 4)
    video = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: sensorWidth,
      AVVideoHeightKey: sensorHeight,
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ])
    video.expectsMediaDataInRealTime = true
    video.transform = CGAffineTransform(rotationAngle: .pi / 2)
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
    guard writer.canAdd(video) else { throw LensiError.unavailable("Can't record video on this device.") }
    writer.add(video)

    if withAudio {
      let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: 96_000,
      ])
      a.expectsMediaDataInRealTime = true
      if writer.canAdd(a) {
        writer.add(a)
        audio = a
      } else {
        audio = nil
      }
    } else {
      audio = nil
    }
  }

  /// `time` is the ARFrame timestamp (seconds on the host clock).
  func append(pixelBuffer: CVPixelBuffer, time: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished, !failed else { return }
    let t = CMTime(seconds: time, preferredTimescale: 600_000)
    if startTime == nil {
      // startWriting() is only legal once, while the status is still .unknown.
      guard writer.status == .unknown, writer.startWriting() else {
        failed = true
        NSLog("[lensi] recorder could not start: %@", writer.error?.localizedDescription ?? "unknown")
        return
      }
      writer.startSession(atSourceTime: t)
      startTime = t
    }
    guard writer.status == .writing else {
      failed = true
      return
    }
    guard video.isReadyForMoreMediaData else { return }
    if adaptor.append(pixelBuffer, withPresentationTime: t) { lastTime = t }
  }

  func append(audio buffer: CMSampleBuffer) {
    lock.lock()
    defer { lock.unlock() }
    guard !finished, let audio, let start = startTime, writer.status == .writing else { return }
    guard CMSampleBufferGetPresentationTimeStamp(buffer) >= start, audio.isReadyForMoreMediaData else { return }
    audio.append(buffer)
  }

  func finish(_ done: @escaping (Result<(URL, Double), Error>) -> Void) {
    lock.lock()
    finished = true
    let start = startTime
    let last = lastTime
    lock.unlock()
    // Needs a started session with at least two frames in it; otherwise there's
    // nothing worth keeping (and endSession before startSession would raise).
    guard let start, writer.status == .writing, last > start else {
      if writer.status == .writing { writer.cancelWriting() }
      try? FileManager.default.removeItem(at: url)
      done(.failure(writer.error ?? LensiError.unavailable("Nothing was recorded.")))
      return
    }
    video.markAsFinished()
    audio?.markAsFinished()
    writer.endSession(atSourceTime: last)
    writer.finishWriting { [writer, url] in
      if writer.status == .completed {
        done(.success((url, max(0, (last - start).seconds))))
      } else {
        done(.failure(writer.error ?? LensiError.unavailable("Recording failed.")))
      }
    }
  }
}
