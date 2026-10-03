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
# launch [lensi-url]: a cold start, optionally carrying a scripted run.
launch() {
  xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
  sleep 1
  if [ -n "${1:-}" ]; then
    SIMCTL_CHILD_LENSI_URL="$1" xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
  else
    xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
  fi
}
alive() { if running; then echo "alive after $1"; else echo "NOT RUNNING after $1" | tee -a "$OUT/problems.txt"; fi; }

# Grant what the app may ask for so no system alert covers the screenshots.
xcrun simctl privacy "$DEV" grant all "$BUNDLE" >/dev/null 2>&1 || true

launch
shot 01-camera 14
alive camera
shot 02-camera-settled 3

launch "lensi:///?demo=cars"
shot 03-capture-1s 1
shot 04-capture-3s 2
shot 05-capture-6s 3
shot 06-capture-12s 6
alive cars

launch "lensi:///?demo=board&lens=learn"
shot 07-board-5s 5
shot 08-board-12s 7
alive board

launch "lensi:///?demo=truck&lens=guide&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F"
shot 09-guide-5s 5
shot 10-guide-12s 7
alive guide

launch "lensi:///?memories=1"
shot 11-memories 6
alive memories

# Render the share image inside the app and pull it out of the container.
launch "lensi:///?demo=cars&export=1"
sleep 16
shot 12-export-source 0
alive export
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data 2>/dev/null || true)
if [ -n "$DATA" ]; then
  find "$DATA" -name 'lensi-*.jpg' -newer "$OUT/01-camera.png" -size +20k 2>/dev/null | head -3 | while read -r f; do cp "$f" "$OUT/13-export-$(basename "$f")"; echo "export $f"; done
  find "$DATA/Documents/lensi" -name capture.json 2>/dev/null | head -6 | while read -r f; do cp "$f" "$OUT/capture-$(basename "$(dirname "$f")").json"; done
fi

# A real deep link into the running app, last (it may leave a system prompt up).
xcrun simctl openurl "$DEV" "lensi:///?demo=groceries&lens=shop" || echo "openurl failed" >> "$OUT/problems.txt"
shot 14-openurl-6s 6

xcrun simctl spawn "$DEV" log show --start "$START" --style compact --predicate 'process == "Lensi"' > "$OUT/device.log" 2>/dev/null || true
grep -iE "\[lensi\]|error|exception|fatal|failed to launch|terminat" "$OUT/device.log" | tail -400 > "$OUT/device-filtered.log" || true
# Crash reports for the app land on the host.
find "$HOME/Library/Logs/DiagnosticReports" -name 'Lensi*' -newermt "$START" 2>/dev/null | head -5 | while read -r f; do cp "$f" "$OUT/"; echo "crash report $f"; done
ls -la "$OUT"
