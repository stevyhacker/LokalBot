#!/usr/bin/env bash
set -euo pipefail
root=/workspace/pr354-validation
export PATH="/root/.cargo/bin:$PATH"
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
trap 'echo $? > /workspace/pr354-validation/full-validation-exit-code.txt' EXIT
cd /workspace/lokalbot/LinuxWindows
cp target/release/examples/autocomplete_eval "$root/autocomplete-eval-pr"
cargo test --release --locked -j16 -p lokalbot-ai --test e2e_runtime --no-run > "$root/e2e-build.log" 2>&1
cd ..
git fetch --depth 1 --filter=blob:none origin a70373f0f20f5daaee0c08fa1216beb3a9e76bb7
git worktree add --detach /workspace/master a70373f0f20f5daaee0c08fa1216beb3a9e76bb7
cd /workspace/master/LinuxWindows
CARGO_TARGET_DIR=/workspace/lokalbot/LinuxWindows/target cargo build --release --locked -j16 -p lokalbot-engine --example autocomplete_eval > "$root/master-build.log" 2>&1
cp /workspace/lokalbot/LinuxWindows/target/release/examples/autocomplete_eval "$root/autocomplete-eval-master"
git rev-parse HEAD > "$root/master-tested-sha.txt"
git status --porcelain > "$root/master-source-status.txt"
sha256sum "$root"/autocomplete-eval-* > "$root/both-evaluators-sha256.txt"
cd /workspace/lokalbot/LinuxWindows
LOKALBOT_E2E_ROOT="$root/e2e-bundled" LOKALBOT_E2E_BACKEND=cuda cargo test --release --locked -j16 -p lokalbot-ai --test e2e_runtime installs_runtime_downloads_models_and_answers -- --ignored --nocapture --test-threads=1 > "$root/e2e-bundled.log" 2>&1
bash /tmp/lokalbot-5090-matched-bench.sh
