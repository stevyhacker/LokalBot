# Configuring LokalBot from the terminal

Date: 2026-10-17. Status: design. The four open decisions were settled on
2026-10-17; see [Decisions](#decisions).

## Goal

Coding agents (Claude Code, Codex, Cursor) and people in a terminal should be
able to inspect and change every LokalBot setting, and trigger the app's common
actions, through `lokalbot-cli`:

- JSON output an agent can parse.
- A schema it can discover.
- Changes that take effect in the running app right away.

The constraint: AGENTS.md requires separate consent boundaries for
meeting-library access, screen memory, remote inference origins, and Agent
Mode actions. A configuration CLI must not become a way around them.

## What exists today

### The CLI reads the library and nothing else

`lokalbot-cli` (`CLI/`, shared logic in `LokalBot/CLISupport/`) has these
commands: `list`, `get`, `search`, `actions`, `people`, `path`, `mcp`, and
`install-skill`.

- Every command except `install-skill` checks `AgentAccessGate`.
- PRIVACY.md ("External-agent access") and the Agent CLI section in Settings
  describe the CLI as read-only.
- The bundled skill tells agents never to change consent markers.

### Settings are one JSON blob in UserDefaults

- `AppSettings` is JSON-encoded under `lokalbotv3.settings` in the app's
  domain:
  - `me.dotenv.LokalBot` for the release app.
  - `.dev` for LokalBot Dev.
  - The `me.dotenv.LokalBot.local-build` suite for Xcode builds.
- It has 135 coding keys. Some of them are legacy or bookkeeping keys, such as
  `languageHint`, `meetingSettingsVersion`, `cotypingSettingsVersion`,
  `dreamingFirstEligibleDayKey`, and `chatGPTPlanNoticeAcknowledged`.
- `SettingDescriptor.all` gives Settings search a title, category, and aliases
  for 86 of those keys, and for 9 entries that are not in the blob:
  - `models`, `permissions`, `agentAccess`, `screenMemoryAccess`, and others.
- The other 49 keys have no descriptor, for example:
  - remote server URLs and approved origins;
  - `cotypingMaxWords`;
  - `dayDigestHour`;
  - `speechVoice`.
- **Ownership:** `SettingsStore` owns the value at runtime and saves it 250 ms
  after each change.
- **Side effects:** `AppState.settings` is the UI binding. Its `didSet` sends
  each change to the subsystems that apply it live:
  - the detector;
  - dictation and autocomplete event taps;
  - the Ask hotkey;
  - the digest, Dream, export, and routine schedulers;
  - screen capture;
  - coding-agent ingestion;
  - model roles.

  Writing `settingsStore.current` directly skips all of that.
- **Value types:** several enums use display strings as raw values. For
  example, `AutoRecordMode.automatic` is stored as `"Record automatically"`.
  Others use case names. Shortcuts, the Granite model, and custom models are
  structured values.

### State outside the blob

| State | Where | Written by |
| --- | --- | --- |
| API keys (`openai-compatible-api-key`, `remote-transcription-api-key`, `autocomplete-server-api-key`) | Keychain, service = bundle id | Settings → Models |
| ChatGPT plan registration and tokens | Keychain | OAuth sign-in sheet |
| Encryption keys (screenshot, chat, speaker identity, autocomplete learning) | Keychain | Created once; never user-set |
| Meeting-library grant | `control/agent-access-enabled`; its contents are the grant identity | Privacy toggle (`AgentAccessManager`) |
| Screen-memory grant | `control/screen-memory-access-enabled`, JSON scope; an **empty file means all retained history** | Privacy toggle and history picker |
| People and project curation | `people/curation.json`, `projects/tracked.json` (loaded once at launch) | People and Projects workspaces |
| Dream pins, saved moments, speaker profiles, learned text | Library root, some encrypted | Their own screens |
| Agent Mode approval mode | `lokalbotv3.agent.approvalMode` | Agent composer; raising it asks for confirmation |
| Launch at login | `SMAppService` (must be called by the app process) | General |
| Automatic update checks | Sparkle `SU*` keys | General |
| Downloaded models | `<root>/models`, app-support caches | Models |
| TCC permissions | macOS | Only the person, in System Settings |

### The CLI cannot change a running app

- Nothing in the app observes UserDefaults written by another process.
- The app has none of: URL scheme, AppleScript dictionary, App Intents, XPC
  service, or socket.
- The only channel from the CLI to the app is a file-system watcher on
  `control/`. It is used for `agent-wake`, which starts the model server for
  `ask_library`, and it runs only while meeting access is on.
- The headless flags (`LokalBot --digest`, `--dream`, `--process`, …) start a
  second full `AppState`. While the GUI owns a local model server, the ones
  that need it (for example `--digest` with the built-in Think model) fail with
  "another LokalBot instance owns this local server".
  A second GUI launch only activates the running copy and passes nothing along.

### Compiling `AppSettings` into the CLI is impractical

`AppSettings` references about 35 types. Several of them live in engine files
(`TranscriptionModelChoice`, `ThinkReasoningLevel`, `CotypingBackend`,
`AppTheme`), so the dependency closure is about 157 app files, including
FluidAudio, WhisperKit, LlamaCore, and SwiftUI.

## Why `defaults write` is not the answer

Agents with a shell will try it. All of these were checked against the code:

1. **It doesn't apply, and it gets reverted.** The running app neither sees the
   change nor applies its side effects. It saves its in-memory copy on the next
   in-app change and again at quit (`SettingsStore.flush()`).
2. **A partial blob changes privacy-relevant defaults.** The tolerant decoder
   reads missing keys as *legacy* values:
   - a missing `autoRecordMode` becomes **Record automatically**;
   - a missing `dictationIntent` becomes Compose;
   - a missing `dictationUseScreenContext` becomes **on**.

   An agent that writes `{"appTheme": "dark"}` would turn on automatic
   recording.
3. **It skips the couplings the UI enforces.** For example:
   - turning tracking off also resets the capture mode;
   - export and routines need a folder;
   - Dreaming goes through `setDreamingEnabled`;
   - the Ask shortcut reverts itself when registration fails.
4. **It deletes data without review.** The UI sends a shorter `retentionDays`,
   or turning off `keepOCRTextForever`, through a reviewed cleanup
   (`RetentionSettingsControls`). The scheduled prune reads the current value
   and deletes whatever falls outside it. A raw write skips the review.
5. **Touching a marker can grant everything.** An empty
   `screen-memory-access-enabled` is read as the legacy unscoped grant, so
   `touch` grants all retained history.

A supported path is safer than leaving agents to improvise.

## Proposal

### Principles

1. **The app is the only writer.** The CLI sends requests. The app validates
   them with the real types and applies them through `AppState.settings`, so
   side effects, couplings, and saving behave exactly as they do in Settings.
2. **One registry describes every setting.** CLI help, `config schema`, MCP
   tools, and Settings search all read it, and a test keeps it complete.
3. **Consent stays with the person.** An agent may change preferences after
   the person allows it. A change that would widen what is captured, read, or
   sent asks for approval in the app. Grants themselves can never be set from
   the terminal.

### 1. Settings registry

Add a Foundation-only `SettingSpec` table in `LokalBot/CLISupport/`, compiled
into both targets:

```swift
struct SettingSpec {
    let key: String              // the coding key, e.g. "autoRecordMode"
    let category: SettingCategory
    let title: String            // shared with Settings search
    let aliases: String
    let summary: String          // one line for `config describe`
    let kind: Kind               // bool, int(range), double(range), text, url, path,
                                 // list(csv), enumeration([token: storedRawValue]), json(schema)
    let tier: Tier               // .preference, .consent(Widening), .readOnly
    let applies: Applies         // .live, .nextUse, .relaunch
}
```

- **Keys:** the canonical key is the stored coding key. It is already stable,
  it already identifies Settings search entries (`settings.<key>`), and it
  needs no second naming scheme. `config search "dark mode"` reuses
  `SettingsSearchRanker` and the aliases, so agents can find keys by plain
  words.
- **Enum values:** tokens are the Swift case names (`automatic|ask|manual`),
  mapped to stored raw values. Agents never see display strings.
- **`SettingDescriptor` builds on it:** it takes its title, category, and
  aliases from the registry. The nine descriptors that are not stored settings
  stay as navigation entries.
- **Coverage tests** (in the app test target):
  - every key in the encoded `AppSettings()` has a spec or is marked
    read-only;
  - each spec's default equals the encoded default;
  - each enum's tokens round-trip through `allCases`;
  - adding a setting without a spec fails the build's tests.

### 2. Live control channel

**A Unix domain socket served by the running app**

- **Location:** `<libraryRoot>/control/app.sock`. The folder is 0700 and the
  socket 0600.
- **Server:** an `NWListener` on a Unix endpoint, started on the interactive
  launch path.
- **Protocol:** line-delimited JSON-RPC 2.0, reusing the `JSONValue` codec
  from `MCPProtocol`. This is the app-hosted door the 2026-07-10 agent-access
  design left a provider seam for.
- **Peer check:** `getsockopt(LOCAL_PEERCRED)` must match the app's uid.
  `LOCAL_PEERPID` plus `proc_pidpath` names the caller in approval prompts and
  in the audit log ("lokalbot-cli, started by claude").
- **Applying a change:** each request is applied on the MainActor:
  1. JSON round-trip the current `AppSettings`.
  2. Replace the requested keys.
  3. Decode with the real decoder.
  4. Reject the request if the decoder flags the key in
     `corruptedSettingsKeys`, or if the value was clamped. Report both cases.
  5. Run the coupling rules.
  6. Assign `app.settings`.
- **Couplings move to AppState:** the rules now in `SettingsView` (tracking
  versus capture mode, folders required, Dreaming, Ask shortcut revert) become
  `AppState` methods that both the UI and the socket call. That also takes
  logic out of view code.
- **Path length:** `sun_path` is limited to 104 bytes. Test roots under
  `$TMPDIR` can exceed that. In that case, bind under a short per-uid
  directory and record its path in `control/app.sock.path`.

**When the app isn't running: launch it in the background**

Every read and write goes through the running app. There is no offline edit
path, so the decoding, coupling, and approval rules live in one place. When
no app answers, the CLI starts one:

1. **Check the grant first.** The CLI reads `control/settings-control-enabled`
   itself. If the grant is off, it returns `[settings_access_disabled]` and
   launches nothing.
2. **Check whether a copy is already running.** The CLI probes
   `.instance.lock` with a non-blocking `flock`:
   - **Lock held:** a GUI is running or starting. The CLI waits for the socket.
   - **Lock free:** the CLI launches the app.
3. **Launch its own bundle.** The CLI launches the `.app` that contains it,
   resolved through symlinks the way `AppIdentifiers` resolves identity:

   ```
   /usr/bin/open -g -j <enclosing LokalBot.app> --args --lokalbot-background-launch
   ```

   - `-g -j` keeps the app in the background and hidden.
   - It is never `open -a LokalBot`, which could start a different copy
     (Dev, a local build) with another library.
   - A CLI that is not inside a bundle returns `[app_not_running]` with a hint.
4. **Wait for the socket.** The CLI polls the socket up to `--launch-timeout`
   (default 30 s), then sends the request.
5. **The app stays running** afterwards as a normal menu-bar app.

**What the background-launch flag does in the app**

- The new flag is not a headless command. The process is the normal GUI: it
  takes the instance lock and starts its usual services (meeting detection,
  activity tracking, schedulers), exactly as the person configured them.
- `AppDelegate` treats it like a login launch: menu-bar-only installs start
  silently, through `DockPolicy.beginLaunchSuppression()`, instead of opening
  the main window. Dock-mode installs launch hidden (`open -j`).
- The listener starts once `AppState` and its settings are ready. It does not
  wait for the library to finish loading, because settings don't depend on it.

**Approvals in a background app**

- A widening request posts a notification and appears in the menu bar menu.
- If notifications are off, the app opens its approval window directly. An
  approval needs the person, so bringing that one window forward is
  intentional.

**Version skew**

- Every request carries the protocol version, and the app refuses one it
  does not know. `hello` returns the app and protocol versions.
- A Sparkle update replaces the bundle while the old app keeps running. In
  that case the CLI returns `[app_outdated]`: "Restart LokalBot to finish the
  update".
- A running copy that holds the lock but never opens a socket (a build from
  before this feature) gets the same answer.

**Opting out**

`--no-launch` returns `[app_not_running]` instead of starting the app, for
scripts that must not start background services.

**Alternatives considered**

| Option | Why not |
| --- | --- |
| Command files in `control/`, reusing the watcher | No synchronous reply (the CLI would poll result files), cleanup is error-prone, there is no peer identity, and the watcher only runs while meeting access is on |
| XPC Mach service | Needs launchd or `SMAppService` registration; heavy for a non-sandboxed menu-bar app |
| URL scheme | One-way, brings the app forward, returns no result |
| App Intents / Shortcuts | Good later for Shortcuts users and could be generated from the registry, but `shortcuts run` is clumsy for agents and needs a typed intent per action |
| `defaults write` + KVO in the app | Hazards 2–5 above remain, and there is still no reply or validation |
| Offline edits through the app binary (an early-exit `--settings-request` flag) | A second code path, and changes that need approval would be refused because nobody is there to approve them. Replaced by background launch |

### 3. Authorization and consent tiers

**A new, separate grant**

- Settings → Privacy → External agents gets a third toggle: "Allow external
  agents to change LokalBot settings". It is off by default.
- Only the app writes its marker, `control/settings-control-enabled`.
- It does not imply meeting or screen access, and neither of those implies
  it.
- Reading values (`config get/list`, `status`) needs this grant, because
  values include personal text such as the writing profile, digest
  instructions, and folder paths. URL user info and queries are redacted with
  `DiagnosticsSettingsSanitizer`.
- `config schema`, `describe`, and `search` show no values and need no grant.
  They are answered from the registry in the CLI, without launching the app.

**Tiers**

| Tier | Rule | Examples |
| --- | --- | --- |
| **Preference** | Applied live once the grant is on; logged | `appTheme`, `textSize`, `appLanguage`, `menuBarOnly`, `stopDebounceSeconds`, `autoTranscribe`, `autoSummarize`, `noteTemplate`, `summaryLanguage`, `transcriptionLanguage`, `transcriptionPrompt`, diarization, `echoCancellation`, `speechVoice`, `speechSpeed`, budgets and reasoning levels, digest, Dream, export, and routine hours, `dayDigestCustomPrompt`, autocomplete tuning (`cotypingMaxWords`, debounce, accept keys, style and profile), dictation trigger, shortcut, output, and overlay, local model selection, launch at login, update checks |
| **Consent-widening** | Narrowing is a preference. Widening is applied only after the person approves it in the app | **Capture:** `trackingEnabled` on, `screenContextCaptureMode` raised, `meetingVisualContextEnabled`, `keepOCRTextForever` on, removing any capture, autocomplete, or coding-agent exclusion. **New sources:** `calendarDetectionEnabled`, `useCalendarAgenda`, coding-agent readers, `rememberSpeakersOnMac`, `dictationRetainAudio`. **Recording others:** `autoRecordMode` → `automatic`. **Global input:** `cotypingEnabled`, `dictationEnabled`, `quickRecallEnabled`. **Context sent to models:** the `cotypingUse*` and `dictationUse*` context switches, integrated terminals. **Data off the Mac:** adding an origin to any of the three approval lists, `openRouterDataPolicy` → `accountPolicy`, setting an API key. **Files outside the library:** export and routine folders. **Deletion:** shortening `retentionDays` (approval shows the existing retention review) |
| **Never from the terminal** | Read-only, or not shown | The three access markers, Agent Mode approval mode, reading secrets back, encryption keys, TCC permissions, `lokalbot.uiTest.*` and the storage/suite overrides, ChatGPT plan sign-in (the CLI can open the sheet), bookkeeping keys |

**Notes on the tiers**

- **Server URLs:** changing a backend or base URL is a preference when the
  target is loopback or already approved. Nothing is sent to an unapproved
  origin, so approving that origin is the step that grants consent, and it
  uses the existing approval disclosure.
- **API keys:** setting one needs approval even for an approved origin.
  Swapping in another account's key would send the person's content to that
  account's request logs.

**Approval flow**

1. A widening request returns
   `{"status": "needs_approval", "request_id": "…"}`.
2. The app posts a notification and shows an approval card naming:
   - the caller;
   - the exact change;
   - the disclosure copy Settings already uses for that choice.
3. `--wait [seconds]` blocks until the request is approved, denied, or
   expires. Exit codes distinguish the three.
4. A multi-key import lists every change on one card.
5. Requests expire after a few minutes and cannot be approved in bulk later.

**Audit and undo**

- Every change applied through the socket appends
  `{time, caller, key, previous, new, tier}` to
  `diagnostics/settings-changes.jsonl` and to `AppLog`.
- Settings → Privacy → External agents lists recent agent changes with
  **Undo**.

**Limits**

Any process running as the person can already rewrite their preferences, and
PRIVACY.md already says an enabled tool runs as your macOS user. The tiers
are a consent and visibility boundary for the supported path. They are not a
sandbox against malicious local code. The doc and the Settings copy should
say that plainly.

### 4. Command surface

```bash
lokalbot-cli status                          # app running?, identity, version, recording/processing,
                                             # model readiness, permission status, grants
lokalbot-cli config schema                   # JSON Schema for every key (no values)
lokalbot-cli config search "dark mode"       # → appTheme
lokalbot-cli config describe autoRecordMode  # type, tokens, default, tier, applies, summary
lokalbot-cli config list [--category recording] [--changed] [--table]
lokalbot-cli config get noteTemplate
lokalbot-cli config set noteTemplate=lecture summaryLanguage=english [--dry-run]
lokalbot-cli config set trackingEnabled=true --wait 120    # needs approval in the app
lokalbot-cli config reset cotypingMaxWords   # back to the default
lokalbot-cli config export > lokalbot-settings.json
lokalbot-cli config import lokalbot-settings.json --dry-run  # diff + tiers, then apply
lokalbot-cli secret set openai-compatible --stdin           # write-only; needs approval
lokalbot-cli open settings dictationShortcut  # Settings, focused on that control, for what
                                              # only the person can do (permissions, sign-in)
```

- **Launching:** any command that needs values starts the app in the
  background when it isn't running. `--no-launch` and `--launch-timeout <s>`
  apply to every such command.

- **Atomic:** `set` applies all of its pairs or none.
- **`--dry-run`:** prints the diff, the tier of each change, and how each
  takes effect.
- **Output:** JSON by default, `--table` for people, as in the existing
  commands.
- **Errors:** stable codes in the style of `[access_disabled]`:
  - `[settings_access_disabled]`
  - `[unknown_key]`
  - `[invalid_value]`
  - `[read_only]`
  - `[needs_approval]`
  - `[denied]`
  - `[expired]`
  - `[app_not_running]`: `--no-launch` was given, the launch failed, or the
    CLI is not inside an app bundle
  - `[app_outdated]`: the running app predates the CLI's protocol version
- **Results:** each result reports `previous`, `effective` (after couplings),
  `applies`, and warnings. For example: "Accessibility is not granted;
  capture starts once it is."

### 5. Actions beyond settings (not in the first release)

The first release is settings, secrets, `status`, and `open`. The same socket
can later carry the actions agents ask for most. Running them in the live app
fixes today's headless conflict with the model server.

| Method | Today |
| --- | --- |
| `recording.start` / `recording.stop` | `AppState.startRecording` / `stopRecording` |
| `meeting.process <id> [--no-summary]`, `meeting.resummarize <id>` | `--process` (second AppState) |
| `digest.run [--day]`, `dream.run [--day]`, `health.run`, `diagnostics.export` | Headless flags; with the built-in Think model, `--digest` and `--dream` fail while the GUI owns llama-server |
| `models.list` / `download` / `delete` / `check` | Settings → Models |
| `ui.open settings --tab models`, `ui.open meeting <id>` | Settings search and deep links |

Edits to library content are out of scope for this design:

- action status;
- People rename, merge, or hide;
- project tracking;
- speaker names.

They would need their own decision and probably their own grant scope. The
skill keeps telling agents never to write into the meetings folder.

### 6. MCP and skill

- **MCP:** add `get_status`, `search_settings`, `describe_setting`,
  `get_settings`, and `set_settings` to `lokalbot-cli mcp`:
  - they use the same registry, grant, and tiers;
  - a widening change returns `needs_approval` with a request id;
  - `get_settings_request` reports its outcome.
- **Skill:** add a "Configure LokalBot" section to
  `.agents/skills/lokalbot-cli/SKILL.md`:
  - run `describe` before `set`;
  - never use `defaults write` or edit `control/`;
  - tell the person when approval is waiting in the app;
  - do not retry a denied request.

## Implementation status

Phase 1, with the registry part of Phase 0, is implemented on branch
`ccr-c1452663-cvoqi1`:

- `SettingRegistry` covers all 130 settings keys; the 5 bookkeeping keys are
  listed in `internalKeys`. `SettingRegistryTests` checks it against
  `AppSettings`. `SettingDescriptor` keeps its own table for now; a test keeps
  their titles and categories equal.
- The settings grant, the control socket, background launch, and
  `config schema|describe|search|list|get`, `status`, and `open` are in place.
- Moving the UI couplings into `AppState` is deferred to Phase 2, because
  only writes need them.

## Phases

| Phase | Scope | Size |
| --- | --- | --- |
| 0 | Registry and coverage tests; `SettingDescriptor` built from it; UI couplings moved into `AppState` methods. No behavior change | Medium, mostly mechanical (135 keys) |
| 1 | `config schema/describe/search` (no grant, no app). Settings grant toggle and marker; control socket with `hello` and the peer check; background launch; `config list/get`, `status`, and `open` | Medium |
| 2 | Preference writes, audit log, Undo list; PRIVACY.md, DEVELOPMENT.md, Settings copy, and skill updated | Medium |
| 3 | Approval requests (notification, menu bar, approval window), `--wait`, `secret set`, retention review through approval | Medium |
| 4 | MCP tools; optional App Intents generated from the registry | Small–medium |
| Later | Actions over the socket (recording, processing, digest, Dream, models); headless flags forward to a running app. Only if wanted after settings ship | Medium–large |

## Tests

- **Unit:**
  - Registry coverage, defaults, and token round-trips.
  - `SettingsChangeApplier` for every kind:
    - unknown, read-only, and invalid values;
    - clamped values reported;
    - partial input never resets other keys.
  - Tier classification for every widening rule, including list removals and
    capture-mode ordering.
  - Coupling rules shared with the UI.
  - Peer-credential check.
- **Integration:**
  - Start the embedded CLI against a socket served in the test host, as
    `MCPServerIntegrationTests` does.
  - In `Scripts/e2e.sh`, with a temporary `LOKALBOT_STORAGE_ROOT` and
    `LOKALBOT_DEFAULTS_SUITE`:
    - background launch from a stopped app;
    - a second CLI call reusing the running copy;
    - `--no-launch` returning `[app_not_running]`;
    - a disabled grant returning `[settings_access_disabled]` without
      launching anything.
  - Launch-flag unit tests: the background-launch flag is not parsed as a
    headless command, and it suppresses the main window.
- **Privacy regressions:**
  - No CLI path writes a `control/` marker.
  - A widening change never applies without approval.
  - A retention reduction never deletes without review.
  - A denied or expired request leaves settings byte-identical.

## Documents to update when this ships

- **PRIVACY.md ("External-agent access"):** the CLI and MCP still read the
  library only with Agent Access on. With a separate toggle they can change
  preferences, and widening changes need approval in the app.
- **DEVELOPMENT.md:** Agent CLI & MCP, Headless flags.
- **SettingsView Agent CLI copy:** "Read-only by design" changes.
- **`.agents/skills/lokalbot-cli/SKILL.md`:** see the MCP and skill section.

## Decisions

Settled on 2026-10-17:

1. **Grant model:** a separate "Allow external agents to change LokalBot
   settings" toggle, independent of the meeting and screen toggles.
2. **Widening changes:** allowed from the terminal, applied only after the
   person approves them in the app.
3. **App not running:** the CLI launches the app in the background and sends
   the request to it. There is no offline edit path.
4. **Scope:** mostly settings. The first release is settings, secrets,
   `status`, and `open`. Actions come later if wanted. Library edits are out
   of scope.
