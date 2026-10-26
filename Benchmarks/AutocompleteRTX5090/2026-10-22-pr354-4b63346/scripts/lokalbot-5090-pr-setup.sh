#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
root=/workspace/pr354-validation
mkdir -p "$root"
trap 'echo $? > /workspace/pr354-validation/setup-exit-code.txt' EXIT
nvidia-smi > "$root/nvidia-smi.txt"
nvidia-smi --query-gpu=name,uuid,memory.total,driver_version,compute_cap --format=csv > "$root/card-details.csv"
lscpu > "$root/cpu.txt"
cat /etc/os-release > "$root/os-release.txt"
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl git build-essential pkg-config libssl-dev libasound2-dev libx11-dev libxkbcommon-dev libxkbcommon-x11-dev libxcb1-dev libwayland-dev libvulkan1 vulkan-tools libxext6 libgl1 libegl1 libfontconfig1-dev ripgrep python3
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
vulkaninfo --summary > "$root/vulkan-summary.txt" 2>&1 || true
# rg 'deviceName.*RTX 5090' "$root/vulkan-summary.txt"
python3 - <<'PY' > "$root/driver-version.txt"
import ctypes
v=ctypes.c_int()
assert ctypes.CDLL('libcuda.so.1').cuDriverGetVersion(ctypes.byref(v)) == 0
print('CUDA driver API version:', v.value)
assert v.value >= 13000
PY
curl --fail --silent --show-error https://sh.rustup.rs -o /tmp/lokalbot-install-rust.sh
sh /tmp/lokalbot-install-rust.sh -y --profile minimal --default-toolchain 1.99.1
export PATH="/root/.cargo/bin:$PATH"
mkdir -p /workspace/lokalbot
cd /workspace/lokalbot
git init
git remote add origin https://github.com/stevyhacker/LokalBot.git
git sparse-checkout init --cone
git sparse-checkout set LinuxWindows .agents LokalBot/Resources/SampleMeeting
git fetch --depth 1 --filter=blob:none origin 4b63346556f15776d441cf3e8c42a8ce2a7c15f6
git checkout --detach FETCH_HEAD
git rev-parse HEAD > "$root/tested-sha.txt"
git status --porcelain > "$root/source-status.txt"
cd LinuxWindows
rustc --version > "$root/rust-version.txt"
cargo test --release --locked -j 16 -p lokalbot-ai --lib > "$root/ai-unit-tests.log" 2>&1
cargo build --release --locked -j 16 -p lokalbot-engine --example autocomplete_eval
sha256sum target/release/examples/autocomplete_eval > "$root/evaluator-sha256.txt"
