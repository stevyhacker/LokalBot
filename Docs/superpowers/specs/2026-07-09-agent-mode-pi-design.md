# Agent Mode (pi) — Design

**Date:** 2026-07-09
**Status:** Approved (brainstorming complete; implementation plan pending)

## Summary

Add an **Agent Mode** pane to LokalBot: the [pi coding agent](https://github.com/earendil-works/pi)
(`@earendil-works/pi-coding-agent`) runs under the hood as an RPC subprocess, driven by a fully
native SwiftUI transcript UI, preconnected to the same local LLM engine that powers summaries and
Ask. The Models settings card is rebranded from "Summarization" to **"Main LLM engine"** — *used
for questions, meeting summaries, and Agent Mode*.

Decisions made during brainstorming:

| Decision | Choice |
|---|---|
| Agent scope | Library-first, any folder allowed (defaults to the LokalBot library; `lokalbot-cli` preinstalled as an agent skill; user can pick any workspace folder) |
| UI form | Main-window sidebar pane only (no floating overlay in v1) |
| Approval posture | Gate `write`/`edit`/`bash`; reads auto-allowed; per-session auto-approve toggle |
| Runtime distribution | Download on first enable (~49 MB), not bundled in the DMG |
| Integration approach | pi `--mode rpc` subprocess under Bun + native SwiftUI (validated end-to-end on this machine, pi 0.80.5 / Bun 1.3.14) |
| Engine | Reuse the summarization engine unchanged; display-only rename to "Main LLM engine" |

## Verified facts this design rests on

Measured/verified 2026-07-09 on Apple Silicon:

- pi 0.80.5 requires Node >= 22.19; it **runs correctly under Bun 1.3.14**, including `--mode rpc`
  (commands answered, events streamed, extension UI sub-protocol functional).
- Sizes: Bun binary 22.5 MB compressed / 60 MB on disk; pi + full npm dependency tree 26.1 MB
  gzipped / 165 MB on disk. Total download ≈ 49 MB, installed ≈ 225 MB.
- RPC protocol: JSONL over stdin/stdout, LF-only framing (clients must not split on U+2028/U+2029);
  commands `prompt`/`steer`/`follow_up`/`abort`/`new_session`/`get_state`/`set_model`/…;
  dialog sub-protocol `extension_ui_request` / `extension_ui_response` for extension-raised
  confirm/select/input, with optional timeouts.
- Extensions can intercept `tool_call` events and **block** tool execution, and can register
  custom providers via `pi.registerProvider(name, { baseUrl, api: "openai-completions", … })`.
- Isolation flags exist for everything we need: `--no-extensions -e <path>`, `--no-skills`,
  `--skill <path>`, `--no-prompt-templates`, `--no-approve`, `--session-dir <dir>`, `--offline`.
- **Privacy trap found and neutralized:** pi ships `enableInstallTelemetry: true` by default and
  performs update checks. `--offline` (= `PI_OFFLINE=1`) disables startup network operations;
  `PI_SKIP_VERSION_CHECK=1` additionally guards version checks. Both are part of the launch
  contract below.
- LokalBot's bundled `llama-server` already exposes an OpenAI-compatible `/v1` API on fixed
  loopback ports (`LlamaServer.shared` = 17872, 16 384-token context). `ProcessingPipeline.
  makeTextEngine` (ProcessingPipeline.swift:453) is the single engine switchboard.

## Architecture

```
┌────────────────────────── LokalBot.app ──────────────────────────┐
│  AgentView (SwiftUI pane)                                        │
│      │ observes                                                  │
│  AgentSessionController (@MainActor)                             │
│      │ commands/events (typed)                                   │
│  PiRPCClient ── Codable codec, id correlation, AsyncStream       │
│      │ JSONL over pipes (LF-only framing)                        │
│  PiProcess (actor) ── supervision à la LlamaServer               │
│      │ spawns                                                    │
│  <storage>/agent-runtime/bun … /pi/cli.js --mode rpc             │
│      │ loads only                                                │
│  Resources/pi/lokalbot-extension (provider + tool gate)          │
│      │ HTTP (localhost only)                                     │
│  llama-server :17872/v1  (same instance as summaries/Ask)        │
└──────────────────────────────────────────────────────────────────┘
```

### New subsystem `LokalBot/Agent/`

Small single-purpose types, following the Cotyping decomposition pattern:

- **`AgentRuntimeInstaller`** — downloads and verifies the runtime on first enable:
  - Artifact 1: pinned Bun binary zip from the oven-sh/bun GitHub release.
  - Artifact 2: **prebuilt pi bundle** (`lokalbot-pi-bundle-<piVersion>.tar.gz`): pi +
    lockfile-resolved `node_modules`, packed by a new `Scripts/build-pi-bundle.sh` and attached
    to LokalBot's own GitHub releases. One tarball, one checksum; no npm client runs on user
    machines.
  - A manifest checked into the app (versions + URLs + SHA256s) is the single source of truth.
    Checksum mismatch is a hard failure. Version bumps surface as an update button in the pane.
  - Installs into `<storage>/agent-runtime/{bun,pi}/`, executable bit set, same
    copy-out-of-Resources hygiene as `LlamaServer.installedBinary()` where applicable.
- **`PiProcess`** (actor) — spawns and supervises `bun <runtime>/pi/cli.js --mode rpc …`.
  Clones `LlamaServer.swift` hardening: PID marker JSON for orphan reclamation across hard
  quits, SIGTERM→SIGKILL teardown, stderr captured to a rotating log file, restart-on-crash
  signal to the controller. Owns stdin writes and stdout reads; framing splits on `\n` only,
  tolerates trailing `\r`, never uses line APIs that split on U+2028/U+2029.
- **`PiRPCClient`** — typed `Codable` models for commands, responses, and events; request-id
  correlation; events published as an `AsyncStream`. Also decodes `extension_ui_request` and
  encodes `extension_ui_response`.
- **`AgentSessionController`** (@MainActor, ObservableObject) — the pane's view model:
  - sends `prompt` (or `steer` while streaming), `abort`, `new_session`;
  - folds events into the transcript model;
  - routes gated tool calls to approval UI and answers them (policy lives here, not in JS);
  - owns workspace selection (default: library root; NSOpenPanel for other folders; recents);
  - lists/resumes sessions (`--session-dir <storage>/agent/sessions`; sessions are JSONL files);
  - resolves the LLM endpoint before launch (below) and re-launches pi on workspace change
    (pi's working directory is fixed per process).
- **Transcript model** — value types for user turns, streamed assistant text (`message_update`),
  collapsible thinking blocks, and tool cards (bash command + live output via
  `tool_execution_update`; unified diff for `edit`; path/size for `write`/`read`), errors.

### Bundled pi extension (`Resources/pi/lokalbot-extension/`)

TypeScript, loaded via `--no-extensions -e <path>` so the user's own `~/.pi` extensions never
load inside LokalBot (verified live: without this flag, personal extensions leak in).

1. **Provider registration** — `pi.registerProvider("lokalbot", { baseUrl: env.LOKALBOT_LLM_BASE_URL,
   api: "openai-completions", apiKey: env.LOKALBOT_LLM_API_KEY ?? "lokalbot", models: [{ id:
   env.LOKALBOT_LLM_MODEL, contextWindow: env.LOKALBOT_LLM_CTX, cost: { input: 0, output: 0,
   cacheRead: 0, cacheWrite: 0 }, … }] })`, with
   conservative `compat` flags (`supportsDeveloperRole: false`, `supportsReasoningEffort: false`)
   for llama.cpp/Ollama servers. Accurate `contextWindow` matters: it drives pi's auto-compaction.
2. **Tool gate** — `pi.on("tool_call", …)` intercepts `write`, `edit`, `bash` (reads pass through)
   and raises `ctx.ui.confirm` with a JSON-encoded payload (tool name + args) in the message field.
   Swift parses it, renders a rich approval card, and answers. No timeout — waits for the user.
   Auto-approval decisions are made on the Swift side (instant programmatic answers), keeping all
   policy in one place.

### Launch contract

```
env:  LOKALBOT_LLM_BASE_URL, LOKALBOT_LLM_MODEL, LOKALBOT_LLM_CTX, LOKALBOT_LLM_API_KEY?,
      PI_SKIP_VERSION_CHECK=1, PATH=<Contents/Helpers>:$PATH
cwd:  <selected workspace folder>
argv: bun <runtime>/pi/cli.js --mode rpc
        --provider lokalbot --model <id>
        --no-extensions -e <bundle>/Resources/pi/lokalbot-extension
        --no-skills --skill <bundle>/Resources/lokalbot-cli   (library-aware skill, already bundled)
        --no-prompt-templates --no-approve
        (note: --no-context-files is deliberately NOT passed — AGENTS.md/CLAUDE.md discovery in
         user projects is useful and read-only; project-local *code* loading is what --no-approve blocks)
        --session-dir <storage>/agent/sessions
        --offline
```

### Engine resolution (preconnection)

Mirrors `ProcessingPipeline.makeTextEngine(_:server:)` switching on `settings.summarizerBackend`:

- `.builtIn` → `LlamaServer.shared.ensureRunning(modelAt: catalogEntry)` →
  `http://127.0.0.1:17872/v1`, model id = catalog entry id, ctx 16 384. Shares the instance the
  summaries use — no extra RAM.
- `.ollama` → user's Ollama base URL (`/v1`), configured model.
- `.openAICompatible` → user's base URL/model/key as-is.
- `.appleIntelligence` → **not supported** (no HTTP endpoint). The pane explains this and offers
  a one-click switch to a built-in model for agent sessions.

## UI

**Sidebar:** new `NavSection.agent` ("Agent"), mounted in `MainWindowView` alongside Ask.

**Pane layout:**
- **Session tabs** — each tab owns an independent `AgentSessionController` and pi subprocess, so
  work continues when another tab is selected. The plus button starts a concurrent session and
  every tab has its own close button; closing one tab shuts down only that process.
- **Header** — workspace picker ("Meeting Library" default, recents, "Choose…"), health dot
  (runtime installed · pi alive · LLM reachable), and the per-session **auto-approve toggle**
  (off by default).
- **Transcript** — native rendering in `ChatTranscriptView`'s editorial style. Tool cards
  collapsed by default; expand for full output/diff. Live-streaming bash output while running.
- **Approval cards** — inline in the transcript on the pending tool card: **Allow once /
  Allow for session / Deny**. "Allow for session" is scoped per tool name.
- **Composer** — single input; Enter = prompt, or steering message while the agent is streaming
  (`streamingBehavior: "steer"`); Stop button = `abort`.
- **First-run** — explainer card: what Agent Mode is, "runs pi, a local coding agent, powered by
  your Main LLM engine — everything stays on this Mac", Download button (~49 MB) with
  `ModelDownloadManager`-style progress, then ready. Feature is entirely opt-in.

## Settings & rebrand

- `ModelsView.swift` "Summarization" card → **"Main LLM engine"**, caption *"Used for questions,
  meeting summaries, and Agent Mode."* Same backend `Picker`, same catalog rows.
- Copy updates: `SettingsView.swift` `processingSection` (line ~231), `TextEngineError.noModel`
  message ("No model selected for the main LLM engine. Pick one in Settings → Models.").
- **Display-only rename:** stored keys (`summarizerBackend`, `builtInModelID`) and Swift symbols
  keep their names so existing users' settings survive. Symbol renames are a later pure refactor
  if desired.
- New "Agent Mode" settings group (Models or Advanced pane): runtime status (installed version,
  update, remove), default workspace, link to Privacy explainer.

## Privacy & safety

- **LLM traffic is localhost-only by construction** for the built-in backend; Ollama/OpenAI-compat
  endpoints are user-chosen, same as today for summaries.
- `--offline` + `PI_SKIP_VERSION_CHECK=1` neutralize pi's install-telemetry ping and update checks.
  The runtime download itself (GitHub releases) is user-initiated, matching the Hugging Face
  model-download posture; the Privacy pane copy lists it.
- **Honest disclosures** in the enable card and Privacy pane:
  1. Approved shell commands run with the user's full permissions and may themselves access the
     network — the approval gate exists precisely so each such action is user-initiated.
  2. Agent sessions are plaintext JSONL under the storage root — same posture as transcripts and
     summaries today.
- `--no-approve` prevents pi from loading project-local extensions/skills from whatever folder the
  agent is pointed at (blocks the "malicious repo carries a pi extension" vector).
- Default posture: reads auto-allowed; `write`/`edit`/`bash` gated; auto-approve is per-session,
  never persisted.

## Error handling

Each failure mode gets a specific pane state, not a generic error:

| Failure | Behavior |
|---|---|
| Runtime download fails | Retry button; checksum mismatch = hard fail with distinct copy |
| pi process crashes | Banner + restart button; session JSONL survives, `--session` resumes it |
| llama-server not up | Auto `ensureRunning`, "warming up model…" spinner |
| No model / Apple Intelligence backend | Inline prompt to download/select a built-in model |
| RPC drift | Prevented, not handled: pi version pinned in the manifest; upgrades are deliberate and test-gated |

## Testing

- **Unit** (pure, no processes): JSONL framing codec (LF-only, U+2028 inside strings, `\r\n`
  tolerance); event→transcript folding; approval policy state machine; installer manifest and
  checksum verification.
- **Integration** (hermetic): launch the real Bun+pi in `--mode rpc` against a stub
  OpenAI-compatible HTTP server serving canned completions inside the test process. Asserts the
  full launch contract: provider registration, prompt round-trip, tool-gate confirm round-trip.
  Skips when the runtime isn't installed locally.
- **UI tests:** synthetic transcript fixtures through the pane (existing XCUITest harness).
- **E2E:** new headless flag `--agent "<prompt>"` beside `--chat` in `HeadlessCommands.swift`,
  wired into `Scripts/test/e2e.sh`, skipping when the runtime is absent.

## Out of scope (v1)

- Floating overlay / global hotkey summon (revisit after the pane ships).
- Encrypting pi session files at rest.
- pi model switching UI beyond the Main LLM engine selection (pi's `/model` surface is unused).
- Pruning unused provider SDKs from the pi bundle (~40 MB of the 165 MB installed; risky against
  pi's shrinkwrap — reconsider only if size complaints materialize).

**Amendment (2026-07-10, recorded at final review):** v1 also shipped without these spec'd
features — session resume/picker, workspace recents, the Agent Mode settings group (runtime
status/remove), Privacy-pane disclosure copy, collapsible thinking blocks, provider compat
flags, and orphan-pi PID reclamation (tracked follow-up).
