# MemT-1.0-Nano: partial recall vs. restraint results

Stopped at the user's request after **30 of 120 cases**, in the unchanged frozen request order. The in-flight `P56-yes` case was interrupted; it and the other uncompleted cases are excluded, not counted as model failures. Both owned inference processes were stopped and a follow-up check found zero active benchmark processes.

| Completed slice | Useful memories recalled | Unwanted proposals | Empty cases correct |
|---|---:|---:|---:|
| All 30 cases | 17/18 (94.4%) | 0 | 12/12 (100%) |
| 25 English cases | 13/14 (92.9%) | 0 | 11/11 (100%) |
| 5 Serbian cases | 4/4 (100%) | 0 | 1/1 (100%) |

All 30 completed responses were valid JSON with normal completion. Every emitted proposal had a valid source citation. All 17 proposals were semantically reviewed with model identity visible. There were no kind or presentation errors under the existing scoring rules. Twenty-nine cases satisfied the complete case contract.

The one miss, `P34-yes`, concerned updating known information. The known list said “I prefer prose over bullet points.” The new evidence said “I now prefer bullet points over prose; my old preference has changed.” MemT returned an empty list instead of saving the new preference. This is consistent with over-aggressive suppression of a changed known preference; the output alone does not establish the model's internal reason.

## Matching English cases only

The other models' saved results were filtered to these exact 25 English case IDs. These denominators differ from the original 96-case English benchmark. No extra baseline inference was run.

| Configuration | Recall | Unwanted proposals | Empty cases correct |
|---|---:|---:|---:|
| Qwen3.5 4B (Q4_K_M) | 7/14 | 1 | 10/11 |
| Qwen3.5 9B (Q4_K_M) | 9/14 | 2 | 9/11 |
| Hy-Memory 30B-A3B (Official Q4_K_M) | 14/14 | 18 | 0/11 |
| LFM2.5 24B-A2B (QAD Q4_0) | 9/14 | 18 | 1/11 |
| MemT-1.0-Nano (experimental NF4 experts / BF16 dense) | 13/14 | 0 | 11/11 |

This small prefix looks promising for the tested MemT configuration, but it is not a full-benchmark ranking. Most contrast pairs are incomplete, so pair-success metrics are intentionally omitted. The stop was user-requested, not a performance-based stopping rule, but the incomplete slice can still be unrepresentative.

## Configuration and limits

The same frozen cases, messages, source handles, JSON schema and scorer were used, with greedy decoding, seed 0, thinking explicitly disabled and a 1024-token output cap. MemT ran on Windows with an RX 6600 XT (8 GB VRAM, 32 GB system RAM). Its official checkpoint was quantized through the experimental NF4 expert-offload adapter; dense and native-memory weights remained BF16. The other four configurations used GGUFs and llama.cpp on Ubuntu. Hardware, quantization, runtime and schema-enforcement implementations differ. This is not a controlled same-runtime or same-precision comparison, nor a speed ranking.

Each case starts with fresh state and all evidence in context. The official forward method bypasses the native-memory branch without prior memory state. **This tests stateless extraction, not MemT's persistent latent-memory feature.** The results do not establish performance with reasoning enabled or other configurations.

All 27 official weight files were hash-verified, and the loader accounted for all 753 tensors. Tiny-model parity checks, tokenizer/schema checks, and a separate full-model JSON smoke test passed. An initial memory-mapped loading crash occurred before inference; switching to the documented safetensors `pread` backend resolved it. The failed preparation attempt is preserved. Numerical parity with identically quantized tiny-model weights does not establish lossless quantization versus BF16.

The synthetic dataset and semantic review are assistant-authored/assisted, with no independent human validation. No statistical-significance claim is made.

## Evidence

- [Raw completed responses](results/memt-nano-nf4-offload.jsonl)
- [Partial scores and matched-case comparison](partial-scores.json)
- [Case-level results](partial-details.json)
- [Per-proposal evidence](audit.jsonl) and [semantic decisions](review.json)
- [Frozen execution identity](results/memt-nano-nf4-offload.meta.json)
- [Stop receipt](stop-receipt.json), [run log](run.log), and [validation](partial-validation.txt)
- [Protocol and deviations](PROTOCOL_EXTENSION.md)

No result was posted or published. No paid GPU was rented. The original full-run comparison, chart and Reddit draft remain unchanged; these partial results have not been substituted into them.
