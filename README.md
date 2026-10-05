# lensi

heyclicky for your camera. Lensi opens straight into a live guide: prop the phone up, point it at the job (a car, the pipes under a sink, a breaker box), tap the mic and say what you're doing. It tags the parts with short labels that stay on them as you and the phone move, and walks you through it one step at a time, checking each step when something changes where you're working. Tap for a photo, hold for video, or swipe to the other lenses for the photo-and-answer flow. It runs on Apple's on-device model first.

## What it does

| | |
|---|---|
| **Live guide (default)** | Say, type or pick what you're working on. Lensi looks once, pins a short tag on each part the job touches (ARKit world anchors, so the tags stay put while your hands and the phone move), and shows one step at a time in a directions panel, read aloud. The current step's part is outlined, its tag turns the lens colour, and it is watched: when it changes and settles (a cap off, a valve turned), Lensi checks the step from a fresh look and either moves on or says what to do. Hands free: tap the mic once and say what you're doing; from then on it keeps listening between its own lines, so "next", "go back", "say that again", "is this right?" or a question never needs a greasy finger on the glass. Talk in the room is ignored unless it's a question or starts with "Lensi"; "stop listening" turns it off. Ask "where's the shutoff valve?" and it tags and outlines the valve where it is now, even if it wasn't in view when the plan was made. If the current step's part is out of view, its tag waits on the screen edge with an arrow pointing the way. The screen stays on for the whole job. |
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
| **Slide to pin** | A strip along the bottom of the camera. Put a finger on it and Lensi finds the things in view (SAM's parts and YOLO's objects), fixed where they are in the world from that moment, so moving the phone doesn't change them. Slide along it and the highlight moves from one thing to the next, left to right, with a tick for each; only the highlighted thing is outlined. Hold still for 1.5 s and that thing is pinned: outlined in the lens colour and named just above (the eyes and the brain name it). A pin stays on its thing: EdgeTAM, Meta's on-device SAM 2, follows it every frame from its memory of it (the frame it was pinned on and the last few), through close-ups, zooming out, blur and turning. Up close, with only part of it on the picture, the whole outline goes where that part went. Out of view, it stays where it was in the world until EdgeTAM finds it again. Outlines and pinned tags are drawn by SceneKit in the camera's own frame, so they don't slide against the picture however fast the phone moves, as a smooth curve through the outline's points. It works at .5× too: there the strip's things are found on the ultra-wide's picture, and a thing pinned there is followed by EdgeTAM on it and laid in the world once you're back at 1×. Taps on the camera do nothing. |
| **Zoom dial** | One button with the zoom on it (.5×, 1×, 2.7×). Drag across it and a half-circle dial rises with ticks for every step, turning under the finger. Let go and it keeps exactly that zoom. A tap goes to the next stop (.5, 1, 2, 5), and a pinch turns the same dial. .5× is the ultra-wide camera on every iPhone that has one: through ARKit where ARKit tracks with it, and otherwise (an iPhone 17) on its own, with ARKit paused until you're back at 1× and pinned things followed on the ultra-wide's picture by EdgeTAM, carried across the switch by its memory of them. Between EdgeTAM's outlines the gyro moves them by however far the phone has turned since their frame. Above 1× it's a crop. |
| **Memories** | Every capture is saved on the phone. Swipe up to browse them, reopen one, ask more, or share an annotated print. Video captures let you pick which moment gets annotated. |

## How it works

| Step | Where | Notes |
|---|---|---|
| Live outlines | MobileSAM on the camera feed itself, as often as the phone keeps up (encoder on the Neural Engine, one decoder pass per prompt; frames go in straight from ARKit's buffer on the GPU). Prompts: each guide tag's part and each pinned thing; nothing is outlined by itself. A thing already outlined is followed: SAM is asked where it should be now, of its candidates the one overlapping that wins, and a cut that doesn't fit is refused. Between SAM's cuts the outline rides its own pixels (points inside it followed frame to frame, their median motion), and the phone's motion is ARKit's, so it stays on a part that moves while you move. Measured on real footage against hand-drawn masks (`tools/track`, below) | Replaces the old corner brackets; `[lensi] live SAM …` logs its cost |
| Pinned things | EdgeTAM (Meta's on-device SAM 2, CVPR 2025, Apache 2.0) split into four fixed-shape Core ML models: the encoder runs once a frame for every pinned thing, and each thing's tracker attends to its own memory (the pinned frame, the last six, and an object pointer from each of the last fifteen) before its mask is decoded. Each outline is laid in the world like a SAM cut; without LiDAR, where the lines of sight through it from everywhere the phone has been cross says how far it is | `tools/edgetam`, below; `[lensi] EdgeTAM …` logs its cost |
| Live detection | YOLO11n on the Neural Engine, about 15 fps: names the strip's things when they're objects it knows, and gives SAM a box for them | |
| The eyes | Vision: foreground instance outlines, OCR, barcodes, classification, saliency, plus YOLO on the still | About 0.5–1.5 s |
| Part outlines | MobileSAM (Meta's Segment Anything, mobile variant) on Core ML. A grid of point prompts over the subject proposes parts (knobs, ports, handles) that become numbered marks for the model (never drawn for you); taps and labels are point-prompted | Falls back to Vision instances |
| The brain | Apple Intelligence (Foundation Models). On iOS 27 the photo goes in with numbered marks drawn on it, and the model answers by mark number | Claude (via `server/`) or vision-only as fallbacks |
| The ears | On-device speech recognition | |
| Live guide tags | The plan is made on one frame whose camera pose is frozen; each part's point is raycast into the world (or given the median depth of tracked feature points near the ray) and pinned there | ARKit, re-projected every frame |
| Live guide outline | Live SAM re-cuts each tag's part from where the phone is now (above); until it has, the part's SAM shape from the plan's frame, laid on a plane through its pin that faces the camera that took the frame | ARKit, re-projected every frame |
| Change watch | Twice a second, while the phone is steady and the part is in view, a Vision feature print of a ~15 cm crop around it is compared with how it looked; a difference that holds for ~1.5 s triggers a check (at most every 12 s per step) | Thresholds still to be tuned on a device |

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

- **Simulator:** `npx expo run:ios`. The simulator has no ARKit, so the app shows a *virtual camera* over public demo scenes (swipe sideways to switch). Vision and SAM still run on the real stills. Four scenes are moving footage (`workers`, `aisle`, `bottles`: Intel's CC BY sample videos; `shaker`: a black shaker bottle filmed handheld for Lensi, walking round it, up close and back out, down to 0.5×), so the strip can be tried on things that move. What the strip offers in them was found and followed frame by frame by the app's own Swift ([`tools/strip`](tools/strip/main.swift), and for the bottle EdgeTAM in [`tools/edgetrack`](tools/edgetrack/main.swift), on CI), and a pin rides its thing's track.
- **Web preview (UI and motion only):** `npm run web`. It uses the virtual camera, scripted model answers and simulated speech.
- **Scripted runs:** `lensi:///?demo=truck&lens=guide&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F` captures a demo scene and runs it. Add `export=1` to also render the share image, `tap=0.3,0.33` to tap the print there once it's labelled, `brain=vision` to force the eyes-only brain, or `file=clip.mp4` (from the app's Documents) with `moment=0` to read a video and then a second keyframe. On the live camera, `scene=truck` picks the Simulator's scene, `guide=<task>` starts a guided job as if it were said, `scrub=0.05,0.35,0.6` lands a finger on the strip, slides through those points (0–1 across it) and holds on the last, which pins that thing, and `zoom=2.7` turns the zoom dial there and leaves it up. CI hands the same URL over at launch (`SIMCTL_CHILD_LENSI_URL=… xcrun simctl launch …`), which avoids the "Open in Lensi?" prompt that `simctl openurl` can raise.

### On your iPhone without TestFlight

No Mac needed: [`iphone.yml`](.github/workflows/iphone.yml) builds an ad hoc release on GitHub's Mac runners, signed with the team's App Store Connect API key (secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`), for the iPhones registered with the team. A new iPhone's UDID goes in the repository variable `IPHONE_UDIDS`, and the workflow registers it. Run the workflow, or push to the `iphone` branch. Then on the iPhone, paste this into Safari and tap Install:

```
itms-services://?action=download-manifest&url=https://raw.githubusercontent.com/vedantlbhatt/lensi/ota/ios/manifest.plist
```

After that, **JavaScript changes arrive over the air**. Every push to `main` or `camera-first` publishes its JavaScript on the `ota` branch ([`ota.yml`](.github/workflows/ota.yml), [`tools/ota`](tools/ota/publish.py)). The app looks there at launch, downloads anything newer, and restarts into it once nothing is in hand ([`src/lib/ota.ts`](app/src/lib/ota.ts)). An update only runs on a build of the same native code: [`tools/ota/runtime.py`](tools/ota/runtime.py) hashes the Swift, the native packages and the app config, and the build carries that hash. A Swift change therefore needs a new install. If an update ever fails to start, the next launch sets it aside and runs the build's own JavaScript ([`plugins/withOTA.js`](app/plugins/withOTA.js)).

With a Mac, `npx expo run:ios --device` installs straight over the cable as usual.

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
tools/edgetam/               EdgeTAM → four fixed-shape Core ML models, checked against Meta's own predictor
tools/edgetrack/             the app's EdgeTAMTracker.swift on a folder of frames
tools/wide/                  the 0.5x gyro warp checked against a camera turned for real
.github/workflows/ios.yml    macOS CI: SAM verify, Simulator build, scripted screenshots
```

## Tests

```sh
cd app && npm test && npx tsc --noEmit
cd server && npm test && npx tsc --noEmit
```

CI also builds for the iOS 27 Simulator, drives scripted captures through deep links, and pushes screenshots, a screen recording of each run, device logs, the app's stderr and the exported share image to the `ci-results` branch. Three stock clips (Intel IoT Devkit sample videos, CC BY 4.0) go through the video pipeline there: `lensi:///?file=car-detection.mp4` opens a video from the app's Documents.

### Following moving things, on real footage

`tools/track` runs the app's own live-outline code (SAMSegmenter, LiveTracker, LiveFlow, OutlineMath) over real videos on CI's Mac, with no phone and no ARKit, and scores every frame against an outline drawn by hand (DAVIS 2017; the Intel clips have none and are judged by eye). J is the overlap with the hand-drawn outline; lurch is how far the outline's middle jumps from one frame to the next rather than gliding, next to the hand-drawn outline's own. SAM runs 8 times a second (every third frame of 24 fps footage, about what a phone manages):

| clip | SAM at a fixed spot | before LiveFlow (coasting) | now (`lensi@8`) | hand-drawn lurch |
|---|---|---|---|---|
| car through a junction | J 39% | J 93%, lurch 3.9 px | J 93%, lurch 1.9 px | 0.7 px |
| car round a roundabout | J 95% | J 92%, 7.4 px | J 92%, 6.2 px | 0.8 px |
| drifting car | J 9% | J 74%, 24.3 px | J 82%, 20.8 px | 9.8 px |
| dog | J 70% | J 78%, 17.5 px | J 82%, 10.4 px | 7.3 px |
| parkour | J 13% | J 64%, 15.5 px | J 60%, 7.2 px | 3.7 px |
| bolt on a belt | lost | 8.3 px | 0.6 px | |
| bolt moving its width a cut | lost | lost at the second cut | held, 9.3 px | |

EdgeTAM, as pinned things are followed now, on the same footage against the same hand-drawn outlines (`edgetam`: every frame; `edgetam@8`: every third, the flow carrying it between):

| clip | SAM (`lensi@8`) | EdgeTAM every frame | EdgeTAM every third |
|---|---|---|---|
| car round a roundabout | J 91.7%, jerk 3.8 px | J 97.5%, 1.3 px | J 95.9%, 5.1 px |
| car through a junction | J 92.8%, 1.7 px | J 96.8%, 1.0 px | J 95.7%, 2.5 px |
| drifting car | J 71.1%, 19.1 px | J 93.2%, 10.2 px | J 86.7%, 31.1 px |
| dog | J 81.2%, 10.6 px | J 93.9%, 7.6 px | J 86.8%, 11.9 px |
| parkour | J 73.4%, 7.5 px | J 93.0%, 4.0 px | J 78.5%, 10.5 px |

From its memory of the thing it holds on where SAM's re-cuts drift (J 94.9% on average against 82.0%), and the more often it runs the better: the app asks it up to 20 times a second.

At 4 cuts a second (a hot phone, or a guide part waiting its turn) coasting loses fast things (dog J 32%, drifting car 10%) and LiveFlow keeps them (73%, 53%). LiveFlow costs 2-3 ms a frame plus about 1 ms per outline on a Mac core. Not measured here: ARKit (the phone's own motion), SAM's speed on a phone's Neural Engine, heat. `bash tools/track/ci.sh` reproduces it on a Mac; results and videos land on the `ci-track` branch.

### Following a pinned thing with EdgeTAM, on handheld footage

A pinned thing is followed by [EdgeTAM](https://github.com/facebookresearch/EdgeTAM), the on-device version of Meta's SAM 2 video tracker. SAM 2 keeps a memory of the thing that grows with the video; [`tools/edgetam/parts.py`](tools/edgetam/parts.py) lays it out in fixed slots with a validity flag each (7 frames x 512 tokens, 16 object pointers), so it becomes four models with one shape each: encoder, prompt, track and memory, 51 MB in float16. The test footage is a black shaker bottle on a striped rug, filmed handheld: walking round it, so close that it runs off the picture, back out, blurring, turning, and down to 0.5x where it is a few dozen pixels tall (533 frames, 30 fps, `tools/edgetam/footage`).

| check | frames | IoU with the reference |
|---|---|---|
| the split in PyTorch vs EdgeTAM's own video predictor | 533 | mean 1.0000, worst 0.9991 |
| the app's `EdgeTAMTracker.swift` with the Core ML models (CI's Mac) vs that predictor | 533 | mean 0.981, worst 0.936; never lost |
| EdgeTAM on every other frame (15 a second, about a phone's rate) vs every frame | 267 | mean 0.993, worst 0.960 |
| the app itself in the iOS Simulator, with the models it ships, on its 360x640 demo clip at 15 fps (`10h`), what it drew vs the predictor | 267 | mean 0.964, worst 0.900; never lost (each step's own outline: 0.967, worst 0.904), about 1 s a frame on the Simulator's CPU |
| the clip played as the phone's camera (`EDGETRACK_LIVE_MS=60`): a look only when the app would start one (15 a second at 30 fps), each answer 60 ms after its frame, moved on by LiveFlow in between; what's drawn on every frame | 533 | mean 0.924, worst 0.691; 130 frames under 0.9 |
| the same, each answer 100 ms late (10 looks a second) | 533 | mean 0.896, worst 0.592; 238 frames under 0.9 |

Every row above but the last two draws each outline on the frame it was made from, which no phone does: it looks at most 20 times a second, each answer lands some tens of milliseconds after its frame, and something has to move the outline in between (ARKit at 1x, the gyro at 0.5x). Played as the phone's camera, the bottle's outline trails it in the fastest moves (the close-up, frames 180 to 210). [`tools/edgetam/timing.py`](tools/edgetam/timing.py) splits that up, at the same timing: with the outline moved exactly as the bottle moved between answers (what a phone that knew its own motion perfectly would do, which ARKit approaches for a thing standing still), mean 0.950, worst 0.763 (the outline changes shape as the view turns while an answer is on its way; every frame: 0.976); not moved at all, 0.728. The clip has no ARKit or gyro, so the live run moves it by the bottle's own pixels (LiveFlow), and a black, smooth bottle gives it little to follow: 0.924. Not measured here: EdgeTAM's real speed on an iPhone (60 ms is about Meta's 16 frames a second on an iPhone 15 Pro Max), and ARKit on this clip.

In the Simulator, `lensi:///?scene=shaker&edgetam=shaker` has the app itself run EdgeTAM over every frame of the clip with the models it ships (`LensiAR.trackVideo`, on the Simulator's CPU), glide each outline into the last as the phone draws it, and write the clip again with the outline drawn on every frame (`lensi-edgetam.mp4`, made by the app); the virtual camera then plays the app's own run in place of the bundled track. CI's run does it (`10h-edgetam-in-app`, filmed once the run is done) next to pinning the bottle from the strip (`10g`). The virtual camera plays demo footage natively (`DemoVideoView`) and draws what's pinned in the same display frame as the picture: drawn from JavaScript, an outline landed a few frames late whenever the Simulator was busy, beside a thing that moved fast.

A phone's video can stamp its frames unevenly: round the switch to 0.5x the 15 fps demo clip shows the odd frames of the 30 fps footage for a second, so a track packed by time alone lagged the picture there by half a frame (IoU 0.71 at worst). [`tools/edgetam/match.py`](tools/edgetam/match.py) finds the frame each clip frame really shows; the bottle's bundled track is packed by it (worst 0.93), and the app's own run above is scored by it.

Smaller models were tried and turned down: with their weights stored in 8 bits a value (`EDGETAM_WEIGHTS=int8`, 27 MB for the four against 52) the app's tracker lost the bottle's outline in the closest frames (IoU 0.66 at worst, 13 frames under 0.7, against float16's 0.94), though the same rounding in PyTorch cost nothing, and it was no faster on CI's Mac. The app ships float16.

Snapping the outline to the picture's own edges was tried and turned down too. EdgeTAM's mask is 256 x 256 over the whole picture, so a guided filter (He, Sun & Tang) on the 1024 canvas round the thing, the picture as the guide, should put the edge where the picture has one. On DAVIS's hand-drawn masks (`tools/track`, five clips, `track-lab` runs 28 and 29) it moved the drawn line about 0.1 px nearer the real edge and J up 0.1 to 0.3 points with the colours or a 512 grid, and nothing at all on the cheap setting (94.96% either way): no more than the same run moves by from one try to the next. On the shaker bottle wobble and jerk didn't change (8.7%, 9.0 px), and it cost 1 to 11 ms a cut on CI's Mac. The code is in 793301f (`EdgeSnap`).

On a flat picture (0.5x, and the virtual camera's track) each new outline is glided into the last: carried onto it by the affine map that fits best, so motion and zoom pass straight through, and only what's left (the mask's edge noise) eased in (`OutlineMath.glide`). [`tools/edgetam/smooth.py`](tools/edgetam/smooth.py) is the app's outline code in Python for trying such things on the full-precision masks. `bash tools/edgetam/ci.sh` on a Mac reproduces all of it (the `edgetam-lab` workflow), and the compiled models and the outlines drawn on the clip land on the `ci-edgetam` branch.

#### Across the switch to 0.5x

The app's 0.5x on an iPhone 17 swaps cameras in an instant: the same thing is suddenly half the size, somewhere else on the picture. [`tools/edgetam/lens_switch.py`](tools/edgetam/lens_switch.py) simulates it on the bottle clip ("1x" is the clip's middle half blown up) and follows the bottle across the switch three ways, scored against EdgeTAM's own run (IoU on the first frame after the switch, then the mean over the rest):

| switch | frames | keep its memory (the app) | start again from a box | re-prompt, keep recent frames |
|---|---|---|---|---|
| 1x to 0.5x | 447-502 (far off) | 0.982, then 0.990 | 0.944, then 0.972 | 0.944, then 0.978 |
| 1x to 0.5x | 315-353 (nearer) | 0.990, then 0.993 | 0.976, then 0.991 | 0.976, then 0.992 |
| 0.5x to 1x | 447-502 (far off) | 0.940, then 0.953 | 0.917, then 0.948 | 0.917, then 0.950 |
| 0.5x to 1x | 315-353 (nearer) | 0.966, then 0.970 | 0.960, then 0.967 | 0.960, then 0.970 |

(Into "1x" the scores are capped by the blown-up picture's blur, for every way alike.) Between EdgeTAM's outlines at 0.5x the gyro moves them by how far the phone has turned since their frame; [`tools/wide/warp_test.py`](tools/wide/warp_test.py) checks that warp against a pinhole camera turned for real (0.0000 px off over 200 random turns, in CoreMotion's right-handed convention).

### Pinned while you walk round it, on ARKit walk-arounds

[`tools/walk`](tools/walk/main.swift) runs the app's 1x path over the stretches of ARKitScenes scans where the camera walks round a still thing, from far to close enough that it runs off the picture and back (1.1 to 4.2 m of travel, 86 to 200 degrees of turn, nine scans): each cut laid in the world and held by ARKit between cuts, as on the phone, and scored against SAM asked with the thing's hand-drawn 3D box from each frame's pose. Lost is how often the overlap falls below 0.5; slip is how far the outline moves against the box from one frame to the next (what a person sees as jitter), lurch how far its middle jumps. Means over the nine:

| | J | lost | slip | lurch |
|---|---|---|---|---|
| SAM's cuts, gated (the path before EdgeTAM) | 75.3% | 12.8% | 1.4 px | 1.7 px |
| EdgeTAM as first wired in | 76.8% | 8.9% | 4.8 px | 6.0 px |
| EdgeTAM now | 75.9% | 7.4% | 2.9 px | 3.3 px |

(The first EdgeTAM row is from an earlier run; the harness's Core ML isn't bit-for-bit the same from run to run.) EdgeTAM keeps hold of things SAM loses (a TV lost in 33% of frames, against SAM's 78%). As first wired in, up close it threw the whole outline about: the part of a sink or washer on the picture moved and rescaled the whole outline unchecked, and where that failed the part was laid as the whole thing (lurch 26 and 13 px). Now that part moves a still thing whose depth is known by 10% at most, has to be plausibly the same thing, and is never laid as the whole. Lines of sight put a washer filling three quarters of the picture at 0.55 of its distance (a big thing's outline is mostly its near face, so its middle isn't one place in the world as you go round it); only a cut wholly on the picture and at most 40% of it across is sighted now (a sofa that ended at 0.53 of its distance ends at 1.01). What jitter is left is mostly where a big thing fills the picture; a bottle doesn't. At 0.5x on an iPhone 17 ARKit is paused, and it can come back with its world somewhere else; `shift@true` moves the recorded poses' world by 8 degrees and 30 cm halfway through each walk-around, as such a resume would. Laid where they were, pinned things were lost in 19% of the frames after it (J 69.9%); now, back at 1x, a pinned thing's first cut is laid afresh where EdgeTAM sees it (the whole outline moved onto the part on the picture, up close), and one seen whole nowhere near where it should be is too: lost in 11% (J 74.0%). `bash tools/walk/ci.sh` on a Mac reproduces it (`track-lab`); results and videos land on the `ci-track-lab` branch.

### Pinned while the phone moves, on real ARKit recordings

The footage above has no camera pose. `tools/pin` runs the app's world anchoring on Apple's ARKitScenes (iPad Pro captures with ARKit's own recorded pose and lens for every frame, and 3D boxes drawn around the furniture by hand; CC BY-NC-SA): `FrozenCamera` and `LiveShape` (`LiveWorld.swift`, shared with the app), LiveTracker, LiveFlow and SAM, over 3 s stretches where a still thing stays in view while the camera moves the most. "On the box" is how much of the outline lies on the thing's hand-drawn 3D box as each pose sees it (no SAM in that check); lurch is next to the box's own, which is all camera motion. The app's camera math puts the boxes' corners within 0.00 px of the dataset's own projection.

| scan, 3 s | camera | no ARKit (SAM at a fixed place) | ARKit alone (one cut) | the app | box's own lurch |
|---|---|---|---|---|---|
| kitchen cabinet | 66 cm, 54 degrees | 16% on the box, 5.7 px lurch | 94%, 1.0 px | 89%, 3.6 px | 0.9 px |
| TV | 80 cm, 47 degrees | 21%, 9.1 px | 88%, 0.7 px | 94%, 0.8 px | 0.7 px |
| chair | 206 cm, 58 degrees | 68%, 41.1 px | 92%, 1.6 px | 96%, 3.1 px | 1.5 px |
| cabinet | 77 cm, 38 degrees | 48%, 47.1 px | 99.8%, 0.8 px | 98.4%, 1.9 px | 0.8 px |

ARKit alone keeps an outline on a still thing as steadily as the thing itself moves on screen; SAM's re-cuts keep its shape right as the view turns (on the kitchen cabinet, J against SAM asked with the box goes 83% to 84%, on the chair 49% to 73%). Re-cuts are asked by how fast the thing itself moves (ARKit takes the phone's motion out): strict for a still one, loose for one that moves, since a strict gate refuses the real changes of a moving, bending thing (parkour 60% to 19%) and a loose one let the wooden floor creep into a wooden table (56% to 86% on the kitchen cabinet with the change). Not handled: things SAM can't cut from a point, such as a glass-topped open-frame table, where SAM cuts the rug seen through the glass. `bash tools/pin/ci.sh` on a Mac reproduces it (the scans are fetched from Apple, 1-2 GB each); results and videos land on the `ci-track-lab` branch.

## Design

- **Type:** SF Pro, the iPhone's own, in sentence case. No display faces, no monospace, no italics. (The web preview substitutes Inter.)
- **Labels:** a plain white tag sitting on the thing it names. No dots, no leader lines.
- **Colour:** black and white like the Camera app, plus one highlighter per lens for outlines and the pointer.
- **Motion:** everything physical is a spring: tags settle onto their parts, the card rises from the shutter, a capture goes back into Memories.
