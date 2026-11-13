# Project layout

Part of the [development guide](../../DEVELOPMENT.md).

## Repository

```
repository/
├── README.md, PRIVACY.md, SECURITY.md, SUPPORT.md, LICENSE, THIRD_PARTY_NOTICES.md
├── AGENTS.md, CLAUDE.md, AGENT_SETUP.md, CONTEXT.md   # agent instructions, agent setup guide, glossary
├── DEVELOPMENT.md, RELEASING.md                       # development guide index, release runbook
├── project.yml                # XcodeGen manifest: LokalBot + LokalBot Dev + tests + lokalbot-cli
├── wrangler.jsonc             # Cloudflare Workers Builds deploys Website/ from here
├── LokalBot/                  # the Mac app (below)
├── LokalBotTests/             # unit tests, in the same folders as the code they test
├── LokalBotUITests/           # XCUITest suite (runs on hosted CI, never locally)
├── CLI/                       # lokalbot-cli: ArgumentParser entry + Commands/
├── LinuxWindows/              # the Windows and Linux app (Rust + GPUI) and the shared sync crate
├── Companion/                 # iPhone, iPad and Android companion apps, sync protocol, e2e harness
├── Distribution/              # Claude and OpenAI plugins, Homebrew, npm, MCP Registry, Raycast, Hugging Face
├── Website/                   # lokalbot.com: public/ (served), generator/, worker/, HOSTING.md
├── Scripts/                   # build/, release/, test/, media/, cotyping/, dev/, ci/, tests/
├── Benchmarks/                # transcribe/, think/, autocomplete/, search/, voice/
├── Docs/                      # development/, releasing/, guides/, designs/, plans/, reports/, archive/
├── Assets/                    # README, social and video media
├── Video/                     # video projects (HyperFrames and filming scripts); archive/ for finished ones
├── LICENSES/                  # license texts for bundled third-party code
├── .agents/skills/lokalbot-cli/SKILL.md   # bundled into the app, symlinked on install
├── Vendor/                    # fetched runtimes and models (git-ignored; Scripts/build/fetch-*.sh)
└── Local/                     # personal scratch work (git-ignored)
```

## The Mac app

`LokalBot/` is layered first and grouped by feature inside each layer. A feature
keeps the same folder name in every layer it appears in: for example `Meetings/`,
`Speakers/`, `Timeline/`, `ScreenMemory/` and `ModelSetup/` exist under `Views/`,
`Models/` and `Services/`.

```
LokalBot/
├── LokalBotApp.swift, AppState*.swift, AppLifecycle.swift, HeadlessCommands.swift
├── Views/        # SwiftUI: Actions, Agent, Ask, Autocomplete, Components, Dictation, LiveRadar,
│                 #   Meetings, ModelSetup, Onboarding, People, Projects, ScreenMemory,
│                 #   SelectionActions, Settings, Timeline, Today, Window
├── Models/       # value types and presentation: Actions, App, Ask, Meetings, ModelSetup,
│                 #   Onboarding, People, Projects, ScreenMemory, SelectionActions, Settings,
│                 #   Speakers, Timeline, Today, Transcription
├── Services/     # Actions, AgentAccess, AgentMemory, App, AppControl, Audio, Calendar, Capture,
│                 #   Chat, CodingAgents, Companion, Diagnostics, Dreaming, Email, FileSearch,
│                 #   FollowThrough, Handoff, Health, HuggingFace, MeetingRadar, Meetings,
│                 #   ModelSetup, Notes, People, Permissions, PersonalModel, Projects, Recording,
│                 #   ScreenMemory, Search, SelectionActions, Speakers, Storage, Timeline, Transcription
├── Engines/      # TranscriptionEngine, TextEngine, ModelCatalog, ModelDownloadManager,
│                 #   LlamaServer, InferenceBroker, Subscription/ (ChatGPT and Claude plans)
├── Cotyping/     # Autocomplete: coordinator, AX focus tracking, input monitor, ghost text, Llama/
├── Dictation/    # system-wide voice typing
├── Agent/        # Agent Mode: pi RPC session, Bun runtime installer, approval flow
├── CLISupport/   # library access shared with lokalbot-cli and the MCP server
├── Support/      # design system, small helpers, hardware probes, download rescue
└── Resources/    # localizations, sample meeting, bundled model checks and assets
```

`LokalBotTests/` mirrors this: a test sits in the folder of the code it tests
(`LokalBotTests/Services/Meetings/MeetingMergeServiceTests.swift`). End-to-end,
replay, upgrade and benchmark tests that span features are in
`LokalBotTests/Integration/`, shared test helpers in `LokalBotTests/TestSupport/`,
and test data in `LokalBotTests/Fixtures/`. Run `xcodegen generate` after adding,
moving or removing a Swift file.
