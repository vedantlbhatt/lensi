# lensi

heyclicky for your camera. Lensi opens straight into a live guide: prop the phone up, point it at the job (a car, the pipes under a sink, a breaker box), tap the mic and say what you're doing. It tags the parts with short labels that stay on them as you and the phone move, and walks you through it one step at a time, checking each step when something changes where you're working. Tap for a photo, hold for video, or swipe to the other lenses for the photo-and-answer flow. It runs on Apple's on-device model first.

## What it does

| | |
|---|---|
| **Live guide (default)** | Say, type or pick what you're working on. Lensi looks once, pins a short tag on each part the job touches (ARKit world anchors, so the tags stay put while your hands and the phone move), and shows one step at a time in a directions panel, read aloud. The current step's part is highlighted and watched: when it changes and settles (a cap off, a valve turned), Lensi checks the step from a fresh look and either moves on or says what to do. Hands free: tap the mic once and say what you're doing; from then on it keeps listening between its own lines, so "next", "go back", "say that again", "is this right?" or a question never needs a greasy finger on the glass. Talk in the room is ignored unless it's a question or starts with "Lensi". |
| **Capture anything** | Tap the shutter for a photo, hold it for up to 15 s of video, or drop in a photo, video, file or clipboard image from the rail. |
| **Ask out loud** | Hold the mic, ask "how do I descale this?", let go. Lensi takes the photo and answers. "How do I…" questions become walkthroughs. |
| **Annotate** | The photo springs back into a framed print. The subject's outline draws itself while the model thinks, then each part's name settles onto the part as a plain white tag. |
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
| Part outlines | MobileSAM (Meta's Segment Anything, mobile variant) on Core ML. A grid of point prompts over the subject proposes parts (knobs, ports, handles) that become numbered marks for the model (never drawn for you); taps and labels are point-prompted | Falls back to Vision instances |
| The brain | Apple Intelligence (Foundation Models). On iOS 27 the photo goes in with numbered marks drawn on it, and the model answers by mark number | Claude (via `server/`) or vision-only as fallbacks |
| The ears | On-device speech recognition | |
| Live guide tags | The plan is made on one frame whose camera pose is frozen; each part's point is raycast into the world (or given the median depth of tracked feature points near the ray) and pinned there | ARKit, re-projected every frame |
| Change watch | Twice a second, while the phone is steady and the part is in view, a Vision feature print of a ~15 cm crop around it is compared with how it looked; a difference that holds for ~1.5 s triggers a check | Thresholds still to be tuned on a device |

The model never invents coordinates. It points by **mark number** (set-of-marks prompting), so every label lands on something the phone actually found. Claude can also point by coordinate, and its points are snapped to the nearest region and refined with SAM.

Brains, picked in Settings (default **Auto**):

- **On-device** (Apple Intelligence): private, offline, free. iOS 26 reasons over the mark list as text; iOS 27 also sees the image.
- **Claude**: `server/` streams Claude's answer line by line.
- **Eyes only**: no model at all. It names and counts what the detector recognises ("Four people and a chair"), reads text and codes, and answers a tap with what is under it (the text it reads, or the thing it's part of). It also answers the questions that need nothing more ("How many people are there?", "What does it say?", "Where does the code go?") and offers those as follow-ups. It never guesses beyond that.

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
- **Scripted runs:** `lensi:///?demo=truck&lens=guide&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F` captures a demo scene and runs it. Add `export=1` to also render the share image, `tap=0.3,0.33` to tap the print there once it's labelled, `brain=vision` to force the eyes-only brain, or `file=clip.mp4` (from the app's Documents) with `moment=0` to read a video and then a second keyframe. CI hands the same URL over at launch (`SIMCTL_CHILD_LENSI_URL=… xcrun simctl launch …`), which avoids the "Open in Lensi?" prompt that `simctl openurl` can raise.

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

CI also builds for the iOS 27 Simulator, drives scripted captures through deep links, and pushes screenshots, a screen recording of each run, device logs, the app's stderr and the exported share image to the `ci-results` branch. Three stock clips (Intel IoT Devkit sample videos, CC BY 4.0) go through the video pipeline there: `lensi:///?file=car-detection.mp4` opens a video from the app's Documents.

## Design

- **Type:** SF Pro, the iPhone's own, in sentence case. No display faces, no monospace, no italics. (The web preview substitutes Inter.)
- **Labels:** a plain white tag sitting on the thing it names. No dots, no leader lines.
- **Colour:** black and white like the Camera app, plus one highlighter per lens for outlines and the pointer.
- **Motion:** everything physical is a spring: tags settle onto their parts, the card rises from the shutter, a capture goes back into Memories.
