import ARKit
import ExpoModulesCore
import UIKit

/// Room the app's chrome takes above and below the camera, in points.
struct PinInsets: Record {
  @Field var top: Double = 0
  @Field var bottom: Double = 0
}

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

    // The native code this build was made from (tools/ota/runtime.py, put in the Info.plist by
    // plugins/withOTA.js): over-the-air JavaScript is only for the same.
    Constant("runtime") { Bundle.main.object(forInfoDictionaryKey: "LensiRuntime") as? String }

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

    // MARK: Following a thing through a video (EdgeTAM)

    // The app's EdgeTAMTracker on a video file with the models it ships: pinned with `box`
    // (x0, y0, x1, y1: fractions of the picture) on the first frame, followed through every
    // `every`-th after (EdgeTAMVideo); with `render`, the clip written again with it drawn on.
    AsyncFunction("trackVideo") { (uri: String, box: [Double], every: Int, render: String?, color: String?, promise: Promise) in
      guard box.count == 4, box.allSatisfy({ $0.isFinite }) else {
        promise.reject("E_TRACK", "Bad box.")
        return
      }
      let url: URL? = uri.hasPrefix("file:") ? URL(string: uri) : URL(fileURLWithPath: uri)
      guard let url else {
        promise.reject("E_TRACK", "Bad file.")
        return
      }
      // Where to write the clip with what it followed drawn on it (none: no video).
      var film: URL?
      if let render, !render.isEmpty {
        film = render.hasPrefix("file:") ? URL(string: render) : URL(fileURLWithPath: render)
      }
      let pen = UIColor(hex: color ?? "#FFFFFF")
      let rect = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          promise.resolve(try EdgeTAMVideo.track(url: url, box: rect, every: every, render: film, color: pen))
        } catch {
          promise.reject("E_TRACK", error.localizedDescription)
        }
      }
    }

    // MARK: Brain: Apple Intelligence (Foundation Models)

    AsyncFunction("intelligenceStatus") { () -> [String: Any] in
      IntelligenceBridge.status()
    }

    AsyncFunction("intelligencePrewarm") {
      IntelligenceBridge.prewarm()
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

    // A hands-free job has no touches for minutes: keep the screen from locking.
    AsyncFunction("setKeepAwake") { (on: Bool) in
      UIApplication.shared.isIdleTimerDisabled = on
    }.runOnQueue(.main)

    // MARK: The camera

    View(LensiARView.self) {
      Events("onSelect", "onFocusChange", "onTrackingChange", "onPinTap", "onGuideChange", "onZoomRange")

      Prop("showDetections") { (view: LensiARView, value: Bool) in
        view.showDetections = value
      }

      Prop("liveSegments") { (view: LensiARView, value: Bool) in
        view.liveSegments = value
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

      Prop("pinInsets") { (view: LensiARView, value: PinInsets?) in
        view.pinInsets = UIEdgeInsets(top: value?.top ?? 0, left: 0, bottom: value?.bottom ?? 0, right: 0)
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

      AsyncFunction("guideCapture") { (view: LensiARView, promise: Promise) in
        view.guideCapture { result in
          switch result {
          case .success(let frame): promise.resolve(frame)
          case .failure(let error): promise.reject("E_GUIDE", error.localizedDescription)
          }
        }
      }.runOnQueue(.main)

      AsyncFunction("guideOutline") { (view: LensiARView, frameId: String, id: String, points: [Double]) in
        view.guideOutline(frameId: frameId, id: id, points: points)
      }.runOnQueue(.main)

      AsyncFunction("guidePin") { (view: LensiARView, frameId: String, id: String, x: Double, y: Double, label: String) in
        view.guidePin(frameId: frameId, id: id, x: x, y: y, label: label)
      }.runOnQueue(.main)

      AsyncFunction("guideFocus") { (view: LensiARView, id: String?) in
        view.guideFocus(id)
      }.runOnQueue(.main)

      AsyncFunction("guideWatch") { (view: LensiARView, id: String?) in
        view.guideWatch(id)
      }.runOnQueue(.main)

      AsyncFunction("guideClear") { (view: LensiARView) in
        view.guideClear()
      }.runOnQueue(.main)

      AsyncFunction("setZoom") { (view: LensiARView, zoom: Double) in
        view.setZoom(zoom)
      }.runOnQueue(.main)

      // The strip: slide to pick, hold to pin.
      AsyncFunction("scrubStart") { (view: LensiARView, top: Double, bottom: Double, promise: Promise) in
        view.scrubStart(top: top, bottom: bottom) { things in promise.resolve(things) }
      }.runOnQueue(.main)

      AsyncFunction("scrubTo") { (view: LensiARView, index: Int) in
        view.scrubTo(index)
      }.runOnQueue(.main)

      AsyncFunction("scrubPin") { (view: LensiARView, index: Int) -> String? in
        view.scrubPin(index)
      }.runOnQueue(.main)

      AsyncFunction("scrubEnd") { (view: LensiARView) in
        view.scrubEnd()
      }.runOnQueue(.main)

      AsyncFunction("scrubClear") { (view: LensiARView) in
        view.scrubClear()
      }.runOnQueue(.main)
    }

    // The virtual camera's footage, with what's pinned in it outlined in the same display frame
    // as the picture (DemoVideoView). Not the default view: requireNativeView('LensiAR', 'DemoVideoView').
    View(DemoVideoView.self) {
      Events("onFrame")

      Prop("source") { (view: DemoVideoView, uri: String) in
        view.setSource(uri)
      }

      Prop("tracks") { (view: DemoVideoView, json: String) in
        view.setTracks(json)
      }

      Prop("pins") { (view: DemoVideoView, pins: [DemoPin]) in
        view.setPins(pins)
      }

      Prop("highlight") { (view: DemoVideoView, pin: DemoPin?) in
        view.setHighlight(pin?.track ?? -1, color: pin?.color ?? "#ffffff")
      }
    }
  }
}
