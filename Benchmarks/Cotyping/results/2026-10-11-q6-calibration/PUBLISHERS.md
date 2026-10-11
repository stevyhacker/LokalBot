# Publisher survey — 11 October 2026

The current default is Google's pre-trained `google/gemma-4-E2B` base model.
Instruction-tuned (`-it`), QAT and fine-tuned files change the checkpoint and cannot
answer a fixed-model quantization question. Public Hugging Face metadata and
model cards were saved with their repository revisions in `sources/` and
`publisher-survey.json`.

| Publisher | Relevant release found | Treatment |
|---|---|---|
| [mradermacher](https://huggingface.co/mradermacher/gemma-4-E2B-i1-GGUF) | E2B base importance-weighted and [static Q6](https://huggingface.co/mradermacher/gemma-4-E2B-GGUF) | Both benchmarked |
| [Unsloth](https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF) | IT Q6_K / UD-Q6_K_XL; separate IT QAT releases | Surveyed; excluded because source is IT/QAT |
| [Bartowski](https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF) | IT Q6_K and Q6_K_L | Surveyed; excluded because source is IT |
| [LM Studio](https://huggingface.co/lmstudio-community/gemma-4-E2B-it-GGUF) | IT Q6_K and IT QAT releases | Surveyed; excluded because source is IT/QAT |
| [ggml-org](https://huggingface.co/ggml-org/gemma-4-E2B-GGUF) | Base BF16 and Q8_0; no published Q6 in inspected revision | Pinned BF16 source for three controlled local Q6 arms |
| [Animateus](https://huggingface.co/Animateus/gemma-4-E2B-GGUF) | Base Q6_K, calibrated on English/Polish/German per its card | Benchmarked |
| [SporkySporkness](https://huggingface.co/SporkySporkness/gemma-4-E2B-GGUF) | Base Q6_K, card says reconverted from BF16 | Benchmarked |

Unsloth's Q6_K file is about 4.50 GB and its UD-Q6_K_XL is about 4.71 GB;
Bartowski's Q6_K is about 3.90 GB and Q6_K_L about 4.56 GB. Those sizes illustrate
that a Q6 label does not guarantee the same tensor precision mix. They are not
quality or speed results and these IT artifacts were not run as base substitutes.

The [mradermacher FAQ](https://huggingface.co/mradermacher/model_requests#what-is-the-imatrix-training-data-you-use-can-i-have-a-copy) describes primarily English importance-matrix data and calls
its Q6 importance-weighted file practically equivalent to static Q6. This study
tests that claim for LokalBot's workload instead of inferring quality from
downloads or likes. Animateus's claimed multilingual metrics remain publisher
claims; the report uses independently collected LokalBot results.

This is a dated survey of these publishers' matching public listings, not proof
that no other same-base conversion exists anywhere on the Hub.
