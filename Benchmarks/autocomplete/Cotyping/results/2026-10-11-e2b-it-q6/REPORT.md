**Unsloth and Bartowski E2B IT Q6 — completed native and blind Claude comparison**

**Keep the current E2B base Q6 default.** The IT candidates are 11.7–12.9% faster at matched suggestion frequency, but Claude Opus 5.5 rates substantially more poor Serbian Latin suggestions. Current Q6 has **191 helpful / 18 poor** suggestions, versus **170/41 Unsloth** and **169/42 Bartowski**. Their small English-quality advantages remain uncertain. Neither meets the combined quality and speed requirement. The installed app, model and default remain unchanged.

All three models were rerun on the same Mac with the current native decoder and prompt fixed. The test uses the preceding Q6 study's 48 fictional bilingual scenarios, yielding 144 English and 144 Serbian Latin checkpoints; this is a reused corpus, not a new untouched holdout. No previous timings or judge scores are pooled.

**Equal suggestion frequency and latency**

Every arm shows exactly **112/144 English and 109/144 Serbian Latin suggestions**, or 221/288 total, in both matched native rounds. Matching changes zero current-Q6 outputs and preserves all 192 midword suggestions per arm. It uses unlabeled boundary-confidence traces, followed by actual native timing at the fitted thresholds.

| Variant | Matched mean / p95 | Mean difference vs current, 95% interval | Shown-only mean | Median peak process RSS |
|---|---:|---:|---:|---:|
| Current E2B base i1 Q6 | **52.0 / 105.0 ms** | Reference | 61.1 ms | 4.15 GB |
| Unsloth E2B IT Q6_K | **45.9 / 101.6 ms** | −6.08 ms [−8.60, −3.63], 11.7% faster mean | 54.3 ms | 4.81 GB |
| Bartowski E2B IT Q6_K | **45.3 / 99.9 ms** | −6.69 ms [−9.07, −4.36], 12.9% faster mean | 53.5 ms | 4.21 GB |

The matched English means are 44.4 / 36.6 / 36.4 ms for current / Unsloth / Bartowski; Serbian Latin means are 59.6 / 55.2 / 54.2 ms. Each matched timing estimate uses two rounds of 288 requests per model, not 576 independent scenarios. Intervals use 5,000 paired bootstrap draws over 48 bilingual scenarios, without a multiple-comparison correction. Native latency measures completion and excludes model load, debounce, accessibility and overlay rendering. Output text differs substantially, so these numbers do not establish a pure inference-kernel speed advantage.

At the **unchanged production gates**, the IT models offer suggestions far more often: Unsloth 267/288 and Bartowski 265/288 versus current 221/288. Their warmed means are 51.2 and 50.8 ms versus current 52.5 ms; both paired difference intervals include zero. The clearer matched-frequency gain therefore depends on evaluation-fitted gates, not a demonstrated drop-in speed improvement with unchanged production settings. Both IT fallback thresholds reach the existing probability cap: `fallback = min(1, 3.1 × primary)`. These are diagnostic cutoffs fitted on this corpus, not deployable calibration. [All timing and gate tables](TABLES.md) · [Matching clarification](matching-notes.json).

**Blind quality judgment at equal frequency**

Claude Opus 5.5 independently rated only the synthetic typed prefixes and shuffled anonymous suggestions. It received no model labels, timings, intended futures or app source. All 272 non-silent primary cases and 24 reversed-order repeat cases completed; the 16 all-silent checkpoints contribute zero in the 288-checkpoint denominator. The native prompt, rubric, packet order and high reasoning effort remain fixed. Previous studies’ ratings are not pooled.

Utility is an ordinal −2..2 judgment relative to silence at zero. “Helpful” means >0 and “poor” means <0; neutral suggestions are omitted from those two counts. Counts below use **exactly 112 shown English and 109 shown Serbian Latin suggestions per arm**. Utility means retain all 144 checkpoints per language, including silence.

| Variant | English helpful / poor | English utility | Serbian Latin helpful / poor | Serbian Latin utility | Overall utility delta vs current, 95% interval |
|---|---:|---:|---:|---:|---:|
| Current E2B base i1 Q6 | **104 / 4** | 1.125 | **87 / 14** | **0.819** | Reference |
| Unsloth E2B IT Q6_K | 107 / 1 | 1.215 | 63 / 40 | 0.271 | **−0.229 [−0.399, −0.062]** |
| Bartowski E2B IT Q6_K | 106 / 1 | 1.201 | 63 / 41 | 0.278 | **−0.233 [−0.396, −0.073]** |

English utility differences are +0.090 [−0.035, +0.222] for Unsloth and +0.076 [−0.042, +0.188] for Bartowski: both intervals include zero. Serbian Latin differences are −0.549 [−0.833, −0.285] and −0.542 [−0.819, −0.285]. Each IT model has 20 Serbian Latin suggestions flagged malformed, versus six for current Q6, and five language-switch flags versus one. Their extra Serbian errors outweigh the possible English benefit in this equally weighted bilingual sample. This is a result for the fixed raw-prefix prompt; it does not establish that these publishers are generally worse.

The IT publishers are effectively tied here: Bartowski minus Unsloth overall utility is −0.003 [−0.059, +0.049]. Bartowski’s lower memory footprint therefore makes it the more economical candidate for a future IT-specific study, but neither is a replacement recommendation. [All quality, timing and gate tables](TABLES.md) · [Literal examples with ratings](EXAMPLES.md) · [Every paired case](quality-examples.json).

The 24 repeated cases contain 39 distinct nonempty options. Exact utility agreement is **29/39 (74.4%)**; agreement on positive utility versus nonpositive is **36/39 (92.3%)**. All differing ratings move one point. No preferred-option contradictions occur, so the planned consistency sensitivity leaves the result unchanged. Repeats do not replace original ratings. The intervals capture scenario sampling uncertainty, not the full uncertainty of a model judge; these ratings are not observed human acceptance.

The user-authorized direct Anthropic API resolved the access blocker. Every successful response identifies `claude-opus-5-5`, and every saved API request is checked against the original blinded packet and system instruction. The earlier 25 CLI quota failures and one OpenRouter guardrail failure remain archived. One direct-API structured-format preflight produced no ratings; its response is preserved, followed by plain-JSON output with the unchanged rubric. All 25 plain-JSON batches passed complete case/option coverage on their first attempt. No valid scores were discarded or rerated. [Judge status](judge-status.json) · [Direct-API amendment](judge-direct-api-amendment.json).

The authored first-word diagnostic remains 164/288 current, 141 Unsloth and 142 Bartowski. It tests one reference continuation and is not used as a substitute for the blind usefulness ratings above.

**Long fields, cancellation and provenance**

At production gates, long-field mean latency is 156.3 ms current, 162.5 ms Unsloth and 156.2 ms Bartowski. Unsloth also has slower paired cancellation return (33.6 → 40.5 ms) and cancellation through replacement (241.6 → 249.6 ms). Bartowski's return is slower (33.9 → 39.1 ms), while its through-replacement mean is lower (243.7 → 239.7 ms) with an interval including zero. Only four source cancellation scenarios were used; these are exploratory measurements, with different paired baselines because only mutually cancelled requests are included. All 288 replacement/cold output checks pass.

These are standard `Q6_K` releases from [Unsloth](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF) and [Bartowski](https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF). The IT checkpoint change is intentional; this is not a comparison of publisher recipes on identical base weights. Their mixed tensor precision also differs: Unsloth's file is 4.50 GB, Bartowski's 3.90 GB and current 3.85 GB. Dynamic XL/L and QAT variants were not tested. [Pinned artifacts and precision inspection](PROVENANCE.md).

The fixed prompt is LokalBot's raw typed prefix, with no IT chat template added. Temporary evaluation copies disable automatic BOS insertion to match current Q6, changing exactly one metadata byte and no weights. Using the actual app's linked tokenizer, all **402 distinct input prefixes produce identical token IDs** across arms. Publisher stopping metadata is preserved, including Unsloth's different EOS convention. This is a BOS-aligned fixed-prompt substitution test, not an evaluation of the IT models' best chat-prompt performance.

**Next step and validation**

Retain current Q6 for English and Serbian Latin. Do not adopt the fitted IT thresholds: this reused corpus is not an untouched holdout and the quality guard fails. A future English-only investigation could prioritize Bartowski because of its lower memory cost, but the English quality advantage needs confirmation on new scenarios and human ratings. Language-specific routing is only a hypothesis; this experiment did not measure its identification, memory or model-switching costs.

For the current feature, the most useful quality follow-up is a Serbian Latin midword/output-validity experiment that preserves legitimate word forms while catching malformed or cross-language tails, evaluated at equal frequency. For speed, continue measuring decoder/runtime changes that preserve current-Q6 outputs. These are proposed next experiments, not implemented changes.

All **39 native processes / 7,776 measured observations** completed, with 312 excluded warmups, byte-identical prompts, 3,888 deterministic repeated outputs, exact native frequency matching and no replay errors. Eleven focused Python tests pass, and the full saved-data analysis reproduces the native measurements unchanged while adding all 504 primary/repeat option ratings. The app executable and installed Q6 hashes are unchanged. No app build, reinstall, local UI tests, release, workflow changes or manual CI actions were performed. [Validation and reproduction](VALIDATION.md) · [Frozen method](METHOD.md) · [Numerical summary](summary.json) · [Complete evidence](evidence.tar.gz).
