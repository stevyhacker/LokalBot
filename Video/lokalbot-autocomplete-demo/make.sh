#!/bin/bash
# Renders the autocomplete demo: picture, soundtrack, MP4, GIF, poster and captions.
#
#   ./make.sh [out-dir]          default: renders/ (gitignored)
#
# Needs Node with Playwright (headless Chromium), Python 3 with numpy and
# scipy, and ffmpeg. The footage frames come from build_edit.py; the voice,
# music and effects from the voice assets branch (see README.md).
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
# KEEP_FRAMES=1 reuses frames already rendered (after re-rendering a span with
# `node render.cjs frames renders/frames --from s --to s`).
if [[ ${KEEP_FRAMES:-} != 1 ]]; then
  rm -rf "$OUT/frames"
  node render.cjs frames "$OUT/frames" --workers "${WORKERS:-3}"
fi

echo "== MP4 =="
# Two-pass EBU R128 to -14 LUFS, the level the social sites play at.
measured=$(ffmpeg -hide_banner -nostats -i "$OUT/soundtrack.wav" \
  -af loudnorm=I=-14:TP=-1.0:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<< "$measured"; }
norm="loudnorm=I=-14:TP=-1.0:LRA=11:measured_I=$(get input_i):measured_TP=$(get input_tp)"
norm="$norm:measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset):linear=true"
ffmpeg -y -hide_banner -loglevel error -framerate 30 -i "$OUT/frames/%05d.png" -i "$OUT/soundtrack.wav" \
  -map 0:v -map 1:a -af "$norm,aresample=48000" -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
  -profile:v high -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT/lokalbot-autocomplete-demo.mp4"

echo "== GIF and poster =="
# 640 px at 12 fps stays under the 15 MB X allows for a GIF.
ffmpeg -y -hide_banner -loglevel error -i "$OUT/lokalbot-autocomplete-demo.mp4" -vf \
  "fps=12,scale=640:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  "$OUT/lokalbot-autocomplete-demo.gif"
# The hook's last frame: the logo and "Autocomplete for your whole Mac."
cp "$OUT/frames/$(printf %05d "${POSTER_FRAME:-166}").png" "$OUT/lokalbot-autocomplete-demo-poster.png"

echo "== captions =="
# Every spoken line, for sites that take a caption file (YouTube).
python3 - "$OUT/lokalbot-autocomplete-demo.srt" <<'PY'
import json, sys
def stamp(t):
    ms = round(t * 1000)
    return f'{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}'
subs = json.load(open('edit.json'))['subtitles']
with open(sys.argv[1], 'w') as f:
    for i, (a, b, text) in enumerate(subs, 1):
        f.write(f'{i}\n{stamp(a)} --> {stamp(b)}\n{text}\n\n')
PY
ls -lh "$OUT"/lokalbot-autocomplete-demo*
