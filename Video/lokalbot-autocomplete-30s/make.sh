#!/bin/bash
# Renders the 30 s autocomplete demo: picture, soundtrack, MP4, GIF and poster.
#
#   ./make.sh [out-dir]          default: renders/ (gitignored)
#
# Needs Node with Playwright (headless Chromium), Python 3 with numpy and
# scipy, and ffmpeg. The footage frames come from build_edit.py.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/renders}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
NODE_PATH=${NODE_PATH:-$(npm root -g)}
export NODE_PATH
cd "$HERE"

echo "== cues and soundtrack =="
node render.cjs events "$OUT/events.json"
python3 audio.py edit.json "$OUT/events.json" "$OUT/soundtrack.wav"

echo "== picture =="
rm -rf "$OUT/frames"
node render.cjs frames "$OUT/frames" --workers "${WORKERS:-3}"

echo "== MP4 =="
# Two-pass EBU R128 to -14 LUFS, the level the social sites play at.
measured=$(ffmpeg -hide_banner -nostats -i "$OUT/soundtrack.wav" \
  -af loudnorm=I=-14:TP=-1.0:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<< "$measured"; }
norm="loudnorm=I=-14:TP=-1.0:LRA=11:measured_I=$(get input_i):measured_TP=$(get input_tp)"
norm="$norm:measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset):linear=true"
ffmpeg -y -hide_banner -loglevel error -framerate 30 -i "$OUT/frames/%05d.png" -i "$OUT/soundtrack.wav" \
  -map 0:v -map 1:a -af "$norm,aresample=48000" -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
  -profile:v high -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT/lokalbot-autocomplete-30s.mp4"

echo "== GIF and poster =="
ffmpeg -y -hide_banner -loglevel error -i "$OUT/lokalbot-autocomplete-30s.mp4" -vf \
  "fps=15,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=200:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  "$OUT/lokalbot-autocomplete-30s.gif"
cp "$OUT/frames/$(printf %05d "${POSTER_FRAME:-679}").png" "$OUT/lokalbot-autocomplete-30s-poster.png"
ls -lh "$OUT"/lokalbot-autocomplete-30s*
