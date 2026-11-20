# 0087. Windows and Linux: core — coding_agents

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/coding_agents/`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/coding_agents/attribution.rs`

#### Time attribution to projects is deterministic name matching with agent-burst overlap
Splits the day's foreground activity across the projects its coding-agent
sessions worked in (`TimelineProjectAttribution.swift`). A window whose
title names a project counts toward it. Time in an app where an agent runs
(Claude, Codex, a terminal, an editor) goes to the agent bursts it overlaps,
and only for the part those bursts cover. Everything else stays
unattributed. Deterministic matching on names; no model decides.

#### Windows within two minutes of a burst edge count, since request is typed just before
`EDGE_MARGIN_SECONDS`: Agent activity counts for a window this close to a burst's edges: a burst
starts with the request, which the person typed just before.

#### Only person-started bursts, not scheduled runs, oldest first
`Attribution.bursts`: Bursts the person started, not scheduled runs, oldest first.

#### Ties break by name so ordering never flickers
`ranked`: Busiest first; equal times by name, so the order never flickers.

#### Busiest project wins a window title naming two
`Attribution::new`: The busiest project wins a title that names two.

#### Linked repositories name projects; project-of-day names keep their own
`Attribution::new`: A repository a session linked names its project too, as when the
folder is "alpha" and the repository "logic-onchain". One named after
a project of the day stays that project's; any other goes to the
project that linked it most.

#### Shares never exceed block duration; remainder is unattributed
`Attribution::shares`: The block's time per project, busiest first. The shares never add up to
more than the block's duration; the remainder is unattributed.

#### Distinct window titles matched once because days repeat them
`Attribution::shares_of`: Each block's shares, in order. A day repeats the same window titles many
times, so each distinct one is matched against the projects once.

#### Bursts sorted by start, so loop breaks early
`Attribution::agent_shares`: Bursts are in start order, so none after this one can overlap.

#### Covered time is clipped to the block itself
`Attribution::agent_shares`: The covered part is measured inside the block itself.

#### First nineteen match Mac list; rest are Linux and Windows hosts
`SHARED_HOSTS`: The first nineteen are the Mac's list; the rest are the terminals and
editors agents run in on Linux and Windows.

#### Apps carrying a channel suffix match by prefix
`SHARED_HOST_PREFIXES`: Apps whose name carries a channel, such as "T3 Code (Nightly)".

#### Chat apps without coding agent never count; other time stays unattributed
`hosts`: Whether `app` can be where the person drives this agent: its own app, a
terminal, or an editor. A chat app with no coding agent never counts, so
time spent elsewhere while agents work stays unattributed.

#### Resumed agent session's bursts read as one task
`AgentTask`: One agent session's work inside a work session. An agent session that
pauses and resumes leaves several bursts; they read as one task
(`TimelineAgentTask`).

#### Latest burst's name used because sessions get renamed
`AgentTask::title`: The latest name: a session can be renamed as the work takes shape.

### `LinuxWindows/crates/lokalbot-core/src/coding_agents/mod.rs`

#### Bursts stored with sorted-key JSON and Swift-reference-second dates
Coding-agent evidence (`CodingAgentSession.swift`): Claude Code and Codex
work saved as bursts in `coding_agent_bursts`, with sorted-key JSON payloads
whose dates are Swift-reference seconds. The transcript readers live in
`lokalbot-engine`; this is the data every other feature reads.

#### Must match digest segment split
`INACTIVITY_GAP_SECONDS`: Matches the digest's segment split: later events start a new burst.

#### Gaps beyond five minutes count as waiting
`ACTIVE_GAP_CAP_SECONDS`: Longer gaps between events count as waiting, not active work.

#### Actions are recorded commands, not claims; encoded like Swift enums
`CodingAgentAction`: An outcome parsed from a command the agent ran. These are recorded actions,
unlike the agent's own report, which is only a claim. Encoded as Swift
encodes enums with associated values: `{"commit":{"message":"…"}}`.

#### Number absent when command merged current branch's PR
`CodingAgentAction::MergedPullRequest`: `number` is absent when the command merged the current branch's PR.

#### Label format owner/repo#N matches DayDigestEvidence.pullRequestLabel
`pull_request_label`: `owner/repo#N` for a GitHub pull request URL (`DayDigestEvidence.pullRequestLabel`).

#### Field order and omitted optionals reproduce Swift sortedKeys payload
`CodingAgentBurst`: A contiguous run of agent work inside one session. The fields are in
sorted-key order, so the payload reads as the Mac's `.sortedKeys` encoder
writes it. Absent optionals are left out, as Swift leaves them out.

#### Formats numbers like Swift String(Double) for evidence signatures
`number`: `String(Double)`, as the Mac's evidence signatures format numbers.

#### Burst id stable within a day: session plus first event
`CodingAgentBurst::id`: Stable within a day: bursts are keyed by session and first event.

#### Only settled bursts become evidence so saved digests stay fixed
`CodingAgentBurst::is_settled`: A burst idle for the full inactivity gap can never grow again. Only
settled bursts become evidence, so a saved digest's inputs cannot
change underneath it.

#### Scheduled runs often report on earlier days
`CodingAgentBurst::is_scheduled_run`: Every request came from a schedule, not from the person at the time.
Such runs often report on earlier days.

#### Presentation fields may change on settled bursts; work does not
`CodingAgentBurst::has_same_work`: The same requests, reply, actions, pull requests and tool calls in the
same session. A settled burst's work never changes, but how it is
presented can: a session is renamed, and bursts saved by earlier readers
carry the session's folder and branch, file names relative to another
folder, and edges moved by activity on the other side of midnight.

#### Times compared to a millisecond because stored seconds round
`CodingAgentBurst::is_same_as_stored`: Equal in every stored field. Times and durations are compared to within
a millisecond: a scan's times come from the transcript, a stored burst's
from Swift-reference seconds, and the two differ by rounding only.

#### Fixed field order so signatures change exactly with content
`CodingAgentBurst::signature_fields`: Every field the digest can read, in a fixed order, for evidence
signatures that change exactly when the burst's content does.

#### Substantive content first, trace metadata last and labeled
`CodingAgentBurst::evidence_text`: Model-facing evidence in the same shape as the digest's other work
sources: substantive content first, trace metadata last and labeled.

#### Request-like or placeholder titles are omitted from evidence
`CodingAgentBurst::evidence_text`: A request or placeholder title names no work; the requests below
already say what was asked.

#### Untitled sessions get request or placeholder titles that name no work
`CodingAgentBurst::title_names_work`: The title came from the transcript and names the work. A session the
transcript leaves untitled is labeled with its first request or a
placeholder, which name a conversation instead.

#### Title fallback order: session title, deliverable, short instruction
`CodingAgentBurst::work_title`: A short work title for a task list: the session's own title when it
names the work, otherwise the deliverable its recorded actions name (an
opened pull request, then a commit), then its request when that is a
short instruction. "can you add a demo to the PR?" and "Untitled
session" never become a task.

#### Projectless folders and sibling checkouts take project from pull requests
`CodingAgentBurst::work_project`: The repository the work belongs to. A session started in a folder that
names no project, such as a scratch folder or the folder holding every
checkout, takes it from its pull requests, as does a sibling checkout
such as `LokalBot-port`. `None` when nothing names one.

#### Session shown once rather than once per burst in summaries
`merging`: One session's bursts as a single view, for a summary that should see the
session once rather than once per burst.

#### Project is repository name; agent worktrees live under .claude/worktrees
`project_name`: The repository name, not the checkout folder: agent worktrees live under
`<repo>/.claude/worktrees/<name>`.

#### Scratch, checkout-holding and home folders name no project
`names_no_project`: A folder that holds work without naming it: no folder at all, a Claude
scratch folder such as `scratch-2026-10-19-6f7eb7`, or a folder that holds
checkouts, such as `~/Documents/GitHub` or the home folder.

#### Undecodable stored payload reads as nothing
`decode`: A stored payload; one that doesn't decode reads as nothing.

#### Bursts never cross midnight so start names the day; bad payloads skipped
`Library::coding_agent_bursts`: Settled bursts that began in `[start, end)`, oldest first. A burst never
crosses midnight, so its start names its day. An undecodable payload
is skipped, as the Mac skips it.

#### Only writes so a failure never looks like an empty source
`Library::upsert_coding_agent_bursts`: Inserts or replaces bursts by id. Callers compute what changed; this
only writes, so a failure never looks like an empty source.

#### Deleting bursts withdraws journals but never touches agent transcripts
`Library::delete_coding_agent_evidence`: Deletes every saved burst, withdrawing the generated journals that used
them (`AppState.deleteCodingAgentEvidence`). The agents' own transcripts
are never touched. The caller stops reading first.

### `LinuxWindows/crates/lokalbot-core/src/coding_agents/tests.rs`

#### Fixture mirrors Swift JSONEncoder sortedKeys encoding
`mac_payload`: `JSONEncoder` with `.sortedKeys` over the Swift `CodingAgentBurst`: dates as
seconds since 2001, enums with associated values as `{"case":{...}}`, and a
`nil` optional left out.

#### Moved Mac libraries carry the key true without ever being asked
`reading_needs_both_the_setting_and_a_choice_the_person_made`: Existing installs here, and libraries moved from a Mac, carry the key
as true without ever having been asked.

### `LinuxWindows/crates/lokalbot-core/src/coding_agents/text.rs`

#### Keep case when second letter is uppercase, as in iOS
`instruction`: "iOS …" keeps its case.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
