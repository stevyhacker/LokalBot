# 0011. Agent Mode

- Status: Accepted
- Date: 2026-11-20

## Context

Agent Mode runs the pi coding agent on Bun inside LokalBot, so a model can read files, run commands and look things up in the user's library, while LokalBot asks before anything outside a short allowlist runs. The Mac app (`LokalBot/Agent/`, with the approval extension in `LokalBot/Resources/pi/lokalbot-extension/`) and the Windows and Linux app (`LinuxWindows/crates/lokalbot-agent/`) share one launch contract, one set of approval rules and the ChatGPT plan relay; the feature also covers handing work to a coding agent installed on the computer. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Runtime setup

### Setup assembles the runtime in staging and swaps it in only after every digest matches

Setup downloads and verifies Bun, then installs pi from the public npm registry with the frozen lockfile bundled in the app. Everything is assembled in a staging folder and swapped into place only after every digest matched, so a failed setup leaves nothing half-written. The package install uses a private cache inside staging, so nothing lands in the user's `~/.bun` and no stale cache entry can stand in for a download (the lockfile's integrity hashes are still checked).

Where: `LokalBot/Agent/AgentRuntimeInstaller.swift`, `LinuxWindows/crates/lokalbot-agent/src/install.rs` (`package_install_command`).

### The runtime digest covers the folder's whole shape and nothing machine-specific

Records are ordered by raw UTF-8 name within each folder, length-delimited and tagged by type. Symlinks hash their link text and are never followed, regular files hash their bytes, and folders are recorded so empty or extra folders change the digest. Metadata and absolute paths are left out, so identical installs hash identically.

Where: `LinuxWindows/crates/lokalbot-agent/src/digest.rs` (`tree_hex`).

### Opening the Agent pane checks a receipt; starting a task runs the deep audit

Installation already verifies every staged byte before the atomic swap, so showing the pane only proves that the expected entry points and a matching version receipt are present. Starting a task runs `isIntegrityValid`, the deep audit of the mutable runtime tree.

Where: `LokalBot/Agent/AgentRuntime.swift` (`AgentRuntimeLayout.isInstalled`).

### Repair stops every agent first

"Set Up Agent Mode" and "Repair Agent Mode" share one path, and repair stops every agent before touching the runtime because a running Bun keeps its files open on Windows.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/agent/model.rs` (`AgentModel::install`).

## Launching pi

### pi runs isolated from the user's pi setup, offline and without context files

The launch contract (from the 2026-07-09 spec) isolates pi from the user's `~/.pi` and any folder-local pi configuration (`--no-extensions -e`, `--no-skills --skill`, `--no-prompt-templates`, `--no-approve`) and keeps it offline (`--offline` and `PI_SKIP_VERSION_CHECK`), because pi ships update checks and install telemetry on by default. Context files are disabled because pi's upward discovery is not confined to the working folder; workspace files stay readable through the read tool, which the extension gates. LokalBot's own system prompt replaces pi's coding-agent prompt and the extension appends the per-run environment; on Linux and Windows `LOKALBOT_STORAGE_ROOT` points the bundled `lokalbot-cli` at this library.

Where: `LokalBot/Agent/PiLaunchPlanner.swift` (`PiLaunchPlanner`), `LinuxWindows/crates/lokalbot-agent/src/launch.rs`.

### Only the verified runtime runs: no run-time installs and no compile caches

Bun's transpiler cache and jiti's extension cache (and on the Mac pi's compile cache) are off, because they would keep compiled copies of pi and of the approval extension in `~/Library/Caches/bun` or `~/.bun` and the temporary folder, outside the verified runtime, and later launches would run those copies. On Linux and Windows Bun also runs with `--no-install`, so a missing import can never be fetched from npm at run time.

Where: `LokalBot/Agent/PiLaunchPlanner.swift` (`PiLaunchPlanner.plan`), `LinuxWindows/crates/lokalbot-agent/src/launch.rs`.

### A protected-roots encoding failure stops the extension

If the protected roots cannot be encoded, the extension stops at startup instead of running without them: `null` fails its launch validation.

Where: `LokalBot/Agent/PiLaunchPlanner.swift` (`PiLaunchPlanner.plan`), `LinuxWindows/crates/lokalbot-agent/src/launch.rs` (`plan`).

### The provider key never reaches the agent's shell commands

A credential-free endpoint must not inherit a key for another service from the parent process (injected test sessions included). The extension takes the key at startup and removes it from the environment, because pi gives every shell command a copy of its environment and a command or a script it starts could read it. pi evaluates the extension module again for a new session, so the key is kept on `globalThis` rather than read from the environment.

Where: `LokalBot/Agent/PiLaunchPlanner.swift` (`PiLaunchPlanner.plan`), `LinuxWindows/crates/lokalbot-agent/src/launch.rs` (`plan`), `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`takeProviderAPIKey`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`takeProviderAPIKey`).

### A missing path is never passed to pi

pi takes a missing path as the prompt text itself.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.makePlan`).

### On Windows LokalBot pins a real Bash, never WSL's launcher, and falls back to PowerShell

On Linux pi runs `/bin/bash -c` (then `bash` on PATH, then `sh`). On Windows pi 1.5.2 tries the `shellPath` setting, Git Bash under `%ProgramFiles%` and `%ProgramFiles(x86)%`, then any `bash.exe` on PATH, which is often WSL's launcher in `System32` and would run commands inside a Linux distribution with different files and tools. LokalBot resolves the shell itself and pins Git Bash (or another Bash on PATH such as MSYS2 or Cygwin, never a WSL launcher) with `shellPath` in its private pi settings; with no Bash at all the agent gets pi's PowerShell tool, and the approval card shows each PowerShell command exactly as it does a Bash command.

Where: `LinuxWindows/crates/lokalbot-agent/src/shell.rs`, `LinuxWindows/crates/lokalbot-agent/src/launch.rs`.

### The default working folder is an empty folder beside the library

Agent tools start in an empty workspace that is a sibling of the private library, so choosing the default workspace does not expose recordings or settings, and the library is never an implicit working folder.

Where: `LokalBot/Models/App/AppDirectories.swift` (`AppDirectories.agentWorkspace`), `LinuxWindows/crates/lokalbot-agent/src/layout.rs` (`AgentDirectories.default_workspace`).

## Tool approvals and data access

### Every tool call asks except a read inside the workspace

Approval is an allowlist: a read inside the selected workspace and outside the private library is the only call that runs without asking, and every other tool asks, including MCP tools, codemode and tools that later pi releases add. In pi's hook, returning `undefined` lets the tool run, so the runtime tests drive the real hook and expect a blocking result even when the fake UI would approve. They also load pi's built-in MCP extension, which `--no-extensions` leaves off, to prove its tools still pass the gate.

Where: `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`requiresApproval`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`requiresApproval`), `Scripts/tests/pi-runtime.test.ts` (`withExtensionFixture`, `STUB_MCP_SERVER`).

### File access is judged on the path pi will actually open

pi's file tools rewrite a requested path before opening it (pi 1.5.2 `utils/paths.js` and `core/tools/path-utils.js`), and `resolveReadPath` opens a missing file through a look-alike name when one exists. Checked as typed, each of these named a missing file inside the workspace and ran without asking, so the extension checks the file pi will open.

Where: `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`resolveReadPath`), `Scripts/tests/pi-runtime.test.ts`.

### Paths are canonicalized through the nearest existing ancestor, and dangling links fail closed

Symlinks are resolved through the nearest existing ancestor and any not-yet-created suffix is appended, so a path through a symlink cannot escape because its last component does not exist yet, and a symlinked parent cannot turn an apparently local write into an external one. A dangling link stops the walk and fails closed. The Mac host uses the same rule as the bundled extension.

Where: `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`canonicalize`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`canonicalize`), `LokalBot/Agent/AgentApprovalPolicy.swift` (`AgentApprovalPolicy.canonicalFileURL`).

### Relative tool paths resolve against the session's saved folder

The extension resolves relative paths the way pi's tools do: against the session folder, which for a resumed session is the folder it was saved with, not necessarily this process's working folder.

Where: `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`lokalbotExtension` `tool_call`).

### Approval covers the exact command, never a prefix

The whole shell command must fit in the approval payload; LokalBot never asks about a prefix and then runs the unchanged, longer request. The extension refuses before asking when it does not fit, and the host also refuses, failing closed for old, malformed or locally bounded payloads. Lengths are counted in UTF-16 units, as JavaScript counts them.

Where: `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`lokalbotExtension` `tool_call`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`lokalbotExtension` `tool_call`), `LinuxWindows/crates/lokalbot-agent/src/transcript.rs` (`ApprovalRequest::can_approve`).

### A command is approved once at a time

A command gets only Deny and Allow once, and so does a file inside LokalBot's own data. A caller cannot keep shell permission even when it asks for session scope; the next command is asked about on its own. The approval card names the file or command, what will happen and where, and the first lines to review, with Deny set apart from the answers that allow.

Where: `LokalBot/Views/Agent/AgentApprovalDock.swift`, `LinuxWindows/crates/lokalbot-app/src/pages/agent/approval.rs`, `LokalBotTests/Agent/AgentSessionControllerTests.swift` (`testBashAlwaysRequiresOneTimeApproval`).

### Library lookups skip approval only when the model runs on this computer

A lone read-only lookup of the user's own library runs without asking in every mode, the default included, but only while the task's model is known to run on this computer. A lookup's output goes to the model, so with a model on a server or a subscription plan, or one whose place is not known, the same lookups ask wherever they asked before. Anything that cannot be proved to be a lookup follows the mode.

Where: `LokalBot/Agent/AgentApprovalPolicy.swift` (`AgentApprovalPolicy.modelRunsOnThisMac`), `LinuxWindows/crates/lokalbot-agent/src/policy.rs` (`ApprovalPolicy.verdict`), `LinuxWindows/crates/lokalbot-app/src/pages/agent/words.rs` (`level_detail`), `LokalBotTests/Agent/AgentApprovalPolicyTests.swift` (`testTheSameLookupsAskWhenTheModelIsNotOnThisMac`).

### A lookup is one plain `lokalbot-cli` read call

Only one `lokalbot-cli brief`, `list`, `get` or `search` call made of plain and quoted words counts, so nothing can chain, redirect, substitute or expand into another command. Those four only read the library and print, and only with the listed options (`LOOKUP_OPTIONS`). A trailing `2>&1` and `| head` or `| tail` with a line count are allowed.

Where: `LokalBot/Agent/AgentApprovalPolicy.swift` (`AgentApprovalPolicy.isLibraryLookup`), `LinuxWindows/crates/lokalbot-agent/src/policy.rs` (`is_library_lookup`).

### Raising the access level is confirmed; lowering it applies at once

Changing the agent's access level in the composer asks for confirmation only when it gives the agent more access.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/agent/composer.rs` (`render_access`).

### Attached sources are stored as references and read again on every send

Files, meetings and saved screen moments attached to a task are stored only as references. Their text is read again, with the current permissions, each time a message is sent, and appended to the prompt as reference data the model is told not to follow as instructions.

Where: `LokalBot/Agent/AgentContextResolver.swift`, `LinuxWindows/crates/lokalbot-agent/src/context.rs`.

### Agent read access is granted per kind of data

The Personal context grant is separate from meeting and screen access, and agents also need each item marked Share with Agents. A feature page's own box grants that kind alone: ticking Files on the Files page never lets agents read meetings too.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/personal_context.rs` (`SettingsPage.personal_access_row`), `LokalBotTests/Services/AgentAccess/AgentReadAccessTests.swift` (`AgentReadAccess.setGranted`).

## Model endpoints

### Agent endpoints follow Think's remote-origin consent and also require HTTPS off this computer

The built-in Think model is llama-server's `Role::Main`. Ollama and OpenAI-compatible servers follow the same remote-origin consent as the rest of Think, and Agent Mode also requires HTTPS for anything not on this computer, which the extension enforces again. The ChatGPT plan is reached through a relay on this computer that holds the plan's tokens, and the relay's own approval stands in for the origin check.

Where: `LokalBot/Agent/AgentLLMEndpoint.swift`, `LokalBot/Engines/ThinkExecution.swift` (`agentResolution`), `LinuxWindows/crates/lokalbot-agent/src/endpoint.rs`.

### The keyring is read only for OpenAI-compatible servers

Only an OpenAI-compatible server takes a key, and reading the system keyring can block for a long time when no secret service answers.

Where: `LinuxWindows/crates/lokalbot-agent/src/launcher.rs` (`PiLauncher.connect`).

### The inference client rejects every redirect

A launched task has approval for one origin, so redirects are rejected before the HTTP client can replay context or credentials, same-origin redirects included; the final inference endpoint has to be configured instead.

Where: `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`inferenceFetchForOrigin`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`inferenceFetchForOrigin`).

### Withdrawing a server or plan approval ends a running turn

During a turn the agent sends the conversation, attached context and tool results to its endpoint at every model step without going through `send`, so a turn on a destination that is no longer approved is ended along with its process, not only refused its next prompt. A session that is waiting sends nothing until `send`, which refuses.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.remoteApprovalsDidChange`), `LokalBotTests/Agent/AgentSessionControllerTests.swift` (`testRevokingTheServerStopsARunningTurn`).

### The extension sets `input` on every model it registers

pi's `registerProvider` path does not default `input` (unlike its `models.json` path), and pi-ai's `openai-completions` dereferences `model.input` unguarded, so leaving it out crashes every completion with "undefined is not an object".

Where: `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`lokalbotExtension` model registration), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`lokalbotExtension` `registerProvider`).

### Responses models send developer messages, replay encrypted reasoning and set no output cap

pi-ai sends a reasoning model's instructions as a developer message, because the plan route rejects system messages, and replays its encrypted reasoning; the route also rejects output caps. With `store: false` nothing is kept on OpenAI's side, so pi replays the encrypted reasoning with the tool call and its output.

Where: `LokalBot/Resources/pi/lokalbot-extension/index.ts` (`RESPONSES_MODEL_TRAITS`), `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`RESPONSES_MODEL_TRAITS`), `Scripts/tests/pi-runtime.test.ts`.

### The per-run environment is the last prompt section

The environment section gives today's date, the working folder and which model answers; `servedBy` names a plan's provider when a local relay forwards to it. It is the last section, and pi folds a changed section into the leading system message (small local models' chat templates reject a system message after the first), so the date changes the cached prompt only once a day.

Where: `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts` (`environmentSection`), `Scripts/tests/pi-runtime.test.ts`.

### The built-in model is leased per turn on the Mac, and a task lease never makes other models wait

On the Mac the Main LLM lease is held only while a turn runs (built-in engine only), so an unrelated model load cannot evict it mid-turn; a lease kept for as long as the tab stayed open made every other model on that server wait behind it. On Linux and Windows a session holds a `lokalbot_ai::Lease` on `Role::Main`, and while that task lease is held a request for another model fails instead of waiting for a task that may never be closed.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.llmLease`), `LinuxWindows/crates/lokalbot-agent/src/endpoint.rs`, `LinuxWindows/crates/lokalbot-ai/src/runtime.rs` (`LlamaServer::lease_model_for_task`).

### Each caller takes its own model lease

When a send joined the lease request of a turn the agent had started, the turn could settle and give the lease back before the send resumed, and the send then stored that lease as if it were still held. Every caller now asks for a lease of its own.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.holdModelForTurn`).

## ChatGPT plan relay

### A loopback relay holds the plan's tokens so pi never does

pi speaks the Responses API to a relay on 127.0.0.1 with a key issued for one task (one session on the Mac). The relay checks that key, shapes the body to the plan route's rules, adds the current Sign in with ChatGPT access token (refreshed by `ChatGPTPlanAccount` on the Mac, `Account` in Rust) and streams OpenAI's reply back unchanged. Only `POST /v1/responses` is relayed, so pi and the commands it runs never hold the plan's tokens.

Where: `LokalBot/Agent/ChatGPTPlanRelay.swift` (`ChatGPTPlanRelay`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay.rs`.

### The Rust relay uses blocking sockets, one thread per connection

A hang-up or `Relay::stop` closes pi's connection at once. ureq's read of OpenAI's stream can't be interrupted from another thread, so that upstream connection is dropped when its next event arrives.

Where: `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay.rs`.

### The relay refuses requests that carry an `Origin` header

Browsers always send `Origin`; pi never does.

Where: `LokalBot/Agent/ChatGPTPlanRelay.swift` (`ChatGPTPlanRelayRequest.read`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay.rs` (`read_request`).

### The relay strips fields the plan route can't take

It removes the fields the route rejects, server-side conversation state it can't use over HTTP, and pi-ai fields that have no meaning on plan usage, following the route's "Preview limitations" (developers.openai.com/siwc/token-sharing-open-source, 2026-10).

Where: `LokalBot/Agent/ChatGPTPlanRelay.swift` (`ChatGPTPlanRelayPolicy.unsupportedFields`), `LinuxWindows/crates/lokalbot-ai/src/plans/chatgpt/relay.rs` (`UNSUPPORTED_FIELDS`).

### Only temporary plan outages are retried

pi retries 408, 409, 429 and 5xx by default. Plan limits, eligibility and request errors don't change on a retry, while temporary plan outages do; `nil` leaves pi's default for a status.

Where: `LokalBot/Agent/ChatGPTPlanRelay.swift` (`ChatGPTPlanRelayPolicy.shouldRetry`).

## The pi process and session lifecycle

### pi's stdout is split on LF bytes only

pi's RPC framing (`docs/rpc.md`, "Framing") makes LF (0x0A) the only record delimiter, strips one trailing CR, and never splits on U+2028 or U+2029 inside JSON strings. So the splitter works on raw bytes, and the process reader never uses a string-based line reader.

Where: `LokalBot/Agent/PiJSONLFrameSplitter.swift` (`PiJSONLFrameSplitter`), `LinuxWindows/crates/lokalbot-agent/src/frame.rs`, `LokalBotTests/Agent/PiJSONLFrameSplitterTests.swift` (`PiJSONLFrameSplitterTests`).

### Nothing started for pi outlives LokalBot

On Linux, Bun leads a new session (`setsid`) and gets `SIGTERM` when LokalBot dies through `PR_SET_PDEATHSIG`, which fires when the forking thread exits, so every pi is forked from one spawner thread that lives as long as LokalBot. pi's own `SIGTERM` handler kills the tool commands it started in their own process groups; stopping sends `SIGTERM` to the group, waits, then `SIGKILL`s the group and every descendant found in `/proc`, and a record in `<library>/agent/processes` lets the next run stop a pi that ignored its signal. On Windows, Bun starts suspended in its own job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and then resumes; every tool command inherits the job, so stopping, or LokalBot exiting and closing the handle, ends the whole tree. On quit every agent is asked to stop at once and whatever is left is killed.

Where: `LinuxWindows/crates/lokalbot-agent/src/process.rs` (`unix::spawn`), `LinuxWindows/crates/lokalbot-app/src/pages/agent/model.rs` (`AgentModel::new`).

### pi's child is reaped only by `stop` or `Drop`

The waiter never reaps it, so the PID and its process group cannot be reused while they may still be signalled.

Where: `LinuxWindows/crates/lokalbot-agent/src/process.rs` (`PiProcess.child`).

### Writing to pi's stdin never blocks the session

stdin is a bounded, serial channel: on Linux and Windows it is written on its own thread, and on the Mac `DispatchIO` owns a duplicated descriptor, so writes never block the `PiProcess` actor and `close()` can cancel an in-flight write even when the child has stopped draining its pipe.

Where: `LokalBot/Agent/PiProcess.swift` (`PiStdinWriter`), `LinuxWindows/crates/lokalbot-agent/src/process.rs`.

### RPC results go to the session's sink and are never awaited

The process reader feeds every stdout record to `RpcClient::handle_line`; a `response` whose id matches a pending request completes it, and everything else is forwarded as an event. Results are delivered to the sink rather than awaited, so one slow acknowledgement (pi's `abort` waits for idle) can never stop approvals or other events from being handled.

Where: `LokalBot/Agent/PiRPCClient.swift`, `LinuxWindows/crates/lokalbot-agent/src/rpc.rs`.

### Under backpressure only text deltas are dropped

Text deltas are the only messages dropped when the inbox is full; anything else waits, and pi honors the backpressure on its stdout. The event queue keeps its oldest entries so a burst can never evict an already-buffered approval, and dropping any structural event ends the stream deterministically.

Where: `LokalBot/Agent/PiRPCClient.swift` (`PiRPCClient.emit`), `LinuxWindows/crates/lokalbot-agent/src/session.rs` (`AgentSession::client_sink`).

### A turn is finished at `agent_settled`, not `agent_end`

`agent_end` can come before an automatic retry or compaction; the pinned pi runtime emits `agent_settled` only once the whole run is idle.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.handle`), `LinuxWindows/crates/lokalbot-agent/src/session.rs` (`AgentSession::handle_event`).

### Abort cancels waiting approvals first and lets a sent acknowledgement settle

pi's confirmation promise has no abort signal, so waiting approvals are resolved as cancelled before the abort, or pi's abort RPC waits forever for idle. Once an RPC is sent, cancelling its acknowledgement would report a transport failure and requeue an already-delivered prompt, so that acknowledgement is left to settle while abort stops the turn on its own.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.abort`), `LinuxWindows/crates/lokalbot-agent/src/session.rs` (`AgentSession::abort`).

### Closing or failing a task invalidates its generation before the process stops

On failure the generation is invalidated before the process stop, so frames already buffered cannot revive the task. Closing or restarting a tab invalidates an in-flight start, because a close during model warm-up could otherwise finish spawning pi after `shutdown()` had already returned.

Where: `LinuxWindows/crates/lokalbot-agent/src/session.rs` (`AgentSession::transition_to_failure`), `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.lifecycleGeneration`).

### A new pi never starts while the old one is still stopping

A start waits for shutdown stops that are still running, so two pi processes never share one session file. Failure cleanup is serialized with shutdown and restart: the failed state is not published, and restart stays disabled, until the old process has actually ended.

Where: `LinuxWindows/crates/lokalbot-agent/src/session.rs` (`AgentSession.stops_pending`, `AgentSession::transition_to_failure`), `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.failureTeardownInProgress`).

### Closing a tab revokes library access before pi's SIGTERM grace period

Closing a tab closes the meeting-library capability immediately, even if pi ignores termination until the SIGKILL fallback.

Where: `LokalBot/Agent/AgentSessionController.swift` (`AgentSessionController.shutdown`).

## Conversations and results

### Only the latest branch of a pi conversation is shown

pi session files hold a tree. Only the ancestor chain of the most recent leaf is visible, so abandoned branches never leak into previews or a new fork.

Where: `LokalBot/Agent/AgentConversationArchive.swift` (`AgentConversationArchive.activeBranch`).

### Tool arguments are stored and shown as canonical JSON

Compact JSON with recursively sorted keys and unescaped slashes keeps displayed arguments and stored data stable whatever serde_json's map ordering is.

Where: `LinuxWindows/crates/lokalbot-agent/src/messages.rs` (`canonical_json`).

### A step's label never hides what ran

Only `lokalbot-cli` calls made of plain words get a name for what they look up; anything a shell could chain or redirect is a command, shown with its text.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/agent/words.rs` (`command_label`), `LokalBotTests/Agent/AgentPresentationTests.swift` (`testOtherCommandsShowTheirText`).

### Opening a result preview never runs a tool

The results panel beside the conversation shows the files the task changed, its steps, the sources it was given and a preview of the chosen one, and opening a preview never runs a tool.

Where: `LokalBot/Views/Agent/AgentResultsPanel.swift`, `LinuxWindows/crates/lokalbot-app/src/pages/agent/results.rs`.

## Handing work to installed coding agents

### Handoff fills the agent's input and never sends the prompt

Handing an action or a meeting to a coding agent installed on this computer leaves the prompt unsent on every route: a deep link fills the agent's input box, and an agent with no link starts in a new terminal with the prompt on the clipboard to paste. Nothing leaves this computer until the user sends it there.

Where: `LokalBot/Support/ActionAgentHandoff.swift` (`ActionAgentHandoff`), `LokalBot/Support/ExternalAgentHandoff.swift`, `LinuxWindows/crates/lokalbot-app/src/agent_handoff.rs`, `LinuxWindows/crates/lokalbot-core/src/agent_handoff.rs`.

### No prompt ever goes on a command line

A new terminal only runs a program the caller located, and no prompt is passed on its command line, where a terminal or a shell could read it as more than text. So Codex has no terminal route: its CLI has no documented way to fill a prompt without sending it.

Where: `LinuxWindows/crates/lokalbot-platform/src/agent_links.rs` (`open_in_terminal`), `LinuxWindows/crates/lokalbot-app/src/agent_handoff.rs` (`Route::Terminal`).

### Handoff prompts are capped at Claude Code's deep-link limit

Claude Code cuts a deep link's `q` at about 14,000 characters. Codex documents no limit and gets the same budget, so both apps open with the same notes.

Where: `LokalBot/Support/ActionAgentHandoff.swift` (`ActionAgentHandoff.promptCharacterLimit`), `LinuxWindows/crates/lokalbot-core/src/agent_handoff.rs` (`MEETING_PROMPT_LIMIT`).

### Deep-link query values percent-encode `+`, `&` and `=`

`URLComponents` leaves `+`, `&` and `=` bare, and the `URLSearchParams` parsing in both apps reads a bare `+` as a space and `&` as a new parameter, so the encoder keeps every such character out of a link's query.

Where: `LokalBot/Support/ExternalAgentHandoff.swift` (`ExternalAgentHandoff.encodeQueryValue`), `LinuxWindows/crates/lokalbot-core/src/agent_handoff.rs` (`encode_query_value`), `LokalBotTests/Support/ExternalAgentHandoffTests.swift` (`testPromptSurvivesQueryParsing`).

### The Claude Code terminal route uses `claude-cli://open`

It opens Claude Code in a new window of the terminal it last ran in. Claude Code registers this handler itself, only after the first prompt of an interactive session.

Where: `LokalBot/Support/ActionAgentHandoff.swift` (`ActionAgentHandoff.Route.claudeCodeTerminal`).

### Agent CLIs are also looked up through the login shell

A command is found on PATH or where Claude Code's and Codex's installers put it. A desktop session started from a launcher can have a minimal PATH, so once a menu has asked, a CLI under a Node version manager is found through the login shell, at most once per launch.

Where: `LinuxWindows/crates/lokalbot-app/src/agent_handoff.rs` (`locate_command`).

### Handoff packages are pruned after 7 days

A handoff package is kept 7 days. Old packages used to be removed only when the next one was written, so after a single handoff the window's text and screenshot stayed in the library.

Where: `LokalBotTests/Services/ScreenMemory/ScreenshotProcessingWorkerTests.swift` (`ScreenshotRetention` handoff packages).

## Consequences

- Approval is an allowlist enforced by both the extension and the host. A new pi tool, pi release or path rewrite must ask by default, and any pi upgrade means rechecking pi's path rewriting, hook return values and event order (pi 1.5.2 is what these rules were checked against).
- The Mac and the Windows and Linux app ship two copies of the extension (`index.ts`) and two implementations of the launch contract, approval policy and plan relay; a change on one side has to be made on the other.
- Keys, plan tokens and pi's process tree stay on LokalBot's side: nothing the agent's shell can reach may hold a credential, and nothing pi starts may outlive LokalBot or a closed tab.
