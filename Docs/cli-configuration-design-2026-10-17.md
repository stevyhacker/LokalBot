# Configuring LokalBot from the terminal

Date: 2026-10-17, extended 2026-10-18. Status: design; Phase 1 implemented.
Decisions are recorded in [Decisions](#decisions) and
[Decisions (agent-led setup)](#decisions-agent-led-setup).

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

The end goal (added 2026-10-18): a person tells their agent "install LokalBot
and set it up for me", and the agent does everything except the few steps that
macOS and these consent boundaries reserve for the person. See
[Agent-led install and setup](#agent-led-install-and-setup).

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

- Settings → Privacy → External agents gets another toggle: "Allow external
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

1. A request with a widening change waits, whole, for the person. It returns
   `[needs_approval]` with the request in `details`: its `id`, every change,
   and, for a shorter retention policy, what the cleanup deletes. An
   identical request still waiting is reused, and at most five wait at once.
2. The app posts a notification and shows an approval card naming:
   - the caller;
   - every change in the request, marking the widening ones;
   - each widening setting's description.
3. `--wait <seconds>` (up to 300) polls `settings.request` until the request
   is approved, denied, or expires, and `config request <id>` asks later.
   Exit codes: 0 approved, 3 still waiting, 4 denied, 5 expired.
4. A multi-key import lists every change on one card.
5. Requests expire after five minutes and cannot be approved in bulk later.
   Turning the settings grant off declines every request still waiting.
6. Approving re-plans the request against the settings as they are then, and
   asks for the permissions the Settings controls would. A shorter retention
   policy applies only the cleanup the card showed; if that changed, the card
   shows the new review and waits.

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
printf %s "$KEY" | lokalbot-cli secret set openai-compatible  # key on stdin; needs approval
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
  - `[unknown_request]`, `[too_many_requests]`, `[unknown_secret]`
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

## Agent-led install and setup

Added 2026-10-18. Phases 2 and 3 make settings writable and approvable. This
section adds what an agent needs to take a person from "not installed" to
"fully working".

### What the person still does

macOS and the consent boundaries leave a few clicks to the person:

1. **Gatekeeper.** The first-open confirmation, if the download is quarantined.
   Notarized builds show it once.
2. **Setup approval.** One approval in LokalBot: let this agent change
   settings, plus any read access the person chooses to add.
3. **Consent review.** One review of the setup's consent changes, such as
   capture level, calendar, automatic recording, or a remote server. They are
   combined on one card.
4. **macOS permissions.**
   - Allow in the prompts for Microphone, Calendar, and Notifications.
   - Toggles in System Settings for Accessibility, Screen Recording, and Input
     Monitoring, with LokalBot's existing drag guidance.
   - A relaunch after Accessibility or Input Monitoring.

Everything else is the agent's.

### The journey

```bash
# 1. Install (agent)
brew install --cask stevyhacker/tap/lokalbot
CLI=/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli

# 2. Ask to set up (the person approves once in LokalBot)
$CLI setup start --wait 300        # opens LokalBot; onboarding shows the agent's request

# 3. Agree a plan with the person, then apply it
$CLI setup plan --preset recommended > plan.json   # defaults checked against this Mac
$CLI setup apply plan.json --wait 300              # preferences apply; consent changes go to one review card

# 4. Models (agent)
$CLI models download --preset recommended
$CLI models status                                 # poll until meeting-ready

# 5. Permissions (the person clicks; the agent guides and checks)
$CLI permissions                                   # what enabled features need, and what is granted
$CLI permissions request microphone                # shows the macOS prompt
$CLI permissions request accessibility             # opens System Settings with LokalBot's drag guidance
$CLI restart                                       # when Accessibility or Input Monitoring needs it

# 6. Finish and verify (agent)
$CLI setup finish                                  # closes onboarding; a menu-bar app from now on
$CLI install-skill
claude mcp add lokalbot -- $CLI mcp                # only if the person wants library access in Claude Code
$CLI doctor                                        # readiness and next steps, as JSON
```

### New pieces

**Bootstrap request (`setup start`)**

Today the socket exists only after the person turns on the settings grant, and
finding that toggle is the first step an agent cannot do. `setup start` works
without any grant:

- **The request.** The CLI writes a one-time request to
  `control/setup-request.json`. It holds the grants requested, the requester
  (process path, plus the parent agent's name when known), a random nonce, and
  an expiry of a few minutes.
- **Where it appears.** The CLI opens the app with `--lokalbot-agent-setup`.
  - A fresh install shows onboarding anyway. The window opens on a "Set up
    with your agent" step instead of the wizard.
  - An already set-up app shows the same request in a small approval window.
- **What it asks.** The step names the agent and asks to let it change LokalBot
  settings. Meeting-library and screen-memory read access appear as separate
  checkboxes, off by default, with their existing descriptions. Deny leaves
  everything off.
- **On approval.** The app writes the markers itself (the CLI never does),
  deletes the request, and starts the socket. `--wait` polls for the socket.
- **The boundary.** The terminal can request a grant; only the person, in the
  app, can give it. A request file written by another process gains nothing
  without that click.

**Setup plans (`setup plan`, `setup apply`)**

A plan is a JSON object of registry keys and tokens, plus model and
launch-at-login choices. It has the same shape as `config import`.

- **Starting point.** `setup plan --preset recommended|lightweight` starts from
  that model preset and the fresh-install defaults. Using
  `HardwareCapabilityProbe`, the CLI suggests `lightweight` on Macs with less
  memory than the recommended stack needs.
- **The person's answers.** The agent fills in what it learned from the person:
  record automatically or ask, Day Memory detail, notes language, calendar,
  dictation, autocomplete, and so on.
- **Applying.** `setup apply` applies preferences right away and sends every
  consent change to one review card. The card lists each change with the
  disclosure Settings already uses.
  - Approve applies them all through the same `AppState` paths as Settings,
    so their permission prompts fire.
  - "Review individually" falls back to one approval per change.
  - Deny applies none of them.
- **Conversation first.** The skill tells the agent to ask the person about
  consent items before applying, so the card confirms choices already
  discussed.

**Models (`models`)**

- **Commands:** `list`, `recommend`, `download --preset|--role`, `status`,
  `cancel`, and `check`.
- **App entry points:** `modelSetup.apply(ModelStackPreset…)`,
  `modelRoles.startCoreModelDownloads`, `ModelDownloadManager`, and
  `modelChecks.run`.
- **Start, then poll.** Requests return at once. `status` reports per-role
  progress and readiness from `modelRoles.snapshot`, because downloads take
  minutes and the socket has a short timeout.

**Permissions (`permissions`, `restart`)**

- `permissions` lists each enabled feature, the permission it needs, and
  whether that permission is granted. It uses the table behind Memory Health.
- `permissions request <name>` calls `PermissionGuidanceController.requestAccess`:
  - Microphone and Calendar get a macOS prompt.
  - The others open System Settings with the drag guidance.
- `restart` uses `PermissionManager.relaunch()`.
- The agent tells the person exactly what to click and polls until the grant
  shows.

**Finish and verify**

- `setup finish` sets the onboarding flag through the app and closes the
  window.
- `doctor` extends `status` with:
  - model readiness and onboarding state;
  - permissions still needed for features the person turned on;
  - launch at login, and whether the CLI is on PATH;
  - a list of next steps.

  It exits non-zero while anything blocks a feature the person turned on.

**Distribution for agents**

- `/lokalbot:setup` in the existing Claude Code plugin
  (`Distribution/claude-plugin`) walks through the journey above.
- A short agent-facing guide, `AGENT_SETUP.md` at the repository root and also
  on the website, lists the commands and rules, so any agent can follow it
  from a link.
- The skill gains a "Setting up LokalBot" section.

**Rules for agents** (in the skill and the guide)

- Install with Homebrew or the notarized DMG. Never remove the quarantine
  attribute or otherwise bypass Gatekeeper.
- Never write LokalBot's preferences with `defaults write`, and never create or
  edit files in `control/`. `setup start` is the only way to ask for access.
- Ask the person before requesting consent changes or read access, and never
  retry a denied request.
- Verify with `doctor` instead of assuming a step worked.

### What has to land first

- **Side effects in `AppState`.** Turning on Day Memory, calendar detection,
  or a capture mode used to request permissions from `SettingsView` closures,
  so a write over the socket would have skipped those prompts. Done in
  Phase 3.
- **Richer `status`.** It needs model readiness and onboarding state. Done in
  Phase 2.
- **Wider `open`.** It needs to accept the Settings destinations that are not
  registry keys (`permissions`, `models`, and the grants). Done in Phase 2.

## Implementation status

Phase 1, with the registry part of Phase 0, is implemented on branch
`ccr-c1452663-cvoqi1`:

- `SettingRegistry` covers all 137 settings keys (130 at first; 7 added when `master` gained meeting note export and personal learning); the 5 bookkeeping keys are
  listed in `internalKeys`. `SettingRegistryTests` checks it against
  `AppSettings`. `SettingDescriptor` keeps its own table for now; a test keeps
  their titles and categories equal.
- The settings grant, the control socket, background launch, and
  `config schema|describe|search|list|get`, `status`, and `open` are in place.
- Moving the UI couplings into `AppState` waited for writes, which need
  them; Phase 3 moved them.

Phase 2 is implemented in PR #288:

- `config set|reset|export|import` and `settings.set`: all or nothing, with
  dry run. Preference and narrowing changes apply; widening ones return
  `needs_approval` with the changes in `details`, and read-only ones
  `read_only`.
- `SettingsChangeApplier` validates through the real decoder and applies the
  narrowing couplings (tracking off resets the capture mode, the capture mode
  drives `screenshotsEnabled`, dreaming keeps its start day). The permission
  requests that the Settings view fires when a feature is turned on move with
  Phase 3, because only approved widening changes trigger them.
- Audit log in `diagnostics/settings-changes.jsonl` with the caller's name,
  and a "Recent changes by agents" list with Undo under the toggle.
- `status` reports model readiness and onboarding; `open` accepts the
  non-setting Settings sections.

Phase 3 is implemented in PR #288 as well:

- `SettingsApprovals` queues requests with widening changes and new API keys.
  The app posts a notification, opens the approval window when notifications
  are off, and shows a menu bar row; the window has one card per request.
- `settings.request`, `--wait`, and `config request` report the answer with
  distinct exit codes.
- `secret list|set|clear` (`AppSecret`): keys go in on stdin, wait for
  approval, are held in memory only until answered, and are never read back.
  The card shows the last four characters.
- The Settings controls' couplings and permission prompts moved into
  `AppState` (`changeSettings`, `coupledSettings`,
  `requestPermissions(forChangeFrom:to:)`), as did the retention cleanup
  (`applyRetentionReview`). The tracking, capture mode, and calendar controls,
  approved requests, and Undo all use them.
- Undo is not offered for retention changes, which could delete without a
  review. `screenshotsEnabled` became read-only: it follows the capture mode.

Phase 4 is implemented in the follow-up PR:

- `setup start` (`AgentSetup`, `AgentSetupRequests`): the request file, the
  `agent-setup` window (shown instead of the onboarding wizard on a new
  install; declining opens the wizard), separate read-access boxes off by
  default, and the answer file `--wait` reads. Only Allow writes markers.
- `setup plan` (current values for `SetupPlan.keys`, the preset suited to this
  Mac's memory, and the settings that need approval) and `setup apply`
  (preferences directly, consent changes on one card, then the model preset
  and launch at login), `setup finish`, and `setup launch-at-login`.
- `models status|preset|download|cancel`, `permissions [request <name>]`,
  `restart` (refused while recording), and `doctor` (exits 1 while something
  the person turned on is blocked).
- `/lokalbot:setup` in the Claude Code plugin, `AGENT_SETUP.md`, and a
  "Setting up LokalBot" section in the skill.
- Not done: "Review individually" on the consent card, `models
  list|recommend|check`, and a website copy of `AGENT_SETUP.md`.

## Phases

| Phase | Scope | Size |
| --- | --- | --- |
| 0 | Registry and coverage tests. Done in PR #281, except building `SettingDescriptor` from the registry and moving couplings, which go with Phase 2 | Done (part) |
| 1 | `config schema/describe/search`, settings grant and marker, control socket, background launch, `config list/get`, `status`, `open` | Done in PR #281 |
| 2 | Preference writes, audit log, Undo list. `status` gains model readiness and onboarding state; `open` accepts non-registry destinations | Done in PR #288 |
| 3 | Approval requests (notification, menu bar, approval window), one combined card for multi-change requests, `--wait`, `secret set`, retention review through approval. Settings-view side effects (permission requests, couplings) moved into `AppState` | Done in PR #288 |
| 4 | Agent-led setup: `setup start` (bootstrap request in onboarding), `setup plan/apply`, `models`, `permissions`, `restart`, `setup finish`, `doctor`. Plus `/lokalbot:setup`, `AGENT_SETUP.md`, and the skill section | Medium–large |
| 5 | MCP tools; optional App Intents generated from the registry | Small–medium |
| Later | Other actions over the socket (recording, processing, digest, Dream); headless flags forward to a running app | Medium–large |

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

   The 2026-10-18 goal widens this: the actions setup needs (models,
   permissions, onboarding, restart) join Phase 4. Recording, processing, and
   library edits stay out.

## Decisions (agent-led setup)

Settled on 2026-10-18:

1. **Bootstrap:** the agent asks with `setup start`, and the person approves
   in LokalBot. The terminal can request access but never give it.
2. **Read access in the setup step:** meeting-library and screen-memory access
   appear as separate checkboxes, off by default.
3. **Consent changes during setup:** one combined review card, with
   "Review individually" as a fallback.
4. **Delivery:** PR #281 merges as Phase 1, and Phases 2–4 follow in their own
   PRs.
