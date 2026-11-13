#!/bin/zsh
# Day-digest benchmark: runs DayDigestBenchmarkTests over cases.json against
# the built-in model, served with the app's own llama-server settings
# (LlamaServer.swift, MainLLMRuntimePolicy) on a separate port.
#
#   Benchmarks/think/DayDigest/run.sh <label> [runs]
#
# Writes results/<label>.json plus the server and xcodebuild logs. Build the
# LokalBot scheme into .build/dd first; the test host and llama-server come
# from that build.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LABEL="${1:?usage: run.sh <label> [runs]}"
RUNS="${2:-1}"
MODEL="${LOKALBOT_DIGEST_BENCH_GGUF:-$HOME/Library/Application Support/me.dotenv.LokalBot/models/Qwen3.5-4B-Q4_K_M.gguf}"
SERVER="${LOKALBOT_DIGEST_BENCH_SERVER:-$ROOT/.build/dd/Build/Products/Debug/LokalBot.app/Contents/Resources/llama-cpp/llama-server}"
PORT="${LOKALBOT_DIGEST_BENCH_PORT:-18579}"
KEY="digest-bench"
OUT="$ROOT/Benchmarks/think/DayDigest/results/$LABEL.json"
mkdir -p "${OUT:h}"

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "port $PORT is in use; refusing to start a second server" >&2
  exit 1
fi

"$SERVER" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -c 32768 -ngl 99 --jinja --no-webui \
  --api-key "$KEY" --cache-ram 2048 --reasoning on > "$OUT.server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

curl -sf --retry 120 --retry-delay 1 --retry-connrefused --retry-all-errors \
  -H "Authorization: Bearer $KEY" "http://127.0.0.1:$PORT/health" > /dev/null

TEST_RUNNER_LOKALBOT_DIGEST_BENCH=1 \
TEST_RUNNER_LOKALBOT_DIGEST_BENCH_CASES="$ROOT/Benchmarks/think/DayDigest/cases.json" \
TEST_RUNNER_LOKALBOT_DIGEST_BENCH_OUT="$OUT" \
TEST_RUNNER_LOKALBOT_DIGEST_BENCH_URL="http://127.0.0.1:$PORT/v1" \
TEST_RUNNER_LOKALBOT_DIGEST_BENCH_KEY="$KEY" \
TEST_RUNNER_LOKALBOT_DIGEST_BENCH_RUNS="$RUNS" \
xcodebuild -project "$ROOT/LokalBot.xcodeproj" -scheme LokalBot -destination 'platform=macOS' \
  -derivedDataPath "$ROOT/.build/dd" -skip-testing:LokalBotUITests \
  -only-testing:LokalBotTests/DayDigestBenchmarkTests test > "$OUT.xcodebuild.log" 2>&1

echo "wrote $OUT"
