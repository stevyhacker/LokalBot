Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../../2026-10-10-experiments-manifest.json).

---
license: apache-2.0
library_name: transformers
---
# Qwen3-4B-Base

## Qwen3 Highlights

Qwen3 is the latest generation of large language models in Qwen series, offering a comprehensive suite of dense and mixture-of-experts (MoE) models.
Building upon extensive advancements in training data, model architecture, and optimization techniques, Qwen3 delivers the following key improvements over the previously released Qwen2.5:

- **Expanded Higher-Quality Pre-training Corpus:** Qwen3 is pre-trained on 36 trillion tokens across 119 languages — tripling the language coverage of Qwen2.5 — with a much richer mix of high-quality data, including coding, STEM, reasoning, book, multilingual, and synthetic data.
- **Training Techniques and Model Architecture:** Qwen3 incorporates a series of training techiques and architectural refinements, including global-batch load balancing loss for MoE models and qk layernorm for all models, leading to improved stability and overall performance.
- **Three-stage Pre-training:** Stage 1 focuses on broad language modeling and general knowledge acquisition, Stage 2 improves reasoning skills like STEM, coding, and logical reasoning, and Stage 3 enhances long-context comprehension by extending training sequence lengths up to 32k tokens.
- **Scaling Law Guided Hyperparameter Tuning:** Through comprehensive scaling law studies across the three-stage pre-training pipeline, Qwen3 systematically tunes critical hyperparameters — such as learning rate scheduler and batch size — separately for dense and MoE models, resulting in better training dynamics and final performance across different model scales.

## Model Overview

**Qwen3-4B-Base** has the following features:
- Type: Causal Language Models
- Training Stage: Pretraining
- Number of Parameters: 4.0B
- Number of Paramaters (Non-Embedding): 3.6B
- Number of Layers: 36
- Number of Attention Heads (GQA): 32 for Q and 8 for KV
- Context Length: 32,768

For more details, including benchmark evaluation, hardware requirements, and inference performance, please refer to our [blog](https://qwenlm.github.io/blog/qwen3/), [GitHub](https://github.com/QwenLM/Qwen3), and [Documentation](https://qwen.readthedocs.io/en/latest/).

## Requirements

The code of Qwen3 has been in the latest Hugging Face `transformers` and we advise you to use the latest version of `transformers`.

With `transformers<4.51.0`, you will encounter the following error:
```
KeyError: 'qwen3'
```

## Evaluation & Performance

Detailed evaluation results are reported in this [📑 blog](https://qwenlm.github.io/blog/qwen3/).

### Citation

If you find our work helpful, feel free to give us a cite.

```
@misc{qwen3technicalreport,
      title={Qwen3 Technical Report},
      author={Qwen Team},
      year={2025},
      eprint={2505.09388},
      archivePrefix={arXiv},
      primaryClass={cs.CL},
      url={https://arxiv.org/abs/2505.09388},
}
```
