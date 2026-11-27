# COLLECTION.md: "LokalBot recommended local stack" Hugging Face Collection

A Hugging Face **Collection** that lists the exact model repos LokalBot's v0.14.0 stack downloads: our four Apache-2.0 task-specific fine-tunes (`stevyhacker/*-LokalBot-GGUF`) plus the two unmodified third-party repos (`FluidInference/nemotron-3-diarization-coreml` and `ggml-org/embeddinggemma-2-GGUF`). **We never mirror or rehost unmodified third-party weights**: upstream models link directly to their owners' repos, while LokalBot's four Apache-2.0 fine-tunes publish full open-license training provenance, SHA-256 digests, and head-to-head evals against stock baselines on each model card.

## Curated items (verified against `ModelCatalog.swift` and `QwenLlamaASR.swift` on 2026-11-26)

Each repo id matches what LokalBot v0.14.0 downloads, taken from the source file listed.

| # | Role | HF repo id | What LokalBot loads | Source in the app | License & size |
| --- | --- | --- | --- | --- | --- |
| 1 | Transcription (Default) | `stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF` | `Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf` + `mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf` | `LokalBot/Engines/QwenLlamaASR.swift` | Apache-2.0, 2.52 GB |
| 2 | Transcription (Compact) | `stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF` | `Qwen3-ASR-0.6B-LokalBot-v1-Q8_0.gguf` + `mmproj-Qwen3-ASR-0.6B-Q8_0.gguf` | `LokalBot/Engines/QwenLlamaASR.swift` | Apache-2.0, 1.02 GB |
| 3 | Speaker diarization | `FluidInference/nemotron-3-diarization-coreml` | `Nemotron3Diarizer_offline.mlmodelc` | `LokalBot/Services/Transcription/NemotronDiarizationModels.swift` | OpenMDW-1.1, 0.20 GB |
| 4 | Summaries, memory & Ask | `stevyhacker/Qwen3.5-4B-LokalBot-GGUF` | `Qwen3.5-4B-LokalBot-v4-Q4_K_M.gguf` | `LokalBot/Engines/ModelCatalog.swift` | Apache-2.0, 2.74 GB |
| 5 | Semantic search | `ggml-org/embeddinggemma-2-GGUF` | `embeddinggemma-2-Q8_0.gguf` | `LokalBot/Services/Search/EmbeddingIndex.swift` | Apache-2.0, 0.31 GB |
| 6 | Inline autocomplete | `stevyhacker/Gemma-4-E2B-LokalBot-GGUF` | `Gemma-4-E2B-LokalBot-v4-i1-Q5_K_M-pleQ4K.gguf` | `LokalBot/Engines/ModelCatalog.swift` | Apache-2.0, 3.02 GB |

## Per-model curation notes

- **`stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF` (v3, 2.52 GB GGUF Q8_0):** Default Mac transcription fine-tune of `Qwen/Qwen3-ASR-1.7B` on `llama-server`. 9.79% AMI ihm and 24.41% AMI sdm WER (-1.67 pp vs stock), 100.0% clean silence (0 hallucinated words vs 123 stock), -24.31 pp code-switching WER, 31.7x RT on M4 Max. Apache-2.0.
- **`stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF` (v1, 1.02 GB GGUF Q8_0):** Compact Mac transcription fine-tune of `Qwen/Qwen3-ASR-0.6B` with bit-identical stock mmproj. 10.72% AMI ihm WER, -21.69 pp South Slavic auto WER, -28.49 pp code-switch WER, 100.0% clean silence, 52.7x RT. Apache-2.0.
- **`FluidInference/nemotron-3-diarization-coreml` (0.20 GB):** Default Core ML speaker diarization of `nvidia/Nemotron-3-Diarization` via FluidAudio. 14.56% DER vs 43.44% for Pyannote on AMI, 8/8 speaker counts, 500x RT. OpenMDW-1.1.
- **`stevyhacker/Qwen3.5-4B-LokalBot-GGUF` (v4, 2.74 GB Q4_K_M):** Default Think model fine-tuned from `Qwen/Qwen3.5-4B` for source-linked meeting notes, memory, and Ask. 118/120 memory retention (1 unwanted vs 12 stock), 45.0% Blind21 decision overlap (vs 7.5% stock), 60.6% fewer validator rejections, 1.78x faster median latency, 6/6 native tools. Apache-2.0.
- **`ggml-org/embeddinggemma-2-GGUF` (0.31 GB Q8_0):** Default semantic search embedder on `llama-server`. 39 ms p50 hybrid query and 0.280 R@1 across 232 QMSum meetings (43/48 top-1 on multilingual EN/SR probe). Apache-2.0.
- **`stevyhacker/Gemma-4-E2B-LokalBot-GGUF` (v4, 3.02 GB i1-Q5_K_M + PLE Q4_K):** Default autocomplete fine-tune of `google/gemma-4-E2B`. 55/56 memory+visible grounding (26/26 memory recall, 0 stale facts), 57.3% blind FH2 (94.0% precision), 60.8% q6pub midword, 0 unsafe checks, 785 MiB smaller than Q6_K. Apache-2.0.

The five default 16 GB Mac files total ~8.8 GB (8.9 GB with Kokoro TTS), matching the README (see also the [Local Desktop AI Leaderboard](https://www.lokalbot.com/benchmarks) and [Local AI Hardware & RAM Calculator](https://www.lokalbot.com/hardware)). Screen text uses Apple Vision, which ships with macOS.

## Changelog of replaced defaults

- **2026-11-27:** Switched default Gemma 4 E2B (LokalBot v4) autocomplete quant from `i1-Q6_K` (`3.85 GB`) to `i1-Q5_K_M + pleQ4K` (`3.02 GB`, `-785 MiB` disk and RAM+VRAM, faster Vulkan latency, `57.3%` FH2 / `94.0%` precision). `v4-i1-Q6_K` stays selectable in Settings for existing `v0.14.0`/`v0.14.1` installs.
- **2026-11-26 (v0.14.0):** Promoted all four Apache-2.0 `stevyhacker/*-LokalBot-GGUF` fine-tunes (`Qwen3-ASR 1.7B v3`, `Qwen3-ASR 0.6B v1`, `Qwen3.5 4B v4`, `Gemma 4 E2B v4`) replacing `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`, `unsloth/Qwen3.5-4B-GGUF`, and `mradermacher/gemma-4-E2B-i1-GGUF` as defaults. The stock baselines remain selectable in Settings.
- **2026-11-10:** Replaced `unsloth/LFM2.5-1.2B-Instruct-GGUF` with Gemma 4 E2B Base for default autocomplete (LFM2.5 stays in the Lightweight preset).
- **2026-10-07:** Replaced `mradermacher/harrier-oss-v1-0.6b-GGUF` with `ggml-org/embeddinggemma-2-GGUF`.
- **2026-09-30:** Replaced `ibm-granite/granite-speech-4.1-2b-GGUF`, `unsloth/gemma-4-E4B-it-GGUF`, `Qwen/Qwen3-Embedding-0.6B-GGUF`, and `FluidInference/speaker-diarization-coreml`.

Verification method (reproduce before publishing): query `https://huggingface.co/api/models/<id>` and confirm the exact file LokalBot loads exists in `siblings`. `scripts/create_collection.py` runs this check before it writes anything.

## Collection description (paste as-is; 136 characters)

> LokalBot v0.14.0 local stack: 4 Apache-2.0 fine-tunes + Nemotron 3 & EmbeddingGemma 2 (~8.8 GB). https://github.com/stevyhacker/lokalbot

## Updating the collection

### Option A: script

```sh
uv run --with huggingface_hub python Distribution/huggingface/scripts/create_collection.py
```

The script creates the collection if needed, adds missing items, removes items not in its list, rewrites every note, sets the order, and sets the description. It requires a token with Collection write permission.

### Option B: web UI

1. Sign in at huggingface.co and open the collection.
2. Click **Add to collection** and paste each repo id from the table.
3. Remove any older default repo not listed in the table.
4. For each item, click **Edit note** and paste the matching curation note above.
5. Drag items into table order.
6. Click **Edit collection description** and paste the description above.

## Policy & boundaries

- Never mirror, fork, or reupload untouched third-party weights (such as Nemotron 3 or EmbeddingGemma 2). Link directly to upstream model owners.
- Only publish models under `stevyhacker/*-LokalBot-GGUF` when they are genuine open-license (Apache-2.0) fine-tunes trained on open data with verified head-to-head evals and SHA-256 checksums documented on the model card.
- The collection holds models only; the benchmark Space is maintained separately in `SPACE-benchmark.md`.
