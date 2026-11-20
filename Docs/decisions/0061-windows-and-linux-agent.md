# 0061. Windows and Linux: agent

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-agent/examples/`, `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/`, `LinuxWindows/crates/lokalbot-agent/resources/tests/`, `LinuxWindows/crates/lokalbot-agent/src/archive.rs`, `LinuxWindows/crates/lokalbot-agent/src/context.rs`, `LinuxWindows/crates/lokalbot-agent/src/digest.rs`, `LinuxWindows/crates/lokalbot-agent/src/endpoint.rs`, `LinuxWindows/crates/lokalbot-agent/src/fileurl.rs`, `LinuxWindows/crates/lokalbot-agent/src/frame.rs`, `LinuxWindows/crates/lokalbot-agent/src/fsutil.rs`, `LinuxWindows/crates/lokalbot-agent/src/history.rs`, `LinuxWindows/crates/lokalbot-agent/src/install.rs`, `LinuxWindows/crates/lokalbot-agent/src/launch.rs`, `LinuxWindows/crates/lokalbot-agent/src/launcher.rs`, `LinuxWindows/crates/lokalbot-agent/src/layout.rs`, `LinuxWindows/crates/lokalbot-agent/src/lib.rs`, `LinuxWindows/crates/lokalbot-agent/src/manifest.rs`, `LinuxWindows/crates/lokalbot-agent/src/messages.rs`, `LinuxWindows/crates/lokalbot-agent/src/policy.rs`, `LinuxWindows/crates/lokalbot-agent/src/presentation.rs`, `LinuxWindows/crates/lokalbot-agent/src/process.rs`, `LinuxWindows/crates/lokalbot-agent/src/resources.rs`, `LinuxWindows/crates/lokalbot-agent/src/rpc.rs`, `LinuxWindows/crates/lokalbot-agent/src/session.rs`, `LinuxWindows/crates/lokalbot-agent/src/session_tests.rs`, `LinuxWindows/crates/lokalbot-agent/src/shell.rs`, `LinuxWindows/crates/lokalbot-agent/src/tabs.rs`, `LinuxWindows/crates/lokalbot-agent/src/tasks.rs`, `LinuxWindows/crates/lokalbot-agent/src/transcript.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-agent/examples/agent_turn.rs`

#### agent_turn example runs one Agent turn headless with CLI flags
One Agent Mode turn against the real runtime and model, without the UI
(`LokalBot --agent` on macOS). Drives the same task list and session code
the Agent page uses, answers each approval card from the command line, and
checks the result.

```text
agent_turn <library> --workspace <dir> [--install] [--download-model]
           [--approve | --deny] [--expect-file <path> [--expect-text <text>]]
           [--expect-missing <path>] [--cli <dir>] [--powershell]
           [--timeout <seconds>] <prompt>
```

`--install` sets up Bun and pi in `<library>/runtimes/agent-runtime`;
`--download-model` fetches the built-in Think model and llama.cpp runtime
named by `<library>/settings.json` when they are missing. `--powershell`
gives the agent pi's PowerShell tool, as on Windows without Bash.

#### Without credential store a plan task reports unreadable sign-in
`agent_turn.main PiLauncher`: Without the app's credential store, a plan task reports that the
sign-in can't be read.

### `LinuxWindows/crates/lokalbot-agent/resources/lokalbot-extension/index.ts`

#### Extension registers model, gates tools, resolves paths exactly as pi 1.5.2
LokalBot pi extension: registers the app-configured model as a provider,
gates every tool except workspace reads behind the host UI, and adds the
per-run facts that LokalBot's system prompt refers to.

Runs inside pi (RPC mode) under Bun. The env contract comes from the launch
planner (lokalbot-agent/src/launch.rs); the confirm() below surfaces in
LokalBot as an extension_ui_request on stdout, answered over stdin.

Linux and Windows port of LokalBot/Resources/pi/lokalbot-extension: paths
are resolved exactly as pi 1.5.2's file tools resolve them (Windows drive
paths such as /c/Users, a leading "@", Unicode spaces, "~\\"), so the
approval card always names the file pi will touch, and PowerShell commands
are reviewed like Bash commands.

#### Other tools are reviewed from exact arguments that must fit in full
`PREVIEWED_TOOLS`: Tools whose approval card shows a dedicated preview. Any other tool is
reviewed from its exact arguments, which must fit in full.

#### PowerShell tool shares the bash tool's arguments
`SHELL_TOOLS`: Tools whose whole request is one shell command. pi's optional Windows
`powershell` tool shares the bash tool's arguments.

#### Chat completions for local servers; Responses API for ChatGPT plan relay
`PROVIDER_APIS`: Chat completions for local and OpenAI-compatible servers; the Responses
API for LokalBot's ChatGPT plan relay.

#### Plan route needs developer messages, encrypted reasoning replay, no output caps
`RESPONSES_MODEL_TRAITS`: pi-ai sends a reasoning model's instructions as a developer message (the
plan route rejects system messages) and replays its encrypted reasoning.
The route also rejects output caps.

#### Budgets mirror ThinkReasoningLevel.budgetTokens so levels match summaries
`THINKING_BUDGETS`: ThinkReasoningLevel.budgetTokens, so a level means the same thinking
allowance in Agent Mode as in summaries.

#### Keep provider key on globalThis, out of shell-inherited environment
`takeProviderAPIKey`: The provider key stays inside this process. pi gives every shell command
a copy of its environment, so a command or a script it starts could
otherwise read the key. pi evaluates this module again for a new session,
so the key is kept on globalThis rather than read from the environment.

#### llama.cpp ignores the key; Ollama and LM Studio may want one
`takeProviderAPIKey`: llama.cpp ignores the key; Ollama/LM Studio may want one.

#### Pi's own HTTP client needs injected fetch; reasoning level read per request
`lokalbotExtension streamSimple`: Pi has its own HTTP client: the host's URLSession redirect policy does
not cover it. Inject only this provider's supported transport hook.
LokalBot writes the Agent reasoning level (already limited to what the
model accepts) to a file it may change mid-task; read it per request.

#### Model input must be set; pi's registerProvider does not default it
`lokalbotExtension registerProvider`: Required: pi's registerProvider path does NOT default `input`
(unlike its models.json path), and pi-ai's openai-completions
dereferences model.input unguarded — omitting this crashes every
completion with "undefined is not an object".

#### Shell command must fit approval payload in full; never approve a prefix
`lokalbotExtension tool_call`: The exact shell command must fit in the approval payload. Never ask for
approval of a prefix and then execute the unchanged, longer request.

#### Resolve relative paths against session folder, not process cwd
`lokalbotExtension tool_call`: pi's tools resolve relative paths against the session folder: the
folder a resumed session was saved with, not necessarily this process's.

#### Approval payload is machine-parseable so host renders exact changes
`lokalbotExtension tool_call`: Machine-parseable payload: the host renders exact commands and file
changes, rather than relying on a model-authored summary.

#### Environment section is last prompt section so date changes cache daily
`environmentSection`: The facts LokalBot's system prompt points to: today's date, what the
working folder is, and which model answers. It is the last prompt section,
and pi folds a changed section into the leading system message for this
provider, so the date only changes the cached prompt once a day.
`servedBy` names a plan's provider when a local relay forwards to it.

#### Reject all redirects since approval covers one origin
`inferenceFetchForOrigin`: A launched Agent task has approval for one origin. Reject redirects before
the HTTP client can replay context or credentials, including same-origin
redirects: configure the final inference endpoint instead.

#### Reasoning file format; missing or unreadable means Automatic
`readReasoningLevel`: `{"level": "<ThinkReasoningLevel>"}`. Missing or unreadable: Automatic,
which leaves every request exactly as pi built it.

#### Mirrors OpenAICompatibleEngine.applyGenerationOptions; Automatic leaves request unchanged
`applyReasoningLevel`: Mirrors OpenAICompatibleEngine.applyGenerationOptions for a level the host
already limited to the model's (ReasoningSupport). Automatic leaves every
request exactly as pi built it.

#### Zero thinking budget alone still opens Qwen's thinking turn
`applyReasoningLevel llama-server`: A zero budget alone still opens Qwen's thinking turn.

#### Only gpt-oss takes graded level; others can only switch off
`applyReasoningLevel ollama`: Only gpt-oss takes a graded level; other thinking models can only be
switched off, which the host limits the level to.

#### Responses API takes level as reasoning.effort like plan engine
`applyResponsesReasoningLevel`: The Responses API takes a level as `reasoning.effort`, as the ChatGPT plan
engine sends it. Automatic leaves pi's request as built.

#### Retry once when server rejects reasoning level; none becomes low
`retryRejectedReasoning`: A chosen level can be one the selected model does not accept. When the
server names reasoning in a 400/422, retry once: `none` becomes `low` for
models that always reason; any other level falls back to the server's
default. Mirrors OpenAICompatibleEngine.shouldRetryRejectedReasoningLevel.

#### Mirrors pi 1.5.2 handling of Git Bash, MSYS, Cygwin, WSL drive paths
`normalizeWindowsShellPath`: pi 1.5.2 `normalizeWindowsShellPath`: Git Bash, MSYS, Cygwin and WSL drive paths.

#### Mirrors pi 1.5.2 normalizePath; forTool adds file-tool options
`normalizeToolPath`: pi 1.5.2 `normalizePath`. `forTool` adds the options its file tools pass.

#### Mirrors pi 1.5.2 resolveToCwd used by write and edit
`resolveToCwd`: pi 1.5.2 `resolveToCwd`, which its write and edit tools use.

#### Read check follows pi's look-alike filename fallback to the real file
`resolveReadPath`: pi 1.5.2 `resolveReadPath`: a missing file is opened through a look-alike
name when one exists, so a read is checked against the file pi will open.

#### Returns the file pi will open, or undefined when uncertain
`requestedPath`: The file pi's tool will open, or undefined when that is not certain.

#### Canonicalize nearest existing ancestor; dangling link fails closed
`canonicalize`: Canonicalize the nearest existing ancestor so a path through a symlink
cannot escape merely because its final component does not exist yet.
A dangling link stops the walk and fails closed.

#### relative compares case-insensitively on Windows and spans drives
`isInside`: `relative` compares case-insensitively on Windows and spans drives.

#### Only reads inside workspace and outside private library skip approval
`requiresApproval`: Allowlist: a read inside the selected workspace and outside the private
library is the only call that runs without asking. Every other tool asks,
including MCP tools, codemode, and tools that later Pi releases add.

#### Unresolvable paths and ancestor workspaces never exempt private library
`requiresApproval`: Missing/unresolvable paths are never silently treated as in-workspace.
Choosing Home or another ancestor as a workspace does not silently make
the private library, server credentials, or Agent history normal files.

#### Argument text is length-checked before approval is requested
`approvalPayload`: Checked against MAX_APPROVAL_TEXT before approval is requested.

### `LinuxWindows/crates/lokalbot-agent/resources/tests/pi-runtime.test.ts`

#### Runs macOS pi-runtime suite against Linux/Windows extension with pinned runtime
The macOS suite (Scripts/tests/pi-runtime.test.ts) run against the Linux and
Windows extension, plus the cases this port adds. Run against a
checksum-pinned, frozen-lockfile runtime:
  LOKALBOT_PINNED_RUNTIME_ROOT=\<library>/runtimes/agent-runtime \
bash crates/lokalbot-agent/resources/tests/run-pi-runtime-tests.sh

#### Use junctions on Windows because they need no privileges
`linkDirectory`: Directory links that need no privileges on Windows.

#### Blocking result must be returned even if fake UI approves everything
`withExtensionFixture`: Exercise the actual extension hook without a model, library, or tool runner.
Returning undefined is what allows Pi to execute, so a blocking result must
be returned even if the fake UI would approve every request.

#### cwd is the session folder pi resolves tool paths against
`withExtensionFixture call`: `cwd` is the session folder pi resolves tool paths against (ctx.cwd).

#### Test that pi's bash tool does not inherit the provider key
`withExtensionFixture API key test`: pi's bash tool spawns each command with a copy of process.env.

#### Pi re-evaluates extension per session, so key must persist
`withExtensionFixture API key test`: pi evaluates the extension again for a new session.

#### Resumed session resolves paths against the folder it was saved with
`resumed session path test`: pi resolves against ctx.cwd: a resumed session keeps the folder it was saved with.

#### Fixture mimics OpenAI Responses event stream order
`responsesStream`: A Responses event stream as OpenAI sends it: each output item added, its
text, the item done, then the completed response.

#### Fixture mimics plan relay: encrypted reasoning, tool call, then answer
`responsesTurn`: What LokalBot's ChatGPT plan relay passes back: encrypted reasoning and a
tool call, then the answer once the tool's output comes in.

#### Runs one RPC turn against stub model and answers approvals uniformly
`piTurn`: One Pi RPC turn against a stub model that requests `toolCall` and then
replies STUB-REPLY. Every approval prompt is answered with `approved`.

#### Windows child processes need SystemRoot, TEMP and system environment
`piTurn`: Windows processes need SystemRoot, TEMP and the rest of the system set.

#### Test env mirrors launch plan: no transpiler caches outside runtime
`piTurn`: As in the launch plan: no transpiler caches outside the runtime.

#### MCP client is loaded explicitly to prove its tools pass the gate
`STUB_MCP_SERVER`: Pi's MCP client is a built-in extension that Agent Mode's --no-extensions
leaves off. Loading it explicitly proves its tools still pass the gate.

#### Small-model templates reject later system messages; pi folds into first
`piTurn system prompt test`: Small local models' chat templates reject a system message after the
first; Pi folds the changed prompt into the leading one instead.

#### Responses provider sends developer instructions and no output cap
`Responses provider test`: Instructions go out as a developer message, and no output cap.

#### store false means pi replays encrypted reasoning with call and output
`Responses turn test`: store: false keeps nothing on OpenAI's side, so pi replays the
encrypted reasoning with the call and its output.

#### Resolving @ as workspace-relative would have skipped approval of library file
`leading @ path test`: pi strips the "@" and opens the library file; resolving "@…" as a
workspace-relative name would have let it through without asking.

#### Pi opens curly-apostrophe variant when typed name is missing
`curly apostrophe path test`: pi opens the curly-apostrophe variant when the typed name is missing.

### `LinuxWindows/crates/lokalbot-agent/resources/tests/run-pi-runtime-tests.sh`

#### Run extension tests with pinned Bun without installing into checkout
Runs the extension suite with the pinned runtime's Bun, resolving the
extension's imports from that runtime without installing anything into the
checkout or modifying the installed runtime (Scripts/tests/run-pi-runtime-tests.sh).

#### Disable transpiler caches so nothing lands in ~/.bun or /tmp
No transpiler caches: Bun and jiti would keep them in ~/.bun and /tmp.

### `LinuxWindows/crates/lokalbot-agent/src/archive.rs`

#### Opening saved conversation needs no model, process, tool run or grant
Read-only transcript loading and branching (`AgentConversationArchive.swift`).
Opening a saved conversation needs no model, process, tool run or grant.

#### Only newest leaf's ancestors are visible; abandoned branches never leak
`active_branch`: pi files hold a tree; only the newest leaf's ancestors are visible, so
abandoned branches never leak into previews or forks.

#### Fork includes recorded tool results so no dangling calls remain
`fork`: Writes a new session file through `item` (the `matching_occurrence_from_end`
-th identical message, counted from the end), including the recorded
results of its tool calls, so the fork never has dangling calls.

### `LinuxWindows/crates/lokalbot-agent/src/context.rs`

#### Store only references; reread with current permissions on each send
Attached sources (`AgentContextResolver.swift`): files, meetings and saved
screen moments. Only references are stored; the text is read again, with
the current permissions, each time a message is sent, and appended to the
prompt as reference data the model is told not to follow as instructions.

#### Prompt appends sources as one JSON array with sorted keys
`ContextResolver.prompt`: The prompt pi receives: the user's text, then the attached sources as
one JSON array with sorted keys.

#### Meeting folders resolving outside the library are never read
`ContextResolver.meeting_text`: A meeting folder that resolves outside the library is not read.

#### Recheck screen grant after reading since it may be revoked
`ContextResolver.moment_text`: The grant may have been revoked while the text was being read.

#### Saved moments limited to current screen grant, newest first
`ContextResolver.saved_moments`: Saved moments inside the current screen-memory grant, newest first.

#### Documents limited to UTF-8 text, 256 KiB, no NUL bytes
`read_document`: A UTF-8 text file of at most 256 KiB without NUL bytes.

### `LinuxWindows/crates/lokalbot-agent/src/digest.rs`

#### Tree digest uses macOS record format so digests match Mac app
SHA-256 of files and of whole folders (`SHA256Verifier` in
`AgentRuntime.swift`). The tree digest uses the macOS record format, so a
digest computed here means the same thing as one computed by the Mac app.

#### Stream hashing so the ~80 MB Bun binary is never fully in memory
`file_hex`: Streaming digest so the ~80 MB Bun binary never lands in memory at once.

#### Tree digest ordering, record types, symlink and metadata rules for reproducibility
`tree_hex`: Deterministic digest of a folder's complete shape and contents. Records
are ordered by raw UTF-8 name within each folder, length-delimited, and
tagged by type. Symlinks hash their link text and are never followed;
regular files hash their bytes; folders are recorded so empty or extra
folders change the digest. Metadata and absolute paths are left out, so
identical installs hash identically.

#### Receipt fields must be lowercase 64-character hex
`is_hex_digest`: Lowercase 64-character hex, as every receipt field must be.

#### Hand-computed vector matches SHA256Verifier.treeHexDigest on macOS
`tree_digest_uses_the_macos_record_format`: Matches `SHA256Verifier.treeHexDigest` on macOS for the same layout:
one folder `d` holding `f` = "x". Computed by hand from the record
format (kind, u64 big-endian length + path, u64 length + payload).

### `LinuxWindows/crates/lokalbot-agent/src/endpoint.rs`

#### Endpoint resolution: leases, remote consent, HTTPS requirement, plan relay
The endpoint pi's `lokalbot` provider talks to (`AgentLLMEndpoint.swift`,
`ThinkExecution.agentResolution`).

The built-in Think model is the llama-server `Role::Main`; a session holds
a [`lokalbot_ai::Lease`] on it so an unrelated model load cannot unload it
mid-conversation. Ollama and OpenAI-compatible servers follow the same
remote-origin consent as the rest of Think, and Agent Mode additionally
requires HTTPS for anything that is not on this computer (the extension
enforces it again). The ChatGPT plan is reached through a relay on this
computer that holds the plan's tokens
([`lokalbot_ai::plans::chatgpt::relay`]); its own approval stands in for
the origin check.

#### Dialect selects request fields the extension writes for reasoning level
`ReasoningDialect`: Which request fields carry a reasoning level to this server. The
extension writes them (`applyReasoningLevel` in its index.ts).

#### Mirrors Swift ChatCompletionDialect.inferred(from:)
`ReasoningDialect.inferred`: `ChatCompletionDialect.inferred(from:)`.

#### Variants are pi-ai's names for Agent Mode wire formats
`ProviderApi`: pi-ai's names for the wire formats Agent Mode uses.

#### Base URL ends in /v1 for llama-server and Ollama
`LlmEndpoint.base_url`: Ends in `/v1` for llama-server and Ollama.

#### Plan relay is local but content goes to plan's provider
`LlmEndpoint.plan`: Set when requests run on a subscription plan through LokalBot's
relay: `base_url` is on this computer, but the content goes to the
plan's provider.

#### Match built-in Think window so compaction boundary agrees
`DEFAULT_CONTEXT_TOKENS`: Matches the built-in Think server's window, so Agent Mode compacts at the
same boundary; external servers use it as a conservative declared window.

#### Caller leases the built-in server and builds endpoint
`Resolution::BuiltIn`: The caller leases the built-in server and builds the endpoint from it.

#### Caller starts a plan relay per task and points pi at it
`Resolution::ChatGptPlan`: The caller starts a ChatGPT plan relay for the task and points pi at it.

#### Pure settings-to-endpoint resolution; presentation passes no API key
`resolve`: Settings to endpoint, without starting anything. `api_key` is the stored
OpenAI-compatible key (presentation passes `None`).

#### Plan reached via relay holding tokens, so no credentials read
`resolve ChatGptPlan`: pi reaches the plan through a relay that holds the tokens, so
nothing here reads credentials.

#### CLI-backed plans offer no model endpoint for pi
`resolve CLI plans`: CLI-backed plans run their own coding-agent CLI; they offer no model
endpoint for pi to call.

#### Anthropic chat completions live under /v1 whatever URL form was entered
`anthropic_chat_root`: pi speaks chat completions, which Anthropic serves under `/v1` whichever
form of its URL was entered (`AnthropicAPI.versionedRoot`).

#### Composer footer shows where the task's model runs
`Destination`: Where a task's model runs, for the composer footer (`InferencePresentation`).

#### Model and destination mirror AgentSessionController.ModelContext
`ModelContext`: The model a task uses and where it runs (`AgentSessionController.ModelContext`).

#### Context bound to launched connection despite later Settings changes
`ModelContext.from_endpoint`: Bound to a launched connection, even if Settings change later.

#### Plan relay listens locally but plan's provider answers
`ModelContext.from_endpoint`: A plan relay listens on this computer; the plan's provider answers.

#### API-server approval for same company is not plan approval
`chatgpt plan approval test`: An API-server approval for the same company is not the plan's.

#### Stored API key is never the plan's credential
`chatgpt plan approval test`: A stored API key is never the plan's credential.

#### Approved Claude plan still unsupported: Claude Code offers no endpoint
`the_claude_plan_is_not_an_agent_endpoint`: Even an approved plan: Claude Code offers no model endpoint.

#### Approved plain HTTP on private network is refused like Think
`remote_servers_need_approval_and_https`: Approved but plain HTTP on a private network: refused, as for Think.

### `LinuxWindows/crates/lokalbot-agent/src/fileurl.rs`

#### file URLs match Swift JSONEncoder so Mac and port metadata interoperate
`file://` URLs as Swift's `JSONEncoder` writes `URL` values, so task
metadata written by the Mac app reads here and the other way round.

#### Directory URLs end in slash like URL(fileURLWithPath:)
`to_file_url`: `file:///home/me/Work%20Folder/` (directories end in `/`, like
`URL(fileURLWithPath:)` for an existing folder).

#### Windows drive paths get an extra leading slash
`to_file_url`: `C:/…` on Windows

#### Plain absolute paths are accepted as well as file URLs
`from_file_url`: The path of a `file://` URL; a plain absolute path is accepted too.

#### file://localhost/ equals file:///
`from_file_url`: `file://localhost/…` is the same as `file:///…`.

### `LinuxWindows/crates/lokalbot-agent/src/frame.rs`

#### Frame by LF on raw bytes; U+2028/2029 never split records
Splits pi's stdout into JSONL records (`PiJSONLFrameSplitter.swift`).

pi's RPC framing (docs/rpc.md): LF (0x0A) is the only record delimiter;
one trailing CR is stripped; U+2028/U+2029 inside JSON strings must not
split records. That is why this works on raw bytes and why the process
reader never uses a string-based line reader.

#### Limit applies to records and commands written to stdin
`MAX_FRAME_BYTES`: The largest record (and the largest command written to stdin).

#### Call on EOF to drain an unterminated final record
`FrameSplitter.flush`: Drains an unterminated final record (call on EOF).

#### Test splits mid-record and mid-UTF-8 sequence
`reassembles_records_across_chunks`: Split mid-record and mid-UTF-8 sequence (é is two bytes).

### `LinuxWindows/crates/lokalbot-agent/src/fsutil.rs`

#### Task metadata and session history are owner-only
Owner-only folders and files for task metadata and session history.

### `LinuxWindows/crates/lokalbot-agent/src/history.rs`

#### Stream list metadata without retaining prompts; load contents only when opened
Saved pi sessions (`AgentSessionHistory.swift`): list metadata streamed
from each JSONL file in the sessions folder, without keeping prompts or
responses in memory. Conversation contents load only when opened.

#### File path identifies a saved session
`SavedSession.id`: The file path, which identifies a saved session.

#### Sessions sorted most recently active first
`load`: Every readable saved session, most recently active first.

#### Symlinks and folders are never listed
`load`: Symlinks and folders are never listed.

#### Load one session file for a task that knows its file
`load_file`: One session file of `directory` (for a task that knows its file).

#### Reread before opening so stale entry or symlink cannot redirect launch
`validated`: Re-reads the file just before opening, so a stale list entry, a replaced
file or a symlink cannot redirect an exact-session launch.

#### Dates are epoch milliseconds or ISO 8601 strings
`date`: Milliseconds since 1970, or an ISO 8601 string.

#### Title is first line, whitespace collapsed, cut near 80 characters
`display_title`: The first line, whitespace collapsed, cut at a word near 80 characters.

### `LinuxWindows/crates/lokalbot-agent/src/install.rs`

#### Stage whole setup and swap in only after all digests match
Agent Mode setup (`AgentRuntimeInstaller.swift`): downloads and verifies
Bun, then installs pi from the public npm registry with the frozen
lockfile bundled in the app. Everything is assembled in a staging folder
and swapped into place only after every digest matched, so a failed setup
leaves nothing half-written.

#### Progress is 0 to 1, or None when size unknown
`InstallPhase::Downloading`: 0…1, or `None` when the size is unknown.

#### Fetch verifies size and digest of pinned artifact
`Fetch`: Downloads one pinned artifact to `dest`, verifying size and digest.

#### Cheap receipt check used when Agent page opens
`Installer.initial_phase`: The cheap receipt check used when the Agent page opens.

#### Skip when installed; force repairs; call blocks
`Installer.install`: Installs unless already installed (`force` repairs). Blocking.

#### Recheck digest after fetch so a hook cannot skip it
`install_into`: The fetch verifies the digest; check again so a hook cannot skip it.

#### Move old runtime aside first so failed rename leaves no half-removed folder
`install_into`: Swap: the old runtime (if any) moves aside first, so a failed
rename never leaves a half-removed folder in place.

#### User's Verify Agent runtime hashes every runtime file
`Installer.verify`: The user's "Verify Agent runtime": hashes every runtime file.

#### Private bun cache in staging; lockfile integrity still checked
`package_install_command`: A private cache inside staging: nothing lands in the user's
~/.bun, and no stale cache entry can stand in for a download
(the lockfile's integrity hashes are still checked).

#### Install with frozen lockfile and no scripts into template folder
`install_packages`: `bun install --production --frozen-lockfile --ignore-scripts` in
`destination`, which already holds the package template.

### `LinuxWindows/crates/lokalbot-agent/src/launch.rs`

#### Isolated, offline pi launch contract and Linux/Windows additions
The exact pi launch contract (`PiLaunchPlanner.swift`).

pi is isolated from the user's `~/.pi` and any folder-local pi
configuration (`--no-extensions -e`, `--no-skills --skill`,
`--no-prompt-templates`, `--no-approve`) and offline (`--offline` and
`PI_SKIP_VERSION_CHECK`, since pi ships update checks and install
telemetry on by default). Context files are disabled because pi's upward
discovery is not confined to the working folder; workspace files stay
readable through the read tool, which the extension gates. LokalBot's own
system prompt replaces pi's coding-agent prompt; the extension appends the
per-run environment.

Additions on Linux and Windows: Bun runs with `--no-install` so a missing
import can never be fetched from npm at run time; Bun's transpiler cache
and jiti's extension cache are off, since they would keep compiled copies
of pi and of the approval extension in `~/.bun` and the shared temporary
folder, outside the audited runtime; `LOKALBOT_STORAGE_ROOT`
points the bundled `lokalbot-cli` at this library; on Windows without Bash
the model gets pi's PowerShell tool instead (see [`crate::shell`]).

#### Maps to pi --continue: most recent session for working folder
`SessionChoice::ContinueRecent`: pi's `--continue`: the most recent session for this working folder.

#### Tells extension's environment prompt section what the working folder is
`WorkspaceKind`: What the working folder is, for the extension's environment prompt section
(`AgentWorkspaceKind` in `PiLaunchPlanner.swift`).

#### Replaces pi's default system prompt via --system-prompt
`PlanInputs.system_prompt`: Replaces pi's default system prompt (`--system-prompt`).

#### Holds lokalbot-cli which the skill calls by name
`PlanInputs.helpers_dir`: Holds `lokalbot-cli`, which the skill calls by name.

#### --tools override needed when Windows has no Bash
`PlanInputs.tools`: `--tools`, when the default tool set must change (Windows without Bash).

#### Plan relay is local but model is not; extension names who serves it
`plan`: A plan relay is on this computer; the model is not. The extension's
environment section says who serves it.

#### Host rewrites reasoning file; extension reads it per request; absent means Automatic
`plan`: The host rewrites this file when the reasoning level changes; the
extension reads it before every model request. Absent: Automatic.

#### Encoding failure must stop extension, never omit protected roots
`plan`: An encoding failure must stop the extension at startup, never omit the
protected roots: `null` fails its launch validation.

#### Keyless endpoint must not inherit another service's key; extension strips key from shell env
`plan`: A credential-free endpoint must not inherit a key for another service.
The extension takes the key at startup and removes it from the
environment the agent's shell commands inherit.

#### Windows environment names are case-insensitive; keep one entry
`same_name`: Environment names are case-insensitive on Windows ("Path"); keep one entry.

### `LinuxWindows/crates/lokalbot-agent/src/launcher.rs`

#### Launcher resolves endpoint, audits runtime, issues scoped grant, starts pi
The real [`Launcher`]: resolves the Think endpoint (leasing the built-in
llama-server when that is the model, or starting a ChatGPT plan relay),
audits the runtime, issues a scoped `lokalbot-cli` grant, writes the
extension and starts pi (`AgentSessionController.start`,
`ThinkExecution.prepareAgentConnection`).

#### Scoped grant lasts at most a day; revoked on stop
`CAPABILITY_LIFETIME_HOURS`: A scoped grant lasts at most a day; revoking it on stop is the norm.

#### Engine's llama.cpp runtime serves the built-in model
`PiLauncher.runtime`: The app's llama.cpp runtime (the engine's), for the built-in model.

#### Stored OpenAI-compatible key is read at launch only
`PiLauncher.api_key`: The stored OpenAI-compatible key, read at launch only.

#### Plan task's relay draws tokens from this sign-in
`PiLauncher.chatgpt_account`: The ChatGPT plan sign-in a plan task's relay draws its tokens from.

#### Folder with lokalbot-cli goes first on agent PATH
`PiLauncher.helpers_dir`: The folder holding `lokalbot-cli`, put first on the agent's PATH.

#### None means detect the command shell
`PiLauncher.shell`: The command shell; `None` detects it ([`ShellChoice::detect`]).

#### Connection holds what must stay alive while task runs
`PiLauncher.connect`: The endpoint, with what must stay alive while the task runs.

#### Read keyring only for OpenAI-compatible; it can block without secret service
`PiLauncher.connect`: Only an OpenAI-compatible server takes a key; reading the system
keyring can block for a long time when no secret service answers.

#### Relay on loopback gives pi random key; only relay holds tokens
`connect_chatgpt_plan`: A relay for this task on 127.0.0.1. pi gets its random key; only the
relay holds the plan's tokens.

#### Missing sign-in opens Models at launch, not at first turn
`connect_chatgpt_plan`: A missing sign-in opens Models now instead of failing the first turn.

#### Lease keeps built-in model loaded and relay serves plan until task stops
`Connection`: A task's model connection. The lease keeps the built-in model loaded; the
relay serves the ChatGPT plan. Both last until the task stops.

#### Weak handle so dropping process ends pi despite reader thread
`ProcessTransport`: The client writes through a weak handle: dropping the session's process
ends pi even while the reader thread still holds the client.

#### Pi holds relay key, never plan token or stored API key
`a_plan_task_points_pi_at_a_relay_on_this_computer`: pi holds the relay's key, never the plan token or a stored API key.

### `LinuxWindows/crates/lokalbot-agent/src/layout.rs`

#### Runtime is machine-local cache; sessions and tasks live in library agent folder
Where Agent Mode keeps its files (`AgentRuntimeLayout`).

The runtime (Bun, pi and LokalBot's pi extension) is a machine-local
cache next to the llama.cpp runtime in `<library>/runtimes/`, not user
data. pi's session files, the task list and pi's own configuration live in
`<library>/agent/`, where macOS keeps them, so they follow
`LOKALBOT_STORAGE_ROOT` and stay with the rest of the library.

#### version.json records versions and digests verified at install
`VersionMarker`: `version.json`: versions and the digests verified at install time.

#### Extension is written from the copy built into the app
`RuntimeLayout.extension_dir`: LokalBot's pi extension, written from the copy built into the app.

#### System prompt is written from copy built into the app
`RuntimeLayout.system_prompt_file`: LokalBot's system prompt, written from the copy built into the app.

#### Cheap receipt check for launch; deep audit is is_integrity_valid
`RuntimeLayout.is_installed`: Cheap receipt check for the normal launch path. Installation verifies
every staged byte before the atomic swap, so routine entry only proves
that the entry points and a matching receipt are present; use
`is_integrity_valid` for a deep audit.

#### Recursive hash audit reserved for install, launch, repair, verify
`RuntimeLayout.is_integrity_valid`: Recursive audit: hashes every runtime file. Reserved for installation,
launching a task, repair and the user's "Verify Agent runtime".

#### agent folder holds pi sessions, task metadata and pi config
`AgentDirectories`: `<library>/agent`: pi sessions, task metadata and pi's own configuration.

#### Holds pi session JSONL and tasks.json, matching macOS
`AgentDirectories.sessions`: pi session JSONL files and `tasks.json` (`AgentRuntimeLayout.sessionsDirectory`).

#### PI_CODING_AGENT_DIR isolates pi settings from ~/.pi
`AgentDirectories.pi_config`: `PI_CODING_AGENT_DIR`: pi's settings and state, isolated from `~/.pi`.

#### Approval mode kept out of settings.json like macOS default
`AgentDirectories.approval_mode_file`: The remembered approval mode, kept out of `settings.json` like the
macOS `lokalbotv3.agent.approvalMode` default.

#### Records running pi processes so later run stops leftovers
`AgentDirectories.process_markers`: Records of running pi processes, so a later run can stop leftovers.

#### Default workspace is library sibling so private library is never implicit
`AgentDirectories.default_workspace`: The default working folder, a sibling of the library
(`AppDirectories.agentWorkspace(forLibraryRoot:)`), so the private
library is never an implicit working folder.

### `LinuxWindows/crates/lokalbot-agent/src/lib.rs`

#### Agent Mode drives pinned Bun and pi over JSONL RPC; extension gates tools
Agent Mode for Linux and Windows: a local coding and file agent powered by
the selected Think model (`LokalBot/Agent` on macOS).

LokalBot does not implement the agent loop. It installs a pinned Bun and
the open-source pi coding agent ([`install`]), runs pi as a subprocess in
RPC mode ([`process`], [`launch`]) and drives it over JSONL on stdio
([`frame`], [`messages`], [`rpc`]). pi's model is the Think model behind
an OpenAI-compatible endpoint ([`endpoint`]); LokalBot's pi extension
gates every tool except workspace reads, and [`policy`] decides which of
those requests the user must approve. [`session`] and [`tabs`] hold the
state the Agent page shows; [`history`], [`archive`] and [`tasks`] read
and write the same files as the Mac app.

### `LinuxWindows/crates/lokalbot-agent/src/manifest.rs`

#### Provenance and verification of pinned Bun and pi digests, recorded 2026-11-14
Pinned runtime components (`AgentRuntimeManifest` in `AgentRuntime.swift`).

Bun is a checksum-verified release archive; pi is installed from the
public npm registry with the frozen lockfile bundled in this crate.

Sources, recorded 2026-11-14: the Bun archives are the `bun-v1.4.4` assets
of \<https://github.com/oven-sh/bun/releases/tag/bun-v1.4.4>; each was
downloaded once and hashed, and the digest matches the `digest` GitHub
publishes for the asset. The binary digests are of the file inside each
archive. The x64 and x64-baseline archives of this release hold the same
binary, so one pin per OS serves every x86-64 CPU. The pi digests, recorded
2026-11-14 for pi 1.5.2, come from
`bun install --production --frozen-lockfile --ignore-scripts` of the bundled
`package.json` + `bun.lock` on each OS; `cli.js`, `package.json` and
`bun.lock` match the macOS pins byte for byte, and so does the Linux tree.

#### None digests are unchecked in tests; shipped manifest pins all
`RuntimeManifest`: Everything an install is checked against. `None` digests are not checked
(tests); the shipped manifest pins every one.

#### Network bytes: Bun archive plus pi npm packages, used for copy
`RuntimeManifest.approximate_download_bytes`: Network bytes for setup (Bun archive plus pi's npm packages), for copy.

#### Digest of win32-x64 install of bundled lockfile
`platform::PI_TREE_SHA256 (windows)`: win32-x64 install of the bundled lockfile.

#### 54.7 MB archive plus 25.3 MB npm packages
`platform::DOWNLOAD_BYTES (windows)`: 54.7 MB archive + 25.3 MB of npm packages.

#### 115.3 MB Bun plus 116.0 MB pi tree
`platform::INSTALLED_BYTES (windows)`: 115.3 MB Bun + 116.0 MB pi tree.

#### Digest of linux-x64 install of bundled lockfile, 125 packages
`platform::PI_TREE_SHA256 (linux)`: linux-x64 install of the bundled lockfile (125 packages).

#### 51.8 MB archive plus 25.3 MB npm packages
`platform::DOWNLOAD_BYTES (linux)`: 51.8 MB archive + 25.3 MB of npm packages.

#### 107.3 MB Bun plus 116.0 MB pi tree
`platform::INSTALLED_BYTES (linux)`: 107.3 MB Bun + 116.0 MB pi tree.

#### Rounded size text such as about 60 MB for setup card
`RuntimeManifest.download_label`: "about 60 MB", for the setup card.

### `LinuxWindows/crates/lokalbot-agent/src/messages.rs`

#### Decode only displayed fields; unknown events never break the client
pi RPC records (`PiRPCMessages.swift`): commands written to stdin and the
events read from stdout. Only the fields Agent Mode displays are decoded;
everything else becomes [`PiEvent::Unknown`] so protocol additions never
break the client.

#### UI responses correlate to pi's request id and get no response
`PiCommand.id`: The correlation id we put into the command, if pi answers it.
UI responses correlate to pi's request id and get no response.

#### Command is one JSON line, sorted keys, no trailing newline
`PiCommand.json_line`: One line of JSON with sorted keys and no trailing newline.

#### Data is re-encoded with sorted keys
`PiResponse.data_json`: `data`, re-encoded with sorted keys.

#### None when record is not a typed JSON object
`PiEvent.decode`: Decodes one JSONL record; `None` when it is not a JSON object with a type.

#### Only text deltas may be dropped under pressure
`PiEvent.is_lossy_text_delta`: Text deltas are the only events that may be dropped under pressure.

#### None when the assistant turn finished normally
`terminal_failure`: What a stopped assistant turn reports, or `None` when it finished normally.

#### Sorted keys and unescaped slashes keep displayed data stable
`canonical_json`: Compact JSON with recursively sorted keys and unescaped slashes, so
displayed arguments and stored data are stable whatever serde_json's map
ordering is.

#### Result is alphabetical with or without preserve_order
`canonical_json`: With serde_json's `preserve_order` the map keeps insertion order, which
`sorted` made alphabetical; without it the map sorts anyway.

### `LinuxWindows/crates/lokalbot-agent/src/policy.rs`

#### Policy decides auto-answer versus asking for raised approval requests
Tool approvals (`AgentApprovalPolicy.swift`).

The bundled extension raises an approval request for every tool call
except a read inside the working folder and outside the private library.
This decides whether a raised request is answered automatically (a
read-only lookup of the user's own library with a model on this computer,
the approval mode, "Allow for Session" choices) or shown to the user.

#### Ordered least to most permissive; app-wide; stored as macOS raw values 0 to 3
`ApprovalMode`: Approval levels, ordered from least to most permissive so the UI asks to
confirm only escalations. Remembered app-wide; per-tool exceptions are
session-only. Stored as the macOS raw values (0…3).

#### approval-mode.json stores mode as 0 to 3
`StoredMode`: `approval-mode.json`: `{"mode": 0…3}`.

#### Lookups skip approval only when the model is known to be local
`ApprovalPolicy.model_runs_on_this_computer`: True only while the task's model is known to run on this computer. A
lookup's output is fed to the model, so with a model anywhere else,
or one whose place is not known, a lookup is not let through here.

#### Automatic modes apply only to structured requests from matching workspace; others fail closed
`ApprovalPolicy.verdict`: Automatic modes only apply to structured approvals from the process
for this working folder; stale or malformed requests fail closed.

#### Lone library lookup runs in every mode only with a local model
`ApprovalPolicy.verdict`: A lone read-only lookup of the user's own library runs in every
mode, the default included, when the model runs on this
computer. With a model elsewhere it asks. Anything
`is_library_lookup` cannot prove to be a lookup falls through
and follows the mode.

#### Full access covers all tools including MCP and future ones
`ApprovalPolicy.verdict FullAccess`: Every tool, including MCP tools and tools later pi releases
add. Protected file changes already asked above.

#### Allow for Session stays narrower: canonical write/edit paths inside workspace
`ApprovalPolicy.verdict`: "Allow for Session" stays narrower than the modes: only canonical
write/edit paths inside the matching workspace inherit it.

#### Headless harness may opt into workspace-contained write/edit only
`approve_workspace_file_changes_for_automation`: The headless harness has nobody to click file-change cards. It may
opt into workspace-contained write/edit calls only.

#### Reset keeps mode and model location, which belong to the task
`reset_session`: Keeps the mode and where the model runs, which belong to the task.

#### Unlisted option keeps a command from counting as lookup
`LOOKUP_OPTIONS`: The options `lokalbot-cli brief`, `list`, `get` and `search` take. None
of them writes a file or reaches the network. A word that starts with `-`
and is not listed here keeps the command from counting as a lookup, so an
option a later release adds asks until it is added.

#### Lookup must be one plain call with known options and limited suffixes
`is_library_lookup`: One `lokalbot-cli brief`, `list`, `get` or `search` call made of plain and
quoted words, so nothing can chain, redirect, substitute or expand into
another command. Those four only read the library and print, and only with
the options in [`LOOKUP_OPTIONS`]. A trailing `2>&1` and `| head` or
`| tail` with a line count are allowed.

#### None when text allows chaining, redirect, substitution or expansion
`plain_command_words`: The words of a command that is a single call made of plain and quoted
words, after an optional `2>&1` and `| head` or `| tail` with a line
count. `None` when the text holds anything a shell could use to chain,
redirect, substitute or expand.

#### With $, backticks, backslashes excluded, quotes only group words
`plain_command_words`: With `$`, backticks and backslashes excluded, quotes only group words.

#### Suffix rule matches macOS regular expression
`strip_allowed_suffix`: Removes what `(\s+2>&1)?(\s*\|\s*(head|tail)(\s+-n\s+[0-9]+|\s+-[0-9]+))?\s*$`
matches, as the macOS app does with that expression.

#### Missing or unresolvable paths count as protected (fail closed)
`is_protected`: Missing or unresolvable paths count as protected (fail closed).

#### Resolve via nearest existing ancestor; symlinked parent cannot escape; dangling fails closed
`canonical_path`: Resolves symlinks through the nearest existing ancestor, then appends the
not-yet-created rest, matching the extension's rule: a symlinked parent
cannot turn an apparently local write into an outside one. A dangling
link fails closed.

#### Removes . and .. without disk access, like standardizedFileURL
`lexically_normalized`: `.` and `..` removed without touching the disk (`standardizedFileURL`).

#### Component-wise comparison; Windows paths compare case-insensitively
`is_within`: Component-wise; Windows paths compare case-insensitively.

#### Private app data is never an implicit working folder
`WorkspacePolicy`: Private app data is never an implicit working folder
(`AgentWorkspacePolicy`). File tools may still request individual reads.

#### Only known options pass; output flags or future options ask
`library_lookups_take_only_their_known_options`: Only the options the four lookups take pass. An output flag, or any
option a later release might add, asks.

#### Owner decision: lookups run without request at every level with local model
`each_library_lookup_runs_without_asking_at_the_default_level_with_a_local_model`: The owner's decision: a read-only lookup of the user's own library
runs without a request at the default level, and so at every level,
when the task's model runs on this computer.

#### Lookup output goes to model, so non-local or unknown model asks
`the_same_lookups_ask_when_the_model_is_not_on_this_computer`: A lookup's output goes to the model. With a model on a server or a
subscription plan, or one whose place is not known, the same lookups
ask wherever they asked before lookups could skip approval.

#### PowerShell keeps asking because lookup rule reads Bash words
`everything_else_still_asks_at_the_default_level`: PowerShell (Windows without Bash) keeps asking: the rule reads Bash words.

#### Request from another working folder is stale or malformed and asks
`lookup_from_another_working_folder_still_asks`: A request from a folder other than the task's working folder is stale
or malformed, and asks even when it is a lookup.

### `LinuxWindows/crates/lokalbot-agent/src/presentation.rs`

#### Presentation rules hold no text so they test without a window; mirror AgentPresentation.swift
The rules behind what the Agent page shows (`AgentPresentation.swift`):
where a step's file sits, which files a turn changed, how a conversation
folds for reading, where a task stands, and how the task list groups.
The words live with the page; these rules hold no text, so they are tested
without a window.

#### Folder shown as Agent Workspace, a subfolder of it, or ~/ path
`FileTarget.folder`: "Agent Workspace", "Agent Workspace/drafts" or "~/Desktop".

#### Leading @ dropped, ~ is home, relative from workspace, links followed to real target
`FileTarget::resolve`: Resolves a path the way the agent's file tools do: a leading `@` is
dropped, `~` is the home folder, and a relative path starts at the
working folder. Links are followed, so a link that leaves the working
folder is named for where it really points.

#### Written means restored from history where earlier file state is unknown
`Change::Written`: A write restored from saved history, where the earlier state is unknown.

#### Line count is of the text a write put in the file
`ChangedFile.line_count`: Lines of the text a write put in the file.

#### step_id is the last step that changed the file, used to open its result
`ChangedFile.step_id`: The step that changed it last, for opening its result.

#### Lists succeeded write/edit files in first-changed order; existed_before tells new from replaced
`ChangedFile::list`: The files changed by the succeeded write and edit steps in `items`, in
the order they were first changed. `existed_before` says, for a write
step seen as it started, whether its file was already there.

#### A file the agent created stays Created however often touched again
`ChangedFile::list`: A file the agent made stays new however often it is touched again.

#### In a finished turn entries include what the agent said between steps
`StepGroup.entries`: The steps and, in a finished turn, what the agent said between them.

#### A finished turn folds all its work into one counted line
`StepGroup.is_turn_summary`: A finished turn folds all its work into one counted line.

#### Layout regroups the transcript for reading and never reorders or drops a message
`Block`: What the conversation shows, top to bottom. It regroups the transcript
for reading and never reorders or drops a message.

#### Said is what the agent says while working, shown in full
`Block::Said`: What the agent says while it works, shown in full.

#### Answer is the last thing said in a finished turn, carrying that turn's steps
`Block::Answer`: The last thing the agent said in a finished turn, with that turn's steps.

#### While working, last turn stays unfolded; earlier and ended turns fold work above the answer
`layout`: `is_working` says the last turn is still going: its words stay in full
and each run of steps folds on its own. Every earlier turn, and the last
one once it ends, folds its work into one line above its answer.

#### Approval items are skipped because the approval card above the composer owns them
`layout`: The approval card above the composer owns these.

#### The answer is the last assistant message when no step follows it
`layout_turn`: The answer is the last thing the agent said, when no step follows it.

#### Notices such as denials and errors are never folded away
`layout_turn`: A notice (a denial, an error) is never folded away.

#### Task is Done only while agent is open and last turn ended with an answer
`TaskStatus::resolve`: A task is done while its agent is still open and its last
turn ended with an answer.

#### Earlier holds tasks from before task times were saved
`SectionKind::Earlier`: Tasks from before task times were saved.

#### Task list groups pinned first, then one group per day, newest first
`TaskListSection`: The task list's groups: pinned tasks, then one group per day, newest first.

#### Pinned entries keep input order; others go newest first
`TaskListSection::make`: Pinned entries keep the order they come in; the rest go newest first.

#### A lone in-progress step shows live with no folded line above
`a_step_in_progress_leaves_its_run_and_rejoins_when_done`: The only step of a run shows live with no folded line above it.

#### Agent words between steps stay inside the fold, in order
`a_finished_turn_folds_its_work_into_one_line_above_the_answer`: What the agent said between steps stays inside the fold, in order.

#### A notice after the answer does not undo Done
`status_follows_what_the_task_is_doing`: A notice after the answer does not undo it.

#### A saved conversation only being read is Saved, not Done again
`status_follows_what_the_task_is_doing`: A saved conversation that is only being read is not "done" again.

#### History does not say if a written file existed, so it is Written
`changed_files_come_from_succeeded_writes_and_edits`: History does not say whether a written file was there before.

### `LinuxWindows/crates/lokalbot-agent/src/process.rs`

#### Nothing pi starts may outlive LokalBot: Linux setsid and PDEATHSIG, Windows kill-on-close job object
One pi subprocess (`PiProcess.swift`): spawns it from a launch plan, feeds
stdout through the JSONL splitter, keeps a stderr tail, writes stdin on its
own thread with bounded buffering, and supervises shutdown.

Nothing it starts may outlive LokalBot:
- Linux: Bun leads a new session (`setsid`) and gets `SIGTERM` when
  LokalBot dies (`PR_SET_PDEATHSIG`, from a spawner thread that lives as
  long as the process, since the signal follows the forking thread). pi's
  own `SIGTERM` handler kills the tool commands it started in their own
  process groups. Stopping sends `SIGTERM` to the group, waits, then
  `SIGKILL`s the group and every descendant found in `/proc`. A record in
  `<library>/agent/processes` lets the next run stop a pi that ignored
  its signal.
- Windows: Bun starts suspended inside its own job object with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, then resumes. Every tool command
  inherits the job, so stopping (or LokalBot exiting, which closes the
  handle) ends the whole tree.

#### Stop waits this long for orderly exit before force-killing
`STOP_GRACE`: Stopping waits this long for an orderly exit before force-killing.

#### Child reaped only by stop or Drop so PID cannot be reused while signalable
`PiProcess.child`: Reaped only by `stop` or Drop, never by the waiter, so
the PID (and its process group) cannot be reused while it may still
be signalled.

#### on_frame gets stdout in order; on_exit runs once after stdout closes and exit; markers are Linux-only
`PiProcess::spawn`: Starts `plan`. `on_frame` receives every stdout record in order;
`on_exit` runs once after stdout closes and the process has exited.
`markers` is the folder for leftover-process records (Linux).

#### Wait up to 500 ms for stderr reader so crash tail is captured
`PiProcess::spawn`: Let the stderr reader catch the last lines of a crash.

#### Queuing a record never blocks on a full pipe
`PiProcess::send_line`: Queues one JSONL record. Never blocks on a full pipe.

#### Stop closes stdin, terminates, waits grace, then kills all; blocking and idempotent
`PiProcess::stop`: Closes stdin (pi's orderly shutdown), asks the tree to exit, waits up
to `grace`, then kills everything that is left. Blocking; idempotent.

#### On app quit sessions stop in parallel without waiting, then kill_tree cleans up
`PiProcess::begin_stop`: Asks the tree to exit without waiting (app quit: several sessions stop
in parallel, then `kill_tree` cleans up).

#### Signalling group is safe because the unreaped child keeps its ID reserved
`PiProcess::signal_terminate`: SAFETY: signal delivery to the process group Bun leads; the
unreaped child keeps that ID reserved.

#### Windows has no SIGTERM; closing stdin is pi's shutdown request
`PiProcess::signal_terminate`: Windows has no SIGTERM; closing stdin is pi's shutdown request.

#### SIGKILL is safe because Bun is unreaped so PID and group are still ours
`PiProcess::kill_tree`: SAFETY: Bun is not reaped yet, so its PID and group ID are still
ours; the descendants were found under it a moment ago.

#### Wait with WNOWAIT leaves child unreaped; returns exit code only on normal exit
`wait_without_reaping`: Blocks until `pid` exits, leaving it unreaped (Unix `WNOWAIT`), and
returns its exit code when it exited normally.

#### Short helper tied to LokalBot, tree killed after timeout; None on signal or timeout
`run_tree`: Runs a short helper (`bun install`) tied to LokalBot and waits for it,
killing its tree after `timeout`. Returns the exit code (`None` when
killed by a signal or the timeout).

#### No marker on Windows because the job object covers a crashed LokalBot
`write_marker`: The job object already covers a crashed LokalBot.

#### Only a process running the recorded Bun binary whose LokalBot is gone is touched
`stop_leftovers`: Stops pi processes an earlier, crashed LokalBot left behind. Only a
process still running the recorded Bun binary, whose LokalBot is gone, is
touched.

#### Skip markers whose owner LokalBot is still alive
`stop_leftovers`: Another LokalBot's live session.

#### Kill is safe because PID runs recorded Bun and its LokalBot is gone
`stop_leftovers`: SAFETY: the PID runs our recorded Bun binary and the LokalBot
that started it is gone.

#### PDEATHSIG fires when forking thread exits, so fork from one long-lived thread
`unix::spawn`: `PR_SET_PDEATHSIG` fires when the forking *thread* exits, so every
pi is forked from one thread that lives as long as LokalBot.

#### pre_exec only calls async-signal-safe functions and allocates nothing
`unix::spawn`: SAFETY: runs between fork and exec and only calls async-signal-safe
functions (setsid, prctl, getppid); it allocates nothing.

#### Check parent after prctl because LokalBot may have died before it took effect
`unix::spawn`: LokalBot may have died before prctl took effect.

#### Parse stat after last paren because comm may contain spaces and parens
`unix::descendants`: `pid (comm) state ppid …`; comm may contain spaces and parens.

#### Job handle is process-wide kernel handle, passed to thread-safe calls, closed once in Drop
`windows::Job`: SAFETY: a job handle is a process-wide kernel handle, only passed to
thread-safe Win32 calls and closed once, in Drop.

#### Win32 info struct zero-initialized and exactly sized as the API allows
`windows::Job::new`: SAFETY: plain Win32 calls with valid arguments; the info struct
is zero-initialized as the API allows and sized exactly.

#### Closing handle with KILL_ON_JOB_CLOSE ends any process still in the job
`windows::Job::drop`: SAFETY: closing our own handle; with KILL_ON_JOB_CLOSE this ends
any process still in the job.

#### Start suspended, assign to job, then resume so no child starts outside the job
`windows::spawn`: Starts the process suspended, puts it in a fresh job, then resumes it,
so not even its first child can start outside the job.

#### Test: tool commands in own groups must still die; stop bounded when stdin undrained
`stop_kills_detached_grandchildren_and_is_idempotent`: pi's tool commands run detached in their own groups; stopping must
still end them, and stop is bounded when nothing drains stdin.

### `LinuxWindows/crates/lokalbot-agent/src/resources.rs`

#### Extension, skill and prompt rewritten from built-in copies before each launch so disk edits never decide approvals
Files the app carries for Agent Mode (`LokalBot/Resources/pi` on macOS):
the frozen pi manifest and lockfile, LokalBot's pi extension (provider
registration, the approval gate and the environment prompt section), the
library skill and the system prompt.

The extension, skill and prompt are written into the runtime folder before
each launch from these copies, so a stale or edited file on disk never
decides what needs approval or what the model is told.

#### Must be the same text as the macOS system-prompt.md
`SYSTEM_PROMPT`: The same text as `LokalBot/Resources/pi/system-prompt.md`.

#### Atomic temp-and-rename write so a pi in another task never reads half a file
`write_if_changed`: Temp file + rename: a pi starting in another task never reads half a file.

#### Skip comparison when port source copy has no macOS app
`the_system_prompt_is_the_macos_text`: A source copy of the port alone has no macOS app to compare with.

#### Test keeps extension path boundary visible without a runtime; full suite in resources/tests
`the_extension_resolves_paths_against_the_session_folder`: The boundary the extension checks is the one pi's tools use. The suite in
`resources/tests` runs this; here it stays visible without a runtime.

#### Skill must not claim missing About you page or settings access; both exist here
`the_skill_says_what_this_app_has`: The page and the command line both exist here.

### `LinuxWindows/crates/lokalbot-agent/src/rpc.rs`

#### Results go to a sink, never awaited, so a slow abort ack cannot block approvals
Request/response correlation over pi's JSONL stream (`PiRPCClient.swift`).

The process reader feeds every stdout record to [`RpcClient::handle_line`].
A `response` whose id matches a pending request completes it; everything
else is forwarded as an event. Results are delivered to the session's
sink, never awaited, so one slow acknowledgement (pi's `abort` waits for
idle) can never stop approvals or other events from being handled.

#### Closed means stream ended and every pending request already failed
`ClientMessage::Closed`: The stream ended; every pending request already failed.

#### Attach after process runs; reader may already be feeding lines
`RpcClient::attach`: Set once the process is running (the reader may already be feeding lines).

#### For lines pi never acknowledges such as extension_ui_response
`RpcClient::send`: For lines pi never acknowledges (`extension_ui_response`).

#### Unmatched response becomes an event, never stolen by another request
`request_resolves_on_matching_id_and_events_flow_through`: An unmatched response is an event, never stolen by another request.

### `LinuxWindows/crates/lokalbot-agent/src/session.rs`

#### Session is a UI-thread state machine; async completions carry lifecycle generation so stale ones cannot revive tasks
One Agent Mode task (`AgentSessionController.swift`): starts pi through a
[`Launcher`], folds its events into the transcript, round-trips tool
approvals between pi's confirm dialogs and the UI, and keeps the host
queue of follow-ups.

The macOS controller is a main-actor object whose `await`s let other
events through. Here it is a plain state machine owned by the UI thread:
every slow step (model warm-up, spawning, an RPC acknowledgement, a
process stop) runs elsewhere and comes back as a [`SessionInput`] through
the task's inbox, tagged with the lifecycle generation it belongs to, so a
stale completion can never revive a closed or restarted task.

#### Configuration launch failures send the user to Models
`LaunchError`: Why a launch failed. Configuration problems send the user to Models.

#### ChatGPT plan relay pi talks to stops when dropped
`Launched.relay`: The ChatGPT plan relay pi talks to; it stops when dropped.

#### Scoped lokalbot-cli grant must be revoked when the task stops
`Launched.capability`: The scoped `lokalbot-cli` grant to revoke when the task stops.

#### Real pi reports its session file; test transports do not
`Launched.reports_session_file`: Real pi reports its session file; test transports do not.

#### Launch happens off the UI thread; done runs exactly once
`Launcher`: Starts pi off the UI thread. `done` runs exactly once.

#### Library, agent folders and runtime are never implicit working folder; file changes ask
`AgentEnvironment::private_roots`: The library, its agent folders and the runtime: never an implicit
working folder, and file-tool changes to them always ask.

#### Clamp to nearest supported level below, else lowest; Automatic gives none
`ReasoningChoices::clamp`: The supported level nearest below `level`, else the lowest one.

#### Protected means LokalBot's own data; change allowed only once
`ApprovalFile.is_protected`: Part of LokalBot's own data: a change there is only ever allowed once.

#### Model context bound to launched connection even if Settings change later
`AgentSession.model_context`: Bound to the launched connection, even if Settings change later.

#### None until a launch; then levels the launched model accepts
`AgentSession.reasoning_choices`: The levels the launched model accepts; `None` until a launch.

#### True after Stop ended a turn until next message or turn
`AgentSession.was_stopped`: True after Stop ended a turn, until the next message or turn.

#### Records whether write target existed at step start to tell new from replaced
`AgentSession.write_target_existed`: For each write step seen as it started, whether its file was already
there. It tells a new file from a replaced one afterwards.

#### Relay runs from launch until shutdown or failure, like the lease
`AgentSession.relay`: Runs from launch until shutdown or failure, like the lease.

#### Failed is published and restart allowed only after failure's process stop finishes
`AgentSession.failure_teardown_in_progress`: A failure's process stop is still running; `Failed` is published, and
a restart allowed, only after it finishes.

#### Start waits for shutdown stops so two pi never share one session file
`AgentSession.stops_pending`: Shutdown stops still running; a start waits for them so two pi
processes never share one session file.

#### True after Stop ended a turn until next message or turn
`AgentSession::was_stopped`: True after Stop ended a turn, until the next message or turn.

#### None for steps not seen starting, such as restored history
`AgentSession::write_target_existed`: Whether the file a write step named was already there when the step
started; `None` for a step not seen starting (restored history).

#### True only when launched connection is known on-device; before launch it is unknown
`AgentSession::model_runs_on_this_computer`: True only while the task's model is known to run on this computer:
the launched connection's, or before launch none (it is not known).

#### Show launched model, else the one a new launch would use
`AgentSession::presented_model`: The model a new launch would use, or the launched one.

#### Relative path starts at request's folder; placement judged against task working folder
`AgentSession::approval_file`: The file an approval request names (`approvalTarget`): a relative
path starts at the folder the request came from, and where it sits is
judged against this task's working folder. `None` when it names none.

#### Only text deltas drop when inbox is full; others wait and pi honors stdout backpressure
`AgentSession::client_sink`: pi traffic for this generation. Text deltas are the only messages
dropped when the inbox is full; anything else waits, and pi honors the
backpressure on its stdout.

#### Process stop finishes in background and a later start waits for it
`AgentSession::shutdown`: Stops this task's pi and returns to idle. The process stop finishes in
the background; a later start waits for it.

#### Revoke library access before the stop's grace period
`AgentSession::shutdown`: Revoke library access before the stop's grace period.

#### On quit ask pi to stop without waiting; caller waits once and kills leftovers
`AgentSession::begin_quit`: App quit: asks pi to stop without waiting. The caller then waits once
for every task and kills what is left.

#### Park pauses idle runtime without losing saved task, draft or preview
`AgentSession::park`: Pauses an idle runtime without losing the saved task, draft or preview.

#### Preview shown without starting anything, read off the UI thread
`AgentSession::load_saved_preview`: Shows a saved conversation without starting anything (read off the UI thread).

#### Synchronous preview because start needs it immediately
`AgentSession::load_saved_preview_now`: Applies a preview read on this thread (start needs it immediately).

#### Queues while running, sends when ready, otherwise starts then sends
`AgentSession::submit`: Composer submission: queues a follow-up while running, sends when
ready, or starts the task and sends once it is ready.

#### Relay loopback URL passes origin check; the plan has its own approval
`AgentSession::send`: The relay's loopback URL passes the origin check; the plan has
its own approval.

#### Follow-ups stay in host queue until delivery so cancel and edit are real
`AgentSession::queue_draft`: Follow-ups stay in the host queue until delivery, so cancelling and
editing them are real operations.

#### Send now steers while working, next message when ready, starts idle task; keeps place on failure
`AgentSession::send_queued_now`: "Send now" on one queued message (`sendQueuedNow`): as a steering
message while the agent works, as the next message when it is ready.
An idle or failed task starts and sends it first. The message keeps
its place when it cannot be sent.

#### Cancel waiting approvals first because pi's confirm promise has no abort signal
`AgentSession::abort`: Stops the current turn. pi's confirmation promise has no abort signal,
so waiting approvals are cancelled first or the abort waits forever.

#### Mode saved app-wide; changing clears per-tool session exceptions so downgrade applies
`AgentSession::set_approval_mode`: Remembers the mode app-wide and answers waiting cards it now allows.
Changing modes clears per-tool session exceptions so a downgrade
takes effect.

#### Unattended harness may approve workspace file changes only
`AgentSession::approve_workspace_file_changes_for_automation`: The unattended harness may approve workspace file changes only.

#### Deliver queue on agent_settled, not agent_end, which precedes retry or compaction
`AgentSession::handle_event`: agent_end can precede automatic retry or compaction; pi emits
agent_settled only once the whole run is idle.

#### Library lookups skip approval only for known on-device model from bound connection
`AgentSession::handle_ui_request`: Library lookups skip approval only with a model known to run on
this computer; the bound connection decides, never later Settings.

#### Prompt ack can arrive after agent_settled so deliver queue again when Ready
`AgentSession::handle_response`: The acknowledgement can arrive after agent_settled.

#### Running agent uses new reasoning level from its next model call
`AgentSession::reasoning_level_did_change`: After the Agent or Think reasoning setting changed: a running agent
uses the new level from its next model call.

#### Session allowances end at lifecycle boundaries; mode is an app preference that persists
`AgentSession::reset_approval_policy`: Session allowances end at lifecycle boundaries; the mode is an app
preference and survives closing or resuming a task.

#### Invalidate generation before stop so buffered frames cannot revive task; restart waits for exit
`AgentSession::transition_to_failure`: Invalidates the generation before the process stop, so frames already
buffered cannot revive the task, and keeps restart disabled until the
old process has actually ended.

#### Runs before model loading or capability issuance; old working folder never migrated silently
`AgentSession::prepare_workspace`: Before model loading or capability issuance, including resumed tasks.
An old working folder is never migrated silently.

#### Mirrors InferenceEndpointPolicy.validate run before each send to a remote endpoint
`remote_block`: Why a launched remote endpoint may no longer receive context
(`InferenceEndpointPolicy.validate` before each send).

#### Extension sends structured lokalbot_tool_approval title; older summary-only payloads stay readable
`parse_approval_payload`: Our extension sends title `lokalbot_tool_approval` with structured
fields; older payloads with only a summary stay readable.

#### Title is first line cut at a word near 36 characters
`make_session_title`: The first line, cut at a word near 36 characters.

### `LinuxWindows/crates/lokalbot-agent/src/session_tests.rs`

#### Temp dir dropped last because Windows cannot remove an open library
`Harness._dir`: Dropped last: Windows can't remove the library while it is open.

#### Widening mode answers newly allowed cards but never bash
`read_mode_approves_reads_but_shows_changes_and_shell`: Widening the mode answers the cards it now allows, but never bash.

#### Approval arriving while stopping is cancelled at once
`stop_cancels_pending_approvals_before_aborting_and_keeps_follow_ups`: An approval arriving while stopping is cancelled at once.

#### qwen3.5 accepts Off to High so Max clamps to High
`reasoning_level_is_written_for_the_extension_and_follows_changes`: qwen3.5 accepts Off–High: Max clamps to High.

#### Approving a LAN server does not replace encrypting what is sent to it
`a_running_task_stops_sending_to_plain_http_off_this_computer`: `InferenceEndpointPolicy.validate` before each send: approving a server on the
user's network doesn't stand in for encrypting what goes to it.

#### Owner decision: read-only library lookup skips card only when model is on-device
`a_library_lookup_runs_unasked_with_a_model_on_this_computer`: The owner's decision: a read-only library lookup runs without a card at
the default level only while the task's model runs on this computer.

#### After agent stops, where the model runs is unknown
`a_library_lookup_runs_unasked_with_a_model_on_this_computer`: After the task's agent stops, where the model runs is not known.

#### Read levels do not let lookups through; only full access runs every command
`a_library_lookup_asks_when_the_model_is_not_on_this_computer`: The read levels do not let it through either; full access runs every command.

#### LokalBot's own data can only ever be allowed once
`an_approval_names_its_file_and_where_it_sits`: LokalBot's own data can only ever be allowed once.

### `LinuxWindows/crates/lokalbot-agent/src/shell.rs`

#### Resolve shell ourselves: pin Git Bash via shellPath, never WSL launcher, else PowerShell tool
Which shell the agent's command tool uses.

On Linux pi runs `/bin/bash -c` (then `bash` on PATH, then `sh`).

On Windows pi 1.5.2 looks for Bash in this order: the `shellPath`
setting, Git Bash under `%ProgramFiles%` and `%ProgramFiles(x86)%`, then
any `bash.exe` on PATH; without one, every command fails. The first
`bash.exe` on PATH is often WSL's launcher in `System32`, which would run
commands inside a Linux distribution with different files and tools. So
LokalBot resolves the shell itself: Git Bash (or another Bash such as
MSYS2 or Cygwin on PATH, never a WSL launcher) is pinned with `shellPath`
in LokalBot's private pi settings; with no Bash at all the agent gets
pi's PowerShell tool instead, and the approval card shows each PowerShell
command exactly as it does a Bash command.

#### Write or clear shellPath in pi settings while keeping other keys
`ShellChoice::apply`: Writes (or clears) `shellPath` in pi's settings in `pi_config`,
keeping any other keys.

#### System32 and Store WindowsApps bash.exe start WSL, so they are excluded
`is_wsl_launcher`: `System32\bash.exe` and the Store's `WindowsApps\bash.exe` start WSL.

#### Linux writes no settings file when nothing changes
`shell_path_is_pinned_and_cleared_in_pi_settings`: Linux writes nothing when there is nothing to change.

### `LinuxWindows/crates/lokalbot-agent/src/tabs.rs`

#### Four-process limit applies to running agents, never to browsing tasks or history
The task list (`AgentSessionTabs.swift`): a persistent catalog of tasks
with lazily loaded transcripts. The four-process limit applies to running
agents, never to browsing tasks or saved history.

#### Closing a task archives it and keeps its draft
`TaskList::close`: Archives (closing a task keeps its draft).

#### Saved sessions without a task get one so every conversation can be browsed
`TaskList::apply_history`: Saved sessions read off the UI thread are matched to tasks; sessions
without one get a task, so every saved conversation can be browsed.

#### Park idle runtimes beyond limit; missing saved file never silently becomes fresh conversation
`TaskList::prepare_start`: Makes room and checks a task before its runtime starts: idle runtimes
beyond the limit are parked, and a missing saved file never silently
becomes a fresh conversation.

#### Fork creates an independent task through item_id; existing files unchanged
`TaskList::fork`: An independent task through `item_id`. Existing files are unchanged.

#### On quit all pi are asked to stop at once; leftovers killed after grace
`TaskList::shutdown_all`: App quit: every pi is asked to stop at once, then whatever is left
after `grace` is killed.

#### Temp dir dropped last because Windows cannot remove an open library
`Fixture._dir`: Dropped last: Windows can't remove the library while it is open.

### `LinuxWindows/crates/lokalbot-agent/src/tasks.rs`

#### tasks.json uses macOS encoding: uppercase UUIDs, file URLs, seconds since 2001
Task metadata (`AgentTaskStore.swift`): titles, drafts, attachments,
queued follow-ups, pins and archive state, kept apart from pi's
append-only conversation. Archiving never deletes history, and browsing a
task never needs a running process.

`tasks.json` sits next to pi's session files in `<library>/agent/sessions`
and uses the macOS encoding: uppercase UUID strings, `file://` URLs and
dates as seconds since 2001-01-01.

#### Only references stored; text re-read with current permissions when message is sent
`Attachment`: A reference to source material. The text is re-read with current
permissions when a message is sent; only references are stored.

#### Symlinked or oversized tasks file is an error so caller keeps it untouched
`TaskStore::load`: Records with duplicate ids dropped. A symlinked or oversized file is
an error, so the caller keeps it untouched instead of overwriting it.

#### pi edit tool sends edits array of oldText/newText; older calls send one pair
`ResultPreview::tool`: pi's edit tool sends `edits: [{oldText, newText}]`; older calls a single pair.

#### file:// link resolves to tool call on that file, path taken against task folder
`result_for_file_link`: The result a `file://` link in an answer points at (`AgentSessionView`'s
`openURL`): a tool call on that file, its path taken against the task's folder.

#### Swift encodes UUID as uppercase hyphenated string
`swift_uuid`: Swift encodes `UUID` as an uppercase hyphenated string.

### `LinuxWindows/crates/lokalbot-agent/src/transcript.rs`

#### Transcript is a pure state machine so folding rules test without process or UI
The display transcript (`AgentTranscript.swift`): a pure state machine
that folds pi events into ordered items, so every folding rule is unit
tested without a process or UI.

#### App-owned structured request so card shows exact command or content, not model summary
`ApprovalRequest`: An app-owned, structured description of a tool request, so the approval
card shows the exact command or content rather than a model-written
summary.

#### Exact JSON arguments for tools without dedicated preview, such as MCP and future pi tools
`ApprovalRequest.arguments`: Exact JSON arguments of a tool without a dedicated preview (MCP tools,
codemode, tools later pi releases add).

#### Limit also enforced by extension; host fails closed; lengths in UTF-16 units
`ApprovalRequest::can_approve`: Also enforced by the extension before it asks. The host stays fail
closed for old, malformed or locally bounded payloads. Lengths are
UTF-16 units, as JavaScript counts them.

#### Rejects when too many approvals wait or the id is oversized
`TranscriptFolder::add_approval`: False when too many approvals are waiting or the id is oversized.

#### Drop oldest non-approval items until within item and character budgets
`TranscriptFolder::enforce_resource_limits`: Drops the oldest non-approval items until within the item and
character budgets.

#### New attempt clears failure since pi retries; only outcome at agent_settled is terminal
`TranscriptFolder::fold`: A fresh attempt can recover from pi's automatic retry; only
the outcome left at agent_settled is terminal.

#### Remove empty assistant item for tool-call-only turns
`TranscriptFolder::fold`: tool-call-only turn

#### Preview fields share one budget; any cut marks truncated and blocks approving shell or arguments
`bounded_approval`: Bounds a card's preview fields to one shared budget; anything cut marks
it truncated, which also blocks approving a shell command or arguments.

#### 32,768 emoji equal 65,536 UTF-16 units; one more char is over the limit
`shell_approval_requires_the_complete_command_in_utf16_units`: 32,768 emoji are 65,536 UTF-16 units; one more character is over.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
