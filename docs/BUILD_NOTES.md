# Build notes (overnight, Oct 3 2026)

A running log of the camera-first rebuild on branch `camera-first`: what exists, what has been verified and how, and what still needs a real iPhone.

## Verification status

| Area | How it was checked | Status |
|---|---|---|
| TS logic (geometry, regions, protocol, links, QR codes, eyes-only engine) | `npm test` (node test runner, 30 tests) | passing |
| App ↔ server protocol | server tests run the real server in mock mode through the app's own parser | passing |
| UI + motion | Expo web preview driven by Playwright (iPhone viewport, real touch events) | camera, capture, walkthrough, voice, memories, settings, drop menu reviewed |
| MobileSAM → Core ML | `tools/sam`: torch vs wrapper (bit-exact decoder), fp16 interpreter, then **real Core ML on macOS CI** (CPU and all compute units) | passing |
| Swift compile (Release, iOS 27 SDK) | `.github/workflows/ios.yml` on the `xcode-27` runner | passing |
| App launch + scripted runs in the iOS 27 Simulator | same job; screenshots, device log, timeline and capture JSON on the `ci-results` branch | launches; Vision OCR, YOLO and SAM (CPU) annotate the demo scenes |
| Eyes on public images (Vision + YOLO + SAM on macOS) | `tools/eyes` in the `sam` job | SAM part outlines on every image; QR payloads read |
| Native crash review | a read-only pass over every Swift file (recording, speech, torch, photo, threading) | 10 issues found and fixed |
| ARKit capture, recording, torch, live pins, speech, Apple Intelligence | need a physical iPhone | not yet run on device |

## Things that need a device

- **Photo:** `ARSession.captureHighResolutionFrame`, falling back to the current frame. The JPEG is written upright (`.oriented(.right)`).
- **Video:** ARKit frames plus session audio are written with `AVAssetWriter`. Audio is requested only while recording (`providesAudioData` is toggled by re-running the configuration).
- **Torch:** `ARConfiguration.configurableCaptureDeviceForPrimaryCamera`.
- **Apple Intelligence:** `IntelligenceBridge.status()` reports why it is unavailable (not eligible, not enabled, still downloading). On iOS 27 the photo is attached with numbered marks drawn on it.
- **Speech:** `SFSpeechRecognizer`, on device when the locale supports it.

## iOS 27: the UIScene life cycle is mandatory

The first simulator run built fine and then never showed the app: the device log said
*"Application failed to launch: UIScene life cycle is required for apps built with this SDK."*
Expo SDK 57 ships `ExpoAppSceneDelegate` and `ExpoReactNativeFactoryProvider` for this, but its
prebuild template still creates the window in the app delegate. `app/plugins/withSceneLifecycle.js`
adds the scene manifest, a `SceneDelegate: ExpoAppSceneDelegate`, and moves window creation out
of `AppDelegate`. Every edit it makes is checked, so if Expo changes the template, prebuild fails
loudly instead of shipping an app that dies at launch. Once Expo's template adopts scenes, delete
the plugin.

Scripted CI runs reach the app through the launch environment
(`SIMCTL_CHILD_LENSI_URL=lensi:///?demo=cars xcrun simctl launch …`, read by the native
`launchURL` constant). `simctl openurl` puts up an "Open in Lensi?" prompt that nothing in CI can
tap.

## What the Simulator runs taught

- **CI's VM can only run Core ML on the CPU** ("On-device compilation within a VM only supports
  CPU"). Our models use `.cpuOnly` in the Simulator (`Detector.computeUnits`) and `.all` on a
  phone. Vision's own foreground-instance mask also fails there, so Simulator captures have no
  subject outline; phones do.
- **Cold start is about 6 s in the VM.** The scripted runs wait for it before their first shot.
- **Scene labels make bad names.** Vision's classifier often leads with "outdoor" or "machine";
  `thingLabel` skips those when naming the subject.

## Decisions

- **The camera is ARKit, not AVFoundation.** Live detection, live pins, photos and video all come from one session, so there is no camera restart when switching modes.
- **Set-of-marks over coordinates for the on-device model.** A ~3B model can't be trusted to output pixel coordinates; it can pick "mark 4". Coordinates come only from Vision and SAM.
- **Fields are emitted only once complete.** Partial `@Generable` snapshots grow token by token, so a title is sent once the model has moved on to the summary. Labels land whole instead of flickering.
- **The print metaphor.** After a capture the photo springs from full-bleed (matching the viewfinder) into a framed print above the card, so nothing the model labels is ever hidden under UI.
- **Fragment Mono for labels.** Its advance is exactly 0.618 em, so label widths are computed, not measured, and the layout is synchronous and collision-free.
