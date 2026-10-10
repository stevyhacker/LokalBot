Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Model selection research — 10 October 2026

Five promising deployable candidates, rather than a claim that these are universally the best five language models. Selection is for short, local, English/Serbian prose continuation on the installed M4 Max, using the existing llama.cpp runtime and completion prompt. No instruction prompt, speculative decoder, quantization-specific tuning or model-specific threshold is introduced in the primary comparison.

| Candidate | Reason to test | Primary source |
|---|---|---|
| Gemma 4 E4B, pre-trained | Direct larger sibling of the current E2B; tests whether additional capacity buys useful continuation quality. E4B has 4.5B effective parameters, about 8B including per-layer embeddings. | [Gemma 4 report, July 2026](https://arxiv.org/abs/2607.02770), [Google model card](https://huggingface.co/google/gemma-4-E4B) |
| Qwen3.5 2B Base | Different multilingual tokenizer and compact hybrid architecture; explicitly pre-trained checkpoint suited to continuation. The small model uses interleaved Gated DeltaNet and attention blocks. | [Official base model card](https://huggingface.co/Qwen/Qwen3.5-2B-Base), [Qwen3.5 announcement](https://qwen.ai/blog?id=qwen3.5) |
| LFM2.5 1.2B Base | Smallest candidate; tests memory and latency savings from the edge-focused family without imposing instruction formatting. Serbian is outside its listed supported languages, making the language breakdown essential. | [Official base model card](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Base), [LFM2 technical report](https://arxiv.org/abs/2511.23404) |
| LFM2.5 2.6B Base | August 2026 release; expands the vocabulary to 128K and pre-training to about 34T tokens. Tests whether a newer, larger LFM can improve multilingual continuation while staying compact. Agentic post-training claims do not apply to this base checkpoint. | [Official August announcement](https://www.liquid.ai/blog/lfm2-5-2-6b), [Base model card](https://huggingface.co/LiquidAI/LFM2.5-2.6B-Base) |
| Gemma 4 E4B Luchador | An actual writing-oriented fine-tune/merge, using LoRA and weighted merges to add prose-style training. Included to test whether that specialization transfers to short everyday writing. Its roleplay/conversation training is a potential mismatch, and its published scores are author-reported rather than independent autocomplete evidence. | [Author model card and recipe](https://huggingface.co/rpDungeon/Gemma-4-E4B-Luchador) |

Every candidate uses Q6_K. Three use importance-matrix quants, LFM 1.2B uses the official LiquidAI conversion, and Luchador uses a Bartowski conversion. These are comparisons of specific deployable artifacts, not a controlled comparison of full-precision architectures. Exact repositories, revisions, sizes and SHA-256 hashes are in `models.json`; download receipts verify the published LFS hashes. Only tensor files are loaded; no repository Python code is executed.

## Useful research ideas

**Calibrate triggering per model and language.** [Gmail Smart Compose](https://arxiv.org/html/1906.00080v1#S3.SS3) uses confidence thresholds to trade suggestion coverage for quality. Its evaluations compare models at equal coverage and its multilingual deployment uses language-specific thresholds. This motivates a follow-up calibration study on separate development data. The present fixed-threshold study answers whether a model is a good drop-in replacement for the installed hybrid; it does not establish each model's best possible operating point.

**Optimize the actual device and workload.** The [LFM2 report](https://arxiv.org/html/2511.23404v1#S2) searches architectures under hardware constraints, using short gated convolutions plus a minority of attention blocks. Its published CPU speedups do not establish LokalBot speedups on Metal. The current LokalBot runtime permits partial prompt reuse for attention models and deliberately reprocesses recurrent/hybrid model prompts, because their rolling state cannot be rewound using the same operation. That implementation can dominate short repeated completions.

**Fine-tune for continuation, not chat.** The Japanese medical [LFM autocomplete adaptation](https://huggingface.co/genshiai-daichi/med-lfm2.5-1.2b-autocomplete) describes continued pre-training followed by prefix-to-continuation training, with loss on continuation tokens. Its examples are qualitative, not a controlled benchmark. The recipe is relevant to a future English/Serbian writing adapter; the weights themselves are gated, medical and Japanese, so they were excluded from this general-writing study. No access application was submitted.

**Train against plausible mistakes.** [Synthetic Hallucinations, Real Gains, June 2026](https://arxiv.org/abs/2606.03130) uses frontier-generated hard negatives to improve code FIM completions. The transferable hypothesis is to construct short prose pairs with natural continuations versus script switches, repetitions and unsupported specifics, then test a continuation adapter on an independent writing corpus. Its reported code gains are not evidence of gains in Serbian or prose. No such adapter was trained in this study.

**Multiple-candidate decoding is a separate experiment.** [Superposed Decoding, NeurIPS 2024](https://arxiv.org/abs/2405.18400) combines candidate embeddings and an n-gram filter to generate several drafts more cheaply than repeated independent sampling. It is relevant to the earlier candidate-decoder investigation, but is not a drop-in model replacement and would alter the decoder. This study does not infer a LokalBot latency benefit from that paper's reported speedup.

## Other candidates considered

- [Auto-Completer 0.2](https://huggingface.co/Parveshiiii/Auto-Completer-0.2): directly targets completion and derives from SmolLM2-360M, but deliberately wraps sentences in quotes, is English-only, and supports its accuracy claims with internal tests. Its documented output format conflicts with inline insertion; it is not one of the five primary candidates.
- [Instella-MoE, September 2026](https://arxiv.org/abs/2609.00791): a newer, fully open research release, with 16B total and 2.8B active parameters. The larger resident footprint and different architecture make it a less direct background-autocomplete replacement than the chosen candidates. It was researched, not benchmarked.
- Large reasoning models, code-only FIM fine-tunes and general refusal-removal merges were not prioritized: their advertised specialization does not establish better short natural-language continuation.

Model cards list Apache 2.0 for the Google and Qwen base checkpoints, Liquid's own license for LFM, and `gemma` for Luchador. These labels are recorded as provenance; this experiment does not change model distribution or the app's default model. Product adoption should use the exact upstream and derivative terms, not assume that every fine-tune inherits the same metadata.

## Claude-selected follow-up queue

At the user's request, Claude Opus 5.5 selected four additional models and three papers, plus a calibration companion. Independently checked sources, exact proposed Q6_K file identities, priorities and limitations are in [CLAUDE-TEST-LIST.md](CLAUDE-TEST-LIST.md). These additions are queued and untested; they do not change the five-candidate results above.
