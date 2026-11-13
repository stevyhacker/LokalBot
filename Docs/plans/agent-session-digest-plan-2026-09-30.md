# Agent sessions as Day Digest evidence — exploration (2026-09-30)

Status: phases 1–3 are implemented.
- **Phase 1** added the transcript readers, bursts, fixture tests, and the
  `--agent-sessions [yyyy-MM-dd]` debug flag in `LokalBot/Services/CodingAgents/`.
- **Phase 2** added the opt-in setting, settled-burst storage with retention
  and revocation, the `## Agent sessions` journal section, and the evidence
  signature and validator changes.
- **Phase 3** gives agent sessions to the digest model as segment evidence.
  Its results on real data are under phase 3 below.

Measured with the Swift readers on this Mac:

| Day | Sessions | Bursts | Transcript bytes read | Evidence | Time |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2026-09-24 | 35 | 49 | 749 MB | 50.7 K chars | 4.0 s |
| 2026-09-28 | 19 | 41 | 585 MB | 43.8 K chars | 2.8 s |
| 2026-09-29 | 22 | 46 | 542 MB | 46.1 K chars | 2.6 s |
| 2026-09-30 (morning) | 7 | 9 | 133 MB | 12.8 K chars | 0.7 s |

Bytes read are higher than the prototype's figure because they include every
file touched that day, such as resumed Codex rollouts. A per-file cache
(phase 2) removes repeat reads.

## Why: what the 2026-09-29 digest missed

The journal for 2026-09-29 was built from activity blocks and screen text. Its
task list included PR #112, "issues #113–#115" (they are PRs), and TokenLogic
PR #357. Two of its six tasks were noise from OCR of the Claude app's sidebar:
"Agent dashboard management" and "Review of prior agent conversation
histories". Claude appeared as 1h 55m of foreground time.

For the same day, the prototype read 33 local agent sessions (12 Claude Code,
21 Codex). They held about 382 MB of transcript and produced about 47 KB of
compact evidence (0.012%) in under a second. That evidence showed work the
digest never mentioned:

| Session (agent) | Project | Grounded result |
| --- | --- | --- |
| Update app branding (Codex, ~189 active min) | Mojo | Opened localhostinc/app PR #186 and pushed four follow-up commits |
| Review PR #175 sign-in flow (Codex, ~133 min) | Mojo | Commits fixing the Notion and Canva connectors; touched PRs #169, #170, #175 |
| Update CI review model (Codex, ~16 min) | alpha | Opened TokenLogic alpha PR #377 ("switch Claude review to Opus 5.5") |
| Day digest generation issue (Claude Code, ~287 min) | LokalBot | PRs #113–#117; commit "Use one remote origin approval…" |
| Data gathering opportunities (Claude Code, ~201 min) | LokalBot | PRs #108 and #109; tests run |
| README improvements + fork (Claude Code) | LokalBot | PRs #105, #107, #110, #111; launch film drafts |

Screen memory only sees what is in the foreground. Agents now do much of the
work in the background and in parallel: the day logged about 1,400 active
agent-minutes, compared with 1h 55m of Claude foreground time. Agent transcripts
are the only local record of that work, and they are much better evidence than
OCR of a terminal or chat window.

## What is on disk

Over the last seven days, Claude Code (109 files) and Codex (255 files)
account for almost all use. Cursor, opencode, Factory, Gemini, Amp, and omp had
no activity, and pi had two files. Version 1 should support only Claude Code
and Codex.

**Claude Code** — `~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`
- One JSON record per line. The useful types are `user`, `assistant`,
  `custom-title`/`agent-name` (the session title), and `pr-link`, which holds
  `prNumber`, `prUrl`, `prRepository`, and `timestamp`.
- Each record carries `timestamp`, `cwd`, `gitBranch`, `sessionId`, `uuid`,
  and `isSidechain`.
- A user prompt is a `user` record whose content is a string or `text` blocks.
  The roughly 90% of `user` records that are `tool_result` blocks are tool
  output and must be skipped.
- Assistant `tool_use` blocks give touched files (`Edit`/`Write`
  `file_path`) and shell commands (`Bash.command`).
- Forked or resumed sessions copy earlier records under the same `uuid`, so
  deduplication must use record `uuid` across files. The original file is
  created first, so the reader visits files by creation date and each record
  is credited to the session where it happened.
- `pr-link` records are re-emitted every turn, and forks copy them. They only
  annotate a burst that was active when they were written; they never create
  or extend one.
- The harness writes some turns in the person's name. These include
  `<command-name>` slash commands (kept as `/code-review high`, except
  housekeeping such as `/fast`), `<scheduled-task>` runs, and `<bash-input>`
  terminal commands. Terminal commands are kept as the command only; their
  `<bash-stdout>` is output and is dropped. Other hyphenated or underscored
  tags (`system-reminder`, `ide_selection`, `artifact-view-context`) are
  context, not the person's words.
- Size is dominated by tool output: one session was 15 MB and 5,800 lines, of
  which about 12 lines were real prompts.
- Claude Code deletes transcripts after `cleanupPeriodDays` (30 by default).

**Codex** — `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` (13 GB in total)
- Files are organized by the date the session started, and a resumed session
  keeps appending to that file. On 2026-09-29, rollouts from 09-03, 09-09,
  09-22, and 09-24 were written. The reader therefore selects files by
  modification date and never by folder. Metadata filtering keeps the 4,750
  files (13 GB) out of every scan.
- `session_meta` holds `id`, `cwd`, `originator`, `source`, and `git`. A
  subagent's `source` is an object: `{"subagent":{"other":"guardian"}}` for
  approval reviewers, or `{"subagent":{"thread_spawn":…}}` for spawned
  workers. People's sessions have a string such as `"vscode"`. The "Guardian
  review" threads were 12 of the 21 Codex sessions on 2026-09-29. All
  subagents are skipped, because their parent session reports the work.
- `response_item` records have the payload types `message`
  (`user`/`assistant`/`developer` roles), `function_call`, and
  `custom_tool_call`. An `apply_patch` body names files as
  `*** Update File: <path>`. Injected context arrives as separate
  `input_text` items of the same user message: `# AGENTS.md instructions`,
  `<environment_context>`, and IDE or browser context ending in
  `## My request:`. Each item is judged on its own.
- `event_msg.item_completed` includes `CommandExecution`, whose `command` is
  a JSON-encoded argv, and `FileChange`, whose `changes` maps each path to its
  diff. Only the command and the paths are read.
- Titles come from `~/.codex/session_index.jsonl` (`id`, `thread_name`; later
  lines are renames). The internal `state_5.sqlite` is never opened.
- `<heartbeat>` turns are scheduled automations, kept as `Scheduled
  automation: <id>`.

**Never read**: `~/.codex/auth.json`, `~/.factory/auth.*`, any
`*.auth-token`, `history.jsonl`, or anything outside an explicit allowlist of
transcript globs. These stores sit right next to credentials.

## What to extract, and what never to extract

Split each session into **bursts**: runs of activity with no gap of 10 minutes
or more. This matches `inactivityGap` in `DayDigestEvidence.summarySegments`. A
burst is not the whole session, because a Claude session can span 06:50–23:47
and would otherwise merge the whole day into one segment. For each burst, keep:

- agent, session id, title, project (the `cwd` basename or git origin repo), and branch;
- start, end, and active minutes (event gaps capped at 5 min);
- user prompts, scrubbed with `ScreenContextPrivacy.redact` and capped at
  about 280 chars each (at most 4 per burst, plus a count of the rest);
- the agent's last text reply in the burst, capped at about 600 chars;
- files changed, as paths relative to the repo with scratchpad and worktree
  prefixes stripped;
- structured actions parsed from commands: `commit: <msg>`, `opened PR:
  <title>`, `merged PR #N`, `release: <tag>`, `ran tests`, `pushed`, and PR
  URLs from `pr-link`.

Never keep tool outputs, command output, file contents, reasoning or thinking
blocks, system or developer prompts, `AGENTS.md`/`CLAUDE.md` injections, or
images. Dropping tool outputs does most of the work: it removes secrets printed
by shells, file dumps, and meeting text that an agent fetched through the
LokalBot CLI or MCP.

## Where it plugs in

The digest already folds in one kind of pre-structured evidence: meetings.
Agent sessions should enter the same way.

1. **Reader adapters** (done in phase 1, under `LokalBot/Services/CodingAgents/`).
   "AgentSession" already names Agent Mode types, so these use a `CodingAgent` prefix.
   - `CodingAgentSessionReader.transcripts(in:)` returns clipped
     `CodingAgentTranscript`s. `CodingAgentBurstBuilder` splits them into
     `CodingAgentBurst`s, and `CodingAgentSessionScanner` combines the
     readers and applies folder exclusions.
   - `ClaudeCodeSessionReader` and `CodexSessionReader` memory-map each file.
     They recognise tool-output lines from their opening bytes and take only
     their timestamp, ignore unknown record types, and fail soft for each file.
   - Files are skipped by modification and creation date, so the 13 GB store
     is never scanned.
   - `CodingAgentParseCache` (phase 2) reuses parsed files while their size
     and modification date are unchanged. On this Mac, a cold seven-day scan
     read 1.5–1.9 GB in 6–8 s. A cached refresh took 0.05–0.2 s, re-parsing
     only the one or two live sessions, and produced the same bursts as a
     fresh scan.
   - Fork copies are dropped using each file's hashed record ids, which are
     cached too. A cached original still removes the copies in a fork that
     appears later.
   - Timestamp-only events whose neighbours are within the five-minute
     active cap are compacted away. That changes no burst boundary or active
     time: 2026-09-28 gave the same 41 bursts and 43,840 characters.

2. **Store** (recommended over reading sources at digest time)
   - Ingest bursts into a LokalBot-owned table next to the activity store, keyed by
     `(agent, sessionID, burstStart)` and holding a source fingerprint.
   - Reasons:
     (a) Claude Code deletes transcripts after 30 days, so regenerating a past
     day would silently drop its agent work;
     (b) the evidence validator becomes a cheap, stable query;
     (c) retention and deletion follow LokalBot's rules. Screen-text retention
     applies, and removing a burst retracts unchanged journals through
     `retractGeneratedJournals`.

3. **`DailyEvidenceSnapshot`** (`LokalBot/Services/DailyEvidenceSnapshot.swift:36`)
   - Add `agentBursts: [DayAgentBurst]` and include it in `latestEvidenceAt`,
     `isEmpty`, and `signature`.
   - Load it in `FileDailyEvidenceSource.snapshot` (`:165`).

4. **`DayDigestEvidence`** (`LokalBot/Services/DayDigestEvidence.swift`)
   - Add `agentSessions` and pass it through `build` and
     `digestEvidence(calendar:)` (`DailyDigestEvidence.swift:6`).
   - In `summaryEvents()` (`:315`), emit one `SummaryEvent` per burst as
     `WORK SOURCE: AGENT SESSION`, at an order between meeting (0) and
     activity (1).
   - `summaryDetailIndices` (`:450`) always reserves meetings. Reserve agent
     bursts that have actions (commits or PRs) the same way, capped at about 4
     per segment, and sample the rest evenly.
   - Down-weight screen contexts from agent host apps (Claude, Codex,
     Terminal, Ghostty, iTerm, Cursor, Zed, VS Code) when a burst covers the
     same time. Those contexts are OCR of the transcript, and they produced
     yesterday's "agent dashboard" noise.

5. **Journal** (`renderDocument`, `:222`)
   - Add a deterministic `## Agent sessions` section between Meetings and Time
     allocation. For each session, list time, agent, project, title, PRs,
     commits, and changed-file count. No model is involved, so it is lossless
     even when generation fails, like the Meetings section.
   - Add one line per burst to `chronologicalLog`.
   - Teach `fallback`/`bestAvailableFallbackBlocks` to use agent titles and
     actions after meetings.
   - `DayDigestPresentation` already splits sections by `## `, so it needs a
     renderer for the new section.

6. **Prompt** (`PromptTemplates.dayDigestFocusSystem`, `:132`)
   - The prompt already says that work done with a coding agent counts as the
     person's own work. Add a short description of the agent-session format.
   - Tell the model that commits and PRs listed under Actions are verified
     outcomes, and that the agent's report is a claim to corroborate.

7. **Freshness and validation** (`DayDigestLifecycle`)
   - `evidenceValidator` (`:302`) filters current evidence to the original
     IDs. Filter agent bursts to the original `(session, burstStart)` set, and
     truncate each burst at its original last-event time. JSONL is
     append-only, so the prefix is stable.
   - Without this, a session still running at 23:00 would fail every run with
     `evidenceChangedDuringGeneration`.
   - Treat agent evidence as ordinary activity for the once-per-evening
     scheduler policy. It should not force a repair the way meeting artifacts do.
   - `contentSignature` (`DailyDigestEvidence.swift:50`): append agent fields
     **only when non-empty**. Otherwise every existing journal's `v1` signature
     changes and all past days show as stale. Days that gain agent evidence
     will show as stale once, which is correct. Offer a manual regenerate, and
     do not mass-repair more than the scheduler's 7-day catch-up window.

## Privacy contract (PRIVACY.md changes required)

- A new **Agent sessions** capture source, off by default. It has one toggle
  per agent and follows the same pattern as screen memory, which is opt-in.
- Disclose exactly what is read and kept: the extracted fields above. State
  that tool outputs and file contents are never read into LokalBot.
- Honor existing exclusions. If an agent's host app is in `excludedApps`, skip
  it by default. Add a project-folder exclusion list, because client repos may
  be off-limits. Skip sessions whose `cwd` is under an excluded folder.
- Retention: extracted bursts follow screen-text retention. Deleting in
  LokalBot never touches the agent's own files.
- Remote Think: agent evidence is covered by the existing remote-origin
  approval, but the approval copy should name it.
- Circularity: sessions that called the LokalBot CLI or MCP can restate
  library content in replies. For those bursts, keep prompts and actions and
  drop the agent's reply text. Exclude LokalBot's own Agent Mode sessions,
  since they already live in the library.

## Phased plan

1. **Readers and debug flag (done).** Swift readers with fixture tests
   (`LokalBotTests/CodingAgentSessionTests.swift`). The fixtures cover forks,
   sidechains, Guardian threads, resumed Codex rollouts, harness-written
   turns, secret redaction, and unknown or malformed records.
   `LokalBot --agent-sessions [yyyy-MM-dd]` prints a day's bursts before any
   window opens. No UI, storage, or digest change.
2. **Evidence plus a deterministic section (done).**
   - `CodingAgentEvidenceIngestor` scans the digest's seven-day window every
     ten minutes and before each digest run.
   - Only bursts idle for ten minutes are stored, in `coding_agent_bursts`.
     Such a burst can never grow, so the validator only filters to the
     original ids.
   - New bursts are additions. Removed or corrected bursts go through
     `withPrimaryEvidenceChange`, and an unreadable transcript never counts
     as a deletion. A scan that finishes after the configuration changed is
     discarded.
   - Late work on yesterday reopens its digest; older days only show as
     stale.
   - Retention follows screen text. That covers the automatic prune and the
     reviewed cleanup, which shows a row for agent records.
   - Settings → Day Memory → Coding agent sessions offers the toggle,
     per-agent switches, a folder exclusion list, and "Delete saved agent
     sessions", which also stops reading.
3. **LLM integration (done).**
   - Each settled burst becomes a `WORK SOURCE: AGENT SESSION` summary event.
   - Within a segment, a session's bursts merge into one detail. Up to six of
     the twelve detail slots are reserved for sessions, those with recorded
     outcomes first.
   - While a session covers the time, screen text from agent host apps
     (Claude, Codex, terminals, editors) keeps one sample, and standalone
     captures there are dropped. The lossless journal keeps both.
   - The focus prompt says requests show intent, recorded actions are the
     strongest evidence, and the agent's report is a claim.
   - Evaluated on the real 2026-09-29 model input, without running a model:

     | | Before | After |
     | --- | --- | --- |
     | Agent-session details | 0 of 8 segments | 29 details in all 8 segments |
     | Claude-app screen blocks | 7 | 3 |

   - The previously missing work now reaches the model: Mojo branding #186
     (3 segments), Review PR #175 (2), alpha CI #377 (1), and LokalBot
     #108–#117.
   - A first attempt with a four-slot reservation and no merging repeated one
     session up to three times per segment and still dropped PR #175. That
     led to per-session merging and the six-slot reservation.
   - **Model run (on-device Qwen3.5-4B, both variants, journal untouched).**
     - Before: six tasks from screen text, several wrong. They included
       "Claude Workspace Review" (sidebar noise) and "LokalBot CI Performance
       Improvements … PR #157 and #175" (#175 belongs to Mojo).
     - The first after-run showed two gaps:
       - Segment extraction keeps one task per segment, so parallel sessions
         were lost. Mojo #186, PR #175, and alpha #377 reached the model but
         not the task list.
       - A scheduled "previous day work update" report was read as work done
         that day.
     - Passing every session to aggregation made the 4B model blend
       unrelated sessions into four tasks. So session tasks are now stated
       from recorded actions and added after aggregation, merging only by
       title. Scheduled runs' reports are withheld.
     - The same run exposed a reader bug: Codex records commands as argv
       arrays, all 14,070 of them over ten days, and the reader expected a
       string. Every Codex action was being dropped.
     - Final after-run: 11 grounded tasks. They cover every session behind
       the missed work, including Mojo branding #186 with its commits, PR
       #175 with its fixes, alpha #377, LokalBot #108–#117, and README
       #105–#111. The scheduled run is described as a request, not as work.
       The remaining errors are the small model's wording, such as naming
       a PR from another repository.
4. **Follow-ons.**
   - Index bursts in Recall, e.g. "what did Codex change for branding?".
   - Expose bursts through CLI/MCP under the screen-memory toggle.
   - Use agent actions as Dream inputs.
   - Label tasks as delegated or hands-on.
   - Add adapters for pi, opencode, and Cursor if usage appears.

## Alternatives considered

- **Agent hooks** (Claude Code `Stop`/`SessionEnd`, Codex `hooks.json`)
  calling `lokalbot` would be precise. But they only cover future sessions,
  need persistent changes to each agent's configuration, and miss sessions
  started elsewhere. They could be an optional precision add-on later, not the
  primary path.
- **OpenTelemetry export** from the agents to a local OTLP receiver. This is
  heavier, needs setup for each agent, and the emitted events are tuned for
  cost and usage rather than content.
- **Reading source files at digest time without a store.** This is simpler,
  but evidence disappears when the agent prunes its transcripts, and the
  validator would re-parse large files at commit.

## Decisions (2026-09-30)

- Agent work appears both as a deterministic `## Agent sessions` section and
  merged into Tasks.
- The agent's final reply is kept, labeled as a claim to corroborate with
  recorded actions. It is withheld for sessions that read the LokalBot library.
- Project-folder exclusions drop whole sessions; the scanner already supports
  them. The settings UI arrives with the capture toggle in phase 2.
