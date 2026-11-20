# 0016. Mac app: CodingAgents

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/CodingAgents/`, `LokalBotTests/Services/CodingAgents/`.

## Decisions

### `LokalBot/Services/CodingAgents/ClaudeCodeSessionReader.swift`

#### Unreadable files are reported, never fatal, so agent format changes do not stop digest
`CodingAgentReadResult`: What one reader found for a day. Unreadable files are reported, never
fatal: an agent update that changes its format must not stop the digest.

#### Cached variant reparses only bytes appended since last read
`CodingAgentSessionReader.transcripts(in:cache:)`: The same, reusing what earlier scans parsed: only bytes appended to
a transcript since it was last read are parsed again.

#### Select by metadata to keep multi-gigabyte archives out; optionally include Codex .zst
`CodingAgentSessionReader.candidateFiles`: Transcript files that may hold activity inside `interval`: written
since it began, and created before it ended. Skipping by metadata
keeps multi-gigabyte archives out of every scan. `compressedRollouts`
also takes Codex's compressed rollouts, `*.jsonl.zst`.

#### Compressed file creation date postdates session start, so use bounded start
`CodingAgentSessionReader.candidateFiles`: A compressed file was created when it was compressed, after its session began.

#### Reads only prompts, replies, edit/shell tool inputs, titles, PR links; results give timestamps only
`ClaudeCodeSessionReader`: Reads Claude Code sessions from `~/.claude/projects/<cwd-slug>/<id>.jsonl`.

Only user prompts, the agent's text replies, tool names and inputs for
file edits and shell commands, titles, and PR links are read. Tool
results are recognised from their opening bytes and contribute only a
timestamp. Subagent sidechains, meta records, and compaction summaries
are skipped.

#### Only top-level project files; subagent transcripts live in subfolders and are skipped
`ClaudeCodeSessionReader.transcripts`: Top level of each project folder only: subagent transcripts live
in per-session subfolders and are not the person's sessions.

#### Read older files first so forked history is credited to the original session
`ClaudeCodeSessionReader.transcripts`: A fork or resumed session copies earlier records under their
original ids. Reading older files first credits that history to
the session where it happened.

#### De-duplication depends on the whole scan so is not cached in summaries
`ClaudeCodeSessionReader.transcripts`: De-duplication against other files depends on the whole scan,
so it happens here rather than in the cached summary.

#### A file whose window holds only copied records claims nothing
`ClaudeCodeSessionReader.transcripts`: A file whose window holds only copies claims nothing.

#### Cached per-file summary holds record times, ids, labels, compacted events and titles
`ClaudeCodeSessionSummary`: What the Claude Code reader keeps of one session file between scans:
each timed record's time, id, and labels, the events those records hold
with redundant activity compacted away, and the file's titles. A
window's transcript is built from it when a scan reads it.

#### Hashed record id drops fork copies; per process, never persisted
`ClaudeCodeSessionSummary.Record.key`: The hashed record id, for dropping copies a fork or resumed
session carries. Hashes are per process and never persisted.

#### Index into labels, or -1 when record names neither folder nor branch
`ClaudeCodeSessionSummary.Record.label`: Index into `labels`, or `-1` for a record naming neither.

#### Same folder/branch pair shared so long sessions store each path once
`ClaudeCodeSessionSummary.Label`: A folder and branch records ran in. Records naming the same pair
share one copy, so a long session holds each path once.

#### Checked across whole file since earlier library text can reappear in replies
`ClaudeCodeSessionSummary.consultedLokalBot`: Checked across the whole file, not just the window: text read from
the library earlier can still be restated in today's replies.

#### A record the file already holds is a copy counted at first appearance
`ClaudeCodeSessionSummary.consume`: A record the file already holds is a copy, with the same time; it
counts where it first appears.

#### Tool results hold most bytes; read only their time
`ClaudeCodeSessionSummary.consume`: Tool results carry most of the bytes; read only their time.

#### Events keep each record's folder and branch so bursts are labeled by own work
`ClaudeCodeSessionSummary.consume`: Each record names the folder and branch it ran in; its
events keep them, so a burst is labeled by its own work.

#### Label by first record naming a folder; name earlier edited files relative to it
`ClaudeCodeSessionSummary.transcript`: The session is labeled by the first record naming a folder. Files a
record without one edited are named relative to it, once it is known.

#### Commands run in agent terminal mode are the person's own work
`ClaudeCodeSessionSummary.appendPrompt`: A command the person ran in the agent's terminal mode is theirs,
and still work in this session.

#### Edited paths relative to record folder; without one, named when window read
`ClaudeCodeSessionSummary.appendAssistant`: An edited file is named relative to the record's folder. A record
without one keeps the path as written, named when a window is read.

### `LokalBot/Services/CodingAgents/CodexSessionReader.swift`

#### Select rollouts by modification date; skip subagents; never open credentials or SQLite
`CodexSessionReader`: Reads Codex rollouts from `~/.codex/sessions/YYYY/MM/DD/*.jsonl` and
`~/.codex/archived_sessions/`. Codex compresses rollouts it is done with
to `*.jsonl.zst`, which are read too.

A rollout stays in the folder of the day it started even when it is
resumed weeks later, so files are selected by modification date rather
than by folder. Subagent threads, including approval reviewers, are
skipped: their parent session reports the work. Titles come from
`session_index.jsonl`; credentials and the internal SQLite state are
never opened.

#### Read only newest copy of plain and compressed rollout to avoid double count
`CodexSessionReader.newestCopies`: One file per rollout: a rollout kept both plain and compressed is read
from the copy written last. Reading both would count its work twice.

#### Subagent source is an object; people start with vscode or cli strings
`CodexRolloutSummary.consume`: A subagent's `source` is an object such as
{"subagent":{"other":"guardian"}}; people start "vscode"/"cli".

#### Codex injects instructions as separate items of a user message; judge each
`CodexRolloutSummary`: Codex sends injected instructions and context as separate
items of the same user message; each is judged on its own.

#### Read only the command, never aggregated output
`CodexRolloutSummary`: Only the command; `aggregated_output` and friends are never read.

#### Codex argv array has the script last
`CodexRolloutSummary.command`: A completed command as the shell ran it. Codex records the argv as an
array such as `["/bin/zsh", "-lc", "git push"]`; the script is last.

#### Shell tool arguments use cmd string or command string/argv
`CodexRolloutSummary.shellCommand`: Shell tools pass JSON arguments with `cmd` (string) or `command`
(string or argv).

#### Later session_index lines are renames and win; appended lines fold in
`CodexThreadTitles`: Thread names by id from `session_index.jsonl`; later lines are renames
and win, so appended lines fold into the names already read.

### `LokalBot/Services/CodingAgents/CodingAgentCompressedTranscript.swift`

#### Decompress in pieces, never whole; one rollout can hold gigabytes
`CodingAgentCompressedTranscript`: Codex compresses rollouts it is done with to `<name>.jsonl.zst`, so most
of a long-time user's history is compressed. A compressed transcript is
decompressed a piece at a time, never whole: one rollout can hold
gigabytes of tool output.

#### Compression resets creation date; use filename date minus one day to cover time zones
`CodingAgentCompressedTranscript.startBound`: A time no later than the rollout's first record. Compressing gives the
file a new creation date, the time it was last written, so the start
comes from its name, `rollout-2026-10-19T08-23-26-<id>.jsonl.zst`.
The name is in the local time where Codex ran, so a day before its
date covers every zone.

#### Batches end on line breaks; truncated frame is unreadable
`CodingAgentCompressedTranscript.forEachBatch`: Hands `body` the transcript's lines in batches that end on a line
break; the last batch holds a final line without one. Returns the
decompressed size. A file that ends inside a frame is unreadable.

#### Zstd holds last frame byte until output written, so loop drains output buffer
`CodingAgentCompressedTranscript.forEachBatch`: Zstd keeps the last byte of a frame until the frame's output is
all written, so this loop also drains a full output buffer.

### `LokalBot/Services/CodingAgents/CodingAgentEvidenceIngestor.swift`

#### Only settled bursts stored; removals revoke dependents; read failure is never deletion
`CodingAgentEvidenceIngestor`: Keeps stored coding-agent evidence in step with the agents' transcripts.

Scans run off the main actor over a recent window. Only settled bursts
are stored, so a digest's inputs cannot change while it is written. New
bursts are plain additions. Removing or correcting a stored burst (a
deleted session, a new folder exclusion) revokes dependent products
through the same path as deleting screen evidence. A read failure is
never taken as a deletion.

#### Agent text expires with screen text; nil keeps it forever
`CodingAgentEvidenceIngestor.Configuration.retentionDays`: Agent text expires with screen text; `nil` keeps it indefinitely.

#### New installs read nothing until setup finishes
`CodingAgentEvidenceIngestor.Configuration.init(settings:onboardingFinished:)`: Setup shows this choice, so a new install reads nothing until setup
is finished. From then on the settings alone decide.

#### Window matches digest scheduler catch-up days
`CodingAgentEvidenceIngestor.windowDays`: Matches the digest scheduler's catch-up window.

#### Shared across refreshes so only appended lines are parsed
`CodingAgentEvidenceIngestor.parseCache`: Reused across window refreshes and days, so a refresh parses only
the lines agents appended since the last one.

#### First refresh parses everything so launch waits for meeting library
`CodingAgentEvidenceIngestor.start`: Refresh once `waitUntilReady` returns, then on a fixed interval while
any agent is enabled. The first refresh parses every transcript in the
window, so at launch it waits for the meeting library to load.

#### Refreshes run serially, never concurrently
`CodingAgentEvidenceIngestor.refresh`: Scan the recent window, plus `day` when it is older, and store what
changed. Refreshes run one after another, never concurrently.

#### Older days bypass the cache, which would reparse and drop window files
`CodingAgentEvidenceIngestor.performRefresh`: An older day reaches past what the cache keeps: reading it
there would reparse the window's files and drop the rest.

#### Discard scan results if configuration changed during the scan
`CodingAgentEvidenceIngestor.performRefresh`: Turning the feature off, deleting saved sessions, or adding an
exclusion during the scan must not be undone by its result.

#### Finished days keep bursts unless work changes; branch relabels rebuilt digests repeatedly
`CodingAgentEvidenceIngestor.apply`: A finished day keeps the bursts its digest and Dream review were
written with until a session's work there changes or the session
is gone. On 2026-10-20 and 21, sessions that moved to another
branch relabeled earlier days' bursts, and each relabel rebuilt
those days' digests, several times a day.

#### Unreadable transcript is not treated as deleted
`CodingAgentEvidenceIngestor.apply`: An unreadable transcript is not a deleted one.

#### Ids follow first event so moved edges look new while work is equal
`CodingAgentEvidenceIngestor.sessionDaysWithUnchangedWork`: Sessions on days before `today` whose stored bursts hold the same
work, in order, as the scan's. Ids follow a burst's first event, so
a moved edge reads as a different burst; the work does not.

### `LokalBot/Services/CodingAgents/CodingAgentParseCache.swift`

#### File summaries hold no window so new days reuse them and parse only appended lines
`CodingAgentFileSummary`: What a reader keeps of one transcript file between scans: enough to build
its transcript for any window that starts at or after the time it was
kept from. Summaries hold no window of their own, so a new day or a
refresh reuses them and parses only the lines agents appended since.

#### Trim drops records before start since no later scan reads them
`CodingAgentFileSummary.trim`: Drops timed records before `start`, which no later scan reads.

#### Folder, branch and record id live on the source record so events share them
`CodingAgentStoredEvent`: An event as a file summary keeps it. Folder, branch, and record id live
on the record it came from, so a busy record's events share them.

#### Record is the source record's index in its summary, -1 for none
`CodingAgentStoredEvent.record`: The source record's index in its summary, or `-1` for none.

#### Transcripts are append-only; shrunk, replaced or altered-prefix files are reparsed from start
`CodingAgentFileState`: A transcript file's summary and how far it was read. Both agents only
append to their transcripts; a file that shrank, was replaced, or whose
bytes before the resume point changed is parsed again from the start.

#### Offset covers complete lines only; a partial line is reread once its newline arrives
`CodingAgentFileState.offset`: Bytes folded into `summary`: every complete line. A line still being
written is read again once its newline arrives.

#### Boundary is a hash of the bytes just before offset
`CodingAgentFileState.boundary`: Hash of the bytes just before `offset`.

#### Records before this time were not kept; scans reaching further back reparse
`CodingAgentFileState.retainedFrom`: Records from before this time were not kept, so a scan reaching
further back parses the file again.

#### Activity is compacted by local day, so a time zone change reparses
`CodingAgentFileState.timeZone`: Activity is compacted by local day, so a time zone change reparses.

#### Per-file parse state is clipped per scan so moving windows reuse files and refreshes parse appended bytes
`CodingAgentParseCache`: Per-file parse state from earlier scans, keyed by path. Each scan clips a
file's summary to its own window, so a window that moves to a new day
reuses every file, and a refresh parses only the bytes appended since.

#### Reuse cached summary while unchanged, else extend by appended lines; bytesRead nil if unopened
`CodingAgentParseCache.summary`: `file`'s summary for a scan whose window starts at `start`: the cached
one while the file is unchanged, extended by the lines appended since
otherwise. Without a cache the whole file is parsed. `bytesRead` is
`nil` when the file was not opened.

#### A last line without newline is read for this scan only, not cached
`CodingAgentParseCache.summary`: The last line has no newline yet: read it for this scan only.

#### Compressed transcripts are finished, read whole once, reused while size and mtime match
`CodingAgentParseCache.compressedSummary`: A compressed transcript is one Codex has finished with, so nothing is
appended to it: it is read whole when it is new or changed, and its
summary is reused while its size and modification date stay the same.
Its state's `size` and `offset` are both the compressed size.

### `LokalBot/Services/CodingAgents/CodingAgentSession.swift`

#### Read only an explicit allowlist of transcript paths, never agent credentials
`CodingAgentKind`: A coding agent whose local session transcripts LokalBot can read as
work evidence. Transcripts are the agent's own files; LokalBot reads an
explicit allowlist of transcript paths and never the agent's credentials.

#### Actions parsed from commands are recorded facts, unlike the agent's own claims
`CodingAgentAction`: An outcome parsed from a command the agent ran. These are recorded
actions, unlike the agent's own report, which is only a claim.

#### Nil number means the command merged the current branch's PR
`CodingAgentAction.mergedPullRequest`: `nil` when the command merged the current branch's PR.

#### Tool output, file contents, reasoning and injected text never become events
`CodingAgentEvent`: One timestamped fact from a transcript. Tool output, file contents,
reasoning, and injected system or developer text never become events.

#### Re-emitted PR links annotate work but never start, extend or sustain a burst
`CodingAgentEvent.Kind.pullRequest`: A PR the agent associated with the session. Claude Code re-emits
these links every turn, so they annotate work but never start,
extend, or keep alive a burst on their own.

#### Activity is timestamp-only evidence; tool result content is deliberately not read
`CodingAgentEvent.Kind.activity`: Timestamp-only evidence that the agent was working, such as a
tool result whose content is deliberately not read.

#### Hashed record id drops fork or resume copies; hashes are per process, never persisted
`CodingAgentEvent.recordKey`: The source record's hashed id, for dropping copies a fork or resumed
session carries. Hashes are per process and never persisted.

#### Bursts are labeled from their own records so settled work is never relabeled
`CodingAgentEvent.workingDirectory`: The folder and branch the source record names, for readers whose
records carry them. A burst is labeled from its own records, so a
session that moves on never relabels work that already settled.

#### Parsed session events are already clipped to the requested day
`CodingAgentTranscript`: One parsed session, with events already clipped to the requested day.

#### Session-wide labels apply only to bursts whose events carry none
`CodingAgentTranscript.workingDirectory`: Session-wide labels, for bursts whose events carry none.

#### Replies are withheld when the session read LokalBot's library to avoid self-consumption
`CodingAgentTranscript.consultedLokalBot`: The session read LokalBot's own library through its CLI or MCP.
Its replies may restate library content, so they are withheld to
keep the digest from consuming its own output.

#### Bursts split at the day digest's idle gap so all-day sessions don't merge
`CodingAgentBurst`: A contiguous run of agent work inside one session. A new burst starts
after the same idle gap the day digest uses to split segments, so a
session left open all day never merges the whole day into one item.

#### Burst id is stable within a day, keyed by session and first event
`CodingAgentBurst.id`: Stable within a day: bursts are keyed by session and first event.

#### Only settled bursts become evidence so saved digest inputs cannot change
`CodingAgentBurst.isSettled`: A burst idle for the full inactivity gap can never grow again: any
later event starts a new burst. Only settled bursts become evidence,
so a saved digest's inputs cannot change underneath it.

#### Scheduled runs often report on earlier days, so their requests aren't the person's
`CodingAgentBurst.isScheduledRun`: Every request came from a schedule, not from the person at the time.
Such runs often report on earlier days.

#### Recorded outcome means any action or linked pull request
`CodingAgentBurst.recordedOutcome`: The burst committed, opened or merged a pull request, released,
pushed, ran tests, or linked a pull request.

#### Same work ignores presentation changes like renames, folders, relative paths and midnight edges
`CodingAgentBurst.hasSameWork`: The same requests, reply, actions, pull requests, and tool calls in
the same session. A settled burst's work never changes, but how it is
presented can: a session is renamed, and bursts saved by earlier
readers carry the session's folder and branch, file names relative to
another folder, and edges moved by activity on the other side of
midnight.

#### Fixed-order fields make evidence signatures change exactly when burst content does
`CodingAgentBurst.signatureFields`: Every field the digest can read, in a fixed order, for evidence
signatures that change exactly when the burst's content does.

#### Evidence puts substantive content first and labeled trace metadata last
`CodingAgentBurst.evidenceText`: Model-facing evidence in the same shape as the digest's other work
sources: substantive content first, trace metadata last and labeled.

#### Request or placeholder titles are omitted since requests already say what was asked
`CodingAgentBurst.evidenceText`: A request or placeholder title names no work; the requests below
already say what was asked.

#### Only transcript titles name work; untitled sessions get a request or placeholder
`CodingAgentBurst.titleNamesWork`: The title came from the transcript and names the work. A session the
transcript leaves untitled is labeled with its first request or a
placeholder, which name a conversation instead.

#### Work title order: own title, opened PR, commit, short instruction request
`CodingAgentBurst.workTitle`: A short work title for a task list: the session's own title when it
names the work, otherwise the deliverable its recorded actions name
(an opened pull request, then a commit), then its request when that is
a short instruction. "can you add a demo to the PR?" and "Untitled
session" never become a task.

#### Scratch or checkout-holding folders take project from pull requests, including sibling checkouts
`CodingAgentBurst.workProject`: The repository the work belongs to. A session started in a folder that
names no project, such as a scratch folder or the folder holding every
checkout, takes it from its pull requests, as does a sibling checkout
such as `LokalBot-port`. `nil` when nothing names one.

#### Inactivity gap must match DayDigestEvidence.summarySegments
`CodingAgentBurstBuilder.inactivityGap`: Matches `DayDigestEvidence.summarySegments(inactivityGap:)`.

#### Gaps longer than the cap count as waiting, not active work
`CodingAgentBurstBuilder.activeGapCap`: Longer gaps between events count as waiting, not active work.

#### Annotations join the burst active when written; idle re-emitted links are dropped
`CodingAgentBurstBuilder.bursts`: Annotations join the burst that was active when they were written;
a link re-emitted while nothing else happened is dropped.

#### Label bursts from their own events so branch changes don't relabel them as the window slides
`CodingAgentBurstBuilder.burst`: A scan reads a window of days, and a long session changes branch
and folder within it. Labels from the session as a whole would
relabel this burst on every such change and as the window slides.

#### Merge a session's bursts into one view for summaries that see the session once
`CodingAgentBurstBuilder.merging`: One session's bursts as a single view, for a summary that should see
the session once rather than once per burst. `nil` for no bursts.

#### Drop redundant activity pings but keep those spanning midnight so saved burst edges stay stable
`CodingAgentBurstBuilder.compactingActivity`: Drops timestamp-only events that change neither a burst boundary nor
its active time. A ping is redundant when the events either side of it
are within `activeGapCap` of each other: the gaps it splits count in
full either way. Busy sessions log thousands of tool results, so this
keeps cached transcripts small without changing any burst.

Bursts are cut at midnight, so a ping is kept when its neighbors fall
on different days: otherwise the next day's first event, or the
scan window's start, would move the edge of a burst already saved.
So compacting a whole file and then clipping it to whole days of
`calendar` keeps the same events as clipping first, and compacting
again after later events are appended keeps the same as compacting
once at the end.

#### Project is the repository name, since agent worktrees live under repo/.claude/worktrees
`CodingAgentBurstBuilder.projectName`: The repository name, not the checkout folder: agent worktrees live
under `<repo>/.claude/worktrees/<name>`.

#### Scratch folders, checkout holders and home folder name no project
`CodingAgentBurstBuilder.namesNoProject`: A folder that holds work without naming it: no folder at all, a Claude
scratch folder such as `scratch-2026-10-19-6f7eb7`, or a folder that
holds checkouts, such as `~/Documents/GitHub` or the home folder.

### `LokalBot/Services/CodingAgents/CodingAgentSessionScanner.swift`

#### Project-folder exclusions apply before anything leaves the reader
`CodingAgentSessionScanner`: Collects bursts from every enabled agent for a day and applies the
person's project-folder exclusions before anything leaves the reader.

#### Sessions inside excluded folders are dropped so those repositories never enter the library
`CodingAgentSessionScanner.excludedFolders`: Sessions whose working directory is inside one of these folders are
dropped, for repositories whose work must never enter the library.

#### Each transcript is read once; bursts never cross midnight so belong to one day
`CodingAgentSessionScanner.scan`: Every local day from `firstDay` through `lastDay`, reading each
transcript once. Bursts never cross midnight, so each belongs to
exactly one day's evidence.

### `LokalBot/Services/CodingAgents/CodingAgentText.swift`

#### All reader strings are stripped of injected context, redacted and length-capped
`CodingAgentText`: Text rules shared by the coding-agent transcript readers. Every string
that leaves a reader passes through here: injected context is removed,
credentials are redacted, and length is capped before anything is kept.

#### Codex puts IDE, browser and file context above the request marker
`CodingAgentText.prompt`: Codex puts IDE, browser, and file context above the request.

#### Terminal-mode input is the person's own; its captured output is never kept
`CodingAgentText.prompt`: The person's own shell input; its captured output is never kept.

#### An unclosed harness tag still marks harness text and is rejected
`CodingAgentText.prompt`: An unclosed harness tag is still harness text.

#### Text addressed to an agent, not a work name: questions, truncation, links, conversational openers
`CodingAgentText.readsAsRequest`: Text said to an agent rather than a name for work: a question, a
truncated or harness-tagged request, a link, or a conversational
opening such as "can you" or "we should".

#### Only short imperative requests become titles; questions, long, terminal or pasted text yield nil
`CodingAgentText.instruction`: A request that is a short instruction, as a work title: "Review all
open PRs" as is, "let's commit the benchmark." as "Commit the
benchmark". `nil` for anything else, such as a question, a long or
truncated request, a terminal command, or pasted text.

#### Keep original case for words like iOS when capitalizing
`CodingAgentText.instruction`: "iOS …" keeps its case.

#### Command output is never read, so an action means ran, not succeeded
`CodingAgentText.actions`: Outcomes recorded by a shell command. Command output is never read,
so an action means the agent ran it, not that it succeeded.

#### Detects the agent reading LokalBot's library, whose content replies may echo
`CodingAgentText.readsLokalBot`: The agent read LokalBot's library, whose content its replies may echo.

#### Codex stores commands as JSON argv; the script is the last element
`CodingAgentText.unwrappedShellCommand`: Codex records commands as a JSON-encoded argv such as
`["/bin/zsh","-lc","git push"]`; the script is the last element.

#### Paths are project-relative and never expose scratch or worktree plumbing
`CodingAgentText.displayPath`: A changed file as the person would name it: relative to the session's
project, never exposing scratch or worktree plumbing.

#### Worktrees sit inside the project folder so strip them first
`CodingAgentText.displayPath`: Worktrees sit inside the project folder, so strip them first.

#### Whole harness-written messages in the person's turn are ignored
`CodingAgentText.ignoredPromptPrefixes`: Whole messages the harness writes in the person's turn.

#### Harness tags are hyphenated or underscored, unlike HTML a person might paste
`CodingAgentText.ignoredBlocks`: Harness context wrapped around or beside a request: system reminders,
IDE and browser state, skill bodies, captured terminal output. These
tags are hyphenated or underscored (`system-reminder`, `bash-stdout`,
`ide_selection`), unlike HTML a person might paste into a prompt.

#### Scheduled runs are requested work but not in the harness-injected words
`CodingAgentText.scheduledRun`: Runs the person scheduled earlier: they asked for the work, but not
in the words the harness injects for each run.

#### Classify lines from opening bytes; tool output dominates (15 MB session had ~12 prompts)
`CodingAgentJSONLines`: Streams a JSON Lines transcript without loading it into Swift strings.
Tool output dominates these files (one 15 MB session held about a dozen
prompts), so readers classify a line from its opening bytes and fully
decode only lines that can carry evidence.

#### Escaped quotes in nested JSON can't match, so ids read safely without decoding
`CodingAgentJSONLines.Line.stringValue`: The first unescaped string value for `"key":"`. Escaped quotes in
nested JSON text cannot match, so this safely reads identifiers
and timestamps without decoding a multi-megabyte line.

#### Fast path for UTC stamps both agents write; Foundation fallback for other ISO forms
`CodingAgentTimestamp.date`: Parses the UTC `yyyy-MM-ddTHH:mm:ss(.SSS…)Z` stamps both agents
write, falling back to Foundation for any other ISO 8601 form.

#### Days from civil date use Howard Hinnant's algorithm
`CodingAgentTimestamp.date`: Days from the civil calendar (Howard Hinnant's algorithm).

### `LokalBotTests/Services/CodingAgents/CodingAgentDigestModelTests.swift`

#### Fixture builds one busy segment with more events than detail slots
`testACrowdedSegmentKeepsRoomForSessionsThatRecordedOutcomes`: One busy stretch with forty screen activities and seven parallel
sessions, followed by seven short, separate stretches, so the busy
one stays a single segment with more events than detail slots.

#### Seven separate later stretches keep the session within one segment
`testASessionsBurstsInOneSegmentAppearOnceWithAllTheirActions`: Seven separate later stretches keep the session to one segment; a
quiet day would otherwise be spread across several.

#### Plain loops and typed locals avoid slow type-checking on CI's compiler
`testScreenTextFromAgentAppsYieldsToTheSessionItShows`: Plain loops and typed locals: inline arithmetic inside a mapped
initializer is too slow to type-check on CI's compiler.

#### 2026-10-19 journal named tasks by request or folder and listed duplicate PR reviews
`testSessionTasksAreNamedByTheirWorkAndProjectNotTheRequestOrFolder`: The 2026-10-19 journal named tasks "can you add short video demo
recording of the new app platforms in the PR? (GitHub)", "Untitled
session (GitHub)", and "… (scratch-2026-10-19-6f7eb7)", and listed two
PR review sessions beside the model's own review task.

#### Bursts mimic transcript readers: untitled session labeled by first request or placeholder
`CodingAgentDigestModelTests.session`: Bursts read the way the transcript readers produce them, so an
untitled session is labeled with its first request or the placeholder.

### `LokalBotTests/Services/CodingAgents/CodingAgentEvidenceTests.swift`

#### Re-reading same work later must not reopen a finished day's digest and Dream review
`testSameWorkReadAgainLeavesAFinishedDayAloneButChangedWorkReopensIt`: Bursts saved by earlier readers carry their session's latest branch
and folder, file names relative to another folder, and edges moved by
activity across midnight. Reading them again on a later day must not
reopen that day's digest and Dream review; changed work still does.

#### 2026-10-20/21 relabeled bursts rebuilt digests and discarded Dream reviews repeatedly
`testASessionMovingOnLeavesAnEarlierDaysEvidenceAndDigestCurrent`: 2026-10-20 and 21: Claude Code sessions that moved to another branch
or folder relabeled their earlier bursts on each refresh. Every
relabel revised those days, which rebuilt their digests and discarded
their Dream reviews several times a day.

#### First scan parses every transcript, so it waits for the meeting library at launch
`testTheFirstScanWaitsUntilTheLibraryIsReady`: The first scan parses every transcript in the window, so at launch it
waits for the meeting library instead of competing with its load.

#### Person deleting saved sessions during a scan must not store results
`CodingAgentEvidenceIngestor scan test`: The person deletes saved sessions while this scan runs.

#### Own defaults suite keeps the setup flag from touching the host's
`CodingAgentEvidenceTests.isolatedDefaults`: A defaults suite of its own, so the setup flag never touches the host's.

### `LokalBotTests/Services/CodingAgents/CodingAgentSessionTests.swift`

#### A fork arriving after caching must still credit copied history to the original
`testCacheReparsesOnlyChangedFilesAndStillDropsANewForksCopies`: The fork arrives after the original was cached; its copied
history must still be credited to the original.

#### 2026-10-31 every refresh re-parsed whole transcripts and every new day the whole window
`testARefreshParsesOnlyAppendedBytesAndMatchesAFullRead`: 2026-10-31: every refresh re-parsed each transcript still being written
in full, and every new day re-parsed the whole window.

#### A saved burst must not change when the session continues past midnight
`testCompactingKeepsADaysLastEventWhateverFollowsMidnight`: A saved burst must not change when the session goes on past midnight.

#### Folder and branch labels come from own records, not the scan window (2026-10-20/21)
`testClaudeBurstsAreLabeledByTheirOwnRecordsWhateverTheScanWindow`: 2026-10-20 and 21: a session's folder and branch were read across the
whole scan window, so a session that moved on relabeled the work it
had saved on earlier days, and each relabel rebuilt those days' digests.

#### Compressing gives a rollout the creation date of its last write
`testCodexReaderReadsCompressedRolloutsLikePlainOnes`: Compressing gives the file the creation date of its last write.

#### Test lines exceed the decoder's 4 MiB output buffer and span many frames
`testDecompressionHandsOverWholeLinesAcrossFramesAndBuffers`: Lines longer than the decoder's 4 MiB output buffer, split over many frames.

#### UI-test runner moved to Scripts/test/; older sessions still name the old path
`testActionsAreParsedFromTheCommandsTheAgentRan`: The UI-test runner moved to Scripts/test/; older sessions still name the old path.

#### Claude user records keep Claude Code's key order, which the tool-result fast path needs
`CodingAgentSessionTests.claudeUser`: A user record in Claude Code's key order, which the tool-result
fast path depends on.

#### Test zstd frames use raw blocks; real compression is libzstd's, tested upstream
`CodingAgentSessionTests.writeCompressed`: Writes `text` as zstd frames of uncompressed blocks, which is what
zstd writes for bytes it cannot shrink. Decoding real compression is
libzstd's own, tested upstream; these frames test the reader around it.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
