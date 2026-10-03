import AVFoundation
import QuartzCore
import Speech

/// Push-to-talk recognition, on device when the locale supports it. Emits
/// `{ transcript, isFinal, level }` as partial results arrive and ~15 times a
/// second for the mic level so the UI can breathe with the voice.
///
/// All state lives on the main queue: `start`/`stop` are called there, the
/// recogniser reports there (its default queue), and the audio tap only
/// measures on its own thread before hopping over.
final class SpeechController {
  private let emit: ([String: Any]) -> Void
  /// A fresh engine per session, so a stale input format (after a Bluetooth
  /// handover, or ARKit holding the mic for a video) never reaches installTap.
  private var engine = AVAudioEngine()
  private let recognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var transcript = ""
  private var level: Float = 0
  private var lastLevelEmit: CFTimeInterval = 0
  private var running = false
  /// Bumped per session: a previous task's late final result must not land in the next one.
  private var generation = 0
  /// Activation and deactivation block; keep them ordered and off the main
  /// queue where possible (deactivating while other apps resume is the slow one).
  private let sessionQueue = DispatchQueue(label: "lensi.audio-session")

  init(emit: @escaping ([String: Any]) -> Void) {
    self.emit = emit
  }

  func requestPermission(_ done: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        done(false)
        return
      }
      AVAudioApplication.requestRecordPermission { granted in
        done(granted)
      }
    }
  }

  func start() throws {
    stop()
    guard let recognizer, recognizer.isAvailable else {
      throw LensiError.unavailable("Speech recognition isn't available right now.")
    }
    transcript = ""
    level = 0
    generation += 1
    let gen = generation

    try sessionQueue.sync {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.addsPunctuation = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

    engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // installTap raises (uncatchably) on a 0 Hz / 0 channel format.
    guard format.sampleRate > 0, format.channelCount > 0 else {
      deactivateSession()
      throw LensiError.unavailable("The microphone isn't available right now.")
    }
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      request.append(buffer)
      self?.measure(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      deactivateSession()
      throw error
    }
    self.request = request
    running = true

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self, gen == self.generation else { return }
      if let result {
        self.transcript = result.bestTranscription.formattedString
        self.emit(["transcript": self.transcript, "isFinal": result.isFinal, "level": Double(self.level)])
      }
      if let error, self.running {
        let ns = error as NSError
        // 1110 = no speech detected; 301 = cancelled. Neither is worth a toast.
        if ns.code != 1110 && ns.code != 301 && ns.code != 216 {
          self.emit(["transcript": self.transcript, "isFinal": true, "level": 0, "error": error.localizedDescription])
        }
      }
    }
  }

  func stop() {
    guard running || task != nil else { return }
    running = false
    request?.endAudio()
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    // Let the recogniser deliver its final result, then release it.
    let task = self.task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { task?.cancel() }
    self.task = nil
    request = nil
    deactivateSession()
  }

  private func deactivateSession() {
    sessionQueue.async {
      let session = AVAudioSession.sharedInstance()
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }
  }

  /// Runs on the audio thread: measure here, touch state on main.
  private func measure(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData?[0] else { return }
    let n = Int(buffer.frameLength)
    guard n > 0 else { return }
    var sum: Float = 0
    for i in 0..<n { sum += data[i] * data[i] }
    let rms = sqrt(sum / Float(n))
    // -50 dB → 0, -10 dB → 1
    let db = 20 * log10(max(rms, 1e-6))
    let v = max(0, min(1, (db + 50) / 40))
    DispatchQueue.main.async { [weak self] in
      guard let self, self.running else { return }
      self.level = self.level * 0.6 + v * 0.4
      let now = CACurrentMediaTime()
      guard now - self.lastLevelEmit > 0.066 else { return }
      self.lastLevelEmit = now
      self.emit(["transcript": self.transcript, "isFinal": false, "level": Double(self.level)])
    }
  }
}
