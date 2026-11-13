# Cloud speech-to-text versus LokalBot's local ASR

This opt-in benchmark compares closed speech-to-text APIs from OpenAI, Google and Alibaba (Qwen) with LokalBot's local engines. Every system receives the same 16 kHz mono WAV chunks. Each vendor is called through its own API, not an aggregator.

| System | Access |
|---|---|
| `gpt-transcribe`, `gpt-4o-transcribe`, `gpt-4o-mini-transcribe` | OpenAI `/v1/audio/transcriptions` |
| `gemini-3.5-transcribe` | Gemini API Files + Interactions, verbatim mode |
| `gemini-3.8-flash` | Gemini API `generateContent`, verbatim-transcript prompt |
| `qwen-audio-3.1-asr-flash`, `qwen3-asr-flash` | Alibaba Model Studio (international), `asr_options.language` |
| `local-qwen3-asr-1.7b` | MLX 8-bit, the app's default transcription model (via mlx-audio, not the app's Swift runtime) |
| `local-parakeet-v3` | MLX Parakeet TDT 0.6B v3 |

Every system gets an English language hint. None of them receives custom vocabulary.

## Data

- **LokalBot meetings.** `prepare.py` reads meeting audio through `lokalbot-cli path`, which is read-only. It splits each track (mic and system) at voice-activity pauses into chunks of up to 120 seconds, and silences longer than 5 seconds are not sent. These meetings have no human reference. Each system is therefore scored against a *leave-family-out consensus*: a backbone ROVER vote over the systems from the other vendors, with each vendor family's votes summing to one. This measures agreement, not accuracy. It also exposes hallucinated spans (runs of four or more inserted words) and dropped speech (runs of deleted words).
- **Public AMI meetings.** This set gives true word-error rates. It uses Mix-Headset recordings from four AMI test meetings (ES2004a, IS1009a, TS3003a and EN2002a), cut into windows of 90–120 seconds that no reference utterance crosses. The references are the `edinburghcstr/ami` IHM test transcripts joined in time order. Overlapping talk is ordered by start time, so every system pays a small, shared ordering penalty.

References and hypotheses both pass through the Whisper English normalizer, using the spelling map pinned in `../ModelAlternatives/2026-09-07/`. The 95% intervals come from a chunk-level bootstrap.

## Running

```sh
export STT_BENCH_DATA=/private/tmp/lokalbot-cloud-stt   # private audio, outputs, transcripts
uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python \
  numpy torch silero-vad mlx-audio "transformers<5" rapidfuzz requests duckdb
.venv/bin/python prepare.py                 # meetings + AMI chunks, manifest.json
.venv/bin/python run_local.py               # serial local baselines
.venv/bin/python import_app.py              # LokalBot's saved transcripts, scored but never voting
.venv/bin/python run_api.py --limit 2       # smoke test each API
.venv/bin/python run_api.py                 # all API systems, 4 requests in flight each
.venv/bin/python score.py --results results/2026-09-30
```

The scorer compares systems only on chunks that every included system finished. It leaves out of a set's table any system that finished less than 90% of that set, which happens for example when a daily quota runs out. Rerunning `run_api.py` retries only chunks without text.

Provider notes:
- Gemini 3.5 Transcribe on Tier 1 allows 10 requests per minute and 100 per day. The runner paces it at 9 per minute.
- Qwen-Audio ASR models are served only by the native DashScope endpoint, with `parameters.format`. On near-silent clips they return HTTP 400 `ASR_RESPONSE_HAVE_NO_WORDS`, which is recorded as an empty transcript.
- OpenAI's authentication errors echo a masked key fragment; saved error records redact it.

Keys are read from `~/.config/lokalbot-stt-bench.env` (`OPENAI_API_KEY`, `GEMINI_API_KEY`, `DASHSCOPE_API_KEY`, and optionally `DASHSCOPE_BASE_URL`), or from the environment. Neither the keys nor raw audio are written to this repository. Outputs are resumable: a chunk with saved text is skipped unless `--force` is passed.

Uploading meeting audio sends other participants' voices to each vendor under that vendor's API data terms. Run the meeting set only with the owner's explicit agreement. Only content-free aggregates belong in `results/`. Transcripts, consensus strings and raw responses stay in `$STT_BENCH_DATA`.
