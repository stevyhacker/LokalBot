#!/bin/bash
# Films the after-meeting agent handoff on a Mac with a Debug LokalBot.app:
# a call ends, LokalBot transcribes and summarizes it, and each action the
# person took on starts as its own Agent Mode task.
#
#   LOKALBOT_APP=<Debug LokalBot.app> OPENROUTER_API_KEY=<key> \
#     Scripts/agent-handoff-demo/film.sh <out-dir>
#
# Transcription runs on this Mac (Parakeet); the summary and the agents use
# an OpenRouter model (DEMO_MODELS, first that answers with private routing).
# The library, settings suite and keychain are throwaway; the key is only
# written to that keychain. The window is recorded with screencapture, so the
# shell running this needs Screen Recording (hosted runners have it). Writes
# the cut (agent-handoff.mp4/.gif, stills) and evidence (logs, the meeting's
# notes, what the agents wrote) to <out-dir>.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$ROOT/Scripts/agent-handoff-demo"
APP=${LOKALBOT_APP:?set LOKALBOT_APP to a Debug LokalBot.app}
: "${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY}"
BIN="$APP/Contents/MacOS/LokalBot"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
WORK=$(cd "$(mktemp -d "${RUNNER_TEMP:-/tmp}/handoff-demo.XXXXXX")" && pwd -P)
LIB="$WORK/library"
WARM="$WORK/warmup"
FILM="$OUT/film"
SUITE="lokalbot.agent-handoff-demo.$$"
KEYCHAIN="$WORK/demo.keychain-db"
OLD_KEYCHAINS=$(security list-keychains -d user | tr -d '"' || true)
OLD_DEFAULT=$(security default-keychain -d user | tr -d '" ' || true)
APP_PID=""
RECORDER_PID=""
mkdir -p "$OUT/logs" "$FILM"

cleanup() {
  [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
  [[ -n "$RECORDER_PID" ]] && kill "$RECORDER_PID" 2>/dev/null || true
  pkill -f "$BIN" 2>/dev/null || true
  # shellcheck disable=SC2086
  security list-keychains -d user -s $OLD_KEYCHAINS >/dev/null 2>&1 || true
  [[ -n "$OLD_DEFAULT" ]] && security default-keychain -d user -s "$OLD_DEFAULT" >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Runs "$@" for at most $1 seconds; macOS has no timeout(1).
run_for() {
  local seconds=$1; shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= seconds )); then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"
}

echo "== Pillow for the cut =="
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q --disable-pip-version-check pillow
PY="$WORK/venv/bin/python"

echo "== OpenRouter model =="
MODEL=""
for candidate in ${DEMO_MODELS:-z-ai/glm-5.3-flash qwen/qwen3.8-flash}; do
  body=$(printf '{"model":"%s","max_tokens":16,"provider":{"data_collection":"deny"},"messages":[{"role":"user","content":"Reply with OK."}]}' "$candidate")
  status=$(curl -sS -o "$WORK/probe.json" -w '%{http_code}' https://openrouter.ai/api/v1/chat/completions \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" -H 'Content-Type: application/json' -d "$body" || echo 000)
  echo "$candidate: HTTP $status"
  if [[ "$status" == 200 ]]; then MODEL=$candidate; break; fi
  head -c 300 "$WORK/probe.json" 2>/dev/null; echo
done
[[ -n "$MODEL" ]] || { echo "no OpenRouter model answered"; exit 1; }
echo "using $MODEL" | tee "$OUT/logs/model.txt"

echo "== keychain =="
password=$(uuidgen)
security create-keychain -p "$password" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$password" "$KEYCHAIN"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN" $OLD_KEYCHAINS
security default-keychain -d user -s "$KEYCHAIN"
security add-generic-password -U -A -s "$BUNDLE_ID" -a openai-compatible-api-key \
  -w "$OPENROUTER_API_KEY" "$KEYCHAIN"

echo "== stage =="
python3 "$HERE/stage.py" library "$LIB"
python3 "$HERE/stage.py" settings "$SUITE" "$MODEL"
WARM_MEETING=$(python3 "$HERE/stage.py" warmup "$WARM")
export LOKALBOT_DEFAULTS_SUITE="$SUITE"

echo "== warm up transcription =="
# A user-initiated --process downloads Parakeet when the cache missed;
# the filmed call is then processed automatically, as after a recording.
if run_for 900 env LOKALBOT_STORAGE_ROOT="$WARM" "$BIN" --process "$WARM_MEETING" --no-summary \
    > "$OUT/logs/warmup.log" 2>&1 && [[ -f "$WARM_MEETING/transcript.json" ]]; then
  python3 -c 'import json,sys; [print(s.get("speaker"), s.get("text")) for s in json.load(open(sys.argv[1]))["segments"]]' \
    "$WARM_MEETING/transcript.json" || true
else
  echo "warm-up failed:"; tail -40 "$OUT/logs/warmup.log"; exit 1
fi

echo "== install Agent Mode =="
if ! run_for 600 env LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_TEST_FILM_SCRIPT=install-agent "$BIN" \
    > "$OUT/logs/install-agent.log" 2>&1; then
  echo "agent runtime install failed:"; tail -40 "$OUT/logs/install-agent.log"; exit 1
fi
grep 'film:' "$OUT/logs/install-agent.log" || true

echo "== film =="
read -r MEETING MEETING_FOLDER < <(python3 "$HERE/stage.py" meeting "$LIB")
echo "meeting $MEETING in $MEETING_FOLDER"
cp "$MEETING_FOLDER/mic.m4a" "$MEETING_FOLDER/system.m4a" "$OUT/logs/"
LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_TEST_FILM_SCRIPT=agent-handoff LOKALBOT_TEST_FILM_MEETING="$MEETING" \
  LOKALBOT_TEST_FILM_DIR="$FILM" "$BIN" > "$OUT/logs/app.log" 2>&1 &
APP_PID=$!
"$PY" "$HERE/record.py" "$FILM" > "$OUT/logs/record.log" 2>&1 &
RECORDER_PID=$!
mkdir -p "$OUT/logs/screen"
waited=0
until [[ -f "$FILM/done" ]]; do
  if ! kill -0 "$APP_PID" 2>/dev/null; then echo "LokalBot exited before the film finished"; break; fi
  if (( waited >= 1800 )); then echo "the film did not finish in 30 minutes"; break; fi
  # The whole screen once a minute, when this runner may record it.
  (( waited % 60 == 0 )) && screencapture -x "$OUT/logs/screen/$(printf %04d "$waited").png" 2>/dev/null || true
  sleep 5; waited=$((waited + 5))
done
touch "$FILM/stop"
wait "$RECORDER_PID" 2>/dev/null || true
RECORDER_PID=""
kill "$APP_PID" 2>/dev/null || true
wait "$APP_PID" 2>/dev/null || true
APP_PID=""
cat "$FILM/director.log" 2>/dev/null || true

echo "== evidence =="
mkdir -p "$OUT/meeting" "$OUT/agent-work"
for file in transcript.md summary.md outcomes.json; do
  [[ -f "$MEETING_FOLDER/$file" ]] && cp "$MEETING_FOLDER/$file" "$OUT/meeting/"
done
WORKSPACE="$LIB.agent-workspace"
[[ -d "$WORKSPACE/handoffs" ]] && cp -R "$WORKSPACE/handoffs/." "$OUT/agent-work/"
find "$OUT/agent-work" -type f | sed "s|$OUT/||" || true
cp "$LIB/debug.log" "$OUT/logs/debug.log" 2>/dev/null || true

if [[ -s "$FILM/frames.jsonl" ]]; then
  "$PY" "$HERE/edit.py" "$FILM" "$OUT"
fi
# Nothing written here may carry the key.
if grep -rqF "$OPENROUTER_API_KEY" "$OUT"; then
  echo "the key turned up in the output; removing it"; rm -rf "$OUT"; exit 1
fi
[[ -f "$FILM/done" && -f "$OUT/agent-handoff.mp4" ]]
