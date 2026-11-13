# Memory retention benchmark · 2026-10-23

This directory contains a new 120-case synthetic contrast suite for the memory-writing step of a local assistant. It is separate from the 36-case development pilot under `Benchmarks/HyMemory/2026-10-16`.

Read [PROTOCOL.md](PROTOCOL.md) before interpreting the results. The suite tests proposed personal memories under a specific retention policy, not a complete memory framework or downstream question answering.

## Inputs and audit trail

- [cases.json](cases.json): 60 contrast pairs / 120 cases, including 96 English and 24 Serbian cases.
- [build_cases.py](build_cases.py): readable case definitions and deterministic ordering.
- [prompts.json](prompts.json), [schema.json](schema.json): exact inference inputs.
- [models.json](models.json): immutable model revisions and weight SHA-256 digests.
- [frozen.json](frozen.json): frozen input digests and UTC timestamp before inference.
- [TRANSFER.md](TRANSFER.md): the application source snapshot was retained locally; only synthetic evaluation assets and rendered prompts were transferred.
- [score.py](score.py), [test_score.py](test_score.py): mechanical scoring and checks.
- [runner.py](runner.py): one arm, incremental raw JSONL, hash-checked resume.
- [run_remote.py](run_remote.py): sequential CPU runs and pinned public downloads.
- [prepare_audit.py](prepare_audit.py): complete source/output review worksheets.
- [chart.py](chart.py): charts derived directly from reviewed score data.

The full application source snapshot is local provenance only and is intentionally omitted from the share bundle. The rendered prompts and schema suffice to reproduce inference.

## Reproduce on Ubuntu

Use a CPU build of llama.cpp v0.7.0, 64 GB RAM, and enough disk for the selected weight files. The exact binary digest and `--version` output are recorded per arm. GPU and newer-runtime results are separate experiments.

```sh
uv run --no-project python -m unittest discover -p test_score.py
# Fetch the desired model from its pinned repo/revision in models.json; check its SHA-256.
uv run --no-project python runner.py qwen35-4b /path/to/Qwen3.5-4B-Q4_K_M.gguf \
  --server /path/to/llama.cpp-0.7.0/build/bin/llama-server
# Repeat for the other model IDs in models.json, one at a time.
uv run --no-project python prepare_audit.py
uv run --no-project python score.py
uv run --no-project python citation_diagnostic.py
# After every emitted item has a recorded semantic review:
uv run --no-project --with matplotlib python chart.py
uv run --no-project python build_report.py
uv run --no-project python validate_results.py
```

`run_remote.py` additionally knows the existing runtime/cache locations on this user's Ubuntu host. It never deletes weights, modifies the app, or runs inference on the Mac. `runner.py` binds only localhost, checks that its port is free, and terminates only the server process it started. Each response is flushed and fsynced before the next request. Observed transport errors remain recorded; they are not silently rerun.

For rapid consecutive runs, assign a different `--port` to each arm (for example 18943, 18944, 18945, 18946). The frozen runner's conservative free-port probe can reject a recently closed socket during TCP TIME_WAIT even when there is no listener. In this run, the first 9B startup stopped at that probe, before any request or response; resuming after cooldown skipped the completed 4B arm. The frozen code and inference settings were not changed. This startup issue is distinct from a model inference failure.

## Interpretation

The main English slice has 52 required memories and 44 empty cases; Serbian has 13 and 11 respectively. Every case has at most one gold memory. Most pairs contrast an eligible statement with a quotation, hypothetical, temporary task, duplicate, or excluded statement. Five pairs instead change the correct preference/fact through negation. This is an edge-case suite, not a representative sample of daily conversations.

Automatic source selection, automatic anchor matching, and reviewed semantic content are different measures. Reviews are assistant judgments with visible model identity, not independent human validation. Raw outputs and explicit reasons make them inspectable. The frozen regex scorer is retained unchanged even when a semantic review disagrees.

There is no significance claim, population confidence interval, production failure-rate estimate, or CPU speed ranking. Results from the older pilot must not be pooled: dataset composition and Hy-Memory quantization differ.

No publishing, app installation, release, or model-default change is part of this work.
