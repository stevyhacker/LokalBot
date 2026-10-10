Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../2026-10-10-experiments-manifest.json).

---
license: other
language:
- en
- ar
- zh
- fr
- de
- ja
- ko
- es
pipeline_tag: text-generation
library_name: transformers
tags:
- liquid
- lfm2.5
- edge
---

<div align="center">
  <img
    src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/2b08LKpev0DNEk6DlnWkY.png"
    alt="Liquid AI"
    style="width: 100%; max-width: 100%; height: auto; display: inline-block; margin-bottom: 0.5em; margin-top: 0.5em;"
  />
  <div style="display: flex; justify-content: center; gap: 0.5em;">
<a href="https://playground.liquid.ai/"><strong>Try LFM</strong></a> • <a href="https://docs.liquid.ai/lfm/getting-started/welcome"><strong>Docs</strong></a> • <a href="https://leap.liquid.ai/"><strong>LEAP</strong></a> • <a href="https://discord.com/invite/liquid-ai"><strong>Discord</strong></a>
  </div>
</div>

<br>

# LFM2.5-1.2B-Base

LFM2.5 is a new family of hybrid models designed for **on-device deployment**. It builds on the LFM2 architecture with extended pre-training and reinforcement learning.

Find more information about LFM2.5 in our [blog post](https://www.liquid.ai/blog/introducing-lfm2-5-the-next-generation-of-on-device-ai).

## 🗒️ Model Details

| Model | Parameters | Description |
|-------|------------|-------------|
| [**LFM2.5-1.2B-Base**](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Base) | 1.2B | Pre-trained base model for fine-tuning |
| [LFM2.5-1.2B-Instruct](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct) | 1.2B | General-purpose instruction-tuned model |
| [LFM2.5-1.2B-Thinking](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking) | 1.2B | General-purpose reasoning model |
| [LFM2.5-1.2B-JP](https://huggingface.co/LiquidAI/LFM2.5-1.2B-JP) | 1.2B | Japanese-optimized chat model |
| [LFM2.5-VL-1.6B](https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B) | 1.6B | Vision-language model with fast inference |
| [LFM2.5-Audio-1.5B](https://huggingface.co/LiquidAI/LFM2.5-Audio-1.5B) | 1.5B | Audio-language model for speech and text I/O |

LFM2.5-1.2B-Base is the pre-trained text-only checkpoint, used to create all the LFM2.5-1.2B variants. It has the following features:

- **Number of parameters**: 1.17B
- **Number of layers**: 16 (10 double-gated LIV convolution blocks + 6 GQA blocks)
- **Training budget**: 28T tokens
- **Context length**: 32,768 tokens
- **Vocabulary size**: 65,536
- **Knowledge cutoff**: Mid-2024
- **Languages**: English, Arabic, Chinese, French, German, Japanese, Korean, Spanish

| Model | Description |
|-------|-------------|
| [**LFM2.5-1.2B-Base**](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct) | Original model checkpoint in native format. Best for fine-tuning or inference with Transformers and vLLM. |
| [LFM2.5-1.2B-Base-GGUF](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF) | Quantized format for llama.cpp and compatible tools. Optimized for CPU inference and local deployment with reduced memory usage. |
| [LFM2.5-1.2B-Base-ONNX](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-ONNX) | ONNX Runtime format for cross-platform deployment. Enables hardware-accelerated inference across diverse environments (cloud, edge, mobile). |

This pre-trained checkpoint is only recommended for tasks that require heavy fine-tuning, like language-specific (e.g., Japanese) or domain-specific (e.g., medical) assistants, training on proprietary data, or experimenting with novel post-training approaches.

## 🏃 Inference

LFM2.5 is supported by many inference frameworks. See the [Inference documentation](https://docs.liquid.ai/lfm/inference/transformers) for the full list.

| Name | Description | Docs | Notebook |
|------|-------------|------|----------|
| [Transformers](https://github.com/huggingface/transformers) | Simple inference with direct access to model internals. | <a href="https://docs.liquid.ai/lfm/inference/transformers">Link</a> | <a href="https://colab.research.google.com/drive/1_q3jQ6LtyiuPzFZv7Vw8xSfPU5FwkKZY?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| [vLLM](https://github.com/vllm-project/vllm) | High-throughput production deployments with GPU. | <a href="https://docs.liquid.ai/lfm/inference/vllm">Link</a> | <a href="https://colab.research.google.com/drive/1VfyscuHP8A3we_YpnzuabYJzr5ju0Mit?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | Cross-platform inference with CPU offloading. | <a href="https://docs.liquid.ai/lfm/inference/llama-cpp">Link</a> | <a href="https://colab.research.google.com/drive/1ohLl3w47OQZA4ELo46i5E4Z6oGWBAyo8?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |

Here's a quick start example with `transformers`:

```python
from transformers import AutoModelForCausalLM, AutoTokenizer, TextStreamer

model_id = "LiquidAI/LFM2.5-1.2B-Base"
model = AutoModelForCausalLM.from_pretrained(
    model_id,
    device_map="auto",
    dtype="bfloat16",
#   attn_implementation="flash_attention_2" <- uncomment on compatible GPU
)
tokenizer = AutoTokenizer.from_pretrained(model_id)
```

## 🔧 Fine-Tuning

We recommend fine-tuning LFM2.5 for your specific use case to achieve the best results.

| Name | Description | Docs | Notebook |
|------|-------------|------|----------|
| CPT ([Unsloth](https://github.com/unslothai/unsloth)) | Continued Pre-Training using Unsloth for text completion. | <a href="https://docs.liquid.ai/lfm/fine-tuning/unsloth">Link</a> | <a href="https://colab.research.google.com/drive/10fm7eNMezs-DSn36mF7vAsNYlOsx9YZO?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| CPT ([Unsloth](https://github.com/unslothai/unsloth)) | Continued Pre-Training using Unsloth for translation. | <a href="https://docs.liquid.ai/lfm/fine-tuning/unsloth">Link</a> | <a href="https://colab.research.google.com/drive/1gaP8yTle2_v35Um8Gpu9239fqbU7UgY8?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| SFT ([Unsloth](https://github.com/unslothai/unsloth)) | Supervised Fine-Tuning with LoRA using Unsloth. | <a href="https://docs.liquid.ai/lfm/fine-tuning/unsloth">Link</a> | <a href="https://colab.research.google.com/drive/1vGRg4ksRj__6OLvXkHhvji_Pamv801Ss?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| SFT ([TRL](https://github.com/huggingface/trl)) | Supervised Fine-Tuning with LoRA using TRL. | <a href="https://docs.liquid.ai/lfm/fine-tuning/trl">Link</a> | <a href="https://colab.research.google.com/drive/1j5Hk_SyBb2soUsuhU0eIEA9GwLNRnElF?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| DPO ([TRL](https://github.com/huggingface/trl)) | Direct Preference Optimization with LoRA using TRL. | <a href="https://docs.liquid.ai/lfm/fine-tuning/trl">Link</a> | <a href="https://colab.research.google.com/drive/1MQdsPxFHeZweGsNx4RH7Ia8lG8PiGE1t?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |
| GRPO ([Unsloth](https://github.com/unslothai/unsloth)) | GRPO with LoRA using Unsloth. | <a href="https://docs.liquid.ai/lfm/fine-tuning/unsloth">Link</a> | <a href="https://colab.research.google.com/drive/1mIikXFaGvcW4vXOZXLbVTxfBRw_XsXa5?usp=sharing"><img src="https://cdn-uploads.huggingface.co/production/uploads/61b8e2ba285851687028d395/vlOyMEjwHa_b_LXysEu2E.png" width="110" alt="Colab link"></a> |

## 📬 Contact

- Got questions or want to connect? [Join our Discord community](https://discord.com/invite/liquid-ai)
- If you are interested in custom solutions with edge deployment, please contact [our sales team](https://www.liquid.ai/contact).

## Citation

```bibtex
@article{liquidai2025lfm2,
  title={LFM2 Technical Report},
  author={Liquid AI},
  journal={arXiv preprint arXiv:2511.23404},
  year={2025}
}
```
