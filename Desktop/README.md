# LokalBot for Linux and Windows

A native Rust / GPUI desktop app alongside LokalBot's existing macOS app. The UI uses the same persistent services as the headless CLI. An ordinary launch opens an empty local library; fictional data requires the explicit `seed` command. This is a functional preview port, with the platform gaps listed below. It does not replace the macOS app or automatically migrate its library.

## Run

Use the Linux tarball or Windows ZIP from the **Rust desktop** workflow on the PR revision. Extract it, then launch `lokalbot-desktop` (`lokalbot-desktop.exe` on Windows). On Linux, `bash packaging/install-linux.sh` optionally installs the binaries and desktop entry for your user. Windows runs directly from the extracted directory.

Ubuntu needs Vulkan (Mesa's software renderer works), X11 or Wayland libraries, ALSA, DBus, FFmpeg for audio import/playback, and Python 3 with `python3-pyatspi` for accessibility capture. Omarchy uses the same native Linux app: GPUI supports Wayland; focused-window verification uses `hyprctl`, and optional pixels use `grim`. The Ubuntu software-renderer preview is the tested Linux configuration. Hyprland capture and physical devices require testing on those desktops.

On Windows, FFmpeg must be on PATH for audio import/playback. Capture uses Windows PowerShell and UI Automation. Hosted CI builds the Windows UI and microphone adapter; physical microphone, display, secure-field and accessibility integration require a real Windows session.

Navigation: Ctrl+1 Today, Ctrl+2 Timeline, Ctrl+3 Meetings, Ctrl+4 Ask, Ctrl+5 Type, Ctrl+6 Agent, Ctrl+7 Settings, Ctrl+8 People, Ctrl+9 Projects.

## Models and credentials

Settings starts with a local OpenAI-compatible endpoint. Configure an already-running local model server, or choose OpenRouter, enter the model ID, and **Approve inference origin**. Keys entered in the UI go to the OS credential store. `OPENROUTER_API_KEY` also works as an ephemeral process variable. The app does not load `.env` files automatically. OpenRouter keys are scoped to its fixed HTTPS origin; a compatible server never receives them. Remote routing defaults to providers that deny data collection. Failures do not relax that policy.

CPU transcription uses `whisper-cli`. CI packages a CPU build pinned to whisper.cpp commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`. Set its executable path and a GGML model path in Settings. From a source checkout, explicitly run `python scripts/bootstrap-whisper.py --build --model` to build that runtime and download a checksum-verified English base model. That model is for the synthetic English check; choose a multilingual model for other languages. No GPU is required. Remote audio has independent opt-in and requires explicitly selecting account-policy routing because the provider transcription API cannot enforce private-only routing.

## Local library and CLI

The library lives in the OS user-data directory returned by `ProjectDirs` for `me/dotenv/LokalBotDesktop`, or in the explicit `LOKALBOT_STORAGE_ROOT`. It is independent of the macOS production library. Long transcripts are processed in bounded UTF-8 parts, with validated source IDs and resumable local checkpoints. Completed parts are reused after a failed request only while the original input/model/consent revision matches.

SQLite/WAL persists meetings, transcript passages, notes, actions, conversations, workday evidence, jobs and settings. Audio stays under that library. Pixels are authenticated AES-GCM ciphertext. Read [PRIVACY.md](PRIVACY.md) for this port's storage and network contract.

```sh
lokalbot-desktop-cli --root /tmp/lokalbot-fictional seed
lokalbot-desktop-cli --root /tmp/lokalbot-fictional import transcript.txt
lokalbot-desktop-cli --root /tmp/lokalbot-fictional configure --meeting-access true
lokalbot-desktop-cli --root /tmp/lokalbot-fictional list
lokalbot-desktop-cli --root /tmp/lokalbot-fictional summarize MEETING_ID
lokalbot-desktop-cli --root /tmp/lokalbot-fictional ask 'Who will test microphone recording?'
lokalbot-desktop-cli --root /tmp/lokalbot-fictional mcp
```

`mcp` is a read-only stdio JSON-RPC server. Meeting and screen access are separate, default-off grants; screen access is time-scoped and never includes pixels or file paths. User-invoked import, processing, edits, export and deletion are available through `--help`. It never listens on a network socket. Imported JSON gets fresh record and passage IDs and cannot adopt external media paths.

## Build and checks

Rust 1.95.0, GPUI Kit 0.7.0, and the full dependency graph are pinned by the toolchain and lockfile. GPUI Kit uses third-party registry snapshots of Zed's GPUI; see [dependency provenance](docs/dependency-provenance.md) for the publisher, upstream revision, graph counts and verification limits. On Ubuntu install the dependencies listed in [the workflow](../.github/workflows/desktop.yml), then:

```sh
cargo test --locked --no-default-features
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo build --locked
python scripts/ui-smoke.py # remote/hosted Ubuntu only; also needs tesseract-ocr
dbus-run-session -- python3 scripts/capture-smoke.py # python3-pyatspi and GTK3 introspection
```

UI checks run on the isolated Ubuntu Xvfb display, with lavapipe Vulkan and fictional data. The smoke runner records screenshots and validates persisted state. CI also extracts each generated archive, verifies its checksum/source revision, launches the bundled CLI and CPU Whisper, and checks persistence/search. On Linux those extracted binaries run the native UI and guarded accessibility checks (`python scripts/verify-package.py --ui`). Live model evaluation is explicitly enabled with `lokalbot-desktop-cli eval --live` on a freshly seeded synthetic library with an approved origin. Automated public CI uses only loopback responses and synthetic fixtures, never your credentials.

## Port coverage

| Area | Current implementation | Remaining platform parity |
| --- | --- | --- |
| Meetings | Real microphone adapter, FFmpeg import, CPU/opt-in API transcription, notes, cited summaries, editable actions, deletion/export, verified PCM recovery | Per-application system audio, automatic call detection/calendar, live transcription, neural diarization and remembered voice profiles |
| Workday | Persisted app activity, guarded visible accessibility text, independently enabled encrypted pixels, retention, saved moments, daily model digest | macOS event-trigger capture/OCR fallback, automatic Dream memory, coding-session ingestion and curated routines |
| Search and Ask | SQLite FTS5, retained evidence, cited model answers, uncertainty and source navigation; vector storage/service foundation | Automatic embedding backfill, all macOS source/date/filter scopes and conversational history navigation |
| Type | In-app writing, real dictation through the selected ASR backend, explicit Copy, model completion | Global hotkeys/ghost-text overlay and compositor-safe insertion |
| Agent | Persisted model plans, reviewable direct executable proposal, manual approval, bounded output/time, credential environment allowlist | Embedded multi-turn Pi tools, attachments and advanced approval modes |
| People / Projects | Names supplied in meeting metadata, library-backed groups | Learned relationship/project memory and identity review |
| Distribution | Native Linux/Windows builds and revision-labelled unsigned archives | OS installer/signing/update channel and verified Omarchy/physical Windows integration |

Agent commands run with ordinary user permissions; a selected working directory is not a filesystem sandbox. The host excludes the private library as a workspace and does not grant implicit attachments, but an explicitly approved program retains its OS user permissions. Approval must consider its complete program and arguments.
