# Closed speech-to-text APIs versus LokalBot's local ASR — 30 September 2026

No closed API measurably beat LokalBot's default local model on the owner's meetings. On the public AMI meeting set, Gemini 3.8 Flash led by about one point, but that margin is within the error of a 27-minute test, and the same model invented speech on short, quiet clips. Among dedicated STT APIs, Gemini 3.5 Transcribe and Qwen-Audio 3.1 ASR Flash tied the local Qwen3-ASR 1.7B on meeting agreement. The OpenAI models trailed on both sets: they dropped overlapped speech on AMI, and GPT-4o Transcribe skipped much of the user's own microphone speech. No app defaults or runtime code changed.

**Systems.** Every system received the same 16 kHz mono WAV chunks with an English language hint and no custom vocabulary. The APIs were called directly, without an aggregator:

- **OpenAI:** `gpt-transcribe`, `gpt-4o-transcribe` and `gpt-4o-mini-transcribe`, via `/v1/audio/transcriptions`.
- **Google:** `gemini-3.5-transcribe` (Interactions API, verbatim mode), and `gemini-3.8-flash` prompted for a verbatim transcript.
- **Alibaba Model Studio (international):** `qwen-audio-3.1-asr-flash` (native API) and `qwen3-asr-flash` (OpenAI-compatible mode).
- **Local, run serially on an Apple M4 Max with 48 GiB (MLX 0.32.3, mlx-audio 0.5.7):** Qwen3-ASR 1.7B 8-bit, which is LokalBot's selected transcription model, and Parakeet TDT 0.6B v3.

**Public AMI meetings with a human reference**

The set has 16 windows of 90–120 seconds from the Mix-Headset recordings of four AMI test meetings: 27.4 minutes and 4,160 reference words. Windows start and end where no reference utterance crosses the cut. Most windows contain heavy overlapped talk, and a single mixed channel cannot carry two simultaneous speakers, so deletions dominate every system's errors. Absolute WER here is therefore higher than on published close-talk AMI results. The low-overlap column is a secondary subset: the 4 windows where under 30% of reference words overlap another utterance (728 words). It is too small to rank systems on.

| System | WER | 95% CI | Deletions | Insertions | Low-overlap WER | List price / audio hour | Speed |
|---|---:|---:|---:|---:|---:|---:|---:|
| Gemini 3.8 Flash, prompted | **16.7%** | 14.0–19.0% | 10.1% | 1.9% | 6.2% | $0.21 | 18× |
| Qwen3-ASR 1.7B, local | 17.6% | 14.6–20.5% | 12.7% | 1.1% | 7.1% | — | 44× |
| Qwen3-ASR Flash | 18.1% | 14.6–20.8% | 14.5% | 0.5% | 6.3% | $0.13 | 25× |
| Qwen-Audio 3.1 ASR Flash | 18.5% | 14.6–21.8% | 9.7% | 4.0% | 5.6% | $0.02 | 10× |
| Parakeet TDT 0.6B v3, local | 19.2% | 15.8–22.3% | 14.0% | 1.2% | 8.1% | — | 129× |
| GPT-4o mini Transcribe | 21.8% | 17.5–25.7% | 16.8% | 1.0% | 7.8% | $0.18 | 34× |
| GPT Transcribe | 22.2% | 17.6–27.5% | 17.9% | 0.8% | 6.9% | $0.27 | 30× |
| GPT-4o Transcribe | 23.0% | 18.4–27.0% | 19.8% | 0.5% | 6.2% | $0.36 | 25× |

Gemini 3.8 Flash had lower WER than the local Qwen model in 93% of paired chunk-bootstrap samples. The OpenAI models' deficit comes almost entirely from deletions of overlapped crosstalk and backchannels. Qwen-Audio 3.1 recovered more overlapped words than the other Qwen variants but inserted 79 words in runs of four or more.

Gemini 3.5 Transcribe is not in this table. The Gemini API's Tier 1 limits for it are 10 requests per minute and 100 per day. The daily quota ran out after 2 of the 16 AMI windows (with 101 of 122 chunks finished overall), so ranking it here requires rerunning the remaining windows after the quota resets.

**The owner's LokalBot meetings: agreement, not ground truth**

This set covers the three most recent meetings with audio, from 26–30 September. Mic and system tracks were cut at speech pauses into 106 chunks, and silences longer than 5 seconds were not sent. The table scores the 99 chunks (69.9 minutes) that every system completed. These meetings have no human reference. Each system is therefore compared with a consensus built only from the *other* vendor families: a backbone ROVER vote in which each family's votes sum to one. A low number means agreement with independent systems. It is not proof of accuracy, and a system that alone gets a hard word right is penalized. "Invented" counts inserted words in runs of four or more; "Dropped" counts deleted words in runs of four or more.

| System | Disagreement | 95% CI | Invented | Dropped | List price / audio hour | Median latency |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3-ASR 1.7B, local | **4.2%** | 3.4–5.1% | 23 | 0 | — | 0.4 s |
| Gemini 3.5 Transcribe | 4.5% | 3.6–5.5% | 21 | 11 | $0.30 | 6.3 s |
| Qwen-Audio 3.1 ASR Flash | 4.6% | 3.8–5.5% | 21 | 11 | $0.01 | 2.9 s |
| Qwen3-ASR Flash | 5.3% | 4.4–6.2% | 26 | 12 | $0.13 | 1.3 s |
| GPT Transcribe | 5.9% | 5.0–6.8% | 9 | 37 | $0.27 | 1.2 s |
| GPT-4o mini Transcribe | 6.2% | 5.2–7.3% | 14 | 23 | $0.18 | 1.4 s |
| Parakeet TDT 0.6B v3, local | 6.2% | 5.0–7.7% | 16 | 83 | — | 0.2 s |
| Gemini 3.8 Flash, prompted | 7.2% | 6.0–8.8% | 115 | 0 | $0.33 | 3.6 s |
| LokalBot app transcript | 7.9% | 6.4–9.6% | 52 | 9 | — | — |
| GPT-4o Transcribe | 10.0% | 8.4–12.0% | 0 | 278 | $0.36 | 1.3 s |

The top three are close: Gemini 3.5 Transcribe and Qwen-Audio 3.1 beat the local model in 14% and 10% of bootstrap samples, respectively. Two failure modes are clear:

- **Gemini 3.8 Flash invents speech.** It produced 115 words in 15 invented spans spread across 15 chunks. For example, it turned a 1.2-second clip, which the other systems heard as one word or silence, into a fluent 30-word sentence. A general multimodal model prompted to transcribe is unsafe for short or quiet segments without extra guarding.
- **GPT-4o Transcribe drops the user's own speech.** Its disagreement on the 28 September microphone track was 42%; the other API and local models were at 7–14%. Only about 20% of the dropped content words also appear on the system track at the same moment, so this is mostly skipped speech, not echo suppression. `gpt-transcribe` supersedes it with far fewer dropped runs.

Qwen-Audio 3.1 returns an HTTP 400 `ASR_RESPONSE_HAVE_NO_WORDS` error instead of an empty transcript for clips with little speech. It did this for 18 chunks, mostly 1–2 seconds long. These are scored as empty output, and some of them held a few words that other systems heard.

**Follow-up for the app**

LokalBot's saved production transcript disagrees more than the same Qwen3-ASR 1.7B model run on the benchmark chunks: 7.9% versus 4.2%. Its substitution rate is double (3.6% versus 1.8%), and the substitutions are spread across many different words. The known-name vocabulary had a single term for these meetings, so it does not explain the gap. One difference is that `QwenASREngine` transcribes speech spans of at most 15 seconds, while the benchmark gives the model up to 120 seconds of context. The app also uses a different weights repository and runtime (speech-swift, not mlx-audio), and its segments were assigned to benchmark chunks by midpoint. A controlled span-length test on the same runtime is needed before changing anything.

**Cost and context**

The recorded API spend for the run was about $2.45 at list prices. Qwen-Audio 3.1 is by far the cheapest API at about $0.01–0.02 per audio hour. Speed is audio seconds per second of request latency, with four requests in flight per API. API latency includes upload from the owner's network. These results agree with the direction of [Artificial Analysis's STT leaderboard](https://artificialanalysis.ai/speech-to-text/non-streaming), which also ranks Gemini 3.5 Transcribe above GPT Transcribe. That leaderboard does not test two-track meeting audio or local Qwen3-ASR. Alibaba's Fun-ASR realtime preview, which leads that leaderboard, is a streaming WebSocket API and was not tested.

**Reproduction and privacy**

`../../README.md` describes the harness. `summary.json` holds only aggregates. Meeting audio, transcripts, consensus strings and raw responses stay in the private `STT_BENCH_DATA` folder. The source baseline is `de3a550`. Uploading the meeting audio sent other participants' voices to OpenAI, Google and Alibaba under their API terms, with the owner's approval.
