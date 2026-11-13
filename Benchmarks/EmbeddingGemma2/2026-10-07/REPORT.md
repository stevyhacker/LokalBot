# EmbeddingGemma 2 on llama.cpp — 7 October 2026

Follow-up to the [6 October comparison](../2026-10-06/REPORT.md). That run used PyTorch MPS, so its main reason to keep Harrier was a slower query path that LokalBot would never ship. This run sends the same frozen fixtures through a llama-server build that supports EmbeddingGemma 2. Harrier ran on the same binary.

**Result: on llama.cpp, EmbeddingGemma 2 text is smaller, faster and at least as accurate as Harrier on this sample. Its vectors match PyTorch. The quality gain on this sample is still not significant, so check a real library before switching the default.**

Hardware: Apple M4 Max / 48 GiB, serial single-input requests, synthetic inputs only. Nothing touched app settings, models, indexes or the installed bundle.

## Runtime requirement

The model needs llama.cpp support from [ggml-org/llama.cpp#30054](https://github.com/ggml-org/llama.cpp/pull/30054), merged 2026-10-06. The app's current pin, `v0.6.0`, was tagged 2026-10-05. It is 23 commits behind that merge and does not load this model. This run used upstream release `b11469`, commit `ad2156533`, macOS arm64 binaries. The app's own build from source, which targets macOS 15, was not qualified.

To embed an image, send it as a typed content part nested one level inside each `input` item. A flat `input: [{type: image_url}]` returns 400, as reported in [ggml-org/llama.cpp#30082](https://github.com/ggml-org/llama.cpp/issues/30082):

```json
{"input": [{"content": [{"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}]}]}
```

## Text — same binary, Q8_0 both

| | Harrier 0.6B | EmbeddingGemma 2 text 270M |
|---|---:|---:|
| Top one, all / EN / BCS | 40 / 22 / 18 of 48 | **43 / 23 / 20** |
| Top five | 47 | **48** |
| Query embedding p50 / p95 | 13.1 / 14.8 ms | **9.0 / 9.5 ms** |
| Document embedding p50 | 17.4 ms | **10.9 ms** |
| Peak server RSS, one input per request | 1.15 GiB | **0.83 GiB** |
| GGUF download | 639 MB | **310 MB** |
| Vector | 1,024 floats | 768, or 512 with Matryoshka truncation |
| Context | 2,048 tokens as configured | 8,192 |

The top-one quality numbers match the PyTorch run exactly. Gemma 512d scores 42/48, and 256d drops to Harrier's 40/48. The paired interval is unchanged at +6.25 points, with a 95% interval of −4.2 to +16.7. Gemma's two BCS regressions from 6 October reproduce: offline planning and streaming ASR.

Parity with BF16 PyTorch: every text vector agrees at cosine ≥ 0.9996, with a median of 0.9999. The GGUF carries the mean pooling and 512→768 projection, so no server pooling flag is needed.

## Screens — 25 images / 50 queries

| Representation, 768d | Top one | Top five | MRR | PyTorch top one |
|---|---:|---:|---:|---:|
| OCR + Harrier | 24 | 47 | 0.655 | 24 |
| OCR + Gemma text | 28 | 48 | 0.708 | 27 |
| Gemma image | 34 | 49 | 0.795 | 35 |
| Gemma OCR + image combined | **35** | 49 | **0.802** | 34 |

The image path adds +20 points over OCR + Harrier, with a paired interval of +2 to +40. As on 6 October, this holds only for constructed fixtures. Image embeddings take **168 ms p50 / 361 ms p95**, against 256 / 299 ms on MPS. Combined embeddings take 171 / 447 ms. Peak RSS with the projector loaded is **2.05 GiB**. The Q8 `mmproj` adds **555 MB** to the download, and it bundles the audio encoder, which this run cannot leave out.

Image vectors agree with PyTorch less closely, with a minimum cosine of 0.963 and a median of 0.993. llama.cpp encodes most fixtures as 319 tokens and some wide ones as 574, while the reference processor uses a 280-token budget. Most categories hold up, but they shift. Charts improve from 7 to 10 of 12, while task-board state drops from 3 to 0 of 8. Tune and qualify the image token budget before relying on visual recall.

## App configuration

These checks ran after the switch was planned, on the vendored source build of b11474.

**Same vectors as b11469.** For Harrier, Gemma text and Gemma image inputs, every vector matches the b11469 upstream release at cosine 1.000000, and all scores are unchanged.

**Parity under the app's settings.** `app_parity.py` launches the server with the app's exact embedder arguments:

```
-c 2048 -b 2048 -ub 2048 --embeddings --parallel 1 --jinja
```

No pooling flag is passed. It sends requests shaped like the app's:
- a whole meeting's chunks in one request;
- screen OCR in batches of 32;
- queries one per request.

Every vector matched the single-input reference at cosine 1.000000:
- all synthetic fixtures;
- all 4,302 meeting chunks and 2,785 screen-OCR documents of a real library.

No real input exceeded the 2,048-token batch. The longest real screen measured 955 Gemma tokens; a constructed 1,800-character code chunk measured 1,133. With prompt caching on, the vectors were also identical. The app turns caching off anyway, so correctness doesn't depend on server defaults.

**Memory while indexing.** Single-input requests understate memory, so `memory_probe` sent 640 real screens in batches of 32 with each model's app arguments:

| Server | Idle RSS | Peak RSS while indexing | Time for 640 screens |
|---|---:|---:|---:|
| Harrier, `--pooling last`, default micro-batch | 970 MiB | 1,287 MiB | 38.1 s |
| EmbeddingGemma 2, `-b 2048 -ub 2048` | **493 MiB** | 1,289 MiB | **23.0 s** |

Gemma halves idle memory and indexes faster; peak memory while indexing is about the same. A whole-meeting request of 64 chunks peaked at 1,471 MiB.

## Reproduce

```sh
# after the 6 October setup, with its disposable root still present
python Benchmarks/EmbeddingGemma2/2026-10-07/run_llamacpp.py gemma-text
python Benchmarks/EmbeddingGemma2/2026-10-07/run_llamacpp.py gemma-vision
python Benchmarks/EmbeddingGemma2/2026-10-07/run_llamacpp.py harrier
python Benchmarks/EmbeddingGemma2/2026-10-07/score_llamacpp.py
# app configuration, on the vendored build (after bash Scripts/build/fetch-llama.sh)
python Benchmarks/EmbeddingGemma2/2026-10-07/run_llamacpp.py gemma-text \
  --binary Vendor/llama-cpp/llama-server --results /private/tmp/lokalbot-embeddinggemma2-20261007/results-b11474
python Benchmarks/EmbeddingGemma2/2026-10-07/app_parity.py   # add --real-library after reallib/prepare.py and embed.py
python Benchmarks/EmbeddingGemma2/2026-10-07/memory_probe.py  # needs the real-library corpus
```

The binary comes from the `b11469` release asset `llama-b11469-bin-macos-arm64.tar.gz`. GGUF files come from [ggml-org/embeddinggemma-2-GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF) and are pinned with checksums in [model-checksums.txt](model-checksums.txt). The repository head was `e60b5a7`. [Scores](results/scores.json), per-input timings and vectors are in `results/`.
