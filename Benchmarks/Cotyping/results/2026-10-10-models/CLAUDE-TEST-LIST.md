Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../2026-10-10-experiments-manifest.json).

# Claude-selected additions to the autocomplete test list

Added 2026-10-10. **Queued; none of these four additions has been benchmarked in this study.** Claude Opus 5.5 selected the models and papers below after receiving aggregate results and product constraints. Its tools were disabled; the implementing assistant independently checked the model cards, configurations, public GGUF metadata and paper identities. These are targeted controls and language-specialist candidates, not a claim that they are the newest releases.

The original results and frozen protocol remain in [REPORT.md](REPORT.md) and [plan.json](plan.json). The new machine-readable queue is [claude-test-list.json](claude-test-list.json). Claude's exact [request (archive)](../2026-10-10-experiments.tar.gz), [response](claude-model-selection/SELECTION.md), and [model receipt (archive)](../2026-10-10-experiments.tar.gz) are preserved.

## Next model batch, in Claude's priority order

| Priority | Model | Why add it | Verified public Q6_K file size | What the trial must establish |
|---|---|---|---:|---|
| 1 | [Google Gemma 4 E4B IT](https://huggingface.co/google/gemma-4-E4B-it) | Compare the official instruction-tuned checkpoint with E4B base and Luchador. Luchador's author identifies this IT checkpoint as the foundation onto which writing adaptations were merged. | 6.33 GB | Whether ordinary instruction tuning accounts for the observed gains, and whether the official model retains better Cyrillic behavior under the unchanged raw-completion prompt. |
| 2 | [Qwen3 4B Base](https://huggingface.co/Qwen/Qwen3-4B-Base) | An attention-only multilingual alternative whose architecture can use the existing attention KV reuse path, unlike the tested Qwen3.5 hybrid. | 3.31 GB | Quality and actual shared-prefix latency on this runtime. Different generations and model sizes mean this is not a controlled isolation of architecture alone. |
| 3 | [Salamandra 2B Base](https://huggingface.co/BSC-LT/salamandra-2b) | A smaller European-language model. The official metadata explicitly lists `sr` and `sh`; its data table includes Serbian sources. Configuration is Llama-style attention with a 256,000-entry vocabulary. | 1.92 GB | Whether European-language training helps Serbian Latin and Cyrillic without losing too much English quality. A language's inclusion in training is not evidence of good autocomplete. |
| 4 | [YugoGPT 7B](https://huggingface.co/gordicaleksa/YugoGPT) | A Mistral-based model continued on Bosnian/Croatian/Serbian text. This is the direct language-specialist control. | 5.94 GB | Whether language-specific continued pretraining helps the failing script. The card does not establish the Cyrillic share of training data; dense 7B latency and English quality are open questions. |

Sizes are decimal GB from the published file metadata, not measured RAM or latency. The four source repositories are public and declare Apache-2.0 in their cards. Runtime loading, exact tokenizer behavior and downloaded file hashes still need verification before inference.

The [Luchador recipe](https://huggingface.co/rpDungeon/Gemma-4-E4B-Luchador) combines multiple adapters with the IT weights. Adding stock IT is an informative control, but different quantization/calibration recipes still prevent attributing a gain to one specific LoRA or merge technique. A strict causal comparison would require matching those recipes too.

Proposed files are pinned by repository revision and published SHA-256 in the JSON queue:

| Model | Quantization repository | Exact file |
|---|---|---|
| Gemma E4B IT | [bartowski/google_gemma-4-E4B-it-GGUF](https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF) | `google_gemma-4-E4B-it-Q6_K.gguf` |
| Qwen3 4B Base | [mradermacher/Qwen3-4B-Base-i1-GGUF](https://huggingface.co/mradermacher/Qwen3-4B-Base-i1-GGUF) | `Qwen3-4B-Base.i1-Q6_K.gguf` |
| Salamandra 2B | [RichardErkhov/BSC-LT_-_salamandra-2b-gguf](https://huggingface.co/RichardErkhov/BSC-LT_-_salamandra-2b-gguf) | `salamandra-2b.Q6_K.gguf` |
| YugoGPT | [mradermacher/YugoGPT-i1-GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF) | `YugoGPT.i1-Q6_K.gguf` |

Salamandra's quantizer card links the correct original model but includes inconsistent copied prose naming a 7B instruction-tuned version. Its base identity and tensor dimensions must therefore be checked from the GGUF before admission to the benchmark. Do not silently substitute an instruction-tuned quant. The saved source-card revision records what was inspected; it does not prove the exact upstream weight revision used by a third-party quantizer.

Claude also suggested EuroLLM-1.7B as an alternate in the Salamandra slot, and a large Gemma/Qwen MoE as an optional quality ceiling. Those are deferred: the verified main batch already has four distinct hypotheses, and the MoE requires a substantially different memory budget. No performance claim or model substitution follows from these suggestions.

## Papers and the experiments they add

| Paper selected by Claude | Verified contribution | Proposed LokalBot experiment |
|---|---|---|
| Petrov, La Malfa, Torr & Bibi, [Language Model Tokenizers Introduce Unfairness Between Languages](https://arxiv.org/abs/2305.15425), NeurIPS 2023 | Equivalent content can have very different token lengths across languages. | Measure tokens per word/character on aligned English, Serbian Latin and Cyrillic text; record how often the six-token limit cuts a word short. Any word-budget comparison is a separate decoder experiment. |
| Geifman & El-Yaniv, [Selective Classification for Deep Neural Networks](https://arxiv.org/abs/1705.08500), 2017 | Evaluate the trade-off between accepted predictions and error among accepted predictions. | Plot poor-suggestion rate and utility against coverage, by model and script. Calibrate gates on new development data and confirm at matched coverage on a newly sealed split. |
| Phan, Havasi, Muckley & Ullrich, [Understanding and Mitigating Tokenization Bias in Language Models](https://arxiv.org/abs/2406.16829), 2024 | Token-prefix conditioning can differ from conditioning on the corresponding characters; the paper derives correction algorithms. | Audit partial-word confidence and alternatives using each tokenizer. Compare existing healing with a bounded correction prototype, separately from model replacement. The paper's general correction is not equivalent to ordinary token healing. |

Claude additionally recommended Guo, Pleiss, Sun & Weinberger's [On Calibration of Modern Neural Networks](https://arxiv.org/abs/1706.04599), ICML 2017, as a companion for fitting confidence. Its classification results motivate a calibration experiment; they do not establish that first-word probability is already a calibrated measure of suggestion usefulness.

## How to run the next round fairly

1. Keep the installed E2B hybrid as the reference and Luchador as the previous quality finalist. First run all four additions with the same prompt, decoder, sampler and six-token/four-word limits. Verify model identity and native loading before scoring. Report integration failures separately from quality.
2. Freeze new development and confirmation phrases before generating candidate output. Earlier confirmation cases are now historical regression data, not an untouched holdout. Preserve English/Serbian Latin/Serbian Cyrillic and boundary/mid-word breakdowns. Include independent human ratings if available.
3. Use serial, reordered timing rounds on the same machine. Separate fresh-context prefill from shared-prefix generation, and report mean/p95, coverage, poor suggestions, utility and exact reference matches. Keep the latency boundary consistent with the original report.
4. Run matched-coverage calibration as a separately labelled experiment. The current study's JSONL records final text/suppression/latency but not the complete candidate confidence trajectories or suppressed continuations needed to sweep both hybrid gates. Capture those in instrumented replays; judge newly exposed continuations before comparing utility. Keep mid-word healing, which bypasses boundary gates, separate. Do not tune on confirmation ratings.

LokalBot already implements token healing; adding it is not a new recommendation. The tokenization papers motivate measuring and testing its remaining approximations. Differences across tokenizer families may matter, but token fragmentation alone cannot explain a within-family regression if the compared models use identical tokenizers.

Claude's raw response also refers to a previously observed 200 ms speed cliff and a user-imposed 15–20 minute approval rule. Neither is supported by this study or the supplied instructions, so neither was adopted. Its suggestion that gate sweeps are a zero-cost re-analysis is limited by the missing trace data described above. No new quality, latency or acceptance result is claimed for this queue.
