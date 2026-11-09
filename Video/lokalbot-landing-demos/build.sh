#!/bin/bash
# Cuts every clip in edit.json from a filming run's footage, in both appearances,
# with a WebP poster for each, on a machine with ffmpeg and Pillow:
#
#   build.sh <footage-dir> <out-dir> [clip...]
#
# <footage-dir> is the workflow's landing-demos-footage artifact. The Agents clip
# comes from agents/, not from here. LANDING_FONT names the keycap font where the
# system one is missing.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FOOTAGE=$1
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
shift 2
TAKES=$(mktemp -d)
trap 'rm -rf "$TAKES"' EXIT
python3 -I "$HERE/unpack.py" "$FOOTAGE" "$TAKES" >/dev/null
JOBS=$(mktemp)
python3 -I - "$HERE/edit.json" "$@" > "$JOBS" <<'PY'
import json, sys
clips = json.load(open(sys.argv[1]))["clips"]
wanted = sys.argv[2:] or list(clips)
for clip in wanted:
    for cut in clips[clip]["cuts"]:
        for theme in ("light", "dark"):
            print(clip, cut, theme)
PY
cut_one() {
  local clip=$1 cut=$2 theme=$3 name="$1-$2-$3"
  python3 -I "$HERE/compose.py" "$TAKES" "$clip" "$cut" "$theme" "$OUT/$name.mp4" --poster "$OUT/$name.png"
  python3 -I -c "from PIL import Image; import sys; Image.open(sys.argv[1]).save(sys.argv[2], quality=80, method=6)" "$OUT/$name.png" "$OUT/$name.webp"
  rm -f "$OUT/$name.png"
}
export -f cut_one
export HERE TAKES OUT
parallel --colsep ' ' -j "${JOBS_MAX:-8}" --halt now,fail=1 cut_one {1} {2} {3} :::: "$JOBS"
rm -f "$JOBS"
ls -la "$OUT"
