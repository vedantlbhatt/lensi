#!/bin/bash
# The app's pinning on real handheld walk-arounds (tools/walk), as CI runs it, on ARKitScenes
# validation scans (Apple, CC BY-NC-SA 4.0: iPad Pro captures with ARKit's own camera pose and
# lens for every frame, LiDAR depth, and 3D boxes drawn around the furniture by hand). From the
# repo root on a Mac, with the compiled SAM models in models-all/:
#
#   bash tools/walk/ci.sh            (ARKIT_SCENES="id id ..." to choose the scans,
#                                     WALK_PICK=n how many of them to run in full)
#
# First every scan's poses, lenses and boxes alone (a few MB each) say which have the best walk
# up close and back out; then the best WALK_PICK are fetched whole (1-2 GB each) and run.
# Writes out/walk: picks.txt, scene-<id>.json, scene-<id>*.mp4, summary.txt.
set -o pipefail
mkdir -p out/walk footage/arkit
BASE=https://docs-assets.developer.apple.com/ml-research/datasets/arkitscenes/v1/raw/Validation
# Every eighth validation scan, and the two with walks found before.
IDS="${ARKIT_SCENES:-42899714 48458656 41069021 41125696 41125763 41159525 41159555 41254269 41254425 42444954 42445028
42445984 42446079 42446137 42446522 42446541 42897538 42897559 42897667 42898497 42898570 42898826 42899461 42899679
42899698 42899725 44358435 44358455 44358536 45260898 45260928 45261144 45261575 45261631 45662944 45663105 45663164
47115474 47204554 47204605 47331071 47331322 47331644 47331668 47331989 47332893 47332911 47333441 47333916 47333932
47334103 47334234 47334256 47334380 47429925 47430001 47430033 47430051 47430479 47895353 47895534 47895556 47895745
48018345 48018367 48018387 48018732 48018966 48458430 48458647 48458665}"
PICK="${WALK_PICK:-10}"
swiftc -O -o walk tools/walk/main.swift \
  app/modules/lensi-ar/ios/SAMSegmenter.swift app/modules/lensi-ar/ios/OutlineMath.swift app/modules/lensi-ar/ios/LiveTracker.swift \
  app/modules/lensi-ar/ios/LiveFlow.swift app/modules/lensi-ar/ios/LiveWorld.swift app/modules/lensi-ar/ios/LiveSeg.swift \
  app/modules/lensi-ar/ios/Analyzer.swift app/modules/lensi-ar/ios/Detector.swift || exit 1

# One of a scan's zips, unpacked into <scan>/<asset>/ (the zips may or may not hold their own folder).
fetch() {
  local d="$1" id="$2" asset="$3"
  [ -d "$d/$asset" ] && [ -n "$(ls "$d/$asset" | head -1)" ] && return 0
  if ! curl -fsSL --retry 2 --max-time 900 -o "$d/$asset.zip" "$BASE/$id/$asset.zip"; then
    echo "ARKitScenes $id: no $asset.zip"
    rm -f "$d/$asset.zip"
    return 1
  fi
  rm -rf "$d/$asset.tmp" && mkdir -p "$d/$asset.tmp"
  unzip -q -o "$d/$asset.zip" -d "$d/$asset.tmp" && rm -f "$d/$asset.zip"
  if [ -d "$d/$asset.tmp/$asset" ]; then
    rm -rf "$d/$asset" && mv "$d/$asset.tmp/$asset" "$d/$asset"
  else
    mkdir -p "$d/$asset"
    find "$d/$asset.tmp" -type f \( -name '*.png' -o -name '*.pincam' \) -exec mv {} "$d/$asset/" \;
  fi
  rm -rf "$d/$asset.tmp"
}

# Pass 1: which scans have a walk up close and back out.
: > out/walk/picks.txt
for id in $IDS; do
  d="footage/arkit/$id"
  mkdir -p "$d"
  ok=1
  for f in lowres_wide.traj "${id}_3dod_annotation.json"; do
    [ -s "$d/$f" ] || curl -fsSL --retry 2 --max-time 300 -o "$d/$f" "$BASE/$id/$f" || { echo "ARKitScenes $id: no $f"; ok=0; break; }
  done
  [ "$ok" = 1 ] && fetch "$d" "$id" vga_wide_intrinsics || continue
  ./walk "$d" out/walk "scene-$id" 240 select 2>&1 | grep '^PICK' | tee -a out/walk/picks.txt
done
BEST=$(sort -k3 -g -r out/walk/picks.txt | awk '$3 > 0 {print $2}' | sed 's/^scene-//' | head -n "$PICK")
echo "Running in full: $BEST"

# Pass 2: the best, whole.
for id in $BEST; do
  d="footage/arkit/$id"
  fetch "$d" "$id" vga_wide || continue
  fetch "$d" "$id" lowres_depth
  echo "ARKitScenes $id: $(ls "$d/vga_wide" | wc -l) frames, $(ls "$d/vga_wide_intrinsics" 2>/dev/null | wc -l) lenses, $(ls "$d/lowres_depth" 2>/dev/null | wc -l) depth maps, $(du -sh "$d" | cut -f1)"
  LENSI_MODELS_DIR=models-all ./walk "$d" out/walk "scene-$id" 2>&1 | tee -a out/walk/summary.txt \
    && python tools/walk/render.py "$d" "out/walk/scene-$id.json" out/walk || echo "FAIL $id"
  # 1-2 GB of frames a scan: gone once it's measured and drawn.
  rm -rf "$d/vga_wide" "$d/lowres_depth"
done
exit 0
