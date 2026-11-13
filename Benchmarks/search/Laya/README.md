# Laya evaluation for LokalBot

Offline, synthetic Ask/Search intent evaluation. No app integration or private library access.

## Protocol fixed before inference

- 80 manually authored semantic families, translated to English, Serbian Latin and Serbian Cyrillic (240 rows). Equal Ask/Search labels in each language. Translation variants are correlated, not 240 independent user samples.
- Labels express intended interaction: answer/synthesize versus retrieve a matching item. Boundary/title/code queries are included; this is an author-labeled diagnostic, not a validated production test set.
- The actual `AskIntent` enum is extracted from the current Swift source and compiled as a standalone Foundation CLI. Its outputs are the production baseline; no UI tests run.
- A second, predeclared heuristic adds Serbian opening words and two-word imperative handling. It is an evaluation comparator only, not an app change.
- Compare all three shipped Laya checkpoints, default language routing, explicit language routing, and multilingual-only execution. Use one fixed English task schema and reversed option order as a robustness check. Do not tune prompts or thresholds after seeing labels/results.
- Test PyTorch MPS and laya-apple MLX on identical pinned weights. Downloads occur separately; inference runs with Hugging Face offline flags. No ANE performance claim without an actual validated run.
- Main quality gates for considering a product pilot: at least 95% overall accuracy, at least 90% in each language, no more than 2% Search-to-Ask errors, and no regressions on the existing AskIntent unit-test cases. Warm single-request p95 target: 100 ms. These are proposed product gates, not upstream guarantees.
- Record probabilities, confusion matrices, per-language scores, reversed-order disagreements, cold initialization/first call, full-call warm latency, process RSS and GPU allocation. RSS and GPU figures must not be added: unified-memory accounting can overlap.
- Confidence fallback uses selected-option probability, not Laya's entropy-based `confidence` field. Report 0.7/0.8/0.9/0.95/0.99 thresholds against the existing heuristic; 0.9 is the predeclared primary diagnostic. No fitted calibration or training on this fixture.

Results and exact reproduction details are saved under `results/2026-09-24/`.

## Reproduce

From the repository root, on an Apple Silicon Mac with working Metal access:

```sh
UV_CACHE_DIR=/private/tmp/laya-eval-cache uv venv --python 3.12 /private/tmp/laya-eval-venv
UV_CACHE_DIR=/private/tmp/laya-eval-cache uv pip install --python /private/tmp/laya-eval-venv/bin/python -r Benchmarks/search/Laya/requirements-lock.txt
export HF_HOME=/private/tmp/laya-eval-models
export LAYA_APPLE_CACHE=/private/tmp/laya-eval-apple-cache
export HF_HUB_DISABLE_TELEMETRY=1
/private/tmp/laya-eval-venv/bin/laya-apple download laya laya-multilingual laya-typed-decisions
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 TOKENIZERS_PARALLELISM=false
/private/tmp/laya-eval-venv/bin/python Benchmarks/search/Laya/run.py --baseline
/private/tmp/laya-eval-venv/bin/python Benchmarks/search/Laya/run_all.py
/private/tmp/laya-eval-venv/bin/python Benchmarks/search/Laya/run.py --router
/private/tmp/laya-eval-venv/bin/python Benchmarks/search/Laya/score.py
```

The frozen `cases.jsonl` is the test input. `make_cases.py` records how it was authored. `run_all.py` skips complete runs, so preserve this result directory and select a new output directory in `run.py` for an independent rerun. Do not overwrite historical measurements. The recorded run used the two pinned Git source checkouts in `manifest.json`; the lockfile references those exact commits.

The initial sandbox could not see MPS. GPU measurements used approved execution outside that sandbox; no CPU fallback was accepted. All benchmarks ran sequentially. These are model inference and standalone Swift checks, not UI tests.
