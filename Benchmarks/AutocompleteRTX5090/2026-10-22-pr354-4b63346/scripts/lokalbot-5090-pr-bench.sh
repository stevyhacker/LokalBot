#!/usr/bin/env bash
set -euo pipefail
root=/workspace/pr354-validation
export PATH="/root/.cargo/bin:$PATH"
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
cd /workspace/lokalbot/LinuxWindows
nvidia-smi --query-gpu=timestamp,name,utilization.gpu,memory.used,power.draw --format=csv -l 1 > "$root/gpu-usage.csv" &
monitor=$!
trap 'code=$?; kill "$monitor" 2>/dev/null || true; echo "$code" > /workspace/pr354-validation/benchmark-exit-code.txt' EXIT
for run in 1 2 3; do
  if test "$run" = 2; then order='cuda vulkan'; else order='vulkan cuda'; fi
  for backend in $order; do
    python3 /tmp/lokalbot-5090-pr-proof.py "$backend" "$run" > "$root/$backend-$run-proof.log" 2>&1 &
    proof=$!
    RUST_LOG=warn,lokalbot_ai::runtime=info timeout 900s target/release/examples/autocomplete_eval \
      "$root/autocomplete-$backend" --backend "$backend" --model lfm2.5-1.2b-instruct --debounce 160 --key-ms 140 \
      > "$root/$backend-$run.log" 2>&1
    wait "$proof"
    tail -n 1 "$root/$backend-$run.log"
  done
done
git status --porcelain > "$root/source-status-after.txt"
