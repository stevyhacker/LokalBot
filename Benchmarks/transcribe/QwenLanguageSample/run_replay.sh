#!/bin/bash
# Run QwenLanguageSampleReplayTests on QLS_OUT/manifest.json (make_manifest.py) with the
# pinned 1.7B GGUF pair in QLS_OUT/llama-models. Results append to the manifest's output and
# runs resume, so a batch can be stopped and run again. Keep batches short: the laptop heats up.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
OUT=${QLS_OUT:-/private/tmp/lokalbot-qwen-sample}
export TEST_RUNNER_LOKALBOT_QWEN_SAMPLE_MANIFEST="$OUT/manifest.json"
export TEST_RUNNER_LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR="$OUT/llama-models"
started=$(date +%s)
"$ROOT/Scripts/test/unit-tests.sh" QwenLanguageSampleReplayTests/testReplayBenchmarkTracks
echo "replay batch took $(( $(date +%s) - started )) s"
