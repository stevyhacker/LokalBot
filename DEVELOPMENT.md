# LokalBot — technical deep dive

Everything the [README](README.md) summarizes, in full detail: build workflows, subsystem internals, configuration, headless flags, testing, and the on-disk layout. Shared contributor instructions live in [AGENTS.md](AGENTS.md); the data and network contract lives in [PRIVACY.md](PRIVACY.md). For signing and publication, use [RELEASING.md](RELEASING.md). This guide covers the Mac app; the Windows and Linux app (Rust + GPUI, in `LinuxWindows/`) has its own guide in [LinuxWindows/README.md](LinuxWindows/README.md).

## Build from source

For the Mac app, use an Apple Silicon Mac with full Xcode installed; the [build workflow](.github/workflows/build.yml) pins the CI toolchain. With Homebrew available:

```bash
brew install xcodegen cmake
# Rust (https://rustup.rs) builds the phone and tablet sync library; the repo
# pins the toolchain, which rustup installs on first use.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain none

git clone https://github.com/stevyhacker/lokalbot.git
cd lokalbot

# XcodeGen needs these paths before the first build fetches the runtimes.
mkdir -p Vendor/llama-cpp Vendor/sherpa-onnx
# The phone and tablet sync library (Rust), as a local Swift package.
Scripts/build/build-sync-xcframework.sh
xcodegen generate
open LokalBot.xcodeproj
```

Select **LokalBot Dev**, set your signing team, and run. The Dev app has its own identity, macOS permission grants, library, model storage, and Keychain namespace, so it can live alongside the installed release without applying development retention settings to release data. The first build prepares pinned native runtimes; model downloads happen separately.

For the Windows and Linux app, see [Build from source](LinuxWindows/README.md#build-from-source) in its README (Rust).

[Build and test commands](Docs/development/build-workflows.md) · [Testing guide](Docs/development/testing.md) · [Screenshot guide](Docs/guides/screenshot-kit.md)

### Find your way around the code

```text
LokalBot/
├── Views/       # Native SwiftUI screens, settings, and onboarding
├── Services/    # Recording, search, storage, and workday memory
├── Engines/     # Transcription, model catalog, and local inference
├── Cotyping/    # System-wide autocomplete
├── Dictation/   # Voice typing
└── Agent/       # Optional Agent Mode and approval flow
CLI/             # Command-line interface and MCP entry points
LinuxWindows/    # Windows and Linux app (Rust + GPUI)
LokalBotTests/   # Unit tests
Scripts/         # Build, verification, capture, and release tooling
project.yml      # XcodeGen source of truth
```

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
| [Importing from other apps](Docs/development/meeting-import.md) | Granola, Otter, Fireflies, Fathom, Screenpipe, Zoom, Voice Memos, MacWhisper |
| [Configuration](Docs/development/configuration.md) | Settings, languages, environment variables |
| [Agent CLI and MCP](Docs/development/agent-cli.md) | `lokalbot-cli` and the MCP server |
| [Headless flags](Docs/development/headless-flags.md) | The app binary as a test harness |
| [Testing](Docs/development/testing.md) | Unit, UI, replay, day-in-the-life and upgrade checks |
| [On-disk layout](Docs/development/on-disk-layout.md) | What the app stores where |
| [Project layout](Docs/development/project-layout.md) | How this repository is organized |

## Releasing

In-place signed updates ship via [Sparkle](https://github.com/sparkle-project/Sparkle). The release runbook (notarization, appcast signing, DMG tooling) lives in [`RELEASING.md`](RELEASING.md). `AppUpdateManager` stays inert on dev builds (`LOKALBOT_DEV`) and in forks with placeholder `SUFeedURL` or `SUPublicEDKey` values.

## Status

**Done:** robust two-track recording · live notes and transcript · local transcription and neural diarization · eight summary backends (including ChatGPT, Claude, Antigravity, and Gemini plans) with templates and languages · reviewable outcomes with cited evidence · Today and session-based Timeline views · FTS5 and semantic meeting/screen search · synchronized playback and Kokoro TTS · encrypted visual context, saved moments, and contextual privacy · Quick Recall · scheduled exports and fixed-scope routines · Memory Health · Ask · model-role readiness and presets · Agent Mode · independently gated meeting/screen MCP tools · Sparkle updates · dev/prod split · Autocomplete via the opt-in Cotyping engine · opt-in system-wide Dictation.

**Not yet built:** VLM screenshot captions (needs a multimodal Think model and a caption pass; `LlamaServer` already loads an `--mmproj` projector for the Files embedder and Granite Speech).
