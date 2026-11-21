# 0013. Coding-agent sessions

- Status: Accepted
- Date: 2026-11-20

## Context

LokalBot reads the session transcripts of coding agents such as Claude Code and Codex into timeline bursts that feed day digests, and keeps a search copy of the notes those agents write for their own later sessions. The Mac app (`LokalBot/Services/CodingAgents`, `LokalBot/Services/AgentMemory`) and the Windows and Linux app (`lokalbot-engine` `coding_agents` and `agent_notes`) follow the same rules, and the npm package in `Distribution/npm` reuses them to sum up a year of agent use from the same logs plus Cursor and Gemini CLI. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Consent, exclusions and deletion

### Nothing from the agents is read until the person chooses

Nothing under `~/.claude` or `~/.codex` is opened until the person has chosen to allow it, in setup or in Settings → Day Memory → Coding agent sessions; `Settings::enabled_coding_agents` is empty before that. On a new install no session is read until setup is finished: `finishOnboarding` starts reading.

Where: `LokalBot/AppState.swift` (`AppState.init`), `LokalBot/Views/Settings/CodingAgentEvidenceSettings.swift`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/coding_agents.rs`, `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs`.

### Sessions in excluded folders are dropped

Sessions whose working directory is inside an excluded folder are dropped, for repositories whose work must never enter the library. A new exclusion also removes stored bursts it covers (see the next decisions).

Where: `LokalBot/Services/CodingAgents/CodingAgentSessionScanner.swift` (`CodingAgentSessionScanner.excludedFolders`).

### Turning session reading off keeps what was saved

Turning off transcript reading stops it but keeps the sessions already saved, like the other capture sources. Deleting them is a separate, explicit action on the same settings page.

Where: `LokalBot/AppState.swift` (`AppState.applyCodingAgentEvidenceSetting`), `LinuxWindows/crates/lokalbot-app/src/pages/settings/coding_agents.rs`.

### Deleting or correcting saved sessions withdraws what was built from them

Deleting saved sessions removes every one and withdraws the generated journals that used them. When a stored burst is removed or corrected (a deleted session, a new folder exclusion), its dependent products are withdrawn through the same path as deleting screen evidence; new bursts are plain additions. The agents' own files are never touched.

Where: `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppData::delete_coding_agent_evidence`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs`, `LokalBot/Services/CodingAgents/CodingAgentEvidenceIngestor.swift`.

### Agent notes stay off until turned on after a notice, and turning them off deletes the copy

Read coding agent notes stays off until the person turns it on after a notice, and nothing under the agents' folders is opened before that. Turning it off deletes the saved copies, because they only mirror the agents' own files.

Where: `LokalBot/AppState.swift` (`AppState.applyCodingAgentNotesSetting`), `LokalBot/Views/Settings/CodingAgentEvidenceSettings.swift`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/coding_agents.rs`, `LinuxWindows/crates/lokalbot-engine/src/agent_notes/mod.rs`.

### External agents need their own Agent notes grant

The Agent notes grant (`AgentNotesAccessGate`) is only a marker the app sets from Settings → AI agents. It is separate from every other grant, and no Agent Mode capability satisfies it. `lokalbot-cli` and its MCP server search the saved notes themselves, without the app running, and find none while Read coding agent notes is off, because turning that off deletes them.

Where: `LinuxWindows/crates/lokalbot-core/src/agent_notes/access.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/settings/privacy.rs` (`SettingsPage.set_agent_notes_access`).

### Ask resolves cited notes only while note reading is on

Ask loads cited coding-agent notes only while Read coding agent notes is on, as on the rest of the page: with it off, the saved copy is gone. On Windows and Linux the cited notes not loaded yet are read off the UI thread.

Where: `LokalBot/Views/Ask/AskAnswerSources.swift` (`AnswerSourcesList.loadCitedNotes`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/transcript.rs` (`AskPage::load_note_citations`).

## Reading transcripts

### Claude Code transcripts are read oldest first

A forked or resumed session copies earlier records under their original ids. Reading older files first credits that history to the session where it happened.

Where: `LokalBot/Services/CodingAgents/ClaudeCodeSessionReader.swift` (`ClaudeCodeSessionReader.transcripts`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/claude.rs` (`ClaudeReader::transcripts`), `Distribution/npm/src/claude.mjs` (`readClaude`).

### Codex rollouts are chosen by modification date, not by folder

Rollouts are read from `~/.codex/sessions/YYYY/MM/DD/*.jsonl` and `~/.codex/archived_sessions/`, including the `*.jsonl.zst` files Codex compresses finished rollouts into. A rollout stays in the folder of the day it started even when it is resumed weeks later, so files are selected by modification date. Titles come from `session_index.jsonl`; credentials and Codex's internal SQLite state are never opened.

Where: `LokalBot/Services/CodingAgents/CodexSessionReader.swift` (`CodexSessionReader`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/codex.rs`, `Distribution/npm/src/codex.mjs`.

### Subagent work belongs to the session that spawned it

The app skips Codex subagent threads, approval reviewers included, because their parent session reports the work. A subagent thread is recognized by an object-valued `source` such as `{"subagent":{"other":"guardian"}}`; sessions people start have `"vscode"` or `"cli"`. The npm package instead adds a Codex subagent thread to the session that spawned it, a helper thread with no parent (such as an approval reviewer) to tokens and tool calls only, and Claude Code subagent transcripts (`<config>/projects/<folder>/<id>/subagents/`) to their parent's time, tokens and tool calls, never its requests.

Where: `LokalBot/Services/CodingAgents/CodexSessionReader.swift` (`CodexSessionReader`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/codex.rs` (`CodexSummary::consume`), `Distribution/npm/src/codex.mjs`, `Distribution/npm/src/claude.mjs`.

### A rollout kept both plain and compressed is read once

Such a rollout is read from the copy written last. Reading both would count its work twice.

Where: `LokalBot/Services/CodingAgents/CodexSessionReader.swift` (`CodexSessionReader.newestCopies`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/codex.rs` (`newest_copies`).

### A compressed rollout's start comes from its file name

Compressing gives the file a new creation date, the time it was last written, so the bound no later than its first record comes from its name, `rollout-2026-10-19T08-23-26-<id>.jsonl.zst`. The name is in the local time where Codex ran, so a day before its date covers every zone. The test gives compressed rollouts the creation date of their last write and expects them read like plain ones.

Where: `LokalBot/Services/CodingAgents/CodingAgentCompressedTranscript.swift` (`CodingAgentCompressedTranscript.startBound`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/cache.rs` (`start_bound`), `LokalBotTests/Services/CodingAgents/CodingAgentSessionTests.swift` (`testCodexReaderReadsCompressedRolloutsLikePlainOnes`).

### Transcripts are streamed, never held whole

Tool output dominates these files: one line can hold a multi-megabyte screenshot and one rollout gigabytes, and most of a long-time user's Codex history is compressed. The Mac app decompresses `.zst` rollouts a piece at a time, and because zstd keeps a frame's last byte until all of the frame's output is written, its loop also drains a full output buffer. The npm package streams transcripts as raw bytes one line at a time, and reads `.zst` through Node's own zstd decompressor, which needs Node.js 22.15 or later.

Where: `LokalBot/Services/CodingAgents/CodingAgentCompressedTranscript.swift` (`CodingAgentCompressedTranscript`, `CodingAgentCompressedTranscript.forEachBatch`), `Distribution/npm/src/lines.mjs`.

### Transcript lines are classified by their opening bytes

One 15 MB session held about a dozen prompts; the rest was tool output. So readers classify a JSON Lines line from its opening bytes and fully decode only lines that can carry evidence.

Where: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/text.rs` (`Line`).

### A cached transcript that stops being append-only is parsed again

Both agents only append to their transcripts. A file that shrank, was replaced, or whose bytes before the resume point changed is parsed again from the start.

Where: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/cache.rs` (`FileState`).

## What a session contributes

### Tool output, file contents and reasoning never become events

An event is one timestamped fact from a transcript. Tool output, file contents, reasoning and injected system or developer text never become events; only what a person typed counts as a request, and only the commands an agent ran count as actions.

Where: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/builder.rs` (`EventKind`), `Distribution/npm/src/text.mjs`.

### Every string leaving a reader goes through one set of text rules

Injected context is removed, credentials are redacted, and length is capped before anything is kept. The npm package's text rules mirror the app's, and no text leaves that module, only counts.

Where: `LokalBot/Services/CodingAgents/CodingAgentText.swift` (`CodingAgentText`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/text.rs`, `Distribution/npm/src/text.mjs`.

### Recorded actions come from the commands the agent ran

The pull requests and commits shown for a work session come from the shell commands the agent ran; its own report is left out because it is only a claim. Command output is never read, so an action means the agent ran the command, not that it succeeded.

Where: `LokalBot/Services/CodingAgents/CodingAgentText.swift` (`CodingAgentText.actions`), `LokalBot/Views/ScreenMemory/CaptureDetailView.swift` (`TimelineAgentPanel`), `LinuxWindows/crates/lokalbot-app/src/pages/timeline/agent_work.rs`.

### Replies of sessions that read LokalBot's library are withheld

A session that read LokalBot's own library through its CLI or MCP may restate library content in its replies, so they are withheld to keep the digest from consuming its own output.

Where: `LokalBot/Services/CodingAgents/CodingAgentSession.swift` (`CodingAgentTranscript.consultedLokalBot`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/builder.rs` (`Transcript.consulted_lokalbot`).

### Pull request links annotate work but never start or extend a burst

Claude Code emits the pull request links it associated with a session again every turn, so they annotate work but never start, extend or keep alive a burst on their own.

Where: `LokalBot/Services/CodingAgents/CodingAgentSession.swift` (`CodingAgentEvent.Kind.pullRequest`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/builder.rs` (`EventKind::PullRequest`).

## Bursts and digests

### Only settled bursts become evidence

A burst idle for the full inactivity gap can never grow again, because any later event starts a new burst. Only settled bursts are stored, so a saved digest's inputs cannot change underneath it.

Where: `LokalBot/Services/CodingAgents/CodingAgentSession.swift` (`CodingAgentBurst.isSettled`), `LinuxWindows/crates/lokalbot-core/src/coding_agents/mod.rs` (`CodingAgentBurst::is_settled`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs`.

### Redundant activity pings are dropped, except across midnight

A timestamp-only event is redundant when the events either side of it are within `activeGapCap` of each other: the gaps it splits count in full either way. Busy sessions log thousands of tool results, so dropping these keeps cached transcripts small without changing any burst. Bursts are cut at midnight, so a ping is kept when its neighbors fall on different days; otherwise the next day's first event, or the scan window's start, would move the edge of a burst already saved. This makes compacting then clipping to whole days keep the same events as clipping first, and compacting again after later appends keep the same as compacting once at the end.

Where: `LokalBot/Services/CodingAgents/CodingAgentSession.swift` (`CodingAgentBurstBuilder.compactingActivity`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/builder.rs` (`compacting_activity`).

### A burst is labeled from its own records

A scan reads a window of days, and a long session changes branch and folder within it. Labels taken from the session as a whole would relabel the burst on every such change and as the window slides, so each burst is labeled from its own records.

Where: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/builder.rs` (`burst`).

### A finished day keeps its bursts until its work changes

A finished day keeps the bursts its digest and overnight review were written with until a session's work there changes or the session is gone. On 2026-10-20 and 21, Claude Code sessions that moved to another branch or folder relabeled their earlier bursts on each refresh; every relabel revised those days, which rebuilt their digests and discarded their Dream reviews several times a day.

Where: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs` (`apply_scan`), `LokalBotTests/Services/CodingAgents/CodingAgentEvidenceTests.swift` (`testASessionMovingOnLeavesAnEarlierDaysEvidenceAndDigestCurrent`).

## Refreshes

### A scan's result never undoes a change made while it ran

Turning the feature off, deleting saved sessions or adding an exclusion during a session scan must not be undone by its result. A notes scan whose setting was turned off or narrowed mid-read is discarded; the settings change starts its own refresh, which waits for this one.

Where: `LokalBot/Services/CodingAgents/CodingAgentEvidenceIngestor.swift` (`CodingAgentEvidenceIngestor.performRefresh`), `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs` (`Ingestor::refresh_from`), `LinuxWindows/crates/lokalbot-engine/src/agent_notes/mod.rs` (`Ingestor.refresh_with`).

### Note scans and deletions run one at a time

Note scans run on a background thread one at a time, and deletion takes its turn with them, so turning the setting off and on again cannot delete what the new read just saved.

Where: `LokalBot/Services/AgentMemory/AgentMemoryStore.swift` (`AgentMemoryIngestor.removeAll`), `LinuxWindows/crates/lokalbot-engine/src/agent_notes/mod.rs` (`Ingestor`).

### A failed read is never a deletion

A session scan never takes a read failure as a deletion. A notes scan lists files that exist but could not be read, and while any are listed, notes missing from the scan are not taken as deleted.

Where: `LinuxWindows/crates/lokalbot-engine/src/coding_agents/mod.rs`, `LokalBot/Services/AgentMemory/AgentMemoryNote.swift` (`AgentMemoryScan.unreadableFiles`), `LinuxWindows/crates/lokalbot-core/src/agent_notes/mod.rs` (`NoteScan.unreadable_files`).

## Agent notes

### Notes come only from the agents' memory folders and feed search only

While Read coding agent notes is on, LokalBot collects Claude Code's notes (`~/.claude/projects/*/memory/*.md`) and Codex's memories (`~/.codex/memories`) and makes `agent-notes.sqlite` in the library match what it found. Instruction files such as `CLAUDE.md` and `AGENTS.md` are never read. The notes are a search source only: nothing feeds the day digest, the overnight review or Personal Context.

Where: `LokalBot/Services/AgentMemory/AgentMemoryReaders.swift`, `LokalBot/Services/AgentMemory/AgentMemoryStore.swift` (`AgentMemoryIngestor`), `LinuxWindows/crates/lokalbot-engine/src/agent_notes/mod.rs`.

### Opening a note opens the agent's own file, which LokalBot never edits

A note opens as the agent's own file in its default app. LokalBot keeps a copy for search only and never edits the file.

Where: `LokalBot/Views/Agent/AgentNoteResultRow.swift` (`AgentNoteOpener`), `LinuxWindows/crates/lokalbot-app/src/pages/ask/search.rs` (`open_note`).

### Folder exclusions err toward excluding sibling projects

Claude Code names a project folder after its working directory with every character that is not an ASCII letter or digit turned into `-`. That loses which dashes were separators, so a sibling such as `app-old` reads as inside an excluded `app` and is left out too: the safe direction.

Where: `LokalBot/Services/AgentMemory/AgentMemoryNote.swift` (`AgentMemoryExclusions.excludes`), `LinuxWindows/crates/lokalbot-engine/src/agent_notes/exclusions.rs` (`Exclusions.excludes_claude_project`).

### A project's working directory must reproduce its folder name

Because the project folder's name is the path with its separators lost, the working directory is read from the project's newest session files and kept only if it produces the same name.

Where: `LinuxWindows/crates/lokalbot-engine/src/agent_notes/claude.rs` (`working_directory`).

## The npm package

### The share card leaves out project names by default

Project names can be client names, so the share image omits them unless `showProjects` is set.

Where: `Distribution/npm/src/card.mjs` (`renderCard`).

### The npm readers decode every line

Judging Claude Code log lines by their opening bytes was measured on 5.3 GB of real logs and saved no time, so every line is decoded rather than keeping a second way of reading that could disagree with the first. As in the app's reader, a tool result contributes only its time, and meta records and compaction summaries are skipped.

Where: `Distribution/npm/src/claude.mjs`.

### Days whose Claude Code logs are gone use `stats-cache.json`

Claude Code deletes session logs after 30 days unless `cleanupPeriodDays` says otherwise, but keeps a count per day in `stats-cache.json` beside the projects folder. Those counts, keyed by date (`2026-02-03`), stand in for the days whose logs are gone; the file holds numbers only.

Where: `Distribution/npm/src/claude.mjs` (`readClaudeSummary`).

### Codex commands and edits are counted once

Codex logs a shell command when it is asked for and again when it has run, and an edit as a patch and again as a file change. Each is counted from the record of what happened when the rollout has one.

Where: `Distribution/npm/src/codex.mjs` (`readRollout`).

### Codex token totals are counted by their growth

Codex token readings are running totals, so each reading adds what the total grew by since the previous one. Readings from before the window move the baseline without being counted, and a total that falls has started again, so its new reading counts in full.

Where: `Distribution/npm/src/codex.mjs` (`advance`).

### Cursor is read from two stores without double counting

Cursor's global SQLite store (`state.vscdb`, table `cursorDiskKV`), read through Node's built-in `node:sqlite` (Node 22.5+), holds composer sessions, exact bubble timestamps, models, subagents, tool calls and token counts. `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<id>/<id>.jsonl` catches Cursor Agent CLI sessions and transcripts not in `state.vscdb`, and is the fallback on Node.js before 22.5. Only counts, timestamps, tool names, git actions, models and token totals are kept, never prompt or reply text.

Where: `Distribution/npm/src/cursor.mjs`.

### Gemini CLI input tokens already include cached ones

Sessions are read from `~/.gemini/tmp/<project>/chats/session-*.json`. In these logs `tokens.input` already includes `tokens.cached`, and `tokens.thoughts` counts reasoning output tokens. No prompt or reply text is kept.

Where: `Distribution/npm/src/gemini.mjs`.

### Agent hours use the timeline's burst definition

"Agent hours" follow LokalBot's timeline (`CodingAgentBurstBuilder`): a run of work ends after ten minutes with no activity, and a pause longer than five minutes inside a run counts as five. Two agents working at once count twice.

Where: `Distribution/npm/src/stats.mjs`.

## Consequences

- The privacy boundary sits in the readers: nothing is opened before the person chooses, every kept string passes the shared text rules, tool output and reply text of sessions that read the library never enter the library, and credentials, Codex's internal state, instruction files and the agents' own files are never read or edited. A new agent or field has to go through the same path.
- Saved bursts must stay stable once a day is finished. Anything that relabels, regroups or moves the edges of saved bursts revises those days, rebuilds their digests and discards their Dream reviews.
- The Mac reader, the Windows and Linux reader and the npm package mirror each other's rules (oldest first, selection by modification date, one copy per rollout, start from the file name, burst definition), so a change to one belongs in all three. A scan never undoes a settings change and never takes a failed read as a deletion.
