#!/bin/bash
# Run LokalBot's headless pipeline over benchmark meeting folders, one at a time.
#
#   run.sh APP MODE FOLDER...
#     APP     path to a built "LokalBot Dev.app"
#     MODE    full (transcribe + summarize) | transcript (--no-summary) | summary (--summary-only)
#     FOLDER  folder names such as is1009a-ref, under $SUMMARY_BENCH_DIR/library/meetings/2026/10
#
# Each run is capped at CAP seconds (default 300) and finished folders are
# skipped, so a batch can be stopped and resumed. Keep batches short: back-to-back
# model runs heat a laptop. Runs use the Dev app's identity, their own defaults
# suite, and the benchmark library, never the user's meetings.
#
# Transcribe each condition with one build. A different unsigned build cannot
# read the Keychain key the first one sealed its speaker evidence with, so it
# stalls on a Keychain prompt after transcription; the cap ends such runs.
set -u
BENCH=${SUMMARY_BENCH_DIR:-/private/tmp/lokalbot-summary-bench}
LIB=$BENCH/library
CAP=${CAP:-300}
APP=$1; MODE=$2; shift 2
BIN="$APP/Contents/MacOS/LokalBot Dev"
case $MODE in
  full) ARGS=(); DONE=summary.md ;;
  transcript) ARGS=(--no-summary); DONE=transcript.json ;;
  summary) ARGS=(--summary-only); DONE=summary.md ;;
  *) echo "unknown mode $MODE"; exit 2 ;;
esac
for folder in "$@"; do
  d=$LIB/meetings/2026/10/$folder
  if [ -s "$d/$DONE" ]; then echo "skip $folder: $DONE exists"; continue; fi
  # Without a transcript, --summary-only would silently transcribe with this build.
  if [ "$MODE" = summary ] && [ ! -s "$d/transcript.json" ]; then echo "skip $folder: no transcript.json"; continue; fi
  # Speaker evidence is sealed with a Keychain key. An unsigned Dev build that
  # did not create the key waits on a Keychain prompt forever, and speaker
  # names do not change what the benchmark scores, so set it aside.
  if [ "$MODE" = summary ] && [ -d "$d/speaker-evidence" ]; then mv "$d/speaker-evidence" "$d.speaker-evidence"; fi
  start=$(date +%s)
  LOKALBOT_STORAGE_ROOT=$LIB LOKALBOT_DEFAULTS_SUITE=lokalbot.summary-bench \
    timeout "$CAP" "$BIN" --process "$d" "${ARGS[@]+"${ARGS[@]}"}" > "$d.$MODE.log" 2>&1
  rc=$?
  echo "$(date +%H:%M:%S) $MODE $folder exit=$rc $(( $(date +%s) - start ))s $(grep -h -- '--process:' "$d.$MODE.log" | sed 's/.*--process: //' | cut -c1-90)"
  # Headless runs leave the search embedder running after they exit.
  pkill -f "llama-server -m $LIB/models/" 2>/dev/null
done
