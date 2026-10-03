import ARKit
import ExpoModulesCore

public class LensiARModule: Module {
  public func definition() -> ModuleDefinition {
    Name("LensiAR")

    Constant("isSupported") { ARWorldTrackingConfiguration.isSupported }

    View(LensiARView.self) {
      Events("onSelect", "onFocusChange", "onTrackingChange", "onPinTap")

      Prop("showDetections") { (view: LensiARView, value: Bool) in
        view.showDetections = value
      }

      AsyncFunction("capture") { (view: LensiARView) in
        view.select(at: nil)
      }

      AsyncFunction("setPin") { (view: LensiARView, id: String, title: String, color: String?) in
        view.setPin(id: id, title: title, color: color)
      }

      AsyncFunction("addCallout") { (view: LensiARView, parentId: String, id: String, x: Double, y: Double, text: String) in
        view.addCallout(parentId: parentId, id: id, x: x, y: y, text: text)
      }

      AsyncFunction("removePin") { (view: LensiARView, id: String) in
        view.removePin(id: id)
      }

      AsyncFunction("clearPins") { (view: LensiARView) in
        view.clearPins()
      }
    }
  }
}
