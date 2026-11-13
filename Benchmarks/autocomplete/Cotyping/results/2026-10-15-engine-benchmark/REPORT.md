# Autocomplete engine benchmark — 2026-10-15

This is the first run of the revamped benchmark (`Benchmarks/autocomplete/Cotyping/engine_benchmark.py`).
It covers the default autocomplete model, **Gemma 4 E2B Base `Q6_K`**, and the
Lightweight preset's **LFM2.5 1.2B Instruct `Q4_K_M`**.

## Results

**Both models made no unsafe suggestions.** Gemma 4 E2B Base predicts the next
word slightly more often, is right more often when it shows something, and is
the only one of the two that suggests much in Serbian. LFM2.5 is two to three
times faster. Both stay under about 100 ms p95 per keystroke on this Mac.

| | Gemma 4 E2B Base (default) | LFM2.5 1.2B Instruct (Lightweight) |
| --- | ---: | ---: |
| Unsafe results, 28 checks × 5 passes | **0** | **0** |
| Checks: shown / withheld / allowed silence | 24 / 3 / 1 | 24 / 3 / 1 |
| Word completions | 12/13 | 12/13 |
| Next-word accuracy, 788 word positions | **23.1%** | 20.7% |
| — English, 624 positions | 25.3% | 24.2% |
| — Other languages, 164 positions | 14.6% | 7.3% |
| Suggestion shown (coverage) | 46.1% | 48.1% |
| Right when shown (precision) | **50.1%** | 43.0% |
| Per keystroke while typing, median / p95 | 56 / 102 ms | **26 / 76 ms** |
| Checks, warm median / p95 | 60 / 103 ms | **18 / 29 ms** |
| Model load | 0.65 s | 0.16 s |

Gemma minus LFM accuracy, with phrase-level paired bootstrap intervals
(10,000 resamples, seed 1337):

| Group | Difference (95% interval) |
| --- | --- |
| All 96 phrases | +2.4 points (−0.1 to +5.0) |
| English, 72 phrases | +1.1 points (−1.4 to +3.5) |
| Other languages, 24 phrases | +7.3 points (0.0 to +15.1) |

Gemma alone was right at 58 positions and LFM alone at 39. In English the two
models are statistically tied. The overall lead comes from the other languages:
LFM2.5 shows almost nothing in Serbian (2% coverage, 0% accuracy), while Gemma
reaches 8–9%. Those groups are small, so read the intervals, not the points.

### What the checks show

- **Withheld (both models, the same 3):** `notes-list`, `comma-clause` and
  `sentence-start`. These are open-ended continuations where the first-word
  confidence gate (`ef8eeef`) holds back an unsure guess. Under the old scoring
  these three made both models "fail safety".
- **Allowed silence (both):** `mid-word`, inside "rec|eive", where the engine
  declines to insert. That is permitted.
- **Word completions:** 12/13 for both. LFM2.5 completes "schedu" as "ling."
  ("scheduling."), which the old check rejected and the new one accepts.
- **Determinism:** every one of the 5 passes showed identical suggestions for
  both models.

### Accuracy by category

Accuracy is the exact first word out of all positions, so silence counts as a
miss. Coverage is the share of positions where anything showed.

| Category | Positions | Gemma accuracy | LFM accuracy | Gemma coverage | LFM coverage |
| --- | ---: | ---: | ---: | ---: | ---: |
| email | 52 | 50.0% | 42.3% | 67% | 87% |
| formatting | 39 | 41.0% | 38.5% | 67% | 77% |
| long-context | 47 | 19.1% | 23.4% | 53% | 83% |
| conversation | 76 | 23.7% | 19.7% | 49% | 51% |
| work | 76 | 14.5% | 13.2% | 38% | 51% |
| technology | 86 | 20.9% | 20.9% | 49% | 53% |
| everyday | 80 | 25.0% | 28.7% | 46% | 51% |
| travel | 83 | 26.5% | 21.7% | 51% | 47% |
| science | 85 | 21.2% | 22.4% | 54% | 48% |
| multilingual (Serbian, German, French, Spanish) | 40 | 35.0% | 30.0% | 55% | 45% |
| serbian-latin | 66 | 7.6% | 0.0% | 14% | 2% |
| serbian-cyrillic | 58 | 8.6% | 0.0% | 22% | 2% |

## What changed from the old check

The [July](../2026-07-21-model-debounce-benchmark.md) and
[October 14](../2026-10-14-engine-bench/REPORT.md) runs used the original
28-scenario check, and it had five problems:

1. **Silence counted as unsafe.** It scored a missing suggestion as a safety
   failure, so the confidence gate looked like a defect.
2. **One right answer per fragment.** It accepted only one word tail, so
   "scheduling" was wrong.
3. **Latency measured startup.** The average was dominated by a 10–40 s first
   request in a freshly launched app process, and p95 over 28 samples landed on
   the second request.
4. **It took keyboard focus.** It started the full app, which added a menu-bar
   icon and took focus.
5. **No accuracy measure.** It said nothing about whether suggestions were
   right.

The revamp keeps the same 28 scenarios and fixes each problem:

- **Outcomes instead of pass/fail.** Each result is now shown, allowed silence,
  withheld, a wrong word, unsafe or an error. Only unsafe and error fail.
- **Every real word counts.** Word completions accept any real word that fits
  the fragment.
- **Headless engine run.** `--cotyping-bench --model-path` runs before app
  startup on `LlamaCotypingRuntime.forAutocomplete()`, the runtime the app
  builds. It uses fresh-install settings (4 words) and times loading on its own.
  The first pass is reported apart from 4 warm passes.
- **Next-word accuracy.** The runner replays every word boundary of the 96
  checked-in original phrases.
- **Typing latency.** It also types 8 of those phrases one character at a time
  through the same production settings.
- **Settings check.** Each replay observation must report the production hybrid,
  `certified` prefix search, 2 threads and prefix healing, or the run stops.

## Method

Source: commit `15d7a26` on this branch, clean, from `master` `9bff2ca`.
Release build, unsigned. Apple M4 Max, 48 GB, macOS 27.0.1.

```sh
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Release \
  -derivedDataPath <scratch>/DerivedData -clonedSourcePackagesDirPath .build/SourcePackages \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build

uv run --no-project python -S Benchmarks/autocomplete/Cotyping/engine_benchmark.py \
  --app <scratch>/DerivedData/Build/Products/Release/LokalBot.app/Contents/MacOS/LokalBot \
  --model "$HOME/Library/Application Support/me.dotenv.LokalBot/models/gemma-4-E2B.i1-Q6_K.gguf" \
  --output <dir>/gemma4-e2b-base-q6

uv run --no-project python -S Benchmarks/autocomplete/Cotyping/engine_benchmark.py \
  --app <same executable> \
  --model "$HOME/Library/Application Support/me.dotenv.LokalBot/models/LFM2.5-1.2B-Instruct-Q4_K_M.gguf" \
  --output <dir>/lfm2.5-1.2b-instruct
```

The whole run took 60 s for Gemma and 30 s for LFM2.5, with a 1-minute pause
between them. No process took keyboard focus. The macOS foreground log shows
only `loginwindow`, the lock screen, during the Gemma run.

**Corpora:**

- `quality-cases.json`: 32 phrases (email, formatting, long-context documents
  of about 1,550 characters, multilingual).
- `hybrid-confirmation-cases.json`: 64 phrases (six English topics, Serbian
  Latin and Cyrillic).

Both are original synthetic text written for earlier LokalBot studies, and
their SHA-256 values are in each `manifest.json`. The hybrid set confirmed the
hybrid decoder before it shipped, so it is not held out from product decisions.

**Scoring:**

- **Accuracy** follows `quality_replay.py`: the first suggested word must equal
  the next word, ignoring case and apostrophe style.
- **Precision** is correct ÷ shown.
- Eight untimed warmup requests open each replay.
- Percentiles are nearest-rank.
- Typing latency covers keystrokes that ran the model, which was all 363 in
  both runs.

**Boundary:** these are engine timings only. Input monitoring, debounce,
accessibility reads, screen and memory context, learning and drawing the
suggestion are not included. Accuracy uses typed text plus app and window title
only, while the app also reads nearby screen text, so real suggestions have more
context than this.

**Not comparable:** the earlier Cotabby-corpus figures (34.50% vs 30.43% on
2026-10-02) used a different corpus, the pre-hybrid decoder and no confidence
gate.

## Files

Each model folder holds:

- `manifest.json`: hashes, source commit, hardware, settings.
- `checks.json`: 28 scenarios, pass 1 outcomes, latency.
- `accuracy.json`: per-position scores and category breakdown.
- `typing.json`: per-keystroke latencies.
- `summary.json`.

Replay inputs, raw observations and stderr logs were not kept; the inputs are
regenerated from the corpora by the script.
