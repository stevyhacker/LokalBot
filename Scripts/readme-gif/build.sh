#!/bin/bash
# Builds the README hero GIFs from takes recorded by film.sh.
#
#   Scripts/readme-gif/build.sh <takes-dir> [out-dir]   (default out-dir: Assets/hero)
#
# Writes lokalbot-demo-<appearance>.gif for each of APPEARANCES (default "light dark"). Needs ffmpeg and gifsicle.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TAKES=$(cd "$1" && pwd)
OUT=${2:-"$HERE/../../Assets/hero"}
mkdir -p "$OUT"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-readme-gif-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

swiftc -O -swift-version 5 "$HERE/compose.swift" -o "$WORK/compose"
fps=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['fps'])" "$HERE/edit.json")
for appearance in ${APPEARANCES:-light dark}; do
  "$WORK/compose" "$HERE/edit.json" "$appearance" "$TAKES" "$WORK/$appearance"
  # One palette for the whole loop, weighted toward what changes; ordered
  # dithering and rectangle diffs keep unchanged pixels identical between frames.
  ffmpeg -v error -y -framerate "$fps" -i "$WORK/$appearance/%05d.png" -filter_complex \
    "[0:v]split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
    -loop 0 "$WORK/$appearance.gif"
  gifsicle -O3 --lossy=${LOSSY:-20} "$WORK/$appearance.gif" -o "$OUT/lokalbot-demo-$appearance.gif"
  printf '%s: %s bytes\n' "$OUT/lokalbot-demo-$appearance.gif" "$(stat -f %z "$OUT/lokalbot-demo-$appearance.gif")"
done
