# Project layout

Part of the [development guide](../../DEVELOPMENT.md).

```
repository/
├── project.yml                            # XcodeGen manifest: LokalBot + LokalBot Dev + tests + lokalbot-cli
├── Scripts/                               # fetch-llama, e2e, ui-tests, DMG + appcast release tooling
├── CLI/                                   # lokalbot-cli ArgumentParser entry + Commands/ (brief/list/get/search/ask/reply/actions/people/personal-context/search-files/path/setup/config/secret/models/permissions/status/doctor/restart/open/mcp/install-skill)
├── .agents/skills/lokalbot-cli/SKILL.md   # bundled into the app, symlinked on install
└── LokalBot/
    ├── LokalBotApp.swift   # @main: Window + MenuBarExtra + Settings scenes, headless flags
    ├── Models/             # Meeting, Transcript, AppSettings, NoteTemplate, SummaryLanguage, *Language
    ├── CLISupport/         # SessionLookup + SessionFormatter (shared with the CLI)
    ├── Services/           # detection, recorders, ProcessingPipeline, StorageManager, SearchIndex/
    │                       #   EmbeddingIndex, ActivityTracker/ScreenshotService (OCR), diarization,
    │                       #   PermissionManager, AppUpdateManager, AppLog, HuggingFace/, Chat/ (agent + tools)
    ├── Engines/            # TranscriptionEngine, TextEngine, AppleIntelligenceEngine,
    │                       #   ModelCatalog / ModelDownloadManager / LlamaServer / InferenceBroker
    ├── Support/            # prompt budgeting, download rescue, DeviceInfo/HardwareCapabilityProbe, ranker
    ├── Cotyping/           # CotypingCoordinator + AX focus tracker, CGEventTap input monitor,
    │                       #   ghost-text overlay, synthetic inserter, prompt renderer + output normalizer
    ├── Agent/              # Agent Mode: pi RPC session, Bun runtime installer, approval flow
    └── Views/              # Today, MeetingWorkspace, Ask, Timeline, Autocomplete, Settings, Agent, Onboarding
```
