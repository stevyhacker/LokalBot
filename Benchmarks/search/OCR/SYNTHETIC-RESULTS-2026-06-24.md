# Synthetic OCR Benchmark Results - 2026-06-24

Input set: five locally generated synthetic screenshots with explicit ground
truth text in `Benchmarks/search/OCR/synthetic/manifest.tsv`.

Hardware/runtime: Apple M4 Max MacBook. Apple Vision used
`VNRecognizeTextRequest` with `.accurate` and language correction disabled.
PP-OCRv6 ran through PaddleOCR. PaddleOCR-VL and DeepSeek-OCR ran through the
bundled `Vendor/llama-cpp/llama-server` using GGUF models at a 1024-token cap.

Metric notes: token scores use normalized multiset tokens. Character similarity
uses normalized whitespace/case and is sensitive to reading-order changes in
multi-column UI screenshots.

| Engine | Images | Mean latency | Token precision | Token recall | Token F1 | Token Jaccard | Char similarity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple Vision | 5 | 119.6 ms | 0.971 | 0.971 | 0.971 | 0.946 | 0.812 |
| PP-OCRv6 medium | 5 | 6.78 s | 0.960 | 0.990 | 0.974 | 0.952 | 0.867 |
| PaddleOCR-VL GGUF | 5 | 1.70 s | 0.871 | 0.813 | 0.777 | 0.717 | 0.731 |
| DeepSeek-OCR GGUF | 5 | 1.44 s | 0.844 | 0.732 | 0.741 | 0.687 | 0.680 |

## Per-Fixture Notes

| Fixture | Surface | Apple Vision F1 | PP-OCRv6 F1 | PaddleOCR-VL F1 | DeepSeek F1 | Notes |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `synth-01` | Code editor | 0.913 | 0.904 | 0.318 | 0.895 | PaddleOCR-VL read the chrome/sidebar but missed the code body. DeepSeek recovered most tokens but had ordering/noise issues. |
| `synth-02` | Dashboard/table | 0.942 | 0.987 | 0.568 | 0.987 | DeepSeek and PP-OCRv6 handled this fixture best. PaddleOCR-VL duplicated text and invented repeated values. |
| `synth-03` | Terminal | 1.000 | 0.978 | 1.000 | 0.933 | Vision and PaddleOCR-VL handled terminal text perfectly. |
| `synth-04` | Chat notes | 1.000 | 1.000 | 1.000 | 0.865 | DeepSeek dropped some visible chat text. |
| `synth-05` | Preferences | 1.000 | 1.000 | 1.000 | 0.028 | DeepSeek entered a repetition loop: `OCR# 1.1.1...` until the token cap. |

## Decision

PP-OCRv6 medium was the only tested open-source option that was slightly higher
quality than Apple Vision on this synthetic set, mostly from higher recall and
better character-order similarity on the dashboard/table fixture. It was still
about 57x slower than Apple Vision on these same images and had a roughly
15-second model load.

PaddleOCR-VL GGUF is much faster than PP-OCRv6, but it is not reliable enough as
a screenshot OCR replacement: it missed dense code text and produced duplicated
or hallucinated dashboard content.

DeepSeek-OCR GGUF was the fastest open-source VLM path in this synthetic run,
but it was not reliable. It had two good fixtures, two partial fixtures, and one
hard repetition-loop failure. A second run with the upstream-style `Free OCR.`
prompt was worse overall: mean token F1 fell to 0.529 and the model looped on
two fixtures. The upstream DeepSeek examples also use an n-gram logits processor
in the vLLM path; this llama.cpp GGUF path did not have that protection.

Keep Apple Vision as the default continuous screenshot OCR pipeline. PP-OCRv6 is
worth retaining only as a slow offline/manual high-recall experiment, not as a
default switch. PaddleOCR-VL GGUF and DeepSeek-OCR GGUF remain useful only as
fast exploratory VLM parse modes when exact OCR fidelity is not required.

## Reproduction

```bash
python3 Benchmarks/search/OCR/create_synthetic_screenshots.py --output-dir Benchmarks/search/OCR/synthetic
CLANG_MODULE_CACHE_PATH=/private/tmp/lokalbot-clang-cache swift Benchmarks/search/OCR/VisionImageBenchmark.swift Benchmarks/search/OCR/synthetic/manifest.tsv /private/tmp/synth-ocr-results > /private/tmp/synth-vision.tsv
PADDLE_PDX_CACHE_HOME=/private/tmp/paddlex-cache PADDLE_PDX_MODEL_SOURCE=huggingface PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK=True /private/tmp/synth-ocr-venv/bin/python Benchmarks/search/OCR/run_paddleocr_synthetic.py --manifest Benchmarks/search/OCR/synthetic/manifest.tsv --variant ppocr-v6-medium --output-dir /private/tmp/synth-ocr-results > /private/tmp/synth-ppocr.tsv
python3 Benchmarks/search/OCR/run_llamacpp_vlm_synthetic.py --manifest Benchmarks/search/OCR/synthetic/manifest.tsv --endpoint http://127.0.0.1:8097/v1/chat/completions --output-dir /private/tmp/synth-ocr-results --max-tokens 1024 --model-label paddleocr-vl-gguf > /private/tmp/synth-paddleocr-vl.tsv
python3 Benchmarks/search/OCR/run_llamacpp_vlm_synthetic.py --manifest Benchmarks/search/OCR/synthetic/manifest.tsv --endpoint http://127.0.0.1:8098/v1/chat/completions --output-dir /private/tmp/synth-ocr-results --max-tokens 1024 --model-label deepseek-ocr-gguf > /private/tmp/synth-deepseek.tsv
python3 Benchmarks/search/OCR/score_text_outputs.py /private/tmp/synth-vision.tsv /private/tmp/synth-ppocr.tsv /private/tmp/synth-paddleocr-vl.tsv /private/tmp/synth-deepseek.tsv
```
