#!/bin/bash
# EdgeTAM on the bottle video (tools/edgetam/footage/shaker.mp4), as CI runs it on a Mac. From the
# repo root:
#
#   bash tools/edgetam/ci.sh
#
# 1. EdgeTAM's own video predictor (PyTorch) on every frame: the reference.
# 2. The four Core ML models (convert.py), compiled for the app: out/edgetam/models/*.mlmodelc.
# 3. Those models in parts.Tracker (Python) against the reference: the conversion's cost.
# 4. The app's own EdgeTAMTracker.swift (tools/edgetrack) on every frame: IoU with the reference,
#    shake, milliseconds, and the outline drawn on the video as the phone draws it.
# 5. The same clip played as the phone's camera (EDGETRACK_LIVE_MS): EdgeTAM only as often as the
#    app starts it, each answer late by the time it takes (60 ms, and 100 for a slower phone), the
#    outline moved on between answers; scored and drawn the same way.
set -o pipefail
OUT=out/edgetam
# The bottle in the first frame, in the clip's 540 x 960 pixels.
BOX="${EDGETAM_BOX:-220,520,375,712}"
mkdir -p "$OUT" build
# numpy 2.2: coremltools 9.0 casts one-element arrays to ints, which later numpy refuses.
python -m pip install --quiet torch==2.7.0 torchvision==0.22.0 coremltools==9.0 timm==1.0.15 "hydra-core>=1.3.2" \
  "iopath>=0.1.10" opencv-python-headless pillow numpy==2.2.6 tqdm || exit 1
if [ ! -d build/EdgeTAM ]; then
  git clone -q --depth 1 https://github.com/facebookresearch/EdgeTAM build/EdgeTAM || exit 1
  # Its backbone would fetch ImageNet weights that the checkpoint replaces anyway.
  sed -i '' 's/pretrained=True,/pretrained=False,/' build/EdgeTAM/sam2/modeling/backbones/timm.py
fi
EDGETAM="$PWD/build/EdgeTAM"
python tools/track/frames.py tools/edgetam/footage/shaker.mp4 footage/shaker 0 100000 || exit 1

# The reference takes ~15 minutes on CI's Mac: kept between runs (REF, cached by the workflow)
# while the clip and reference.py stay the same.
REF="${EDGETAM_REF:-build/edgetam-reference}"
if [ ! -f "$REF/times.json" ] && git fetch -q --depth 1 origin ci-edgetam 2>/dev/null; then
  # A previous run's, on the results branch (as a folder, or packed).
  rm -rf build/ci-edgetam && mkdir -p build/ci-edgetam
  if git archive FETCH_HEAD reference 2>/dev/null | tar -x -C build/ci-edgetam 2>/dev/null; then
    mkdir -p "$(dirname "$REF")" && rm -rf "$REF" && mv build/ci-edgetam/reference "$REF"
  elif git show FETCH_HEAD:reference.tgz > build/ci-edgetam/reference.tgz 2>/dev/null; then
    tar -xzf build/ci-edgetam/reference.tgz -C build/ci-edgetam && rm -rf "$REF" && mv build/ci-edgetam/edgetam-reference "$REF"
  fi
  [ -f "$REF/times.json" ] && echo "== Reference: a previous run's ($(ls "$REF" | grep -c png) masks)"
fi
if [ ! -f "$REF/times.json" ]; then
  echo "== Reference: EdgeTAM's own predictor (PyTorch)"
  python tools/edgetam/reference.py "$EDGETAM" "$PWD/footage/shaker" "$PWD/$REF" "$BOX" 2>&1 | grep -v "propagate in video" | tee "$OUT/reference.txt"
fi
REF="$PWD/$REF"

echo "== Core ML"
python tools/edgetam/convert.py "$EDGETAM" "$PWD/build/edgetam" 2>&1 | grep -v "%|" | tee "$OUT/convert.txt" || exit 1
mkdir -p "$OUT/models"
for m in EdgeTAMEncoder EdgeTAMPrompt EdgeTAMTrack EdgeTAMMemory; do
  xcrun coremlcompiler compile "build/edgetam/$m.mlpackage" "$OUT/models/" >/dev/null || exit 1
done
du -sh "$OUT"/models/* | tee "$OUT/model-sizes.txt"

echo "== The app's EdgeTAMTracker.swift (tools/edgetrack)"
I=app/modules/lensi-ar/ios
swiftc -O -o edgetrack tools/edgetrack/main.swift $I/EdgeTAMTracker.swift \
  $I/SAMSegmenter.swift $I/OutlineMath.swift $I/LiveTracker.swift $I/LiveFlow.swift $I/LiveWorld.swift $I/LiveSeg.swift \
  $I/Detector.swift $I/FlatFollow.swift || exit 1
LENSI_MODELS_DIR="$OUT/models" ./edgetrack footage/shaker "$OUT/swift.json" "$BOX" 2>&1 | tee "$OUT/swift.txt"
python tools/edgetam/report.py footage/shaker "$REF" "$OUT/swift.json" "$OUT" shaker outline shown 2>&1 | tee -a "$OUT/summary.txt"

echo "== As the phone's camera: EdgeTAM at the app's rate, each answer late"
for ms in 60 100; do
  EDGETRACK_LIVE_MS=$ms LENSI_MODELS_DIR="$OUT/models" ./edgetrack footage/shaker "$OUT/live$ms.json" "$BOX" 2>&1 | tee "$OUT/live$ms.txt" | tee -a "$OUT/summary.txt"
  python tools/edgetam/report.py footage/shaker "$REF" "$OUT/live$ms.json" "$OUT" "shaker-live$ms" live 2>&1 | tee -a "$OUT/summary.txt"
done
# The outline moved whole between answers (LiveFlow.carry, the app before LiveFlow.bend).
EDGETRACK_LIVE_MS=60 EDGETRACK_BEND=0 LENSI_MODELS_DIR="$OUT/models" ./edgetrack footage/shaker "$OUT/live60whole.json" "$BOX" 2>&1 | tail -1 | tee -a "$OUT/summary.txt"
REPORT_VIDEO=0 python tools/edgetam/report.py footage/shaker "$REF" "$OUT/live60whole.json" "$OUT" shaker-live60whole live 2>&1 | tee -a "$OUT/summary.txt"
# LiveFlow.bend's settings tried on the bottle (tools/track tries the same on DAVIS, bend-*).
for v in INSET=2 INSET=5 MOST=0.4 SIGMA=1 SIGMA=4 HOME=2; do
  name="live60-$(echo "$v" | tr 'A-Z=.' 'a-z--')"
  env "EDGETRACK_BEND_$v" EDGETRACK_LIVE_MS=60 LENSI_MODELS_DIR="$OUT/models" ./edgetrack footage/shaker "$OUT/$name.json" "$BOX" >/dev/null 2>&1
  REPORT_VIDEO=0 python tools/edgetam/report.py footage/shaker "$REF" "$OUT/$name.json" "$OUT" "shaker-$name" live 2>&1 | tee -a "$OUT/summary.txt"
done
# What the timing alone costs, with the outline moved perfectly between answers, or not at all.
python tools/edgetam/timing.py "$REF" "$OUT/swift.json" 2 2 3 3 2>&1 | tee -a "$OUT/summary.txt"

echo "== The Core ML models in parts.Tracker (Python)"
python tools/edgetam/check_coreml.py "$EDGETAM" "$PWD/build/edgetam" "$PWD/footage/shaker" "$REF" "$BOX" \
  "$PWD/$OUT/coreml-ALL.json" ALL 2>&1 | tee "$OUT/coreml-ALL.txt" | grep -v "^frame" | tee -a "$OUT/summary.txt"
# The same models with their weights in 8 bits a value (EDGETAM_WEIGHTS=int8): half the size. The
# app's tracker with them, scored the same way (EDGETAM_INT8=1; tried and turned down, README).
if [ "${EDGETAM_INT8:-0}" = 1 ] && echo "== Core ML, 8-bit weights" && EDGETAM_WEIGHTS=int8 python tools/edgetam/convert.py "$EDGETAM" "$PWD/build/edgetam-int8" 2>&1 | grep -v "%|" | tee "$OUT/convert-int8.txt"; then
  mkdir -p "$OUT/models-int8"
  for m in EdgeTAMEncoder EdgeTAMPrompt EdgeTAMTrack EdgeTAMMemory; do
    xcrun coremlcompiler compile "build/edgetam-int8/$m.mlpackage" "$OUT/models-int8/" >/dev/null
  done
  du -sh "$OUT"/models-int8/* | tee "$OUT/model-sizes-int8.txt"
  LENSI_MODELS_DIR="$OUT/models-int8" ./edgetrack footage/shaker "$OUT/swift-int8.json" "$BOX" 2>&1 | tee "$OUT/swift-int8.txt"
  REPORT_VIDEO=0 python tools/edgetam/report.py footage/shaker "$REF" "$OUT/swift-int8.json" "$OUT" shaker-int8 outline shown 2>&1 | tee -a "$OUT/summary.txt"
fi
# The reference's masks, for looking at the runs elsewhere.
tar -czf "$OUT/reference.tgz" -C "$(dirname "$REF")" "$(basename "$REF")"
exit 0
