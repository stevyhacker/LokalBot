#!/bin/bash
# Replay every AMI fixture through Live Radar with one Muse model.
#   META_API_KEY=... ./run.sh "/path/to/LokalBot Dev.app" muse-spark-1.3 [meeting ...]
# Writes $MUSE_RADAR_DATA/raw/<model>/<meeting>.jsonl and skips meetings that
# already have a summary line, so a stopped run resumes.
set -euo pipefail
APP="$1"
MODEL="$2"
shift 2
DATA="${MUSE_RADAR_DATA:-/private/tmp/lokalbot-muse-radar}"
BIN="$APP/Contents/MacOS/LokalBot Dev"
OUT="$DATA/raw/$MODEL"
PARALLEL="${PARALLEL:-6}"
: "${META_API_KEY:?set META_API_KEY}"
mkdir -p "$OUT"
if [ $# -eq 0 ]; then
  set -- $(cd "$DATA/fixtures" && ls *.json | sed 's/\.json$//')
fi
export BIN MODEL OUT DATA
printf '%s\n' "$@" | xargs -P "$PARALLEL" -n 1 bash -c '
  meeting="$1"
  file="$OUT/$meeting.jsonl"
  if [ -f "$file" ] && grep -q "\"summary\"" "$file"; then echo "$meeting: done"; exit 0; fi
  "$BIN" --radar-replay "$DATA/fixtures/$meeting.json" --model "$MODEL" > "$file.tmp" 2> "$OUT/$meeting.log" \
    && mv "$file.tmp" "$file" && echo "$meeting: $(grep -c "\"pass\"" "$file") passes" \
    || echo "$meeting: FAILED (see $OUT/$meeting.log)"
' _
