# Autocomplete quality improvement — 2026-10-02

The implemented changes improve exact next-word prediction with the existing
LFM model from **27.97% to 30.43%**. The new optional **Gemma 4 E2B Base** model
raises it to **34.50%**, a **23.3% relative improvement** over original LokalBot.
Partial-word completion also improves. These are held-out synthetic replay
results through the production engine, not observed user acceptance rates.

On the direct, identical-input Cotabby comparison, improved LokalBot scores
**30.56% with LFM** and **32.74% with Gemma**, versus **30.69% for Cotabby with
the same Gemma weights**. The former measured gap is largely closed on this
sample. The sample does not establish universal superiority or product parity.
**Cotypist quality parity remains unverified.**

The changes are built and tested, remain uncommitted, and have not been installed
or released. Installed preferences were preserved. At the evaluation freeze,
LFM was the default and Gemma was optional. Following the results, Gemma became
the product default at the user's request; existing saved selections are
preserved and the Lightweight preset retains LFM. The measurements below still
refer to the original frozen evaluation builds.

## Held-out quality

The external corpus contains 1,337 synthetic English phrases across seven
categories. Development used 140 phrases, selected independently of model
outcomes. The other **1,197 phrases / 6,667 word checkpoints** were held out.
The final inference source and executable were frozen before final evaluation;
see [finalist-freeze.json](finalist-freeze.json).

| Metric | Original LFM | Improved LFM | Improved Gemma E2B Base |
| --- | ---: | ---: | ---: |
| Correct next words | 1,865 / 6,667 | 2,029 / 6,667 | 2,300 / 6,667 |
| Next-word accuracy | 27.97% | 30.43% | **34.50%** |
| Two consecutive words correct | 8.76% | 9.91% | 12.05% |
| Three consecutive words correct | 2.86% | 3.42% | 4.26% |
| Suggestion coverage | 99.57% | 99.70% | 99.88% |
| Warm generation p50 | 25.08 ms | 27.50 ms | 52.60 ms |
| Warm generation p95 | 29.26 ms | 29.49 ms | 68.21 ms |
| Inference errors | 0 | 0 | 0 |

LFM gains **2.46 percentage points** (paired 95% bootstrap interval
**+1.58 to +3.39**). Gemma gains **6.52 points** (**+5.61 to +7.43**).
Both improve next-word accuracy in every one of the seven English categories.
Intervals resample entire phrases, paired and stratified by category, rather
than treating related checkpoints as independent observations.

Partial-word evaluation used **1,489 internal-character checkpoints** from a
separate deterministic sample of 70 held-out phrases. Original LFM completes
**62.06%** correctly, improved LFM **67.49%**, and improved Gemma **70.05%**.
Their gains are **+5.44 points** (95% interval **+1.88 to +8.76**) and
**+7.99 points** (**+3.81 to +11.93**), respectively.

An independent fixture of **32 original scenarios / 178 checkpoints** covers
email, formatting, earlier document facts, and multiple languages including
Serbian. It was written before candidate evaluation.

| Challenge category | Original LFM | Improved LFM | Improved Gemma |
| --- | ---: | ---: | ---: |
| Email | 46.15% | 46.15% | 53.85% |
| Formatting | 46.15% | 41.03% | 48.72% |
| Earlier document facts | 17.02% | 25.53% | 27.66% |
| Multilingual | 27.50% | 32.50% | 57.50% |
| Overall | 34.27% | 36.52% | **46.63%** |

This smaller fixture does **not** establish a reliable LFM-only gain: its
overall interval is **−2.27 to +6.59 points**. LFM loses on formatting, and its
two-/three-word scores fall from **13.01% / 6.14%** to **12.33% / 3.51%**.
Gemma improves the first-word score by **12.36 points** (**+5.56 to +19.13**),
but its three-word score is also below baseline (**5.26% versus 6.14%**).
Better next-word prediction does not mean every longer suggestion improves.

Exact metrics, categories and model/build provenance are in
[summary.json](summary.json); paired intervals are in
[quality-deltas.json](quality-deltas.json).

## Direct Cotabby comparison

Cotabby was built from unmodified upstream application source at
[`7724926b3e93f14e3b576ba46ff52c4f64d9712d`](https://github.com/FuJacob/cotabby/tree/7724926b3e93f14e3b576ba46ff52c4f64d9712d).
Its own headless production-path XCTest replay ran on this Mac, using the same
Gemma Q6 file and no screen context. This is a measured comparison, rather than
a comparison against its published benchmark scores.

The sample is the first 20 held-out phrase IDs per category in the fixed hash
ordering: **140 phrases / 782 checkpoints**. LokalBot's full held-out results
were restricted to precisely those checkpoints. The comparison checks exact
typed prefixes, app/title/field metadata, reference words, completeness, and
agreement between Cotabby's native scorer and the common lexical scorer.
All 782 checks agree; no scorer discrepancies were found.

| Product and model | Correct next words | Accuracy | Coverage |
| --- | ---: | ---: | ---: |
| Original LokalBot, LFM | 212 / 782 | 27.11% | 99.62% |
| Cotabby, Gemma E2B Base | 240 / 782 | 30.69% | 93.99% |
| Improved LokalBot, LFM | 239 / 782 | 30.56% | 100% |
| Improved LokalBot, Gemma E2B Base | 256 / 782 | 32.74% | 100% |

Relative to Cotabby, improved LFM is **−0.13 points** (paired 95% interval
**−2.70 to +2.40**). Improved Gemma is **+2.05 points** (**0.00 to +4.04**).
Gemma's precision among shown suggestions is **32.74%**, close to Cotabby's
**32.65%**; its higher coverage contributes to the all-checkpoint advantage.
This is evidence of comparable first-word results on these synthetic inputs,
not a formal equivalence test or a general superiority claim.

The products retain their own prompts, sampling and output-length policies.
Cotabby uses its default 12–20-word preset, temperature 0.1 and native
CotabbyInference revision `7574a21516c65fc31f5cf8ef7380a03412eed480`
(llama.cpp b9310); LokalBot uses its default three-word/five-token setting,
temperature 0.1, and its existing pinned llama.cpp v0.5.0. Both use seed
12648430; repetition penalties differ (Cotabby 1.025, LokalBot 1.05).
These differences are part of the products under test; this is not
an isolated prompt or runtime ablation. In particular, their generation
latencies must **not** be interpreted as a speed comparison at equal length.

The competitor test used one worker, a disposable ad-hoc-signed test host with
a unique bundle identity and isolated preferences. Installed Cotabby was not
changed. Upstream build fingerprints, complete observations, validation and
the isolation wrapper are preserved in the raw archive. Paired results are in
[cotabby-comparison.json](cotabby-comparison.json).

## What changed

- **Preserve what was typed.** Prefix bounding now slices text instead of
  flattening paragraphs, lists and indentation. The renderer retains the
  exact whitespace at the caret.
- **Respect completed words.** Native token healing replays horizontal
  whitespace as a required prefix, preserving the boundary after a finished
  word. Newlines remain in the conditioning context. For example, `Warm `
  previously yielded `th is a`; it now yields `and cool air`. After
  `My notes from the session:\n\nRecord `, `ed the key` becomes `the key points`.
- **Use relevant context.** A short `Subject:` or `Topic:` preface replaces
  verbose descriptions of the app, window and field. The word ceiling rises
  from 150 to 500 within the unchanged 2,500-character capture budget. The
  native runtime also enforces its physical token budget for dense text.
- **Improve rare fragments.** When the top 64 tokens contain no compatible
  completion, a lazy vocabulary prefix index chooses the best compatible
  token instead of immediately falling back to canonical tokenization.
  The index supports split UTF-8 pieces and is cleared on model unload.
- **Offer a stronger completion model.** The checksum-pinned Gemma E2B Base
  model is selectable for Autocomplete and excluded from the main chat model
  picker. It is a 3.85 GB download versus LFM's 0.73 GB and is intended for
  Macs with at least 16 GB of memory. Peak resident memory was not measured.
- **Make quality reproducible.** `--cotyping-replay` starts before migration,
  AppState, capture and learning. It exercises the production request builder,
  native generation, healing and normalization using explicit synthetic inputs.

No screen-library retrieval, clipboard use, writing-history collection, or
network inference was enabled to obtain these gains. The earlier small
token-ranking optimization is also retained; its separate
[latency report](../2026-10-02-comparison/REPORT.md) does not explain the quality
gains above.

## Rejected experiments and remaining limits

Development tested Qwen3.5 0.8B Base, LFM2.5 1.2B Base, Gemma E2B and E4B,
alternate prompts, app-context removal and larger output budgets. The complete
29-run development ledger is in [experiments.csv](experiments.csv), with
hashes and settings in [experiments.json](experiments.json).

Removing context reduced quality. Preserving raw trailing spaces without native
healing was particularly harmful. Instruction prompts and assistant-prefill
prompts also performed worse. Raising the output budget from five to twelve
tokens did not improve first-word quality and increased latency. E4B offered
no gain over E2B on the development set and was slower. No inference changes
were made after the finalist freeze in response to held-out results.

The existing 28-case completion/safety suite has a remaining LFM regression:
`Let me double-check my schedu` now completes as `ling.` instead of the expected
`le…`. This extends the typed fragment but fails the existing exact-word
criterion. Original LFM passes **28/28** behavior assertions, improved LFM
**27/28**, and improved Gemma **28/28**. The expectation was not weakened or
hidden. Keyword hits also fall from 15/64 to 10/64 for LFM (Gemma: 12/64);
this small suite is not an aggregate semantic-quality win.

Cold readiness remains an issue. In fresh-process suite runs, the first
request takes **10.43 seconds** for original LFM, **10.70 seconds** for improved
LFM and **47.47 seconds** for Gemma; Gemma's second request takes **2.96 seconds**.
These include loading/setup/compilation and are single observations, not stable
cold percentiles. The app already prewarms the model; no UI measurement was
made to establish how much of this delay a user sees. Including latency
targets, the suite passes **27/28, 26/28 and 26/28** respectively. Its CLI exit
code gates behavior assertions only. See [safety.json](safety.json).

Cotypist's official [usage guide](https://cotypist.app/help/tips) emphasizes
useful first-word suggestions, word-by-word acceptance, and updating predictions
as more letters are typed. Its [personalization guide](https://cotypist.app/help/personalization)
describes optional local writing-history personalization. Those informed the
evaluation priorities, but no matched Cotypist run was performed. The changes
do not establish parity with its personalized suggestions or actual typing
experience. A remote interaction comparison and acceptance/keystroke-savings
evaluation are the next evidence needed; no UI tests ran locally.

## Method, validation and reproduction

Hardware: Apple M4 Max, 48 GiB, macOS 27.0.1. LokalBot measurements use Release
builds. The original source baseline is
`530bcc2cc1c28c28adf6db3899ab14d5d615fd46`, instrumented with the synthetic
headless replay entry point. Every run records its executable and model hash.
The final executable SHA-256 is
`726afa188d020e84d3fa542a2eaae5b1ac5c634d31f0a358c815b80515010709`.

Partitioning sorts IDs per category by SHA-256 of `1337:<id>`; the first 20 form
development and the rest form held-out. Partial-word testing takes the first
10 held-out IDs per category in that ordering and every internal character
position after the first word. The model sees only prior typed text and
permitted app/title/field metadata. Future reference words, corpus categories
and screen text are never passed to inference. Suppressions and errors remain
in the accuracy denominator. Case and straight/curly apostrophes are normalized;
two-/three-word rates require consecutive matches and enough remaining words.

The replay prewarms the model before timing. Warm timing covers native
generation and normalization, and excludes loading, keyboard handling,
debounce, AX validation and rendering. Runs use a fixed seed and were serial.
Exact lexical matching can reject perfectly good alternate wording. The corpus
is public and synthetic; the development/held-out split prevents task tuning
leakage, not possible pretraining exposure. The small multilingual challenge
is directional evidence, not per-language qualification. Personalized profiles,
other model choices, remote engines, and the server fallback were not evaluated.

Validation:

- Release build succeeded; dependency pins were preserved and XcodeGen ran
  after source files were added.
- **215 focused Swift unit tests passed**, with zero failures, covering request
  construction, context, healing, Unicode, normalization, streaming, settings,
  model catalog and benchmark criteria. **8 Python scoring/pairing tests pass.**
- A production replay regression check fails on all 178 original challenge
  prompts and passes on all 178 improved prompts for both models. It catches
  loss of exact bounded text, paragraphs and caret whitespace. The old binary
  is the reverted control; see [context-regression-proof.json](context-regression-proof.json).
- Strict SwiftLint and diff checks pass. All frozen inference source hashes
  still match. Validation details are in [validation.json](validation.json).

Changed test expectations: prompt rendering retains trailing whitespace;
spaces after completed words become required decoding prefixes; newlines stay
in context; surface hints use `Subject:` / `Topic:`. These reflect the intended
behavioral fixes. The exact `schedule` expectation remains unchanged.

See the [runner instructions](../../README.md). For this same held-out run:

```sh
uv run --no-project python -S Benchmarks/autocomplete/Cotyping/quality_replay.py \
  --app /absolute/path/to/LokalBot.app/Contents/MacOS/LokalBot \
  --model /absolute/path/to/model.gguf \
  --corpus /absolute/path/to/cotabby/CotabbyTests/Fixtures/phrase-prediction-1337.json \
  --split heldout --output /absolute/path/to/new-results
```

Use `--mode midword --per-category 10` for partial words. Use the original
`Benchmarks/autocomplete/Cotyping/quality-cases.json` with `--split all` for the independent
challenge. Run `compare_quality.py` on paired reports and `compare_cotabby.py`
on completed competitor/LokalBot runs; both are in the benchmark directory.

[raw-runs.tar.gz](raw-runs.tar.gz) contains all measured variants, exact inputs,
observations, reports, manifests, logs and the competitor test wrapper.
[archive-manifest.json](archive-manifest.json) records every archived file's
hash. Source/licensing attribution is in [ATTRIBUTION.md](ATTRIBUTION.md).

## Subsequent default-model decision

At the user's request, Gemma E2B Base is now the fresh-install default,
recommended setup model, and Balanced local preset's autocomplete model. LFM
remains in the Lightweight local preset. Saved selections are preserved.
The setup license link now points to [Google's Gemma license](https://ai.google.dev/gemma/apache_2).
No inference policy or model artifact changed in this follow-up.

Validation: Debug build-for-testing, **63 selected non-UI tests**, strict
SwiftLint, documentation links and diff checks passed. This follow-up has
not been installed or released; the benchmark hashes above remain historical.

### Changed test expectations

- `ModelCatalogTests/testQualityCotypingModelIsPinnedAndOnlyOfferedForAutocomplete`:
  fresh settings select Gemma instead of LFM, following the user's quality-first
  default choice. It also checks the recommendation and Gemma license link.
- `ModelCatalogTests/testRecommendedCotypingModelUsesBenchmarkedLFMQuant` was
  renamed `testLightweightCotypingModelKeepsBenchmarkedLFMQuant`: LFM's artifact
  checks remain, but its role is now the explicit lightweight alternative.
- `ModelCatalogTests/testPresetModelSummaryNamesEveryRoleModel`: Balanced local
  names Gemma; Lightweight local continues to name LFM, matching those presets.
- `CotypingSettingsTests/testTolerantDecodeKeepsOtherDefaults`: settings without
  a saved model explicitly expect Gemma. A separate saved-selection check
  confirms that persisted LFM and custom choices are preserved.
