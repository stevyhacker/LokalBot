# COLLECTION.md — "LokalBot recommended local stack" Hugging Face Collection

A Hugging Face **Collection** that curates the exact third-party model repos LokalBot's default stack downloads. **We never rehost or mirror weights**: every item links to the model owner's repo, so licenses (Apache-2.0 and OpenMDW-1.1) and download bandwidth stay with their owners. The collection is pure curation — a one-click "get everything LokalBot recommends" list with per-model notes.

## Curated items (repo ids verified via the HF API on 2026-09-30; item 5 on 2026-11-10)

Each id is the repo the app downloads, taken from the source file listed.

| # | Role | HF repo id (verified) | What LokalBot loads | Source in the app | Curation note |
| --- | --- | --- | --- | --- | --- |
| 1 | Transcription | `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` | 8-bit MLX weights (2.47 GB) | `LokalBot/Engines/PinnedSpeechModels.swift` | Default transcription. 8-bit MLX conversion of Qwen/Qwen3-ASR-1.7B (2.47 GB). Apache-2.0. |
| 2 | Speaker diarization | `FluidInference/nemotron-3-diarization-coreml` | `Nemotron3Diarizer_offline.mlmodelc` (0.2 GB) | `LokalBot/Services/NemotronDiarizationModels.swift` | Default speaker diarization. Core ML offline model (0.2 GB) of nvidia/Nemotron-3-Diarization, run through FluidAudio. 14.6% DER vs 43.4% for the previous Pyannote setup on AMI. OpenMDW-1.1. |
| 3 | Summaries and chat | `unsloth/Qwen3.5-4B-GGUF` | `Qwen3.5-4B-Q4_K_M.gguf` (2.74 GB) | `LokalBot/Engines/ModelCatalog.swift` | Default for summaries and chat. Q4_K_M (2.74 GB): a 26-minute meeting to notes in 33 s warm, about 85 tok/s decode on M4 Max. Apache-2.0. |
| 4 | Semantic search | `ggml-org/embeddinggemma-2-GGUF` | `embeddinggemma-2-Q8_0.gguf` (0.31 GB) | `LokalBot/Services/EmbeddingIndex.swift` | Default semantic search. Q8_0 (0.31 GB) on a dedicated llama-server with embeddings enabled. Correct passage first for 43/48 test queries vs 40/48 for Harrier 0.6B, at half the size. Apache-2.0. |
| 5 | Autocomplete | `mradermacher/gemma-4-E2B-i1-GGUF` (quant of `google/gemma-4-E2B`) | `gemma-4-E2B.i1-Q6_K.gguf` (3.85 GB) | `LokalBot/Engines/ModelCatalog.swift` | Default autocomplete. Q6_K (3.85 GB) imatrix GGUF of google/gemma-4-E2B. 23.1% next-word accuracy vs 20.7% for LFM2.5 1.2B on 96 phrases (a tie in English), right when shown 50%; 56 ms median per keystroke. Apache-2.0. |

The five files total 9.6 GB, matching the README's "Local AI, your choice" section. Screen text uses Apple Vision, which ships with macOS and has no repo to link. Every figure in the notes comes from the reports indexed in `Benchmarks/README.md`.

Removed on 2026-09-30, because they are no longer defaults: `ibm-granite/granite-speech-4.1-2b-GGUF`, `unsloth/gemma-4-E4B-it-GGUF`, `Qwen/Qwen3-Embedding-0.6B-GGUF`, and `FluidInference/speaker-diarization-coreml`. Granite Speech, Gemma 4 E4B, and Pyannote Community-1 diarization remain optional in the app. Harrier replaced Qwen3 Embedding for search. On 2026-10-07 `mradermacher/harrier-oss-v1-0.6b-GGUF` was removed when EmbeddingGemma 2 replaced Harrier. On 2026-11-10 this list replaced `unsloth/LFM2.5-1.2B-Instruct-GGUF` with Gemma 4 E2B Base, the default autocomplete model since October; LFM2.5 1.2B is the Lightweight preset's. The published collection keeps the September list until the next sync below.

Verification method (reproduce before publishing): query `https://huggingface.co/api/models/<id>` and confirm the file LokalBot loads exists in `siblings`. `scripts/create_collection.py` runs this check before it writes anything.

## Collection description (paste as-is; 143 characters)

> LokalBot 9.6 GB default stack: transcription, diarization, summaries, search, autocomplete. Links only. https://github.com/stevyhacker/lokalbot

## Updating the collection

### Option A — script

```sh
uv run --with huggingface_hub python Distribution/huggingface/scripts/create_collection.py
```

The script creates the collection if needed, adds missing items, removes items not in its list, rewrites every note, sets the order, and sets the description. It needs a token with Collection write permission. The current fine-grained token has repo write only and gets 403 on `/api/collections`.

### Option B — web UI

1. Sign in at huggingface.co and open the collection.
2. **Add to collection** → paste each repo id from the table.
3. Delete any item that is not in the table.
4. For each item, **Edit note** → paste the curation note.
5. Drag items into table order.
6. **Edit collection description** → paste the description above.

The 2026-09-30 update used the signed-in web session. It sent the same `/api/collections/<slug>` requests the page makes, so it produced the same result as the script.

## Non-goals

- No mirrors, forks, or reuploads of any weights — including "convenience" quant packs. Link only.
- No fine-tunes/merges of the curated models under the LokalBot name.
- The collection holds models only; the benchmark Space is specified separately in `SPACE-benchmark.md`.
