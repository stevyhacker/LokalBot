#!/usr/bin/env bash
set -euo pipefail
root=/workspace/pr354-validation
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
vulkaninfo --summary > "$root/vulkan-before-benchmark.txt" 2>&1
rg 'deviceName.*RTX 5090' "$root/vulkan-before-benchmark.txt"
nvidia-smi --query-gpu=timestamp,name,utilization.gpu,memory.used,power.draw --format=csv -l 1 > "$root/gpu-usage.csv" &
monitor=$!
trap 'code=$?; kill "$monitor" 2>/dev/null || true; echo "$code" > /workspace/pr354-validation/benchmark-exit-code.txt' EXIT
for run in 1 2 3; do
  case "$run" in
    1) order='master vulkan cuda';;
    2) order='cuda vulkan master';;
    3) order='vulkan master cuda';;
  esac
  for mode in $order; do
    backend=$mode
    binary="$root/autocomplete-eval-pr"
    if test "$mode" = master; then backend=vulkan; binary="$root/autocomplete-eval-master"; fi
    python3 /tmp/lokalbot-5090-matched-proof.py "$mode" "$backend" "$run" > "$root/$mode-$run-proof.log" 2>&1 &
    proof=$!
    RUST_LOG=warn,lokalbot_ai::runtime=info timeout 600s "$binary" \
      "$root/autocomplete-$mode" --backend "$backend" --model lfm2.5-1.2b-instruct --debounce 160 --key-ms 140 \
      > "$root/$mode-$run.log" 2>&1
    wait "$proof"
    tail -n 1 "$root/$mode-$run.log"
  done
done
git -C /workspace/lokalbot status --porcelain > "$root/source-status-after.txt"
git -C /workspace/master status --porcelain > "$root/master-source-status-after.txt"
