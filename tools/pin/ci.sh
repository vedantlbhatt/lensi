#!/bin/bash
# ARKit pinning on real ARKit recordings (tools/pin), as CI runs it: fetches a few ARKitScenes
# validation scans (Apple, CC BY-NC-SA 4.0: iPad Pro captures with ARKit's own camera pose and
# lens for every frame, and 3D boxes drawn around the furniture by hand), runs the app's own
# outline code over each with ARKit's recorded poses, renders the videos.
# From the repo root on a Mac, with the compiled SAM models in models-all/:
#
#   bash tools/pin/ci.sh            (ARKIT_SCENES="id id ..." to choose the scans)
#
# Writes out/pin: scene-<id>.json, scene-<id>{,-compare,-arkit-compare}.mp4, summary.txt.
set -o pipefail
mkdir -p out/pin footage/arkit
BASE=https://docs-assets.developer.apple.com/ml-research/datasets/arkitscenes/v1/raw/Validation
IDS="${ARKIT_SCENES:-42444976 41069021 42899714 47331063 47333441 47429987 47895745 48458656}"
swiftc -O -o pin tools/pin/main.swift \
  app/modules/lensi-ar/ios/SAMSegmenter.swift app/modules/lensi-ar/ios/OutlineMath.swift app/modules/lensi-ar/ios/LiveTracker.swift \
  app/modules/lensi-ar/ios/LiveFlow.swift app/modules/lensi-ar/ios/LiveWorld.swift \
  app/modules/lensi-ar/ios/Analyzer.swift app/modules/lensi-ar/ios/Detector.swift || exit 1
for id in $IDS; do
  d="footage/arkit/$id"
  if [ ! -d "$d/vga_wide" ]; then
    mkdir -p "$d"
    ok=1
    for f in vga_wide.zip vga_wide_intrinsics.zip lowres_wide.traj "${id}_3dod_annotation.json"; do
      curl -fsSL --retry 2 --max-time 900 -o "$d/$f" "$BASE/$id/$f" || { echo "ARKitScenes $id: no $f"; ok=0; break; }
    done
    [ "$ok" = 1 ] || continue
    ls -la "$d"
    (cd "$d" && unzip -q -o vga_wide.zip && unzip -q -o vga_wide_intrinsics.zip && rm -f vga_wide.zip vga_wide_intrinsics.zip)
    # The zips may or may not hold their own folder.
    if [ ! -d "$d/vga_wide" ]; then mkdir -p "$d/vga_wide" && find "$d" -maxdepth 2 -name '*.png' -exec mv {} "$d/vga_wide/" \; ; fi
    if [ ! -d "$d/vga_wide_intrinsics" ]; then mkdir -p "$d/vga_wide_intrinsics" && find "$d" -maxdepth 2 -name '*.pincam' -exec mv {} "$d/vga_wide_intrinsics/" \; ; fi
    echo "ARKitScenes $id: $(ls "$d/vga_wide" | wc -l) frames, $(ls "$d/vga_wide_intrinsics" | wc -l) lenses, $(du -sh "$d" | cut -f1)"
  fi
  LENSI_MODELS_DIR=models-all ./pin "$d" out/pin "scene-$id" 2>&1 | tee -a out/pin/summary.txt \
    && python tools/pin/render.py "$d" "out/pin/scene-$id.json" out/pin || echo "FAIL $id"
  # 1-2 GB of frames a scan: gone once it's measured and drawn.
  rm -rf "$d/vga_wide"
done
exit 0
