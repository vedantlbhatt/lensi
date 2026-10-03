# Build notes (overnight, Oct 3 2026)

A running log of the camera-first rebuild on branch `camera-first`: what exists, what has been verified and how, and what still needs a real iPhone.

## Verification status

| Area | How it was checked | Status |
|---|---|---|
| TS logic (geometry, regions, protocol, links, QR codes, colours, eyes-only engine) | `npm test` (node test runner, 38 tests) | passing |
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
  `thingLabel` skips those when naming the subject. The list is in Vision's own form
  (`night_sky`) while the phone sends `night sky`, so labels are normalised before the check
  (a circuit board was once titled "Night sky").
- **The detector guesses at slivers.** A car roof cut off by the frame's edge came back as a
  "bottle"; small boxes touching the edge no longer get names.
- **Vision's subject mask doesn't run in the VM**, so CI captures had no outline. When it
  returns nothing, SAM is prompted with the detector's best box instead (also helps phones
  on photos without a clear foreground).
- **Build one architecture.** A generic Simulator destination compiled every file for arm64
  and x86_64 (3,837 objects each). And ccache ran but wrote to its default directory,
  because Xcode doesn't pass `CCACHE_DIR` to the compiler; CI now caches that directory.
- **`launchctl list` lies while recording.** It reported the app gone while it was on screen;
  liveness is now checked by the launched PID (Simulator apps are host processes).

## The Release crash: a colour printed as `9.4e-7`

Some capture screens aborted in the Simulator's Release build (SIGABRT from a worklet, no JS
stack). In Release, an uncaught JS error on Reanimated's UI runtime is fatal. `BlurText` animates
each word's colour every frame and built `rgba(…, ${a})` from a float; as a word settles its
alpha drops below 1e-6 and JavaScript prints it in exponent form, which Reanimated's colour parser
rejects by throwing. It hit the capture title about a second after it landed, every walkthrough
step, and the listening overlay. `lib/color.ts` now builds every animated colour with the alpha
clamped and rounded to three decimals, and a test pins the exponent case. Run 6 confirmed it: every
scenario, the board and export ones included, ran to the end with no crash report.

To catch the next one: CI launches the app with `simctl launch --stdout/--stderr`, because
libc++abi prints an uncaught error's message there and nowhere else. Those paths must be
absolute: the launched process opens them inside the Simulator, a relative path lands on a
read-only volume, and the launch itself fails (run 5 never got the app running).

## Decisions

- **The camera is ARKit, not AVFoundation.** Live detection, live pins, photos and video all come from one session, so there is no camera restart when switching modes.
- **Set-of-marks over coordinates for the on-device model.** A ~3B model can't be trusted to output pixel coordinates; it can pick "mark 4". Coordinates come only from Vision and SAM.
- **Fields are emitted only once complete.** Partial `@Generable` snapshots grow token by token, so a title is sent once the model has moved on to the summary. Labels land whole instead of flickering.
- **The print metaphor.** After a capture the photo springs from full-bleed (matching the viewfinder) into a framed print above the card, so nothing the model labels is ever hidden under UI.
- **Fragment Mono for labels.** Its advance is exactly 0.618 em, so label widths are computed, not measured, and the layout is synchronous and collision-free.
