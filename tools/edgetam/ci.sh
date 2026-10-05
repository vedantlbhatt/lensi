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
set -o pipefail
OUT=out/edgetam
# The bottle in the first frame, in the clip's 540 x 960 pixels.
BOX="${EDGETAM_BOX:-220,520,375,712}"
mkdir -p "$OUT" build
python -m pip install --quiet torch==2.7.0 torchvision==0.22.0 coremltools==9.0 timm==1.0.15 "hydra-core>=1.3.2" \
  "iopath>=0.1.10" opencv-python-headless pillow numpy tqdm || exit 1
if [ ! -d build/EdgeTAM ]; then
  git clone -q --depth 1 https://github.com/facebookresearch/EdgeTAM build/EdgeTAM || exit 1
  # Its backbone would fetch ImageNet weights that the checkpoint replaces anyway.
  sed -i '' 's/pretrained=True,/pretrained=False,/' build/EdgeTAM/sam2/modeling/backbones/timm.py
fi
EDGETAM="$PWD/build/EdgeTAM"
python tools/track/frames.py tools/edgetam/footage/shaker.mp4 footage/shaker 0 100000 || exit 1

echo "== Reference: EdgeTAM's own predictor (PyTorch)"
python tools/edgetam/reference.py "$EDGETAM" "$PWD/footage/shaker" "$PWD/$OUT/reference" "$BOX" 2>&1 | tee "$OUT/reference.txt"

echo "== Core ML"
python tools/edgetam/convert.py "$EDGETAM" "$PWD/build/edgetam" 2>&1 | tee "$OUT/convert.txt" || exit 1
mkdir -p "$OUT/models"
for m in EdgeTAMEncoder EdgeTAMPrompt EdgeTAMTrack EdgeTAMMemory; do
  xcrun coremlcompiler compile "build/edgetam/$m.mlpackage" "$OUT/models/" >/dev/null || exit 1
done
du -sh "$OUT"/models/* | tee "$OUT/model-sizes.txt"

echo "== The app's EdgeTAMTracker.swift (tools/edgetrack)"
I=app/modules/lensi-ar/ios
swiftc -O -o edgetrack tools/edgetrack/main.swift $I/EdgeTAMTracker.swift \
  $I/SAMSegmenter.swift $I/OutlineMath.swift $I/LiveTracker.swift $I/LiveFlow.swift $I/LiveWorld.swift $I/LiveSeg.swift \
  $I/Detector.swift || exit 1
LENSI_MODELS_DIR="$OUT/models" ./edgetrack footage/shaker "$OUT/swift.json" "$BOX" 2>&1 | tee "$OUT/swift.txt"
python tools/edgetam/report.py footage/shaker "$OUT/reference" "$OUT/swift.json" "$OUT" shaker outline 2>&1 | tee -a "$OUT/summary.txt"

echo "== The Core ML models in parts.Tracker (Python)"
for units in ALL CPU_ONLY; do
  python tools/edgetam/check_coreml.py "$EDGETAM" "$PWD/build/edgetam" "$PWD/footage/shaker" "$PWD/$OUT/reference" "$BOX" \
    "$PWD/$OUT/coreml-$units.json" "$units" 2>&1 | tee "$OUT/coreml-$units.txt" | grep -v "^frame" | tee -a "$OUT/summary.txt"
done
# The reference's masks (a few MB of PNGs) are only needed here.
tar -czf "$OUT/reference.tgz" -C "$OUT" reference && rm -rf "$OUT/reference"
exit 0
