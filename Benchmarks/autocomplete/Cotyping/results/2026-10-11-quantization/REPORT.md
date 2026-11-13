**E2B quantization results — 11 October 2026**

**Keep E2B Q6_K as the default.** Q4_K_M is the best short-request speed candidate, but it does not establish a quality-preserving upgrade for English and Serbian Latin. Q8_0 has the highest mean Claude score, yet its quality advantage is uncertain and it costs more latency and memory. No alternative passes the study's combined adoption guard. The installed app and model remain unchanged.

The comparison used the same E2B base family, current decoder, prompt bytes, sampler and token budget: **65 serial native processes, 12,960 measured observations, 288 distinct quality checkpoints**, and Claude Opus 5.5 blind ratings. Main confidence thresholds stayed fixed; a separate native replay matched every quantization to **124/144 English and 108/144 Serbian Latin suggestions**. No Cyrillic evaluation was included.

**What is worth keeping**

- **Q4_K_M:** 9.4% faster warmed short requests (53.4 → 48.4 ms) and about 0.42 GB less peak resident memory. At equal frequency, Claude found 175 helpful / 34 poor suggestions, versus Q6's 177 / 29. Serbian Latin utility fell by 0.049 per checkpoint in this sample; the 95% interval is −0.188 to +0.083, so this is not proof of a population-wide degradation, but it fails to establish non-regression. Cancellation-through-replacement also increased 216.9 → 222.0 ms on the paired subset. This is a possible future low-latency tradeoff, not a default upgrade.
- **IQ4_XS:** smallest file and resident set, saving about 0.54 GB; long-field generation improved 5.1% (151.4 → 143.7 ms), with better dynamic-typing timing too. Short-request mean was effectively unchanged. It produced 32 poor suggestions versus 29, including 25 versus 22 in Serbian Latin. Useful as a memory-constrained research candidate, with no demonstrated quality-preserving overall improvement.
- **Q5_K_M:** only 5.6% smaller on disk, but warmed short generation was 6.6% slower and long/recovery timings also regressed. Its small quality advantage is uncertain (+0.031 utility, 95% interval −0.035 to +0.097). No practical upgrade here.
- **Q8_0:** 29.2% larger file, about 1.12 GB more peak resident memory and 8.9% slower warmed short generation. Its equal-frequency mean utility was 0.851 versus Q6's 0.802: +0.049, 95% interval −0.007 to +0.104. Serbian poor suggestions fell 22 → 18, but English poor suggestions rose 7 → 9. The uncertain gain does not justify replacing Q6 on this Mac.

Small score differences should be treated cautiously: reversed-order repeat ratings agreed exactly only 66.7% of the time, although positive-utility versus silence agreed 89.7%. Every candidate's overall and per-language utility-difference interval includes zero. There was no numeric-score/preference inconsistency. Quality was judged on fresh checkpoints, not every long-field or dynamic-typing output; this is not a human typing trial.

**Recommended next steps**

Keep the current Q6 default and decoder. If a quantization follow-up is desired, prioritize Q4_K_M: it is the only clear short-generation speed lead, and the remaining questions are a fresh Serbian Latin quality sample and a larger independent cancellation cohort. IQ4_XS is the better direction only when memory or long fields are the main constraint. Do not adopt Q8 just because it stores more bits.

The large embedding tables are the main remaining size lever: these Q4 artifacts retain about 2.26 GB of Q6 embedding weights. A custom lower-bit embedding conversion would be a separate quality experiment from the original checkpoint, not a reason to blindly requantize the current file. Other Macs, actual user acceptance and first-visible UI latency remain unmeasured.

[Concrete wins and regressions](EXAMPLES.md) · [Validation and reproduction](VALIDATION.md) · [Machine-readable results](summary.json) · [Raw evidence](evidence.tar.gz) · [Evidence manifest](evidence-manifest.json)

**Warmed short-request timing and resource cost**

| Quantization | File GB | File change | Warm mean / p95 ms | Mean change vs Q6 | Peak RSS GB¹ |
|---|---:|---:|---:|---:|---:|
| Q6_K (current) | 3.845 | +0.0% | 53.4 / 107.2 | +0.0% | 4.15 |
| Q4_K_M | 3.428 | -10.9% | 48.4 / 96.3 | -9.4% | 3.74 |
| IQ4_XS | 3.304 | -14.1% | 53.4 / 100.8 | +0.0% | 3.61 |
| Q5_K_M | 3.630 | -5.6% | 56.9 / 111.4 | +6.6% | 3.94 |
| Q8_0 | 4.967 | +29.2% | 58.2 / 117.2 | +8.9% | 5.28 |

¹ Median of ten production processes’ peak resident memory, including mapped weights; decimal GB. This is not a measurement of total system/GPU memory. Separate process footprint stays around 0.41 GB for every arm. Warmed timings use the two additional reversed-order rounds (576 observations per model).

**Production timing, including the original two passes**

| Quantization | Fresh mean / p95 ms | Long mean / p95 ms | Typing/backspace mean / p95 ms |
|---|---:|---:|---:|
| Q6_K (current) | 53.6 / 107.5 | 151.4 / 243.5 | 45.8 / 85.9 |
| Q4_K_M | 49.1 / 99.5 | 151.0 / 245.0 | 39.5 / 83.2 |
| IQ4_XS | 53.4 / 99.7 | 143.7 / 228.0 | 41.0 / 76.6 |
| Q5_K_M | 56.4 / 109.8 | 159.7 / 260.7 | 47.0 / 92.8 |
| Q8_0 | 72.2 / 160.2 | 159.8 / 251.0 | 51.4 / 118.1 |

Q8 fresh means were 86.7 and 57.8 ms in the original passes. The extra warm-run result above avoids using that first-use effect as the estimate of everyday short-request latency. Long/dynamic/cancellation timings retain the original two-pass cohort; they were not rerun in the warm-only follow-up.

**Equal suggestion frequency**

Every arm shows 124/144 English and 108/144 Serbian Latin suggestions: 232/288 overall. All midword outputs remain unchanged by frequency matching. The thresholds below are evaluation-only.

| Quantization | English primary / fallback | Serbian Latin primary / fallback | Matched mean / p95 ms | Paired mean difference [95% interval], ms |
|---|---:|---:|---:|---:|
| Q6_K (current) | 0.0996 / 0.3089 | 0.1039 / 0.3220 | 53.5 / 107.6 | +0.00 [+0.00, +0.00] |
| Q4_K_M | 0.0874 / 0.2710 | 0.0852 / 0.2640 | 49.2 / 97.8 | -4.31 [-5.45, -3.09] |
| IQ4_XS | 0.0906 / 0.2810 | 0.1040 / 0.3224 | 53.8 / 101.0 | +0.35 [-0.84, +1.66] |
| Q5_K_M | 0.0982 / 0.3044 | 0.0975 / 0.3022 | 56.9 / 111.2 | +3.41 [+2.18, +4.71] |
| Q8_0 | 0.1008 / 0.3125 | 0.1041 / 0.3226 | 57.5 / 114.8 | +4.01 [+3.16, +4.95] |

**Claude quality ratings**

Usefulness is an ordinal −2..2 score relative to silence=0, averaged over every checkpoint, including suppressed suggestions. Helpful means >0; poor means <0. Each language has 144 distinct checkpoints. These are model judgments, not acceptance rates.

At unchanged production thresholds:

| Quantization | EN shown | EN helpful / poor | EN mean utility | SR Latin shown | SR Latin helpful / poor | SR Latin mean utility | Overall difference [95% interval] |
|---|---:|---:|---:|---:|---:|---:|---:|
| Q6_K (current) | 124 | 103 / 7 | 1.028 | 108 | 74 / 22 | 0.576 | +0.00 [+0.00, +0.00] |
| Q4_K_M | 120 | 101 / 10 | 1.021 | 107 | 71 / 24 | 0.528 | -0.03 [-0.11, +0.05] |
| IQ4_XS | 121 | 101 / 7 | 1.014 | 108 | 77 / 25 | 0.562 | -0.01 [-0.09, +0.07] |
| Q5_K_M | 124 | 103 / 10 | 1.035 | 107 | 76 / 17 | 0.625 | +0.03 [-0.03, +0.09] |
| Q8_0 | 124 | 104 / 9 | 1.062 | 108 | 77 / 18 | 0.639 | +0.05 [-0.01, +0.10] |

At equal suggestion frequency:

| Quantization | EN shown | EN helpful / poor | EN mean utility | SR Latin shown | SR Latin helpful / poor | SR Latin mean utility | Overall difference [95% interval] |
|---|---:|---:|---:|---:|---:|---:|---:|
| Q6_K (current) | 124 | 103 / 7 | 1.028 | 108 | 74 / 22 | 0.576 | +0.00 [+0.00, +0.00] |
| Q4_K_M | 124 | 104 / 10 | 1.049 | 108 | 71 / 24 | 0.528 | -0.01 [-0.10, +0.07] |
| IQ4_XS | 124 | 103 / 7 | 1.028 | 108 | 77 / 25 | 0.562 | -0.01 [-0.09, +0.07] |
| Q5_K_M | 124 | 103 / 10 | 1.035 | 108 | 77 / 17 | 0.632 | +0.03 [-0.03, +0.10] |
| Q8_0 | 124 | 104 / 9 | 1.062 | 108 | 77 / 18 | 0.639 | +0.05 [-0.01, +0.10] |

**Cancellation and recovery**

| Quantization | Both cancelled, pairs | Return mean Q6 → arm, ms | Replacement-complete mean Q6 → arm, ms | Replacement-complete p95 Q6 → arm, ms | Mean replacement difference [95% interval], ms |
|---|---:|---:|---:|---:|---:|
| Q6_K (current) | 83 | 33.7 → 33.7 | 214.6 → 214.6 | 409.8 → 409.8 | +0.00 [+0.00, +0.00] |
| Q4_K_M | 82 | 34.0 → 37.0 | 216.9 → 222.0 | 409.8 → 423.3 | +5.11 [+0.52, +12.44] |
| IQ4_XS | 82 | 34.1 → 38.5 | 216.5 → 211.7 | 409.8 → 395.3 | -4.86 [-12.84, +0.75] |
| Q5_K_M | 82 | 34.0 → 40.2 | 216.9 → 235.3 | 409.8 → 434.3 | +18.41 [+14.27, +21.69] |
| Q8_0 | 83 | 33.7 → 32.1 | 214.6 → 214.4 | 409.8 → 389.2 | -0.16 [-8.97, +10.75] |

Each model attempted 96 cancellations. Q4 delivered/cancelled 82; the other models delivered/cancelled 83. Both arms must cancel on the same request to enter a pair, so paired baseline values vary. There are only four independent bilingual cancellation scenarios; the 82–83 events are correlated repeats, and these intervals/tails are diagnostic. All 96 replacement/cold checks per model match (480/480).

Claude Opus 5.5 rated 240 primary cases and 24 reversed-order repeats. The repeats contained 39 distinct options: 66.7% exact utility agreement, 89.7% agreement on positive utility versus silence, and 0.359 mean absolute score difference. Numeric-utility/preference inconsistencies: 0 primary and 0 repeat cases. Raw ratings and a sensitivity analysis excluding inconsistent cases are retained.

**Method and limits**

The decoder uses certified prefix search, width four / 32 expansions, two generation and two prefill threads, 256-token prefill chunks, a six-token/four-word budget and the unchanged sampler/seed.

- Apple M4 Max, 48 GiB unified memory, macOS 27.0.1, AC power. One frozen Release replay executable, SHA-256 `23562c21a51b6ef3cf32e3a6bab2b59f1c9ed2c8bf6b2e0f12b77921e3c48cf9`, from the preceding cancellation study. Source fingerprints match branch revision `ea3970204e0831d6a76a533f6daec0b9a7a67c5d`. No native inference was run concurrently with another benchmark, build, model test or download.
- Forty-eight newly authored fictional bilingual scenarios: 48 English sentences and 48 Serbian Latin sentences, with one word-boundary and two midword checkpoints each (288 total). They were checked for exact-sentence overlap against the recorded prefix-confirmation, midword, model-study, calibration and cancellation corpora. This does not establish disjointness from every historical fixture.
- Each model has two serial rounds in reversed model order. Each round contains 288 fresh, 48 long-field, 96 typing/backspace/retype and 144 cancellation/replacement/cold observations. Eight warmups per process are excluded. Long-field cases cover twelve bilingual scenarios; dynamic typing covers eight; cancellation covers four, with short/long contexts and 5/20/60-ms requested timers.
- Production thresholds are fixed at 0.1 / 0.31. Separate confidence traces determine per-language cutoffs without quality labels, retaining every ungated midword completion and keeping the fallback-to-primary ratio at 3.1. Two additional native fresh rounds measure actual outputs and latency at matched frequency. Matching uses this evaluation corpus and is a diagnostic, not a learned deployment calibration. Trace mode is never timed as a production candidate.
- The original 55-process plan contains 10,080 measured observations plus 440 excluded warmups. Q8's fresh mean changed from 86.7 to 57.8 ms between initial passes, so a separately frozen follow-up adds two fully warmed fresh rounds for every model, in reverse order and at unchanged production gates. Those ten additional processes contribute 2,880 measured observations and 80 warmups: 65 processes / 12,960 measured / 520 warmups in total. Original timings remain preserved; warmed follow-up numbers are reported separately.
- Repeated outputs are not independent quality samples. Quality uses the 288 distinct fresh checkpoints; uncertainty resamples the 48 bilingual source scenarios, keeping languages, checkpoints and timing rounds together (5,000 draws). Intervals are exploratory and not adjusted for multiple comparisons or all sources of machine noise.
- Claude Opus receives only fictional prefixes and anonymous candidate continuations. It does not receive model names, benchmark timings, source code, intended reference futures or personal writing. Identical output strings are rated once per case. Silence is utility 0; nonempty text uses the prior -2..2 usefulness rubric. Twenty-four cases repeat with new option IDs and reversed order. These are model opinions, not human acceptance rates.
- Native latency starts inside generation and excludes model loading. The long prewarmed cases exclude separately measured prewarm work from generation latency. Launch-to-first-observation includes model loading and the first warmup; it is a cache-dependent diagnostic, not cold-start proof. Process peak resident memory includes mapped weights; reported process footprint is separate and neither is total system/GPU memory.
- Cancellation is measured from the actual issued timer to return and to the next completed replacement. Comparisons require both paired requests to have cancelled. Completed-before-cancel and unissued timers are counted separately; faster completion is not credited as faster cancellation. Every replacement is checked against its cold reference. These are headless completion timings, not first-visible UI latency or a GPU-idle measurement.

**Model provenance and size**

Q6, Q4_K_M, IQ4_XS and Q5_K_M come from the same [pinned imatrix repository](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF/tree/a9bf638e53783fc93778f357cc5c672eab5393b1). Q8_0 comes from the same publisher's [pinned static repository](https://huggingface.co/mradermacher/gemma-4-E2B-GGUF/tree/3762686d74ff8db6c98f8d3c389f56fbdf994d5a). Each downloaded file's complete SHA-256 matches the pinned publisher LFS metadata. Q6 is the existing installed file, also verified against that metadata.

Architecture metadata, the complete tokenizer metadata and all 601 tensor names/shapes match across the five files. All 284 tensors retaining the same type across every quantization match byte for byte. Publisher cards identify the same Google E2B base model, but do not supply a full unquantized-checkpoint hash; Q8 uses a separate conversion snapshot. No model was requantized from the installed Q6 file.

The “4-bit” label does not describe every tensor. Q4_K_M stores 2.473 GB in Q6_K and only 0.911 GB in Q4_K. IQ4_XS retains 2.257 GB in Q6_K. Both embedding tables alone account for approximately 2.257 GB of Q6 weights in Q6/Q5/Q4/IQ4. That directly explains why the tested four-bit files save only 11–14% of disk space. These findings describe these published artifacts, not every possible custom quantization.

No installed model, app preference, prompt, decoder default or network permission is changed by this study. No local UI tests or CI actions are part of the experiment.
