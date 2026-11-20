# 0122. Distribution channels

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `Distribution/npm/bin/`, `Distribution/npm/src/antigravity.mjs`, `Distribution/npm/src/card-renderer.mjs`, `Distribution/npm/src/card.mjs`, `Distribution/npm/src/claude.mjs`, `Distribution/npm/src/codex.mjs`, `Distribution/npm/src/collector.mjs`, `Distribution/npm/src/cursor.mjs`, `Distribution/npm/src/demo.mjs`, `Distribution/npm/src/format.mjs`, `Distribution/npm/src/gemini.mjs`, `Distribution/npm/src/lines.mjs`, `Distribution/npm/src/opencode.mjs`, `Distribution/npm/src/pi.mjs`, `Distribution/npm/src/pricing.mjs`, `Distribution/npm/src/sqlite.mjs`, `Distribution/npm/src/stats.mjs`, `Distribution/npm/src/terminal.mjs`, `Distribution/npm/src/text.mjs`, `Distribution/npm/src/wrapped.mjs`, `Distribution/npm/test/`, `Distribution/raycast/src/answer-view.tsx`, `Distribution/raycast/src/cli.ts`, `Distribution/raycast/src/draft-reply.tsx`, `Distribution/raycast/src/quick-recall.tsx`, `Distribution/raycast/src/use-lokalbot-answer.ts`.

## Decisions

### `Distribution/npm/bin/lokalbot.mjs`

#### Opening the report is a convenience; path is already printed
`open`: The path is printed above; opening it is a convenience.

### `Distribution/npm/src/antigravity.mjs`

#### Antigravity transcript locations and field meanings; no text kept
Reads Antigravity conversation transcripts from:
  - `~/.gemini/antigravity/brain/<id>/.system_generated/logs/transcript.jsonl`
  - `~/.gemini/antigravity-cli/brain/<id>/...`
  - `~/.gemini/antigravity-ide/brain/<id>/...`
  - `~/.t3/userdata/providers/antigravity/<hash>/antigravity-acp/brain/<id>/...`

Each line is one step (`USER_INPUT`, `PLANNER_RESPONSE`, `CHECKPOINT`, or a
tool step). `input_tokens` is uncached input; `cache_read_tokens` is cached
input read from prompt cache. No prompt or reply text is kept.

### `Distribution/npm/src/card-renderer.mjs`

#### Renderer is zero-import, shared by Node and browser page
Pure, zero-import SVG card renderer shared by Node (`card.mjs`) and the
self-contained browser share page. Keeps CLI rendering and live browser
toggles byte-for-byte consistent with zero external dependencies.

#### Keep at least six weeks so zoomed grids stay balanced
`resolveRange`: Keep at least 6 weeks so zoomed GitHub grids stay visually balanced.

#### Cap cell size so zoomed ranges do not turn giant
`drawContributionGraph`: Compute crisp rounded-square sizing (capped so zoomed ranges don't turn giant)

#### Use 88th-percentile intensity scale so heavy days do not saturate
`drawContributionGraph`: Robust 88th-percentile intensity scale so normal heavy days shine cleanly

### `Distribution/npm/src/card.mjs`

#### Share image and page load nothing from the network
The image people share: an SVG drawn from the year's figures, and the
self-contained page that previews it with live layout/privacy toggles,
saves or copies a 2x PNG, and prepares a post caption. Both load nothing
from the network.

#### Project names may be client names so image omits them by default
`renderCard`: Project names can be client names, so the image leaves them out unless
`showProjects` is set.

#### Pack sparse arrays to keep standalone HTML small
`serializePayload`: Packs sparse grid & earlierDays arrays so the standalone HTML file stays small.

### `Distribution/npm/src/claude.mjs`

#### Claude reader follows Swift reader; decode every line, byte-prefix skipping measured no faster
Reads Claude Code sessions from `<config>/projects/<folder>/<id>.jsonl`
and the subagent transcripts beside them, in
`<config>/projects/<folder>/<id>/subagents/`.

The rules follow LokalBot's own reader (ClaudeCodeSessionReader.swift):
a tool result contributes only its time, and meta records and compaction
summaries are skipped. Subagent work adds to its parent session's time,
tokens and tool calls, never to its requests.

Every line is decoded. Judging lines by their opening bytes instead was
measured on 5.3 GB of real logs and saved no time, so it is not worth a
second way of reading that could disagree with the first.

#### Longer lines are tool results with files or images; skipped
`PARSE_LIMIT`: A longer line is a tool result with a file or an image in it; nothing counted is that large.

#### Use stats-cache.json daily counts for days whose logs were deleted
`readClaudeSummary`: Claude Code deletes session logs after 30 days unless `cleanupPeriodDays`
says otherwise, but keeps a count per day in `stats-cache.json` beside the
projects folder. Returns those counts by date (`2026-02-03`), for the days
whose logs are gone. The file holds numbers only.

#### Read older files first so forked history is credited where it happened
`readClaude`: A fork or resumed session copies earlier records under their original
ids. Reading older files first credits that history where it happened.

#### Fall back to mtime when filesystem reports no creation time
`candidates`: Some filesystems report no creation time.

#### Dedupe usage by API message id since one message spans records
`readTranscript`: Usage by API message id: one message is written as several records.

#### Older versions wrote subagent turns into the session file
`readTranscript`: Older versions wrote subagent turns into the session's own file.

#### Terminal-mode commands count as the person's own actions
`countRequest`: A command the person ran in the agent's terminal mode is still their work.

#### Count the model the person chose, not a subagent's
`countReply`: The model a person chose, not the one a subagent was handed.

### `Distribution/npm/src/codex.mjs`

#### Codex reader rules: modified-date selection, zst, subagent crediting, no credentials
Reads Codex rollouts from `<home>/sessions/YYYY/MM/DD/*.jsonl` and
`<home>/archived_sessions/`. Codex compresses older rollouts with zstd, as
`*.jsonl.zst`; those are read too where Node.js can decompress them.

The rules follow LokalBot's own reader (CodexSessionReader.swift). A
rollout stays in the folder of the day it started even when it is resumed
weeks later, so files are chosen by modification date. A subagent thread
adds to the session that spawned it; a helper thread with no parent, such
as an approval reviewer, adds its tokens and tool calls only. Credentials
and Codex's internal state are never opened.

#### Longer lines are tool output with files or images; skipped
`PARSE_LIMIT`: A longer line is tool output with a file or an image in it; nothing counted is that large.

#### Rollout and its compressed copy are one thread; keep the newer
`readCodex`: A rollout and its compressed copy are one thread: keep the newer file.

#### Credit nested subagent work to the thread a person started
`readCodex`: A subagent can spawn its own; work is credited to the thread a person started.

#### Subagent source is an object; people start vscode, cli or exec
`sessionMeta`: A subagent's `source` is an object such as
{"subagent":{"thread_spawn":{"parent_thread_id":"…"}}}; people start "vscode", "cli" or "exec".

#### Count commands and edits from the done record to avoid doubles
`readRollout`: Codex logs a shell command when it is asked for and again when it has
run, and an edit as a patch and again as a file change. Each is counted
from the record of what happened when the rollout has one.

#### Token counts are running totals written two ways
`readRollout`: Token counts are running totals for the thread, written two ways.

#### Count the model a person chose, not subagent or reviewer
`readRollout`: The model a person chose, not the one a subagent or reviewer was handed.

#### Injected context arrives as separate items; judge each on its own
`countResponseItem`: Codex sends injected instructions and context as separate items of
the same user message; each is judged on its own.

#### Only the command is read, never its output
`countCompletedItem`: Only the command; its output is never read.

#### FileChange maps path to diff; only paths are used
`countCompletedItem`: `changes` maps each path to its diff; only the paths are used.

#### Shell tools pass JSON args with cmd or command
`shellCommand`: Shell tools pass JSON arguments with `cmd` (string) or `command` (string or argv).

#### Pre-window readings set baseline; a falling total restarts and counts fully
`advance`: Adds what a running total grew by since its previous reading. Readings
from before the window move the baseline without being counted. A total
that falls has started again, so the new reading counts in full.

### `Distribution/npm/src/collector.mjs`

#### Collector keeps counts and times only, never request or reply text
What the readers gather for one year: per-session counts and event
times. Request and reply text is counted and dropped; nothing here holds
what was said.

#### start and end are epoch ms with end exclusive
`createCollector`: `start` and `end` are epoch milliseconds; `end` is exclusive.

#### Forked or resumed sessions copy history, so dedupe record ids
`createCollector.seenRecords`: Record ids already counted: a forked or resumed session copies its history.

#### SQLite needs Node.js 22.5+; otherwise skipped and counted
`createCollector.sqliteSkipped`: SQLite databases this Node.js cannot open (needs Node.js 22.5+).

#### Parentless helper thread counts tokens but not hours
`newSession.hidden`: A helper thread with no known parent: its tokens count, its hours do not.

#### Record changed files by absolute path so each counts once
`addFile`: Records a changed file by its absolute path, so one file counts once.

#### Log may come from another system so folder style decides path join
`addFile`: The log may come from another system, so the folder's own style decides.

### `Distribution/npm/src/cursor.mjs`

#### Cursor reads state.vscdb and agent-transcripts JSONL without double counting
Reads Cursor agent sessions from two local stores without double-counting:
  1. Cursor's global SQLite store (`state.vscdb`, `cursorDiskKV` table) via
Node.js's built-in `node:sqlite` (Node 22.5+) — holds composer sessions,
exact bubble timestamps, models, subagents, tool calls, and token counts.
  2. `~/.cursor/projects/<encoded-cwd>/agent-transcripts/<id>/<id>.jsonl` —
catches Cursor Agent CLI / transcripts not in `state.vscdb`, and serves
as a fallback when running on Node.js \< 22.5.

No prompt or reply text is kept; only counts, timestamps, tool names, git
actions, models, and token totals.

#### Source may be default object or a --cursor-dir folder
`readCursor`: `source` is either `{ projectsDir, stateDb }` (default) or a string folder
from `--cursor-dir` (looks for `state.vscdb` and/or `projects/` inside, or
treats the folder itself as `projects/`).

#### Keep composers whose lifetime overlaps the year window
`readCursor`: Keep composers whose lifetime overlaps the requested year window.

#### JSONL lacks timestamps; anchor on file times so hours are never inflated
`readJsonlTranscript`: Cursor JSONL files omit per-line timestamps; anchor conservatively on file
creation/modification time within the year so hours are never inflated.

#### Slug decoding is best-effort and yields only the leaf
`decodeCursorProjectSlug`: `Users-alice-Documents-GitHub-LokalBot` -> `/Users/alice/Documents/GitHub/LokalBot` (best-effort leaf).

### `Distribution/npm/src/demo.mjs`

#### Demo year is seeded so output is deterministic
A made-up year, for screenshots and for trying the cards without logs.
The same seed always produces the same year.

#### Demo has August break and busier year
`demoYear`: A two-week break in August, and a year that gets busier.

### `Distribution/npm/src/format.mjs`

#### Whole hours for year totals; under ten keeps one decimal
`hours`: Whole hours for a year's total: `1,248`. Under ten hours keeps one decimal.

#### Dollars shown whole for card readability
`currency`: `1642.4` as `$1,642`; whole dollars for card readability.

#### Terminal and image cards share these fact lines
`factLines`: The facts both cards state, as `[figure, words]` pieces per line.

### `Distribution/npm/src/gemini.mjs`

#### Gemini tokens.input includes cached; thoughts are output tokens
Reads Gemini CLI sessions from `~/.gemini/tmp/<project>/chats/session-*.json`.
Each session file contains `sessionId`, `startTime`, `lastUpdated`, and
`messages` (`type: "user" | "gemini"` with `model`, `tokens`, and `toolCalls`).

In Gemini CLI logs, `tokens.input` already includes `tokens.cached`, and
`tokens.thoughts` counts reasoning output tokens. No prompt or reply text is kept.

#### Gemini input includes cached; thoughts count as output
`readGemini`: Gemini CLI `input` already includes `cached`; `thoughts` are output tokens.

### `Distribution/npm/src/lines.mjs`

#### Stream JSONL as bytes; zstd needs Node.js 22.15+
Streams a JSON Lines transcript as raw bytes, one line at a time, so a
multi-gigabyte log never has to fit in memory. Tool output dominates these
files: a single line can hold a multi-megabyte screenshot.

Codex compresses older rollouts with zstd (`*.jsonl.zst`). Those are read
through Node's own zstd decompressor, which needs Node.js 22.15 or later.

#### Skip lines over 64 MB since nothing counted is that large
`MAX_LINE`: Lines longer than this are skipped: nothing a reader counts is that large.

#### Line buffer is valid only during the callback
`forEachLine`: Calls `onLine(bytes)` for every non-empty line of `file`. The buffer is
only valid during the call. Returns the number of bytes read.

#### Errors from onLine stop reading and reject; bytes counted after decompression
`forEachLineAsync`: Like `forEachLine`, and also reads zstd-compressed files. An error thrown
by `onLine` stops reading and rejects with that error. Resolves to the
number of bytes read, after decompression.

#### Caller may reuse chunk, so continuing lines are copied
`lineSplitter`: Splits pushed chunks into lines. A chunk may be reused by the caller once
`push` returns, so a line that continues into the next chunk is copied.

### `Distribution/npm/src/opencode.mjs`

#### OpenCode needs Node 22.5+ sqlite; child sessions roll into parent
Reads OpenCode session history from `<data>/opencode/opencode.db` using
Node.js's built-in `node:sqlite` (Node 22.5+, zero external dependencies).
Subagent/child sessions (`parent_id`) roll into their parent session's time,
tokens, and tool calls without adding to its requests.

### `Distribution/npm/src/pi.mjs`

#### Pi and OMP share v3 JSONL format; OMP subagents roll into parent
Reads Pi (`~/.pi/agent/sessions`) and OMP / Oh My Pi (`~/.omp/agent/sessions`)
JSONL session logs. Both share the version-3 JSONL transcript format:
  - `session` header (`id`, `cwd`, `timestamp`)
  - `model_change` (`provider`, `modelId` or `model`)
  - `message` (`role: "user" | "assistant" | "toolResult"`, `content`, `usage`)

OMP also stores subagent runs as nested `<session-dir>/<Subagent>.jsonl` files
beside the parent session; those roll into the parent session's time, tokens,
and tool calls without adding to its requests.

#### OMP stores subagent transcripts under parent-session-stem folder
`readPiFamily`: OMP places subagent transcripts in `<project>/<parent-session-stem>/<Agent>.jsonl`.

### `Distribution/npm/src/pricing.mjs`

#### Rates are API-list estimates, not bills; subscriptions cost less
Public list API rates (USD per million tokens), used to estimate what the
year's logged tokens would cost at pay-as-you-go API pricing. Flat-rate
subscriptions (Claude Pro/Max, ChatGPT Plus/Pro) cost less; the figure is
an API-equivalent estimate, never a bill.

#### input includes both cached and cacheWrite tokens
`tokenCostUsd`: Estimates USD list API value for `{ input, cached, cacheWrite, output }`,
where `input` includes both `cached` and `cacheWrite`.

### `Distribution/npm/src/sqlite.mjs`

#### Older Node returns unsupported so SQLite readers skip gracefully
Thin wrapper around Node.js's built-in `node:sqlite` (Node 22.5+).
Returns `{ db: null, unsupported: true }` on older Node.js versions so
SQLite-backed readers (OpenCode, Cursor) skip gracefully with zero deps.

### `Distribution/npm/src/stats.mjs`

#### Agent hours: 10 min inactivity ends a run; pauses over 5 min count as 5
Turns what the readers gathered into the year's figures.

"Agent hours" uses the same definition as LokalBot's timeline
(CodingAgentBurstBuilder): a run of work ends after ten minutes with no
activity, and a pause longer than five minutes inside a run counts as
five. Two agents working at once count twice.

#### Silence over ten minutes ends a run
`INACTIVITY_GAP`: A longer silence ends a run of work.

#### Pauses inside a run over five minutes count as waiting
`ACTIVE_GAP_CAP`: Longer pauses inside a run count as waiting, not work.

#### Runs under one minute are not an agent working at once
`PARALLEL_MINIMUM`: Shorter runs are not "an agent working" for the at-once count.

#### Year boundaries use this computer's local time zone
`yearWindow`: The year's first instant and the next year's, in this computer's time zone.

#### Summary-day counts have no hours; reported under coverage and extend streak
`computeStats`: Returns `{ stats, grid, calendar, earlierDays }`. `stats` is plain data,
safe to print as JSON. `grid` holds agent milliseconds for every hour of
every day, for drawing.

`summaryDays` maps a date to the counts Claude Code kept for a day whose
logs it has since deleted. Those counts have no hours, so they stay out of
every figure taken from the logs; they are reported on their own under
`coverage`, extend the streak, and come back in `earlierDays` (tool calls
per day of the year) for drawing. A day another agent's logs cover still
gets Claude Code's count: only Claude Code's own logs replace it.

#### Every thread's tokens, tool calls and actions count, hours aside
`computeStats`: Every thread's tokens, tool calls and recorded actions count.

#### Day with sessions but no tool calls still gets a mark
`computeStats`: A day with sessions but no tool calls still gets a mark.

#### Collapse dated snapshot suffixes so one model is one row
`normalizeModelName`: Collapse dated snapshot suffixes like `-20250929` so one model doesn't split across rows.

#### Calendar tolerates 23 and 25 hour days in local time
`newCalendar`: Day and hour lookups for one year in local time, tolerant of the days
that are 23 or 25 hours long.

#### Weeks start Monday as zero, as drawn
`newCalendar`: Monday is 0, as the week is drawn.

#### Concurrency count ignores runs shorter than PARALLEL_MINIMUM
`mostAtOnce`: The most runs of work under way at the same moment.

#### Persona is the trait clearing its bar by the widest margin
`persona`: The one trait that stands out most. Each candidate has a bar to clear;
the one that clears its bar by the widest margin wins, so the title says
something true of this year in particular.

### `Distribution/npm/src/terminal.mjs`

#### Project names are shown on the person's own screen
`renderTerminal`: `stats`, `grid` and `calendar` come from `computeStats`. Project names are
the person's own and are shown here, on their own screen.

#### Explain late-starting logs and how to keep future logs
`coverageNote`: Why the picture may start late in the year, and how to keep next year's
logs. Empty when the logs cover the year.

#### Days with gone logs have no hours, so get a separate mark row
`yearGrid`: Days an agent counted but whose logs are gone: no hours to place them by.

### `Distribution/npm/src/text.mjs`

#### Text rules mirror CodingAgentText.swift; only typed text is a request
Text rules shared by the Claude Code and Codex readers. They mirror
LokalBot's own readers (LokalBot/Services/CodingAgents/CodingAgentText.swift):
only what a person typed counts as a request, and only the commands an
agent ran count as actions. No text leaves this module, only counts.

#### Session-management commands say nothing about the work
`HOUSEKEEPING`: Session-management commands say nothing about the work.

#### Whole harness-written messages in the person's turn are ignored
`IGNORED_PREFIXES`: Whole messages the harness writes in the person's turn.

#### Harness tags are hyphenated or underscored, unlike pasted HTML
`IGNORED_BLOCKS`: Harness context wrapped around or beside a request. These tags are
hyphenated or underscored (`system-reminder`, `ide_selection`), unlike
HTML a person might paste into a prompt.

#### Cap words so pasted logs do not skew request length
`MAX_WORDS`: Pasted logs should not decide how wordy someone's requests are.

#### User-turn text is prompt, command, terminal, scheduled, or harness null
`classifyPrompt`: What a user-turn text is: a request the person typed (`prompt`), a slash
command (`command`), a shell command typed into the agent (`terminal`), a
run they scheduled earlier (`scheduled`), or `null` for harness text.

#### Codex puts IDE and file context above the request
`classifyPrompt`: Codex puts IDE, browser, and file context above the request.

#### An unclosed harness tag is still harness text
`classifyPrompt`: An unclosed harness tag is still harness text.

#### Output is never read; an action means the command ran, not succeeded
`actionsInCommand`: Outcomes a shell command records. Command output is never read, so an
action means the agent ran the command, not that it succeeded.

#### Truncate long commands so pasted heredocs do not stall the scan
`actionsInCommand`: A command is rarely long; a pasted heredoc should not stall the scan.

#### Codex stores commands as JSON argv; script is last element
`unwrappedShellCommand`: Codex records commands as a JSON-encoded argv such as
`["/bin/zsh","-lc","git push"]`; the script is the last element.

#### Scratch, home and checkout-only folders name no project; worktrees use repo
`projectName`: The repository a folder belongs to, or `null` when the folder names no
project: a scratch folder, the home folder, or a folder that only holds
checkouts. Agent worktrees are named for their repository.

#### Claude Code worktree layout is repo/.claude/worktrees/name
`projectName`: Claude Code: \<repo>/.claude/worktrees/\<name>

#### Codex worktree layout is ~/.codex/worktrees/id/repo
`projectName`: Codex: ~/.codex/worktrees/\<id>/\<repo>

### `Distribution/npm/src/wrapped.mjs`

#### January looks back at the year that just ended
`defaultYear`: January still looks back at the year that just ended.

#### Null dir skips an agent; undefined honours env var and default
`wrapped`: Dir options override where each agent's logs are read from; pass `null` to
skip an agent, or omit/`undefined` to honour its environment variable and
default folder. `onProgress(agentName, done, total)` reports progress.

### `Distribution/npm/test/agents.test.mjs`

#### Forked transcript copies shared records and adds one reply
`agents.test fork case`: Forked transcript copies shared records and adds one new reply.

#### Subagent user message never inflates requests
`agents.test OMP`: Subagent user message never inflates requests.

#### SQLite composer dedupes shared JSONL; CLI-only JSONL adds one session
`agents.test Cursor`: 1 composer from state.vscdb (deduping sharedId JSONL) + 1 CLI-only JSONL = 2 sessions.

#### Gemini input includes cached; output includes thoughts
`agents.test Gemini`: `input` already includes `cached`; `output` includes `thoughts`.

### `Distribution/npm/test/claude.test.mjs`

#### One API message in two records counts usage once
`claude.test`: One API message written as two records: its usage counts once.

#### Harness text in the person's turn is not a request
`claude.test`: Harness text in the person's turn is not a request.

#### Times count prompt, assistant records, tool result and reminder only
`claude.test`: The prompt, three assistant records, the tool result and the reminder; not the meta or last year's.

#### Original created first so it is credited the shared records
`claude.test fork`: The original was created first, so its records are credited to it.

#### Non-turn, non-tool-result records are not activity
`claude.test large records`: Records that are neither a turn nor a tool result are not activity.

#### A request with a pasted screenshot still counts
`claude.test large records`: A request with a pasted screenshot is still a request.

### `Distribution/npm/test/cli.test.mjs`

#### Tests never read real ~/.claude or ~/.codex
`cli.test run`: The real ~/.claude and ~/.codex are never read: every run names its folders.

### `Distribution/npm/test/codex.test.mjs`

#### Pre-year running total is baseline, not this year's use
`codex.test`: A running total from before the year is the baseline, not this year's use.

#### Patch plus file change logs count as one edit
`codex.test`: The edit is logged as a patch and again as a file change: one edit.

#### Command asked and run logs count as one commit
`codex.test`: The command is logged when asked for and again when it has run: one commit.

#### Nested subagent is credited to the person's session
`codex.test`: A subagent's own subagent is still credited to the person's session.

#### Parentless reviewer counts tokens, not hours
`codex.test`: An approval reviewer has no parent: its tokens count, its hours do not.

#### Resumed process restarts the running total
`codex.test`: Resumed in a new process: the total begins again.

#### Plain copy written last is the one read
`codex.test`: The plain copy was written last, so it is the one read.

### `Distribution/npm/test/helpers.mjs`

#### Tests write logs to a temp folder, never real agent folders
Shared by the tests. Log files are written into a temporary folder; the
tests never read the real ~/.claude or ~/.codex.

#### Tests run in UTC because fixtures are UTC and years are local
`helpers.mjs`: A year runs from midnight to midnight where the person is. The fixtures
are written in UTC, so the tests run there too.

#### Files are chosen by write time so fixtures live this year
`YEAR`: Files are chosen by when they were written, so fixtures live in this year.

### `Distribution/npm/test/render.test.mjs`

#### Late-starting logs with no earlier count still explain why
`render.test coverage`: Logs that begin late with no earlier count still explain why.

#### Codex-only year needs no note since Codex keeps logs
`render.test coverage`: A year of Codex alone has nothing to explain: Codex keeps its logs.

#### Page must fetch no script, style, image or font
`render.test page`: No script, style sheet, image or font is fetched from anywhere.

#### 20 days mirrors Claude Code's 30-day default retention
`render.test auto-zoom`: Keep only 20 days of activity to mirror Claude Code's 30-day default retention.

### `Distribution/npm/test/stats.test.mjs`

#### Fixture times show 5 minute cap on pauses and 10 minute run end
`stats.test`: +1 min, +1 min, a 7 minute pause (counts 5), then silence for 30 minutes and one more event.

#### Day already covered by logs does not add summary count
`stats.test`: The logs already cover this day, so its count is not added again.

#### One day counts once though both agents worked it
`stats.test`: Feb 3 is one day, though both agents worked on it.

#### DST days have 23 and 25 hours
`stats.test calendar`: 29 March 2026 has 23 hours there; 25 October has 25.

### `Distribution/raycast/src/answer-view.tsx`

#### First action is primary; Try Again and sources follow
`AnswerView.resultActions`: The first is the primary action; Try Again and the sources follow.

### `Distribution/raycast/src/cli.ts`

#### Fall back to app-embedded helper when configured CLI is missing
`resolveCli`: Resolve the CLI path from preferences, falling back to the helper binary
embedded inside /Applications/LokalBot.app when the configured path
(default "lokalbot-cli" on PATH) does not exist.

#### Any error except ENOENT proves the binary exists
`resolveCli`: Any error besides "binary not found" still proves the binary exists.

#### Installed LokalBot predates ask and reply subcommands
`CliOutdatedError`: The installed LokalBot predates the `ask` and `reply` subcommands.

#### Send input on stdin to keep messages out of process list
`runAsk`: Run `ask` or `reply`, optionally writing `input` to standard input (so a
message never appears in the process list). The CLI prints JSON even when
it exits with an error, so the outcome is returned rather than thrown.

#### Ignore stdin pipe errors from CLI exiting before reading input
`runAskWith`: A CLI that exits before reading its input (an old version rejecting
the subcommand) closes the pipe; the exit itself reports why.

### `Distribution/raycast/src/draft-reply.tsx`

#### Fall back to clipboard when no selection is shared
`readMessage`: Nothing selected, or the app does not share its selection.

### `Distribution/raycast/src/quick-recall.tsx`

#### Key includes index since one meeting matches several times
`quick-recall list item key`: One meeting can match several times with the same kind
(transcript lines), so the position makes the key unique.

### `Distribution/raycast/src/use-lokalbot-answer.ts`

#### Rerun CLI on request or revision change; stop it on close
`useLokalBotAnswer`: Runs `request` whenever it or `revision` changes, and stops the CLI when
the command closes. A null request waits.

#### Use a string key so the effect does not rerun each render
`useLokalBotAnswer`: A string key keeps the effect from re-running on every render.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
