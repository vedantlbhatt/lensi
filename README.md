# lensi

heyclicky for your camera. Lensi opens straight into a full-screen camera. Point it at anything, tap for a photo, hold for video, or hold the mic and ask out loud. It outlines the thing, labels its parts, and walks you through using it, step by step, with a pointer that lands on each part as you go. It runs on Apple's on-device model first.

## What it does

| | |
|---|---|
| **Capture anything** | Tap the shutter for a photo, hold it for up to 15 s of video, or drop in a photo, video, file or clipboard image from the rail. |
| **Ask out loud** | Hold the mic, ask "how do I descale this?", let go. Lensi takes the photo and answers. "How do I…" questions become walkthroughs. |
| **Annotate** | The photo springs back into a framed print. The subject's outline draws itself, numbered marks show what the phone's vision found, and labels unfold out of those marks as the model names them. |
| **Walk through** | A step player with a cursor that arcs between targets, taps the part, and reads each step aloud. |
| **Point while answering** | Ask "where's the reset button?" and the cursor flies out of the card to each part the answer names while the outline glows. **Show me** replays it. |
| **Tap to ask** | Tap anything on the print. SAM outlines the part under your finger (marching ants) and Lensi says what it is. |
| **Another angle** | Add more photos of the same thing (the back of the box, the ports on the side) from the capture's top bar. Each photo keeps its own labels; flip between them on the print. |
| **Read codes** | QR links open and Wi-Fi codes copy their password: hold the label Lensi put on the code. |
| **Change it** | Every capture stays editable: switch its lens and it re-annotates; hold a label to rename it, remove it (with Undo), or copy text and open links the phone read there. |
| **Lenses** | Identify, Guide, Fix, Shop, Safe, Learn. Each lens has its own highlighter colour and its own follow-up questions. |
| **Live pins** | Toggle live mode and tap things on the camera to pin labels in 3D (ARKit). The labels stay on the object as you move. |
| **Memories** | Every capture is saved on the phone. Swipe up to browse them, reopen one, ask more, or share an annotated print. Video captures let you pick which moment gets annotated. |

## How it works

| Step | Where | Notes |
|---|---|---|
| Live detection brackets | YOLO11n on the Neural Engine, about 15 fps | Live mode only |
| The eyes | Vision: foreground instance outlines, OCR, barcodes, classification, saliency, plus YOLO on the still | About 0.5–1.5 s |
| Part outlines | MobileSAM (Meta's Segment Anything, mobile variant) on Core ML. A grid of point prompts over the subject proposes parts (knobs, ports, handles) that become numbered marks; taps and labels are point-prompted | Falls back to Vision instances |
| The brain | Apple Intelligence (Foundation Models). On iOS 27 the photo goes in with numbered marks drawn on it, and the model answers by mark number | Claude (via `server/`) or vision-only as fallbacks |
| The ears | On-device speech recognition | |

The model never invents coordinates. It points by **mark number** (set-of-marks prompting), so every label lands on something the phone actually found. Claude can also point by coordinate, and its points are snapped to the nearest region and refined with SAM.

Brains, picked in Settings (default **Auto**):

- **On-device** (Apple Intelligence): private, offline, free. iOS 26 reasons over the mark list as text; iOS 27 also sees the image.
- **Claude**: `server/` streams Claude's answer line by line.
- **Eyes only**: no model at all. It shows only what Vision found (outlines, text, codes).

## Run it

You need a Mac with **Xcode 27** and an iPhone with ARKit. Apple Intelligence features need an Apple Intelligence iPhone on iOS 26+ (iOS 27 for image understanding).

Apps built with the iOS 27 SDK must use the UIScene life cycle or they die at launch. Expo's prebuild template doesn't do that yet, so `app/plugins/withSceneLifecycle.js` sets it up (a scene manifest, plus a `SceneDelegate` built on Expo's `ExpoAppSceneDelegate`). Keep that plugin in `app.json`.

```sh
cd app
npm install
npx expo run:ios --device
```

- **Simulator:** `npx expo run:ios`. The simulator has no ARKit, so the app shows a *virtual camera* over public demo scenes (swipe sideways to switch). Vision and SAM still run on the real stills.
- **Web preview (UI and motion only):** `npm run web`. It uses the virtual camera, scripted model answers and simulated speech.
- **Scripted runs:** `lensi:///?demo=truck&lens=guide&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F` captures a demo scene and runs it. Add `export=1` to also render the share image. CI hands the same URL over at launch (`SIMCTL_CHILD_LENSI_URL=… xcrun simctl launch …`), which avoids the "Open in Lensi?" prompt that `simctl openurl` can raise.

### SAM models

The two Core ML models (≈24 MB, fp16, iOS 17+) live in `app/modules/lensi-ar/ios/Models/`. CI builds them on macOS from MobileSAM's weights and checks them against PyTorch on public images (mask IoU 0.997 to 1.0): see [`tools/sam/README.md`](tools/sam/README.md) and the `sam` job in `.github/workflows/ios.yml`. Without them, part outlines fall back to Vision.

### Cloud brain (optional)

```sh
cd server
npm install
cp .env.example .env   # ANTHROPIC_API_KEY, or LENSI_PROVIDER=bedrock
npm start              # :8787
npm run mock           # scripted answers, no key needed
```

## Layout

```
app/
  src/app/index.tsx          the camera (everything opens from here)
  src/components/camera/     shutter, lens wheel, rail, mic, virtual camera
  src/components/capture/    the print, Skia overlay, labels, pointer, step player, card, share
  src/components/memories/   saved captures
  src/motion/                motion primitives (React Bits ideas, rebuilt in Reanimated)
  src/lib/                   pipeline, engines (apple / cloud / vision), regions, geometry, store
  modules/lensi-ar/          Swift: ARKit camera, Analyzer, SAMSegmenter, Intelligence, Speech, Recorder
server/                      Claude streaming server (+ mock)
tools/sam/                   MobileSAM → Core ML conversion, checks, report on public images
.github/workflows/ios.yml    macOS CI: SAM verify, Simulator build, scripted screenshots
```

## Tests

```sh
cd app && npm test && npx tsc --noEmit
cd server && npm test && npx tsc --noEmit
```

CI also builds for the iOS 27 Simulator, drives scripted captures through deep links, and pushes screenshots, device logs and the exported share image to the `ci-results` branch.

## Design

- **Type:** Bricolage Grotesque (display), Funnel Sans (text), Fragment Mono (anything the machine reads), Instrument Serif italic (quiet asides).
- **Colour:** ink, paper, and one highlighter per lens. No gradients-for-the-sake-of-it, no blue AI glow.
- **Motion:** everything physical is a spring. Things grow out of where they come from: labels from their marks, the card from the shutter, a capture back into Memories.
