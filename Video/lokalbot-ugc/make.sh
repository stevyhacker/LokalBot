#!/bin/bash
# Renders the UGC cut: timeline, soundtrack, picture, MP4, SRT and poster.
#
#   VOICE=liam-ott MUSIC=hype-a ./make.sh [out-dir]      default: renders/ (gitignored)
#
# Needs footage/ (prepare_footage.py), the voice takes in assets/voice/ and
# production/eleven-generation.json (tts_elevenlabs.py), the beat and effects
# in assets/sound/eleven/ (eleven_sound.py), Node with Playwright, Python 3
# with numpy, and ffmpeg.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/renders}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
NODE_PATH=${NODE_PATH:-$(npm root -g)}
export NODE_PATH
cd "$HERE"
NAME=lokalbot-ugc-${VOICE:-estimated}

echo "== timeline and soundtrack =="
python3 build_edit.py --voice "${VOICE:-}" --music "${MUSIC:-hype-a}"
python3 mix.py "$OUT/soundtrack.wav"

echo "== picture =="
if [[ ${KEEP_FRAMES:-} != 1 ]]; then
  rm -rf "$OUT/frames"
  node render.cjs frames "$OUT/frames" --workers "${WORKERS:-4}"
fi

echo "== MP4 =="
# Two-pass EBU R128 to -14 LUFS, the level the social apps play at.
# The limiter runs at 48 kHz, ahead of AAC, so the file stays under -1 dBTP.
measured=$(ffmpeg -hide_banner -nostats -i "$OUT/soundtrack.wav" \
  -af loudnorm=I=-14:TP=-1.0:LRA=11:print_format=json -f null - 2>&1 | sed -n '/^{/,/^}/p')
get() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])" <<< "$measured"; }
norm="loudnorm=I=-14:TP=-1.0:LRA=11:measured_I=$(get input_i):measured_TP=$(get input_tp)"
norm="$norm:measured_LRA=$(get input_lra):measured_thresh=$(get input_thresh):offset=$(get target_offset):linear=true"
ffmpeg -y -hide_banner -loglevel error -framerate 30 -i "$OUT/frames/%05d.png" -i "$OUT/soundtrack.wav" \
  -map 0:v -map 1:a -af "$norm,aresample=48000,alimiter=limit=0.7:attack=2:release=40:level=false" -c:v libx264 -preset slow -crf 17 -pix_fmt yuv420p \
  -profile:v high -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT/$NAME.mp4"

echo "== SRT and poster =="
python3 - "$OUT/$NAME.srt" <<'PY'
import json, sys
e = json.load(open('edit.json'))
caps = {s['id']: s['caption'] for s in json.load(open('narration.json'))['scenes']}
def ts(t):
    ms = int(round(t * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"
with open(sys.argv[1], 'w') as f:
    for i, v in enumerate(e['voice'], 1):
        # Each cue ends before the next starts, so players never stack two.
        nxt = e['voice'][i]['start'] - 0.05 if i < len(e['voice']) else e['duration']
        f.write(f"{i}\n{ts(v['start'] - 0.05)} --> {ts(min(v['end'] + 0.3, nxt - 0.02))}\n{caps[v['id']]}\n\n")
PY
# The poster is the hook with the evidence open: just after "remembers".
POSTER_FRAME=${POSTER_FRAME:-$(python3 -c "import json; e = json.load(open('edit.json'))
w = next(w for c in e['captions'] for w in c['words'] if w[0].startswith('remembers'))
print(round((w[1] + 0.4) * e['fps']) + 1)")}
cp "$OUT/frames/$(printf %05d "$POSTER_FRAME").png" "$OUT/$NAME-poster.png"
ls -lh "$OUT"/$NAME*
