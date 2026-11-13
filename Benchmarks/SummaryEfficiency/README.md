# Summary and action extraction replay

This opt-in benchmark runs the production Swift `MeetingNotesGenerator` against a copied transcript and the local Qwen model. It launches an isolated loopback llama.cpp process, then runs one cold and one warm extraction into separate output folders. These are native tests; the harness excludes the UI test target.

```sh
uv run --no-project Benchmarks/SummaryEfficiency/run.py \
  --transcript '/absolute/path/to/meeting/transcript.json' \
  --model '/absolute/path/to/Qwen3.5-4B-Q4_K_M.gguf' \
  --output /private/tmp/lokalbot-summary-replay
```

The default runtime is `Vendor/llama-cpp/llama-server`; override it with `--runtime`. Omit `--skip-build` to compile the current source with `Scripts/test/unit-tests.sh MeetingNotesReplayTests`. Use a fresh output directory for every invocation so saved checkpoints cannot bypass inference. The sibling `notes.md`, when present, is copied as user context. Source meeting files remain untouched.

Runtime settings match the built-in configuration: 32,768 context tokens, Metal offload, 2,048 MiB prompt cache, and reasoning enabled. Production extraction supplies bounded reasoning/output options per call. The temporary server uses an ephemeral loopback port and an authentication token that is removed during cleanup.

`measurements.json` records content-free per-call usage, prefill/decode/wall time, validation outcomes, and totals. Cold total adds process startup through model health readiness to measured extraction time. Warm total measures extraction against the same loaded runtime and cache. Both runs perform fresh generation; warm does not reuse completed notes. “Cold” means a fresh runtime process, not a flushed macOS filesystem cache. Compilation, XCTest launch, ASR, and unrelated app queue delays are excluded.

The private output folder also contains the copied input, generated notes/outcomes, raw model responses, runtime logs, and XCTest result bundles. Keep these outside the repository. Only aggregate counts and timings are suitable for the checked-in report.

The replay checks source membership, canonical claim validation, and evidence-backed user ownership. Review factual coverage and the meaning of the extracted tasks separately; mechanical validity and low latency alone do not establish summary quality. Normal unit/CI runs skip this benchmark unless `LOKALBOT_NOTES_REPLAY_MANIFEST` is explicitly set.
