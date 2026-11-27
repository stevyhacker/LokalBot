# Plan, frozen before the first inference — 2026-11-25

Re-measure the 2026-11-21 n-gram speculation benchmark on the project's current default Think model and the current bundled
llama-server.

## What changes against 2026-11-21

- Model: `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` (SHA-256 `678f3d49c92ece8cd9425bad9e30cd626d35149b00f5dc2b661cb78ad9346ab0`),
  the new default; reasoning off, as the runner's production Compose options set it.
- Server: llama.cpp b12613 (the version `Scripts/build/fetch-llama.sh` pins), built from this branch. 2026-11-21 used v1.0.0
  (build 12359).
- Every run uses `--fresh-server-per-condition`, so every output is a first-time dictation for its server and all five grant
  conditions count. (2026-11-21 counted only condition 1.)

## Sets (unchanged files)

1. Long dictation: `context-speed-v1.json`, 8 cases, 40 cleaned outputs per run (SHA-256 `fccaae5f…`).
2. Short dictation: `context-cleanup-v4.json`, 17 cases, SHA-256 `bdced6d4…`.
Both with `--split heldout`; the same flags as before (production cleanup prompt).

## Configurations and order

Round 1, v4 model, per set (long set first, then short): `none` (a), `ngram-simple` n 3 m 16, `ngram-simple` n 6 m 32,
`ngram-simple` defaults, `ngram-mod` defaults, `ngram-mod` match 8 / 4-32, `ngram-map-k` n 4 m 32, `ngram-cache`, `none` (b).
Baseline first and last as a noise floor, one server per condition.

Stock-model pair, per set, on the same new server: `none`, then `ngram-cache`, with the old stock
`Qwen3.5-4B-Q4_K_M.gguf` (SHA-256 `00fe7986…`), so a reader can tell the model change from the server change.

Round 2, v4 model, per set: `none` (c), `ngram-mod,ngram-cache`, `ngram-cache`, `ngram-mod` defaults.

The wordlock set from 2026-11-21 is not re-run (not asked for).

## Time budget and trimming

Target: under about 2 hours of runs. Round 1 and the stock pair are mandatory. Round 2 starts only if round 1 and the stock
pair together took under 75 minutes; otherwise round 2 is dropped (rounds are trimmed, configurations are not) and the report
says so.

## What counts

- Median latency per configuration over all cleaned outputs (model-call cases, all five conditions), p90, and the paired
  ratio: the median over cases of the configuration's latency divided by the baseline's for the same case and condition. The
  baseline for a configuration is the `none` run of the same round (round 1: `none` (a); round 2: `none` (c)).
- Output text compared with the same baseline's for every output.
- Correctness scores from `report.json` as they come, not promoted into a pass/fail.
- Draft tokens accepted, from the server logs.
- Results that weaken the case are reported as they are. One pass: a run that fails twice for the same reason stops the
  sweep and is reported.

## Conditions of the machine

Apple M4 Pro, 48 GB. Nothing else started by the benchmark. The owner's trial copy of the app was already running when the
sweep started; it is idle and is not touched. Whether it stayed running is stated in the report.
