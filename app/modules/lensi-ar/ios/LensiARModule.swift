import ARKit
import ExpoModulesCore

public class LensiARModule: Module {
  private let analyzer = Analyzer()
  private lazy var speech = SpeechController { [weak self] body in
    self?.sendEvent("onSpeech", body)
  }

  public func definition() -> ModuleDefinition {
    Name("LensiAR")

    Events("onIntelligence", "onSpeech")

    Constant("isSupported") { ARWorldTrackingConfiguration.isSupported }

    // A scripted run (CI) can hand the app a lensi:// URL through the launch
    // environment (`SIMCTL_CHILD_LENSI_URL=…`), which skips the system's
    // "Open in Lensi?" prompt that `simctl openurl` can raise.
    Constant("launchURL") { ProcessInfo.processInfo.environment["LENSI_URL"] }

    // MARK: Eyes: Vision + YOLO (+ SAM) on a still image

    AsyncFunction("analyze") { (uri: String, promise: Promise) in
      self.analyzer.queue.async {
        do {
          promise.resolve(try self.analyzer.analyze(uri: uri))
        } catch {
          promise.reject("E_ANALYZE", error.localizedDescription)
        }
      }
    }

    AsyncFunction("segment") { (uri: String, x: Double, y: Double, promise: Promise) in
      // Int(NaN) traps; a bad tap from JS must not take the app down.
      guard x.isFinite, y.isFinite else {
        promise.reject("E_SEGMENT", "Bad point.")
        return
      }
      let point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
      self.analyzer.queue.async {
        do {
          promise.resolve(try self.analyzer.segment(uri: uri, at: point))
        } catch {
          promise.reject("E_SEGMENT", error.localizedDescription)
        }
      }
    }

    // MARK: Brain: Apple Intelligence (Foundation Models)

    AsyncFunction("intelligenceStatus") { () -> [String: Any] in
      IntelligenceBridge.status()
    }

    AsyncFunction("intelligenceStart") { (requestId: String, request: String) in
      try IntelligenceBridge.start(requestId: requestId, json: request) { [weak self] body in
        self?.sendEvent("onIntelligence", body)
      }
    }

    // Async on purpose: it queues behind intelligenceStart (same serial queue),
    // so a quick cancel can't arrive first and miss the task it was meant for.
    AsyncFunction("intelligenceCancel") { (requestId: String) in
      IntelligenceBridge.cancel(requestId: requestId)
    }

    // MARK: Ears: on-device speech recognition

    AsyncFunction("speechRequestPermission") { (promise: Promise) in
      self.speech.requestPermission { granted in promise.resolve(granted) }
    }

    AsyncFunction("speechStart") { (promise: Promise) in
      DispatchQueue.main.async {
        do {
          try self.speech.start()
          promise.resolve(nil)
        } catch {
          promise.reject("E_SPEECH", error.localizedDescription)
        }
      }
    }

    AsyncFunction("speechStop") { (promise: Promise) in
      DispatchQueue.main.async {
        self.speech.stop()
        promise.resolve(nil)
      }
    }

    // MARK: The camera

    View(LensiARView.self) {
      Events("onSelect", "onFocusChange", "onTrackingChange", "onPinTap")

      Prop("showDetections") { (view: LensiARView, value: Bool) in
        view.showDetections = value
      }

      Prop("livePins") { (view: LensiARView, value: Bool) in
        view.livePins = value
      }

      Prop("accentColor") { (view: LensiARView, value: String?) in
        view.accent = value.map { UIColor(hex: $0) } ?? .white
      }

      Prop("paused") { (view: LensiARView, value: Bool) in
        view.setPaused(value)
      }

      AsyncFunction("capture") { (view: LensiARView) in
        view.select(at: nil)
      }.runOnQueue(.main)

      AsyncFunction("takePhoto") { (view: LensiARView, promise: Promise) in
        view.takePhoto { result in
          switch result {
          case .success(let photo): promise.resolve(photo)
          case .failure(let error): promise.reject("E_PHOTO", error.localizedDescription)
          }
        }
      }.runOnQueue(.main)

      AsyncFunction("startRecording") { (view: LensiARView, promise: Promise) in
        view.startRecording { error in
          if let error {
            promise.reject("E_RECORD", error.localizedDescription)
          } else {
            promise.resolve(nil)
          }
        }
      }.runOnQueue(.main)

      AsyncFunction("stopRecording") { (view: LensiARView, promise: Promise) in
        view.stopRecording { result in
          switch result {
          case .success(let video): promise.resolve(video)
          case .failure(let error): promise.reject("E_RECORD", error.localizedDescription)
          }
        }
      }.runOnQueue(.main)

      AsyncFunction("setTorch") { (view: LensiARView, on: Bool) -> Bool in
        view.setTorch(on)
      }.runOnQueue(.main)

      AsyncFunction("setPin") { (view: LensiARView, id: String, title: String, color: String?) in
        view.setPin(id: id, title: title, color: color)
      }.runOnQueue(.main)

      AsyncFunction("addCallout") { (view: LensiARView, parentId: String, id: String, x: Double, y: Double, text: String) in
        view.addCallout(parentId: parentId, id: id, x: x, y: y, text: text)
      }.runOnQueue(.main)

      AsyncFunction("removePin") { (view: LensiARView, id: String) in
        view.removePin(id: id)
      }.runOnQueue(.main)

      AsyncFunction("clearPins") { (view: LensiARView) in
        view.clearPins()
      }.runOnQueue(.main)
    }
  }
}
