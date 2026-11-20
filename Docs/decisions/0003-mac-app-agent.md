# 0003. Mac app: Agent

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Agent/`, `LokalBot/Views/Agent/`, `LokalBotTests/Agent/`.

## Decisions

### `LokalBot/Agent/AgentApprovalPolicy.swift`

#### Raw values ordered by permissiveness so UI confirms only escalations; level remembered app-wide
`AgentApprovalMode`: Approval levels exposed by Agent Mode. Raw values are ordered from least to
most permissive so the UI can confirm only escalations. The selected level
is remembered app-wide; individual tool exceptions remain session-only.

#### Pi extension asks for all but workspace reads; policy decides automatic answer or user prompt
`AgentApprovalPolicy`: Pure approval policy for gated agent tools. The bundled pi extension
raises an approval request for every tool call except a `read` inside the
selected workspace and outside the private library. This type
decides whether a raised request can be answered automatically
(a read-only library lookup with a model on this Mac, the approval mode,
session allowances) or must be shown to the user.

#### Lookup output feeds the model, so auto-allow only when model known local
`AgentApprovalPolicy.modelRunsOnThisMac`: True only while the task's model is known to run on this Mac. A
lookup's output is fed to the model, so with a model anywhere else,
or one whose place is not known, a lookup is not let through here.

#### Handed-off meeting tasks allow read-only lookups in read modes; kept across session resets
`AgentApprovalPolicy.allowsLibraryLookups`: Lets read-only `lokalbot-cli` lookups through in the read modes
wherever the model runs. Set for tasks handed off from a meeting's
actions, which may start with no one watching. It belongs to the
task, like `mode`, so session resets keep it.

#### Automatic modes apply only to selected workspace; cross-workspace requests fail closed
`AgentApprovalPolicy.verdict`: Automatic modes only apply to structured approvals emitted by the
process for this selected workspace. Stale or malformed
cross-workspace requests remain fail-closed.

#### Lone library lookup allowed in every mode when model is local; else asks
`AgentApprovalPolicy.verdict`: A lone read-only lookup of the user's own library runs in every
mode, the default included, when the model runs on this Mac.
With a model elsewhere it asks, except for a handed-off task
in the read modes. Anything `isLibraryLookup` cannot prove to
be a lookup falls through and follows the mode.

#### Full access allows every tool including future ones; protected changes already asked
`AgentApprovalPolicy.verdict`: Every agent tool, including MCP tools and tools that later
Pi releases add. Protected file changes already asked above.

#### Allow for Session inherits only canonical write/edit paths inside matching workspace
`AgentApprovalPolicy.verdict`: An individual "Allow for Session" choice stays narrower than the
global modes: only canonical write/edit paths inside the matching
workspace may inherit it.

#### Headless test harness opts into workspace-contained writes only
`AgentApprovalPolicy.approveWorkspaceFileChangesForAutomation`: The headless test harness has no person to click file-change cards. It
may opt into workspace-contained write/edit calls without inheriting
the broader read/edit mode exposed in the app.

#### Unlisted dash options stop a command counting as a lookup
`AgentApprovalPolicy.lookupOptions`: The options `lokalbot-cli brief`, `list`, `get` and `search` take.
None of them writes a file or reaches the network. A word that starts
with `-` and is not listed here keeps the command from counting as a
lookup, so an option a later release adds asks until it is added.

#### Lookup is one plain call to four read-only commands, listed options, limited suffix
`AgentApprovalPolicy.isLibraryLookup`: One `lokalbot-cli brief`, `list`, `get` or `search` call made of plain
and quoted words, so nothing can chain, redirect, substitute or expand
into another command. Those four only read the library and print, and
only with the options listed above. A trailing `2>&1` and `| head` or
`| tail` with a line count are allowed.

#### Nil when text could chain, redirect, substitute or expand
`AgentApprovalPolicy.plainCommandWords`: The words of a command that is a single call made of plain and quoted
words, after an optional `2>&1` and `| head` or `| tail` with a line
count. Nil when the text holds anything a shell could use to chain,
redirect, substitute or expand.

#### With $, backticks, backslashes excluded, quotes only group words
`AgentApprovalPolicy.plainCommandWords`: With `$`, backticks and backslashes excluded, quotes only group words.

#### Resolve symlinks via nearest existing ancestor, matching extension's path rule
`AgentApprovalPolicy.canonicalFileURL`: Resolve symlinks through the nearest existing ancestor, then append any
not-yet-created suffix. This matches the bundled extension's path rule
and prevents a symlinked parent from turning an apparently local write
into an external one.

#### Private app data never an implicit working folder; reads and attachments keep own scope
`AgentWorkspacePolicy`: Private app data is never an implicit working folder. File tools may still
request individual reads, and explicit attachments keep their own scope.

### `LokalBot/Agent/AgentConversationArchive.swift`

#### Opening a saved conversation needs no model, process, tool or permission
`AgentConversationArchive`: Read-only transcript loading and native Pi branching. No model, process,
tool execution, or permission grant is needed to open a saved conversation.

#### Only latest leaf's ancestor chain visible; abandoned branches must not leak
`AgentConversationArchive.activeBranch`: Pi files contain a tree. Only the most recent leaf's ancestor chain is
visible; abandoned branches must not leak into previews or a new fork.

#### Include recorded tool results so forks have no dangling tool calls
`AgentConversationArchive.fork`: A textual assistant message can also contain tool calls. Include its
already-recorded results so the fork never has dangling tool calls.

### `LokalBot/Agent/AgentLLMEndpoint.swift`

#### Dialect selects reasoning request fields; pi extension applyReasoningLevel writes them
`AgentLLMEndpoint.reasoningDialect`: Which request fields carry a reasoning level to this server. The pi
extension writes them; see `applyReasoningLevel` in its index.ts.

#### Plan requests go via local relay but content reaches the plan's provider
`AgentLLMEndpoint.plan`: Set when requests run on a subscription plan through LokalBot's local
relay: `baseURL` is on this Mac, but the content goes to the plan's
provider.

#### Matches Main LLM compaction boundary; conservative window for external endpoints
`AgentLLMEndpoint.defaultContextTokens`: Matches the built-in Main LLM and gives Agent Mode the same compaction
boundary. External endpoints use it as a conservative declared window
when their true model metadata is unavailable.

#### Caller resolves URL and holds InferenceBroker Main LLM lease first
`AgentLLMResolution.builtIn`: Caller resolves the model URL and holds an `InferenceBroker` Main LLM
lease before building the endpoint from the shared base URL + model id.

### `LokalBot/Agent/AgentPresentation.swift`

#### Localizer looks sentences up in catalog; tests pass identity
`AgentLocalize`: Looks a sentence up in the interface catalog. Tests pass `{ $0 }`.

#### Folder label forms: workspace name, subfolder, or ~ path
`AgentFileTarget.folder`: "Agent Workspace", "Agent Workspace/drafts" or "~/Desktop".

#### Resolve @ prefix, ~, relative paths and symlinks like agent tools
`AgentFileTarget.resolve`: Resolves a path the way the agent's file tools do: a leading `@` is
dropped, `~` is the home folder, and a relative path starts at the
working folder. Symlinks are followed, so a link that leaves the
working folder is named for where it really points.

#### Written means restored from history with unknown earlier state
`AgentChangedFile.Change.written`: A write restored from saved history, where the earlier state is unknown.

#### Line count is of the text the write put in the file
`AgentChangedFile.lineCount`: Lines of the text a write put in the file.

#### Keep last changing step so its result can be opened
`AgentChangedFile.stepID`: The step that changed it last, for opening its result.

#### Lists succeeded write/edit files in first-changed order using existedBefore
`AgentChangedFile.list`: The files changed by the succeeded write and edit steps in `items`, in
the order they were first changed. `existedBefore` holds, for each
write step seen as it started, whether its file was already there.

#### A created file stays new however often it is touched again
`AgentChangedFile.list`: A file the agent made stays new however often it is touched again.

#### Only created gets a label beyond edits; written history shows none
`AgentChangedFile.changeLabel`: "New file", or nothing when history does not say what the write did.

#### Doing form omits the ellipsis, which is added when shown
`AgentStepLabel.doing`: "Reading meeting notes", without the ellipsis.

#### Detail is what the step worked on: search, title, folder
`AgentStepLabel.detail`: What the step worked on: the search, the meeting's title, the folder.

#### Label may start with a file or tool name whose capitals must stay
`AgentStepLabel.beginsWithName`: The words can begin with a file or tool name, whose capitals must stay.

#### A step still running when its task stopped never finished
`AgentStepLabel.text`: The words for a step in the given state. A step that was still running
when its task stopped never finished.

#### Resolves a meeting title from an ID or ID prefix
`AgentStepWording.Context.meetingTitle`: A meeting's title from the ID or ID prefix a lookup names.

#### Only plain-word lokalbot-cli calls get a name; chained or redirected shows command text
`AgentStepWording.command`: `lokalbot-cli` calls made of plain words get a name for what they
look up. Anything a shell could chain or redirect is a command, shown
with its text, so a label never hides what ran.

#### Each distinct step once in order; lowercase later items per language
`AgentStepWording.summary`: "Searched meeting library, read meeting notes": each different step
once, in order. `lowercaseFollowing` suits languages that write a
list's later items without a capital; names keep theirs.

#### Entries are steps plus, in a finished turn, the agent's words between
`AgentStepGroup.entries`: The steps and, in a finished turn, what the agent said between them.

#### A finished turn folds all its work into one counted line
`AgentStepGroup.isTurnSummary`: A finished turn folds all its work into one counted line.

#### Blocks regroup the transcript and never reorder or drop a message
`AgentTranscriptBlock`: What the conversation shows, top to bottom. It regroups the transcript
for reading and never reorders or drops a message.

#### Words said while working are shown in full
`AgentTranscriptBlock.said`: What the agent says while it works, shown in full.

#### Answer is last thing said in a finished turn, with its steps
`AgentTranscriptBlock.answer`: The last thing the agent said in a finished turn, with that turn's steps.

#### Working turn keeps words in full; finished turns fold work above answer
`AgentTranscriptLayout.make`: `isWorking` says the last turn is still going: its words stay in full
and each run of steps folds on its own. Every earlier turn, and the
last one once it ends, folds its work into one line above its answer.

#### Approval items are skipped because the card above the composer owns them
`AgentTranscriptLayout.make`: The approval card above the composer owns these.

#### Answer is last said item when no step follows it
`AgentTranscriptLayout.layout`: The answer is the last thing the agent said, when no step follows it.

#### Notices such as denials or errors are never folded away
`AgentTranscriptLayout.layout`: A notice (a denial, an error) is never folded away.

#### Task is done when agent is open and last turn ended with an answer
`AgentTaskStatus.resolve`: A task is done while its agent is still open and its last turn ended with an answer.

#### A saved task doing nothing shows no toolbar word
`AgentTaskStatus.title`: The word for the toolbar. A saved task that is doing nothing shows none.

#### Groups: pinned, then one per day newest first
`AgentTaskListSection`: The task list's groups: pinned tasks, then one group per day, newest first.

#### Earlier holds tasks from before task times were saved
`AgentTaskListSection.Kind.earlier`: Tasks from before task times were saved.

#### Chip title says what the agent does on its own
`AgentApprovalMode.chipTitle`: On the composer's chip: what the agent does on its own.

#### Full access runs commands unasked so uses caution colour
`AgentApprovalMode.needsCaution`: Full access runs commands unasked, so it is drawn in the caution colour.

#### Library lookups skip approval only with a model on this Mac
`AgentApprovalMode.levelDetail`: Lookups skip approval only with a model on this Mac (AgentApprovalPolicy).

#### lokalbotData covers library, runtime, saved tasks and app
`AgentApprovalPresentation.Place.lokalbotData`: Inside LokalBot's library, runtime, saved tasks or app.

#### Full path shown with caution when file is outside working folder
`AgentApprovalPresentation.caution`: The full path, shown with a caution when the file is not in the working folder.

#### Destination shows where the result goes when model is remote
`AgentApprovalPresentation.destination`: Where the result goes when the model is not on this Mac.

#### Allow-for-task answer only when the policy permits it
`AgentApprovalPresentation.taskAnswer`: "Allow writes for this task", when the policy lets this kind of request be allowed that way.

#### File tools always name a file; others show as the tool
`AgentApprovalPresentation.init`: A file tool always names its file; one that does not is shown as the tool it is.

#### Question states the effect; second line states where the file is
`AgentApprovalPresentation.init`: The question says what happens to the file; this line says where the file is.

### `LokalBot/Agent/AgentRuntime.swift`

#### Checksum is lowercase hex
`AgentRuntimeArtifact.sha256`: lowercase hex

#### Bun is checksum-verified archive; pi installed from npm with frozen lockfile
`AgentRuntimeManifest`: Pinned runtime components for Agent Mode. Bun is downloaded as a
checksum-verified release archive. pi is installed from the public npm
registry using the frozen lockfile bundled with LokalBot.

#### Runtime lives in Application Support as machine-local cache, not user data
`AgentRuntimeLayout`: On-disk layout of the installed runtime. Lives in Application Support
(NOT the storage root) alongside model caches and the llama-server
binary — it's a machine-local cache, not user data.

#### Pane open uses cheap receipt check; task start runs deep audit
`AgentRuntimeLayout.isInstalled`: Cheap receipt check for opening the Agent pane. Installation already
verifies every staged byte before the atomic swap, so showing the pane
only needs to prove that the expected entry points and matching
version receipt are present. Starting a task runs `isIntegrityValid`,
the deep audit of the mutable runtime tree.

#### Deep integrity audit runs at install, repair, verify and task start only
`AgentRuntimeLayout.isIntegrityValid`: Explicit, recursive integrity audit. This intentionally opens every pi
runtime file, so it runs at installation, repair, user-requested
verification and before each task starts (`AgentSessionController`,
off the main actor), never on ordinary pane navigation.

#### Version marker records versions and verified digests at install
`AgentRuntimeLayout.versionMarker`: Written at install time with versions and verified artifact digests.

#### Sessions live under storage root to follow LOKALBOT_STORAGE_ROOT
`AgentRuntimeLayout.sessionsDirectory`: pi session JSONL trees live under the storage root so they follow
LOKALBOT_STORAGE_ROOT (hermetic in e2e/UI tests) and land next to
the rest of the user's library.

#### Stream the digest so ~60 MB artifacts avoid memory
`SHA256Verifier.hexDigest`: Streaming digest so ~60 MB artifacts don't land in memory at once.

#### Tree digest ordering, symlink handling and exclusions make identical installs match
`SHA256Verifier.treeHexDigest`: Deterministic digest of a directory's complete shape and contents.
Records are ordered by raw UTF-8 path, length-delimited, and tagged by
file type. Symlinks hash their link text and are never followed; regular
files hash their bytes. Directory records make empty/additional
directories visible too. Metadata and absolute install paths are
deliberately excluded so identical installs hash identically.

### `LokalBot/Agent/AgentRuntimeInstaller.swift`

#### Install into staging and swap at end so failure leaves nothing half-written
`AgentRuntimeInstaller`: Downloads and verifies Bun, then uses the frozen lockfile bundled with the
app to install pi from the public npm registry. Assembly happens in a
staging directory that is swapped into place at the end, so a failed setup
leaves nothing half-written.

#### Progress is 0 to 1, or -1 when length unknown
`AgentRuntimeInstaller.Phase.downloading`: 0…1; -1 when length unknown

#### Recursive audit is user-requested; pane entry uses cheap receipt
`AgentRuntimeInstaller.verifyInstalledState`: User-requested recursive audit. Normal pane entry relies on the cheap
install receipt checked during initialization; this slower operation
opens and hashes the full runtime tree on a utility executor.

### `LokalBot/Agent/AgentSessionController.swift`

#### Controller is main-actor because it feeds SwiftUI; orchestrates session
`AgentSessionController`: Orchestrates one Agent Mode session: resolves the LLM endpoint, spawns
the pi subprocess (or a test transport), pumps pi events into the
transcript, and round-trips tool approvals between pi's confirm dialogs
and the UI. Lives on the main actor because it feeds SwiftUI directly.

#### Plan relay is local but the plan's provider answers
`AgentSessionController.ModelContext`: A plan relay listens on this Mac; the plan's provider answers.

#### Model context stays bound to this process even if Settings change
`AgentSessionController.modelContext`: Bound to this process's connection, even if Settings changes later.

#### Library lookups pass only for a model known to run on this Mac
`AgentSessionController.modelContext`: The approval policy lets library lookups through only for a model
known to run on this Mac; no bound model means it asks.

#### Levels accepted by launched model; nil until launch resolves
`AgentSessionController.reasoningSupport`: The levels the launched model accepts; nil until a launch resolves them.

#### True after Stop until the next message or turn
`AgentSessionController.wasStopped`: True after Stop ended a turn, until the next message or turn.

#### Records whether write target existed to tell new from replaced
`AgentSessionController.writeTargetExisted`: For each write step seen as it started, whether its file was already
there. It tells a new file from a replaced one afterwards.

#### hasSavedConversation covers saved tasks not yet loaded
`AgentSessionController.status`: Where the task stands. `hasSavedConversation` covers a task whose
saved conversation has not been loaded into this controller yet.

#### Only finished tasks count changed files because counting reads disk
`AgentSessionController.status`: Only a finished task counts its changed files; counting reads the disk.

#### English status for logs and VoiceOver fallbacks
`AgentSessionController.taskStatus`: The status in English, for logs and VoiceOver fallbacks.

#### Relative path starts at request folder; place judged against task workspace
`AgentSessionController.approvalTarget`: The file an approval request names. A relative path starts at the
folder the request came from; where it sits is judged against this
task's working folder.

#### Place is working folder, LokalBot data, or elsewhere
`AgentSessionController.approvalPlace`: Where an approval request's file sits: the working folder, LokalBot's
own data, or anywhere else.

#### Approval mode is app preference with its own defaults key
`AgentSessionController.approvalModeDefaultsKey`: The approval mode is an app preference, unlike per-tool "Allow for
Session" exceptions. Keep the key separate from the encoded meeting
settings blob so changing it never rewrites unrelated settings.

#### Generation invalidates in-flight start after tab close or restart
`AgentSessionController.lifecycleGeneration`: Invalidates an in-flight start when its tab is closed or restarted.
Without this, a close during model warm-up could finish spawning pi
after shutdown() had already returned.

#### Failure cleanup serialized so replacement never launches during teardown
`AgentSessionController.failureTeardownInProgress`: Serializes failure cleanup with shutdown/restart. A failed state is not
published until this returns to false, so a replacement process can
never launch while its predecessor is still being terminated.

#### Lease held only while a turn runs, never while task idles
`AgentSessionController.llmLease`: Held while a turn runs (built-in engine only), so the Main LLM cannot
be evicted mid-turn by an unrelated model load. A task that is open
but waiting holds nothing: a lease kept for as long as the tab stayed
open made every other model on that server wait behind it.

#### Built-in weights remembered to retake lease next turn
`AgentSessionController.builtInModel`: The built-in weights this runtime talks to, for taking the lease
again at the next turn; nil for a server or a plan.

#### Unanswered model requests are cancelled by Stop
`AgentSessionController.modelWaits`: Requests for the model that have not been answered yet; Stop cancels
them.

#### Plan relay runs from resolveEndpoint until shutdown or failure
`AgentSessionController.planRelay`: Runs from resolveEndpoint (ChatGPT plan only) until shutdown or
failure, like the lease.

#### Extension reads reasoning level file before every model call
`AgentSessionController.reasoningLevelFile`: The extension reads the Agent reasoning level from this file before
every model call, so a change applies from the agent's next step.

#### UI-test-only path skips warm-up, subprocess and network; opt-in
`AgentSessionController.start`: Keep Agent Mode UI tests hermetic: no model warm-up, capability
issuance, subprocess, or network. Production builds never compile
this path, and host runs must opt in explicitly.

#### shutdown may run while broker was ensuring, before lease assigned
`AgentSessionController.start`: shutdown() may have run while the broker was still ensuring,
before resolveEndpoint had assigned the lease.

#### Revoke capability before SIGTERM grace so tab close cuts access immediately
`AgentSessionController.shutdown`: Revoke access before giving a hung child its SIGTERM grace period.
Closing a tab must close the meeting-library capability immediately,
even if pi ignores termination until the SIGKILL fallback.

#### Follow-ups stay in host queue so cancel and edit are real
`AgentSessionController.queueDraft`: Called only after the user submits. Follow-ups stay in the host queue
until delivery, making cancellation and editing real operations.

#### Send as steering while running; restore queue place on failure
`AgentSessionController.sendQueuedNow`: Sends one queued message without waiting for the turn to end: as a
steering message while the agent works, as the next message otherwise.
The message returns to its place in the queue when it cannot be sent.

#### Throws when connected server or plan approval was withdrawn
`AgentSessionController.requireApprovedDestination`: Throws when the server or plan this runtime is connected to is no
longer approved in Settings → Models.

#### Relay loopback passes origin check; plan has its own approval
`AgentSessionController.requireApprovedDestination`: The relay's loopback URL passes the origin check; the plan has
its own approval.

#### Running turn ends when its destination approval is withdrawn
`AgentSessionController.remoteApprovalsDidChange`: Call when an approval for a Think server or plan is withdrawn. During
a turn the agent sends the conversation, attached context and tool
results to its endpoint at every model step without passing through
`send`, so a turn on a destination that is no longer approved ends
here, with its process. A session that is waiting sends nothing until
`send`, which refuses.

#### Do not cancel an in-flight RPC ack or prompt is requeued
`AgentSessionController.abort`: Once an RPC is sent, canceling its acknowledgement would report a
transport failure and requeue an already-delivered prompt. Let that
acknowledgement settle while abort independently stops the turn.

#### Resolve pending approvals first; Pi confirmation has no abort signal
`AgentSessionController.abort`: Pi's confirmation promise has no abort signal. Resolve it as a
cancellation first or Pi's abort RPC can wait forever for idle.

#### Park pauses idle runtime keeping saved task, draft and preview
`AgentSessionController.park`: Pause an idle runtime without losing the saved task, draft, or preview.

#### Mode change answers visible cards and clears per-tool exceptions
`AgentSessionController.setApprovalMode`: Applies the remembered app-level mode and immediately answers any
already-visible cards that the new mode now permits. Changing modes
clears narrower per-tool session exceptions so downgrades take effect.

#### Read-only lookups skip card in read modes; on for meeting handoffs
`AgentSessionController.allowsLibraryLookups`: Read-only `lokalbot-cli` lookups run without a card in the read modes
even when the model is not on this Mac. On for tasks handed off from a
meeting's actions.

#### Unattended --agent hook approves only workspace file changes
`AgentSessionController.approveWorkspaceFileChangesForAutomation`: Keeps the existing unattended `--agent` test hook narrowly scoped to
workspace file changes; external reads and shell commands still surface
and are denied by that caller.

#### Unattended callers deny every card once so pi turn cannot hang
`AgentSessionController.denyAllPendingApprovals`: Unattended callers have nobody available to inspect sensitive requests.
Resolve every card as a one-time denial so the pi turn cannot hang.

#### Cancelled loop end must not fold a spurious failure
`AgentSessionController.consumeEvents`: shutdown() cancels this task and only later sets .idle; a
cancelled iteration ending must not fold a spurious failure.

#### Fold token deltas at display cadence; flush before structural events
`AgentSessionController.handle`: Pi can emit hundreds of token deltas per second. Fold and publish
those as one string at display cadence; structural events flush the
pending text first so message/tool/approval ordering stays exact.

#### Deliver queued prompts on agent_settled, not agent_end
`AgentSessionController.handle`: agent_end can precede automatic retry/compaction. The pinned Pi
runtime emits agent_settled only after the complete run is idle.

#### Injected transports must not prompt for real credentials
`AgentSessionController.resolveEndpoint`: Injected transports never contact the configured service and
must not prompt for real Keychain or local-server credentials.

#### Take built-in model per turn, waiting if server busy
`AgentSessionController.holdModelForTurn`: Takes the built-in model for the turn about to start, waiting behind
other work when the server is busy with a different model.

#### Every caller requests its own lease to avoid stale stored lease
`AgentSessionController.holdModelForTurn`: Every caller asks for a lease of its own. When a send joined the
request of a turn the agent had started, the turn could settle and
give the lease back before the send resumed, and the send then
stored that lease as if it were still held.

#### Agent-started turns take the model without blocking event loop
`AgentSessionController.holdModelForStartedTurn`: The agent can start a turn the host did not send, such as a follow-up
it accepted just before settling. Take the model for it without
holding up the event loop.

#### Release if turn settled before the model was free
`AgentSessionController.holdModelForStartedTurn`: The turn may have settled before the model was free.

#### On agent_settled give server back; keep relay and identity
`AgentSessionController.releaseModelBetweenTurns`: The agent is idle (`agent_settled`): give the server back until the
next turn. The relay and the model's identity stay.

#### Running agent picks level up at next model call
`AgentSessionController.reasoningLevelDidChange`: Call after the Agent or Think reasoning setting changes. A running
agent picks the level up at its next model call; `send` also checks.

#### Level clamped to what launched model accepts
`AgentSessionController.writeReasoningLevel`: The chosen level, clamped to what the launched model accepts.

#### pi treats a missing path as prompt text, so check existence
`AgentSessionController.makePlan`: pi takes a missing path as the prompt text itself.

#### Capture session file so two tabs cannot open same JSONL
`AgentSessionController.captureActiveSessionFile`: Production Pi reports the exact file it created or resumed. Capturing
it lets the history browser prevent the same JSONL file from being
opened by two live tabs. Test transports skip this background request.

#### Fire-and-forget release; broker serializes it internally
`AgentSessionController.releaseModelConnection`: Stops the plan relay and releases the Main LLM lease. Fire-and-forget
so the synchronous failure paths can call it; the broker serializes
the release internally.

#### Invalidate generation before teardown so buffered frames cannot revive state
`AgentSessionController.transitionToFailure`: Invalidates the current event generation before awaiting subprocess
shutdown. That prevents already-buffered frames from reviving `.ready`
or `.running` while teardown yields, and keeps restart disabled until
the old process has actually been terminated.

#### Session allowances reset at lifecycle; approval mode persists
`AgentSessionController.resetApprovalPolicy`: Session allowances are intentionally cleared at lifecycle
boundaries. The approval mode itself is an app-level preference and
must survive closing or resuming a session.

#### Extension sends structured payload; old summary-only payloads still readable
`AgentSessionController.parseApprovalPayload`: Our extension sends title "lokalbot_tool_approval" with exact structured
fields. Older payloads containing only `summary` remain readable.

#### Check workspace before model load; never migrate old cwd silently
`AgentSessionController.prepareWorkspace`: Used before model loading or capability issuance, including resumed
sessions and headless entry points. Never migrate an old cwd silently.

### `LokalBot/Agent/AgentSessionHistory.swift`

#### Metadata only; conversation stays in Pi JSONL until opened
`AgentSavedSession`: Lightweight metadata for one durable Pi session. Conversation contents
stay in Pi's JSONL file and are loaded only when the user opens the session.

#### Bounded streaming reader extracts only list metadata
`AgentSessionHistory`: Bounded, streaming reader for the local session directory. It intentionally
extracts only list metadata instead of retaining full prompts or responses.

#### Re-read file before launch so stale item or symlink cannot redirect
`AgentSessionHistory.validated`: Re-reads the selected file immediately before launch so a stale list
item, replaced file, or symlink cannot redirect an exact-session open.

### `LokalBot/Agent/AgentSessionTabs.swift`

#### Four-process limit applies to execution, not navigation or history
`AgentSessionTabs`: A persistent task catalog with lazily loaded transcripts. The four-process
resource limit applies to execution, never navigation or saved history.

#### Handoff skips existing tasks, keeps selection, starts as agents free up
`AgentSessionTabs.handOff`: Adds one task per handoff, skipping actions that already have a task,
without changing the selected task. Each prompt waits in its task's
composer. With `start`, tasks are sent as agents free up, at most
`maximumLiveSessions` working at once. `againIfArchived` hands an
action off again when its only task is archived. Returns the new
tasks' IDs.

#### Folder creation is best effort; agent can still make it
`AgentSessionTabs.handOff`: Best effort: the agent can still make the folder itself.

#### Start start:false handoffs once their prompt targets exist
`AgentSessionTabs.startHandoffs`: Sends tasks that were handed off with `start: false`, once whatever
their prompts point at is in place.

#### Edited draft during model warm-up is left for the person
`AgentSessionTabs.sendDraft`: Sends a task's composer the way its Send button does. A draft edited
while the model warmed up is left for the person to send.

#### Rerun on each state change so next handoff starts as an agent finishes
`AgentSessionTabs.startPendingHandoffs`: Starts waiting handoffs while an agent is free. It runs again whenever
a task's state changes, so the next one starts as an agent finishes.

#### Slot exists if under maximum live or an idle tab can be parked
`AgentSessionTabs.hasRuntimeSlot`: True when `start(id)` can run without stopping a busy agent: fewer
than the maximum are live, or an idle one can be parked.

#### Read-only selection includes tasks beyond runtime limit
`AgentSessionTabs.refreshHistory`: Read-only selection, including tasks beyond the runtime resource limit.

#### Serialize runtime transitions so a send cannot race an eviction
`AgentSessionTabs.start`: Serialize runtime transitions so another send cannot race an eviction.

#### Missing saved file must not turn a follow-up into a fresh task
`AgentSessionTabs.start`: Missing saved files must not silently turn a follow-up into a fresh task.

#### Withdrawn approval stops every turn still sending to it
`AgentSessionTabs.remoteApprovalsDidChange`: A withdrawn Think server or plan approval stops every turn that is
still sending to it.

#### State publisher fires before change; start handoffs after it settles
`AgentSessionTabs`: The publisher fires before the state changes; look once it has.

### `LokalBot/Agent/AgentTaskStore.swift`

#### UI metadata independent of Pi history; archiving never deletes
`AgentTaskRecord`: UI metadata is independent of Pi's append-only conversation. Archiving never
deletes history, and browsing a task never requires a running subprocess.

#### Handoff source prevents a second task for the same action
`AgentTaskRecord.handoff`: Set when LokalBot handed this task off, so the same action never gets
a second task.

#### Handoff without source is never matched against earlier tasks
`AgentHandoff`: One task to hand to Agent Mode: its title, the prompt for its composer,
the sources attached to that prompt, and a folder in the workspace made
for what the agent produces. A handoff with no source, such as a window
handed off by hand, is never matched against earlier tasks.

#### Attachments store references; source re-read with current permissions at send
`AgentAttachment.reference`: References only. Source text is re-read with current permissions at send.

### `LokalBot/Agent/AgentTranscript.swift`

#### Structured fields show exact command, not model-written summary
`AgentApprovalRequest`: App-owned, structured description of a mutating tool request. Keeping the
fields separate lets the approval surface show the exact command/content
instead of trusting a model-authored one-line summary.

#### Exact JSON arguments for tools without dedicated preview
`AgentApprovalRequest.arguments`: Exact JSON arguments of a tool without a dedicated preview (MCP tools,
codemode, tools added by later Pi releases).

#### Limit also enforced in extension; host fails closed
`AgentApprovalRequest.canApprove`: Also enforced in the extension before an approval is requested. Keep
the host fail-closed for old, malformed, or locally bounded payloads.

#### Pure state machine so folding rules are unit-testable
`AgentTranscriptFolder`: Folds the PiEvent stream into a display-ready transcript. Pure state
machine — no async, no UI — so every folding rule is unit-testable
(same decomposition philosophy as the Cotyping policy types).

#### Resolve index fresh to avoid stale index after removals
`AgentTranscriptFolder.streamingAssistantIndex`: Resolved fresh on every use so removals elsewhere in the array
(e.g. resolveApproval) can never leave a stale index behind.

#### Fresh attempt clears failure; only outcome at agent_settled is terminal
`AgentTranscriptFolder.fold`: A fresh attempt can recover from Pi's automatic retry. Only
the outcome left when agent_settled arrives is terminal.

### `LokalBot/Agent/AgentUITestTransport.swift`

#### UI fixture does no inference; absent from production builds
`AgentUITestTransport`: Hosted UI fixture for the real RPC/controller/approval flow. It performs
no inference or tool operations, and is absent from production builds.

### `LokalBot/Agent/ChatGPTPlanRelay.swift`

#### Relay keeps plan tokens out of pi; only POST /v1/responses relayed
`ChatGPTPlanRelay`: Lets Agent Mode's pi runtime run on the user's ChatGPT plan without ever
holding the plan's tokens. pi speaks the Responses API to this relay on
127.0.0.1 with a key issued for one session. The relay checks that key,
shapes the body to the plan route's rules, adds the current Sign in with
ChatGPT access token (`ChatGPTPlanAccount` refreshes it), and streams
OpenAI's reply back unchanged. Only `POST /v1/responses` is relayed.

#### Token source returns fresh token after a rejected one
`ChatGPTPlanRelay.TokenSource`: The current access token, or a fresh one after `rejected` was refused.

#### Request cap leaves room for full context with long tool results
`ChatGPTPlanRelay.maximumRequestBytes`: Room for a full agent context with long tool results.

#### Error replies are short JSON; longer is cut
`ChatGPTPlanRelay.maximumErrorBytes`: An error reply is short JSON; anything longer is cut.

#### Bearer key is random per relay and never stored
`ChatGPTPlanRelay.key`: The bearer key pi presents. Random per relay and never stored.

#### Exchange buffer is touched only on the queue
`ChatGPTPlanRelay.Exchange`: One connection from pi. Its buffer is touched only on `queue`.

#### Forward each event-stream line as soon as it arrives
`ChatGPTPlanRelay.liveUpstream`: Forwards each line of the event stream as soon as it arrives.

#### Detect pi closing socket even while model thinks silently
`ChatGPTPlanRelay.watchForHangUp`: pi closes its socket to abort a request. Notice that even while the
model is still thinking and nothing is being written.

#### Refresh token once on 401 since tokens can be revoked early
`ChatGPTPlanRelay.forward`: A token can be revoked or rotated early; refresh it once.

#### Early stream end shows pi a cut stream
`ChatGPTPlanRelay.relayStream`: pi hung up, or OpenAI's stream broke; pi sees the cut stream.

#### Relay errors mimic OpenAI shape; nil retry keeps pi rules
`ChatGPTPlanRelay.reply`: An error the relay itself answers, shaped like OpenAI's so pi shows
the message. `retry` nil keeps pi's own retry rules for the status.

#### Check key when head arrives, before buffering body
`ChatGPTPlanRelayRequest`: The relay's reading of one HTTP/1.1 request from pi. The key is checked as
soon as the head arrives, before a body is buffered.

#### Reject requests with Origin since only browsers send it
`ChatGPTPlanRelayRequest.read`: Browsers always send Origin; pi never does.

#### Apply plan route request rules from OpenAI preview limitations
`ChatGPTPlanRelayPolicy`: The plan route's request rules (developers.openai.com/siwc/token-sharing-open-source,
"Preview limitations", 2026-10), applied to whatever pi sends.

#### Strip fields the route rejects or that mean nothing on plan
`ChatGPTPlanRelayPolicy.unsupportedFields`: Fields the route rejects, server-side conversation state it can't use
over HTTP, and pi-ai fields that have no meaning on plan usage.

#### Body gets store false, stream true, system as developer
`ChatGPTPlanRelayPolicy.upstreamBody`: pi's body with unsupported fields removed, `store: false` and
`stream: true` set, and system messages sent as developer messages.

#### Retry only temporary plan outages, not limits or request errors
`ChatGPTPlanRelayPolicy.shouldRetry`: pi retries 408, 409, 429 and 5xx by default. Plan limits, eligibility
and request errors don't change on a retry; temporary plan outages do.
nil leaves pi's default for the status.

### `LokalBot/Agent/PiJSONLFrameSplitter.swift`

#### LF-only framing on raw bytes; U+2028/2029 must not split
`PiJSONLFrameSplitter`: Splits a byte stream into JSONL records per pi's RPC framing rules
(docs/rpc.md): LF (0x0A) is the only record delimiter; one trailing CR
is stripped; U+2028/U+2029 inside JSON strings must NOT split records —
which is why this operates on raw bytes and why `PiProcess` must never
use a String-based line reader.

### `LokalBot/Agent/PiLaunchPlanner.swift`

#### Kind feeds extension's environment prompt section
`AgentWorkspaceKind`: What the working folder is, for the extension's environment prompt section.

#### Isolate and offline pi; no context files; LokalBot system prompt
`PiLaunchPlanner`: Builds the exact pi launch contract from the 2026-07-09 spec. pi is
fully isolated from the user's ~/.pi and any repo-local pi config
(--no-extensions/-e, --no-skills/--skill, --no-prompt-templates,
--no-approve) and fully offline (--offline + PI_SKIP_VERSION_CHECK —
pi ships install telemetry and update checks enabled by default).
Context files are disabled because pi's upward discovery is not confined
to the selected workspace. Workspace files remain available through the
read tool, whose extension hook canonicalizes paths and asks before any
out-of-workspace access. LokalBot's own system prompt replaces pi's
coding-agent prompt; the extension appends the per-run environment.

#### Plan relay is local but another provider serves the model
`PiLaunchPlanner.plan`: A plan relay is on this Mac; the model is not. The extension's
environment section says who serves it.

#### Reasoning file rewritten by host; extension reads per request
`PiLaunchPlanner.plan`: The host rewrites this file when the Agent reasoning level changes;
the extension reads it for every model request. Absent: Automatic.

#### Encoding failure sends null so extension fails at startup
`PiLaunchPlanner.plan`: An encoding failure must stop the extension at startup, never omit
the protected roots. `null` is rejected by its launch validation.

#### Credential-free endpoints must not inherit another service's key
`PiLaunchPlanner.plan`: A credential-free endpoint must not inherit a key for another
service from the parent process (including injected test sessions).
The extension takes the key at startup and removes it from the
environment that the agent's shell commands inherit.

#### Disable compile caches so no copies live outside verified runtime
`PiLaunchPlanner.plan`: Bun's transpiler cache, pi's compile cache and jiti's extension cache
would keep compiled copies of pi and of the approval extension in
~/Library/Caches/bun and the temporary folder, outside the verified
runtime. Later launches would run those copies instead.

#### Helpers directory on PATH so skill finds lokalbot-cli
`PiLaunchPlanner.plan`: lokalbot-cli lives in Contents/Helpers; the bundled skill
invokes it by name, so it must be on the agent's PATH.

### `LokalBot/Agent/PiProcess.swift`

#### DispatchIO writer never blocks actor and close cancels writes
`PiStdinWriter`: A bounded, serial stdin channel. DispatchIO owns the duplicated descriptor,
so writes never block the PiProcess actor and `close()` can cancel an
in-flight write even when the child has stopped draining its pipe.

#### Close does not wait behind writes; stop aborts active I/O
`PiStdinWriter.close`: This does not wait behind an outstanding write. `.stop` asks DispatchIO
to abort active I/O and makes every queued caller fail immediately.

#### Actor supervises SIGTERM, 2s grace, SIGKILL; stdin delegated to avoid backpressure
`PiProcess`: Owns one pi subprocess: spawns it from a PiLaunchPlan, feeds stdout
bytes through PiJSONLFrameSplitter (LF-only framing — see the splitter's
doc comment), exposes complete frames as an AsyncStream, and supervises
shutdown (SIGTERM → 2s grace → SIGKILL). Mirrors the Process-handling
approach in LlamaServer, as an actor because send/stop race with the
termination handler. Stdin is delegated to PiStdinWriter so pipe
backpressure cannot pin this actor and prevent shutdown.

### `LokalBot/Agent/PiRPCClient.swift`

#### PiProcess is real transport; tests inject fakes
`PiLineTransport`: Line-oriented transport a PiRPCClient talks through. PiProcess is the
real one; tests inject fakes.

#### Actor send is the witness; only incoming needs adapting
`PiProcess: PiLineTransport`: PiProcess's actor-isolated async `send(line:)` is the protocol witness;
only `incoming` needs adapting to expose its nonisolated line stream.

#### One consumer loop owns stream; pending requests keyed by generated id
`PiRPCClient`: Correlates pi RPC commands with their `{type:"response", id:…}` acks
and fans every other stdout line out as a PiEvent. One consumer loop
(started by run()) owns the incoming stream; pending requests are keyed
by the id we generated into the command JSON.

#### For extension UI responses and lines pi never acks
`PiRPCClient.sendResponse`: For extension_ui_response and other lines pi never acks.

#### Queue keeps oldest; only text deltas lossy; others terminate stream
`PiRPCClient.emit`: The queue keeps its oldest entries so an already-buffered approval can
never be evicted by a burst. Text deltas are the sole lossy event type;
dropping any structural event terminates the stream deterministically.

#### UI responses correlate to pi's request id, not ours
`PiCommand.id`: ui responses correlate to pi's request id, not ours

### `LokalBot/Agent/PiRPCMessages.swift`

#### Commands encoded with JSONSerialization, single-line without prettyPrinted
`PiCommand`: Commands sent to pi over stdin (JSONL). Encoded with JSONSerialization,
which is guaranteed single-line without `.prettyPrinted`.

#### Only displayed fields extracted; unknown protocol additions never crash
`PiEvent`: One decoded stdout record from pi RPC mode. Only the fields Agent Mode
displays are extracted; everything else lands in `.unknown` so protocol
additions never crash the client.

### `LokalBot/Views/Agent/AgentAccessPopover.swift`

#### Access level is one remembered choice for every task
`AgentAccessPopover`: The access chip's list: the levels the app has, each with what the agent
does on its own and what still asks, then the model and reasoning. The
level is one remembered choice for every task.

#### Use launched model's levels, or selected model's before launch
`AgentAccessPopover.reasoningSupport`: The launched model's levels, or the selected model's before launch.

#### Agent's own level or Think level, offering only levels the model accepts
`AgentAccessPopover.reasoningMenu`: Agent Mode's own level, or the Think level from Settings → Models,
offering only the levels the model accepts.

### `LokalBot/Views/Agent/AgentActivityGroup.swift`

#### Finished turn's step line counts steps and holds in-between assistant text
`AgentStepsLine`: A run of tool steps as one quiet line ("Searched meeting library, read
meeting notes") that opens to a row per step. A finished turn's line
counts its steps and also holds what the agent said between them.

#### Chevron rotates to point down in either reading direction
`AgentStepsLine.body`: Turns to point down in either reading direction.

### `LokalBot/Views/Agent/AgentApprovalDock.swift`

#### Approval card shows target, effect, text to review; Deny sits apart from allows
`AgentApprovalDock`: One approval request as a card above the composer: a question that names
its target, what will happen and where, the text to review, and the
answers the policy allows for this kind of request. Deny sits apart from
the answers that allow.

#### Room for the whole preview once opened
`AgentApprovalDock.previewMaxHeight`: Room for the whole preview once it is opened.

#### A command runs in the folder its request came from
`AgentApprovalDock.presentation`: A command runs in the folder its request came from.

#### Use plain heading; selectable one reached accessibility with no words on hosted runner
`AgentApprovalDock.body`: A plain heading: a selectable one reached accessibility with no
words on the hosted macOS runner, so the question went unread.

#### Preview box fits its text up to a limit, then scrolls
`AgentApprovalDock.preview`: The box is as tall as its text, up to a limit; beyond it the text scrolls in place.

### `LokalBot/Views/Agent/AgentCommands.swift`

#### Take values not an AppState observer; AppSceneState publishes language and active
`AgentCommands`: Values, not an AppState observer: `AppSceneState` publishes the language
and whether Agent is showing, and the App body passes them in.

### `LokalBot/Views/Agent/AgentComposer.swift`

#### Messages sent while the agent works wait above the field until the turn ends
`AgentComposer`: Where the agent is told what to do: the message, what to attach, the
working folder and how much it may do on its own. A message sent while the
agent works waits above the field until the turn ends.

#### Raising the access level is confirmed; lowering applies at once
`AgentComposer.accessChip`: Raising the level is confirmed; lowering it applies at once.

#### Show destination only when model is off-device so prompt destination stays visible
`AgentComposer.destinationLine`: Shown only when the model is not on this Mac, so where a task's
prompts go stays in view without opening the access list.

#### Up to three queued rows show whole; longer queues scroll in same space
`AgentComposer.queue`: Up to three rows show whole; a longer queue scrolls in the same space.

#### While working Send queues the message; otherwise starts task and sends
`AgentComposer.submit`: While the agent works, Send queues the message. Otherwise it starts
the task if needed and sends.

#### Never send a stale draft after a suspended model warm-up
`AgentComposer.submit`: Never send a stale draft after a suspended model warm-up.

### `LokalBot/Views/Agent/AgentNoteResultRow.swift`

#### Open the agent's own note file; LokalBot keeps a search-only copy and never edits
`AgentNoteOpener`: Opens the agent's own file for a note in its default app. LokalBot keeps a
copy for search only and never edits the file.

### `LokalBot/Views/Agent/AgentResponseText.swift`

#### Use non-editable NSTextView for hanging indents, paragraph spacing and continuous selection
`AgentResponseText`: SwiftUI Text does not expose hanging indents or paragraph spacing. One
non-editable NSTextView gives Agent answers those metrics and a continuous
selection range. SwiftUI still owns content, width, search, and link routing.

#### All links pass through the session's source and file policy
`AgentResponseText.Coordinator.textView`: All links pass through the session's existing source/file policy.

#### Treat only short wholly bold paragraphs as headings, since models emit bold labels
`AgentResponseDocument.sectionKind`: Models often emit a standalone bold section label instead of ##. Treat
only short, wholly emphasized paragraphs as headings; inline emphasis
in prose retains the body size.

### `LokalBot/Views/Agent/AgentResultsPanel.swift`

#### Opening a preview never runs a tool
`AgentResultsPanel`: Beside the conversation: the files the task changed, its steps, the
sources it was given, and a preview of whichever one is chosen. Opening a
preview never runs a tool.

#### Step previews are headed by plain label; others keep their title
`AgentResultsPanel.selectedPreview`: A step's preview is headed by its plain label; other previews keep their own title.

### `LokalBot/Views/Agent/AgentSessionView.swift`

#### New task centres composer mid-page; approvals dock above composer; title and status in toolbar
`AgentSessionView`: One task: a new task's heading and composer mid-page, or the conversation
with the composer docked under it. The task's title and status sit in the
toolbar; an approval request docks above the composer.

#### Saved conversation with messages, loaded or not yet
`AgentSessionView.hasSavedConversation`: A saved conversation with messages, loaded here or not yet.

#### Resolve reading width from the pane so long content cannot inflate window minimum
`AgentSessionView.body`: Resolve the reading width from the pane, rather than allowing a
long response or an action row to contribute its ideal width to
the native window's minimum size.

#### Spacer pushes actions trailing once system title is removed
`AgentSessionView.body`: Without the system title nothing pushes the actions to the
trailing edge, so they sat against the task's title.

#### Not-started tasks show no status word; list row says Not started
`AgentSessionView.toolbarStatus`: A new task needs no word beside its title; the list row says "Not started".

#### Centre content a little above middle where the eye lands
`AgentSessionView.newTask`: A little above the middle, where the eye lands first.

#### Keep opened preview scrollable without consuming the conversation in compact windows
`AgentSessionView.conversation`: Keep the opened preview scrollable without consuming the
conversation above it in a compact window.

#### Find stops following output without scrolling short conversations; avoids button over visible text
`AgentSessionView.transcript`: Find stops following new output without scrolling a short
conversation, which left this button over text already in view.

#### A find match inside a folded step run opens that run
`AgentSessionView.transcript`: A match inside a folded run of steps opens that run.

#### In-progress assistant text shown in full without actions
`AgentSessionView.said`: What the agent says while it works, in full and without actions.

#### Final answer is focal point, then changed files, then quiet copy and retry
`AgentSessionView.answer`: The answer a finished turn ends with: the focal point, then the files
that turn changed and quiet copy and retry controls.

#### Amber when it needs an answer, teal spinner while working, quiet word otherwise
`AgentStatusPill`: The task's status beside its title: amber when it needs an answer, teal
with a spinner while it works, a quiet word otherwise.

#### Message actions need label contrast in dark mode and Increase Contrast, not brand tint
`AgentMessageActionStyle`: Message actions need label contrast, including in dark mode and Increase
Contrast, rather than the brand tint used for decorative accents.

### `LokalBot/Views/Agent/AgentSetupView.swift`

#### Allow enables settings access plus ticked read access; Don't Allow leaves everything off
`AgentSetupView`: The agent setup window: an agent ran `lokalbot-cli setup start` and asks
to set LokalBot up for the person. Allow turns on settings access and any
read access the person ticks; Don't Allow leaves everything off.

#### New install still needs setup, so declining opens onboarding
`AgentSetupCard.decline`: A new install still needs its setup, so declining leads to onboarding.

### `LokalBot/Views/Agent/AgentTaskSidebar.swift`

#### Refresh, runtime check and clear history live in the menu and Agent menu
`AgentTaskSidebar`: The task list: search and New on top, tasks grouped by day with their
status, and Archived at the bottom. Refresh, the runtime check and
clearing history are in the … menu here and in the app's Agent menu.

#### Day groups show time; pinned tasks from another day show the date
`AgentTaskSidebar.time`: A day group already names the day, so its rows show the time. A pinned
task from another day shows the date.

#### Show status, or for an idle task where it works
`AgentTaskRow.line`: The status, or for a task that is doing nothing, where it works.

#### On selected focused rows own colours read on accent fill
`AgentTaskRow.tint`: On a selected row in a focused list the row's own colours read on the accent fill.

### `LokalBot/Views/Agent/AgentView.swift`

#### Avoid nested NavigationSplitView whose inferred minimum grows with transcript
`AgentView.body`: The main window already owns navigation. A second nested
NavigationSplitView lets its inferred detail minimum grow
with the transcript and can prevent the window shrinking.

### `LokalBot/Views/Agent/ChatView.swift`

#### Ask surfaces: transcript with citations, conversation list; ChatAgent ReAct agent on-device
`ChatTranscriptView`: The assistant's conversation surfaces: the transcript embedded by the Ask
section (questions, answers with numbered citations, a sources list under
each answer), and the saved-conversation list shown in Ask's content column. The assistant itself is a small ReAct agent
(`ChatAgent`) over the summarisation `TextEngine` that can search
transcripts, list meetings, and read a meeting's summary or transcript
via tool calls — all on-device.

#### Question headings with time; flat answer, collapsed tool activity, sources, actions
`ChatTranscriptView`: The conversation transcript: each question as a heading with its time,
then the answer as flat text with tool activity collapsed to one line,
its sources and its actions. Embedded by the Ask surface.

#### page is Ask screen; compact is Quick Recall answer with tighter layout
`ChatTranscriptView.Style`: `page` is the Ask screen. `compact` is the answer inside the Quick
Recall window: tighter margins, the question under "You" and its time,
sources as rows like that window's results, and no per-answer actions
(the window's foot has Copy).

#### Lets a small window bring the main window forward and close
`ChatTranscriptView.onOpenSource`: Called after a source was opened from an answer, so a small window
can bring the main window forward and close.

#### Conversations starting today need no divider since questions carry time
`ChatTranscriptPresentation.visibleDateDividerTitle`: The divider a question shows above it. A conversation that starts
today needs none: each question already carries its time.

#### Last answer's failed state keeps its matches
`EditorialTurn.isLastTurn`: The answer that ends the conversation; a failed one keeps its matches.

#### Scope shown in time tooltip and spoken value; composer menus choose scope
`EditorialTurn.userRow`: The question in its own words, with the time it was asked. What it
was limited to is in the time's tooltip and the spoken value; the
composer's two menus are where scope is chosen.

#### Quick Recall shows You and time on a quiet line, question under it
`EditorialTurn.compactUserRow`: Quick Recall: "You" and the time on a quiet line, the question under it.

#### Answer is one selectable text; citation number pill opens passage in place
`EditorialTurn.answerText`: The answer as one selectable text. A citation number is a small pill;
clicking it shows the quoted passage at the number, in place.

#### Popover opens its source right after dismissal
`EditorialTurn.answerText`: The popover opens its source right after this.

#### Binding only for passages opened from answer numbers; sources list has its own
`EditorialTurn.answerPassage`: The passage opened from a number in the text (the sources list opens
its own, at its own numbers).

#### Turn identifier is pushed onto the group, so find the card by its title
`EditorialTurn.statusCard`: The turn's own identifier is pushed onto the card's group,
so the card is found by its title.

#### Caller owns plaintext temp speech output, including cancellation and player failures
`EditorialTurn speech playback`: Caller owns this plaintext temporary output, including
cancellation, superseded playback and player failures.

#### Reply to Remember messages is saved locally with no model involved
`RememberReceiptCard`: The reply to a "Remember …" message: saved locally, no model involved.

#### Re-find matches on this Mac within recorded sources, dates and evidence limits
`FailedAnswerMatches`: The matches for a question whose answer failed, found again on this Mac
within the sources, dates and evidence limits recorded with the question.

#### Tool activity collapses to one caption line; shows spinner step while in flight
`WorkedLine`: Tool activity collapsed to a single caption line ("worked: searched
transcripts · read summary"); expands to the per-step rows on click.
While a step is in flight it shows that step with a spinner instead.

#### Saved conversations persist across launches via ChatStore; selecting loads into transcript
`ChatConversationList`: The Ask section's question history — a selectable list of saved conversations
plus a visible "New conversation" action. Selecting one loads it into the transcript;
conversations persist across launches via `ChatStore`.

#### One native title owns toolbar label and accessibility title; no second Ask label
`ConversationListContent.body`: One native title owns both the visible toolbar label and the window's
accessibility title. The detail column deliberately adds no second
Ask label.

### `LokalBotTests/Agent/AgentApprovalPolicyTests.swift`

#### Only known options pass as lookups; output flags and future options ask
`AgentApprovalPolicyTests.testLibraryLookupsTakeOnlyTheirKnownOptions`: Only the options the four lookups take pass. An output flag, or any
option a later release might add, asks.

#### CLI commands that read other data or change LokalBot are not lookups
`AgentApprovalPolicyTests.testOtherCLICommandsAreNotLookups`: Commands that read LokalBot but are not one of the four lookups, or
that change it, are not lookups.

#### Read-only library lookups run without asking at every level when the model is on this Mac
`AgentApprovalPolicyTests.testEachLibraryLookupRunsWithoutAskingAtTheDefaultLevelWithALocalModel`: The owner's decision: a read-only lookup of the user's own library
runs without a request at the default level, and so at every level,
when the task's model runs on this Mac.

#### Lookup output goes to the model, so lookups ask when the model is remote or unknown
`AgentApprovalPolicyTests.testTheSameLookupsAskWhenTheModelIsNotOnThisMac`: A lookup's output goes to the model. With a model on a server or a
subscription plan, or one whose place is not known, the same lookups
ask wherever they asked before lookups could skip approval.

#### Full access runs every command without asking, as before
`AgentApprovalPolicyTests.testTheSameLookupsAskWhenTheModelIsNotOnThisMac`: Full access runs every command, as it did before.

#### Learning the model left this Mac revokes the lookup allowance
`AgentApprovalPolicyTests.testTheSameLookupsAskWhenTheModelIsNotOnThisMac`: Learning that the model left this Mac takes the lookup back.

#### Handed-off tasks run lookups in read levels wherever the model runs
`AgentApprovalPolicyTests.testHandedOffTasksRunLibraryLookupsInReadModes`: Unchanged from before: a task handed off from a meeting's actions runs
lookups in the read levels wherever its model runs, and asks at the
default level unless the model is on this Mac.

#### With a local model everything that is not a proven lookup still asks
`AgentApprovalPolicyTests.testEverythingElseStillAsksAtTheDefaultLevel`: With a model on this Mac, everything that is not a proven lookup
still asks at the default level.

#### Lookup rule applies only to the shell tool with its command present
`AgentApprovalPolicyTests.testEverythingElseStillAsksAtTheDefaultLevel`: The lookup rule is for the shell tool only, with its command present.

#### Request from a folder other than the task's working folder is stale and asks
`AgentApprovalPolicyTests.testLookupFromAnotherWorkingFolderStillAsks`: A request from a folder other than the task's working folder is stale
or malformed, and asks even when it is a lookup.

### `LokalBotTests/Agent/AgentPresentationTests.swift`

#### A step label never hides what ran; chainable or redirecting commands show their text
`AgentPresentationTests.testOtherCommandsShowTheirText`: A label never hides what ran: anything a shell could chain or redirect
is a command, shown with its text.

#### A step still running when its task stopped never finished
`AgentPresentationTests.testStepTextFollowsItsState`: Still running when its task stopped: it never finished.

#### Translations that put the file name first keep their capitals
`AgentPresentationTests.testSummaryNamesEachDifferentStepOnce`: Where a translation puts the file name first, its capitals stay.

#### Folding drops nothing: every message is in exactly one block
`AgentPresentationTests.testFinishedTurnFoldsItsWorkIntoOneLineAboveTheAnswer`: Nothing is dropped: every message is in exactly one block.

#### A saved conversation that is only being read is not done again
`AgentPresentationTests.testStatusFollowsWhatTheTaskIsDoing`: A saved conversation that is only being read is not "done" again.

#### Group tasks in the current time zone because day titles use it
`AgentPresentationTests.testTasksGroupByDayWithPinnedFirst`: Day titles are formatted in the current time zone, so group in it too.

#### History cannot say whether a written file existed before, so it shows as written
`AgentPresentationTests.testChangedFilesComeFromSucceededWritesAndEdits`: History does not say whether a written file was there before.

#### A write's text stays on this Mac until the agent reads something back
`AgentPresentationTests.testCommandAndOtherToolsShowExactlyWhatWillRun`: A write's text stays on this Mac until the agent reads something back.

### `LokalBotTests/Agent/AgentRuntimeInstallerTests.swift`

#### Fixture zip mirrors the real Bun release layout bun-darwin-aarch64/bun
`AgentRuntimeInstallerTests.makeBunFixture`: zip containing bun-darwin-aarch64/bun (the layout of the real Bun release zip)

### `LokalBotTests/Agent/AgentRuntimeTests.swift`

#### Expected digest is sha256 of the string hello without newline
`AgentRuntimeTests.testSHA256HexDigestOfKnownData`: shasum -a 256 \<\<\< "hello" (with trailing newline stripped): sha256("hello")

#### Cheap receipt skips node_modules; explicit deep audit still covers dependency code
`AgentRuntimeTests.testInstalledReceiptIsFastAndDeepAuditDetectsRuntimeTampering`: The cheap receipt intentionally avoids walking node_modules. An
explicit deep audit still covers imported/runtime dependency code.

#### Maintainer-only check against a fresh frozen install; skips in CI to avoid npm
`AgentRuntimeTests.testCurrentManifestMatchesProvidedPinnedRuntimeTree`: Maintainers can point this at a fresh frozen-lockfile install when
updating the pinned pi runtime. It deliberately skips in ordinary CI,
which must not depend on npm or a preinstalled package tree.

### `LokalBotTests/Agent/AgentSessionControllerTests.swift`

#### Library, saved tasks and runtime paths count as LokalBot's own data
`AgentSessionControllerTests.testApprovalCardKnowsWhetherItsFileExistsAndWhereItIs`: LokalBot's library, its saved tasks and its runtime are its own data.

#### Relative path from a request in another folder is judged where it really is
`AgentSessionControllerTests.testApprovalCardKnowsWhetherItsFileExistsAndWhereItIs`: A relative path from a request made in another folder is judged where it really is.

#### Lookup output goes to the model, so a server-hosted model shows the card
`AgentSessionControllerTests.testLibraryLookupAsksWhenTheModelIsNotOnThisMac`: A lookup's output goes to the model, so with a model on a server the
same lookup shows its card, at the default level and in the read levels.

#### Read levels do not let remote-model lookups through either
`AgentSessionControllerTests.testLibraryLookupAsksWhenTheModelIsNotOnThisMac`: The read levels do not let it through either, as before.

#### Task handed off from meeting actions keeps lookups in the read levels
`AgentSessionControllerTests.testLibraryLookupAsksWhenTheModelIsNotOnThisMac`: A task handed off from a meeting's actions keeps what it had in the read levels.

#### RPC ack and settled event are consumed separately; await published state, not race
`AgentSessionControllerTests.testStopCancelsPendingApprovalBeforeAwaitingIdle`: The RPC acknowledgement and settled event are consumed separately.
Await the published state instead of racing the event-consumption task.

#### Agent talks to its server each step without send, so revoking must end the turn
`AgentSessionControllerTests.testRevokingTheServerStopsARunningTurn`: During a turn the agent talks to its server at every model step
without going through `send`, so revoking the server must end the
turn itself, not only refuse the next prompt.

#### Open task must not hold the built-in model server while idle
`AgentSessionControllerTests.testBuiltInModelIsHeldOnlyWhileATurnRuns`: An open task on the built-in model used to keep the model server for
as long as its tab stayed open, so work on any other model (a changed
Think model, a separate dictation model) waited until the tab closed.

#### Other-model lease is given a few seconds because a held lease would wait for tab close
`AgentSessionControllerTests.testBuiltInModelIsHeldOnlyWhileATurnRuns`: Work on another model gets the server at once while the task waits.
Behind a held lease this request would wait until the tab closed,
so it is given a few seconds, not awaited outright.

#### Agent-started turn and a send during model fetch share exactly one lease
`AgentSessionControllerTests.testATurnTheAgentStartedAndASendKeepOneLeaseBetweenThem`: A turn the agent starts by itself and a send that arrives while the
model is still being fetched each ask for the model. Exactly one lease
is kept for the turn, and it goes back when the turn settles.

#### First ensure is start-up; later ensures asked by a turn are held
`AgentSessionControllerTests.testATurnTheAgentStartedAndASendKeepOneLeaseBetweenThem`: The first ensure is the start-up; hold the ones a turn asks for.

#### send awaits pi's response ack, so ack the first request id p1 concurrently
`AgentSessionControllerTests.testSendFoldsUserAndStreamsAssistant`: send() awaits pi's response ack, so run it concurrently and ack it
once the prompt line is on the wire (first request id is "p1").

#### Shell permission cannot be persisted by requesting session scope
`AgentSessionControllerTests.testBashAlwaysRequiresOneTimeApproval`: A caller cannot persist shell permission even if it requests session
scope; the next command must surface independently.

#### Reads outside the selected workspace stay one-request capabilities
`AgentSessionControllerTests.testOutsideWorkspaceReadAlwaysRequiresOneTimeApproval`: Even if a caller attempts session scope, reads outside the selected
workspace remain one-request capabilities.

#### A late event from the old open stream must not mutate the replacement session
`AgentSessionControllerTests.testRequestFailureTearsDownOldEventLoopBeforeRestart`: The first stream is deliberately still open. A late event from it
must not mutate the replacement session.

### `LokalBotTests/Agent/AgentSessionTabsTests.swift`

#### Controllers are made on add, so transport 0 belongs to the initial task
`AgentSessionTabsTests.testStartedHandoffsKeepFourAgentsWorkingAndStartTheNextAsOneStops`: Controllers are made when tasks are added: the first transport is the initial task's.

#### Second handoff's controller is the last transport made
`AgentSessionTabsTests.testStartedHandoffSkipsATaskSentOrClearedByHand`: The second handoff's controller is the last one made.

#### Failed package copy must not send a prompt naming files that are missing
`AgentSessionTabsTests.testAHandoffLeftUnstartedIsSentOnlyWhenStarted`: A window handoff copies its package into the task's folder before the
task may start. When the task was queued to start first and the copy
then failed, the agent was sent a prompt naming files that were not there.

### `LokalBotTests/Agent/AgentTranscriptTests.swift`

#### Transcript folding rules: deltas accumulate, message_end replaces, one card per call, empty bubbles dropped
`AgentTranscriptTests`: Folding rules: streaming deltas accumulate into one assistant bubble,
message_end replaces it with the final text, tool events drive one card
per toolCallId, and empty assistant bubbles (tool-call-only turns) are
dropped.

#### Removing the approval card shifts indices; a stale raw index would go out of range
`AgentTranscriptTests.testResolveApprovalKeepsStreamingDeltasOnTheRightBubble`: Removing the card shifts the array under the streaming bubble; the
assistant is now the LAST item, so a stale raw index would be out
of range on the next delta.

#### Settling covers a user abort mid-stream where no message_end arrives
`AgentTranscriptTests.testAgentSettledEndsStreamingAssistantItem`: e.g. user aborted mid-stream: no message_end

### `LokalBotTests/Agent/AgentWorkspaceTests.swift`

#### Approval never appears in the conversation; the card above the composer owns it
`AgentWorkspaceTests.testActivityGroupingPreservesMessageOrderAndKeepsApprovalsOutOfTranscript`: The approval never appears in the conversation: the card above the composer owns it.

### `LokalBotTests/Agent/ChatGPTPlanRelayTests.swift`

#### Relay tests use real loopback HTTP with a fake OpenAI upstream and token source
`ChatGPTPlanRelayTests`: The relay Agent Mode's pi talks to for the ChatGPT plan, over real
loopback HTTP with a fake OpenAI upstream and token source.

#### Keeps the body open after the chunks, like a model still thinking
`ChatGPTPlanRelayTests.FakeOpenAI.Reply.staysOpen`: Keeps the body open after the chunks, like a model still thinking.

### `LokalBotTests/Agent/PiJSONLFrameSplitterTests.swift`

#### pi RPC framing: LF is the only delimiter, trailing CR stripped, U+2028 and U+2029 do not split
`PiJSONLFrameSplitterTests`: pi RPC framing rules (docs/rpc.md "Framing"): LF is the ONLY record
delimiter; a trailing CR is stripped; U+2028/U+2029 inside JSON strings
must not split records.

#### Chunks split mid-record and mid-UTF-8 sequence
`PiJSONLFrameSplitterTests.testReassemblesRecordsAcrossChunks`: Split mid-record AND mid-UTF-8-sequence (é is 2 bytes).

### `LokalBotTests/Agent/PiLaunchPlannerTests.swift`

#### Scripts/tests/pi-runtime.test.ts checks these settings leave no cache
`PiLaunchPlannerTests.testCompiledCopiesOutsideTheVerifiedRuntimeAreDisabled`: Scripts/tests/pi-runtime.test.ts checks that these leave no cache.

### `LokalBotTests/Agent/PiProcessTests.swift`

#### sleep never reads stdin, so a full RPC frame keeps the writer busy until stop
`PiProcessTests.testStopIsBoundedWhenChildDoesNotDrainStdin`: `sleep` deliberately never reads stdin. A full-size RPC frame fills
the pipe and keeps the dedicated writer busy until stop closes it.

#### The first frame owns the bounded 4 MiB input budget
`PiProcessTests.testStopIsBoundedWhenChildDoesNotDrainStdin`: expected: the first frame owns the bounded 4 MiB budget

#### Kernel may report EPIPE before DispatchIO observes the close
`PiProcessTests.testStopIsBoundedWhenChildDoesNotDrainStdin`: The kernel may report EPIPE before DispatchIO observes close.

### `LokalBotTests/Agent/PiRPCClientTests.swift`

#### Failing closed on event overflow because the approval could not be queued
`PiRPCClientTests`: Expected: the approval could not be queued, so the client failed closed.

#### After overflow the client stays terminal with the same deterministic failure
`PiRPCClientTests`: Expected: later callers observe the same deterministic failure.

### `LokalBotTests/Agent/PiRPCMessagesTests.swift`

#### Displayed tool args keep paths readable, not escaped slashes
`PiRPCMessagesTests.testToolArgsDoNotEscapeSlashes`: Displayed tool args keep paths readable: "/Users/…", not "\/Users\/…".

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
