**E2B Q6 publishers and English/Serbian Latin calibration — 11 October 2026**

**Retain the current mradermacher i1 Q6.** None of the six alternatives demonstrates a quality or normal-generation-speed upgrade. Current Q6 has the best overall and per-language mean Claude scores in this sample. All candidate-versus-current quality intervals include zero; this supports keeping the established default, not claiming that its weights are conclusively superior.

The requested comparison includes published static Q6 and a locally built English/Serbian Latin calibrated Q6. Additional controls are local static and English-only calibrated Q6, plus same-base files from Animateus and Sporky. The three local builds share one pinned BF16 source and quantizer, isolating the effect of calibration. All arms use E2B **base**, the same native decoder, prompt, sampler and token budget. Cross-publisher source snapshots and converter versions are an additional provenance limitation.

**Equal suggestion frequency and latency**

Every variant shows exactly **112/144 English and 109/144 Serbian Latin suggestions**, 221/288 total. Matching uses unlabeled confidence traces followed by two actual native timing runs. It changes no current-Q6 output and preserves every native midword output. These fitted thresholds are evaluation-only; product gates remain 0.1/0.31.

| Variant | Warm native mean / p95 | Equal-frequency mean / p95 | Claude helpful / poor | Overall utility difference vs current, 95% interval |
|---|---:|---:|---:|---:|
| Current mradermacher i1 Q6 | 51.7 / 103.9 ms | 52.1 / 106.0 ms | **184 / 21** | Reference |
| mradermacher static Q6 | 52.4 / 105.6 ms | 52.1 / 103.3 ms | 177 / 23 | −0.031 [−0.087, +0.024] |
| Local static Q6 | 52.4 / 104.7 ms | 52.1 / 102.9 ms | 177 / 23 | −0.031 [−0.087, +0.024] |
| Local English-calibrated Q6 | 52.2 / 105.2 ms | 51.9 / 104.2 ms | 181 / 21 | −0.017 [−0.059, +0.021] |
| Local EN/SR Latin calibrated Q6 | 52.6 / 106.1 ms | 51.7 / 104.6 ms | 179 / 23 | −0.035 [−0.080, +0.007] |
| Animateus Q6 | 52.1 / 105.1 ms | 51.8 / 104.2 ms | 178 / 25 | −0.042 [−0.090, +0.003] |
| Sporky Q6 | 52.3 / 104.7 ms | 52.0 / 104.0 ms | 177 / 23 | −0.031 [−0.087, +0.024] |

Utility is Claude's −2..2 usefulness score, with silence zero, averaged over **all 288 checkpoints**. Helpful means positive; poor means negative. All variants offer 221 suggestions, so these counts do not reward offering less often. Warm timing uses two predeclared additional rounds at the production gates; the equal-frequency column measures the actual outputs judged in the matched comparison. Each timing column has 576 repeated observations per arm, not 576 independent writing scenarios.

The bilingual candidate's matched mean is only 0.34 ms lower than current (95% interval −1.00 to +0.32 ms). At production gates its warm mean is 0.86 ms higher (+0.15 to +1.53 ms). Neither supports a useful speed upgrade. Native latency excludes model loading, debounce, accessibility and overlay rendering. All Q6 files are approximately 3.85 GB with approximately 4.15–4.16 GB peak process RSS; these alternatives offer no meaningful memory saving.

**English and Serbian Latin**

Current Q6 scores **1.056 English / 0.688 Serbian Latin**, compared with **1.035 / 0.646** for published static and **1.035 / 0.639** for bilingual calibration. Current has 101 helpful / 3 poor English suggestions and 83 / 18 Serbian Latin. Bilingual has 99 / 4 and 80 / 19 respectively. It wins 8 checkpoints and loses 14 against current overall, with 266 utility ties. Examples include both improved phrases and invented or awkward tails; see [exact suggestions](EXAMPLES.md).

The controlled calibration comparison also provides no evidence that adding Serbian text improved Serbian autocomplete. Bilingual versus local static is **−0.003 overall** [−0.049, +0.042], and **−0.007 Serbian Latin** [−0.104, +0.090]. English-only calibration is mildly positive versus local static, **+0.014 overall** [−0.028, +0.059], but remains uncertain and below current Q6's point estimate. Bilingual versus English-only is −0.017 overall [−0.045, +0.007]. This tests one calibration recipe, not the value of every possible bilingual corpus.

Both calibrated builds used **32,768 token positions** from public FLORES-200: English-only versus half English / half Serbian Latin, with identical source, tool, context and quantization settings. Serbian text was transliterated before calibration. Calibration text and newly authored fictional evaluation sentences are separate. FLORES's encyclopedic/news style is a limitation for everyday typing; there was no fine-tuning or use of quality labels to build weights.

**Publisher and tokenizer findings**

The current and mradermacher static files disable automatic beginning-of-sequence (BOS) insertion. The ggml-org source, Animateus and Sporky files enable it. LokalBot asks the tokenizer to insert special tokens, so identical prompt strings alone would not keep input tokens fixed. Before candidate inference, temporary evaluation copies were aligned to the current false setting. Only that single boolean byte changed; original files and both sets of hashes are retained. These are **BOS-aligned weight comparisons**, not benchmarks of those publishers' as-shipped tokenization. Calibration used the unchanged BF16 source and its native BOS convention for both language arms. [Protocol and controls](METHOD.md) · [BOS receipts](bos-alignment.json).

Sporky and mradermacher static have **601/601 identical tensor byte hashes**. Their 1,440 paired fresh/long/dynamic/matched outputs also match exactly after BOS alignment. A different repository name is not necessarily a different quantization. All seven evaluated files use the same tensor shapes and precision mix: 317 Q6_K tensors, 283 F32 tensors and one BF16 projection tensor. Full model hashes differ and are pinned in [models.json](models.json).

[Unsloth](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF), [Bartowski](https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF) and [LM Studio](https://huggingface.co/lmstudio-community/gemma-4-E2B-it-GGUF) were checked. Their relevant public listings use E2B **instruction-tuned**, including separate QAT/dynamic variants. Substituting them would change the checkpoint, so they were not benchmarked as fixed-base alternatives. This is not evidence that they are worse. [ggml-org's base release](https://huggingface.co/ggml-org/gemma-4-E2B-GGUF) supplies the BF16 source used here. [Full dated publisher survey](PUBLISHERS.md).

**Reliability and remaining limits**

All **91 serial native processes / 18,144 measured observations** passed. Prompt bytes and evaluated tokenizer metadata agree, 9,072 repeated outputs are deterministic, and 672 replacement/cold checks pass. Claude Opus 5.5 completed all 21 blind batches: 223 primary cases with any suggestion, 65 all-silent cases retained as zero, and 24 reversed-order repeat cases. Only fictional prefixes and anonymous suggestions were sent, with tools disabled.

Judge repeat agreement is **19/28 exact scores (67.9%)** and **27/28 positive-versus-nonpositive decisions (96.4%)**. One primary case has a preferred-option/score inconsistency; excluding it does not alter the conclusion. Some explanations misdescribe the generated Serbian word, so the exact suggestion strings matter more than the judge's prose. These are model opinions, not human acceptance rates. Intervals use 5,000 paired bootstrap draws over 48 bilingual scenarios and are exploratory, without correction for multiple comparisons.

Long-field, typing/backspace and cancellation results are preserved in [all tables](TABLES.md) and [summary.json](summary.json). Several candidates recover faster after cancellation, but only four independent cancellation scenarios were tested, and none combines that with improved quality and normal generation. Identical-weight static/Sporky runs also differ in long-field timing (171.4 versus 178.8 ms), demonstrating environmental variation. Reverse ordering and warm rounds reduce, but do not eliminate, desktop load and thermal drift. Do not interpret every small timing difference as an effect of quantization.

**Useful next steps**

1. Keep current Q6; this experiment gives no reason to migrate downloads or installed weights.
2. Make BOS behavior an explicit, validated runtime/model contract. Any experiment with BOS enabled should be a separate quality study with a fresh holdout; this comparison deliberately kept the current token sequence fixed.
3. If pursuing calibration, try a larger public/synthetic corpus shaped like English and Serbian Latin typing, with source BOS conventions controlled during calibration as well. Validate on new scenarios and human ratings before another default proposal. The current 32k-token FLORES recipe did not help.
4. Prioritize actual typing-to-visible latency and interrupted-request scheduling over another Q6 publisher swap. Normal Q6 timing here is essentially tied, and prior cancellation tradeoffs remain unresolved.

No app source, default, model catalog, dependency pin or installed setting changed in this study. The installed executable and current Q6 hashes are unchanged from this study's start. No app build, reinstall, local UI test, release, or manual CI action was performed. [Validation and reproduction](VALIDATION.md) · [Complete raw evidence](evidence.tar.gz) · [Archive manifest](evidence-manifest.json).
