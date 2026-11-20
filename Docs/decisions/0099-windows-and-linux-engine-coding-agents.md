# 0099. Windows and Linux: engine — coding_agents

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/builder.rs`

#### Tool output, file contents, reasoning and injected text never become events
`EventKind`: One timestamped fact from a transcript. Tool output, file contents, reasoning
and injected system or developer text never become events.

#### PR links repeat each turn, so they annotate but never extend a burst
`EventKind::PullRequest`: A pull request the agent associated with the session. Claude Code emits
these links again every turn, so they annotate work but never start,
extend or keep alive a burst on their own.

#### Activity is timestamp-only evidence; tool result content is deliberately not read
`EventKind::Activity`: Timestamp-only evidence that the agent was working, such as a tool
result whose content is deliberately not read.

#### Hashed record id drops fork/resume copies; hashes are per process, never persisted
`Event.record_key`: The source record's hashed id, for dropping copies a fork or resumed
session carries. Hashes are per process and never persisted.

#### Bursts are labeled from their own records so settled work is never relabeled
`Event.working_directory`: The folder and branch the source record names, for readers whose records
carry them. A burst is labeled from its own records, so a session that
moves on never relabels work that already settled.

#### Transcript events are already clipped to the requested days
`Transcript`: One parsed session, with events already clipped to the requested days.

#### Session-wide labels are only a fallback for bursts whose events carry none
`Transcript.working_directory`: Session-wide labels, for bursts whose events carry none.

#### Replies withheld when the session read LokalBot's library, to avoid digest self-consumption
`Transcript.consulted_lokalbot`: The session read LokalBot's own library through its CLI or MCP. Its
replies may restate library content, so they are withheld to keep the
digest from consuming its own output.

#### Annotations join the burst active when written; repeats during idle are dropped
`bursts`: Annotations join the burst that was active when they were written; a link
written again while nothing else happened is dropped.

#### Use fold not sum: an empty float sum is -0.0 and would reach the payload
`burst`: Not `sum`: an empty float sum is -0.0, which would reach the payload.

#### Label bursts from their own events, not the session, so labels stay stable as window slides
`burst`: A scan reads a window of days, and a long session changes branch and
folder within it. Labels from the session as a whole would relabel this
burst on every such change and as the window slides.

#### Drop redundant ping events without changing bursts; keep pings across midnight
`compacting_activity`: Drops timestamp-only events that change neither a burst boundary nor its
active time. A ping is redundant when the events either side of it are
within the active-gap cap of each other: the gaps it splits count in full
either way. Busy sessions log thousands of tool results, so this keeps cached
transcripts small without changing any burst.

Bursts are cut at midnight, so a ping is kept when its neighbours fall on
different days: otherwise the next day's first event, or the scan window's
start, would move the edge of a burst already saved.

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/cache.rs`

#### Summaries hold no window, so new days or refreshes reuse them and parse only appended lines
What readers keep between scans (`CodingAgentParseCache.swift`). A summary
holds no window of its own, so a new day or a refresh reuses it and parses
only the lines agents appended since.

#### consume folds in one complete line and keeps timed records from start on
`FileSummary.consume`: Folds in one complete line, keeping timed records from `start` on.

#### trim drops timed records before start, which no later scan reads
`FileSummary.trim`: Drops timed records before `start`, which no later scan reads.

#### Folder, branch and record id live on the record, shared by its events
`StoredEvent`: An event as a summary keeps it. Folder, branch and record id live on the
record it came from, so a busy record's events share them.

#### Record is an index into its summary, -1 for none
`StoredEvent.record`: The source record's index in its summary, or `-1` for none.

#### Codex compresses finished rollouts to .jsonl.zst
`is_compressed`: Codex compresses rollouts it is done with to `<name>.jsonl.zst`.

#### Compressed file start comes from its name, one day earlier to cover every time zone
`start_bound`: A time no later than a compressed rollout's first record. Compressing gives
the file a new creation time, the time it was last written, so the start
comes from its name, `rollout-2026-10-19T08-23-26-<id>.jsonl.zst`. The name
is in the local time where Codex ran, so a day before its date covers every
zone.

#### Select files by metadata window so multi-gigabyte archives are skipped; zst opt-in
`candidate_files`: Transcript files that may hold activity inside the window: written since it
began, and created before it ended. Skipping by metadata keeps
multi-gigabyte archives out of every scan. `compressed_rollouts` also takes
Codex's compressed rollouts, `*.jsonl.zst`.

#### Use symlink_metadata so only regular files count, not links
`candidate_files`: `metadata` follows links; only a regular file itself counts.

#### Compressed files get a creation time after their session began, so use name-derived start
`candidate_files`: A compressed file was created when it was compressed, after its
session began.

#### Agents only append; shrunk, replaced or changed-prefix files are reparsed from the start
`FileState`: Both agents only append to their transcripts; a file that shrank, was
replaced, or whose bytes before the resume point changed is parsed again from
the start.

#### Offset covers complete lines only; an in-progress line is reread once newline arrives
`FileState.offset`: Bytes folded into `summary`: every complete line. A line still being
written is read again once its newline arrives.

#### Reaching further back than retained_from forces a reparse
`FileState.retained_from`: Records from before this time were not kept, so a scan reaching further
back parses the file again.

#### Activity compacts by local day, so a time zone change reparses
`FileState.utc_offset`: Activity is compacted by local day, so a time zone change reparses.

#### Reuse cached summary while unchanged, extend by appended lines; count None if unopened
`summary_of`: `file`'s summary for a scan whose window starts at `start`: the cached one
while the file is unchanged, extended by the lines appended since otherwise.
Without a cache the whole file is parsed. The count is `None` when the file
was not opened.

#### A last line without newline is read for this scan only
`summary_of`: The last line has no newline yet: read it for this scan only.

#### Compressed transcripts are never appended to; read whole, reuse while size and mtime match
`compressed_summary_of`: A compressed transcript is one Codex has finished with, so nothing is
appended to it: it is read whole when it is new or changed, and its summary
is reused while its size and modification time stay the same. Its state's
`size` and `offset` are both the compressed size.

#### Decoder reads frame after frame and fails on a file ending inside one
`compressed_summary_of`: The decoder reads frame after frame, and fails on a file that ends
inside one.

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/claude.rs`

#### Claude reader keeps only prompts, replies, edit/shell tool inputs, titles and PR links; tool results timestamp-only
Reads Claude Code sessions from `~/.claude/projects/<cwd-slug>/<id>.jsonl`
(`ClaudeCodeSessionReader.swift`).

Only user prompts, the agent's text replies, tool names and inputs for file
edits and shell commands, titles and pull request links are read. Tool
results are recognised from their opening bytes and contribute only a
timestamp. Subagent sidechains, meta records and compaction summaries are
skipped.

#### Only top-level project files are read; subagent transcripts are not the person's sessions
`ClaudeReader::transcripts`: Top level of each project folder only: subagent transcripts live in
per-session subfolders and are not the person's sessions.

#### Read older files first so forked or resumed history is credited where it happened
`ClaudeReader::transcripts`: A fork or resumed session copies earlier records under their original
ids. Reading older files first credits that history to the session
where it happened.

#### De-duplication depends on the whole scan, so it happens outside the cached summary
`ClaudeReader::transcripts`: De-duplication against other files depends on the whole scan, so
it happens here rather than in the cached summary.

#### A file whose window holds only copies claims nothing
`ClaudeReader::transcripts`: A file whose window holds only copies claims nothing.

#### Label is an index into labels, -1 when a record names neither
`Record.label`: Index into `labels`, or `-1` for a record naming neither.

#### Records naming the same folder/branch pair share one copy
`Label`: A folder and branch records ran in. Records naming the same pair share one
copy, so a long session holds each path once.

#### Summary keeps record times, ids, labels, compacted events and titles between scans
`ClaudeSummary`: What the reader keeps of one session file between scans: each timed record's
time, id and labels, the events those records hold with redundant activity
compacted away, and the file's titles.

#### Checked across the whole file because earlier library text can be restated today
`ClaudeSummary.consulted_lokalbot`: Checked across the whole file, not just the window: text read from the
library earlier can still be restated in today's replies.

#### Tool results carry most bytes, so read only their time
`ClaudeSummary::consume`: Tool results carry most of the bytes; read only their time.

#### Each record's folder and branch stay on its events so bursts are labeled by own work
`ClaudeSummary::consume`: Each record names the folder and branch it ran in; its events
keep them, so a burst is labeled by its own work.

#### A record already held is a copy and counts where it first appears
`ClaudeSummary::admit`: A record the file already holds is a copy, with the same time; it counts
where it first appears. `None` for a copy.

#### A command run in the agent's terminal mode is the person's own work
`ClaudeSummary::append_prompt`: A command the person ran in the agent's terminal mode is theirs, and
still work in this session.

#### Edited files named relative to record's folder; without one, path kept and named at window read
`ClaudeSummary::append_assistant`: An edited file is named relative to the record's folder. A record without
one keeps the path as written, named when a window is read.

#### Returns window transcript and record ids, or None when the window holds no work
`ClaudeSummary::transcript`: The session's transcript inside the window and the ids of the records it
holds there, or `None` when the window holds no work.

#### Session labeled by first record naming a folder; earlier files named relative to it once known
`ClaudeSummary::transcript`: The session is labeled by the first record naming a folder. Files a
record without one edited are named relative to it, once it is known.

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/codex.rs`

#### Codex rollouts selected by mtime, subagents skipped, credentials and SQLite never opened
Reads Codex rollouts from `~/.codex/sessions/YYYY/MM/DD/*.jsonl` and
`~/.codex/archived_sessions/` (`CodexSessionReader.swift`). Codex compresses
rollouts it is done with to `*.jsonl.zst`, which are read too.

A rollout stays in the folder of the day it started even when it is resumed
weeks later, so files are selected by modification date rather than by
folder. Subagent threads, including approval reviewers, are skipped: their
parent session reports the work. Titles come from `session_index.jsonl`;
credentials and the internal SQLite state are never opened.

#### Walk never enters hidden folders
`walk`: Every file under `directory`, without entering hidden folders.

#### Read one copy per rollout, the newest, to avoid counting work twice
`newest_copies`: One file per rollout: a rollout kept both plain and compressed is read from
the copy written last. Reading both would count its work twice.

#### Later lines in the index are renames and win
`thread_titles`: Thread names by id; later lines are renames and win.

#### Record types matched by opening bytes carry no evidence beyond their time
`TIMESTAMP_ONLY_MARKERS`: Opening bytes of records that never carry evidence beyond their time.

#### Summary keeps session id, labels and compacted events between scans
`CodexSummary`: What the reader keeps of one rollout between scans: the session's id and
labels, and its events with redundant activity compacted away.

#### Subagent sources are objects; people start vscode or cli
`CodexSummary::consume`: A subagent's `source` is an object such as
{"subagent":{"other":"guardian"}}; people start "vscode" or "cli".

#### Injected instructions arrive as separate items of one user message; judge each alone
`CodexSummary::append_response_item`: Codex sends injected instructions and context as separate
items of the same user message; each is judged on its own.

#### Only the command is read; aggregated output is never read
`CodexSummary::append_completed_item`: Only the command; `aggregated_output` and friends are never read.

#### Only the keys of changes are used, never the diffs
`CodexSummary::append_completed_item`: `changes` maps each path to its diff; only the keys are used.

#### None for a subagent thread or a window holding no work
`CodexSummary::transcript`: The session's transcript inside the window, or `None` for a subagent
thread or a window holding no work.

#### Codex records argv as an array; the script is last
`command_in_item`: A completed command as the shell ran it. Codex records the argv as an array
such as `["/bin/zsh", "-lc", "git push"]`; the script is last.

#### apply_patch names each file on a header line
`patched_files`: `apply_patch` names each file on a header line.

#### Shell tool JSON arguments use cmd string or command as string or argv
`shell_command_in_arguments`: Shell tools pass JSON arguments with `cmd` (string) or `command` (string or
argv).

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs`

#### Only settled bursts stored; read failures never deletions; nothing opened until person allows
Keeps stored coding-agent evidence in step with the agents' transcripts
(`CodingAgentEvidenceIngestor.swift`).

Scans run on a background thread over a recent window. Only settled bursts
are stored, so a digest's inputs cannot change while it is written. New
bursts are plain additions. Removing or correcting a stored burst (a deleted
session, a new folder exclusion) withdraws dependent products through the
same path as deleting screen evidence. A read failure is never taken as a
deletion.

Nothing under `~/.claude` or `~/.codex` is opened until the person has chosen
to allow it: [`Settings::enabled_coding_agents`] is empty before that.

#### Window matches the digest scheduler's catch-up days
`WINDOW_DAYS`: Matches the digest scheduler's catch-up window (`DayDigestScheduler.catchUpDays`).

#### First refresh parses every transcript, so it waits for app startup
`FIRST_REFRESH_DELAY`: The first refresh parses every transcript in the window, so it waits for the
app to finish starting.

#### Agent text expires with screen text; None keeps indefinitely
`Configuration.retention_days`: Agent text expires with screen text; `None` keeps it indefinitely.

#### Ids follow a burst's first event, so a moved edge looks different though work is same
`session_days_with_unchanged_work`: Sessions on days before `today` whose stored bursts hold the same work, in
order, as the scan's. Ids follow a burst's first event, so a moved edge reads
as a different burst; the work does not.

#### Replaces stored bursts for scanned agents and days; returns changed days
`apply_scan`: Stores settled bursts from `scan`, replacing what the store holds for the
scanned agents and days. Returns the days that changed.

#### Finished days keep stored bursts unless work changes, to avoid relabel-driven digest rebuilds
`apply_scan`: A finished day keeps the bursts its digest and overnight review were
written with until a session's work there changes or the session is gone.
Sessions that moved to another branch would otherwise relabel earlier
days' bursts, and each relabel would rebuild those days' digests.

#### An unreadable transcript is not a deleted one
`apply_scan`: An unreadable transcript is not a deleted one.

#### One scan at a time; each reuses the last scan's parsed lines
`Ingestor`: The refresh state: one scan runs at a time, and each reuses what the last
one parsed, so a refresh parses only the lines agents appended since.

#### Scans recent window plus older day; does nothing until reading is allowed
`Ingestor::refresh`: Scans the recent window, plus `day` when it is older, and stores what
changed. Does nothing until the person has allowed reading.

#### The empty-agents check is the consent gate before any file opens
`Ingestor::refresh_from`: Before anything opens a file: this is the consent gate.

#### Older days scan uncached, since cached read would reparse the window and drop the rest
`Ingestor::refresh_from`: An older day reaches past what the cache keeps: reading it there
would reparse the window's files and drop the rest.

#### Setting changes during a scan must not be undone by its result
`Ingestor::refresh_from`: Turning the feature off, deleting saved sessions or adding an
exclusion during the scan must not be undone by its result.

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/scanner.rs`

#### Project-folder exclusions are applied before anything leaves the reader
Collects bursts from every enabled agent and applies the person's
project-folder exclusions before anything leaves the reader
(`CodingAgentSessionScanner.swift`).

#### Unreadable files are reported, never fatal, so format changes don't stop the digest
`ReadResult`: What one reader found. Unreadable files are reported, never fatal: an agent
update that changes its format must not stop the digest.

#### Sessions inside excluded folders are dropped so their work never enters the library
`Scanner.excluded_folders`: Sessions whose working directory is inside one of these folders are
dropped, for repositories whose work must never enter the library.

#### Each transcript read once; bursts never cross midnight so belong to one day
`Scanner::scan`: Every local day from `first` through `last`, reading each transcript
once. Bursts never cross midnight, so each belongs to exactly one day.

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/tests.rs`

#### Noon local time keeps the day inside a scan's window
`noon`: Noon local time `days` days ago, so a scan's window always holds it.

#### Transcript stamps need no finer than whole seconds
`whole_second_now`: Transcript stamps have no finer detail than this needs.

#### A fork copies inherited records under their own ids
`subagent_folders_copied_records_and_consulted_replies_stay_out`: A forked session copies the records it inherited under their own ids.

#### A guardian thread reports through its parent session
`codex_rollouts_read_only_what_they_should`: A guardian thread reports through its parent.

#### Codex credentials and database are never parsed whatever they hold
`codex_rollouts_read_only_what_they_should`: Codex's credentials and database are never parsed, whatever they hold.

#### Default flag is true on existing installs without ever having been asked
`nothing_is_read_until_the_person_has_chosen`: Saved as true on every existing install, without ever having been asked.

#### A library moved from a Mac starts unconfirmed too
`nothing_is_read_until_the_person_has_chosen`: A library moved from a Mac starts the same way.

#### Agent files are read, never written
`nothing_is_read_until_the_person_has_chosen`: The agent's files are read, never written.

#### A single-event burst has zero active time, serialized as 0.0 like the Mac
`bursts_split_on_inactivity_and_never_cross_midnight`: A burst of one event has no active time, and says so as the Mac does.

#### UI-test runner moved to Scripts/test/; older sessions still name the old path
`text_rules_match_the_mac`: The UI-test runner moved to Scripts/test/; older sessions still name the old path.

#### Codex names rollouts rollout-\<local start>-\<id>.jsonl
`rollout_name`: `rollout-<local start>-<id>.jsonl`, as Codex names a rollout.

#### Files were just created, so the window must run past now
`compressed_codex_rollouts_are_read_like_plain_ones`: Both files were created just now, so the window runs past now.

#### Compression gives a creation time after the session began
`a_compressed_rollout_counts_on_the_day_it_began`: Compressing gives the file a creation time after its session began:
here, now, two days after the work it holds.

### `LinuxWindows/crates/lokalbot-engine/src/coding_agents/text.rs`

#### Every reader string is stripped of injected context, redacted and capped
Text rules shared by the transcript readers (`CodingAgentText.swift`).
Every string that leaves a reader passes through here: injected context is
removed, credentials are redacted, and length is capped before anything is
kept.

#### Whole messages the harness writes in the person's turn are ignored
`IGNORED_PROMPT_PREFIXES`: Whole messages the harness writes in the person's turn.

#### Harness tags are hyphenated or underscored, unlike pasted HTML
`BLOCK_OPENING`: Harness context wrapped around or beside a request: system reminders, IDE
and browser state, skill bodies, captured terminal output. These tags are
hyphenated or underscored (`system-reminder`, `bash-stdout`, `ide_selection`),
unlike HTML a person might paste into a prompt.

#### Blocks go with their closing tag; unclosed openings are judged as harness text later
`removing_blocks`: Each block goes with its own closing tag; an opening without one stays, to be
judged as harness text afterwards.

#### The less-than sign is one byte, so the step stays on a character boundary
`removing_blocks`: `<` is one byte, so this stays on a character boundary.

#### Codex puts IDE, browser and file context above the request
`prompt`: Codex puts IDE, browser and file context above the request.

#### Terminal input is the person's own; captured output is never kept
`prompt`: The person's own shell input; its captured output is never kept.

#### An unclosed harness tag still counts as harness text
`prompt`: An unclosed harness tag is still harness text.

#### Invoked skills are requests; housekeeping commands like /fast are not
`slash_command`: A skill or command the person invoked, e.g. `/code-review high`. Session
housekeeping such as `/fast on` is not a request.

#### Scheduled runs count as the person's work but not in injected wording
`scheduled_run`: Runs the person scheduled earlier: they asked for the work, but not in the
words the harness injects for each run.

#### Output is never read, so an action means the agent ran it, not that it succeeded
`actions_in_command`: Outcomes recorded by a shell command. Command output is never read, so an
action means the agent ran it, not that it succeeded.

#### Reading LokalBot's library means replies may echo its content
`reads_lokalbot_command`: The agent read LokalBot's library, whose content its replies may echo.

#### Codex commands are JSON argv arrays; the script is last
`unwrapped_shell_command`: Codex records commands as a JSON-encoded argv such as
`["/bin/zsh","-lc","git push"]`; the script is the last element.

#### Windows paths use forward slashes internally so one rule set reads both
`normalized_separators`: Windows paths use forward slashes here, so one set of rules reads both.

#### Mirrors NSString.standardizingPath, lexical because a session folder may no longer exist
`standardized_path`: `NSString.standardizingPath`: `~` expanded, `.`, `..` and doubled separators
gone. Lexical, because a session's folder may no longer exist.

#### A folder chosen on Windows is saved as ~\Code
`standardized_path`: A folder chosen on Windows is saved as `~\Code`.

#### Show changed files relative to project, hiding scratch and worktree plumbing
`display_path`: A changed file as the person would name it: relative to the session's
project, never exposing scratch or worktree plumbing.

#### Worktrees sit inside the project folder, so strip them first
`display_path_in`: Worktrees sit inside the project folder, so strip them first.

#### Accepts the UTC stamps both agents write and other ISO 8601 forms
`timestamp`: The UTC `yyyy-MM-ddTHH:mm:ss(.SSS…)Z` stamps both agents write, and any
other ISO 8601 form.

#### Tool output dominates transcripts, so classify from opening bytes and decode only evidence lines
`Line`: One line of a JSON Lines transcript. Tool output dominates these files (one
15 MB session held about a dozen prompts), so readers classify a line from
its opening bytes and fully decode only lines that can carry evidence.

#### Escaped quotes in nested JSON can't match, so identifiers read safely without decoding
`Line::string_value`: The first unescaped string value for `"key":"`. Escaped quotes in nested
JSON text cannot match, so this safely reads identifiers and timestamps
without decoding a multi-megabyte line.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
