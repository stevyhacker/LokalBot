set -u
cd "${BENCH_DIR:-/root/bench}"
export LD_LIBRARY_PATH=${BENCH_DIR:-/root/bench}/llama/llama-b12613:${BENCH_DIR:-/root/bench}/llama/cudart-llama-b12613-bin-ubuntu-cuda-12.8-x64:${LD_LIBRARY_PATH:-}
chmod +x notes_replay
mkdir -p results
start_server() {
  ./llama/llama-b12613/llama-server -m models/$1 -c 32768 -ngl 99 --jinja --cache-ram 2048 --reasoning auto \
    --host 127.0.0.1 --port 18081 --api-key bench > results/server-$2.log 2>&1 &
  SERVER=$!
  for i in $(seq 1 180); do curl -s 127.0.0.1:18081/health | grep -q '"ok"' && return 0; sleep 1; done
  echo "server $2 did not start"; return 1
}
run_condition() {
  name=$1 file=$2 model=$3 level=$4
  start_server $file $name || return
  python3 log_proxy.py 18080 http://127.0.0.1:18081 results/requests-$name.jsonl &
  PROXY=$!
  sleep 1
  for meeting in sample-en sample-sr ami-es2004a; do
    out=results/$name/$meeting
    rm -rf $out; mkdir -p $out
    echo "== $name $meeting"
    timeout 1800 ./notes_replay inputs/$meeting/transcript.json $out http://127.0.0.1:18080/v1 bench $model $level 2> $out/stages.log | tail -1
    echo "{\"meeting\": \"$meeting\", \"boundary\": true, \"at\": $(date +%s)}" >> results/requests-$name.jsonl
  done
  kill $PROXY $SERVER; wait $SERVER 2>/dev/null
}
run_condition qwen-off Qwen3.5-4B-Q4_K_M.gguf qwen3.5-4b off
run_condition qwen-default Qwen3.5-4B-Q4_K_M.gguf qwen3.5-4b automatic
run_condition inkling-default Inkling-2-Mini-IQ4_NL.gguf inkling-2-mini automatic
echo BENCH-DONE
