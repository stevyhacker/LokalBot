# Spark-X2.6-4B evaluation

Evaluation date: October 20, 2026. See `REPORT.md` for findings and `manifest.json` for pinned identities.

## Method

The candidate is the publisher's Spark-X2.6-4B Q4_K_M GGUF. The baseline is the exact Qwen3.5-4B Q4_K_M file in LokalBot's current model catalog. Both downloads are SHA-256 verified.

Both run sequentially on the same Ubuntu Ryzen 7 9700X host using the existing Linux CPU build of llama.cpp b11474. Its source archive checksum matches `Scripts/fetch-llama.sh`. The binary reports build 0 because this earlier remote build did not inject the version number; the binary SHA-256 is recorded. This is not the macOS Metal binary.

Settings: 8 inference and batch threads, no GPU offload, 32,768-token context, one slot, temperature 0, seed 42, thinking disabled through both template kwargs and a zero token budget. Output is capped at 1,024 tokens for extraction and 2,048 for tools. JSON extraction uses a schema grammar. These settings probe LokalBot-style bounded work; they do not reproduce the publisher's high-reasoning benchmarks.

The 19 existing synthetic MiniCPM5 comparison cases are reused without changes: 12 short extraction cases, one long-context correction/provenance case, and six single-turn tool cases. A separate fixed-stub multi-step test searches for a meeting, reads it, then answers with citations. No model-generated tool is executed against real data or services. No private meeting content is transferred.

`run.py` derives from the existing Linux adaptation in `Bonsai2LFM24B/2026-10-18/extraction.py`. Changes are limited to self-contained fixture paths, explicit CPU/thread settings, a 900-second request timeout, and documentation. Exact-string scores are retained. `review_scores.py` reuses the already-established date/translation equivalences from the original MiniCPM5 evaluation, applied equally to both models.

## Reproduce on the remote host

```sh
cd /home/ubuntu/spark-x26-eval-20261020
~/.local/bin/uv run --no-project run.py \
  --model models/Spark-X2.6-4B-Q4_K_M.gguf \
  --runtime /home/ubuntu/hy-memory-eval-20261016/llama.cpp-b11474/build/bin/llama-server \
  --output results/spark --repeats 1
# Then use models/Qwen3.5-4B-Q4_K_M.gguf and a fresh results/qwen directory.
~/.local/bin/uv run --no-project review_scores.py
# Optional diagnostic recorded separately from the primary scores:
~/.local/bin/uv run --no-project probe_reasoning.py \
  --runtime /home/ubuntu/hy-memory-eval-20261016/llama.cpp-b11474/build/bin/llama-server
```

Choose fresh result directories to preserve prior runs. Source model cards, configuration, license, chat template, benchmark charts, and GGUF metadata are saved under `sources/`. Runtime logs, outputs, and timings are under `results/`.

The targeted reasoning diagnostic rechecks only `tool_do_not_invent` after the primary comparison. It enables the template's default reasoning mode with a 1,024-token thinking budget and 2,048-token total output cap. Its result must not be folded into the primary non-thinking scores.

## Limits

One deterministic run per case is a screening result, not a statistically robust quality ranking. The schema grammar guarantees much of the JSON formatting, so valid JSON is not evidence of unconstrained formatting reliability. This suite does not measure complete meeting-note generation, the app's ownership post-processing, real-user data, cancellation, simultaneous workloads, full 32K/1M context capacity, or high-reasoning agent performance. Linux CPU latency and RSS must not be presented as Apple Silicon performance or memory pressure.
