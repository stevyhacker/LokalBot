# Autocomplete engine benchmark — 2026-10-14

**Superseded by the [2026-10-15 engine benchmark](../2026-10-15-engine-benchmark/REPORT.md).**
This run used the original scoring, which counted withheld suggestions as safety
failures and timed a full app process. `run_in_process_benchmark.py` was
replaced by `engine_benchmark.py` afterwards; the version used here is in commit
`3a2344e`.

The [July 21 run](../2026-07-21-model-debounce-benchmark.md) predates the current
default autocomplete model. This run repeats the same 28-scenario
`LokalBot --cotyping-bench` harness on today's code for **Gemma 4 E2B Base
`Q6_K`** (the default on fresh installs, `ModelCatalog.qualityCotypingID`) and
**LFM2.5 1.2B Instruct `Q4_K_M`** (the Lightweight preset), as a reference.

## Outcome

**Neither model passes the checked-in gate on current code.** The gate is
unchanged: 28/28 safety, at least 12/13 word completions, and p95 inference
latency at or below 2,000 ms.

| Model / exact file | Safety | Word completion | Average, first request excluded | Harness average | p95 | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Gemma 4 E2B Base `gemma-4-E2B.i1-Q6_K.gguf` | 25/28 | 12/13 | 99–116 ms | 1,518–1,665 ms | 851–1,054 ms | Fail (safety) |
| LFM2.5 1.2B Instruct `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` | 24/28 | 11/13 | 41–46 ms | 381–521 ms | 217–292 ms | Fail (safety, word completion) |

Ranges cover 6 complete Gemma runs and 4 LFM runs. Every run of a model
produced the same suggestion text and suppression for every scenario, so the
quality columns did not vary.

- **Three safety misses are the same for both models.** These are suggestions
  that the first-word confidence gate (added 2026-10-06 in `ef8eeef`) withheld.
  The suppression is `lowConfidence`, and no text was shown. The scenarios
  are open-ended continuations that expect a visible suggestion and do not list
  `lowConfidence` as allowed: `notes-list` ("…2."), `comma-clause` ("…through
  Friday,") and `sentence-start` ("…went smoothly overall. "). Neither model
  inserted unsafe text, leaked the prompt or produced an error.
- **LFM2.5's fourth miss** is `wc-schedule`. It completed "schedu" as
  "ling." ("scheduling."), but the scenario requires "le".
- The 13th word-completion case (`mid-word`, `unsafeToInsert`) is the allowed
  strictly-inside-word suppression for both models. As in July, 12/13 is the
  suite's ceiling.
- Keyword hits, a weak relevance signal and not a gate: Gemma 11/64, LFM 8/64.
  LFM had 15/64 in July.

The first-request columns:

- **Harness average** is what the harness reports. It includes the first
  scenario of each fresh process: 39.4–44.0 s for Gemma and 9.6–13.3 s for LFM.
- **First request excluded** averages the other 27 scenarios. Medians of those 27
  were 75–81 ms for Gemma and 32–35 ms for LFM.
- The harness p95 is nearest-rank over 28, so it lands on the second request
  after load. That request is still slower than steady state.

The first request is not integrity hashing. Writing the model's matching
`.sha256` marker (the `gemma4-e2b-base-q6-marker` runs) left it unchanged. Its
cause in a fresh isolated profile was not isolated further, so it is not
evidence of what a long-running installed app shows on its first keystroke.

## Harness and commands

Source: `master` at `9bff2ca7939850c1cfe650ed0b27e99e0796a7c4`, unmodified app
code. Release configuration, unsigned. Hardware: Apple M4 Max, 48 GB, arm64.
Settings, identical to July except the streaming key, which no longer exists
(streamed partials were removed on 2026-10-04 in `a643285`):

- 3 output words
- local learning off
- clipboard context off
- app context on
- in-process runtime on

```sh
xcodegen generate
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Release \
  -derivedDataPath <scratch>/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

uv run --no-project python -S Benchmarks/autocomplete/Cotyping/run_in_process_benchmark.py \
  --app <scratch>/DerivedData/Build/Products/Release/LokalBot.app/Contents/MacOS/LokalBot \
  --model "$HOME/Library/Application Support/me.dotenv.LokalBot/models/gemma-4-E2B.i1-Q6_K.gguf" \
  --output <new-directory> --repetitions 4

uv run --no-project python -S Benchmarks/autocomplete/Cotyping/run_in_process_benchmark.py \
  --app <same executable> \
  --model "$HOME/Library/Application Support/me.dotenv.LokalBot/models/LFM2.5-1.2B-Instruct-Q4_K_M.gguf" \
  --output <new-directory> --repetitions 4
```

The runner gives every repetition its own temporary home, storage folder and
settings suite, then symlinks the model in. Installed preferences and storage
are not touched. Three changes were made to the runner for this run:

- It no longer sets or checks the removed streaming setting.
- It confirms from llama.cpp's load line that the requested file was loaded.
- It records a run whose scenarios miss their contract (exit 1) and keeps going.
  Before, it stopped after the first such run.

The `gemma4-e2b-base-q6` runs predate the integrity-marker line. The
`gemma4-e2b-base-q6-marker` and `lfm2.5-1.2b-instruct` runs used the runner as
committed. One isolated smoke run of Gemma preceded them and is not included.
It was the first process after the build, its first request took 46.6 s, and its
quality results were identical. The third `-marker` repetition took keyboard focus and
received a quit mid-run, so it produced no JSON and the fourth was not run.

Model SHA-256 values match the catalog pins: Gemma `20f49b22…a9c629`, LFM
`856aeee6…413a9b9a`. Executable SHA-256 `aa0dcffe…7717a433`. See each
`manifest.json`.

## Comparability with July

July's table used a **Debug** build and code from before these changes:

- the confidence gate
- the October quality and prompt changes
- the hybrid decoder

This run is Release on current code. Read the two tables as separate
snapshots. The July passes for LFM2.5 and Gemma 4 E4B Instruct do not carry
over to today's engine. Gemma 4 E2B Base became the default because of
held-out exact next-word accuracy (34.50% vs 30.43% for LFM in the
[2026-10-02 quality report](../2026-10-02-quality/REPORT.md)), not because of
this gate.

## Hazard for whoever runs this next

`--cotyping-bench` starts the full app process. It shows a LokalBot menu-bar
icon, and in this run each LFM repetition briefly became the frontmost app,
taking keyboard focus. Run it when nobody is typing.

## Files

- `gemma4-e2b-base-q6/`, `gemma4-e2b-base-q6-marker/`, `lfm2.5-1.2b-instruct/`
  hold each run's `manifest.json` and per-run JSON.
- `summary.json` holds the per-run figures, first request, average and median
  without it, and the missed scenarios.

The per-run stderr logs (llama.cpp load output) were not kept.
