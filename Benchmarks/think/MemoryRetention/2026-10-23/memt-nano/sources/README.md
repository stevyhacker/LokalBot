---
library_name: transformers
pipeline_tag: text-generation
tags:
  - custom_code
  - memt
  - text-generation
base_model: Qwen/Qwen3.6-35B-A3B
license: apache-2.0
---

# **MemT-1.0-Nano**

![MemT-1.0](assets/MemT-1.0.png)

<p align="center" style="line-height: 0;">
  <a href="https://huggingface.co/collections/MemTensor/memt-1" style="display: inline-block; height: 20px; line-height: 0; vertical-align: middle;"><img src="assets/badges/huggingface-models.svg" alt="Hugging Face Models" width="151" height="20" style="display: inline-block; height: 20px; vertical-align: middle; margin: 0;"></a>
  <a href="https://arxiv.org/pdf/2610.26825" style="display: inline-block; height: 20px; line-height: 0; vertical-align: middle;"><img src="assets/badges/tech-report.svg" alt="Tech Report: PDF" width="140" height="20" style="display: inline-block; height: 20px; vertical-align: middle; margin: 0;"></a>
  <a href="https://github.com/MemTensor/MemT-1.0" style="display: inline-block; height: 20px; line-height: 0; vertical-align: middle;"><img src="assets/badges/github.svg" alt="GitHub: MemT-1.0" width="147" height="20" style="display: inline-block; height: 20px; vertical-align: middle; margin: 0;"></a>
</p>

## **Overview**

**MemT-1.0 is a new generation of memory foundation models that makes persistent, dynamically evolving memory an intrinsic part of model computation.**

MemT-1.0 integrates dynamic local memory and trainable hyper memory to retain and leverage historical information without accessing original context at inference. Its persistent state remains constant in size, reducing storage by approximately 66× versus full-context KV cache at 128K history length.

The project makes three main contributions:

* **Memory architecture**. Introduce MemT-1.0 with improved memory storage and utilization, and Mixture-of-Storage (MoS) for scalable memory capacity.

* **Training and evaluation**. Develop backbone preparation and a two-stage training pipeline, supported by 34B tokens of data and dedicated infrastructure. Evaluate memory and general capabilities.

* **Scaling and applications**. Study memory scaling and demonstrate native memory for experience-guided agentic coding.

### Model Family

| Model                       | Backbone                   | Total Parameters | Activated Parameters | Trainable Memory Parameters | Dynamic Memory State |
| --------------------------- | -------------------------- | ---------------- | -------------------- | --------------------------- | -------------------- |
| MemT-1.0-Nano               | Qwen3.6-35B-A3B            | 36B              | 3B                   | 451M                        | 10M                  |
| MemT-1.0-Flash              | DeepSeek-V4-Flash          | 288B             | 17B                  | 3.61B                       | 336M                 |

### Architecture

A **Native Memory Block** runs alongside the backbone attention and contains two components:

* The **Local Memory Block** maintains a dynamic, multi-channel memory matrix and evolves across interaction steps.

* The **Hyper Memory Block** contains trainable memory query, key, and value projections, erase, write, and forget gates, as well as an output gate.

During generation, memory attention reads from the current memory state, normalizes and gates the readout, and adds it to the backbone attention output. At the end of each turn or segment, a stable GDN-2 performs token-level memory updates the memory state for subsequent steps.

![MemT-1.0 native memory architecture](assets/memt-arc.jpg)

### Evaluation Results

Across 11 memory benchmarks, MemT-1.0-Flash and MemT-1.0-Nano rank first and second among the **evaluated parametric-memory methods**, respectively. Strong textual-memory systems remain ahead overall, particularly on long histories that require detailed evidence retrieval.

![MemT-1.0 memory benchmark results](assets/figure_performance.png)

### Experience-Guided Agentic Coding

MemT-1.0 introduces an agentic framework for reusing procedural experience in long-horizon coding tasks. Retrieved experience is stored in native memory and accessed through memory attention during execution, improving task performance without adding experience text to the task context.

![Experience-guided coding agents](assets/application.png)

## **Quick Start**

The examples below use MemT-1.0 with Hugging Face Transformers.

### Installation

Use Python 3.11 or newer and install a CUDA 13 build of PyTorch 2.11.0 for your GPU, then:

```bash
pip install transformers==5.12.1 accelerate==1.15.0 safetensors==0.8.0
```

### Load the Model

```python
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, pipeline

model_id = "MemTensor/MemT-1.0-Nano"  # Or a local model directory.
tokenizer = AutoTokenizer.from_pretrained(model_id, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(
    model_id,
    trust_remote_code=True,
    dtype=torch.bfloat16,
    device_map="auto",
    attn_implementation="sdpa",
)
```

### A Conversation with Memory

```python
session = model.create_session(tokenizer)

# Set enable_memory=True to save past and current turns information to latent
# local memory and clear the plaintext conversation context.
session.chat(
    "I have a three-month-old kitten named memmy who loves eating "
    "small shrimp and is excellent at remembering things.",
    enable_memory=True,
    enable_thinking=False,
)

# Answer using the latent local memory.
answer = session.chat(
    "What are my kitten's name, age, favorite food, and special trait?",
    enable_thinking=False,
)
print(answer)
# Based on the information you provided earlier:
#
# *   **Name:** Memmy
# *   **Age:** Three months old
# *   **Favorite Food:** Small shrimp
# *   **Special Trait:** An excellent memory
```

### Save and Resume

```python
# Save local memory, including any unsaved conversation turns.
state_path = "memmy_memory.safetensors"
session.save_state(state_path)
session.close()

# Restore local memory without loading the plaintext conversation.
restored = model.create_session(tokenizer, state=state_path)

print(len(restored.messages))
# 0

answer = restored.chat(
    "How old is my kitten?",
    enable_thinking=False,
)
print(answer)
# Your kitten is **3 months old**.

restored.close()
```

### Standard Chat

```python
# Use the standard Transformers pipeline for chat generation with plaintext context, without enable_memory.
generator = pipeline("text-generation", model=model, tokenizer=tokenizer)
messages = [{
    "role": "user",
    "content": "Type 'I love MemT' exactly.",
}]
result = generator(
    messages,
    generation_config=model.generation_config,
    tokenizer_encode_kwargs={"enable_thinking": False},
)
print(result[0]["generated_text"][-1]["content"])
# I love MemT
```

## **Citation**

For the MemT-1.0 technical report:

```bibtex
@misc{memtensor2026memt1,
  title        = {MemT-1.0: Towards Memory-Native Evolution},
  author       = {{MemTensor Team}},
  year         = {2026},
  howpublished = {Technical report}
}
```

## **License**

The MemT-1.0-Nano model weights are released under the
**[Apache License, Version 2.0](https://www.apache.org/licenses/LICENSE-2.0)**.

We thank the Qwen team for the backbone model.
The backbone and third-party components retain their original licenses and
copyright notices; the MemT license does not replace their terms.

Portions of the inference code are adapted from Hugging Face Transformers
and retain their upstream attribution:
Copyright 2025 The Qwen Team and The HuggingFace Inc. team. All rights reserved. Apache License 2.0.

## **Contact**

Correspondence: [lizy@memtensor.cn](mailto:lizy@memtensor.cn).
