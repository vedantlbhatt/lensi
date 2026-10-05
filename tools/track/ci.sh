#!/bin/bash
# Live SAM on real footage (tools/track), as CI runs it: fetches the clips, runs the harness on
# each (the app's own SAMSegmenter, LiveTracker and OutlineMath), renders the videos.
# From the repo root on a Mac, with the compiled SAM models in models-all/:
#
#   bash tools/track/ci.sh [run label to render as well as lensi@8]...
#
# Writes out/track: <clip>.json (scores, outlines), <clip>[-<label>]{,-compare}.mp4 (the run
# under SAM at a fixed spot), <clip>-vs-coast-at8-compare.mp4 (the app under the app before
# LiveFlow) and summary.txt.
set -o pipefail
mkdir -p out/track footage
# DAVIS 2017 (CC BY-NC 4.0): real videos with the moving object drawn by hand in every frame.
SEQS="car-roundabout car-shadow drift-straight dog parkour"
if [ ! -d footage/DAVIS/JPEGImages ]; then
  if curl -fsSL --max-time 600 -o davis.zip https://data.vision.ee.ethz.ch/csergi/share/davis/DAVIS-2017-trainval-480p.zip; then
    for s in $SEQS; do unzip -q -o davis.zip "DAVIS/JPEGImages/480p/$s/*" "DAVIS/Annotations/480p/$s/*" -d footage || echo "no $s"; done
  else
    echo "DAVIS unavailable"
  fi
  rm -f davis.zip
fi
# Intel IoT Devkit sample videos (CC BY 4.0): a car driving through a car park, from above, and
# bolts going by on a conveyor belt (a real part on the move).
for v in car-detection bolt-detection bolt-multi-size-detection; do
  [ -f "footage/$v.mp4" ] || curl -fsSL -o "footage/$v.mp4" "https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master/$v.mp4" || echo "$v unavailable"
done
[ -f footage/car-detection.mp4 ] && python tools/track/frames.py footage/car-detection.mp4 footage/carpark 75 110
[ -f footage/bolt-detection.mp4 ] && python tools/track/frames.py footage/bolt-detection.mp4 footage/bolt 38 63
[ -f footage/bolt-multi-size-detection.mp4 ] && python tools/track/frames.py footage/bolt-multi-size-detection.mp4 footage/bigbolt 1286 1362 2 960

swiftc -O -o track tools/track/main.swift app/modules/lensi-ar/ios/EdgeTAMTracker.swift \
  app/modules/lensi-ar/ios/SAMSegmenter.swift app/modules/lensi-ar/ios/OutlineMath.swift app/modules/lensi-ar/ios/LiveTracker.swift \
  app/modules/lensi-ar/ios/LiveFlow.swift app/modules/lensi-ar/ios/LiveSeg.swift app/modules/lensi-ar/ios/Analyzer.swift app/modules/lensi-ar/ios/Detector.swift || exit 1

# One clip: <frames> <masks or -> <name> [seed box]
clip() {
  LENSI_MODELS_DIR=models-all ./track "$1" "$2" out/track "$3" $4 2>&1 | tee -a out/track/summary.txt || { echo "FAIL $3"; return; }
  for label in lensi@8 "${LABELS[@]}"; do
    python tools/track/render.py "$1" "out/track/$3.json" out/track "$label" || echo "FAIL $3 $label"
  done
  # The app now next to the app before LiveFlow.
  python tools/track/render.py "$1" "out/track/$3.json" out/track lensi@8 coast@8 || echo "FAIL $3 vs coast@8"
}
LABELS=("$@")
for s in $SEQS; do
  [ -d "footage/DAVIS/JPEGImages/480p/$s" ] && clip "footage/DAVIS/JPEGImages/480p/$s" "footage/DAVIS/Annotations/480p/$s" "$s"
done
[ -d footage/carpark ] && clip footage/carpark - carpark 0.349,0.289,0.25,0.694
[ -d footage/bolt ] && clip footage/bolt - bolt 0.488,0.352,0.25,0.125
[ -d footage/bigbolt ] && clip footage/bigbolt - bigbolt 0.050,0.060,0.070,0.835
exit 0
