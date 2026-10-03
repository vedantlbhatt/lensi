# Build notes (overnight, Oct 3 2026)

A running log of the camera-first rebuild on branch `camera-first`: what exists, what has been verified and how, and what still needs a real iPhone.

## Verification status

| Area | How it was checked | Status |
|---|---|---|
| TS logic (geometry, regions, protocol) | `npm test` (node test runner) | passing |
| App ↔ server protocol | server tests run the real server in mock mode through the app's own parser | passing |
| UI + motion | Expo web preview driven by Playwright (iPhone viewport, real touch events) | camera, capture, walkthrough, voice, memories, settings, drop menu reviewed |
| MobileSAM → Core ML | `tools/sam`: torch vs wrapper (bit-exact decoder), fp16 interpreter, then **real Core ML on macOS CI** (CPU and all compute units) | passing |
| Swift compile + Simulator run | `.github/workflows/ios.yml` on the `xcode-27` runner | see `ci-results` branch |
| ARKit capture, recording, torch, live pins, speech, Apple Intelligence | need a physical iPhone | not yet run on device |

## Things that need a device

- **Photo:** `ARSession.captureHighResolutionFrame`, falling back to the current frame. The JPEG is written upright (`.oriented(.right)`).
- **Video:** ARKit frames plus session audio are written with `AVAssetWriter`. Audio is requested only while recording (`providesAudioData` is toggled by re-running the configuration).
- **Torch:** `ARConfiguration.configurableCaptureDeviceForPrimaryCamera`.
- **Apple Intelligence:** `IntelligenceBridge.status()` reports why it is unavailable (not eligible, not enabled, still downloading). On iOS 27 the photo is attached with numbered marks drawn on it.
- **Speech:** `SFSpeechRecognizer`, on device when the locale supports it.

## Decisions

- **The camera is ARKit, not AVFoundation.** Live detection, live pins, photos and video all come from one session, so there is no camera restart when switching modes.
- **Set-of-marks over coordinates for the on-device model.** A ~3B model can't be trusted to output pixel coordinates; it can pick "mark 4". Coordinates come only from Vision and SAM.
- **Fields are emitted only once complete.** Partial `@Generable` snapshots grow token by token, so a title is sent once the model has moved on to the summary. Labels land whole instead of flickering.
- **The print metaphor.** After a capture the photo springs from full-bleed (matching the viewfinder) into a framed print above the card, so nothing the model labels is ever hidden under UI.
- **Fragment Mono for labels.** Its advance is exactly 0.618 em, so label widths are computed, not measured, and the layout is synchronous and collision-free.
