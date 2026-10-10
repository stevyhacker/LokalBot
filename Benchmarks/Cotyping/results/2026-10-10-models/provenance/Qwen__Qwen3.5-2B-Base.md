Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

---
library_name: transformers
license: apache-2.0
license_link: https://huggingface.co/Qwen/Qwen3.5-2B-Base/blob/main/LICENSE
pipeline_tag: image-text-to-text
---

# Qwen3.5-2B-Base

<img width="400px" src="https://qianwen-res.oss-accelerate.aliyuncs.com/logo_qwen3.5.png">

[![Qwen Chat](https://img.shields.io/badge/%F0%9F%92%9C%EF%B8%8F%20Qwen%20Chat%20-536af5)](https://chat.qwen.ai)

> [!Note]
> This repository contains model weights and configuration files for the pre-trained only model in the Hugging Face Transformers format.
>
> These artifacts are compatible with Hugging Face Transformers, vLLM, SGLang, etc.
>
> The intended use cases are fine-tuning, in-context learning experiments, and other research or development purposes, not direct interaction.
> However, the control tokens, e.g., `<|im_start|>` and `<|im_end|>` were trained to allow efficient LoRA-style PEFT with the official chat template, mitigating the need to finetune embeddings, a significant optimization given Qwen3.5's larger vocabulary.


Over recent months, we have intensified our focus on developing foundation models that deliver exceptional utility and performance. Qwen3.5 represents a significant leap forward, integrating breakthroughs in multimodal learning, architectural efficiency, reinforcement learning scale, and global accessibility to empower developers and enterprises with unprecedented capability and efficiency.

## Qwen3.5 Highlights

Qwen3.5 features the following enhancement:

- **Unified Vision-Language Foundation**: Early fusion training on multimodal tokens achieves cross-generational parity with Qwen3 and outperforms Qwen3-VL models across reasoning, coding, agents, and visual understanding benchmarks.

- **Efficient Hybrid Architecture**: Gated Delta Networks combined with sparse Mixture-of-Experts deliver high-throughput inference with minimal latency and cost overhead.

- **Scalable RL Generalization**: Reinforcement learning scaled across million-agent environments with progressively complex task distributions for robust real-world adaptability.

- **Global Linguistic Coverage**: Expanded support to 201 languages and dialects, enabling inclusive, worldwide deployment with nuanced cultural and regional understanding.

- **Next-Generation Training Infrastructure**: Near-100% multimodal training efficiency compared to text-only training and asynchronous RL frameworks supporting massive-scale agent scaffolds and environment orchestration.


For more details, please refer to our blog post [Qwen3.5](https://qwen.ai/blog?id=qwen3.5).


## Model Overview

- Type: Causal Language Model with Vision Encoder
- Training Stage: Pre-training & Post-training
- Language Model
    - Number of Parameters: 2B
    - Hidden Dimension: 2048
    - Token Embedding: 248320 (Padded)
    - Number of Layers: 24
    - Hidden Layout: 6 × (3 × (Gated DeltaNet → FFN) → 1 × (Gated Attention → FFN))
    - Gated DeltaNet:
        - Number of Linear Attention Heads: 16 for V and 16 for QK
        - Head Dimension: 128
    - Gated Attention:
        - Number of Attention Heads: 8 for Q and 2 for KV
        - Head Dimension: 256
        - Rotary Position Embedding Dimension: 64
    - Feed Forward Network:
        - Intermediate Dimension: 6144
    - LM Output: 248320 (Tied to token embedding)
    - MTP: trained with multi-steps
- Context Length: 262,144 natively and extensible up to 1,010,000 tokens.

### Citation

If you find our work helpful, feel free to give us a cite.

```bibtex
@misc{qwen3.5,
    title  = {{Qwen3.5}: Towards Native Multimodal Agents},
    author = {{Qwen Team}},
    month  = {February},
    year   = {2026},
    url    = {https://qwen.ai/blog?id=qwen3.5}
}
```
