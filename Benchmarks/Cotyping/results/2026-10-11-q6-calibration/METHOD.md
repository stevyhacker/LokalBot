# E2B Q6 publisher and language-calibration comparison

This study keeps the E2B **base** checkpoint family, native decoder, prompt renderer,
sampler, token budget, thread settings and replay executable fixed. It does not
change the installed application or model. The machine-readable plan was frozen
before candidate inference.

## Arms

1. `q6`: installed mradermacher importance-weighted Q6_K, the current default.
2. `static`: the same publisher's static Q6_K.
3. `local_static`: Q6_K generated from the pinned ggml-org E2B BF16 conversion.
4. `english`: the same source and quantizer, with English calibration.
5. `bilingual`: the same source and quantizer, with English/Serbian Latin calibration.
6. `animateus`: a separate publisher's importance-weighted E2B base Q6_K.
7. `sporky`: SporkySporkness's E2B base Q6_K.

The local three-arm comparison isolates the calibration choice. Cross-publisher
comparisons additionally reflect each publisher's converter and source snapshot.
All model revisions, file sizes, full SHA-256 values, tool hashes and conversion
commands are saved. GGUF architecture, tokenizer and tensor layouts are inspected.
No model is requantized from the installed Q6 file.

### Beginning-of-sequence control

Inspection found one tokenizer-metadata difference: the ggml-org source,
Animateus and Sporky files set `tokenizer.ggml.add_bos_token=true`, while the
current and published static files set it false. LokalBot requests automatic
special-token insertion, so unchanged prompt text alone would not control input
tokens. Before any candidate replay, the experiment aligns this flag to false
in temporary APFS-cloned evaluation files. The original downloads/builds remain
intact; every byte except that boolean is verified unchanged. All evaluated
tokenizer metadata must then match the current model exactly. Published model
hashes and derived evaluation hashes are reported separately.

Calibration itself uses the unmodified BF16 source and its native BOS convention
for both language arms. The comparison therefore concerns quantized weights
under the current product input-token convention. It does not measure the
publishers' as-shipped BOS behavior or propose changing the product prompt.

## Calibration

Public FLORES-200 dev and devtest text is used **only for calibration**. Serbian
Cyrillic text is deterministically transliterated to Serbian Latin before
tokenization. No Cyrillic benchmark arm is involved. Attribution and the
CC-BY-SA-4.0 license accompany any redistributed calibration text.

Both calibrated models use 32,768 token positions at a 512-token context:

- English: first 32 English chunks plus the next 32 English chunks.
- Bilingual: first 32 English chunks plus first 32 Serbian Latin chunks.

Each 32-chunk matrix is computed on the same BF16 source. The native imatrix tool
merges the two component accumulators before Q6_K quantization. Output-weight
statistics are included. These are corpus-derived importance weights, not model
fine-tuning, and no evaluation quality labels enter calibration.

FLORES is mostly encyclopedic/news text, not a representative sample of every
person's typing. This experiment tests one modest calibration budget and recipe;
a weak result would not establish that all bilingual calibration is ineffective.

## Evaluation and timing

Forty-eight newly authored fictional bilingual scenarios produce 288 checkpoints:
144 English and 144 Serbian Latin, comprising 96 word boundaries and 192 midword
positions. Full sentences are checked for overlap with five previous corpus files
and the calibration text. Exact checks do not prove semantic independence.

The existing quantization runner executes 91 serial native processes: two
reverse-order rounds of fresh, long-field, typing/backspace and cancellation
fixtures; two additional warmed fresh rounds; one confidence trace; and two
native equal-frequency rounds. All arms receive byte-identical rendered prompts.
Eight warmups per process are excluded. The two extra warm rounds are predeclared,
not added after looking for a preferred timing outcome.

The decoder uses certified prefix search, width four / 32 expansions, two
generation and prefill threads, 256-token prefill chunks, six output tokens/four
words, temperature 0.1, repeat penalty 1.05, top-p 0.7, top-k 20, min-p 0.08 and
seed 0xC0FFEE. Production confidence thresholds are 0.1/0.31.

Native generation time excludes model loading, debounce, accessibility and ghost
rendering. Long-field prewarm is separately performed by the frozen runner.
Peak RSS is process resident memory, not total system/GPU memory. Cancellation
timing requires both paired requests to cancel and includes replacement latency;
four independent cancellation scenarios make those tail estimates exploratory.

## Equal frequency and Claude

Unlabeled confidence traces set per-language boundary thresholds to the current
Q6's shown count, or a lower common feasible count if necessary. Native midword
outputs are preserved and fallback/primary ratio stays 3.1. Actual native outputs
and latency are rerun at those thresholds; trace timing is not used as production
latency. This is an evaluation-corpus matching diagnostic, not deployable tuning.

Claude Opus receives only fictional typed prefixes and shuffled anonymous
continuations, with tools disabled. It receives neither the intended future,
model/publisher labels, timing, source code nor calibration text. Identical
continuations are rated once within each case. Suppressed suggestions have zero
utility. Twenty-four cases repeat with reversed options to measure reliability.

Quality uses the established -2..2 usefulness rubric. Report helpful/poor counts,
per-language utility, and paired intervals from 5,000 bootstrap draws over the
48 bilingual source scenarios. Repeated runs are not independent quality samples.
Intervals are exploratory and not corrected for all comparisons. Claude scores
are model opinions, not observed human acceptance.

## Publication and decision

Publish reports, examples, source/protocol hashes, raw synthetic outputs, judging
packets, calibration provenance and validation receipts in PR #230. Model weights
and application binaries remain local. Keep the installed Q6 default; describe
any supported candidate advantage and the remaining uncertainty.
