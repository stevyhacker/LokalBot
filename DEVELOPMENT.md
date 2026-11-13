# LokalBot — technical deep dive

Everything the [README](README.md) summarizes, in full detail: build workflows, subsystem internals, configuration, headless flags, testing, and the on-disk layout. Shared contributor instructions live in [AGENTS.md](AGENTS.md); the data and network contract lives in [PRIVACY.md](PRIVACY.md). For signing and publication, use [RELEASING.md](RELEASING.md). This guide covers the Mac app; the Windows and Linux app (Rust + GPUI, in `LinuxWindows/`) has its own guide in [LinuxWindows/README.md](LinuxWindows/README.md).

## Topics

Each topic has its own page under [`Docs/development/`](Docs/development/):

| Topic | Covers |
| --- | --- |
| [Build workflows](Docs/development/build-workflows.md) | Toolchain, schemes, vendored runtimes, signing for local builds |
| [Recording and meeting detection](Docs/development/recording.md) | Detection, two-track capture, recovery |
| [Transcription and speakers](Docs/development/transcription.md) | Transcribe engines, diarization, speaker attribution |
| [Summaries and notes](Docs/development/summaries.md) | Think model notes, outcomes, boundaries, templates |
| [Built-in LLM runtime](Docs/development/llm-runtime.md) | llama.cpp server, model catalog, downloads |
| [Search and player](Docs/development/search.md) | FTS5 and semantic index, playback |
| [Ask](Docs/development/ask.md) | Conversational Q&A over the library |
| [Day tracking](Docs/development/day-tracking.md) | Today, Timeline, Day Digest |
| [Autocomplete](Docs/development/autocomplete.md) | The Cotyping engine |
| [Dictation](Docs/development/dictation.md) | System-wide voice typing |
| [Agent Mode](Docs/development/agent-mode.md) | The embedded pi coding agent |
| [Live Radar and Follow-through](Docs/development/live-radar.md) | Live meeting analysis and planned follow-ups |
| [Screen context](Docs/development/screen-context.md) | Capture, OCR, privacy |
| [Safe local routines](Docs/development/routines.md) | Scheduled local jobs |
| [Email](Docs/development/email.md) | Read-only Gmail |
| [Meeting note export](Docs/development/note-export.md) | Notes written to a folder |
| [Configuration](Docs/development/configuration.md) | Settings, languages, environment variables |
| [Agent CLI and MCP](Docs/development/agent-cli.md) | `lokalbot-cli` and the MCP server |
| [Headless flags](Docs/development/headless-flags.md) | The app binary as a test harness |
| [Testing](Docs/development/testing.md) | Unit, UI, replay, day-in-the-life and upgrade checks |
| [On-disk layout](Docs/development/on-disk-layout.md) | What the app stores where |
| [Project layout](Docs/development/project-layout.md) | How this repository is organized |

## Releasing

In-place signed updates ship via [Sparkle](https://github.com/sparkle-project/Sparkle). The release runbook (notarization, appcast signing, DMG tooling) lives in [`RELEASING.md`](RELEASING.md). `AppUpdateManager` stays inert on dev builds (`LOKALBOT_DEV`) and in forks with placeholder `SUFeedURL` or `SUPublicEDKey` values.

## Status

**Done:** robust two-track recording · live notes and transcript · local transcription and neural diarization · six summary backends (including ChatGPT and Claude plans) with templates and languages · reviewable outcomes with cited evidence · Today and session-based Timeline views · FTS5 and semantic meeting/screen search · synchronized playback and Kokoro TTS · encrypted visual context, saved moments, and contextual privacy · Quick Recall · scheduled exports and fixed-scope routines · Memory Health · Ask · model-role readiness and presets · Agent Mode · independently gated meeting/screen MCP tools · Sparkle updates · dev/prod split · Autocomplete via the opt-in Cotyping engine · opt-in system-wide Dictation.

**Not yet built:** VLM screenshot captions (needs a multimodal Think model and a caption pass; `LlamaServer` already loads an `--mmproj` projector for the Files embedder and Granite Speech).
