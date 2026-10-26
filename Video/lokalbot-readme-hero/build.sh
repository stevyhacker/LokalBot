#!/bin/bash
# Builds the README hero GIF from the filmed takes and the previous hero's live scenes.
#
#   Video/lokalbot-readme-hero/build.sh <takes-dir> [out.gif]   (default: Assets/hero/lokalbot-demo-light.gif)
#
# Needs python3 with Pillow, ffmpeg, and gifsicle.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TAKES=$(cd "$1" && pwd)
OUT=${2:-"$REPO/Assets/hero/lokalbot-demo-light.gif"}
# The last hero built by Scripts/readme-gif: its live autocomplete and dictation scenes are reused.
LEGACY_REV=43d72b9
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-readme-hero.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir "$WORK/legacy"
git -C "$REPO" show "$LEGACY_REV:Assets/hero/lokalbot-demo-light.gif" > "$WORK/legacy.gif"
ffmpeg -v error -y -i "$WORK/legacy.gif" -vf fps=20 -start_number 0 "$WORK/legacy/%04d.png"
python3 "$HERE/compose.py" "$TAKES" "$WORK/legacy" "$WORK/frames"
# One palette for the whole loop, no dithering: flat UI and text stay crisp, and
# rectangle diffs keep unchanged pixels identical between frames.
ffmpeg -v error -y -framerate 15 -i "$WORK/frames/%04d.png" -filter_complex \
  "pad=iw+2:ih+2:1:1:color=0xD0D7DE,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  -loop 0 "$WORK/reel.gif"
gifsicle -O3 "$WORK/reel.gif" -o "$OUT"
printf '%s: %s bytes\n' "$OUT" "$(stat -f %z "$OUT")"
