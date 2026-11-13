**Favor Breeze for natural narration, based on the user's listening preference.** Breeze TTS 2 runs locally on this Mac, and the user finds it more natural and better sounding than Kokoro. Its higher memory use and generation time are tradeoffs to weigh against that quality preference. Kokoro remains useful when speed and a smaller memory footprint matter most. Commercial adoption of Breeze still requires a separate BreezeBlue license and app integration work.

On 10 September 2026, the user reported: "breeze is more natural and better sounding". This qualitative feedback fills the perceptual-quality gap in the initial automated evaluation and changes the recommendation for narration where naturalness is the priority. It records this user's preference; it is not a blinded listening study or a general preference score. The measurements below are from the original 9 September run.

This evaluation ran on 9 September 2026 on the user's Apple M4 Max with 48 GiB unified memory and macOS 27.0. It tested Breeze TTS 2 Q8_0 with audio.cpp v0.7.3 using Metal against the installed Kokoro 82M runtime and model, using the same subprocess arguments as LokalBot's current engine. The benchmark lives in this directory; production source, the installed app, preferences, and the meeting library were not changed.

| Measured result | Breeze TTS 2 Q8_0 | Installed Kokoro, Heart voice |
| --- | ---: | ---: |
| Short prompt: total generation time | 4.17 s warm | 2.07 s |
| Daily summary: total generation time | 11.86 s warm | 5.73 s |
| 255-word passage: total generation time | 63.12 s warm | 26.96 s |
| 255-word passage: generated audio duration | 92.08 s | 81.00 s |
| 255-word passage: generation time / audio duration | 0.685 | 0.333 |
| Peak process physical footprint in full run | 6.42 GiB | 0.81 GiB |
| Matched content check, after formatting normalization | 1 / 356 word discrepancies | 1 / 356 word discrepancies |

Breeze took 2.34 times as long to finish the long passage and used about 7.9 times the peak physical memory. Its slower speaking pace accounts for part of the total-time difference; even per second of output audio, generation took about twice as long. The Q8_0 download is 5,079,668,352 bytes (5.08 GB / 4.73 GiB). These results apply to this quantization and runtime, rather than every implementation of Breeze.

Breeze's benefit is earlier playback when its model is already loaded. Across seven warm requests, the first PCM chunk arrived in 0.836–1.119 s (median 0.878 s). Kokoro's current file-return interface waits for the complete waveform; for the daily summary that was 5.73 s. The two timing measures describe different events, so first-chunk latency should not be compared with Kokoro's total generation time as if they were throughput measurements.

There is also a buffering requirement. With the tested streaming settings, the first chunk contains only 0.32 s of speech. On the warm short request, it arrives at 0.849 s, and the next chunk arrives at 1.635 s. Starting immediately would exhaust that first chunk at 1.169 s, leaving a 0.467 s gap. The same calculation finds one initial underrun in every Breeze trace, requiring an additional 0.437–0.569 s of initial buffering in the warm cases. The earliest continuous start derived from those traces is **1.30–1.69 s**. This is an offline playback simulation, not an observed sound-device dropout or an inserted silence in the saved WAVs. An actual adapter needs a buffer policy and additional allowance for scheduling jitter.

The first request after starting a new lazy-load Breeze process took 10.35 s to its first audio chunk in the full run and 17.40 s in the earlier smoke run. Server startup through health readiness was outside request timing, and the OS page cache was not purged. These are two process-cold observations, not a cold-disk distribution. An optional integration would need to balance those waits against keeping roughly 5 GiB of physical footprint resident between requests. The official model card's 40 ms first-audio claim comes from a warmed NVIDIA H100 setup; it does not describe this Mac. [Official Breeze model card](https://huggingface.co/BreezeBlue/Breeze-TTS-2)

All eight full Breeze requests and two smoke requests completed successfully. The 255-word passage traversed three runtime text chunks and produced a complete 92-second file. Same-seed cold and warm short requests produced byte-identical WAVs; a second seed changed the waveform and duration. All 16 saved WAVs have valid mono 24 kHz PCM16 data, nonzero audio, and no clipped samples in the recorded measurements. This is a small functional pilot, without a reliability or latency-percentile claim.

The content check used local Qwen3-ASR-1.7B on MPS/BF16, with no reference transcript supplied to the recognizer. The matched aggregate uses one result per model for the short prompt, daily summary, neutral narration, and long passage: 356 words per model. Both scored 3/356 discrepancies before normalization and 1/356 afterward. The formatting adjustment treats `2:30` and `two thirty` as equivalent; percentage-symbol normalization is also applied symmetrically. No content words or names are corrected. Both long-file transcriptions rendered `next step` as `next steps`, which could be a shared ASR ambiguity. This metric checks transcript agreement and does not establish naturalness or a human-rated error rate.

The numeric case is reported separately to avoid scoring written/spoken formatting as pronunciation errors. Both ASR transcripts retained version 0.8.0, 14:30, September 9, 2026, 12.5%, 2,450 euros, API, PDF, GitHub, and Friday. Breeze's transcript spelled the product name `Localbot`; Kokoro's used `Local bot`. Those spellings do not establish an acoustic difference. The short, neutral, and directed passages transcribed without content discrepancies.

Reference-conditioned generation used an 8.27-second synthetic Kokoro Heart sample created from the fixture text. The neutral and directed Breeze cases used the same narration text and seed. The directed case requested slower, restrained suspense and used guidance 4 instead of 1: duration rose from 10.00 to 10.72 s, and generation time from 6.70 to 8.45 s. Because instruction and guidance changed together, that difference does not isolate instruction following. The user's follow-up favors Breeze's naturalness and overall sound; speaker similarity, emotion, and pronunciation have not received separate listening scores. The official model supports English and Chinese; this pilot covers English only. [Official model capabilities](https://huggingface.co/BreezeBlue/Breeze-TTS-2)

The following samples are synthetic and saved at their original generated level. They are not loudness-matched or blinded. For listening, compare intelligibility, rhythm, unwanted pauses, voice consistency, and whether the directed version follows the requested delivery. The WAVs are not committed: the Breeze license below restricts commercial use of its outputs, and `run_eval.py` writes them to `audio/` again. Their SHA-256 hashes are in [audio_sha256.json](results/audio_sha256.json).

| Passage | Breeze | Kokoro |
| --- | --- | --- |
| Short notification | `audio/breeze_short_warm.wav` | `audio/kokoro_short.wav` |
| Daily summary | `audio/breeze_digest_warm.wav` | `audio/kokoro_digest.wav` |
| Names and numbers | `audio/breeze_names_numbers_warm.wav` | `audio/kokoro_names_numbers.wav` |
| Neutral narration | `audio/breeze_neutral_warm.wav` | `audio/kokoro_neutral.wav` |
| Narration with suspense instruction | `audio/breeze_directed_warm.wav` | — |
| 255-word work summary | `audio/breeze_long_warm.wav` | `audio/kokoro_long.wav` |
| Synthetic reference supplied to Breeze | — | `audio/kokoro_reference.wav` |

The license checked during this run is the BreezeBlue Research and Non-Commercial License Agreement v1.1, dated 1 September 2026. It expressly accommodates limited internal evaluation, including by a for-profit entity. It requires a separate written commercial license for product/service use and commercial use of outputs, and has no small-business or revenue-threshold exception. Using a GGUF conversion or separately licensed runtime does not remove the model restrictions. Breeze is the preferred narration candidate from the user's listening feedback, with product adoption pending licensing and integration. [Breeze license, sections 1.7, 3, and 14.2](https://huggingface.co/BreezeBlue/Breeze-TTS-2/blob/ee9fc7c/LICENSE)

The test is reproducible from [cases.json](cases.json), [run_eval.py](run_eval.py), [check_content.py](check_content.py), and [summarize_results.py](summarize_results.py). Exact runtime/model revisions, verified download hashes, installed baseline hashes, hardware, and the cached ASR environment are recorded in [environment.json](environment.json). Raw request options and client event times are in [breeze.json](results/breeze.json); baseline results are in [kokoro.json](results/kokoro.json); transcripts are in [content.json](results/content.json). Derived metrics, WAV hashes, and validation are in [summary.json](results/summary.json), [audio_sha256.json](results/audio_sha256.json), and [validation.json](results/validation.json).

To recompute the saved scores and artifact checks, run from the repository root:

```sh
uv run --no-project --python 3.13 python Benchmarks/voice/Breeze/2026-09-09/summarize_results.py
```

To repeat inference on this machine, place the pinned GGUF and extracted arm64 Metal runtime in a scratch directory matching `environment.json`, with `runtime/audiocpp_server` executable. The benchmark uses a loopback-only server, shuts down its own process when complete, and expects the installed Kokoro files at the paths recorded in the environment. Run the baseline first to create the synthetic reference. These commands replace this pilot's local result files:

```sh
uv run --no-project --python 3.13 python Benchmarks/voice/Breeze/2026-09-09/run_eval.py baseline --scratch /private/tmp/lokalbot-breeze-eval.q3p6Ds
uv run --no-project --python 3.13 python Benchmarks/voice/Breeze/2026-09-09/run_eval.py breeze --scratch /private/tmp/lokalbot-breeze-eval.q3p6Ds --smoke
uv run --no-project --python 3.13 python Benchmarks/voice/Breeze/2026-09-09/run_eval.py breeze --scratch /private/tmp/lokalbot-breeze-eval.q3p6Ds
uv run --no-project /private/tmp/lokalbot-funasr-comparison-20260908/venv/bin/python Benchmarks/voice/Breeze/2026-09-09/check_content.py
uv run --no-project --python 3.13 python Benchmarks/voice/Breeze/2026-09-09/summarize_results.py
```

The Breeze server used Metal, four CPU threads, lazy loading, a single model, 600-character text chunks, seed 42 (plus one seed-43 repeat), max_tokens 1500, 16 stream frames per event, and a lookahead margin of 12. Kokoro used Heart/speaker 3, speed 1.0, two threads, and its installed English/Chinese lexicons. Runtime option semantics are documented in the pinned [audio.cpp Breeze implementation guide](https://github.com/0xShug0/audio.cpp/blob/9c6a282337cc83f227cc10428867a478947706ad/docs/models/breeze_tts.md).

Process memory comes from macOS `proc_pid_rusage` physical-footprint accounting, not RSS or summed CPU/GPU allocations. Breeze's peak is a high-water mark for the entire server process; Kokoro starts a process per case and was sampled every 50 ms. The measurements were sequential on a working Mac, without a controlled power or thermal profile. No local UI tests were run. Chinese, other voices, BF16, long sessions, interruption/cancellation, concurrent model load, energy use, app packaging, and sound-device playback remain outside this pilot. WAV files and the temporary 5 GB model download remain local; audio binaries are excluded from Git by the benchmark's `.gitignore`.
