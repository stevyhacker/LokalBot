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

## Addendum: the language benchmark on the v3 weights (written before any inference)

`Benchmarks/transcribe/QwenLanguageSample`, as on 2026-11-23: 10 FLEURS languages and 7 code-switched tracks (40 dev
utterances each, 6 to 9 minutes), both layouts (`plain`, `word`), 34 runs per path, run through
`QwenLanguageSampleReplayTests` (the app's VAD, window merging and `QwenASREngine.decodeOnAuto`, one llama-server with
the app's flags). The same audio and references as 2026-11-23 (`items.json` from `fetch_tracks.py`, unchanged).

- **Weights:** the replay test gained an environment switch (`LOKALBOT_QWEN_SAMPLE_WEIGHTS=lokalbot-v3`) that selects
  `QwenLlamaASR.accuracyLokalBotV3` instead of `QwenLlamaASR.accuracy`; the model folder holds the v3 pair (size and
  SHA-256 checked before the runs). Each run is checked from the server's command line (sampled from the process list)
  and the test's own printed weights name.
- **Paths measured:**
  1. `old`: the replayed pre-sampling path (`decodeAsBefore`: every window on auto, vote, every window again pinned),
     which is what 2026-11-23 called "before";
  2. `master`: `decodeOnAuto` of upstream master `e06d7968` (the 12-window sample), the "before" of the dictation
     benchmark, built from the detached worktree at that commit;
  3. `branch`: `decodeOnAuto` of this branch (both rules).
  The text of a window decoded in the same language is the same in every path (greedy), so accuracy does not depend on run
  order; time is from single, unpaired runs and is reported as indicative only.
- **Comparisons:** branch against old (the 2026-11-23 table: same pinned language and text, in how many of 34),
  branch against master (what the PR changes), WER or CER per one-language track for old, master and branch, the
  code-switched tracks, and the decode counts. The 2026-11-23 stretch analysis (every run of 2 to 12 windows, 9,130
  stretches) is rerun on the v3 `old` records.
- **Order:** the master worktree runs `old` and `master` modes in one test run; then the branch runs the `branch` mode.
  Nothing else heavy runs while a test runs. Builds with credentials off (`Local/build-dev.sh`), one xcodebuild at a time.
- **What counts as weakening the case:** any track whose text or word errors get worse after the change, any change in
  the pinned language, any track where the rule fires on a stretch that crosses a language change.
