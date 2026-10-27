# Spark-X2.6-4B: promising LokalBot candidate, not yet a default replacement

Evaluated October 20, 2026. **Spark deserves a pilot for extraction and meeting notes.** In this small controlled screen it preserved two facts that LokalBot's current Qwen3.5-4B default missed, with similar short-extraction latency. It also made an unnecessary tool call that Qwen avoided, and processed the long input more slowly. This is enough evidence to justify further testing, not a default switch.

I ran both checksum-verified Q4_K_M files sequentially on the same Ryzen 7 9700X Ubuntu host, using a Linux CPU build of LokalBot's pinned llama.cpp b11474, eight threads, 32K context, greedy decoding, and thinking disabled. The existing synthetic cases and scoring equivalences were reused unchanged. No private work-memory data was sent to the host. Full methodology and commands: [README.md](README.md).

| Measured result | Spark-X2.6-4B | Qwen3.5-4B |
| --- | ---: | ---: |
| Short extraction cases, factual correctness | **12/12** | 10/12 |
| Correct fields in those cases | **43/43** | 41/43 |
| Serbian Latin and Cyrillic cases | 2/2 | 2/2 |
| Single-turn tool cases | 5/6 | **6/6** |
| Search → read → cited answer | Pass | Pass |
| Long-context corrections and source IDs | 6/6 fields | 6/6 fields |
| Median short extraction response | 2.72 s | 2.86 s |
| Median single-turn tool response | 2.54 s | 4.18 s |
| Multi-step workflow total | 14.99 s | 15.61 s |
| Long-context response, including input processing | 150.08 s | **120.03 s** |
| Long-context input tokens | 19,780 | 19,328 |
| Peak server RSS over the primary suite | 7.28 GiB | 7.18 GiB |
| Weight download | 3.187 GB | 2.741 GB |

The latency medians include failed cases; different output lengths also affect response times. Spark's shorter tool responses do not imply faster token generation: median short-tool decode rates were 15.92 tokens/s for Spark and 17.73 for Qwen. These are Linux CPU observations, not Mac performance claims. RSS includes mapped weights, context, runtime buffers, and caching.

**The factual differences:** Qwen extracted the acceptance timestamp as `yesterday` instead of `03:20`, borrowing a phrase from an unrelated installer statement. In a roster with two people named Alex, it correctly returned owner ID `p1` but incorrectly said that person's privacy task did not belong to the user, despite the roster explicitly identifying `p1` as the user. Spark answered both correctly. Both passed the tested missing-information, negation, conditional-task, transcript-injection, and Serbian scenarios. These are narrow examples, not broad robustness guarantees.

**The tool failure:** asked to send an email and explicitly instructed to explain the limitation if no email tool existed, Spark emitted a native `search_meetings` call for `release approval`. Qwen explained that it could not send email and made no call. No email or other external action was executed. Spark's other tool calls were parsed natively by b11474, including parallel reads; no XML adapter was needed for either model's multi-step pass.

A targeted follow-up enabled thinking with a 1,024-token reasoning budget and 2,048-token total output limit, retaining temperature 0. Spark then answered the unavailable-tool case correctly in **18.06 s**. Qwen also passed in **14.78 s**. This post-result diagnostic does not change the primary 5/6 and 6/6 scores, and it is not a full high-reasoning agent evaluation. It shows a useful quality/latency tradeoff worth testing further.

**Scoring:** raw exact-string extraction scores were Spark 7/12 and Qwen 8/12. The established scorer accepts equivalent date forms such as `Friday` / `by Friday` and Serbian inflections; with those pre-existing allowances, factual scores are 12/12 and 10/12. No new allowances were invented for these models. All 13 structured-output cases per model produced valid JSON, but they were grammar-constrained. See [reviewed-scores.json](reviewed-scores.json), [Spark results](results/spark/summary.json), [Qwen results](results/qwen/summary.json), and the saved individual responses.

The publisher's offering is attractive: 4.112B parameters, Apache-2.0 licensing, official GGUF files, and none/low/high reasoning control. It retains the Spark-X2.5 architecture: 36 layers, with 27 sliding-attention layers using a 512-token window and nine full-attention layers. Native support requires llama.cpp b10828 or later; LokalBot's current b11474 pin already clears that requirement. The actual remote load and generation tests confirm CPU compatibility. [Pinned model card](https://huggingface.co/XHToken/Spark-X2.6-4B/blob/2f1d8110eb60b18920d424d7bf47f4001a956f1e/README.md), [configuration](https://huggingface.co/XHToken/Spark-X2.6-4B/blob/2f1d8110eb60b18920d424d7bf47f4001a956f1e/config.json), [GGUF files](https://huggingface.co/XHToken/Spark-X2.6-4B-GGUF/tree/16c77db5a782d75d6953770339f7ae06be7dd3f7).

| Publisher-reported benchmark | Spark-X2.6-4B | Qwen3.5-4B | Qwen3.5-9B |
| --- | ---: | ---: | ---: |
| BFCL v4 | 71.8 | 50.3 | 66.1 |
| SWE Verified | 62.8 | 38.8 | 53.1 |
| IFEval | 93.6 | 89.8 | 91.5 |
| LongBench v2 | 53.3 | 50.0 | 55.2 |
| GPQA Diamond | 77.1 | 76.2 | 81.7 |

These are publisher claims, not reproduced results. The chart says all evaluations use thinking, with Spark at **high** effort; several comparator numbers come from external model cards or papers, and two additional agent benchmarks are in-house and not yet released. The card does not provide enough per-task harness and budget detail to establish a controlled reproduction. Do not transfer those headline advantages directly to LokalBot's non-thinking summaries. [Pinned benchmark chart and footnotes](https://huggingface.co/XHToken/Spark-X2.6-4B/blob/2f1d8110eb60b18920d424d7bf47f4001a956f1e/images/all_benchmark.svg).

The advertised 1,048,576-token context is not a practical default for a 16 GB Mac. From the published architecture, a window-aware FP16 KV cache alone is approximately **1.18 GiB at 32K** and **36.05 GiB at 1M**, before weights and other buffers. This is an architectural estimate, not measured allocation or a claim about quantized KV caches. LokalBot currently uses 32,768 context tokens. The tested long input used approximately 20K, so neither full 32K nor 1M quality was established.

Next adoption evidence should cover complete meeting-note generation and LokalBot's ownership/citation post-processing, repeated English/Serbian tasks, bounded reasoning and unsupported-tool behavior, cancellation/recovery, and Apple Silicon latency and memory alongside the app's other resident models. Keep Qwen as the default until those checks demonstrate a repeatable benefit. Spark is not a replacement for ASR or the dedicated embedding model, and this evaluation provides no reason to replace the current autocomplete model.

**Completion:** model inference and the comparison are complete; raw outputs, checksums, source snapshots, scripts, and hardware details are saved here. No app build, installation, release, catalog change, or settings change was performed. Remaining uncertainty concerns product adoption, not an unfinished benchmark run.
