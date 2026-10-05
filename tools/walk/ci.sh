#!/bin/bash
# The app's pinning on real handheld walk-arounds (tools/walk), as CI runs it: fetches a few
# ARKitScenes validation scans (Apple, CC BY-NC-SA 4.0: iPad Pro captures with ARKit's own
# camera pose and lens for every frame, LiDAR depth, and 3D boxes drawn around the furniture by
# hand), runs the app's own outline code over the stretch of each where the camera goes from far
# to close and back, renders the videos. From the repo root on a Mac, with the compiled SAM
# models in models-all/:
#
#   bash tools/walk/ci.sh            (ARKIT_SCENES="id id ..." to choose the scans)
#
# Writes out/walk: scene-<id>.json, scene-<id>{,-before-after,-lidar,-depth}.mp4, summary.txt.
set -o pipefail
mkdir -p out/walk footage/arkit
BASE=https://docs-assets.developer.apple.com/ml-research/datasets/arkitscenes/v1/raw/Validation
IDS="${ARKIT_SCENES:-42444976 41069021 42899714 47331063 47333441 47429987 47895745 48458656}"
swiftc -O -o walk tools/walk/main.swift \
  app/modules/lensi-ar/ios/SAMSegmenter.swift app/modules/lensi-ar/ios/OutlineMath.swift app/modules/lensi-ar/ios/LiveTracker.swift \
  app/modules/lensi-ar/ios/LiveFlow.swift app/modules/lensi-ar/ios/LiveWorld.swift app/modules/lensi-ar/ios/LiveSeg.swift \
  app/modules/lensi-ar/ios/Analyzer.swift app/modules/lensi-ar/ios/Detector.swift || exit 1
for id in $IDS; do
  d="footage/arkit/$id"
  mkdir -p "$d"
  ok=1
  for f in lowres_wide.traj "${id}_3dod_annotation.json"; do
    [ -s "$d/$f" ] || curl -fsSL --retry 2 --max-time 300 -o "$d/$f" "$BASE/$id/$f" || { echo "ARKitScenes $id: no $f"; ok=0; break; }
  done
  [ "$ok" = 1 ] || continue
  for asset in vga_wide vga_wide_intrinsics lowres_depth; do
    [ -d "$d/$asset" ] && [ -n "$(ls "$d/$asset" | head -1)" ] && continue
    if ! curl -fsSL --retry 2 --max-time 900 -o "$d/$asset.zip" "$BASE/$id/$asset.zip"; then
      echo "ARKitScenes $id: no $asset.zip"
      rm -f "$d/$asset.zip"
      continue
    fi
    rm -rf "$d/$asset.tmp" && mkdir -p "$d/$asset.tmp"
    unzip -q -o "$d/$asset.zip" -d "$d/$asset.tmp" && rm -f "$d/$asset.zip"
    # The zips may or may not hold their own folder.
    if [ -d "$d/$asset.tmp/$asset" ]; then
      rm -rf "$d/$asset" && mv "$d/$asset.tmp/$asset" "$d/$asset"
    else
      mkdir -p "$d/$asset"
      find "$d/$asset.tmp" -type f \( -name '*.png' -o -name '*.pincam' \) -exec mv {} "$d/$asset/" \;
    fi
    rm -rf "$d/$asset.tmp"
  done
  if [ ! -d "$d/vga_wide" ]; then echo "ARKitScenes $id: no frames"; continue; fi
  echo "ARKitScenes $id: $(ls "$d/vga_wide" | wc -l) frames, $(ls "$d/vga_wide_intrinsics" 2>/dev/null | wc -l) lenses, $(ls "$d/lowres_depth" 2>/dev/null | wc -l) depth maps, $(du -sh "$d" | cut -f1)"
  LENSI_MODELS_DIR=models-all ./walk "$d" out/walk "scene-$id" 2>&1 | tee -a out/walk/summary.txt \
    && python tools/walk/render.py "$d" "out/walk/scene-$id.json" out/walk || echo "FAIL $id"
  # 1-2 GB of frames a scan: gone once it's measured and drawn.
  rm -rf "$d/vga_wide" "$d/lowres_depth"
done
exit 0
