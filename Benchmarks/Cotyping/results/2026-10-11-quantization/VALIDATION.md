**Validation and reproduction — E2B quantization, 11 October 2026**

This change adds benchmark tools, results and documentation. It changes no app source, production configuration, dependency pin, model catalog or installed preference. The Release replay binary from the preceding cancellation study was reused after verifying the six recorded runtime/replay/test/helper source hashes against `ea3970204e0831d6a76a533f6daec0b9a7a67c5d`. No new app build, installation, release or local UI test was performed.

All **65 serial native processes** exited successfully: **12,960 measured observations** and 520 excluded warmups. Every input, raw output, model pin and executable hash in the receipts was verified. Paired prompts are byte-identical across models. **6,480 repeated non-cancellation outputs** match their original text and suppression exactly. This is deterministic repetition, not 6,480 independent quality judgments.

The confidence traces reproduce every production output at the original thresholds. Both native matched-frequency rounds reproduce the traced counterfactuals and exactly 124 English / 108 Serbian Latin suggestions per model. All 960 model/checkpoint midword outputs are preserved by matching. All **480 replacement/cold pairs** match after cancellation. No replay error was recorded.

**Six focused Python tests pass.** They cover matched-frequency fallback mass, preserving ungated fragments, rejecting unmatchable confidence ties, Unicode midword reference scoring, keeping silence in the quality denominator with clustered checkpoints, and measuring cancellation from actual issuance while excluding unpaired completed requests. Existing expected outputs were not relaxed. Swift/Xcode/project files did not change, so no duplicate app build or XCTest run was needed for this benchmark-only update.

All **22 blind Claude batches** completed with verified `claude-opus-5-5` receipts, tools disabled, source/model identities/reference futures omitted, and no private writing supplied. There are 240 primary cases, 24 repeat cases and 48 all-silent checkpoints retained as zero utility in the 288-case denominator. Request/response hashes and exact case/option coverage were checked. No failed judge attempt was replaced or hidden; there were no failed batches. Repeated ratings and raw opinions remain in the archive.

The installed executable remains `322e74f16ffe42bc77cd60f3a56aeae2e0a1ca05ad0ba78d579f465bf6160379`; installed Q6 remains `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`. **The current E2B Q6 default is retained.** New GGUFs were stored only in temporary benchmark storage, outside the app's model directory. No workflow was edited, explicitly dispatched or retried; the existing PR remains draft.

[Validation receipt](validation.json) · [Python test output](python-tests-final.log) · [Unchanged installation](unchanged-app-receipt.json) · [Exact model pins](models.json) · [Summary](summary.json)

**Recompute saved results**

Extract the evidence into a new directory. The archive contains frozen corpora/plans, all replay inputs/JSONL/stderr/receipts, model metadata and SHA-256 pins, GGUF inspection, source fingerprints, analysis scripts, and all blind judge requests/ratings/responses. It excludes GGUF weights, app bundles, private preferences and personal text. Every archive member is listed in the adjacent SHA-256 manifest.

```sh
mkdir -p /tmp/lokalbot-quantization-evidence
tar -xzf Benchmarks/Cotyping/results/2026-10-11-quantization/evidence.tar.gz \
  -C /tmp/lokalbot-quantization-evidence
UV_CACHE_DIR=/private/tmp/lokalbot-quantization-uv uv run --no-project python \
  /tmp/lokalbot-quantization-evidence/quantization_analysis.py \
  --root /tmp/lokalbot-quantization-evidence
```

This validates the frozen receipts and recomputes statistics without loading a model or calling Claude. `summary.json` is deterministic. The original 55-process plan and the ten-process warm-run addition are separate files; the original Q8 first-pass slowdown is preserved. Recalculation is not a new benchmark.

**Run a new comparison**

Use a fresh directory, never overwrite this evidence. Acquire the pinned models from `models.json` and verify complete SHA-256 values. Build the recorded source as Release with the pinned dependencies, or identify another compatible binary and record the source difference. Copy `corpus.json`, the Python helpers and model manifests into the new directory; update the model paths without changing the hashes. The archived `download_models.py` and `inspect_gguf.py` contain dated local paths and require rebasing before reuse.

```sh
uv run --no-project python Benchmarks/Cotyping/quantization_experiment.py \
  --root /tmp/new-quantization-run prepare \
  --app /path/to/Release/LokalBot.app/Contents/MacOS/LokalBot
uv run --no-project python Benchmarks/Cotyping/quantization_experiment.py \
  --root /tmp/new-quantization-run run --mode production
uv run --no-project python Benchmarks/Cotyping/quantization_experiment.py \
  --root /tmp/new-quantization-run run --mode trace
uv run --no-project python Benchmarks/Cotyping/quantization_experiment.py \
  --root /tmp/new-quantization-run match
uv run --no-project python Benchmarks/Cotyping/quantization_experiment.py \
  --root /tmp/new-quantization-run run --mode matched
```

For the full 65-process timing protocol, also copy the preserved `steady-timing-plan.json` and `run_steady_timing.py` into the new root alongside the helper modules, then run that wrapper there. It adds production fresh rounds three/four. `prepare` and each replay refuse to replace existing plans/run directories. Freeze any new source/model changes before inference, and do not run local GPU measurements alongside other benchmarks, builds or model downloads.

`judge-prepare` only creates anonymous packets; it does not transmit them. Judge execution requires explicit authorization for the destination and synthetic contents. The archived wrapper invokes the installed Claude CLI with safe mode, empty tool/MCP configuration, no session persistence and the fixed rubric. Final analysis without `--without-judge` requires all verified judge receipts; the frozen 65-process analysis also requires both warm follow-up rounds.
