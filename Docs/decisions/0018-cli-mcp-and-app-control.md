# 0018. CLI, MCP and app control

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers how external agents use LokalBot: `lokalbot-cli` and its stdio MCP server reading the library, the Raycast extension, the per-kind read grants under `control/`, and the control socket through which agents change settings and set API keys with the person's approval in the app. The Mac app implements it in Swift (`CLI/`, `LokalBot/CLISupport/`, `LokalBot/Services/AppControl/`), and the Windows and Linux app in Rust (`lokalbot-cli`, `lokalbot-core`, `lokalbot-app`, `lokalbot-platform`) with the same commands, output and errors. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Read-access grants

### Each kind of access is its own marker file under `control/`, and none grants another

External agents get read access only through marker files under `<root>/control/`, the same on macOS, Windows and Linux, and `lokalbot-cli` and its MCP server check them even with the app closed. Meeting-library access, or an Agent Mode meeting capability, never grants screen memory (window titles, OCR text, activity blocks, screenshot metadata); meeting or screen access never grants settings control, and settings control grants neither; no Agent Mode capability satisfies the Files grant. Only the app writes the settings-control marker, from its Privacy switch or an allowed setup request. Remote model servers need an approved origin (`RemoteInferenceGate.swift`).

Where: `LinuxWindows/crates/lokalbot-core/src/access.rs` (`settings_control_enabled`), `LinuxWindows/crates/lokalbot-core/src/files/access.rs`, `LokalBot/AppState.swift` (`AppState.screenMemoryAccess`), `LokalBot/CLISupport/ScreenMemoryAccessGate.swift` (`ScreenMemoryAccessGate`), `LokalBot/CLISupport/SettingsControlGate.swift` (`SettingsControlGate`).

### A terminal CLI honors the Privacy switch; only an app-issued capability for Agent Mode bypasses it

Access comes from the user-controlled global switch or from a short-lived bearer capability (`<uuid>.<64 hex>`) that the app issues to one embedded Agent Mode process, which inherits it. A normal terminal invocation has no capability and honors the Privacy switch just like MCP. Only the secret's SHA-256 is stored; the secret exists only in the process environment and is revoked when the tab shuts down.

Where: `LokalBot/CLISupport/AgentAccessGate.swift` (`AgentAccessGate.isAuthorized`, `AgentAccessGate.issueScopedCapability`), `LinuxWindows/crates/lokalbot-core/src/access.rs` (`issue_agent_capability`).

### Re-enabling access issues a new grant identity

A long-running read keeps the same grant through response delivery. Re-enabling global access issues a new identity, so it cannot revive an answer whose original grant was revoked while inference was pending.

Where: `LokalBot/CLISupport/AgentAccessGate.swift` (`AgentAccessGate.authorizationID`).

### A setup request only asks; the app grants, and only what the person ticked

The one way the terminal can ask for access is a short-lived request file in the library's `control/` folder that the app shows to the person. Only the app writes grant markers, and only after the person allows the request in LokalBot, so a request written by any other process gains nothing without that click. The app turns on only what the person ticked among what the request asked for and reports what took; a box counts only if the request asked for it.

Where: `LokalBot/CLISupport/AgentSetup.swift` (`AgentSetup`), `LinuxWindows/crates/lokalbot-core/src/control/setup.rs`, `LinuxWindows/crates/lokalbot-app/src/control/setup.rs` (`grant_read_access`).

### The External Agents read switch mirrors the markers, so nothing widens on upgrade

Settings → External Agents has one switch for reading LokalBot data with a box per kind; each kind keeps its own marker in `control/`, and the switch only writes and removes those markers. Turning it off removes them all and remembers the boxes and the screen history range for next time. The switch is on exactly while some kind is granted, so grants made before it existed (a toggle per kind) or by an agent setup request show as they are and nothing widens on upgrade. Changing LokalBot's settings stays a separate grant.

Where: `LokalBot/Services/AgentAccess/AgentReadAccess.swift` (`AgentReadAccess`).

### A legacy empty screen-memory marker stays authorized until a profile is chosen

An empty marker was written by the earlier binary gate, so it keeps that user's existing authorization until they choose a profile.

Where: `LokalBot/CLISupport/ScreenMemoryAccessGate.swift` (`ScreenMemoryAccessGate.profile`).

### An existing `control/` folder is hardened explicitly

`createDirectory(attributes:)` does not re-apply attributes when the shared `control/` directory already exists (for example after meeting access was enabled first), so enabling screen access hardens the existing directory itself.

Where: `LokalBot/CLISupport/ScreenMemoryAccessGate.swift` (`ScreenMemoryAccessGate.enable`).

### Files access publishes the chosen folders in `control/files-access.json`

While the Files grant is on and Files is on with a folder, the app keeps `control/files-access.json` listing the chosen folders, so `lokalbot-cli` and its MCP server can search the Files index with the app closed and without reading the app's settings. Anything else removes that list. The grant is set from Settings → External Agents on the Mac, and from Settings → AI agents or Settings → Files on Windows and Linux.

Where: `LokalBot/Services/FileSearch/FilesAccessManager.swift` (`FilesAccessManager`), `LinuxWindows/crates/lokalbot-core/src/files/access.rs`.

### Personal context is served from a projection of shared claims that fails closed

While the Personal context grant is on, the app keeps `control/personal-context.json` in step with the claims the person chose to share, so the CLI and MCP server answer without the app running and without reading the encrypted personal model. Every failure removes the shared copy rather than leaving a stale one, agent access fails closed when the saved personal model can't be read instead of treating it as "nothing shared", and a projection left on disk without its grant marker is never served, whatever other access is on.

Where: `LokalBot/Services/PersonalModel/PersonalContextAccessManager.swift` (`PersonalContextAccessManager`), `LokalBot/Services/PersonalModel/PersonalModelController.swift` (`PersonalModelController.readableClaims`), `LinuxWindows/crates/lokalbot-cli/src/personal.rs`, `LokalBotTests/CLISupport/PersonalContextAccessTests.swift` (`testRefusedWithoutItsOwnGrantEvenWithOtherAccess`).

## What agents can read

### The CLI opens the library read-only and never writes into `meetings/`

`lokalbot-cli` gives read-only access to the library, a stdio MCP server, and settings changes only through the running app. It opens the library read-only and never writes into `meetings/`.

Where: `LinuxWindows/crates/lokalbot-cli/src/lib.rs`.

### Reports carry names, never email addresses

Action-item and people reports for the CLI and MCP show owners and names only. The People directory is built with the same rules as the app, and attendee email addresses are used inside its builder as private join keys and never leave it.

Where: `LokalBot/CLISupport/PeopleReport.swift` (`PeopleReport`), `LinuxWindows/crates/lokalbot-cli/src/reports.rs`.

### Screen memory exposes text and metadata only, checked again on every returned row

The screen tools return OCR text, window titles and activity metadata from `lokalbotv3.sqlite`, opened read-only for every request, and never pixels or screenshot file paths. The access profile is enforced again on returned rows even though the SQLite reader already applies the bound, so the authorization boundary holds for alternate readers and future refactors.

Where: `LinuxWindows/crates/lokalbot-cli/src/screen.rs`, `LokalBot/CLISupport/FileLibraryToolProvider.swift` (`FileLibraryToolProvider.searchScreen`).

### Work-memory items need the grant of every source behind them

In the briefing, a work-memory item needs meeting access for meeting sources and screen access (and its history window) for screen, activity and digest evidence. Items without source attribution are never shown.

Where: `LokalBot/CLISupport/Briefing.swift` (`Briefing.workMemory`), `LinuxWindows/crates/lokalbot-cli/src/briefing.rs` (`work_memory`).

### Unknown `include` parts are rejected

`get_meetings`, like `get --include` and `list_meetings`, rejects a misspelt part instead of returning a meeting without that section.

Where: `LinuxWindows/crates/lokalbot-cli/src/mcp.rs` (`get_meetings` include parsing).

### A plain `list` only checks that summary and transcript files exist

`has_summary` and `has_transcript` only say the file is there. Reading every summary and transcript for them made a plain `list` read the whole library, so summaries are read only when they are printed.

Where: `LinuxWindows/crates/lokalbot-cli/src/session.rs` (`list_json`).

## Settings changes from the terminal

### Changes that widen consent wait for the person; everything else applies all or none

A consent setting widens when a change makes LokalBot capture, read, record, keep or send more; narrowing it is always allowed. Preference and narrowing changes apply directly, all or none, and a request with a widening change waits, with the rest of the request, until the person approves it in the app.

Where: `LokalBot/CLISupport/SettingChange.swift` (`SettingSpec.classify`), `LokalBot/Services/AppControl/AppControlHandler.swift` (`AppControlHandler.setSettings`), `LinuxWindows/crates/lokalbot-app/src/control/handler.rs` (`ControlHost.set_settings`).

### Every consent setting has a narrowing direction

A consent setting with no rule would treat every change as widening, including turning it off, so a test checks that each one can be narrowed.

Where: `LokalBotTests/CLISupport/SettingChangeTests.swift` (`testEveryConsentSettingHasADirection`).

### Only moving the model download source back toward Hugging Face narrows

Each later source puts another third-party host ahead of the earlier ones (ModelScope, then HF-Mirror, then Hugging Face), so only a move back toward Hugging Face counts as narrowing.

Where: `LokalBot/CLISupport/SettingChange.swift` (`SettingSpec.widens`), `LinuxWindows/crates/lokalbot-core/src/control/change.rs` (`SettingSpec::widens`).

### Writing back a redacted URL keeps the real user info and query

`config list` and `export` show URLs without user info or query, and writing that form back must not strip them from the stored value.

Where: `LokalBot/CLISupport/SettingChange.swift` (`SettingsChangePlan.plan`), `LinuxWindows/crates/lokalbot-core/src/control/change.rs` (`ChangePlan::make`).

### Coding-agent evidence reads as off until the person has chosen

The terminal sees `codingAgentEvidenceEnabled` as what actually happens: the stored default is on, but nothing is read until the person has chosen, so an agent turning it on has to ask.

Where: `LinuxWindows/crates/lokalbot-core/src/control/mod.rs` (`encoded`).

### API keys are write-only from the terminal and always wait for the person

`lokalbot-cli secret` reads a key from standard input, one line, and the key never appears in any output or reply; the CLI can say whether a key is saved, never read it back. A new key always waits for the person, held in memory until the request is answered.

Where: `LokalBot/CLISupport/AppControlApproval.swift` (`AppSecret`), `LinuxWindows/crates/lokalbot-core/src/control/protocol.rs` (`AppSecret`), `LinuxWindows/crates/lokalbot-app/src/control/handler.rs` (`ControlHost.secret_set`), `LinuxWindows/crates/lokalbot-cli/tests/cli.rs` (`api_keys_come_from_standard_input_and_never_print`).

## Approvals

### Only the person approves, one card per request, in the approval window

Each waiting request (a widening settings change or a new API key) is one card in the approval window listing every change it makes in full. It is answered once, expires after a few minutes, and is never approved in bulk. Approve applies exactly those changes through the same paths as Settings and Deny changes nothing; only that window calls `Approvals::approve` (`ControlHost::approve`), nothing on the control socket can reach it, and no key press approves.

Where: `LinuxWindows/crates/lokalbot-core/src/control/approvals.rs`, `LinuxWindows/crates/lokalbot-app/src/windows/settings_approval.rs`, `LinuxWindows/crates/lokalbot-app/src/control/mod.rs` (`ControlHost::approve`).

### Approving applies what the card showed to the settings as they are now

Settings the request left alone stay as the person has set them since. If approving now would widen more than the card showed, or a shorter retention policy would delete more than its review, the card gets the new changes and keeps waiting: for example, a lengthening that needed no cleanup when asked would delete after the person lengthened retention further, and a card that adds one origin would add both. Every value is checked before anything is deleted.

Where: `LokalBot/Services/AppControl/AppState+AgentSettings.swift` (`AppState.applyApprovedSettings`), `LinuxWindows/crates/lokalbot-app/src/control/mod.rs` (`ControlHost.approve_settings`), `LokalBotTests/Services/AppControl/SettingsApprovalFlowTests.swift` (`SettingsApprovals.approve`).

### A retention change whose deletion review can't be built is refused

When a change's shorter retention policy deletes something, the card needs a review of that cleanup, built on the UI thread as on the Mac because it is rare. A review that can't be built refuses the change rather than skipping the review.

Where: `LinuxWindows/crates/lokalbot-app/src/control/mod.rs` (`ControlHost.retention_review`).

### Retention changes have no Undo in the audit log

Undoing a retention change could delete without the review a shorter policy needs, so those are changed back in Settings instead.

Where: `LokalBot/Services/AppControl/AgentSettingsChanges.swift` (`AgentSettingsChanges.keysWithoutUndo`), `LinuxWindows/crates/lokalbot-core/src/control/audit.rs` (`KEYS_WITHOUT_UNDO`).

## The control socket

### The socket runs only while the person allows settings changes, and every request re-checks it

The app serves the control socket only while the person allows external agents to change settings. Every request re-checks the Privacy marker, so revoking the grant takes effect even for a connection already accepted, and the socket has no method that approves anything.

Where: `LinuxWindows/crates/lokalbot-app/src/control/mod.rs`, `LinuxWindows/crates/lokalbot-platform/src/control_socket.rs`.

### Only this user can reach the socket, and the client refuses anyone else's

On Windows and Linux it is a Unix socket (mode 0600) in the user's private runtime folder (mode 0700) with the peer's user id checked, or a named pipe whose access list holds only this user and which refuses remote clients, named after a hash of the library root. The client refuses an endpoint another user owns, so a request, which can hold an API key, never reaches anyone else's process. On the Mac the socket lives in the library's 0700 `control/` folder, and a root whose path is too long for `sun_path` uses a per-user name in /tmp that the app and the CLI derive the same way.

Where: `LinuxWindows/crates/lokalbot-core/src/control/socket.rs`, `LinuxWindows/crates/lokalbot-platform/src/control_socket.rs`, `LokalBot/CLISupport/AppControlSocket.swift` (`AppControlSocket`).

### The named-pipe client lets the server identify it, never impersonate it

The client connects so that the server may identify it but never act as it.

Where: `LinuxWindows/crates/lokalbot-core/src/control/socket.rs` (`connect`).

### Blocking socket I/O runs off the thread it could stall

Pipe exchanges run on a helper thread because a named pipe has no I/O timeouts. In tests the blocking Swift client stays off the main actor that runs the server's handler.

Where: `LinuxWindows/crates/lokalbot-core/src/control/socket.rs` (`exchange`), `LokalBotTests/Services/AppControl/AppControlTests.swift` (`AppControlClient.request`).

### Shutdown wakes the accept with a connection held open until the thread exits

On drop the server wakes its blocking accept with a connection of its own and holds it open until the thread has gone. A Windows pipe listener skips a client that has already left, so closing that connection first could leave accept, and the join waiting on it, blocked for good.

Where: `LinuxWindows/crates/lokalbot-platform/src/control_socket.rs` (`ControlServer::drop`).

## Finding and launching the app

### The CLI never starts the app for an agent the person has not allowed

A control request does not launch LokalBot unless the person has allowed the agent.

Where: `LokalBot/CLISupport/AppControlClient.swift` (`AppControlClient.request`), `LinuxWindows/crates/lokalbot-cli/src/control.rs` (`Client::request`).

### The CLI launches the LokalBot beside it by path, never by name

The CLI resolves the app that contains it through the installed link (the `~/.local/bin` symlink on the Mac) and launches it by path, so a CLI never starts a different copy with another library. The helper's version is read from the executable's real path, because a shell that finds the helper on PATH passes only the bare name as `argv[0]`.

Where: `LokalBot/CLISupport/AppControlClient.swift` (`AppControlClient.enclosingApp`), `LinuxWindows/crates/lokalbot-cli/src/control.rs` (`Client::enclosing_app`), `LokalBot/CLISupport/HelperVersion.swift` (`HelperVersion.current`).

### Waiting for an answer polls the running app and never starts LokalBot

Waiting polls the running app until the request is answered or the given seconds pass. It never starts LokalBot, because a request lives only in the copy that took it.

Where: `CLI/Commands/ApprovalCommands.swift` (`ControlOutput.waitForAnswer`), `LinuxWindows/crates/lokalbot-cli/src/control.rs` (`poll`).

### Requests that need the person report their state through exit codes

A request left waiting prints as JSON and exits 3. With `--wait` the CLI follows it until the person answers and exits 0 when approved, 4 when denied and 5 when expired.

Where: `LinuxWindows/crates/lokalbot-cli/src/control.rs` (`send_for_approval`).

### The CLI resolves the same library as the app

`AppDirectories` hard-codes the app's bundle id rather than using `Bundle.main.bundleIdentifier`, so the CLI process, whose own bundle id differs, resolves the library the app writes. It honors the `LOKALBOT_STORAGE_ROOT` override too, so the CLI can be pointed at an isolated test library exactly like the app.

Where: `LokalBot/CLISupport/SessionLookup.swift` (`SessionLookup.storageRootURL`).

### `Meeting.folderURL` lives in `StorageManager.swift`

The embedded `lokalbot-cli` does not compile `StorageManager`, so the folder lookup lives there rather than in `Meeting.swift`, and the `Meeting` value type stays dependency-free.

Where: `LokalBot/Services/Storage/StorageManager.swift` (`Meeting.folderURL`).

## Ask and the local model server

### `ask` sends the question and context only to the app's model server on 127.0.0.1

The question and matching meeting context go to the app's local model server on 127.0.0.1, and nothing leaves the computer. The app records its server in `<root>/llama-server-<port>.json` (`port`, `pid`, `authenticationToken`; `llama-server-17872.json` for `ask`), written 0600 on Unix because it holds the bearer token, and the same file lets a later run recognize and stop a helper an earlier run left behind. Role ports never move because CLI and MCP clients rely on them, and without the marker the tool answers that the app must be running.

Where: `LinuxWindows/crates/lokalbot-cli/src/ask.rs`, `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`ServerMarker`, `Role::release_port`).

### Agent leases are re-acquired before the old one is released

Each wake acquires a fresh TTL lease and then releases the previous one, in that order, so the lease count never dips to zero and starts a linger. Re-acquiring instead of renewing runs the broker's ensure every time, so a `llama-server` that crashed since the last question is revived instead of trusted.

Where: `LokalBot/Services/AgentAccess/AgentAccessManager.swift` (`AgentAccessManager.acquireOrRenewAgentLease`).

## Output, MCP and installation

### JSON output matches the macOS helper exactly

The Windows and Linux CLI has the commands, output and errors of the macOS helper, and prints JSON as Swift's `JSONEncoder` does: sorted keys, two-space indentation, `"key" : value`, whole numbers without a fraction and, unless asked otherwise, `/` escaped as `\/`.

Where: `LinuxWindows/crates/lokalbot-cli/src/json.rs`, `LinuxWindows/crates/lokalbot-cli/src/lib.rs`.

### Refusal codes are shared across platforms

A command refused because a switch is off names its code. The skill and `AGENT_SETUP.md` tell agents to look for these codes, and the Windows and Linux CLI prints the same ones.

Where: `LokalBotTests/CLISupport/AgentAccessGateTests.swift` (`testACommandRefusedForASwitchThatIsOffNamesItsCode`).

### The MCP server reads whatever stdin has, so it answers while the client keeps stdin open

The stdio reader takes whatever bytes are available, up to `chunkBytes`, and returns empty only at EOF. `FileHandle.read(upToCount:)` waits for the full count on a pipe, so a client that kept stdin open and sent one short request never got a reply; real clients (Claude Code, Claude Desktop) keep stdin open and need `initialize` answered before they send anything else.

Where: `LokalBot/CLISupport/MCPProtocol.swift` (`MCPStdioLineReader.readAvailable`), `LokalBotTests/Integration/MCPServerIntegrationTests.swift` (`testAnswersInitializeWhileStdinStaysOpen`).

### The Raycast extension passes messages on standard input and reads JSON on failure

`ask` and `reply` messages go on standard input so they never appear in the process list. The CLI prints JSON even when it exits with an error, so the extension returns the outcome rather than throwing.

Where: `Distribution/raycast/src/cli.ts` (`runAsk`).

### Installing and uninstalling touch only what the installer owns

On Linux `install-skill` links `~/.local/bin/lokalbot-cli` to the binary, writes the skill once under `~/.local/share/lokalbot-cli/skill` and links it from `~/.agents/skills/lokalbot-cli` and `~/.claude/skills/lokalbot-cli` (copies with `--copy`); on Windows it copies the binary to `%LOCALAPPDATA%\Programs\LokalBot\bin` and the skill into the same skill folders under `%USERPROFILE%`. When this binary, or an identical copy, already sits at the command path (`packaging/linux/install.sh` copies it there and the app runs it from there), it is left in place and only the skill is written. Paths the installer does not own are never replaced, and uninstalling removes only what the installer created.

Where: `LinuxWindows/crates/lokalbot-cli/src/install.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/advanced.rs` (`SettingsPage::uninstall_cli`).

### Diagnostics export refuses an existing folder

Exporting diagnostics refuses a target folder that already exists and leaves it intact, so `--export-diagnostics ~/Desktop` can never delete the Desktop.

Where: `LokalBotTests/Services/Diagnostics/DiagnosticsExporterTests.swift` (`testExportRefusesAnExistingFolderAndLeavesItIntact`).

## Consequences

- A new kind of agent data needs its own marker in `control/` that the CLI can check with the app closed, and no other grant may imply it. A new setting reachable from the terminal needs a consent classification with a narrowing direction.
- Nothing reachable from the control socket may approve. Approvals stay in the app's window, and applying one re-checks the request against the current settings.
- The Swift and Rust CLIs share commands, JSON formatting, exit codes, refusal codes, fixed ports and marker layouts, so a change to one has to land in the other.
