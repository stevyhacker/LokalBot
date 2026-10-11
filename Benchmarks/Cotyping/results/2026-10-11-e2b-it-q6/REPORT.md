**Unsloth and Bartowski E2B IT Q6 — native results, Claude judgment pending**

**Keep the current E2B base Q6 default.** Both instruction-tuned candidates generate faster at matched suggestion frequency, but the requested Claude quality comparison is blocked by service access. No quality winner or combined upgrade is established. The installed app, model and default remain unchanged.

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

**Quality is still unresolved**

Claude Opus 5.5 received no successful request. All 25 CLI batches returned `429 usage_limit_reached`, with a reported reset at **22:30 Europe/Podgorica on 11 October**. A single attempt through the configured OpenRouter account, restricted to Anthropic's Opus 5.5 endpoint, returned `404 model-ignored-by-guardrail`. No guardrail or account setting was changed. The failed requests and responses are retained; no ratings were fabricated, substituted from another model or borrowed from earlier studies. [Judge status](judge-status.json).

The full blinded evaluation is prepared: 272 checkpoints where at least one production or matched policy offers text, 16 all-silent cases retained as zero, and 24 reversed-order repeat cases. Packets contain only fictional prefixes and anonymous unique suggestions. Once an authorized Claude connection is available, the same packets can be judged without repeating native benchmarks.

An available **reference-word diagnostic** is lower for the IT models: 141/288 Unsloth and 142/288 Bartowski versus 164/288 current. This checks the first completed word against one authored continuation; it does not measure plausible alternative quality and cannot replace Claude or human ratings. The [literal English and Serbian Latin examples](EXAMPLES.md) include differences in phrase length, unsupported specifics and language/word-form behavior. They are not presented as judged wins or losses.

**Long fields, cancellation and provenance**

At production gates, long-field mean latency is 156.3 ms current, 162.5 ms Unsloth and 156.2 ms Bartowski. Unsloth also has slower paired cancellation return (33.6 → 40.5 ms) and cancellation through replacement (241.6 → 249.6 ms). Bartowski's return is slower (33.9 → 39.1 ms), while its through-replacement mean is lower (243.7 → 239.7 ms) with an interval including zero. Only four source cancellation scenarios were used; these are exploratory measurements, with different paired baselines because only mutually cancelled requests are included. All 288 replacement/cold output checks pass.

These are standard `Q6_K` releases from [Unsloth](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF) and [Bartowski](https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF). The IT checkpoint change is intentional; this is not a comparison of publisher recipes on identical base weights. Their mixed tensor precision also differs: Unsloth's file is 4.50 GB, Bartowski's 3.90 GB and current 3.85 GB. Dynamic XL/L and QAT variants were not tested. [Pinned artifacts and precision inspection](PROVENANCE.md).

The fixed prompt is LokalBot's raw typed prefix, with no IT chat template added. Temporary evaluation copies disable automatic BOS insertion to match current Q6, changing exactly one metadata byte and no weights. Using the actual app's linked tokenizer, all **402 distinct input prefixes produce identical token IDs** across arms. Publisher stopping metadata is preserved, including Unsloth's different EOS convention. This is a BOS-aligned fixed-prompt substitution test, not an evaluation of the IT models' best chat-prompt performance.

**Next step and validation**

Finish the prepared blind Claude evaluation for both languages before considering an upgrade. Bartowski is the more economical IT candidate to investigate first because its measured latency is comparable to Unsloth's and it uses substantially less memory; that is a performance observation, not a quality recommendation. If its quality survives judging, fit gates on a separate calibration set and confirm on new bilingual scenarios and human ratings before proposing adoption. Current Q6 stays enabled throughout.

All **39 native processes / 7,776 measured observations** completed, with 312 excluded warmups, byte-identical prompts, 3,888 deterministic repeated outputs, exact native frequency matching and no replay errors. Eleven focused Python tests pass. The app executable and installed Q6 hashes are unchanged. No app build, reinstall, local UI tests, release, workflow changes or manual CI actions were performed. [Validation and reproduction](VALIDATION.md) · [Frozen method](METHOD.md) · [Numerical summary](summary.json) · [Complete evidence](evidence.tar.gz).
