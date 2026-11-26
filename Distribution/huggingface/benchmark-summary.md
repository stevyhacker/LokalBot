# LokalBot: Local Desktop AI Leaderboard (synced benchmark summary)

Updated **2026-11-26**. Generated from `Website/public/benchmarks.json`. Every number comes verbatim from a checked-in report under `Benchmarks/README.md` or a verified Apache-2.0 Hugging Face model card. Nothing here is estimated or invented.

- **Interactive sortable leaderboard:** https://www.lokalbot.com/benchmarks
- **Machine-readable JSON:** https://www.lokalbot.com/benchmarks.json
- **Full harnesses & raw outputs:** `Benchmarks/README.md`
- **Hardware scope:** Primary desktop runs on Apple M4 Max (48 GB unified memory); Linux CPU memory/extraction runs on AMD Ryzen 7 9700X (64 GB); v0.14.0 Qwen3.5 4B replay on NVIDIA RTX PRO 6000 Blackwell (pinned llama.cpp v1.0.0); experimental MemT run on Windows + RX 6600 XT.

## v0.14.0 local reference stack (~9.7 GB total)

| Role | Default model | Format | Size (GB) | Headline result | Interactive view |
| --- | --- | --- | ---: | --- | --- |
| Transcription | **Qwen3-ASR 1.7B (LokalBot v3)** | GGUF Q8_0 + mmproj (llama.cpp) | 2.52 | 9.79% AMI ihm · 100% clean silence | [View suite](https://www.lokalbot.com/benchmarks#stt-lokalbot-v3) |
| Speaker Diarization | **Nemotron 3** | Core ML (FluidAudio) | 0.20 | 14.56% DER · 500x RT | [View suite](https://www.lokalbot.com/benchmarks#diarization-ami) |
| Hybrid Search | **EmbeddingGemma 2** | GGUF Q8_0 + SQLite FTS5 | 0.31 | 39 ms p50 · 50 MB RAM | [View suite](https://www.lokalbot.com/benchmarks#retrieval-qmsum) |
| Inline Autocomplete | **Gemma 4 E2B (LokalBot v4)** | GGUF i1-Q6_K (llama.cpp) | 3.85 | 56/56 grounded · 52.2% precision | [View suite](https://www.lokalbot.com/benchmarks#autocomplete-lokalbot-v4) |
| Summaries & Memory | **Qwen3.5 4B (LokalBot v4)** | GGUF Q4_K_M (llama.cpp) | 2.74 | 118/120 memory · 1.78x faster | [View suite](https://www.lokalbot.com/benchmarks#summaries-lokalbot-v4) |
| Screen OCR & Voice | **Apple Vision + Kokoro 82M** | macOS native + local TTS | 0.10 | 0.971 F1 · 119.6 ms OCR | [View suite](https://www.lokalbot.com/benchmarks#ocr-synthetic) |

## v0.14.0 Apache-2.0 Fine-Tuned Models

| Role | Model | Hugging Face repo | Format | Size (GB) | License | Headline result |
| --- | --- | --- | --- | ---: | --- | --- |
| Transcription (Default) | **Qwen3-ASR 1.7B (LokalBot v3)** | [`stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF) | GGUF Q8_0 + mmproj | 2.52 | Apache-2.0 | 9.79% AMI ihm · 24.41% sdm · 100% clean silence · -24.3 pp code-switch |
| Transcription (Compact) | **Qwen3-ASR 0.6B (LokalBot v1)** | [`stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3-ASR-0.6B-LokalBot-GGUF) | GGUF Q8_0 + stock mmproj | 1.02 | Apache-2.0 | 10.72% AMI ihm · -21.7 pp South Slavic WER · 52.7x RT · 100% clean silence |
| Summaries, Memory & Ask | **Qwen3.5 4B (LokalBot v4)** | [`stevyhacker/Qwen3.5-4B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3.5-4B-LokalBot-GGUF) | GGUF Q4_K_M | 2.74 | Apache-2.0 | 118/120 memory (1 unw.) · 45% Blind21 decisions · 60.6% fewer rejections · 1.78x faster |
| Inline Autocomplete | **Gemma 4 E2B (LokalBot v4)** | [`stevyhacker/Gemma-4-E2B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Gemma-4-E2B-LokalBot-GGUF) | GGUF i1-Q6_K | 3.85 | Apache-2.0 | 56/56 memory+visible · 52.2% precision · 80.0% email prec · 20.2 ms boundary |

## Speech-to-Text (Meetings, Multilingual & Live)

Local ASR models measured head-to-head against OpenAI, Google, and Alibaba cloud STT APIs on overlapped AMI meetings, real two-track calls, multilingual FLEURS clips, and turn-by-turn live latency.

### AMI Meetings: Local ASR vs. Closed Cloud APIs

**Run date:** 2026-09-30 · **Hardware:** Apple M4 Max (48 GB) · MLX 0.32.3 / mlx-audio 0.5.7 · direct cloud APIs  
**Dataset:** 16 windows (90–120 s) from 4 AMI Mix-Headset test meetings · 27.4 min · 4,160 reference words  
**Source:** `Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#stt-ami-cloud)

| Model | Status | Runtime / Quant | AMI WER ↓ | 95% CI | Low-overlap ↓ | Speed ↑ | Price / hr ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Gemini 3.8 Flash (prompted) | Cloud API | Cloud API · Hosted | 16.7% | 14.0–19.0% | 6.2% | 18× | $0.21 |
| **Qwen3-ASR 1.7B** | Default | MLX 8-bit · 8-bit · 2.47 GB | 17.6% | 14.6–20.5% | 7.1% | 44× | $0 |
| Qwen3-ASR Flash | Cloud API | Cloud API · Hosted | 18.1% | 14.6–20.8% | 6.3% | 25× | $0.13 |
| Qwen-Audio 3.1 ASR Flash | Cloud API | Cloud API · Hosted | 18.5% | 14.6–21.8% | 5.6% | 10× | $0.02 |
| Parakeet TDT 0.6B v3 | Local option | MLX / Core ML · 0.63 GB | 19.2% | 15.8–22.3% | 8.1% | 129× | $0 |
| GPT-4o mini Transcribe | Cloud API | Cloud API · Hosted | 21.8% | 17.5–25.7% | 7.8% | 34× | $0.18 |
| GPT Transcribe | Cloud API | Cloud API · Hosted | 22.2% | 17.6–27.5% | 6.9% | 30× | $0.27 |
| GPT-4o Transcribe | Cloud API | Cloud API · Hosted | 23.0% | 18.4–27.0% | 6.2% | 25× | $0.36 |

- **Notes:** Heavy overlapped crosstalk on a single mixed channel makes deletions dominate every system's WER. Local models run serially with zero upload; API speed includes network upload with 4 requests in flight.
- **Caveat:** Gemini 3.8 Flash edged Qwen3-ASR 1.7B by 0.9 pts on AMI (within CI), but invented 115 words across 15 spans on real quiet meeting chunks (see Real 2-Track Meetings suite).

### Real Two-Track Meetings: Consensus Disagreement & Hallucinations

**Run date:** 2026-09-30 · **Hardware:** Apple M4 Max (48 GB) · MLX local vs direct cloud APIs  
**Dataset:** 3 real two-track meetings · 99 shared chunks · 69.9 min (no human reference; scored via leave-one-family-out ROVER vote)  
**Source:** `Benchmarks/transcribe/CloudSTT/results/2026-09-30/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#stt-meetings-agreement)

| Model | Status | Runtime / Quant | Disagreement ↓ | Invented words ↓ | Dropped words ↓ | Median latency ↓ | Price / hr ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Qwen3-ASR 1.7B** | Default | MLX 8-bit · 2.47 GB | 4.2% (CI 3.4–5.1%) | 23 | 0 | 0.4 s | $0 |
| Gemini 3.5 Transcribe | Cloud API | Cloud API · Hosted | 4.5% (CI 3.6–5.5%) | 21 | 11 | 6.3 s | $0.30 |
| Qwen-Audio 3.1 ASR Flash | Cloud API | Cloud API · Hosted | 4.6% (CI 3.8–5.5%) | 21 | 11 | 2.9 s | $0.01 |
| Qwen3-ASR Flash | Cloud API | Cloud API · Hosted | 5.3% (CI 4.4–6.2%) | 26 | 12 | 1.3 s | $0.13 |
| GPT Transcribe | Cloud API | Cloud API · Hosted | 5.9% (CI 5.0–6.8%) | 9 | 37 | 1.2 s | $0.27 |
| GPT-4o mini Transcribe | Cloud API | Cloud API · Hosted | 6.2% (CI 5.2–7.3%) | 14 | 23 | 1.4 s | $0.18 |
| Parakeet TDT 0.6B v3 | Local option | MLX / Core ML · 0.63 GB | 6.2% (CI 5.0–7.7%) | 16 | 83 | 0.2 s | $0 |
| Gemini 3.8 Flash (prompted) | Cloud API | Cloud API · Hosted | 7.2% (CI 6.0–8.8%) | 115 | 0 | 3.6 s | $0.33 |
| GPT-4o Transcribe | Cloud API | Cloud API · Hosted | 10.0% (CI 8.4–12.0%) | 0 | 278 | 1.3 s | $0.36 |

- **Notes:** Measures agreement with independent vendor families, not ground-truth WER. Invented = inserted runs ≥ 4 words; Dropped = deleted runs ≥ 4 words.
- **Caveat:** Reveals failure modes invisible in clean benchmarks: Gemini 3.8 Flash invented 115 words on short/quiet chunks, and GPT-4o Transcribe dropped 278 words on the microphone track.

### Qwen3-ASR 1.7B Runtime Parity: llama.cpp v1.0.0 vs. MLX

**Run date:** 2026-11-14 · **Hardware:** Apple M4 Max (48 GB) · macOS 27.2.1 · identical Silero VAD windows  
**Dataset:** 11 conditions · 6.6 hours of audio (AMI, owner meetings, German/Japanese/Russian/Serbian FLEURS)  
**Source:** `Benchmarks/transcribe/QwenLlamaCpp/results/2026-11-14-llama-v1/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#stt-llamacpp-vs-mlx)

| Model | Status | Runtime / Quant | AMI WER ↓ | German FLEURS ↓ | Serbian + vocab ↓ | EN Speed ↑ | Peak Footprint ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Qwen3-ASR 1.7B (llama.cpp v1.0.0)** | Default | llama-server b12359 · Q8_0 + mmproj Q8_0 | 17.76% | 3.9% | 12.4% | 42.2× | 2.35 GB |
| Qwen3-ASR 1.7B (MLX) | Baseline | MLX 0.32.3 · 8-bit MLX | 17.80% | 4.5% | 13.4% | 47.2× | 7.60 GB (3.86 GB MLX alloc) |

- **Notes:** Compares ggml-org/Qwen3-ASR-1.7B-GGUF Q8_0 on llama.cpp v1.0.0 (b12359) against aufklarer/Qwen3-ASR-1.7B-MLX-8bit on speech-swift 0.0.29.
- **Caveat:** llama.cpp matched or slightly beat MLX on accuracy while cutting peak memory footprint from 7.6 GB to 2.35 GB, at 8–13% slower throughput.

### Small Local Speech Engines & Multilingual FLEURS

**Run date:** 2026-10-09 · **Hardware:** Apple M4 Max (48 GB) · network blocked by macOS  
**Dataset:** 44 human-transcribed English clips (24 AMI IHM + 20 FLEURS, 810 words) + 8-clip German/French/Polish FLEURS probes  
**Source:** `Benchmarks/transcribe/WhistleComparison/results/2026-10-09/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#stt-small-engines)

| Model | Status | Runtime / Quant | English WER ↓ | German WER ↓ | Median clip ↓ | Throughput ↑ | Download ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Qwen3-ASR 1.7B** | Default | speech-swift / MLX · 8-bit | 7.65% | 2.20% | 157.0 ms | 40.4× | 2.47 GB |
| Parakeet Ultra 0.6B | Local option | FluidAudio 0.17.5 Core ML · Core ML | 8.89% | 1.65% | 48.0 ms | 135.6× | 632 MB |
| Whistle (native C++) | Not adopted | C API · 16.9 MB | 20.25% | 19.78% | 31.7 ms | 200.2× | 16.9 MB |

- **Notes:** Bounded evaluation testing whether a 17 MB ultra-small C++ engine (Whistle) could rival Parakeet Ultra or Qwen3-ASR 1.7B.
- **Caveat:** German/French/Polish subsets have 8 clips each (~140–227 words); treat as directional rather than population rankings.

### Turn-by-Turn Live Transcript Latency (Two-Track Call)

**Run date:** 2026-11-10 · **Hardware:** Apple M4 Max (48 GB) · macOS 27.2 · Release build  
**Dataset:** Scripted two-track English call (25 speaker hand-overs); turn closed at speech pause via Silero VAD  
**Source:** `Benchmarks/transcribe/LiveTurns/results/2026-11-10/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#stt-live-turns)

| Model | Status | Runtime / Quant | Turn median ↓ | Turn worst ↓ | Old window median | Turn WER ↓ | Decode only ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Granite Speech 5 fast | Local option | Core ML / fast EN · English-only | 0.48 s | 0.79 s | 1.74 s | 11.2% | 0.02 s |
| Parakeet TDT 0.6B v3 | Local option | FluidAudio Core ML · 0.63 GB | 0.50 s | 0.81 s | 1.86 s | 3.4% | 0.04 s |
| Parakeet Ultra 0.6B | Local option | FluidAudio Core ML · 0.63 GB | 0.50 s | 0.81 s | 2.23 s | 4.7% | 0.04 s |
| **Qwen3-ASR 1.7B** | Default | MLX 8-bit · 2.47 GB | 0.64 s | 0.86 s | 1.89 s | 2.9% | 0.15 s |
| Whisper large-v3 turbo | Local option | WhisperKit 1.1.1 · 1.6 GB | 1.32 s | 1.52 s | 3.22 s | 5.8% | 0.81 s |

- **Notes:** Times measure end-of-word to displayed text. Cutting tracks at pauses cut both latency and word errors versus fixed 4–12 s preview windows.
- **Caveat:** Synthetic voices on a scripted call without crosstalk; real meetings have pauses mid-sentence. Muse Voice Transcribe (cloud) measured 0.74 s median on separate AMI audio.

### v0.14.0 Apache-2.0 ASR Fine-Tunes: Qwen3-ASR 1.7B v3 & 0.6B v1 vs. Stock Q8_0

**Run date:** 2026-11-24 · **Hardware:** Apple M4 Max (48 GB) · LokalBot vendored llama-server v1.0.0 · greedy decoding  
**Dataset:** Disjoint Blind Holdout (466 clips) + Expanded AMI Meetings (400 clips: 200 ihm + 200 sdm)  
**Source:** [HF model card: `stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3-ASR-1.7B-LokalBot-GGUF) · [Interactive table](https://www.lokalbot.com/benchmarks#stt-lokalbot-v3)

| Model | Status | Runtime / Quant | AMI ihm (200) ↓ | AMI sdm (200) ↓ | Code-Switch ↓ | Clean Silence ↑ | Speed (RTF) ↑ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Qwen3-ASR 1.7B (LokalBot v3)** | Default | llama-server v1.0.0 · Q8_0 + v3 mmproj · 2.52 GB | 9.79% (-0.45 pp) | 24.41% (-1.67 pp) | 12.81% (-24.31 pp) | 100.0% (0 halluc.) | 31.69x |
| Qwen3-ASR 1.7B (Stock Q8_0) | Baseline | llama-server v1.0.0 · Q8_0 + mmproj · 2.52 GB | 10.24% | 26.08% | 37.12% | 8.3% (123 halluc. w) | 31.34x |
| Qwen3-ASR 0.6B (LokalBot v1) | Local option | llama-server v1.0.0 · Q8_0 + stock mmproj · 1.02 GB | 10.72% (-0.15 pp) | 26.23% (-0.34 pp) | 20.72% (-28.49 pp) | 100.0% (0 halluc.) | 52.72x |
| Qwen3-ASR 0.6B (Stock Q8_0) | Baseline | llama-server v1.0.0 · Q8_0 + mmproj · 1.02 GB | 10.87% | 26.57% | 49.21% | 100.0% | 39.67x |

- **Notes:** Head-to-head evals published on the Apache-2.0 Hugging Face model cards using LokalBot's production /completion prompt format and 100% open-license CC0/CC-BY-4.0 training data.
- **Caveat:** v3 requires its paired mmproj-Qwen3-ASR-1.7B-LokalBot-v3-Q8_0.gguf (355.7 MB) and abstains on 2/200 very noisy far-field AMI sdm clips while lowering overall sdm WER by 1.67 pp. Guard languages stay within +0.18 pp of stock.

## Speaker Diarization (Who Spoke When)

Four independent English AMI meetings scored both as headset mixes and distant-microphone rooms (8 conditions, 184.55 minutes, 4 speakers each), with overlap scored and no speaker-count hints.

### AMI Speaker Diarization: Local Core ML vs. Pyannote & Cloud API

**Run date:** 2026-09-23 · **Hardware:** Apple M4 Max (48 GB) · FluidAudio Core ML · Meta cloud API tested 2026-10-27  
**Dataset:** 4 English AMI test meetings × 2 mic conditions = 8 recordings · 184.55 min · 4 speakers · overlap scored  
**Source:** `Benchmarks/transcribe/NemotronDiarization/results/2026-09-23/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#diarization-ami)

| Model | Status | Runtime / Quant | DER (0 ms collar) ↓ | DER (250 ms) ↓ | Speaker count ↑ | Speed ↑ | Peak RSS ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| Nemotron 3 fast128 | Local option | Core ML (FluidAudio) · Full precision | 14.51% | 8.19% | 8/8 | 365× | 0.64 GiB |
| **Nemotron 3 offline** | Default | Core ML (FluidAudio) · Full precision · ~0.20 GB | 14.56% | 8.34% | 8/8 | 500× | 0.67 GiB |
| Nemotron 3 c128 W8A8 | Local option | Core ML (CPU/ANE) · W8A8 | 15.73% | 9.34% | 7/8 | 480× | 0.63 GiB |
| Pyannote Community-1 | Local option | Core ML (FluidAudio) · Previous default | 43.44% | 30.45% | 5/8 | 243× | 0.68 GiB |
| Muse Voice Transcribe 1.0 | Cloud API | Cloud realtime API · Hosted ($0.36/hr) | 60.4% (21.7% ref-cut) | — | 5/8 | Live (0.74 s) | Cloud |

- **Notes:** Diarization Error Rate (DER) = missed speech + false alarms + speaker confusion. Speed is warm median on the 17.49-min ES2004a headset recording.
- **Caveat:** Pyannote baseline is the pinned FluidAudio port, not every Pyannote setup. Muse cloud DER (60.4%) includes pauses kept inside turns; cut to reference speech it scored 21.7% vs 11.8% for Nemotron offline.

## Personal Memory Extraction: Recall vs. Restraint

A personal memory writer has two jobs: save durable user facts with valid citations, and return nothing on noise, temporary tasks, third-party gossip, or sensitive exclusions. Most benchmarks only test the first.

### Recall vs. Restraint — 96 Frozen English Cases (48 Paired Toggles)

**Run date:** 2026-10-25 · **Hardware:** Ryzen 7 9700X Ubuntu CPU (llama.cpp) · MemT on Windows RX 6600 XT (experimental NF4 offload)  
**Dataset:** 96 frozen English cases (52 eligible memories, 44 empty cases) · identical prompt, JSON schema, greedy seed 0  
**Source:** `Benchmarks/think/MemoryRetention/2026-10-23/memt-nano/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#memory-english)

| Model | Status | Runtime / Quant | Useful recall ↑ | Unwanted ↓ | Empty correct ↑ | Full contract ↑ |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| MemT-1.0-Nano | Experimental | Transformers NF4 offload · Exp. NF4 experts / BF16 dense | 98.1% (51/52) | 6 | 88.6% (39/44) | 89/96 |
| Qwen3.5 9B | Local option | llama.cpp · Q4_K_M | 71.2% (37/52) | 5 | 90.9% (40/44) | 77/96 |
| **Qwen3.5 4B** | Default | llama.cpp · Q4_K_M · 2.74 GB | 57.7% (30/52) | 3 | 95.5% (42/44) | 72/96 |
| LFM2.5 24B-A2B | Not adopted | llama.cpp · QAD Q4_0 | 76.9% (40/52) | 53 | 22.7% (10/44) | 44/96 |
| Hy-Memory 30B-A3B | Not adopted | llama.cpp · Official Q4_K_M | 100.0% (52/52) | 76 | 0.0% (0/44) | 32/96 |

- **Notes:** Recall requires both accurate content AND the exact source-line citation. Always returning empty scores 44/44 empty and 0/52 recall; saving everything scores 52/52 recall and 0/44 empty.
- **Caveat:** MemT-1.0-Nano ran under experimental NF4 expert offload on Transformers (different hardware/precision than GGUF arms) and statelessly, so its latent persistent-memory branch was not exercised. Cases and semantic review were assistant-authored.

### Exploratory Serbian Slice — 24 Frozen Cases (Latin & Cyrillic)

**Run date:** 2026-10-25 · **Hardware:** Ryzen 7 9700X Ubuntu CPU (llama.cpp) · MemT on Windows RX 6600 XT  
**Dataset:** 24 frozen Serbian cases (13 eligible memories, 11 empty cases; 12 Latin, 12 Cyrillic)  
**Source:** `Benchmarks/think/MemoryRetention/2026-10-23/memt-nano/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#memory-serbian)

| Model | Status | Runtime / Quant | Useful recall ↑ | Unwanted ↓ | Empty correct ↑ | Full contract ↑ |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| MemT-1.0-Nano | Experimental | Transformers NF4 offload · Exp. NF4 / BF16 | 100.0% (13/13) | 3 | 72.7% (8/11) | 19/24 |
| Qwen3.5 9B | Local option | llama.cpp · Q4_K_M | 92.3% (12/13) | 2 | 81.8% (9/11) | 9/24 |
| **Qwen3.5 4B** | Default | llama.cpp · Q4_K_M · 2.74 GB | 61.5% (8/13) | 2 | 90.9% (10/11) | 10/24 |
| Hy-Memory 30B-A3B | Not adopted | llama.cpp · Official Q4_K_M | 100.0% (13/13) | 25 | 0.0% (0/11) | 4/24 |
| LFM2.5 24B-A2B | Not adopted | llama.cpp · QAD Q4_0 | 61.5% (8/13) | 37 | 0.0% (0/11) | 3/24 |

- **Notes:** Checks recall, restraint, and whether models preserve original language and script without silently translating to English.
- **Caveat:** Exploratory slice only. Hy-Memory advertises English and Chinese coverage; 3 of MemT's Serbian outputs switched language or script.

## System-Wide Local Autocomplete (Inline Cotyping)

Headless engine benchmarks measuring per-keystroke latency, safety, confidence-gated precision across 788 word boundaries, and first-suggestion recovery after a 5-minute pause.

### Production Autocomplete Engine: Gemma 4 E2B vs. LFM2.5 1.2B

**Run date:** 2026-10-15 · **Hardware:** Apple M4 Max (48 GB) · Release build · in-process llama.cpp  
**Dataset:** 140 safety checks (28 scenarios × 5 passes) + 788 word positions in 96 synthetic phrases across 6 languages  
**Source:** `Benchmarks/autocomplete/Cotyping/results/2026-10-15-engine-benchmark/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#autocomplete-engine)

| Model | Status | Runtime / Quant | Right when shown ↑ | Next-word acc ↑ | Non-EN acc ↑ | Keystroke p50 ↓ | Unsafe / 140 ↓ | Model size ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **Gemma 4 E2B Base** | Default | In-process llama.cpp · i1-Q6_K · 3.85 GB | 50.1% | 23.1% (25.3% EN) | 14.6% | 56 ms (102 ms p95) | 0 | 3.85 GB |
| LFM2.5 1.2B Instruct | Local option | In-process llama.cpp · Q4_K_M · 0.73 GB | 43.0% | 20.7% (24.2% EN) | 7.3% | 26 ms (76 ms p95) | 0 | 0.73 GB |

- **Notes:** Accuracy counts held-back suggestions as misses; 'Right when shown' measures precision when the confidence gate displays text. In English, the two models are statistically tied (+1.1 pts, 95% CI −1.4 to +3.5).
- **Caveat:** Engine timings exclude Accessibility field reads and overlay rendering. Synthetic phrases; some confirmed the hybrid decoder before shipping. On Cotabby's separate 782-checkpoint test, Gemma 4 E2B scored 32.7% vs Cotabby's 30.7%.

### First Suggestion After a 5-Minute Pause (Metal Residency Fix)

**Run date:** 2026-11-18 · **Hardware:** Apple M4 Max (48 GB) · macOS 27.2.1 · llama.cpp v1.0.0 (b12359)  
**Dataset:** Gemma 4 E2B i1-Q6_K · single keystroke after 300 s idle vs immediate warm reference  
**Source:** `Benchmarks/autocomplete/Cotyping/results/2026-11-18-first-after-pause/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#autocomplete-pause)

| Model | Status | Runtime / Quant | First suggestion ↓ | Warm reference | Cold penalty ↓ | Wired while idle |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| **Warm-up just before typing (wake / click)** | Default | llama.cpp v1.0.0 · 1-token touch + seq_rm | 49 ms | 47–49 ms | ~1 ms | Released after 3 min away |
| **Warm-up at first keystroke (45 ms debounce)** | Default | llama.cpp v1.0.0 · 1-token touch + seq_rm | 51.5 ms (50, 53 ms) | 47–49 ms | ~3.5 ms | Released after 3 min away |
| Periodic touch every 60 s while active | Local option | llama.cpp v1.0.0 · Keep-warm probe | 59 ms | 47 ms | 12 ms | +2–3 GB wired |
| llama.cpp keep-alive raised to 3600 s | Not adopted | llama.cpp v1.0.0 · Config override | 62 ms | 48 ms | 14 ms | Stays wired 1 hr away |
| Before fix (default 180 s keep-alive) | Baseline | llama.cpp v1.0.0 · No warm-up touch | 112.5 ms (95, 130 ms) | 47–49 ms | +47–82 ms | Unwired at 180 s |

- **Notes:** After llama.cpp's 180 s GGML_METAL_RESIDENCY_KEEP_ALIVE_S expires, ~3.4 GB of weights unwire (+50–80 ms) and the GPU clocks down (+10–15 ms). Decoding one throwaway token on wake/click/key with llama_synchronize and stripping it via seq_rm preserves the KV prompt.
- **Caveat:** 30-minute pauses under heavy OS memory pressure (file paging) have not been re-measured yet. Four warm-up touches over 5 min added 18 mJ CPU energy (468 vs 450 mJ).

### v0.14.0 Apache-2.0 Autocomplete: Gemma 4 E2B (LokalBot v4) vs. Stock

**Run date:** 2026-11-24 · **Hardware:** Apple M4 Max (48 GB) · LokalBot Release binary + llama.cpp v1.0.0  
**Dataset:** 788 Engine word positions + 56 memory and visible-context grounding checks + 242 blind holdout cases  
**Source:** [HF model card: `stevyhacker/Gemma-4-E2B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Gemma-4-E2B-LokalBot-GGUF) · [Interactive table](https://www.lokalbot.com/benchmarks#autocomplete-lokalbot-v4)

| Model | Status | Runtime / Quant | Precision ↑ | Engine Acc ↑ | Grounded / 56 ↑ | Email Prec ↑ | Boundary p50 ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Gemma 4 E2B (LokalBot v4)** | Default | llama.cpp v1.0.0 · i1-Q6_K · 3.85 GB | 52.2% (199/381) | 25.25% (20.1% other) | 56/56 (100%) | 80.0% | 20.2 ms (80.0 ms p95) |
| Gemma 4 E2B (LokalBot v3) | Local option | llama.cpp v1.0.0 · i1-Q6_K · 3.85 GB | 52.4% (242/462) | 30.71% (28.1% other) | 54/56 (2 abstentions) | 70.7% | 26.6 ms (87.2 ms p95) |
| Gemma 4 E2B Base (Stock) | Baseline | llama.cpp v1.0.0 · i1-Q6_K · 3.85 GB | 50.1% (182/363) | 23.10% (14.6% other) | 49/56 (23/30 visible) | 74.3% | 21.2 ms (103.5 ms p95) |

- **Notes:** Rank-32 LoRA across 275 attention, MLP, and Per-Layer Embedding matrices of google/gemma-4-E2B quantized with a bilingual EN/SR imatrix.
- **Caveat:** v4 prioritizes stock-like restraint (182 wrong shown vs 181 stock) and 56/56 grounding; v3 reaches higher raw coverage (58.6%) with +39 extra wrong shown completions.

## Local Hybrid Retrieval & Embedding Models

Head-to-head meeting retrieval across 232 public QMSum meetings (1,576 questions) comparing LokalBot's SQLite FTS5 + EmbeddingGemma 2 layer against GBrain v0.60, plus multilingual embedding comparisons.

### Hybrid Meeting Retrieval: LokalBot (SQLite) vs. GBrain (PGLite MCP)

**Run date:** 2026-11-17 · **Hardware:** Apple M4 Max (48 GB) · shared EmbeddingGemma 2 Q8_0 server (496 MB peak)  
**Dataset:** QMSum (232 public meetings, 129,177 turns, 2.1M words, 1,576 specific questions)  
**Source:** `Benchmarks/memory/GBrain/2026-11-17/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#retrieval-qmsum)

| Model | Status | Runtime / Quant | R@1 ↑ | R@4 / R@10 ↑ | MRR ↑ | Query p50 ↓ | RAM ↓ | Context ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **LokalBot Hybrid (FTS5 + EmbeddingGemma 2)** | Default | SQLite + llama.cpp · RRF k=60 · 167 MB disk | 0.280 | 0.475 (0.595 R@10) | 0.379 | 39 ms (52 ms p95) | 50 MB | 1.2k ch |
| GBrain v0.60 Keyword-Only | Local option | PGLite over stdio MCP · Postgres FTS · 185 MB disk | 0.253 | 0.412 (0.468 R@10) | 0.325 | 159 ms (212 ms p95) | ~1 GB | 97.4k ch |
| GBrain v0.60 Hybrid (EmbeddingGemma 2) | Not adopted | PGLite + llama.cpp · Conservative mode · 247 MB disk | 0.239 | 0.367 (0.370 R@10) | 0.295 | 255 ms (342 ms p95) | ~1 GB | 96.8k ch |
| LokalBot Keyword-Only (SQLite FTS5) | Baseline | SQLite FTS5 BM25 · 80 MB disk | 0.193 | 0.335 (0.456 R@10) | 0.274 | 3 ms (8 ms p95) | 50 MB | 718 ch |

- **Notes:** Both hybrid configurations queried the exact same EmbeddingGemma 2 Q8_0 llama-server. Cloud Xeon keyword-only repeat matched accuracy exactly.
- **Caveat:** GBrain beat LokalBot in keyword-only mode (2,000-char chunks vs single transcript rows) and ran without a hosted reranker or query expansion. Neither system automatically supersedes unlinked contradictory statements.

### Multilingual Embedding Models (English + Serbian Latin/Cyrillic)

**Run date:** 2026-10-07 · **Hardware:** Apple M4 Max (48 GB) · identical llama.cpp build  
**Dataset:** 48 authored queries (24 English, 24 Serbian/Montenegrin Latin & Cyrillic) across 60 synthetic passages  
**Source:** `Benchmarks/search/EmbeddingGemma2/2026-10-07/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#retrieval-embeddings)

| Model | Status | Runtime / Quant | Top-1 ↑ | Top-5 ↑ | MRR ↑ | Query p50 ↓ | Download ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **EmbeddingGemma 2** | Default | llama.cpp · Q8_0 · 768-dim | 89.6% (43/48) | 100.0% (48/48) | 0.944 | 9.0 ms | 0.31 GB |
| Harrier 0.6B | Baseline | llama.cpp · Q8_0 · 1024-dim | 83.3% (40/48) | 97.9% (47/48) | 0.903 | 13.1 ms | 0.64 GB |
| Qwen3-Embedding 0.6B | Not adopted | llama.cpp · Q8_0 | 72.9% (35/48) | — | — | — | 0.64 GB |

- **Notes:** All models ran at Q8_0 on the same llama.cpp build with their native task prompts.
- **Caveat:** On 48 correlated queries, the +6.3 pt top-1 gain over Harrier is within noise (95% CI −4 to +17 pts); EmbeddingGemma 2 won on matching quality at half the download, half the idle RAM, and 31% lower latency.

## Meeting Extraction, Summaries & Native Tool Calling

Small local LLMs (2B–4B) evaluated on structured action-item extraction (ownership, deadlines, timestamps, Serbian Latin/Cyrillic, prompt injection) and native OpenAI-format tool calling in llama.cpp.

### Structured Extraction & Tool Calls on Apple Silicon

**Run date:** 2026-09-10 · **Hardware:** Apple M4 Max (48 GB) · llama.cpp b10173 · -ngl 99 · 32K context  
**Dataset:** 12 synthetic extraction cases (×2 repeats, 86 fields) + 6 single-turn native tool cases + 19K-token archive check  
**Source:** `Benchmarks/think/MiniCPM5/2026-09-10/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#summaries-mac-extraction)

| Model | Status | Runtime / Quant | Field accuracy ↑ | Cases right ↑ | Tool calls ↑ | Median req ↓ | Weights ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Qwen3.5 4B (thinking off)** | Default | llama.cpp Metal · Q4_K_M · 2.74 GB | 93.0% (80/86) | 9/12 | 6/6 | 0.554 s | 2.74 GB |
| MiniCPM5 2B (thinking on) | Not adopted | llama.cpp Metal · Q4_K_M · 1.56 GB | 93.0% (80/86) | 10/12 | — | 5.818 s | 1.56 GB |
| MiniCPM5 2B (Q8_0, thinking off) | Not adopted | llama.cpp Metal · Q8_0 | 88.4% (76/86) | 8/12 | — | 0.338 s | 2.60 GB |
| MiniCPM5 2B (Q4_K_M, thinking off) | Not adopted | llama.cpp Metal · Q4_K_M · 1.56 GB | 79.1% (68/86) | 7/12 | 5/6 | 0.284 s | 1.56 GB |

- **Notes:** In separate full-meeting replays on the same runtime, Qwen3.5 4B summarized a 26-min meeting (4,477 words) in 33.4 s warm / 59.8 s cold and a 91-min meeting (11,229 words) in 71.5–74.2 s (~85 tok/s decode).
- **Caveat:** Bounded synthetic pilot, not a human-rated meeting summary quality corpus. MiniCPM5 2B also looped on a long summary in the Sept 7 pilot.

### 4B Extraction & Tool Calls on Linux CPU: Spark-X2.6-4B vs. Qwen3.5 4B

**Run date:** 2026-10-20 · **Hardware:** AMD Ryzen 7 9700X Ubuntu (CPU-only, 8 threads) · llama.cpp b11474 · 32K context  
**Dataset:** Same 12 synthetic extraction cases (43 fields) + 6 tool cases + ~20K-token long-context pass  
**Source:** `Benchmarks/think/SparkX26/2026-10-20/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#summaries-linux-cpu)

| Model | Status | Runtime / Quant | Fields ↑ | Short cases ↑ | Tool calls ↑ | Short p50 ↓ | 20K-tok req ↓ | Weights ↓ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Spark-X2.6-4B | Experimental | llama.cpp CPU · Q4_K_M · 3.19 GB | 100.0% (43/43) | 12/12 | 5/6 | 2.72 s | 150.08 s | 3.19 GB |
| **Qwen3.5 4B** | Default | llama.cpp CPU · Q4_K_M · 2.74 GB | 95.3% (41/43) | 10/12 | 6/6 | 2.86 s | 120.03 s | 2.74 GB |

- **Notes:** Controlled Linux CPU screen evaluating Apache-2.0 Spark-X2.6-4B as a candidate replacement for Qwen3.5 4B.
- **Caveat:** Linux CPU observations only, not Mac timings. Spark beat Qwen on short extraction (12/12 vs 10/12) but called search_meetings when asked to send email (no email tool exists) and ran 25% slower on ~20K context.

### v0.14.0 Apache-2.0 Think: Qwen3.5 4B (LokalBot v4) vs. Stock Q4_K_M

**Run date:** 2026-11-24 · **Hardware:** NVIDIA RTX PRO 6000 Blackwell · pinned llama.cpp v1.0.0 (b1b770d9) · 32K ctx · enable_thinking=false  
**Dataset:** 120-case Memory Retention + Blind21 holdout (21 untouched EN meetings) + Private28 dev (28 real meetings) + SparkX26  
**Source:** [HF model card: `stevyhacker/Qwen3.5-4B-LokalBot-GGUF`](https://huggingface.co/stevyhacker/Qwen3.5-4B-LokalBot-GGUF) · [Interactive table](https://www.lokalbot.com/benchmarks#summaries-lokalbot-v4)

| Model | Status | Runtime / Quant | Memory (120) ↑ | Blind21 Decisions ↑ | Rejections ↓ | Blind21 Median ↓ | SparkX26 Tools ↑ |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Qwen3.5 4B (LokalBot v4)** | Default | llama.cpp v1.0.0 · Q4_K_M · 2.74 GB | 98.3% (118/120 · 1 unw.) | 45.0% (18/40 · 12/12 mtgs) | 69 (-60.6%) | 13.64 s (1.78x faster) | 6/6 (9/12 cases) |
| Qwen3.5 4B (Stock Q4_K_M) | Baseline | llama.cpp v1.0.0 · Q4_K_M · 2.74 GB | 67.5% (81/120 · 12 unw.) | 7.5% (3/40 · 3/12 mtgs) | 175 | 24.24 s | 6/6 (8/12 cases) |

- **Notes:** Trained on 4,117 Swift-verified rows from open-license sources (zero private meetings in training). Drop-in 2.74 GB Q4_K_M replacement matching stock footprint.
- **Caveat:** On Blind21, stock has higher raw action recall (55.3% vs 47.1%, McNemar p=0.2478) and fewer false-positive decisions on zero-decision meetings (6 vs 25). LokalBot runs v4 with enable_thinking=false by default.

## Screenshot OCR & Local Text-to-Speech

Opt-in on-device screen text extraction (Apple Vision vs. open-source OCR models) and local spoken summary synthesis (Kokoro 82M vs. Breeze TTS 2).

### Screenshot OCR — Synthetic Ground-Truth Set

**Run date:** 2026-06-24 · **Hardware:** Apple M4 Max (48 GB)  
**Dataset:** 5 generated desktop screenshots with exact ground-truth text manifests  
**Source:** `Benchmarks/search/OCR/SYNTHETIC-RESULTS-2026-06-24.md` · [Interactive table](https://www.lokalbot.com/benchmarks#ocr-synthetic)

| Model | Status | Runtime / Quant | Token F1 ↑ | Char sim ↑ | Mean latency ↓ | Precision / Recall |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| PP-OCRv6 medium | Not adopted | det+rec · Local weights | 0.974 | 0.867 | 6,780 ms | 0.960 / 0.990 |
| **Apple Vision** | Default | VNRecognizeTextRequest · 0 MB download | 0.971 | 0.812 | 119.6 ms | 0.971 / 0.971 |
| PaddleOCR-VL 1.6 GGUF | Not adopted | llama.cpp VLM · GGUF | 0.777 | 0.731 | 1,700 ms | 0.871 / 0.813 |
| DeepSeek-OCR GGUF | Not adopted | llama.cpp VLM · GGUF | 0.741 | 0.680 | 1,440 ms | 0.844 / 0.732 |

- **Notes:** Measures multiset token precision/recall/F1 and reading-order character similarity.
- **Caveat:** Small 5-image set; real desktop screenshots (next tab) widened the speed gap even further. PP-OCRv6 also needed ~15 s to load.

### Screenshot OCR — 15 Real Desktop Screenshots (Latency)

**Run date:** 2026-06-24 · **Hardware:** Apple M4 Max (48 GB)  
**Dataset:** 15 real LokalBot macOS screenshots (alternatives sampled on 3–5 images due to runtime)  
**Source:** `Benchmarks/search/OCR/RESULTS-2026-06-24.md` · [Interactive table](https://www.lokalbot.com/benchmarks#ocr-real)

| Model | Status | Runtime / Quant | Mean latency ↓ | Images | Overlap vs Vision |
| --- | --- | --- | ---: | ---: | ---: |
| **Apple Vision (VNRecognizeTextRequest)** | Default | macOS native · 0 MB | 243 ms | 15 | Baseline |
| PaddleOCR-VL 1.6 GGUF (256-tok) | Not adopted | llama.cpp VLM · 256-tok cap | 1,300 ms | 3 | 0.027 |
| DeepSeek-OCR GGUF (512-tok) | Not adopted | llama.cpp VLM · 512-tok cap | 1,640 ms | 3 | 0.000 |
| TrOCR small printed | Not adopted | Transformers · Line-level | 2,470 ms | 3 | 0.001 |
| PaddleOCR-VL 1.6 GGUF (1024-tok) | Not adopted | llama.cpp VLM · 1024-tok cap | 2,740 ms | 3 | 0.104 |
| GOT-OCR 2.0 | Not adopted | HF / MPS · 256-tok cap | 3,700 ms | 3 | 0.000 |
| GLM-OCR | Not adopted | MPS · 256-tok cap | 5,740 ms | 3 | 0.127 |
| PP-OCRv6 medium det+rec | Not adopted | PaddleOCR · Full det+rec | 22,430 ms | 5 | 0.208 |

- **Notes:** Every tested open-source OCR or VLM engine was 5× to 92× slower than Apple Vision on real full-screen captures.
- **Caveat:** Token overlap is measured against Apple Vision rather than human transcription; see Ground Truth tab for absolute F1.

### Local Spoken Summaries: Kokoro 82M vs. Breeze TTS 2

**Run date:** 2026-09-09 · **Hardware:** Apple M4 Max (48 GB) · macOS 27.0 · audio.cpp v0.7.3 Metal vs installed Kokoro  
**Dataset:** 255-word work summary narration + 356-word Qwen3-ASR content check  
**Source:** `Benchmarks/voice/Breeze/2026-09-09/REPORT.md` · [Interactive table](https://www.lokalbot.com/benchmarks#tts-voice)

| Model | Status | Runtime / Quant | 255-word gen ↓ | Gen / audio ↓ | First audio ↓ | Peak memory ↓ | License |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| **Kokoro 82M (Heart voice)** | Default | Local runtime · 82M params | 26.96 s | 0.333× | Full file (5.73 s digest) | 0.81 GiB | Apache-2.0 |
| Breeze TTS 2 | Not adopted | audio.cpp v0.7.3 Metal · Q8_0 · 5.08 GB | 63.12 s | 0.685× | 0.88 s warm (1.3–1.7 s buffered) | 6.42 GiB | Non-commercial |

- **Notes:** Breeze TTS 2 sounded more natural to the owner and streams its first warm chunk in 0.88 s median, while Kokoro is 2.3× faster overall at ~8× lower memory.
- **Caveat:** Breeze TTS 2 uses a non-commercial research license requiring a separate written agreement for product use; listening preference was unblinded from one listener.

## Honest gaps: what is NOT yet measured

| Gap | Status & needed run |
| --- | --- |
| **Apple Silicon variety (M1 / M2 / M3, 16 GB)** | Nearly all Mac numbers come from one M4 Max (48 GB). Timings and memory-pressure behavior on 16 GB M1–M3 Macs need community or secondary-machine runs. |
| **Windows & Linux (Vulkan / CUDA / CPU)** | Only the memory-restraint and Spark-X2.6 suites ran on Linux/Windows so far. Full sherpa-onnx ASR, pyannote/TitaNet diarization, and GPUI Vulkan/CUDA timings are still unmeasured. |
| **Human-rated summary faithfulness** | Extraction tests cover structured fields, ownership, and tool calls, not blind human grading of full meeting recaps across diverse real calls. |
| **Long idle pauses under RAM pressure** | The 5-minute autocomplete warm-up fix is verified (49–53 ms), but 30-minute pauses where macOS pages model files out under memory pressure remain unmeasured. |
| **Broader languages & 5–8 speaker calls** | Diarization covers 4-speaker English AMI rooms; multilingual ASR probes are small FLEURS slices rather than full noisy meetings. |
