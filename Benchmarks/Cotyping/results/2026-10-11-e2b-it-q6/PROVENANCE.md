**Model artifacts and fixed-input controls — 11 October 2026**

This follow-up deliberately compares the current E2B **base** checkpoint with two E2B **instruction-tuned** artifacts. It is not a pure publisher comparison with identical underlying weights. The two IT publishers also use different conversion/quantization recipes. Standard `Q6_K` files were selected before inference; Unsloth's `UD-Q6_K_XL`, Bartowski's `Q6_K_L`, QAT and other releases are outside this test.

| Arm | Published file | Pinned repository revision | Download size |
|---|---|---|---:|
| Current | `gemma-4-E2B.i1-Q6_K.gguf` | `mradermacher/gemma-4-E2B-i1-GGUF` at `a9bf638e53783fc93778f357cc5c672eab5393b1` | 3,845,328,608 bytes |
| Unsloth IT | `gemma-4-E2B-it-Q6_K.gguf` | `unsloth/gemma-4-E2B-it-GGUF` at `0314792d7f1f7e229411f620751375812bb9faf2` | 4,501,721,184 bytes |
| Bartowski IT | `google_gemma-4-E2B-it-Q6_K.gguf` | `bartowski/google_gemma-4-E2B-it-GGUF` at `81012ba3538e061d5ee003f11f25335b17f82e2d` | 3,898,486,240 bytes |

The IT repository metadata and cards were fetched before download on 11 October. Full downloaded-file SHA-256 hashes match the pinned Hugging Face metadata. The installed current Q6 is unchanged and its full hash is reverified. See [publisher hashes](models-publisher.json), [evaluated hashes](models.json) and the original public cards/API responses under `sources/` in the [archive](evidence.tar.gz). Public sources: [current base](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF), [Unsloth IT](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF), [Bartowski IT](https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF).

**Q6 is not a complete description of stored precision**

All three files contain the same 601 tensor names and shapes and use the Gemma 4 architecture. Inspection of the actual artifacts gives:

| Arm | Q6_K tensors | Q8_0 tensors | F32 tensors | BF16 tensors |
|---|---:|---:|---:|---:|
| Current | 317 | 0 | 283 | 1 |
| Unsloth IT | 246 | 1 | 353 | 1 |
| Bartowski IT | 213 | 104 | 283 | 1 |

Tensor counts do not weight tensors by size. The full per-tensor names, shapes, types and storage sizes are retained in `gguf-inspection.json` in the archive. Unsloth is 656 MB larger than current; Bartowski is 53 MB larger. This test does not isolate the effect of any one precision choice.

**Identical prompts and identical input tokens**

The current artifact disables automatic beginning-of-sequence (BOS) insertion; both IT artifacts enable it. LokalBot requests special-token insertion from llama.cpp. Keeping only prompt strings identical would therefore allow different input sequences. Before any candidate generation, temporary APFS clones of the IT files changed only that boolean from true to false. Original downloads remain intact. A full byte comparison verifies that every other byte, including all weights, is identical. [BOS alignment receipts](bos-alignment.json).

The actual Release app's linked `libllama` was used for a vocabulary-only tokenization probe with the runtime's `add_special=true` and `parse_special=true` flags. **All 402 distinct replay prefixes have exactly the same token IDs across all three evaluated artifacts**, including warmups, long fields, typing and cancellation fixtures. The C probe, source/header/library fingerprints, sequence arrays and compile command are retained in the archive. [Tokenization evidence](input-tokenization-summary.json).

The initial stricter metadata assertion found an Unsloth stopping-related difference before inference: token 1 (`<eos>`) is classified as normal rather than control, and the EOS ID is 106 rather than 1. These publisher stopping conventions were preserved. No fixture contains the literal `<eos>` string. The two IT files also contain chat templates, but the unchanged LokalBot raw-prefix renderer does not apply them. The failed assertion, narrow pre-inference amendment and exact tokenization proof are retained. [Control receipt](pre-inference-controls.json).

This is consequently a **BOS-aligned, fixed-raw-prompt IT substitution test**. It neither measures the publishers' as-shipped BOS behavior nor establishes their best quality with chat/instruction prompts. Prompt changes, stopping-policy normalization, different precision variants and installation would require separate experiments.
