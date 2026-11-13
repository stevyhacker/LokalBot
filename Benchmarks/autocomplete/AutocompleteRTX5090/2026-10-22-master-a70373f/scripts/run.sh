#!/usr/bin/env bash
set -euo pipefail
root=/workspace/5090-validation
mkdir -p "$root"
trap 'echo $? > /workspace/5090-validation/validation-exit-code.txt' EXIT
bash /tmp/lokalbot-5090-setup.sh
export PATH="/root/.cargo/bin:$PATH"
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
cd /workspace/lokalbot/LinuxWindows
nvidia-smi --query-gpu=timestamp,name,utilization.gpu,memory.used,power.draw --format=csv -l 1 > "$root/gpu-usage.csv" &
monitor=$!
trap 'code=$?; kill "$monitor" 2>/dev/null || true; echo "$code" > /workspace/5090-validation/validation-exit-code.txt' EXIT
for run in 1 2 3; do
  python3 /tmp/lokalbot-5090-proof.py "$run" > "$root/run-$run-proof.log" 2>&1 &
  proof=$!
  RUST_LOG=warn,lokalbot_ai::runtime=info timeout 900s target/release/examples/autocomplete_eval \
    "$root/autocomplete-vulkan" --backend vulkan --model lfm2.5-1.2b-instruct --debounce 160 --key-ms 140 \
    > "$root/run-$run.log" 2>&1
  wait "$proof"
  tail -n 1 "$root/run-$run.log"
done
git status --porcelain > "$root/source-status-after.txt"
