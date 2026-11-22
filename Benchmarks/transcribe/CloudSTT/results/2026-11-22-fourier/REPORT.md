# Fourier 2B on the public AMI meeting windows

Oruk ran the original [Fourier 2B checkpoint](https://huggingface.co/oruk/oruk-fourier-2b/tree/8c2a8871f1304aa2f634da4fb95e24438c4945b9) on all 16 windows in this benchmark. The four English meetings contain 27.4 minutes of mixed-headset audio and 4,201 normalized reference words.

| Model | WER | 95% interval | Substitutions | Deletions | Insertions | Low-overlap WER |
|---|---:|---:|---:|---:|---:|---:|
| Fourier 2B, BF16 | 17.50% | 14.02%–20.31% | 123 | 600 | 12 | 5.91% |
| Qwen3-ASR 1.7B, MLX 8-bit (published) | 17.64% | 14.58%–20.54% | 159 | 534 | 48 | 7.14% |

The [published Qwen row](../2026-09-30/summary.json) uses the same windows and scorer. The two runs differ in model weights, numerical precision, runtime, and hardware. The intervals are bootstrapped over the 16 windows. The low-overlap subset has 4 windows and 728 reference words.

## Run details

- Ubuntu Linux x86-64, one NVIDIA A10G, CUDA 13.0, PyTorch 2.14.0, vLLM 0.34.0, Transformers 5.22.2. Container digest `sha256:cf5b2fdd087eb4f6d261736967cc5cde974bd22ff4df50365f8fa419b6b4c484`.
- Original BF16 weights, 4,076,193,080 bytes. Hub revision `8c2a8871f1304aa2f634da4fb95e24438c4945b9`, weight SHA-256 `e64765ffdd90c83704c0951e0d88b7f2ed84499af5c208f7ddf8d922cf08441c`. The model is available under CC BY-NC 4.0.
- English language hint, greedy decoding, one full WAV per request, no custom vocabulary or transcript cleanup. Input length was checked for every window using the released processor. The processor retained the full input for all 16 windows, with 9,055–11,921 valid mel frames each. Every generation reached its stop token before the 1,024-token output limit.
- Model load 63.91 s, excluded first-window warm-up 2.47 s. The 16 serial transcriptions took 83.98 s on the A10G. Median latency was 5.31 s per window. Prefix and multimodal input caches were disabled. The rented GPU's actual charge was not measured.
- The original [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/) supplied the audio and the [IHM test split](https://huggingface.co/datasets/edinburghcstr/ami) supplied the human transcripts, under CC BY 4.0. The four recordings are ES2004a, IS1009a, TS3003a, and EN2002a. See [counts and timings per window](summary.json). Audio, model weights and transcripts are excluded from this repository.

## Reproduce

Use the dependencies in the [harness instructions](../../README.md) and a shared `STT_BENCH_DATA` directory. Prepare and score with Transformers 4.57.6 and RapidFuzz 3.14.6. Transcribe in a separate CUDA/vLLM environment. These commands run only the public AMI set.

```sh
cd Benchmarks/transcribe/CloudSTT
export STT_BENCH_DATA=/tmp/lokalbot-public-ami
# Preparation environment with ffmpeg available
python prepare.py --meetings
# CUDA environment with the pinned vLLM image
python run_fourier.py
# Preparation/scoring environment
python score.py --systems local-oruk-fourier-2b --results /tmp/fourier-ami-score
```

Scoring uses the repository's frozen Whisper spelling map, word-level Levenshtein edits, and 2,000 window-bootstrap replicates. The stock local-cost column defaults to zero when no API is billed. It does not include hardware rental.
