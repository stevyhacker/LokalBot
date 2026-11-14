# Qwen3-ASR 1.7B on llama.cpp vs MLX

This benchmark asks whether LokalBot's Qwen3-ASR 1.7B could run on the bundled llama.cpp server instead of speech-swift's MLX runtime without losing accuracy, speed, memory headroom, or the Serbian and vocabulary behaviour. It reuses the [QwenSpanLength](../QwenSpanLength/README.md) harness, so both backends hear the same decode windows, with the same language hint and context, and are scored by the same scripts.

- **MLX arm:** `aufklarer/Qwen3-ASR-1.7B-MLX-8bit` through speech-swift, built with the app's current pins: the `stevyhacker/speech-swift` fork at `33f42bc`, FluidAudio 0.17.7 and mlx-swift 0.32.3. `harness/Package.swift` pins them, and its sources are a symlink to the QwenSpanLength harness.
- **llama.cpp arm:** `ggml-org/Qwen3-ASR-1.7B-GGUF` at Q8_0, with its Q8_0 mmproj, on the llama-server the app ships (v0.9.0, build 12110, from `Scripts/build/fetch-llama.sh`), using `-ngl 99` on Metal.

With `ASR_BACKEND=llama`, the harness writes each window as a 16 kHz float WAV and posts it to llama-server's `/completion` with speech-swift's prompt, token for token:

```
<|im_start|>system\n{context}<|im_end|>\n<|im_start|>user\n<__media__><|im_end|>\n<|im_start|>assistant\nlanguage {code}<asr_text>
```

mtmd wraps the marker in `<|audio_start|>`/`<|audio_end|>`. Without a language, the prompt ends in a bare `<asr_text>`, as speech-swift's does. Decoding is greedy, with no penalties, and the same token cap applies to both arms. llama.cpp randomizes its media marker per process, so the server runs with `LLAMA_MEDIA_MARKER=<__media__>`.

llama-server's own `/v1/audio/transcriptions` is **not** used. In v0.9.0 it formats the prompt differently: a `language` field becomes ` (language: sr)` appended to a user instruction, a `prompt` replaces that instruction, and nothing goes in the system turn. The reply also keeps the model's `language Serbian<asr_text>` prefix. An app integration would need to send Qwen's own prompt layout, as this harness does.

## Running

```sh
export STT_BENCH_DATA=/private/tmp/lokalbot-cloud-stt
export SPAN_BENCH_OUT=$STT_BENCH_DATA/span-length
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python \
  numpy torch silero-vad duckdb rapidfuzz "transformers<5" requests

# Data: CloudSTT's AMI + meeting chunks, and the FLEURS tracks.
(cd ../CloudSTT && ../QwenLlamaCpp/.venv/bin/python prepare.py)
(cd ../QwenSpanLength && ../QwenLlamaCpp/.venv/bin/python fetch_fleurs.py)

# Weights: clone the app's MLX copy, and fetch the pinned GGUF revision.
mkdir -p $SPAN_BENCH_OUT/models/aufklarer $SPAN_BENCH_OUT/llama-models
cp -c -R ~/Library/Application\ Support/me.dotenv.LokalBot/qwen3-asr-models/models/aufklarer/Qwen3-ASR-1.7B-MLX-8bit \
  $SPAN_BENCH_OUT/models/aufklarer/
for f in Qwen3-ASR-1.7B-Q8_0.gguf mmproj-Qwen3-ASR-1.7B-Q8_0.gguf; do
  curl -fL -o $SPAN_BENCH_OUT/llama-models/$f \
    https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/$f
done
Scripts/build/fetch-llama.sh   # from the repo root, if Vendor/llama-cpp is missing

(cd harness && xcodebuild -scheme QwenBackendHarness -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath $SPAN_BENCH_OUT/dd -clonedSourcePackagesDirPath $SPAN_BENCH_OUT/spm \
  -skipPackagePluginValidation -skipMacroValidation build)

.venv/bin/python make_backend_jobs.py
./run_backend.sh mlx      # then, with nothing else heavy running:
./run_backend.sh llama    # starts and stops llama-server itself
.venv/bin/python score_backends.py --results results/2026-11-14
```

`run_backend.sh` runs the harness under `/usr/bin/time -l`, which records peak RSS and peak memory footprint. For llama.cpp it also samples the server's RSS every 0.5 s and reads `footprint`'s peak at the end. The server memory-maps the GGUF, and those file-backed pages count in RSS but not in the footprint, so both figures are reported.

Meeting audio and transcripts are read through `lokalbot-cli path`, which is read-only, and they stay in `SPAN_BENCH_OUT`. Nothing is sent over the network except the localhost requests to llama-server. `results/` holds aggregates only.
