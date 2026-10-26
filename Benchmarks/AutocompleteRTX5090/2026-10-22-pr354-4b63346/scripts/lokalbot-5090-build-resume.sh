set -euo pipefail
root=/workspace/pr354-validation
trap 'echo $? > /workspace/pr354-validation/setup-exit-code.txt' EXIT
export PATH="/root/.cargo/bin:$PATH"
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
vulkaninfo --summary > "$root/vulkan-summary-fixed.txt" 2>&1
rg 'deviceName.*RTX 5090' "$root/vulkan-summary-fixed.txt"
cd /workspace/lokalbot/LinuxWindows
rustup toolchain list
for attempt in 1 2 3; do
  if rustup toolchain install 1.99.1 --profile minimal; then break; fi
  sleep 2
done
rustc --version > "$root/rust-version.txt"
cargo test --release --locked -j 16 -p lokalbot-ai --lib > "$root/ai-unit-tests.log" 2>&1
cargo build --release --locked -j 16 -p lokalbot-engine --example autocomplete_eval
sha256sum target/release/examples/autocomplete_eval > "$root/evaluator-sha256.txt"
