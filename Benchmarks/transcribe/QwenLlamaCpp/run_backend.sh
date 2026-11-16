#!/bin/bash
# Run one backend's job file and record load time, wall time and peak memory.
# Usage: run_backend.sh mlx|llama
# llama-server gets the flags GraniteSpeechEngine uses (-c 4096, --parallel 1,
# --cache-ram 256); LLAMA_CACHE_RAM=8192 reproduces llama.cpp's default host prompt cache.
set -euo pipefail
BACKEND=$1
OUT=${SPAN_BENCH_OUT:-/private/tmp/lokalbot-cloud-stt/span-length}
HARNESS=$OUT/dd/Build/Products/Release/qwen-span-harness
LLAMA_DIR=${LLAMA_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/Vendor/llama-cpp}
MODELS=$OUT/llama-models
LOG=$OUT/perf-$BACKEND${PERF_SUFFIX:-}
mkdir -p "$LOG"

if [ "$BACKEND" = llama ]; then
  if curl -sf http://127.0.0.1:8080/health > /dev/null; then
    echo "port 8080 is already serving; stop that server first" >&2; exit 1
  fi
  export ASR_BACKEND=llama LLAMA_MEDIA_MARKER='<__media__>' LLAMA_URL=http://127.0.0.1:8080
  started=$(python3 -c 'import time; print(time.time())')
  "$LLAMA_DIR/llama-server" -m "$MODELS/Qwen3-ASR-1.7B-Q8_0.gguf" --mmproj "$MODELS/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf" \
    -ngl 99 --host 127.0.0.1 --port 8080 --no-webui \
    -c "${LLAMA_CTX:-4096}" --parallel 1 --cache-ram "${LLAMA_CACHE_RAM:-256}" > "$LOG/server.log" 2>&1 &
  SERVER=$!
  trap 'kill $SERVER 2>/dev/null || true' EXIT
  until curl -sf http://127.0.0.1:8080/health > /dev/null; do
    kill -0 $SERVER 2>/dev/null || { echo "llama-server exited; see $LOG/server.log" >&2; exit 1; }
    sleep 0.1
  done
  python3 -c "import time; print(f'server ready in {time.time() - $started:.2f}s')" | tee "$LOG/load.txt"
  # RSS (includes the mmapped GGUF pages) every 0.5 s; footprint's own peak at the end.
  (while kill -0 $SERVER 2>/dev/null; do ps -o rss= -p $SERVER; sleep 0.5; done) > "$LOG/server-rss.txt" &
  SAMPLER=$!
fi

/usr/bin/time -l "$HARNESS" "$OUT/jobs-$BACKEND.json" 2> >(tee "$LOG/harness.txt" >&2)

if [ "$BACKEND" = llama ]; then
  footprint -p $SERVER > "$LOG/server-footprint.txt" 2>&1 || true
  kill $SAMPLER 2>/dev/null || true
  sort -n "$LOG/server-rss.txt" | tail -1 | awk '{printf "server peak RSS %.2f GiB\n", $1/1048576}' | tee -a "$LOG/load.txt"
  grep -E "phys_footprint(_peak)?:" "$LOG/server-footprint.txt" | tee -a "$LOG/load.txt"
fi
