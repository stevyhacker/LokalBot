# EmbeddingGemma 2 versus Harrier — 6 October 2026

**Decision: retain Harrier as the text-search default. Advance EmbeddingGemma 2 to an optional visual-retrieval prototype.** The candidate improves this synthetic text sample modestly and makes a larger difference when screenshots carry information that OCR cannot represent. It still struggles with diagram connections and task-board state, so it is not ready to promise precise visual recall.

All inference ran locally, serially, on an **Apple M4 Max / 48 GiB**. The benchmark used disposable inputs and indexes; it did not write app settings, live databases, downloaded app models, or the installed bundle. There was no private-library export, live screen capture, remote inference, or UI test.

## Text retrieval

The fixed corpus contains 60 synthetic passages and 48 queries: 24 English queries and 24 Serbian/Montenegrin equivalents, including Cyrillic. Passages, queries and relevance labels reuse the September model-comparison fixture unchanged. Its private transcript distractors are excluded; both models were rerun against the same 60-document corpus, so these results should not be compared directly with the earlier larger-corpus scores.

| Metric | Harrier 0.6B Q8 | EmbeddingGemma 2 text, BF16, 768d |
|---|---:|---:|
| Correct passage first | 40/48 — 83.3% | **43/48 — 89.6%** |
| Correct passage in top five | 47/48 — 97.9% | **48/48 — 100%** |
| English top one | 22/24 | **23/24** |
| Serbian/Montenegrin top one | 18/24 | **20/24** |
| Mean reciprocal rank | 0.9033 | **0.9444** |
| Repeated query embedding p50 | **12.8 ms** | 32.1 ms |
| Repeated query embedding p95 | **13.9 ms** | 35.2 ms |

The top-one gain is **6.25 percentage points**. A paired bootstrap resampling the 24 passage groups, keeping their English/BCS queries together, yields a 95% interval of **−4.17 to +16.67 points**. This sample does not establish a reliable general text-retrieval win. Gemma fixes five Harrier top-one misses but introduces two: the BCS offline-planning query drops from first to second, and the BCS streaming-ASR query drops from first to third.

Latency uses 36 single-input requests: the same first 12 queries repeated three times after warm-up. These are embedding timings, excluding model startup and result ranking. Harrier uses the installed llama.cpp Metal runtime; Gemma uses PyTorch MPS. Precision and runtime differ, so this is a comparison of the measured execution paths, not an isolated architecture-speed comparison.

## Screen retrieval

The fixed screen corpus contains **25 synthetic images / 50 bilingual queries**: six chart patterns, four architecture diagrams, four task boards, six readable notes, and five existing dense UI fixtures. Labels and images were frozen before inference. Charts share identical text and differ in their plotted shape; diagrams share component names and differ in their arrows. Category-specific results prevent these deliberately OCR-ambiguous examples from being presented as a general screenshot benchmark.

Apple Vision ran with the app's recognition settings: accurate recognition, language correction off, automatic language detection on. Each text path used at most the first 1,500 OCR characters, matching the current screen-index input limit. All image paths used the official default 280 vision tokens. The combined path embeds OCR and pixels together into one vector.

| Representation, 768d for Gemma | Top one | Top five | MRR |
|---|---:|---:|---:|
| Apple Vision OCR + current Harrier | 24/50 — 48% | 47/50 — 94% | 0.6553 |
| Same OCR + Gemma text encoder | 27/50 — 54% | 48/50 — 96% | 0.6980 |
| **Gemma image encoder** | **35/50 — 70%** | 49/50 — 98% | **0.8133** |
| Gemma OCR + image, one combined vector | 34/50 — 68% | **50/50 — 100%** | 0.8000 |

| Category | Queries | OCR + Harrier top one | Gemma image top one | Gemma combined top one |
|---|---:|---:|---:|---:|
| Chart trends | 12 | 2 | **7** | 6 |
| Diagram connections | 8 | 2 | **4** | 3 |
| Task-board layout/state | 8 | 2 | 3 | **4** |
| Readable notes | 12 | 10 | 11 | **12** |
| Dense UI | 10 | 8 | **10** | 9 |

Image embeddings improve top-one accuracy by **22 points** over OCR + Harrier on this constructed corpus. The paired screenshot-level interval is +6 to +40 points, conditional on these fixtures. Several images share rendering templates, and the corpus is not a random sample of user screens; that interval does not establish a deployment-wide improvement. Top-five scores are also forgiving here because a small diagram or board family often fits entirely in five results.

Specific image-path failures include the English disconnected-cache query ranking third, the API-star diagram ranking third, and the all-complete task board ranking fourth. The model retrieves the right kind of screen more reliably than it resolves every structural constraint. Visual embeddings should retrieve cited candidate captures for inspection; an exact answer still needs source evidence or a separate reasoning step.

## Runtime cost and dimensions

| Measured path | Loaded parameters | Peak process RSS | MPS driver allocation at end |
|---|---:|---:|---:|
| Harrier Q8 / llama.cpp Metal | approximately 0.6B | 1.14 GiB | not measured |
| Gemma text / BF16 MPS | 271,002,624 | 1.08 GiB | 1.11 GiB |
| Gemma text + vision / BF16 MPS | 438,760,448 | 1.08 GiB | 2.46 GiB |

RSS and MPS allocation use different accounting and overlap on unified memory; do not add them or infer that the vision path consumes only 1.08 GiB. RSS was sampled every 20 ms, while the MPS figures are end-of-run allocations, not peak measurements.

Image embedding costs **255.9 ms p50 / 298.5 ms p95** per screenshot, including image loading and preprocessing. Text-query embedding with the vision model resident costs **33.9 / 39.0 ms**. Combined OCR + image embedding costs **267.3 / 320.0 ms**, excluding the preceding OCR step. Apple Vision OCR had a 48.6 ms median on these images. Background visual indexing appears practical on this M4 Max; battery impact, sustained thermal behavior, and lower-memory Macs were not tested. The preliminary pass measured lower Gemma timings, approximately 26 ms per repeated text query and 223 ms per image; use the final-pass numbers above and expect ordinary machine-load variation.

The official downloaded checkpoint includes all encoders in **1,488,915,288 bytes** of BF16 weights, plus tokenizer/configuration files. Selective loading reduces active parameters but does not prune that download. Harrier's installed Q8 file is **639,448,320 bytes**. An optimized, selectively packaged native artifact needs its own qualification.

| Gemma vector dimension | Text top one / 48 | Image top one / 50 | Raw Float32 bytes/vector |
|---|---:|---:|---:|
| 768 | **43** | **35** | 3,072 |
| 512 | 42 | **35** | 2,048 |
| 256 | 40 | 30 | 1,024 |
| 128 | 36 | 30 | 512 |

Truncation re-normalizes both queries and documents. The current Harrier vector contains 1,024 Float32 values, or 4,096 bytes. Gemma 512d preserves aggregate image top-one accuracy on this sample with half that vector payload, although individual ranks change. Gemma 256d loses five image top-one matches and three text matches versus 768d. Database/text/media overhead is excluded from these byte counts.

## Adoption recommendation and limits

1. Keep Harrier for shipped text search while validating Gemma on a larger, annotated real-library corpus. The small text gain and slower measured query path do not justify an automatic replacement.
2. Prototype optional visual retrieval with the 440M configuration, testing 768d and 512d. Preserve visual opt-in, exclusions, encrypted source storage, and deletion/retention of derived vectors.
3. Qualify the actual native runtime and packaged artifact before integration. This run proves the official checkpoint works on MPS; it does not prove compatibility with LokalBot's bundled llama.cpp runtime, Swift packaging, or minimum macOS version.

Ranking is normalized cosine over fixed vectors. These are component benchmarks; the app's FTS/semantic reciprocal-rank fusion, similarity cutoffs, capture pipeline, model residency, and end-to-end Ask answers were not exercised. No threshold tuning used these labels. A migration needs a new index contract, Gemma's own prefixes and mean pooling, and independently calibrated thresholds. Audio, video, raw-code retrieval, real screenshot quality, and energy use remain unmeasured.

## Provenance and validation

- Source checkout: `613101112cebb242fe8cb21b4616da1d8366febe`.
- Official model: [google/embeddinggemma-2](https://huggingface.co/google/embeddinggemma-2/tree/914f7f89142e33e77833254d9c9b90c3cef7303b), pinned revision `914f7f89142e33e77833254d9c9b90c3cef7303b`; weight SHA-256 `197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79`.
- Harrier: app-pinned Q8 checkpoint, SHA-256 `ba2c9408f82cfdb73aaf70aaea9f125f3fb24c5e76ce0efb469e1530e5ec53e4`.
- Installed llama.cpp: `v0.6.0`; executable SHA-256 `5df00698f0aa581e8d5f5151a36767a90c1638a7e7543412a0431f13b35d7625`.
- Gemma runtime: SentenceTransformers 6.1.0, Transformers 5.19.0, PyTorch 2.14.1, BF16 MPS with eager attention. The published tokenizer has an unbounded length sentinel; the harness explicitly applies the documented 8,192-token input limit.
- Harrier uses production query/document prefixes, last-token pooling, and a 2,048-token server context. Gemma uses the checkpoint's `SearchQuery` and `Document` prompts, official mean pooling and projection, and L2 normalization.
- Models were downloaded and checksum-verified before inference. Inference loaded only local files, disabled Hub networking/telemetry, and used no remote model code.
- All 98 query labels were checked for valid document IDs; all inputs matched their pre-inference freeze hashes. All vectors were finite and nonzero. Repeated query embeddings agreed with their original vectors at cosine greater than 0.99999.
- Final run records share the final harness SHA. The preliminary and final passes produce identical quality scores. Python compilation, Swift compilation, focused strict SwiftLint, and artifact/link checks passed. No app build, installation, release, or UI suite was required for this isolated benchmark.

[Raw scores](results/scores.json), [model manifest](model-manifest.json), [fixture hashes](fixture-freeze.json), [fixture preview](fixture-preview.png), and [reproduction commands](README.md) accompany the report.
