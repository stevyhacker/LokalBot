**Validation and reproduction — E2B IT Q6 follow-up**

The native experiment is complete; external Claude quality judging is blocked and explicitly incomplete. This update changes benchmark/reporting files only. It does not change app code, the model catalog, dependency pins, production thresholds or installed settings.

The frozen Release replay executable has SHA-256 `23562c21a51b6ef3cf32e3a6bab2b59f1c9ed2c8bf6b2e0f12b77921e3c48cf9`. Its six recorded runtime/test/helper hashes were checked against PR source commit `0cb3488d3b504522ff09881e3390e224cc996791`. The existing decoder uses certified prefix search, the selective hybrid, two generation and two prefill threads and 256-token prefill chunks. Prompt, sampler, six-token/four-word budgets and production gates 0.1/0.31 remain fixed. [Source verification](source-before.json).

All **39 processes** exit successfully: 7,776 measured observations plus 312 excluded warmups. The saved-data validator checks input, raw-output, executable and model hashes; exact case IDs; prompt equality; no prompt overrides or private context; 3,888 deterministic repeated non-cancellation outputs; 864 production/trace pairs; 1,728 native matched/trace pairs; 1,152 unchanged midword outputs across matched rounds; and 288 replacement/cold recovery pairs. Every matched arm shows 112 English and 109 Serbian Latin suggestions. Matching changes zero current-Q6 texts. [Validation receipt](validation.json).

Before inference, original download hashes, tensor shapes, precision mix and input-tokenizer metadata were inspected. Both IT evaluation files differ from their originals in exactly the automatic-BOS boolean byte. All 402 distinct prefixes tokenize identically using the actual app's linked `libllama`. The initial over-strict token-type assertion and subsequent pre-inference stopping-metadata clarification are preserved. [Provenance](PROVENANCE.md) · [BOS receipts](bos-alignment.json) · [Tokenization fingerprints; full sequences in archive](input-tokenization-summary.json) · [Frozen controls](pre-inference-controls.json).

**Eleven existing focused Python tests pass.** They cover exact matching, fallback probability mass, preserving ungated midwords, rejecting unmatchable ties, Unicode fragment/reference handling, retaining silence in quality denominators, scenario clustering, actual cancellation issuance, anonymous packets, missing ratings and contradictory preferences. No existing test expectation changes. [Test log](python-tests.log).

**Claude remains pending.** The 25 prepared batches cover 272 primary cases and 24 reversed-order repeats. Sixteen all-silent cases stay in the 288-checkpoint denominator. All CLI requests failed before ratings with a session usage limit; one OpenRouter/Anthropic fallback failed because an account guardrail blocks the model. Neither route yielded a quality score. The archive retains original errors, unchanged packets, the proposed transport adapter and its failed preflight. `judgeCompleted` and `judgeCoverageVerified` are false in the validation receipt. [Status](judge-status.json) · [Transport attempt record](judge-transport-amendment.json).

The installed executable and current-Q6 hashes are identical at the start and end of native testing. No app build or reinstall, local UI test, release, CI retry/dispatch or workflow change was performed. A vocabulary-only C probe was compiled for tokenization verification; that is separate from building the app. [Installation hash receipt](unchanged-app-receipt.json).

**Recompute the saved native results**

The [archive](evidence.tar.gz) contains frozen scripts/plans, model provenance, public cards, synthetic inputs, raw native outputs and logs, matching thresholds, prepared judge packets and failed-service receipts. It excludes model weights, app/probe binaries, credentials, raw desktop process inventory and profiling data. The [manifest](evidence-manifest.json) gives every member's hash. Recalculation does not run models or contact Claude.

```sh
mkdir -p /tmp/lokalbot-e2b-it-q6-evidence
tar -xzf Benchmarks/Cotyping/results/2026-10-11-e2b-it-q6/evidence.tar.gz \
  -C /tmp/lokalbot-e2b-it-q6-evidence
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/it_q6_analysis.py \
  --root /tmp/lokalbot-e2b-it-q6-evidence --without-judge
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/validate_evidence.py --without-judge
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-e2b-it-q6-evidence/make_pending_tables.py
```

The publication check extracts into a new directory, verifies every archive member, recomputes `summary.json`, `validation.json` and `TABLES.md`, and requires byte-for-byte equality. [Reproduction receipt](archive-reproduction.json).

**Finish judging or run another experiment**

After Claude subscription access resets, the archived `run_blind_judge.py` can submit the existing frozen packets using the unchanged rubric and high-effort Opus 5.5. It sends synthetic text externally; the current request authorizes that content and destination. Do not change OpenRouter guardrails as part of this experiment. Preserve any further failures, and do not overwrite successful responses. After all 25 receipts validate, run `it_q6_analysis.py --root <root>` without `--without-judge`, then `validate_evidence.py` and `make_tables.py`. Add the quality results and replace the pending report/archive with a clearly recorded follow-up; do not pool earlier studies' ratings.

For a new native study, use a new directory and rebase the recorded local paths. Obtain the pinned public artifacts, verify hashes, reproduce the documented BOS alignment and tokenization check, and use the recorded Release runtime or explicitly declare any change. The wrapper commands are `prepare --app /path/to/LokalBot`, `production`, `steady`, `trace`, `match`, `matched`, `judge-prepare`, all with `--root <new-root>`. The runner refuses to overwrite existing plans/runs. Run native timing serially, without downloads, builds or judge requests. This study used an M4 Max on AC power with an interactive desktop and resident services present; it is not a continuously isolated machine measurement.
