#!/usr/bin/env bash
# Boots an iOS Simulator, installs the app and drives it through scripted
# runs, taking screenshots along the way. Usage: simulator-shots.sh <Lensi.app> <outdir>
#
# Each run hands the app a lensi:// URL through the launch environment
# (SIMCTL_CHILD_LENSI_URL), which the app reads as if it were a deep link.
# `simctl openurl` is exercised once at the end: for a custom scheme the system
# may ask "Open in Lensi?", which nothing here can tap.
set -uo pipefail
APP="$1"
BUNDLE=com.vedantbhatt.lensi
mkdir -p "$2"
# Absolute: the app's stdout/stderr files are opened by the launched process
# inside the Simulator, where a relative path lands on a read-only volume and
# the launch itself fails ("Read-only file system").
OUT=$(cd "$2" && pwd)
START=$(date "+%Y-%m-%d %H:%M:%S")

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')
TYPE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devicetypes"]; names=[x["identifier"] for x in d if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]]; print(names[-1])')
echo "runtime=$RUNTIME type=$TYPE"
DEV=$(xcrun simctl create lensi "$TYPE" "$RUNTIME")
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b
xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$DEV" "$APP"

shot() { sleep "$2"; xcrun simctl io "$DEV" screenshot --type=png "$OUT/$1.png" >/dev/null 2>&1 && echo "shot $1"; }
# Every launch and liveness check, with times and PIDs, to line up with device.log.
tl() { echo "$(date '+%H:%M:%S') $*" | tee -a "$OUT/timeline.txt"; }
# launch [lensi-url]: a cold start, optionally carrying a scripted run. The app's
# stderr is kept per launch: an uncaught JS error on the UI thread aborts a Release
# build, and libc++abi prints the error's message there and nowhere else.
RUN=0
launch() {
  xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 1
  RUN=$((RUN + 1))
  local io=(--stdout="$OUT/stdout-$RUN.txt" --stderr="$OUT/stderr-$RUN.txt")
  local out
  if [ -n "${1:-}" ]; then
    out=$(SIMCTL_CHILD_LENSI_URL="$1" xcrun simctl launch "${io[@]}" "$DEV" "$BUNDLE" 2>&1)
  else
    out=$(xcrun simctl launch "${io[@]}" "$DEV" "$BUNDLE" 2>&1)
  fi
  tl "launch #$RUN ${1:-camera} -> $out"
  # "com.vedantbhatt.lensi: 12345". Simulator apps are host processes, so the PID can be
  # checked directly; launchctl inside the Simulator answered "not running" for apps that
  # were plainly on screen while a recording was going.
  PID=${out##*: }
}
PID=""
alive() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then tl "alive after $1 (pid $PID)"
  else tl "NOT RUNNING after $1 (pid $PID)"; echo "NOT RUNNING after $1" >> "$OUT/problems.txt"; fi
}

# Grant what the app may ask for so no system alert covers the screenshots.
xcrun simctl privacy "$DEV" grant all "$BUNDLE" >/dev/null 2>&1 || true

# Screen recordings, one mp4 per scenario (the morning demos). HEVC: h264 at the
# Simulator's full resolution came to ~350 MB a run.
REC=""
rec() { xcrun simctl io "$DEV" recordVideo --codec=hevc --force "$OUT/demo-$1.mp4" >/dev/null 2>&1 & REC=$!; sleep 1; }
unrec() { [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null; wait "$REC" 2>/dev/null || true; REC=""; }

# One scenario = one cold launch, filmed. A screenshot taken while recording costs
# 10-20 s in this VM, so each scenario takes a single one, at the end.
# Each film runs <seconds> past launch, plus however long the screenshot takes (anywhere from
# 1 s to 20 s in this VM), so <seconds> alone has to cover the whole analysis: with CPU-only
# Core ML here, Vision + YOLO + SAM take 15-25 s before the labels land.
scenario() { # scenario <name> <seconds> [lensi-url]
  rec "$1"
  launch "${3:-}"
  sleep "$2"
  shot "$1" 0
  alive "$1"
  unrec
}

# A cold start takes ~6 s in CI's VM (JS bundle, fonts). Demo runs use the eyes-only
# brain: this VM can't run Apple Intelligence.
scenario 01-camera 12

# Stock footage for the video pipeline: Intel IoT Devkit sample videos (CC BY 4.0),
# copied into the app's Documents and opened with lensi:///?file=…  The data container
# is looked up after the first launch, when it certainly exists.
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data 2>/dev/null || true)
tl "data container: ${DATA:-none}"
STOCK=(classroom bottle-detection worker-zone-detection store-aisle-detection)
if [ -n "$DATA" ]; then
  mkdir -p "$DATA/Documents"
  for v in "${STOCK[@]}"; do
    curl -fsSL --max-time 90 -o "$DATA/Documents/$v.mp4" "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/$v.mp4" \
      && tl "stock $v $(du -h "$DATA/Documents/$v.mp4" | cut -f1)" || tl "stock $v unavailable"
  done
fi

scenario 02-cars 28 "lensi:///?demo=cars&brain=vision"
# Tap-to-ask, scripted: once the labels are in, the app taps the headlamp itself.
# SAM outlines the part under the point (marching ants) and the eyes say what they can.
scenario 03-tap 32 "lensi:///?demo=cars&brain=vision&tap=0.3,0.33"
scenario 04-board 24 "lensi:///?demo=board&lens=learn&brain=vision"
scenario 05-guide 24 "lensi:///?demo=truck&lens=guide&brain=vision&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F"

# The video pipeline on real footage: three keyframes, the middle one read first by
# Vision, YOLO and SAM; then the run switches to another keyframe and reads that too.
n=6
for v in "${STOCK[@]}"; do
  [ -n "$DATA" ] && [ -f "$DATA/Documents/$v.mp4" ] || continue
  # The classroom run is asked a question at capture instead; the eyes can count.
  case "$v" in
    classroom) lens=learn; extra="ask=How%20many%20people%20are%20there%3F" ;;
    bottle-*) lens=identify; extra="moment=0" ;;
    worker-*) lens=safe; extra="moment=2" ;;
    *) lens=shop; extra="moment=2" ;;
  esac
  scenario "$(printf %02d $n)-stock-$v" 36 "lensi:///?file=$v.mp4&lens=$lens&brain=vision&$extra"
  n=$((n + 1))
done

# The live guide, the app's default: say the job, get tags on the parts and steps.
# Default brain: Apple Intelligence fails in this VM, so the eyes tag the parts.
scenario 10-live-guide 40 "lensi:///?scene=truck&guide=How%20do%20I%20check%20the%20tyre%20pressure%3F"

# Slide to pin: a finger lands on the strip, slides from the first thing towards the
# middle, holds still for 1.5 s and lets go; the thing it stopped on stays pinned (the
# Simulator's camera picks among the scene's real SAM shapes; a phone runs SAM live).
scenario 10c-slide-to-pin 16 "lensi:///?scene=cars&scrub=0.05,0.35,0.6"
# The same on moving footage: the store-aisle clip plays under the strip, which offers what
# tools/strip followed through it with the app's own Swift; the person held on stays pinned
# while they walk.
scenario 10f-slide-to-pin-video 18 "lensi:///?scene=aisle&scrub=0.05,0.6,0.88"
# Handheld and upright: a shaker bottle filmed walking round it, up close, back out, turning and
# down to 0.5x. The bottle is pinned from the strip and followed by EdgeTAM, the app's own Swift
# and Core ML (tools/edgetam), through the whole clip and round again.
scenario 10g-slide-to-pin-shaker 34 "lensi:///?scene=shaker&scrub=0.3,0.5"
# The app's own EdgeTAM on that clip, with the models it ships, on the Simulator's CPU: pinned on
# the bottle in the first frame and followed through every frame, as the phone follows a pinned
# thing. The app leaves what it found in Documents (lensi-edgetam.json) with the clip drawn as the
# phone draws it (lensi-edgetam.mp4, written by the app), and from then on its virtual camera
# shows its own run in place of the bundled tracks: that's what's filmed, once the run is done.
launch "lensi:///?scene=shaker&edgetam=shaker&scrub=0.3,0.5"
EDGE_START=$(date +%s)
if [ -n "$DATA" ]; then
  for _ in $(seq 1 180); do
    [ -s "$DATA/Documents/lensi-edgetam.json" ] && break
    kill -0 "$PID" 2>/dev/null || break
    sleep 5
  done
fi
tl "EdgeTAM in the app: waited $(( $(date +%s) - EDGE_START )) s"
rec 10h-edgetam-in-app
sleep 26
shot 10h-edgetam-in-app 0
alive 10h-edgetam-in-app
unrec
if [ -n "$DATA" ] && cp "$DATA/Documents/lensi-edgetam.json" "$OUT/" 2>/dev/null; then
  cp "$DATA/Documents/lensi-edgetam.mp4" "$OUT/edgetam-in-app.mp4" 2>/dev/null || echo "EdgeTAM in the app drew no video" >> "$OUT/problems.txt"
  found=$(python3 - "$OUT/lensi-edgetam.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("followed in %d of %d frames (every %d), median %.0f ms a frame, models loaded in %.0f ms" % (r["seen"], r["count"], r["every"], r["medianMs"], r["loadMs"]))
PY
)
  tl "EdgeTAM in the app: $found"
else
  tl "EdgeTAM in the app: nothing written"
  echo "EdgeTAM in the app wrote nothing" >> "$OUT/problems.txt"
  cp "$DATA"/Documents/lensi-edgetam-error.txt "$OUT/" 2>/dev/null || true
fi
# The zoom dial: turned to 2.7x and left up, so the shot shows the dial itself.
scenario 10d-zoom-dial 12 "lensi:///?scene=truck&zoom=2.7"
# Over the air, the whole path: this build fetches the JavaScript ota.yml published for its
# runtime from GitHub, restarts into it, and says which update it's running (the toast; the
# device log has AppDelegate's "starting from update").
scenario 10e-over-the-air 45 "lensi:///?scene=cars&ota=1"
# ...and a cold start after it runs that update instead of setting it aside. React Native asks
# AppDelegate for the bundle more than once a launch, and the mark the first ask leaves once
# counted against the second (plugins/withOTA.js): every update lasted one launch.
scenario 10e2-over-the-air-relaunch 12 "lensi:///?scene=cars"
OTA_SEEN=$(xcrun simctl spawn "$DEV" log show --last 2m --style compact --predicate 'process == "Lensi"' 2>/dev/null | grep "Lensi\[$PID:" | grep "over the air" || true)
tl "over the air, cold start: ${OTA_SEEN:-nothing logged}"
OTA_BROKEN=""
case "$OTA_SEEN" in
  *"set aside"*) OTA_BROKEN="a cold start set its own update aside" ;;
  *"starting from update"*) ;;
  *) OTA_BROKEN="a cold start after the update didn't start from it" ;;
esac
[ -z "$OTA_BROKEN" ] || echo "over the air: $OTA_BROKEN" >> "$OUT/problems.txt"

# The same job with steps: the Lensi server in mock mode answers it with a scripted
# plan (no model, no key), so the real app's panel, tags and outline can be filmed.
# The server runs on this Mac; the Simulator reaches it as localhost.
if [ -x ../server/node_modules/.bin/tsx ]; then
  (cd ../server && LENSI_MOCK=1 exec ./node_modules/.bin/tsx src/server.ts) > "$OUT/server.log" 2>&1 &
  SERVER=$!
  for _ in $(seq 1 40); do curl -fsS http://localhost:8787/health >/dev/null 2>&1 && break; sleep 0.5; done
  tl "mock server: $(curl -fsS http://localhost:8787/health 2>&1 | head -c 160)"
  scenario 10b-live-guide-server 56 "lensi:///?scene=truck&brain=cloud&guide=How%20do%20I%20check%20the%20tyre%20pressure%3F"
  kill "$SERVER" 2>/dev/null || true
  pkill -f "tsx src/server.ts" 2>/dev/null || true
else
  tl "mock server: no deps, skipped"
fi

scenario 11-memories 16 "lensi:///?memories=1"

# Render the share image inside the app and pull it out of the container. This run
# keeps the default brain, so it also exercises Apple Intelligence failing in the VM.
launch "lensi:///?demo=cars&export=1&brain=auto"
sleep 24
shot 12-export-source 0
alive export
if [ -n "$DATA" ]; then
  find "$DATA" -name 'lensi-*.jpg' -newer "$OUT/01-camera.png" -size +20k 2>/dev/null | head -3 | while read -r f; do cp "$f" "$OUT/13-export-$(basename "$f")"; echo "export $f"; done
  find "$DATA/Documents/lensi" -name capture.json 2>/dev/null | head -12 | while read -r f; do cp "$f" "$OUT/capture-$(basename "$(dirname "$f")").json"; done
  # Scripted steps that failed leave their error here (Release builds log no JS).
  cp "$DATA"/Documents/lensi-*-error.txt "$OUT/" 2>/dev/null || true
  tl "share images: $(find "$DATA" -name 'lensi-*.jpg' 2>/dev/null | wc -l | tr -d ' ')"

fi

# A real deep link into the running app, last (it may leave a system prompt up).
xcrun simctl openurl "$DEV" "lensi:///?demo=groceries&lens=shop" || echo "openurl failed" >> "$OUT/problems.txt"
shot 14-openurl-6s 6

xcrun simctl spawn "$DEV" log show --start "$START" --style compact --predicate 'process == "Lensi"' > "$OUT/device.log" 2>/dev/null || true
grep -iE "\[lensi\]|error|exception|fatal|failed to launch|terminat" "$OUT/device.log" | tail -400 > "$OUT/device-filtered.log" || true
# What the system said about the app: exits, signals, watchdog and memory kills.
xcrun simctl spawn "$DEV" log show --start "$START" --style compact \
  --predicate 'process != "Lensi" AND eventMessage CONTAINS[c] "com.vedantbhatt.lensi"' 2>/dev/null \
  | grep -iE "exit|terminat|crash|signal|kill|jetsam|watchdog|reason" | tail -200 > "$OUT/system-about-app.log" || true
# Crash reports for the app land on the host (any name; keep the ones about Lensi).
find "$HOME/Library/Logs/DiagnosticReports" -newermt "$START" -type f \( -name '*.ips' -o -name '*.crash' \) 2>/dev/null \
  | while read -r f; do grep -q "Lensi" "$f" 2>/dev/null && cp "$f" "$OUT/" && echo "crash report $f"; done
# Keep only the stderr files that say something, and pull out any uncaught errors.
for f in "$OUT"/stdout-*.txt "$OUT"/stderr-*.txt; do [ -s "$f" ] || rm -f "$f"; done
grep -h -iE "terminating|uncaught|exception|JSError|error" "$OUT"/stderr-*.txt 2>/dev/null | head -50 > "$OUT/uncaught.txt" || true
ls -la "$OUT"
# An iPhone that only ever runs its build's own JavaScript is a regression nothing else shows.
if [ -n "$OTA_BROKEN" ]; then
  echo "::error::Over the air: $OTA_BROKEN"
  exit 1
fi
