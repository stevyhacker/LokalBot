set -uo pipefail
cd "${BENCH_DIR:-/root/bench}"
export LD_LIBRARY_PATH=${BENCH_DIR:-/root/bench}/llama/llama-b12613:${BENCH_DIR:-/root/bench}/llama/cudart-llama-b12613-bin-ubuntu-cuda-12.8-x64:${LD_LIBRARY_PATH:-}
chmod +x notes_replay
mkdir -p results
overall_status=0
start_server() {
  if python3 -c 'import socket, sys; s = socket.socket(); s.settimeout(1); sys.exit(0 if s.connect_ex(("127.0.0.1", 18081)) == 0 else 1)'; then
    echo "port 18081 is already occupied before starting $2" >&2
    return 1
  fi
  ./llama/llama-b12613/llama-server -m models/$1 -c 32768 -ngl 99 --jinja --cache-ram 2048 --reasoning auto \
    --host 127.0.0.1 --port 18081 --api-key bench > results/server-$2.log 2>&1 &
  SERVER=$!
  for i in $(seq 1 180); do
    if ! kill -0 "$SERVER" 2>/dev/null; then
      wait "$SERVER" 2>/dev/null || true
      echo "server $2 exited before becoming ready" >&2
      return 1
    fi
    if curl -s 127.0.0.1:18081/health | grep -q '"ok"'; then
      kill -0 "$SERVER" 2>/dev/null && return 0
    fi
    sleep 1
  done
  kill "$SERVER" 2>/dev/null || true
  wait "$SERVER" 2>/dev/null || true
  echo "server $2 did not start" >&2
  return 1
}
run_condition() {
  name=$1 file=$2 model=$3 level=$4
  cond_status=0
  start_server $file $name || return 1
  python3 log_proxy.py 18080 http://127.0.0.1:18081 results/requests-$name.jsonl &
  PROXY=$!
  sleep 1
  for meeting in sample-en sample-sr ami-es2004a; do
    out=results/$name/$meeting
    rm -rf $out; mkdir -p $out
    echo "== $name $meeting"
    if ! timeout 1800 ./notes_replay inputs/$meeting/transcript.json $out http://127.0.0.1:18080/v1 bench $model $level 2> $out/stages.log | tail -1; then
      cond_status=1
    fi
    echo "{\"meeting\": \"$meeting\", \"boundary\": true, \"at\": $(date +%s)}" >> results/requests-$name.jsonl
  done
  kill "$PROXY" "$SERVER" 2>/dev/null || true
  wait "$PROXY" "$SERVER" 2>/dev/null || true
  return "$cond_status"
}
run_condition qwen-off Qwen3.5-4B-Q4_K_M.gguf qwen3.5-4b off || overall_status=1
run_condition qwen-default Qwen3.5-4B-Q4_K_M.gguf qwen3.5-4b automatic || overall_status=1
run_condition inkling-default Inkling-2-Mini-IQ4_NL.gguf inkling-2-mini automatic || overall_status=1
if [ "$overall_status" -eq 0 ]; then
  echo BENCH-DONE
else
  echo "BENCH-FAILED ($overall_status)" >&2
  exit "$overall_status"
fi
