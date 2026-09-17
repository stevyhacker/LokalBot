<div align="center">

<img src="Assets/lokalbot-icon.svg" width="110" alt="LokalBot icon" />

# LokalBot

**Find what you said or saw on your Mac.**

Find a decision from a call, a page you had open, or what you need to follow up on. LokalBot searches meeting transcripts and screen text you choose to save, with links back to the source.

Free and open source. Runs locally by default. No account required.

[![Download LokalBot for macOS](https://img.shields.io/badge/%E2%80%82Download%20for%20macOS%E2%80%82-LokalBot.dmg-0969da?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg)

<sub>Apple Silicon (M1 or later) · macOS 15+ · <a href="https://github.com/stevyhacker/lokalbot/releases">Release notes</a></sub>

[![Latest release](https://img.shields.io/github/v/release/stevyhacker/lokalbot?color=1f6feb&label=release)](https://github.com/stevyhacker/lokalbot/releases/latest)
[![License: GPLv3](https://img.shields.io/badge/license-GPLv3-2ea043)](LICENSE)

[See it in action](#see-it-in-action) · [Features](#features) · [Privacy](#privacy--verify-it) · [Get started](#download) · [For developers](#for-developers--agents)

</div>

## See it in action

**One search, across meetings and saved screen text.** Quick Recall finds the Redis discussion in a meeting alongside matching Slack and browser context. Open a result to return to the source.

<div align="center"><a href="Assets/screenshots/quick-recall.png"><img src="Assets/screenshots/quick-recall.png" alt="Quick Recall searching for Redis, with results grouped into saved screen context and meeting transcripts" width="660"></a></div>

**Watch the 43-second demo.** Search an engineering discussion, find the database decision, and recover the follow-up to draft the schema.

https://github.com/user-attachments/assets/39cba80c-a0d5-4cf3-9019-b081b287de4f

<sub>The video shows the real app with a prepared fictional meeting. It demonstrates search and source navigation; live recording and transcription are not shown.</sub>

**Find the decision and the discussion behind it.** Open a meeting to review its recap, decisions, and action items, then follow a citation back to the transcript or audio.

<div align="center"><a href="Assets/screenshots/meetings-summary.png"><img src="Assets/screenshots/meetings-summary.png" alt="Meeting workspace showing the Design review recap, decisions, action items, source citations, and audio playback" width="920"></a></div>

**Pick up where you left off.** Today brings the day's summary and outstanding meeting actions together.

<div align="center"><a href="Assets/screenshots/today.png"><img src="Assets/screenshots/today.png" alt="Today showing the day digest and outstanding meeting actions" width="920"></a></div>

<details>
<summary>See your day in Timeline</summary>

Timeline groups captured activity into work sessions, with the underlying context available to inspect.

<div align="center"><a href="Assets/screenshots/timeline.png"><img src="Assets/screenshots/timeline.png" alt="Timeline showing grouped work sessions, meetings, and access to captured context" width="920"></a></div>

</details>

<sub>App screenshots use synthetic demo data captured from v0.8.2. Click an image for the full-resolution view. See the <a href="Assets/screenshots/README.md">capture notes</a> for provenance.</sub>

## Features

| What you want to do | How LokalBot helps |
| --- | --- |
| **Remember a call** | Record microphone and meeting-app audio without adding a bot. Transcribe locally and review the recap, decisions, action items, and open questions. |
| **Find something again** | Search meeting transcripts and optional saved screen text by words or meaning. Open the source behind a result or ask a question with meeting citations. |
| **Keep track of follow-ups** | Review and correct action items, mark them done, and trace them back to the meetings where they came up. |
| **Look back at your day** | Browse work sessions and the day digest. Choose activity-only tracking, visible text, or text with encrypted screenshots. |
| **Write in other apps** | Dictate at the cursor or enable local Autocomplete. Both are optional; Autocomplete has an in-app preview to try before enabling it elsewhere. |
| **Prepare the next step** | Create local follow-up drafts and Markdown exports, or hand reviewed context to the optional Agent Mode. File and shell actions follow its approval settings. |

<details>
<summary>See Autocomplete and model settings</summary>

Try a suggestion before enabling Autocomplete in other apps.

<div align="center"><a href="Assets/screenshots/cotyping.png"><img src="Assets/screenshots/cotyping.png" alt="Autocomplete settings with model readiness, a local suggestion preview, and an acceptance rehearsal" width="920"></a></div>

Choose models for transcription, summaries, search, and writing.

<div align="center"><a href="Assets/screenshots/models.png"><img src="Assets/screenshots/models.png" alt="Models settings showing active model roles, download readiness, and connections" width="920"></a></div>

</details>

## Download

1. **[Download LokalBot.dmg](https://github.com/stevyhacker/lokalbot/releases/latest/download/LokalBot.dmg)**, drag LokalBot to Applications, and open it.
2. Review the recording and capture settings. Meeting recording defaults to automatic detection; you can switch to asking first or starting manually. Grant the permissions for the features you want to use.
3. Let the selected models download. Built-in transcription, search, summaries, and writing can then run locally without an internet connection.

You'll need an **Apple Silicon Mac with macOS 15 or later**, plus disk space for the models you choose. Settings → Models shows their download sizes and readiness. No account, subscription, or API key is required for the built-in models.

[All releases](https://github.com/stevyhacker/lokalbot/releases) · [Setup help](SUPPORT.md) · [Homebrew distribution](Distribution/homebrew/README.md)

## How it works

1. **Capture what you choose.** Meeting recording stores microphone and meeting-app audio locally. Day tracking is separate: activity-only is the default; visible text and screenshots are opt-in.
2. **Process it on your Mac.** Local models transcribe recordings, generate meeting summaries, and prepare search indexes. You can select different models for each job.
3. **Return to the evidence.** Search, ask, replay a passage, review an action, or open a retained screen moment. The library stays in local files and SQLite under your macOS account.

Supported backends include the built-in llama.cpp runtime, Ollama, OpenAI-compatible servers, and Apple Intelligence on supported Macs running macOS 26 or later. Non-loopback servers require approval before receiving context.

<details>
<summary>See an example local model stack</summary>

This higher-capacity example uses about **12.4 GB** after the models are downloaded. It was measured on a **48 GB M4 Max MacBook Pro** with LokalBot's bundled llama.cpp runtime and full Metal offload. It is an example for comparing storage and speed, not the default preset; the current Recommended preset uses the smaller LFM2.5 1.2B for Autocomplete.

| Role | Model | Quantization / format | Model files | Measured generation |
| --- | --- | --- | ---: | --- |
| Transcription | IBM Granite Speech 4.1 2B | `Q4_K_M` + F16 projector | 2.30 GB | ASR; use realtime factor |
| Summaries and chat | Qwen3.5 4B | `Q4_K_M` | 2.74 GB | ~100 tokens/s |
| Autocomplete | Gemma 4 E4B | `UD-Q5_K_XL` | 6.66 GB | ~78 tokens/s |
| Semantic search | Qwen3-Embedding 0.6B | `Q8_0` | 0.64 GB | Embeddings; not generative |
| Speaker diarization | pyannote-community-1 via FluidAudio | Core ML | ~0.10 GB | Diarization; not generative |

The measurements come from one M4 Max machine; generation speed varies with context length, thermals, and other workloads. See the [benchmark summary](https://huggingface.co/spaces/stevyhacker/lokalbot-benchmarks) for the supporting details.

</details>

For model options, benchmarks, storage, and architecture, see [DEVELOPMENT.md](DEVELOPMENT.md) and the [model benchmark results](https://huggingface.co/spaces/stevyhacker/lokalbot-benchmarks).

## Privacy — verify it

LokalBot has no account system, telemetry backend, or LokalBot cloud. Recording and the built-in models process your data on your Mac.

- **Screen context is optional.** Fresh installs use activity-only day tracking. Visible text and encrypted screenshots require a separate choice and the relevant macOS permissions. You can pause capture or exclude apps and domains.
- **Retention is adjustable.** Screen text and screenshots expire after 14 days by default. Moments you explicitly save remain until you unsave or delete them.
- **Downloads and updates use the network.** Models and optional agent runtimes need downloads. Automatic app-update checks are enabled for new installs and can be disabled in Settings.
- **Remote models need approval.** If you configure a non-loopback Ollama or OpenAI-compatible server, LokalBot asks before sending context to that origin.
- **Agent access has separate controls.** Agent Mode commands may read files or use the network according to their approval settings. External CLI/MCP access is off by default, with separate permissions for meetings and screen memory. External clients have their own data-handling policies.

To check the local processing path, download the models, select the built-in backend, disable automatic update checks, and observe network traffic while recording, transcribing, and summarizing. Approved agent commands and external clients are separate network paths.

[Full privacy policy](PRIVACY.md) · [Report a security issue](SECURITY.md)

## FAQ

<details>
<summary>Does it record everything on my screen?</summary>

No. Activity-only tracking is the default. Saving visible text and screenshots is optional, and you can turn tracking off. Private windows, excluded apps and domains, and secure fields are skipped; detected credentials are redacted and the associated pixels are dropped. Detection has limits, so exclude any app or domain you do not want retained. See [PRIVACY.md](PRIVACY.md).

</details>

<details>
<summary>Does a bot join my meetings?</summary>

No. LokalBot records your microphone and the meeting app's audio on your Mac. Those are separate audio sources; identifying individual speakers is a separate step. If system-audio capture is unavailable, the app warns you that recording is microphone-only. Let participants know before recording.

</details>

<details>
<summary>Can I use my own models?</summary>

Yes. Choose compatible GGUF models for the built-in runtime, connect Ollama or an OpenAI-compatible server, or use Apple Intelligence where supported. Settings → Models manages active models, downloaded files, and connections. See [model backends](DEVELOPMENT.md#summarization--notes) for details.

</details>

<details>
<summary>Can I export my data?</summary>

Yes. Export meeting content and use optional Markdown, Obsidian, or Logseq memory exports. Local routines can prepare follow-up drafts in a folder you choose. Exported files are outside the app's encrypted storage and follow the privacy settings of any service you sync them with.

</details>

## For developers & agents

The app bundles `lokalbot-cli`, a read-only interface to your meeting library and a stdio MCP server. Enable meeting-library access in **Settings → Privacy** before connecting a client.

```bash
lokalbot-cli search "database decision"
lokalbot-cli get latest --include metadata,summary
lokalbot-cli mcp
```

If the command is not on your PATH, use `/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli`.

Screen-memory MCP tools need a separate permission scoped to today, the last seven days, or all retained history. They return text and metadata, not decrypted screenshots. An external client may send tool results to its own model provider; LokalBot's local processing does not change that client's data handling.

[CLI skill and examples](.agents/skills/lokalbot-cli/SKILL.md) · [Claude Code plugin](Distribution/claude-plugin/README.md) · [MCP and agent architecture](DEVELOPMENT.md#agent-cli--mcp)

## Build from source

Install Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and CMake (`brew install xcodegen cmake`), then:

```bash
git clone https://github.com/stevyhacker/lokalbot.git
cd lokalbot
xcodegen generate
open LokalBot.xcodeproj
```

Select the **LokalBot Dev** scheme, set your signing team, and run. The Dev app has a separate bundle identity and permission grants from the installed release. The first build prepares the pinned native runtimes; models download when needed.

Build commands, unit tests, hosted UI tests, and troubleshooting are in [DEVELOPMENT.md](DEVELOPMENT.md). Screenshot maintenance is covered in the [capture guide](Docs/screenshot-kit.md).

## Contributing & security

Bug reports and pull requests are welcome. Use the [issue templates](.github/ISSUE_TEMPLATE) and [pull request template](.github/PULL_REQUEST_TEMPLATE.md), and include the checks relevant to your change. Report vulnerabilities privately through [SECURITY.md](SECURITY.md). For usage questions, see [SUPPORT.md](SUPPORT.md).

## License

LokalBot is free software under [GPLv3](LICENSE).

## Acknowledgements

Built with [llama.cpp](https://github.com/ggml-org/llama.cpp), [Qwen3-ASR](https://huggingface.co/Qwen), [IBM Granite Speech](https://huggingface.co/ibm-granite), [Parakeet](https://huggingface.co/nvidia), [WhisperKit](https://github.com/argmaxinc/WhisperKit), [FluidAudio](https://github.com/FluidInference/FluidAudio), [Sparkle](https://github.com/sparkle-project/Sparkle), and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Autocomplete engine shares its loop with [Cotabby](https://cotabby.app).
