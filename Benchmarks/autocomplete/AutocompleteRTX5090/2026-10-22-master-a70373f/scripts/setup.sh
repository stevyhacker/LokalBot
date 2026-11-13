#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
root=/workspace/5090-validation
mkdir -p "$root"
trap 'echo $? > /workspace/5090-validation/setup-exit-code.txt' EXIT
nvidia-smi > "$root/nvidia-smi.txt"
nvidia-smi --query-gpu=name,uuid,memory.total,driver_version,compute_cap --format=csv > "$root/card-details.csv"
lscpu > "$root/cpu.txt"
cat /etc/os-release > "$root/os-release.txt"
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl git build-essential pkg-config libssl-dev libasound2-dev libx11-dev libxkbcommon-dev libxkbcommon-x11-dev libxcb1-dev libwayland-dev libvulkan1 vulkan-tools libxext6 libgl1 libegl1 libfontconfig1-dev ripgrep python3
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
vulkaninfo --summary > "$root/vulkan-summary.txt" 2>&1
rg 'deviceName.*RTX 5090' "$root/vulkan-summary.txt"
curl --fail --silent --show-error https://sh.rustup.rs -o /tmp/lokalbot-install-rust.sh
sh /tmp/lokalbot-install-rust.sh -y --profile minimal --default-toolchain 1.99.1
export PATH="/root/.cargo/bin:$PATH"
mkdir -p /workspace/lokalbot
cd /workspace/lokalbot
git init
git remote add origin https://github.com/stevyhacker/LokalBot.git
git sparse-checkout init --cone
git sparse-checkout set LinuxWindows .agents LokalBot/Resources/SampleMeeting
git fetch --depth 1 --filter=blob:none origin a70373f0f20f5daaee0c08fa1216beb3a9e76bb7
git checkout --detach FETCH_HEAD
test "$(git rev-parse HEAD)" = a70373f0f20f5daaee0c08fa1216beb3a9e76bb7
git rev-parse HEAD > "$root/tested-sha.txt"
git status --porcelain > "$root/source-status.txt"
cd LinuxWindows
rustc --version > "$root/rust-version.txt"
ldd --version > "$root/glibc-version.txt"
cargo build --release --locked -j 16 -p lokalbot-engine --example autocomplete_eval
sha256sum target/release/examples/autocomplete_eval > "$root/evaluator-sha256.txt"
