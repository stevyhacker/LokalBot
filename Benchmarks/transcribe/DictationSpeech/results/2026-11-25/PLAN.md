# Plan: Qwen3-ASR on Automatic, one decode, on the v3 weights (written before any inference)

The 2026-11-23 numbers were measured on the earlier Qwen3-ASR 1.7B weights. The app's default is now
Qwen3-ASR-1.7B-LokalBot-v3 (`qwen3-asr-1.7b-lokalbot-v3`). This repeats the before/after on those weights.

## Builds (Release, ad-hoc signed, credentials off)

- **Before:** upstream master `e06d7968`, built from a detached worktree.
- **After:** this branch at `06e56e81` (two decode rules).
- Both use the same vendored llama.cpp runtime (`b12613`), so the server build does not differ between them.

## Recordings and settings

Same 32 recordings as 2026-11-23 (`long-dictation-v1.json`, 43.1 minutes), same runner (`run.py`, new configs
`qwen-v3-auto` and `qwen-v3-en`), one warm-up, 3 passes (the middle one reversed). The disposable home holds only the two
v3 files at the folder the app reads (`qwen3-asr-models/gguf/Qwen3-ASR-1.7B-Q8_0/`), size and SHA-256 marker matching the
catalog, so nothing is downloaded and the stock weights are not present to fall back to. The loaded file is checked in each
run's app log.

## Configurations and order (one session, builds alternating)

1. Automatic, before
2. Automatic, after
3. English, after
4. Automatic, after (repeat)
5. Automatic, before (repeat, the drift check at the end)

English runs on the after build, as on 2026-11-23. The language is the only difference between rows 2 and 3.

## What counts

- Word error rate on pass 1 (same normalizer as before) with a paired 2,000-sample bootstrap against Automatic, before.
- Time: each recording's median over the 3 passes, median over recordings; paired ratio to Automatic, before, with a
  bootstrap interval (smallest and largest per-recording ratio too); total seconds for the 32; times real time.
- Text: how many recordings have identical text before and after; how many recordings still decode twice (from the app
  log of the after build).
- A repeat that disagrees with its first run by more than 2% on median time is reported as noise, not averaged away.
- Not re-run on the new weights: the language benchmark (FLEURS, code-switched tracks, word layout).
- Machine idle: the first row starts when no process other than the window server is above 25% of a core.
