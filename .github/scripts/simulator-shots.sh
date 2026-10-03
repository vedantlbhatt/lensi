#!/usr/bin/env bash
# Boots an iOS Simulator, installs the app and drives it through deep links,
# taking screenshots along the way. Usage: simulator-shots.sh <Lensi.app> <outdir>
set -uo pipefail
APP="$1"
OUT="$2"
BUNDLE=com.vedantbhatt.lensi
mkdir -p "$OUT"

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c 'import json,sys; r=[x for x in json.load(sys.stdin)["runtimes"] if x["platform"]=="iOS" and x["isAvailable"]]; print(r[-1]["identifier"])')
TYPE=$(xcrun simctl list devicetypes -j | python3 -c 'import json,sys; d=json.load(sys.stdin)["devicetypes"]; names=[x["identifier"] for x in d if "iPhone" in x["name"] and "Pro" in x["name"] and "Max" not in x["name"]]; print(names[-1])')
echo "runtime=$RUNTIME type=$TYPE"
DEV=$(xcrun simctl create lensi "$TYPE" "$RUNTIME")
xcrun simctl boot "$DEV"
xcrun simctl bootstatus "$DEV" -b
xcrun simctl status_bar "$DEV" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$DEV" "$APP"

shot() { sleep "$2"; xcrun simctl io "$DEV" screenshot --type=png "$OUT/$1.png" >/dev/null 2>&1 && echo "shot $1"; }
launch() {
  xcrun simctl terminate "$DEV" "$BUNDLE" >/dev/null 2>&1 || true
  xcrun simctl launch "$DEV" "$BUNDLE" >/dev/null
}

# Grant what the app may ask for so no system alert covers the screenshots.
xcrun simctl privacy "$DEV" grant all "$BUNDLE" >/dev/null 2>&1 || true

launch
shot 01-camera 14
shot 02-camera-settled 3

xcrun simctl openurl "$DEV" "lensi:///?demo=cars"
shot 03-capture-0s 1
shot 04-capture-2s 2
shot 05-capture-5s 3
shot 06-capture-10s 5

launch
sleep 6
xcrun simctl openurl "$DEV" "lensi:///?demo=board&lens=learn"
shot 07-board-4s 4
shot 08-board-10s 6

launch
sleep 6
xcrun simctl openurl "$DEV" "lensi:///?demo=truck&lens=guide&ask=How%20do%20I%20check%20the%20tyre%20pressure%3F"
shot 09-guide-4s 4
shot 10-guide-10s 6

launch
sleep 6
xcrun simctl openurl "$DEV" "lensi:///?memories=1"
shot 11-memories 4

# Render the share image inside the app and pull it out of the container.
launch
sleep 6
xcrun simctl openurl "$DEV" "lensi:///?demo=cars&export=1"
sleep 14
shot 12-export-source 0
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE" data 2>/dev/null || true)
if [ -n "$DATA" ]; then
  find "$DATA" -name 'lensi-*.jpg' -newer "$OUT/01-camera.png" -size +20k 2>/dev/null | head -3 | while read -r f; do cp "$f" "$OUT/13-export-$(basename "$f")"; echo "export $f"; done
  find "$DATA/Documents/lensi" -name capture.json 2>/dev/null | head -3 | while read -r f; do cp "$f" "$OUT/capture-$(basename "$(dirname "$f")").json"; done
fi

xcrun simctl spawn "$DEV" log show --last 6m --style compact --predicate 'process == "Lensi"' > "$OUT/device.log" 2>/dev/null || true
grep -iE "lensi|error|exception|fatal" "$OUT/device.log" | tail -400 > "$OUT/device-filtered.log" || true
ls -la "$OUT"
