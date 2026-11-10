# Facts

Everything the three films say or show, with where it comes from. The films describe the **Mac app
with its default settings on a fresh install**, as of `master` at 133274d (2026-11-09). A fact that
is not here does not go on screen; `kit/check_facts.py` reads every number with a unit out of the
scenes and fails on one that is not in `kit/facts.json`.

## The five models

"Different jobs use different models. These are the Mac defaults on a fresh install, about 9.6 GB of
model files if you use every role. They are not a RAM requirement" (`README.md`, "Local AI, your
choice").

| Job | Model | Format and engine | Files | Source |
| --- | --- | --- | ---: | --- |
| Speech to text ("Transcribe") | Qwen3-ASR 1.7B | MLX 8-bit, in the app's process (MLX Swift) | 2.47 GB | README table; `Engines/PinnedSpeechModels.swift:189` (2,463,307,541 bytes) |
| Who spoke when | Nemotron 3 (Preview) | Core ML, through FluidAudio | 0.20 GB | README table ("~0.20 GB"); `Models/DiarizationModel.swift:21` |
| Notes, answers ("Think") | Qwen3.5 4B | GGUF `Q4_K_M`, the bundled llama.cpp `llama-server` on Metal, 127.0.0.1:17872 | 2.74 GB | README table; `Engines/ModelCatalog.swift:131` (2,740,937,888 bytes); `CLISupport/LlamaServerRole.swift` |
| Autocomplete | Gemma 4 E2B Base | GGUF `Q6_K`, llama.cpp inside the app's process (libllama) | 3.85 GB | README table; `ModelCatalog.swift:117`; `DEVELOPMENT.md` "Autocomplete" |
| Search by meaning | EmbeddingGemma 2 | GGUF `Q8_0`, a second `llama-server`, 127.0.0.1:17873, 768-dimensional vectors | 0.31 GB | README table; `Services/EmbeddingIndex.swift:200`; `DEVELOPMENT.md` "Search & player" |

File names as downloaded: `Qwen3.5-4B-Q4_K_M.gguf`, `gemma-4-E2B.i1-Q6_K.gguf`,
`embeddinggemma-2-Q8_0.gguf` (in `models/`); the Qwen3-ASR weights are a folder under
`qwen3-asr-models/`.

Small helpers on the same path, never counted in "five": Silero voice-activity detection (Core ML),
the Qwen3 forced aligner 0.6B that times each word (MLX 4-bit, about 1 GB, 11 languages), Pyannote
voice embeddings for remembered voices, Apple Vision for screen text (opt-in), and Kokoro 82M, which
reads notes and answers aloud (an optional download).

Three engines: llama.cpp (Metal), MLX, Core ML. "No Ollama / LM Studio required"
(`ModelCatalog.swift:6`).

## What happens to a call

1. **Two tracks.** "`mic.m4a` (AVAudioEngine) captures microphone input; `system.m4a` captures the
   selected application process through a Core Audio tap" (`DEVELOPMENT.md`, "Recording"). No bot
   joins: "Record microphone and meeting-app audio without a bot joining" (`README.md`).
2. **After the call** ("runs automatically when a recording stops"), per track
   (`Services/ProcessingPipeline.swift`, `transcribeTracks`): echo cancellation on the microphone,
   the speaker model marks the turns, Qwen3-ASR transcribes ("52 languages and dialects"), the
   aligner times the words, and each word is given to its speaker. Qwen3-ASR is "intentionally a
   post-meeting engine"; a live transcript is opt-in.
3. **Notes.** Qwen3.5 4B writes `summary.md`: "TL;DR / Key points / Decisions / Action items / Open
   questions" (`DEVELOPMENT.md`, "Summarization & notes").
4. **Index.** Keywords go to SQLite FTS5, and "transcript/summary chunks … are embedded with
   EmbeddingGemma 2 … Vectors live in SQLite" (`DEVELOPMENT.md`, "Search & player").
5. **Use.** Search needs no answering model. Autocomplete finishes a sentence from memory only when
   its two memory settings are on (both off by default; autocomplete itself is opt-in). An agent
   reads the library through `lokalbot-cli mcp`, "MCP over stdio", read-only, and "all agent
   surfaces are **off by default**" (`DEVELOPMENT.md`, "Agent CLI & MCP").

## The library

`~/Library/Application Support/me.dotenv.LokalBot/` (`DEVELOPMENT.md`, "On-disk layout"):

```
meetings/YYYY/MM/dd-slug/   mic.m4a, system.m4a, meta.json, transcript.json, transcript.md, summary.md
journal/YYYY-MM-DD.md       day digests
models/                     downloaded GGUFs
qwen3-asr-models/           downloaded Qwen3-ASR MLX weights
lokalbotv3.sqlite           FTS5 (docs) + embeddings + activity_blocks + ocr_fts + screenshots + ...
```

## Taking turns (memory)

- The two `llama-server` processes start when a feature asks for them. "Consumers take per-request
  leases, a server with no active leases unloads after a short linger, and loaded models sit under
  a RAM residency budget with LRU eviction" (`DEVELOPMENT.md`, "Built-in LLM runtime").
- The linger is 600 s for the Think model and for embeddings (`Engines/InferenceLease.swift:59`:
  "long enough that bursty consumers (chat follow-ups, typing) don't pay a model reload, short
  enough that the RAM comes back within minutes").
- The budget is "half of physical RAM by default" (`Engines/ModelResidency.swift:61`); a load that
  cannot fit proceeds anyway.
- Waiting requests are ordered interactive, agent, pipeline (meeting notes), background (digests,
  embeddings) (`Engines/InferenceLease.swift:7`).
- The MLX speech engines (Qwen3-ASR, its aligner) and voice-activity detection unload after 120 s
  idle (`Engines/QwenASREngine.swift:64`, `QwenWordAligner.swift:40`) and hand MLX's cached buffers
  back. The speaker model does the same (`Services/NeuralDiarizationEngine.swift:30`,
  `idleSeconds: TimeInterval = 120`).
- Nothing loads a model while a call is recording with the default settings: the speaker and
  speech models are prepared in `ProcessingPipeline.transcribeTracks`, after the recording stops.
- The autocomplete model runs inside the app and has no idle timer; it is dropped under memory
  pressure once it has been idle 60 s (`Cotyping/Llama/LlamaCotypingRuntime.swift:417`).
- While a meeting is recording, autocomplete is "Paused while a meeting is recording."
  (`Cotyping/CotypingMeetingPause.swift:11`).

## Measured (one Apple M4 Max with 48 GB; `Benchmarks/README.md`)

Any speed on screen says "M4 Max" beside it or in the end note.

| What | Number |
| --- | --- |
| Autocomplete, per keystroke | 56 ms median, 102 ms p95 |
| Notes for a 26-minute meeting | 33.4 s warm, 59.8 s with the model load |
| Notes decode speed | about 85 tok/s |
| Search by meaning | 9.0 ms per query |
| Speaker model | 14.6% DER on 8 AMI recordings; 500× real time |
| Speech to text | 17.6% WER on 27 minutes of AMI audio |
| Screen text (Apple Vision) | 243 ms a screenshot |

## The edge

- "Recording and built-in AI processing happen on your computer. LokalBot has no account system,
  analytics service, or telemetry backend" (`README.md`, "Privacy").
- In: "Models, updates, and optional agent runtimes need downloads. Automatic update checks can be
  disabled." Model files come from Hugging Face, pinned by SHA-256.
- Out, only when the person turns it on: "A remote model server receives context only after you
  approve its origin"; agents (CLI and MCP) are off by default; a paired phone gets an end-to-end
  encrypted copy only after pairing.

## Words to keep straight

- "Five models" always means the five in the table. The aligner and the other helpers are named as
  helpers, never added to the count or to the 9.6 GB.
- 9.6 GB is files on disk, never memory.
- "Never leaves your Mac" is only true of the built-in models. An agent that asks over MCP usually
  runs on a remote model, so a film that shows the agent does not also say "never left".
- The example sentence, "The offsite is in Lisbon, May 12 to 14.", and the people in it are
  fictional, as in the One Decision film.
