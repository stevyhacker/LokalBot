#!/bin/bash
# Render one film from its composition: look → sound events → mix → draft → onetake's verify.
#   ONETAKE=<onetake checkout> tools/build.sh <pullout|streams|machine> [--final]
# Needs the narration audio from tools/voice.sh. Drafts are 1920×1080 at 30 fps; --final renders 3840×2160 at 60 fps,
# only for an accepted cut. Output: <film>/renders/draft.mp4 (ignored by git; accepted drafts are copied to drafts/).
set -euo pipefail
: "${ONETAKE:?set ONETAKE to a checkout of github.com/feitangyuan/onetake (see README)}"
cd "$(dirname "$0")/.."
D=${1:?film: pullout, streams or machine}; shift
PY=(uv run -q --no-project --python 3.12)
PW=(--with playwright==1.62.0)          # the Playwright release whose Chromium build the render was made with
case $D in
  pullout) SHOTS=0,2.85,8.75,10.45,13.75,15.0,16.25,17.85,21.1,22.15,25.45,26.15 ;;
  streams) SHOTS=0,1.9,4.06,6.74,9.62,12.3,14.16,15.3,16.23,17.14,19.6,24.4,24.9 ;;
  machine) SHOTS=0,0.55,2.03,3.0,5.64,7.3,9.8,11.06,12.96,14.74,17.4,20.76,21.9,23.05 ;;
  *) echo "unknown film: $D" >&2; exit 2 ;;
esac
cp "$ONETAKE/lib/motion.js" "$D/motion.js"
"${PY[@]}" --with pillow --with numpy --with fonttools --with brotli python "$ONETAKE/scripts/look.py" apply "$D/look.json" "$D/comp.html"
"${PY[@]}" "${PW[@]}" python tools/dump_events.py "$D/comp.html"
"${PY[@]}" --with numpy --with scipy python tools/mix.py "$D"
mkdir -p "$D/renders"
"${PY[@]}" "${PW[@]}" --with numpy --with pillow python "$ONETAKE/scripts/render.py" "$D/comp.html" --out "$D/renders/draft.mp4" --sfx "$D/mix.wav" "$@"
"${PY[@]}" "${PW[@]}" --with numpy --with pillow --with scipy --with opencv-python --with matplotlib \
  python "$ONETAKE/scripts/verify_promo.py" "$D/renders/draft.mp4" --comp "$D/comp.html" --shots "$SHOTS"
