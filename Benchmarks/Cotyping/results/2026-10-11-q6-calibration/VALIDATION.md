**Validation and reproduction — Q6 publisher/calibration study**

This update adds benchmark scripts, synthetic fixtures and results. It changes no app implementation, model catalog, production threshold, dependency pin or installed preference. The frozen Release replay executable was reused after verifying the six recorded source hashes against PR source commit `85b737cd89edef6a66aeaf4dd175148e1f5d4005`. The executable SHA-256 is `23562c21a51b6ef3cf32e3a6bab2b59f1c9ed2c8bf6b2e0f12b77921e3c48cf9`. [Source verification](binary-source-verification.json).

All **91 native processes** exited successfully, with **18,144 measured observations** and 728 excluded warmups. Input, raw-output, model and executable pins match the receipts. All measured prompts are byte-identical across arms and no replay supplies a prompt override, meeting memory, screen memory or visible-text context. **9,072 repeated non-cancellation outputs** match text and suppression. Repeated observations are not independent quality cases.

The saved-data validator confirms **2,016 production/trace pairs**, **4,032 native matched/trace pairs**, **2,688 preserved midword outputs** across two rounds, and **672 replacement/cold recovery pairs**. Every arm shows exactly **112/144 English and 109/144 Serbian Latin suggestions** in both matched rounds. Matching changes zero current-Q6 outputs. Sporky and mradermacher static have 601 identical tensor hashes and **1,440 identical paired fresh/long/dynamic/matched outputs**. [Validation receipt](validation.json).

**Six focused Python tests pass.** They cover preserving the original GGUF and every byte except the BOS boolean, avoiding a clone when the flag already matches, rejecting an absent explicit BOS flag, calibration/evaluation separation and Latin-only evaluation, preserving ungated midword suggestions, and exact confidence-frequency matching without rewriting output. No existing test expectation is relaxed. [Test output](python-tests-final.log).

Calibration uses the same pinned BF16 and llama.cpp **b11429 / d81235049** quantizer for the local three-arm control. The English and bilingual importance matrices each have 64 × 512 token positions; all 276 count tensors agree. The validator checks finite quantization accumulators and **1,391,380 merged values per arm** against their components. Undefined correlations in tool-generated diagnostic `.stats` fields contain expected NaNs; they are not quantization accumulators. [Calibration plan](calibration-plan.json) · [Validation](calibration-validation.json).

The initial merge-only command lacked the tool-required `-m` argument. The same pinned source was added and the successful component matrices reused. Original commands, failure logs and hashes are retained. BOS alignment was also decided before candidate inference. Neither change followed evaluation outcomes. [Pre-inference amendments](calibration-amendments.json) · [BOS alignment](bos-alignment.json).

All **21 Claude batches** completed successfully with verified `claude-opus-5-5` receipts, exact case/option coverage and request/response hashes. No tools, model labels, reference futures, application code or personal writing were sent. There are 223 primary cases with any offer, 24 reversed-order repeats, and 65 all-silent cases retained in the 288-case denominator. One preferred-option inconsistency is reported with a sensitivity analysis; original ratings are retained. No failed judge batch was discarded or replaced.

The installed executable hash stayed `b1d1878f324db7d58b48edd467f9ace83973c3637ee7d7020ab2eabafc188d3e` from this study's start to finish. The installed Q6 stayed `20f49b221691c71d955e1d5a840b6e26329db4a5e1626f702fa4226e80a9c629`. This study did not build or reinstall the app, run local UI tests, release, change workflows, or dispatch/retry CI. PR #230 remains ready for review as requested. [Installation hash receipt](unchanged-app-receipt.json).

**Recompute from the archive**

The [evidence archive](evidence.tar.gz) contains frozen plans, inputs, raw native outputs/stderr/receipts, confidence thresholds, all judge packets/responses/ratings, source/model/tool fingerprints, analysis scripts, public publisher metadata, and calibration text/matrices with attribution. It excludes model weights, app bundles, private settings, raw desktop process inventory and profiling files. [Every member's SHA-256](evidence-manifest.json).

```sh
mkdir -p /tmp/lokalbot-q6-evidence
tar -xzf Benchmarks/Cotyping/results/2026-10-11-q6-calibration/evidence.tar.gz \
  -C /tmp/lokalbot-q6-evidence
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-q6-evidence/q6_publisher_analysis.py --root /tmp/lokalbot-q6-evidence
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-q6-evidence/validate_evidence.py
UV_CACHE_DIR=/private/tmp/lokalbot-q6-uv uv run --no-project python \
  /tmp/lokalbot-q6-evidence/make_tables.py
```

These commands validate saved evidence and recompute statistics without model inference or contacting Claude. The publication check extracts the archive, verifies every member, recomputes `summary.json`, `quality-examples.json`, `validation.json` and `TABLES.md`, and requires byte-for-byte equality. Its separate receipt is [archive-reproduction.json](archive-reproduction.json). Recalculation is not another benchmark.

**Run a new experiment**

Use a new directory; the runner refuses to overwrite frozen plans or run folders. Copy the archived helpers and fresh corpus, obtain the model revisions in [models.json](models.json) and source pin in [model-source.json](model-source.json), and verify full hashes. Rebase dated paths in the acquisition/calibration helpers before use. Recreate the three local Q6 files using the recorded tool version and commands in the archive, then align evaluation BOS metadata as documented. Keep the original files and the derived evaluation hashes distinct. Attribution for FLORES text is included in `calibration/NOTICE.md`.

Build the recorded Release source and dependency pins, or explicitly record any runtime difference before inference. Copy model manifests with valid local paths into the new root. The `q6_publisher_experiment.py` commands are, in order, `prepare --app /path/to/LokalBot`, `production`, `steady`, `trace`, `match`, `matched`, then `judge-prepare`, each with `--root /tmp/new-q6-run`. Runs are serial; avoid competing downloads, builds or GPU work. This study used the M4 Max on AC power; an interactive desktop and idle resident services remained present.

`judge-prepare` creates anonymous files locally. Executing `run_blind_judge.py` transmits those fictional packets to Claude and needs authorization for that destination and content. Final analysis requires all verified receipts. Frequency matching fits this evaluation set without quality labels; deployable thresholds need separate calibration and a new holdout.
