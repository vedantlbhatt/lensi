# Build notes (overnight, Oct 3 2026)

A running log of the camera-first rebuild on branch `camera-first`: what exists, what has been verified and how, and what still needs a real iPhone.

## Verification status

| Area | How it was checked | Status |
|---|---|---|
| TS logic (geometry, regions, protocol, links, QR codes, colours, questions, eyes-only engine) | `npm test` (node test runner, 47 tests) | passing |
| App ↔ server protocol | server tests run the real server in mock mode through the app's own parser | passing |
| UI + motion | Expo web preview driven by Playwright (iPhone viewport, real touch events) | camera, capture, walkthrough, voice, memories, settings, drop menu reviewed |
| MobileSAM → Core ML | `tools/sam`: torch vs wrapper (bit-exact decoder), fp16 interpreter, then **real Core ML on macOS CI** (CPU and all compute units) | passing |
| Swift compile (Release, iOS 27 SDK) | `.github/workflows/ios.yml` on the `xcode-27` runner | passing |
| App launch + scripted runs in the iOS 27 Simulator | same job; screenshots, device log, timeline and capture JSON on the `ci-results` branch | launches; Vision OCR, YOLO and SAM (CPU) annotate the demo scenes |
| Eyes on public images (Vision + YOLO + SAM on macOS) | `tools/eyes` in the `sam` job | SAM part outlines on every image; QR payloads read |
| Native crash review | a read-only pass over every Swift file (recording, speech, torch, photo, threading) | 10 issues found and fixed |
| ARKit capture, recording, torch, live pins, live-guide tags and change watch, speech, Apple Intelligence | need a physical iPhone | not yet run on device |

## Live guide (the default mode)

What it is: someone mid-job (car, plumbing, wiring) props the phone up, says what they're doing, and gets short tags pinned on the parts plus one step at a time in a directions panel, read aloud, checked when something changes.

How it fits together:

- `guide.ts` is the session as a pure reducer (plan, steps, one tag per part, next/back/finish, check results, answers) plus the voice-command reader; `guideSession.ts` (`useGuide`) wires it to the camera, the brain, the voice and narration. 9 tests.
- The brain gets a `guide: true` walkthrough request (steps name their part in 1-3 words: `LensiStep.part`, server `G` lines) and `check: <step>` requests (`LensiCheck {done, say}`, server `C|yes/no/unsure`). Eyes only can't judge a step and says so (`done: null`).
- Native: `guideCapture` freezes the frame's pose and feature points; `guidePin` raycasts a part's point into the world; `guideFocus` highlights the current step's tag; `guideWatch` runs the change watch and fires `onGuideChange`.
- Change watch (`GuideWatch.swift`): only while the phone is steady (moved < 2 cm, turned < 3 degrees since the last sample) and the part is on screen; a crop around the part is feature-printed twice a second; "changed" is distance > 0.42 from the baseline, "settled" is < 0.22 from the previous sample; three in a row fire once, then 4 s of quiet. A hand passing through isn't settled, so it doesn't count. These thresholds are a first guess: the distances are logged (`[lensi] watch base … prev …`) so they can be tuned on a phone. A shadow or a light can look like a change, so the watch starts a check at most once per 12 s on a step, and stops after two that weren't done (Check, or "check", still works).
- Questions mid-job look too: the new frame is analysed, so the answer can point at marks. "Where's the shutoff valve?" adds a tag (and outline) for it in the world, pinned in the look that found it (`GuidePart.frame`), and a step that had no part gets it. Parts from different looks are matched by name, never by mark or point (those only mean something within one look). Native keeps the plan's look for the whole job and up to five later ones.
- Outline (`guideOutline`): each part's shape comes from its region's SAM polygon, or SAM at the part's point when the brain named a point (a shape covering half the frame is the scene, not a part, and is dropped). Native lays it on a plane through the part's pin, facing the camera that took the frame (`Selection.withPlane` / `onPlane`), and re-projects it every frame: the current step's part in the lens colour (2.5 pt, 14% fill), the others thin and white, none while any corner is behind the phone. Polygons are thinned to 48 points. This frozen shape is only the fallback: live SAM (below) re-cuts each part on the camera feed, and while it has a fresh cut the frozen one steps aside.
- Live SAM (`LensiARView.segmentLive`): SAM runs on camera frames at most every 80 ms; 4 a second while the phone is propped up and still (moved under 1 cm and turned under 1 degree since SAM's last frame) with nothing tracked moving, or when it runs hot, 1.6 when critical; never two at once, and not while a photo is being analysed (`Analyzer.analyzing`: a plan, a check or an answer is waiting on that, and they'd share the Neural Engine). `SAMSegmenter.prepare(pixelBuffer:orientation:)` turns ARKit's YCbCr buffer upright, Lanczos-scales and pads it on the GPU into one reused 1024 canvas (CI checks it against the photo path on the public images: same prompts, IoU >= 0.9). What gets prompted: the current step's tag every frame plus one other tag in turn; with no tags, the thing last tapped (`outlineTapped`), else the tracked object's box, else the point under the reticle. A thing already outlined is followed (`LiveTracker`): SAM is asked where it should be now (its outline carried along, seen from where the phone is now), at a point well inside that and within its box grown 20%, and a cut that doesn't fit is refused as something else. How strictly depends on how fast the thing itself moves (`LiveTracker.asking`, from the outline's world velocity, which has the phone's motion taken out): under half its size a second it's still, SAM is asked within the predicted box grown 10%, a cut must overlap the prediction by more than 0.5 and be 0.6-1.67x its area, and it's blended in gently (`OutlineMath.Smoothing.still`: ARKit already knows where it is); faster, the box is grown 20%, the gate is 0.25 and 0.4-2.5x, and it's blended as standard. Measured both ways in `tools/pin` (ARKit recordings) and `tools/track` (flat footage): the strict gate stops a same-coloured neighbour creeping in on a still thing, and refuses a moving thing's real changes. Each polygon is resampled to 64 evenly spaced points and laid in the world on a plane through its part facing that frame's camera, and redrawn from the world every display frame. Between SAM's cuts it rides its own pixels (`LiveFlow`, below). A new cut is blended in by `OutlineMath.steady`: edge noise (a change that doesn't keep going the same way) is damped, real turning or bending passes, motion is followed. What's drawn eases onto each new cut over about 30 ms instead of jumping (60 ms was smoother still but fell 4-8 points of J behind on fast things; tools/track measured 30, 60 and adaptive). Two misses in a row, or 4 s without SAM confirming it, and it fades out. Every outline sits on a faint dark halo (`OutlineLayer`), so a white line still shows on a white part. Logged every 3 s: `[lensi] live SAM … ms a frame (encoder … ms), found/prompts, refused, fastest thing, optical flow … ms, thermal`.
- Between SAM's cuts (`LiveFlow`, `LensiARView.flowLive`): up to 30 times a second a 360-px grey copy of the frame is made, and each followed outline is seen from the last frame's camera, carried on the picture, and laid back in the world as the new camera sees it, so the phone's motion cancels and the thing's is what's left. Carrying: points on a 12 x 12 grid well inside the outline (the deepest 70%; the edge is where the background shows through) are followed with pyramidal Lucas-Kanade (4 levels, 9 x 9 windows), each followed back again and the worse half dropped; the outline moves, turns and scales by their medians (MedianFlow), at most 10 degrees and 8% a frame. A SAM cut that lands after the flow has moved on is carried along the same way before it's blended in. Vision's own optical flow was tried first and fails on CI's virtual Mac on every call (memFullErr), so it couldn't be measured; this runs anywhere, the same code in the app, `tools/track` and `tools/eyes`.
- Out of view (`LensiARView.layoutPins`): the current step's tag never just disappears. When its part leaves the screen (or goes behind the guide panel, whose height JS passes as `pinInsets`), the tag waits on the nearest edge with an arrow pointing the way; a part behind the phone is mirrored in front first, so the arrow still says which way to turn. Other tags hide when their part is out of view. A few points of hysteresis stop a part right on the edge from flickering between the two.
- Hands free (`handsFree.ts`, setting "Keep listening during a job", on by default): once someone has talked to the guide, the mic opens again each time the app finishes talking, for as long as a step is up (not while planning; it ends with the job, a tap on the mic, or the app leaving the foreground). It closes while the app speaks, so it never hears itself: `narrate.ts` tracks speaking per utterance and `say()` resolves when a line ends. The mic there also hears the room, so `heard()` in `guide.ts` lets through only the short commands, questions ("which one is it", "it won't come loose") and anything said to "Lensi" by name; other talk is dropped. A short command is sent after 0.9 s of quiet, anything else after 1.5 s.
- The Simulator and the web preview have no ARKit: their tags are drawn over the virtual camera's drifting scene. The web preview fakes one change per job, 7 s into watching a part, to show the flow. Its recogniser hears the scene's question; with `?talk=next|Which tyre is it?|4:check` it then says those lines on later turns (`4:` = after 4 s of quiet), which is how the hands-free film is made. Nothing else is faked.

## Things that need a device

- **Photo:** `ARSession.captureHighResolutionFrame`, falling back to the current frame. The JPEG is written upright (`.oriented(.right)`).
- **Video:** ARKit frames plus session audio are written with `AVAssetWriter`. Audio is requested only while recording (`providesAudioData` is toggled by re-running the configuration).
- **Torch:** `ARConfiguration.configurableCaptureDeviceForPrimaryCamera`.
- **Apple Intelligence:** `IntelligenceBridge.status()` reports why it is unavailable (not eligible, not enabled, still downloading). On iOS 27 the photo is attached with numbered marks drawn on it.
- **Speech:** `SFSpeechRecognizer`, on device when the locale supports it.
- **Live outlines on a phone:** everything about following a moving thing is measured on real footage on CI's Mac (below), not on a phone. What only a phone can say: SAM's encoder time on the Neural Engine (the log's `encoder … ms`; the footage assumes 8 cuts a second), LiveFlow's cost (`optical flow … ms`; a few ms on a Mac core), heat over a long job, and whether ARKit's pose keeps the round trip from the last frame's camera to this one honest while the phone moves.

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
  (`night_sky`) while the phone sends `night sky`, so labels are normalised before the check.
- **In the Simulator the scene classifier is broken outright.** It returns the same labels for
  every image ("outdoor 49, night sky 49, sky 49, celestial body 18, moon 18", read from the
  `seen` field each capture now keeps), so a circuit board was titled "Celestial body". macOS
  gives the same photo "circuit board". The Simulator build skips the classifier.
- **The subject is the most prominent detection, not the most confident.** Confidence alone
  picked a small car at the photo's edge (0.94) over the one filling it (0.75). Prominence is
  confidence × √area × centrality, and surfaces (table, bed, couch, bench) count for a fifth so
  bottles beat the table they stand on.
- **The detector guesses at slivers.** A car roof cut off by the frame's edge came back as a
  "bottle"; small boxes touching the edge no longer get names.
- **Letterbox YOLO's input.** Vision was stretching every image into the model's square input
  (`scaleFill`), so a row of water bottles in a 16:9 frame came back as knives. With `scaleFit`
  darknet's classic test photo gives the textbook bicycle, dog, truck, and Vision maps the boxes
  back to the image correctly (checked in the eyes job's debug renders).
- **SAM's best-scored mask is usually the whole object.** For a tap that is the wrong answer
  (a headlamp tap outlined the car), so taps take the best part-sized candidate.
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
- **Names sit on the things (design reset, morning of Oct 3).** The first design labelled parts with a dot on the part, a leader line and a dark pill in Fragment Mono, with Instrument Serif italics, mono uppercase tags and a cream palette. Feedback: it read as generic AI UI. Now each name is a plain white tag centred on its part (`layoutTags` nudges tags apart only as far as needed), the only typeface is SF Pro via the system font in sentence case, and the palette is black and white plus one highlighter per lens. No decorative dots anywhere. Tag widths are estimated from SF Pro's advances (React Native can't measure text synchronously) and the tag is centred in the estimate, so a near miss never shows. The web preview substitutes Inter for SF Pro; so does the share image, which Skia draws from font files.
