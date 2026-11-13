#!/usr/bin/env bash
# One synthetic workday through the REAL headless pipelines: transcription
# (golden transcripts, or real Parakeet with --real-asr), notes, digest,
# search, boundary review, and the health evaluator. Models are the scenario
# stub replaying committed GLM 5.3 Flash answers. Hermetic library and
# defaults suite; never touches the user's data.
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="${LOKALBOT_APP:-/Applications/LokalBot.app}/Contents/MacOS/LokalBot"
BUN="${LOKALBOT_TEST_BUN:-$(command -v bun || true)}"
[[ -x "$BIN" ]] || { echo "no app binary at $BIN"; exit 2; }
[[ -x "$BUN" ]] || { echo "Bun is required (LOKALBOT_TEST_BUN)"; exit 2; }
REAL_ASR=0; [[ "${1:-}" == "--real-asr" ]] && REAL_ASR=1
# Real Parakeet word error rate allowed across the day's meetings against the
# golden transcripts, ignoring case, punctuation, hyphens, and split or joined
# compounds. 2026-10-01 measured 1 edit in 70 words ("pare" for "pair").
MAX_WER="${LOKALBOT_DAY_MAX_WER:-0.10}"

# CI points LOKALBOT_DAY_ROOT at a folder it uploads when the run fails.
LIB=$(mktemp -d "${LOKALBOT_DAY_ROOT:-/tmp}/lokalbot-day.XXXXXX")
SUITE="me.dotenv.LokalBot.day-in-the-life.$$"
DAY=$(date -v-1d +%Y-%m-%d)
FAILED=0
fail() { echo "  ❌ $1"; FAILED=1; }
pass() { echo "  ✅ $1"; }
cleanup() {
  kill "${STUB_PID:-0}" 2>/dev/null || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  if [[ $FAILED -eq 0 ]]; then rm -rf "$LIB"; else echo "library kept for inspection: $LIB"; fi
}
trap cleanup EXIT

python3 "$ROOT_DIR/Scripts/test/seed_demo_library.py" --profile full-day --day "$DAY" "$LIB" >/dev/null

# macOS ships bash 3.2: start the stub in the background and read its port
# (first stdout line) from a file rather than via process substitution.
"$BUN" run "$ROOT_DIR/LokalBotTests/Fixtures/stub-openai.ts" > "$LIB/stub.out" 2>&1 &
STUB_PID=$!
PORT=""
for _ in $(seq 1 100); do
  PORT=$(head -1 "$LIB/stub.out" 2>/dev/null | tr -dc '0-9')
  [[ -n "$PORT" ]] && break
  sleep 0.1
done
[[ -n "$PORT" ]] || { echo "stub did not start"; FAILED=1; exit 1; }
scenario_flags=(); [[ $REAL_ASR -eq 1 ]] && scenario_flags=(--real-asr)
python3 "$ROOT_DIR/Scripts/test/day-in-the-life/scenario.py" "$ROOT_DIR/LokalBotTests/Fixtures/model-recordings" \
  z-ai/glm-5.3-flash ${scenario_flags[@]+"${scenario_flags[@]}"} > "$LIB/scenario.json"
curl -fsS -X POST --data @"$LIB/scenario.json" "http://127.0.0.1:$PORT/__scenario" >/dev/null

# Semantic search and multi-speaker diarization would start or download local
# models; the run exercises keyword search and per-track transcripts instead.
SETTINGS=$(printf '{"summarizerBackend":"OpenAI-compatible server","openAIBaseURL":"http://127.0.0.1:%s/v1","openAIModel":"z-ai/glm-5.3-flash","trackingEnabled":false,"dayDigestAutoEnabled":false,"dreamingEnabled":false,"autoSummarize":true,"semanticSearchEnabled":false,"multiSpeakerDiarization":false}' "$PORT")
defaults write "$SUITE" lokalbotv3.settings -data "$(printf '%s' "$SETTINGS" | xxd -p | tr -d '\n')"

export LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE"
[[ $REAL_ASR -eq 0 ]] && export LOKALBOT_TEST_GOLDEN_TRANSCRIPTS="$ROOT_DIR/LokalBotTests/Fixtures/day-in-the-life/golden-transcripts"

echo "== meetings: transcribe + notes =="
# Only the design review has recorded notes answers; the merged sprint
# planning exercises transcription of a two-source meeting.
DESIGN=$(ls -d "$LIB"/meetings/*/*/*-design-review)
SPRINT=$(ls -d "$LIB"/meetings/*/*/*-sprint-planning)
for folder in "$DESIGN" "$SPRINT"; do
  flags=(); [[ "$folder" == "$SPRINT" ]] && flags=(--no-summary)
  if "$BIN" --process "$folder" ${flags[@]+"${flags[@]}"} > "$LIB/process-$(basename "$folder").log" 2>&1; then
    pass "processed $(basename "$folder")"
  else
    fail "processing $(basename "$folder") (see $LIB/process-$(basename "$folder").log)"
  fi
  [[ -f "$folder/transcript.json" ]] || fail "no transcript for $(basename "$folder")"
done
if [[ $REAL_ASR -eq 1 ]]; then
  # The recorded notes answer quotes the golden wording, so ownership is only
  # asserted on golden runs. Here the drift signal is the word error rate.
  meetings=()
  for folder in "$DESIGN" "$SPRINT"; do
    name=$(basename "$folder")
    meetings+=("$folder" "$ROOT_DIR/LokalBotTests/Fixtures/day-in-the-life/golden-transcripts/${name#*-}")
  done
  if rate=$(python3 "$ROOT_DIR/Scripts/test/day-in-the-life/assertions.py" wer-day "$MAX_WER" "${meetings[@]}"); then
    pass "day word error rate $rate"
  else
    fail "day word error rate ${rate:-unavailable} exceeds $MAX_WER"
  fi
  python3 "$ROOT_DIR/Scripts/test/day-in-the-life/assertions.py" finished-notes "$DESIGN" \
    && pass "design review notes finished" || fail "design review notes did not finish"
else
  python3 "$ROOT_DIR/Scripts/test/day-in-the-life/assertions.py" owned-action "$DESIGN" \
    && pass "design review has an action owned by me" || fail "no action owned by me in the design review"
fi

echo "== boundary review keeps the meeting searchable =="
# 0–36 s keeps every line the recorded notes answer cites (the last ends at
# 35 s); trimming one makes that answer's evidence IDs invalid, which the app
# rightly rejects. The review still rewrites the transcript and reindexes.
"$BIN" --set-boundaries "$DESIGN" 0 36 > "$LIB/boundaries.log" 2>&1 \
  && pass "boundaries applied" || fail "boundary review failed (see $LIB/boundaries.log)"
# Output is captured first: with pipefail, grep -q exiting early could
# SIGPIPE the app and fail a check that matched.
found=$("$BIN" --search "caching layer" 2>/dev/null || true)
grep -q "Design review" <<<"$found" \
  && pass "meeting still found after review" || fail "meeting not found after boundary review"

# A boundary review revokes the day's derived evidence (its digest), so the
# digest is written after it, as the last derived artifact of the day.
echo "== digest =="
"$BIN" --digest "$DAY" > "$LIB/digest.log" 2>&1 && pass "digest written" || fail "digest failed (see $LIB/digest.log)"

echo "== search =="
found=$("$BIN" --search-screen "connection pool" 2>/dev/null || true)
grep -q "^\[screen\] Terminal" <<<"$found" && pass "screen text found" || fail "screen text not found"

echo "== health =="
"$BIN" --health --day "$DAY" --json > "$LIB/health.json" 2>/dev/null
python3 "$ROOT_DIR/Scripts/test/day-in-the-life/assertions.py" health "$LIB/health.json" \
  && pass "health checks pass with ≥60% digest coverage" || fail "health checks failed (see $LIB/health.json)"

exit $FAILED
