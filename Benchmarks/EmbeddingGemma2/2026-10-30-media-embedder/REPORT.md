# EmbeddingGemma 2 images and audio on the app's llama-server — 30 October 2026

This is the first step toward a Files source in Ask, built on the engine of [DigUp](https://github.com/ARahim3/DigUp) (MIT). DigUp runs the same EmbeddingGemma 2 text model as LokalBot: the same Hugging Face revision and the same checksum. It adds the model's image and audio projector, which it runs in its own process on its own llama.cpp build. This run checks whether the app's llama-server can make DigUp's vectors instead, so LokalBot needs no second llama.cpp.

**Result: it can. With the projector loaded, and each image resized for its token budget before it is sent, the vendored llama-server (v0.7.0, b11669) reproduces DigUp's reference vectors. Text and the PNG screenshot match at cosine 1.000000, the JPEG photo at 0.99984 and 0.99976, and speech at 1.000000. Audio works through the OpenAI `input_audio` content part. When llama.cpp sizes the images itself, it spends 2 to 2.5 times the tokens, and the vectors drift to 0.99 and 0.97.**

Hardware: Apple M4 Max, 48 GiB, macOS 27.2, on AC power. Inputs were synthetic only: DigUp's committed reference files, plus inputs that `load_probe.py` generates. Nothing touched the app's settings, indexes or installed bundle. The app's text model was read in place.

## Setup

- **Text-only server.** The `Scripts/fetch-llama.sh` build, started exactly as `LlamaServer.start` starts the embedder role, on a private port with a bearer token: `-c 2048 -ngl 99 --jinja --no-webui --embeddings -b 2048 -ub 2048 --parallel 1`. Requests send `cache_prompt: false`, as the app does.
- **Media server.** The same arguments plus `--mmproj mmproj-embeddinggemma-2-Q8_0.gguf --image-min-tokens 1 --image-max-tokens 1120`. DigUp creates its media context with these values. llama.cpp then never rescales an image that already has its final size.
- **Images.**
  - Decoded with Pillow.
  - Resized with Pillow's bicubic filter to DigUp's target size for the budget. `common.target_size` ports DigUp's `ImageSizing.targetSize`, and DigUp's Swift resampler matches Pillow bit for bit.
  - Sent as PNG, as a typed content part: `{"input": [{"content": [{"type": "image_url", ...}]}]}`.
- **Audio.** A 16 kHz WAV, sent as `{"type": "input_audio", "input_audio": {"data": ..., "format": "wav"}}`.
- **Reference.**
  - `reference/vectors.json` comes from DigUp at `dc2651a` (27 October). It was made with llama.cpp b11461 and is DigUp's vectors version 1.
  - The inputs are DigUp's synthetic fixtures. `reference/` holds them, with DigUp's license.
  - A cosine of 0.999 passes. DigUp uses the same bar in its `ReferenceVectorTests`.
- **Models.** `model-checksums.txt` pins both files. They come from the revision the app already pins.

## Parity with DigUp's reference inputs

| Input | Budget | Server | Tokens | Cosine to reference |
|---|---:|---|---:|---:|
| 5 texts: English, Bengali and Arabic queries, a document, a 1,800-token document | — | text only | — | ≥ 0.999999 |
| The same 5 texts | — | media | — | equal to text only, 1.000000 |
| `screen.png`, 1440 × 900 | 280 | media, sized | 277 | **1.000000** |
| `photo.jpg`, 1024 × 768 | 140 | media, sized | 134 | **0.999843** |
| `photo.jpg` as a video frame | 70 | media, sized | 67 | **0.999762** |
| `speech.wav`, 4 s | — | media | 104 | **1.000000** |
| `screen.png`, original file | — | media, llama.cpp sizing | 574 | 0.989814 |
| `photo.jpg`, original file | — | media, llama.cpp sizing | 340 | 0.970749 |

- **Batching.** The 5 texts in one request, as the app sends them, match one request per text at cosine 1.000000.
- **Token counts.** An image takes its budget's grid plus 4 tokens. For example, the screen becomes 624 × 1008 px, which is 13 × 21 = 273 soft tokens.
- **PNG vs JPEG.**
  - The PNG is lossless and lands at 1.000000.
  - The JPEG lands just below. Pillow (libjpeg-turbo) and DigUp's stb_image decode it slightly differently.
  - The app will decode with ImageIO, which differs again. DigUp's own indexer also re-encodes images through ImageIO before embedding them.
  - All of them pass the 0.999 bar.
- **Other request shapes.** A `prompt_string` with `multimodal_data` returns HTTP 500 "Failed to tokenize prompt", both on `/v1/embeddings` and on `/embeddings`. Use the OpenAI content parts.

## Image sizing is what makes the vectors match

Without the `--image-*-tokens` flags, llama.cpp sizes images itself:

- The screen takes 574 tokens and the photo 340, about twice DigUp's budgets.
- The vectors move to 0.99 and 0.97.

This is the sizing the [7 October](../2026-10-07/REPORT.md) and [13 October](../2026-10-13-screen-images/REPORT.md) runs measured. The first asked for the token budget to be tuned before relying on image vectors, and the second for the 280 budget to be tested before shipping.

Sizing on the client with the flags above fixes both:

- The token count is the budget's.
- The vectors are DigUp's, so DigUp's evals and its measured budget choices carry over.

## Cost under synthetic load, one input per request

Each server is a fresh process, and each peak covers the whole stage. Footprint is what Activity Monitor calls Memory. It leaves out clean file-backed pages, such as the mapped model, which RSS counts.

| | Text-only embedder (today) | Media embedder |
|---|---:|---:|
| Load until healthy | 0.75 s | 1.01 s |
| Idle footprint / RSS | 266 / 491 MiB | 873 / 1,101 MiB |
| Query, p50 / p95 | 6.0 / 12.0 ms | 5.1 / 9.6 ms |
| 32 texts of 1,500 characters per request, p50 | 442 ms | — |
| Screen at a 280 budget, p50 / p95 | — | 139 / 140 ms |
| Photo at 140, p50 / p95 | — | 76 / 77 ms |
| Video frame at 70, p50 / p95 | — | 44 / 52 ms |
| 8 frames in one request, per frame | — | 44 ms |
| 30 s of audio (754 tokens), p50 / p95 | — | 137 / 140 ms |
| Peak footprint / RSS | 321 / 500 MiB | 1,002 / 1,216 MiB |

What the numbers mean in use:

- **Screens.** The 13 October library captured about 490 screens a day. At a 280 budget, their image vectors take about 70 s of GPU time a day. That run measured 247 ms p50 per screenshot with llama.cpp's own sizing, so the budget cuts the cost by 44%.
- **Photos.** 10,000 photos at a 140 budget take about 13 minutes.
- **Video.** An hour of video takes about 72 s: a frame every 3 s (1,200 frames, before near-duplicates are dropped), plus a 30 s sound window every 25 s (144 windows).
- **Batching.** Sending 8 images in one request saves nothing. One input per request is fine. A typed query then waits behind at most one input from indexing, about 140 ms.
- **Queries.** Queries are no slower on the media server, but it holds about 600 MiB more while idle.
- **Not included.** Decoding and resizing on the client are not counted. DigUp reads the next file on another thread while the model embeds the current one.

On 7 October, the text-only embedder peaked at 1,289 MiB RSS under 32-text batches on b11474. Here it peaks at 500 MiB on v0.7.0. The inputs differ: the synthetic texts here are about 220 tokens each, against up to 955 tokens of real screen text. So this is not a like-for-like comparison. Every request here still filled the 2,048-token micro-batch. The next section gives a likely reason for the drop.

## DigUp's llama.cpp patch is not needed

DigUp builds llama.cpp b11461 with a one-line patch, `scripts/llama.cpp-no-logits.patch`. Without it, a non-causal embedding context reserves a row of 262,144 logits for every token, 1 MiB per token.

The patch does not apply to v0.7.0, because upstream changed the same line:

- `output_reserve` now sets `has_logits = !cparams.embeddings || graph_has_logits`.
- EmbeddingGemma 2's graph (`src/models/gemma-embedding2.cpp`) sets only `t_embd` and never produces logits.

So v0.7.0 already skips that buffer. That is a likely cause of the lower peak above, but this run does not isolate it.

## What this decides for the Files source

1. **A second embedder role, for media.**
   - It runs the embedder's arguments plus `--mmproj <pinned projector> --image-min-tokens 1 --image-max-tokens 1120`.
   - Only indexing passes lease it: files, and screen images if they are turned on. It unloads when idle.
   - Admission already counts the `--mmproj` file (`LlamaServer.estimatedResidentBytes`). The weights are 865 MB, and the measured peak RSS was 1,216 MiB.
   - Queries stay on the text-only embedder, at 266 MiB idle footprint. The two servers make identical text vectors, so a query vector scores media vectors directly.
2. **The app sizes images itself.**
   - Port DigUp's `ImageSizing`: the target size, and the resampler that matches Pillow.
   - Send each image as PNG.
   - Use DigUp's budgets: 280 for screenshots and PDF page images, 140 for photos, 70 for video frames.
3. **Audio goes as 30 s WAV windows** in `input_audio` parts. The model ignores anything past 30 s of one input. Following DigUp, a new window starts every 25 s.
4. **Every llama.cpp update must reproduce `reference/vectors.json`** at 0.999 or better. The Files work moves this check into the unit tests, skipped when the models are absent, as DigUp's `ReferenceVectorTests` is.
5. **The projector downloads only when needed:** when Files or image-based screen search is turned on. It is 554,821,024 bytes, with its SHA-256 pinned in `model-checksums.txt`.

## Limits

- **One machine, one run.** Each configuration ran once on an otherwise idle M4 Max. No app llama-server was running.
- **Synthetic load inputs.** The budget fixes an image's token count, and its cost follows from that, so the image timings should transfer. The text timings are not comparable with real screen text.
- **No retrieval quality.** This run does not measure how well search finds things. The gates for that come later:
  - DigUp's evals (`evals/synthetic.json`, `evals/multilingual.json`) for files;
  - a rerun of the 13 October screen benchmark at a 280 budget, for screens.
- **Reference is llama.cpp, not PyTorch.** Parity here is against DigUp's llama.cpp output. DigUp reports that its llama.cpp and mlx-vlm vectors agree at 0.999 or better. The 7 October run measured the app's text vectors against PyTorch at 0.9996 or better.

## Reproduce

```sh
R=/private/tmp/lokalbot-media-embedder-20261030   # delete afterwards
mkdir -p $R/models
curl -fsSL -o $R/models/mmproj-embeddinggemma-2-Q8_0.gguf \
  https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/bfcd298762cc34d0357ece5ebdd31791a3a374d8/mmproj-embeddinggemma-2-Q8_0.gguf
shasum -a 256 $R/models/*.gguf   # compare with model-checksums.txt
bash Scripts/fetch-llama.sh       # Vendor/llama-cpp at v0.7.0
cd Benchmarks/EmbeddingGemma2/2026-10-30-media-embedder
python3 parity.py       # exits 1 unless every vector reaches 0.999
python3 load_probe.py
rm -rf $R
```

This run used Python 3.13 with numpy 2.3.1, requests 2.32.5 and Pillow 11.3.0. The resize parity depends on Pillow's bicubic filter.

The text model is read from the app's models folder. `TEXT_MODEL`, `MMPROJ` and `LLAMA_SERVER` override the paths. In a worktree without `Vendor/`, point `LLAMA_SERVER` at the main checkout's build.

The results are in [results/parity.json](results/parity.json) and [results/load.json](results/load.json).
