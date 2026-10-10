Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../../2026-10-10-experiments-manifest.json).

---
base_model: gordicaleksa/YugoGPT
language:
- en
library_name: transformers
license: apache-2.0
quantized_by: mradermacher
---
## About

<!-- ### quantize_version: 2 -->
<!-- ### output_tensor_quantised: 1 -->
<!-- ### convert_type: hf -->
<!-- ### vocab_type:  -->
<!-- ### tags: nicoboss -->
weighted/imatrix quants of https://huggingface.co/gordicaleksa/YugoGPT

<!-- provided-files -->
static quants are available at https://huggingface.co/mradermacher/YugoGPT-GGUF
## Usage

If you are unsure how to use GGUF files, refer to one of [TheBloke's
READMEs](https://huggingface.co/TheBloke/KafkaLM-70B-German-V0.1-GGUF) for
more details, including on how to concatenate multi-part files.

## Provided Quants

(sorted by size, not necessarily quality. IQ-quants are often preferable over similar sized non-IQ quants)

| Link | Type | Size/GB | Notes |
|:-----|:-----|--------:|:------|
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ1_S.gguf) | i1-IQ1_S | 1.7 | for the desperate |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ1_M.gguf) | i1-IQ1_M | 1.9 | mostly desperate |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ2_XXS.gguf) | i1-IQ2_XXS | 2.1 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ2_XS.gguf) | i1-IQ2_XS | 2.3 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ2_S.gguf) | i1-IQ2_S | 2.4 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ2_M.gguf) | i1-IQ2_M | 2.6 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q2_K.gguf) | i1-Q2_K | 2.8 | IQ3_XXS probably better |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ3_XXS.gguf) | i1-IQ3_XXS | 2.9 | lower quality |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ3_XS.gguf) | i1-IQ3_XS | 3.1 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q3_K_S.gguf) | i1-Q3_K_S | 3.3 | IQ3_XS probably better |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ3_S.gguf) | i1-IQ3_S | 3.3 | beats Q3_K* |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ3_M.gguf) | i1-IQ3_M | 3.4 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q3_K_M.gguf) | i1-Q3_K_M | 3.6 | IQ3_S probably better |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q3_K_L.gguf) | i1-Q3_K_L | 3.9 | IQ3_M probably better |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-IQ4_XS.gguf) | i1-IQ4_XS | 4.0 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q4_0_4_4.gguf) | i1-Q4_0_4_4 | 4.2 | fast on arm, low quality |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q4_0_4_8.gguf) | i1-Q4_0_4_8 | 4.2 | fast on arm+i8mm, low quality |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q4_0_8_8.gguf) | i1-Q4_0_8_8 | 4.2 | fast on arm+sve, low quality |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q4_0.gguf) | i1-Q4_0 | 4.2 | fast, low quality |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q4_K_S.gguf) | i1-Q4_K_S | 4.2 | optimal size/speed/quality |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q4_K_M.gguf) | i1-Q4_K_M | 4.5 | fast, recommended |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q5_K_S.gguf) | i1-Q5_K_S | 5.1 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q5_K_M.gguf) | i1-Q5_K_M | 5.2 |  |
| [GGUF](https://huggingface.co/mradermacher/YugoGPT-i1-GGUF/resolve/main/YugoGPT.i1-Q6_K.gguf) | i1-Q6_K | 6.0 | practically like static Q6_K |

Here is a handy graph by ikawrakow comparing some lower-quality quant
types (lower is better):

![image.png](https://www.nethype.de/huggingface_embed/quantpplgraph.png)

And here are Artefact2's thoughts on the matter:
https://gist.github.com/Artefact2/b5f810600771265fc1e39442288e8ec9

## FAQ / Model Request

See https://huggingface.co/mradermacher/model_requests for some answers to
questions you might have and/or if you want some other model quantized.

## Thanks

I thank my company, [nethype GmbH](https://www.nethype.de/), for letting
me use its servers and providing upgrades to my workstation to enable
this work in my free time. Additional thanks to [@nicoboss](https://huggingface.co/nicoboss) for giving me access to his private supercomputer, enabling me to provide many more imatrix quants, at much higher quality, than I would otherwise be able to.

<!-- end -->
