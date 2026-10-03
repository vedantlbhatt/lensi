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
OUT="$2"
BUNDLE=com.vedantbhatt.lensi
mkdir -p "$OUT"
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
running() { xcrun simctl spawn "$DEV" launchctl list 2>/dev/null | grep -q "UIKitApplication:$BUNDLE"; }
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
}
alive() { if running; then tl "alive after $1"; else tl "NOT RUNNING after $1"; echo "NOT RUNNING after $1" >> "$OUT/problems.txt"; fi; }

# Grant what the app may ask for so no system alert covers the screenshots.
xcrun simctl privacy "$DEV" grant all "$BUNDLE" >/dev/null 2>&1 || true

# Screen recordings, one mp4 per scenario (the morning demos).
REC=""
rec() { xcrun simctl io "$DEV" recordVideo --codec=h264 --force "$OUT/demo-$1.mp4" >/dev/null 2>&1 & REC=$!; sleep 1; }
unrec() { [ -n "$REC" ] && kill -INT "$REC" 2>/dev/null; wait "$REC" 2>/dev/null || true; REC=""; }

# Stock footage for the video pipeline: Intel IoT Devkit sample videos (CC BY 4.0),
# dropped into the app's Documents and opened with lensi:///?file=…
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data 2>/dev/null || true)
STOCK=(car-detection store-aisle-detection fruit-and-vegetable-detection)
if [ -n "$DATA" ]; then
  mkdir -p "$DATA/Documents"
  for v in "${STOCK[@]}"; do
    curl -fsSL --max-time 60 -o "$DATA/Documents/$v.mp4" "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/$v.mp4" \
      && tl "stock $v $(du -h "$DATA/Documents/$v.mp4" | cut -f1)" || tl "stock $v unavailable"
  done
fi

rec camera
launch
shot 01-camera 14
alive camera
shot 02-camera-settled 3
unrec

# A cold start takes ~6 s in CI's VM (JS bundle, fonts), so the first shot waits.
# Demo runs use the eyes-only brain: this VM can't run Apple Intelligence.
rec cars
launch "lensi:///?demo=cars&brain=vision"
shot 03-capture-7s 7
shot 04-capture-10s 3
shot 05-capture-14s 4
shot 06-capture-20s 6
alive cars
unrec

rec board
launch "lensi:///?demo=board&lens=learn&brain=vision"
shot 07-board-9s 9
shot 08-board-18s 9
alive board
unrec

rec guide
launch "lensi:///?demo=truck&lens=guide&brain=vision&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F"
shot 09-guide-9s 9
shot 10-guide-18s 9
alive guide
unrec

# The video pipeline on real footage: keyframes, then Vision, YOLO and SAM on each.
n=20
for v in "${STOCK[@]}"; do
  [ -n "$DATA" ] && [ -f "$DATA/Documents/$v.mp4" ] || continue
  case "$v" in store-*) lens=shop ;; fruit-*) lens=learn ;; *) lens=identify ;; esac
  rec "stock-$v"
  launch "lensi:///?file=$v.mp4&lens=$lens&brain=vision"
  shot "$n-stock-$v-10s" 10
  shot "$((n + 1))-stock-$v-22s" 12
  alive "stock-$v"
  unrec
  n=$((n + 2))
done

rec memories
launch "lensi:///?memories=1"
shot 11-memories 10
alive memories
unrec

# Render the share image inside the app and pull it out of the container. This run
# keeps the default brain, so it also exercises Apple Intelligence failing in the VM.
launch "lensi:///?demo=cars&export=1&brain=auto"
sleep 24
shot 12-export-source 0
alive export
if [ -n "$DATA" ]; then
  find "$DATA" -name 'lensi-*.jpg' -newer "$OUT/01-camera.png" -size +20k 2>/dev/null | head -3 | while read -r f; do cp "$f" "$OUT/13-export-$(basename "$f")"; echo "export $f"; done
  find "$DATA/Documents/lensi" -name capture.json 2>/dev/null | head -12 | while read -r f; do cp "$f" "$OUT/capture-$(basename "$(dirname "$f")").json"; done
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
