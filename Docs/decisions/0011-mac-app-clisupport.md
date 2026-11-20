# 0011. Mac app: CLISupport

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/CLISupport/`, `LokalBotTests/CLISupport/`.

## Decisions

### `LokalBot/CLISupport/ActionItemsReport.swift`

#### CLI/MCP action report uses app projection; owners are names only, no emails
`ActionItemsReport`: Read-only action threads for the CLI and MCP server. It uses the app's
projection and thread clustering, so saved corrections, completion, and
deferral apply here exactly as they do in LokalBot. Owners are the names
written into outcomes; attendee emails and speaker evidence never appear.

#### Sample meeting actions are fake; listed only when asked by id
`ActionItemsReport.report`: The sample meeting's actions are made up: only listed when asked for by id.

### `LokalBot/CLISupport/AgentAccessGate.swift`

#### Marker files are cross-process truth for agent access and LLM wakeup
`AgentAccessGate`: Cross-process marker-file truth for external-agent access and LLM wakeup.

#### Authorized by global toggle or short-lived Agent Mode capability; terminal honors Privacy
`AgentAccessGate.isAuthorized`: True for the user-controlled global toggle or for an app-issued,
short-lived capability inherited by the embedded Agent Mode process.
A normal terminal invocation has no capability and must honor the
Privacy toggle just like MCP does.

#### Grant identity changes on re-enable so revoked pending answers cannot revive
`AgentAccessGate.authorizationID`: A long-running read must retain the same grant through response delivery.
Re-enabling global access issues a new identity, so it cannot revive an
answer whose original grant was revoked while inference was pending.

#### Persist only SHA-256 of capability; secret lives in environment, revoked at tab shutdown
`AgentAccessGate.issueScopedCapability`: Creates a bearer capability for one embedded Agent Mode subprocess.
Only a SHA-256 digest is persisted; the bearer secret exists in the
process environment and is revoked when the tab shuts down.

### `LokalBot/CLISupport/AgentNotesAccess.swift`

#### Note id is stable and cited as [note:id]
`AgentNoteHit.id`: Stable id of the note, cited as `[note:id]`.

#### Agent value is claude-code or codex
`AgentNoteHit.agent`: `claude-code` or `codex`.

#### Category is Claude Code's own label: user, feedback, project, reference
`AgentNoteHit.category`: Claude Code's own label: user, feedback, project, or reference.

#### Snippet marks matched words between « and »
`AgentNoteHit.snippet`: A passage around the match, the matched words between « and ».

#### agent-notes.sqlite written only by app; CLI opens read-only per call
`AgentNotesIndex`: Read side of the saved coding-agent notes: `agent-notes.sqlite` in the
library, written only by the app (`AgentMemoryStore`). Every call opens
the file read-only and closes it, so the CLI and the app can both search
while the app replaces notes.

#### bm25 column weights: title 10, summary 4, text 1
`AgentNotesIndex.rank`: Column weights for title, summary and text.

#### Match all words, fall back to any; last word prefix-matches while typing
`AgentNotesIndex.search`: Notes matching every word of `query`, best first; when none has every
word, notes matching any. The last word also matches as a prefix, so
results appear while it is typed.

#### FTS5 cannot see words inside CJK runs; use substring search
`AgentNotesIndex.search`: FTS5 cannot see words inside a run of CJK text; see `CJKSearch`.

#### Connection is query-only so no write path can grow
`AgentNotesIndex.Connection`: Query-only, so nothing here can grow a write path to the notes.

#### Agent notes grant is separate marker set from Settings; Agent Mode capability cannot satisfy it
`AgentNotesAccessGate`: Cross-process truth for the Agent notes grant: a marker the app sets from
Settings → External Agents. Separate from every other grant, and no Agent
Mode capability satisfies it.

#### Shared by CLI command and MCP tool; works without app running
`AgentNotesSearchTool`: The agent-facing search over saved coding-agent notes, shared by the CLI
command and the MCP tool. Works without the app running.

#### Notes longer than 4000 characters are cut with ellipsis
`AgentNotesSearchTool.noteCharacters`: A note longer than this is cut, with an ellipsis.

#### Refusals carry codes; bad arguments are usage errors, nil here
`AgentNotesSearchTool.Failure.commandError`: What a CLI command throws for a refusal, with its code. Nil for
bad arguments, which the command reports as a usage error.

#### Type is Claude Code's own label: user, feedback, project, reference
`AgentNotesSearchTool.Report.Item.type`: Claude Code's own label: user, feedback, project, or reference.

#### Project is the folder the note is about, when recorded
`AgentNotesSearchTool.Report.Item.project`: The folder the note is about, when the agent recorded it.

### `LokalBot/CLISupport/AgentReadAccessCopy.swift`

#### Agent messages name one Settings switch and per-kind boxes; app toggle uses same title
`AgentReadAccessCopy`: How messages to agents name the one Settings switch for reading LokalBot
data and the box for each kind under it (Settings → External Agents). The
app's toggle uses the same title.

### `LokalBot/CLISupport/AgentSetup.swift`

#### Terminal asks via short-lived request file; only app writes grants, after person allows
`AgentSetup`: The one way the terminal can ask for access: a short-lived request file in
the library's `control/` folder that the app shows to the person. Only the
app writes grant markers, and only after the person allows the request in
LokalBot. A request written by any other process gains nothing without
that click.

#### CLI setup start passes this argument when opening the app
`AgentSetup.launchArgument`: Passed by `lokalbot-cli setup start` when it opens the app.

#### CLI posts notification so running app looks for new request
`AgentSetup.notificationName`: Posted by the CLI so a running LokalBot looks for a new request.

#### Files grant searches chosen folders via search_files
`AgentSetup.Grant.files`: Search the folders chosen under Files (`search_files`).

#### Requester is CLI's view of its process tree; shown, never trusted
`AgentSetup.Request.requester`: Who asked, as the CLI saw its own process tree, for example
"lokalbot-cli via claude". Shown to the person, never trusted.

#### Grants are what person allowed; empty when declined
`AgentSetup.Answer.grants`: What the person allowed; empty when they declined.

#### Write into private 0700 control folder readable by this user only
`AgentSetup.write`: Writes into the private control folder, readable by this user only.

#### Names process and nearest non-shell ancestor for audit log and setup request
`ProcessAncestry`: Names the program behind a process: its own name and, when it runs under
a shell, the nearest ancestor that is not one, such as "lokalbot-cli via
claude". Used for the audit log and the setup request.

#### Plan settings share config export shape so config import reads them
`SetupPlan`: What `setup plan` prints and `setup apply` reads: the settings a setup
conversation covers, a model preset, and launch at login. `settings` has
the same shape as `config export`, so `config import` reads it too.

#### Setup settings listed in the order to ask the person
`SetupPlan.keys`: The settings to talk through with the person, in the order to ask.

### `LokalBot/CLISupport/AppControlApproval.swift`

#### API keys are write-only from terminal; CLI says if saved, never reads back
`AppSecret`: The API keys `lokalbot-cli secret` can set. Keys are write-only from the
terminal: the CLI can say whether one is saved, never read it back.

#### Show last four characters so person can identify key being approved
`AppSecret.hint`: The last four characters, so the person can tell which key they are
approving without seeing it.

### `LokalBot/CLISupport/AppControlClient.swift`

#### All settings reads/writes go through the app so decoding and coupling rules apply once
`AppControlClient`: Sends one request to the running app, starting the app in the background
when no copy is running for this library. Every settings read and write
goes through the app, so its decoding and coupling rules apply once.

#### Never start app for an agent the person has not allowed
`AppControlClient.request`: Never start the app for an agent the person has not allowed.

#### Protocol is one connection, one request line, one response line
`AppControlClient.send`: One connection, one request line, one response line.

#### App running means a GUI copy holds the library instance lock
`AppControlClient.isAppRunning`: True while a GUI copy holds this library's instance lock.

#### Launch app by path, never name, so CLI starts the right library copy
`AppControlClient.enclosingApp`: The LokalBot app bundle containing this executable, resolved through
the installed `~/.local/bin` symlink. Launching by path, never by
name, keeps a CLI from starting a different copy with another library.

#### Launch hidden in background; stays as normal menu-bar app
`AppControlClient.launchInBackground`: Starts the app hidden and in the background; it stays running as the
normal menu-bar app afterwards.

### `LokalBot/CLISupport/AppControlProtocol.swift`

#### Control socket: one JSON object per line, one request per connection; see CLI design doc
`AppControlProtocol`: The CLI's requests to the running app over the control socket: one JSON
object per line, one request per connection. See
Docs/designs/cli-configuration-design-2026-10-17.md.

#### CLI-started app comes up in menu bar, not main window
`AppControlProtocol.backgroundLaunchArgument`: Passed by `lokalbot-cli` when it starts the app for a request, so the
app comes up in the menu bar like a login launch instead of opening
its main window.

#### Stable error printed as [code] message, like MCP's [access_disabled]
`AppControlError`: A stable error the CLI prints as `[code] message`, like the MCP tools'
`[access_disabled]`.

#### Structured detail an agent can act on, e.g. changes needing approval
`AppControlError.details`: Structured detail an agent can act on, such as the changes that need
approval.

#### Widening change or new API key waits for the person in LokalBot
`AppControlError.needsApproval`: A widening change, or a new API key, waits for the person in LokalBot.
`details` is the request as `settings.request` reports it.

### `LokalBot/CLISupport/AppControlSocket.swift`

#### Socket in 0700 control folder; long paths fall back to per-user /tmp name both sides derive
`AppControlSocket`: Unix-domain socket plumbing shared by the app's control server and the
CLI. The socket lives in the library's 0700 `control/` folder; a root
whose path is too long for `sun_path` uses a per-user name in /tmp that
both sides derive the same way.

#### sun_path holds 104 bytes on macOS including NUL
`AppControlSocket.maximumPathBytes`: `sun_path` holds 104 bytes on macOS, including the terminating NUL.

#### Refuse a socket owned by another user
`AppControlSocket.connect`: Opens a connected client socket, refusing a socket another user owns.

#### Blocking I/O with deadline and no SIGPIPE when peer gone
`AppControlSocket.configure`: Blocking I/O with a deadline, and no SIGPIPE when the peer is gone.

### `LokalBot/CLISupport/AskLibraryContext.swift`

#### Cap per-meeting snippets in first pass so other meetings get a turn
`AskLibraryContext.maxSnippetsPerMeetingFirstPass`: Snippets one meeting may take before every other matching meeting has
had its turn; later slots go to the best remaining hits.

#### Keep short names and acronyms as search terms; drop English function words
`AskLibraryContext.searchTerms`: The question's content words. Short names and acronyms ("Ana", "API",
"Q3") count; English function words and question framing do not.

#### Meeting dates are the user's local days, like today in messages
`AskLibraryContext.build`: Meeting dates are the user's local days, like "today" in `messages`.

#### Search all content words at once so rare words rank meetings
`AskLibraryContext.build`: One search over every content word, so the rarest words rank the
meetings instead of whichever word the question happened to start with.

#### Limit each meeting to first-pass share until others have had one
`AskLibraryContext.spreadAcrossMeetings`: Distinct hits in rank order, except that no meeting takes more than
its first-pass share until every other matching meeting has had one.

#### Message is delimited data; facts only from meeting context
`AskLibraryContext.replyMessages`: The reply-drafting prompt. The message is delimited data, and facts
may come only from the meeting context, the same rule as `messages`.

### `LokalBot/CLISupport/AskLibraryEngine.swift`

#### Marker is 0600, token rotates; CLI validates PID, executable and port
`LocalLlamaServerMarker`: Shared on-disk identity and bearer contract for the private llama-server.
The marker is mode 0600, the token rotates on every subprocess start, and
CLI callers validate that its PID is alive, is the recorded executable,
and owns the expected listening port before trusting localhost.

#### Main LLM server is 127.0.0.1:17872 in the release app
`URLSessionLlamaChatClient.mainServerBaseURL`: The enclosing app's Main LLM server: 127.0.0.1:17872 for the release app.

#### Disable thinking turn so short answers fit the 1,024-token allowance
`URLSessionLlamaChatClient.complete`: The main server runs with reasoning on. A short grounded answer must
not spend its whole 1,024-token allowance thinking, so disable the
thinking turn as the app's own zero-budget requests do.

#### Friendly non-error result when library is empty or nothing matched
`AskLibraryOutcome.notFound`: A friendly non-error result: the library is empty or nothing matched.

#### MCP form appends a Sources list to the answer
`AskLibraryOutcome.toolResult`: The MCP `ask_library` form: the answer with a Sources list appended.

#### Engine owns health probe, app wake and error taxonomy; also drafts replies
`AskLibraryEngine`: Question in, local model reads the library, synthesized answer and
citations out. Owns the health probe, app wake, and error taxonomy.
The same path drafts a reply to a message from what the meetings say.

#### Nil appIsRunning reads the instance lock to detect a running app
`AskLibraryEngine.appIsRunning`: Whether a LokalBot app holds this library. Nil reads the instance lock.

#### Check access first so a disabled library says so before anything else
`AskLibraryEngine.answer`: Access comes first: a disabled library says so before anything else.

#### Retrieve by message and instruction words; no match means no draft
`AskLibraryEngine.draftReply`: Drafts the user's reply to `message` from what their meetings say.
Meetings are retrieved by the message's own words (and the
instruction's); a message nothing matches gets no draft, since the
point is to add what the user's meetings know.

#### Only a running app answers a wake, so report a closed app immediately
`AskLibraryEngine.respond`: Only a running app answers a wake, so a closed one is reported
now instead of after a minute of polling.

### `LokalBot/CLISupport/AskLibraryOutput.swift`

#### JSON separates text from sources so launchers paste drafts without Sources
`AskLibraryOutcome (CLI output)`: `lokalbot-cli ask` and `reply` output. JSON keeps the text and its sources
apart, so a launcher can paste a draft without a Sources list.

#### JSON output shape: status, optional code, text, sources
`AskLibraryOutcome.json`: `{"status": "answered" | "not_found" | "error", "code"?, "text", "sources"}`.

#### The --table form matches the ask_library MCP tool text
`AskLibraryOutcome.plainText`: The `--table` form: the same text as the `ask_library` MCP tool.

### `LokalBot/CLISupport/Briefing.swift`

#### Briefing is the first agent call; every section gated by its own permission
`Briefing`: `get_briefing` and `lokalbot-cli brief`: the one call an agent makes first,
so it knows what LokalBot holds and what it may ask before it asks the
user. A fixed-size, recency-weighted read in the spirit of OptMem's `wake`,
assembled from what LokalBot already records. Every section is gated by
the permission that already covers its data; with nothing granted, the
briefing says only which permissions are off and how to turn them on.

#### Briefing names MCP tools or CLI commands according to what the agent can reach
`Briefing.Vocabulary`: What the briefing tells the agent to call next: MCP tools for
`get_briefing`, `lokalbot-cli` commands for `brief`, so an agent that
can only run a shell isn't pointed at tools it can't reach.

#### Work memory needs permission for every source kind; unattributed items never shown
`Briefing.workMemory`: Work memory items need the permission of every kind of source behind
them: meeting access for meetings, screen access (and its history
window) for screen, activity, and digest evidence. Items without
source attribution are never shown.

#### Skip automated wake-up titles that are raw tags
`Briefing.codingAgentWork`: Automated wake-ups title a session with their raw tags.

#### Recent days in detail, older weeks and months as one line, within history window
`Briefing.timeline`: Recent days in detail, older weeks and months as one line each, all
inside the screen-memory history window.

### `LokalBot/CLISupport/CJKSearch.swift`

#### FTS5 unicode61 cannot split CJK, so CJK queries use substring matching
`CJKSearch`: Keyword search for Chinese, Japanese and Korean text.

SQLite's `unicode61` tokenizer splits on spaces and punctuation. These
scripts put no spaces between words, so an unbroken run of CJK text, and any
Latin letters glued to it, is indexed as one token, and FTS5 can match a word
only at the start of that run: "深色模式" finds "深色模式下设置页面…", but
"对比度" finds nothing. Queries that contain CJK text therefore match by
substring on the stored text. A query without CJK text that FTS finds nowhere
falls back to the same substring match, restricted to rows that contain CJK
text, so "logo" still finds "比如logo再大一点" while libraries without CJK
text see no change.

Compiled into the app and `lokalbot-cli`, so meeting search, screen search
and the MCP screen reader share one matcher.

#### GLOB class ranges compare by code point; matches isCJK within BMP
`CJKSearch.rowGlobPattern`: SQL `GLOB` pattern for text that contains CJK characters. SQLite compares
class ranges by code point, so this matches the same characters as
``isCJK(_:)`` within the Basic Multilingual Plane.

#### Cap relaxed OR terms at 8 to avoid dozens of scans
`CJKSearch.maximumRelaxedTerms`: Relaxed matching ORs at most this many pieces, so a long sentence
cannot turn one search into dozens of scans.

#### Separators include full-width punctuation; dots, hyphens, apostrophes stay in terms
`CJKSearch.separators`: Separators between search terms: whitespace, sentence punctuation and
brackets in ASCII and full-width forms. Dots, hyphens, apostrophes and
underscores stay inside a term, so "2.0.1" and "e-mail" match as written.

#### Terms are distinct and in order; every term must occur
`CJKSearch.terms`: Distinct terms of `query`, in order. Every term must occur for a match.

#### Split long CJK runs into overlapping bigrams; drop single characters
`CJKSearch.relaxedTerms`: Terms for recall-oriented (OR) matching of a spaceless question: each CJK
run of three or more characters becomes its overlapping two-character
pieces, so "下周四发布之前" can still find "下周四发布". Single CJK
characters and single Latin letters are dropped as too common, unless
nothing else is left.

#### LIKE escapes %, _ and backslash; ignores case for ASCII only
`CJKSearch.likePattern`: `LIKE` pattern that matches `term` anywhere, escaping `%`, `_` and `\`.
Use it with ``likeEscapeClause``. Like SQLite's `LIKE`, it ignores case
for ASCII letters only.

#### Snippet adds only markers and ellipses, matching FTS5 snippet contiguity
`CJKSearch.snippet`: An excerpt around the first match, with « » around every match inside
it and … where text was cut. Only the markers and ellipses are added, so
the excerpt without them is a contiguous piece of `text`, as FTS5's
`snippet()` output is. Nil when no term occurs.

#### Merge overlapping and touching matches so pieces mark one span
`CJKSearch.matchRanges`: Every occurrence of every term, sorted, with overlapping and touching
matches merged, so overlapping pieces mark one span.

### `LokalBot/CLISupport/DreamRollupFormat.swift`

#### Rollups are caches stamped by source reviews; stale ones never shown
`DreamRollupFormat`: One line per past week and month, condensed from the overnight reviews.
The app writes them (`DreamRollupService`); the CLI reads them for the
agent briefing. A rollup is a cache over the daily reviews: it records a
stamp of the reviews it was made from, and anyone reading it recomputes
that stamp, so a deleted, retracted, or regenerated review makes it stale
at once. Stale rollups are never shown and are rebuilt the next night.
Clear work memory removes them with the reviews (they live in `dreams/`).

#### Rollup key format is 2026-W41 for weeks, 2026-09 for months
`DreamRollupFormat.Rollup.key`: "2026-W41" or "2026-09".

#### Ignore review files whose embedded day mismatches the file name
`DreamRollupFormat.reviews`: Every readable review, keyed by day. A file whose embedded day does
not match its name is ignored, as the app's store does.

#### Stamp changes when a review appears, disappears or is regenerated
`DreamRollupFormat.stamp`: Changes whenever a review in the period appears, disappears, or is
regenerated.

### `LokalBot/CLISupport/FileLibraryToolProvider.swift`

#### Read tools work with app closed; ask_library delegates to injected engine
`FileLibraryToolProvider`: File-backed MCP provider. Read tools work while the app is closed;
`ask_library` delegates to an injected local-model engine.

#### Briefing is never refused; sections check their own grants
`FileLibraryToolProvider.briefing`: Never refused: with no grants it still says which permissions are off,
so an agent learns what it could ask for. Each section checks its own
grant inside `Briefing`. `lokalbot-cli brief` asks for `.cli` names.

#### File search depends only on the Files marker and folder list
`FileLibraryToolProvider.searchFiles`: Independent of meeting and screen access, and of Agent Mode
capabilities: only the Files marker and its folder list.

#### Agent notes search depends only on the Agent notes marker
`FileLibraryToolProvider.searchAgentNotes`: Independent of every other grant: only the Agent notes marker, and
the notes LokalBot saved while Read coding agent notes is on.

#### Support until filter as list does so earlier weeks can be requested
`FileLibraryToolProvider (until filter)`: As `list --until`: without it, one earlier week could not be
asked for, and newer meetings used up the limit first.

#### Refuse unknown include parts so typos don't drop sections silently
`FileLibraryToolProvider.parseInclude`: As `get --include` and `list_meetings` do, a part it does not know is
refused: a misspelt one must not come back as a meeting without that
section.

#### Over-read screen hits and dedupe repeated snippets from repeated captures
`FileLibraryToolProvider.searchScreen`: A window captured every few seconds repeats one snippet many
times; read further and keep the most relevant copy of each.

#### Re-enforce screen access cutoff on returned rows as authorization boundary
`FileLibraryToolProvider.searchScreen`: Enforce the profile again on returned rows. The SQLite reader
already applies the bound, but this keeps the authorization
boundary intact for alternate readers and future refactors.

#### Nil means outside granted scope; open-ended input stays nil when unbounded
`FileLibraryToolProvider.scopedInterval`: Nil means the requested interval sits wholly outside the granted scope.
A nil input represents an open-ended search and remains nil when access is
unbounded; callers pair it with `screenAccessCutoff` for bounded profiles.

### `LokalBot/CLISupport/FilesAccess.swift`

#### CLI reads a projection of chosen folders instead of app settings
`FilesAccessProjection`: What Files lets agents search, as the app last wrote it: the folders the
person chose. The app keeps it only while the Files grant is on and Files
is on with a folder, so the CLI never has to read the app's settings.

#### Files grant is a cross-process marker plus projection, separate from other grants
`FilesAccessGate`: Cross-process truth for the Files grant: a marker the app sets from
Settings → External Agents (or the box on Settings → Files), plus the
projection it keeps in sync with Settings → Files. Separate from every other grant,
and no Agent Mode capability satisfies it.

#### Index folder name must match FileSearchService.indexFolderName
`FilesAccessGate.indexFolderName`: Files' index in the library (`FileSearchService.indexFolderName`).

#### Revoking the Files grant also removes the folder list
`FilesAccessGate.disable`: Revoking removes the folder list too.

#### Projection is nil when grant off, Files off, or not written
`FilesAccessGate.readProjection`: The chosen folders, or nil when the grant is off, Files is off, or the
app hasn't written them.

#### Keyword search works with app closed; semantic search needs embedding model in Ask
`FilesSearchTool`: `search_files` for MCP and `lokalbot-cli search-files`: word search over
the Files index (DigUp's keyword search), which works while the app is
closed. Search by meaning needs LokalBot's embedding model, so it stays in
Ask.

#### Search looks at most 4,096 ranked matches for ones inside folders and dates
`FilesSearchTool.widestSearch`: The most ranked matches one search looks through for ones inside the
chosen folders and dates.

#### Passages longer than 1,500 characters are cut with an ellipsis
`FilesSearchTool.passageCharacters`: A passage longer than this is cut, with an ellipsis.

#### Refusals carry error codes; bad arguments are nil usage errors
`FilesSearchTool.Failure.commandError`: What a CLI command throws for a refusal, with its code. Nil for
bad arguments, which the command reports as a usage error.

#### Match both given and real folder paths since walks report real paths
`FilesSearchTool.report`: A walk reports a folder by its real path (/private/var for /var).

#### Widen the search window because folder and date filters apply after ranking
`FilesSearchTool.report`: The folders and dates are applied after ranking, so the best few
matches can all fall outside them: forty older invoices hid the
one from this month. Look further down the ranking until enough
are inside, or there is nothing more to look at.

#### EXIF DateTimeOriginal is in the camera's local time
`FilesSearchTool.exifDate`: EXIF `DateTimeOriginal`: "2026:05:14 18:02:11", in the camera's local time.

### `LokalBot/CLISupport/HelperVersion.swift`

#### Version read from enclosing app bundle for --version and MCP handshake
`HelperVersion`: Reads the enclosing app bundle's version for `--version` and the MCP
server handshake.

#### Use executable real path since PATH lookup gives bare argv[0]
`HelperVersion.current`: Defaults to the executable's real path: a shell that finds the helper
on PATH passes only the bare name as argv[0].

### `LokalBot/CLISupport/LibrarySearch.swift`

#### CLI, MCP and app all mean the user's local day, not UTC
`LibraryInputPolicy.localDay`: Start of a real local calendar day written YYYY-MM-DD. The CLI, MCP,
and the app all mean the user's day, not UTC's.

#### Word search semantics: all words, fallback partial, short words whole-word only
`LibrarySearch`: Shared word search over on-disk meeting artifacts, so the CLI and MCP
expose one behavior without needing the app's index. A meeting matches
when it contains every query word, in any order and ignoring case and
accents; when none does, meetings with the most words follow. Hits with
the exact phrase lead, ties keep meeting recency, and a quoted query
matches only its exact phrase. Words of up to three letters or digits
("api", "ana", "q3") match only whole words.

#### Cap transcript hits per meeting so one long meeting can't fill slots
`LibrarySearch.maximumTranscriptHitsPerMeeting`: One long meeting full of a common word must not fill every slot.

#### Format transcript hit start only if the hit is returned
`LibrarySearch.Candidate.start`: A transcript hit's start, formatted only if the hit is returned.

#### Byte-level prefilter skips non-matching texts without changing results
`LibrarySearch.hits`: Skips, from bytes alone, transcripts and texts that cannot match,
which saves the decode and the fold; it never changes a result.

#### Weight words by rarity across meetings so rare words rank
`LibrarySearch.hits`: A word found in few meetings says more than one found in most, so
"what did we decide about pricing" ranks by "pricing", not "we".

#### Complete-word meetings win, partial follow; Ask ranks by weight only
`LibrarySearch.hits`: Every word somewhere in the meeting wins; when no meeting has them
all, partial matches follow so a near miss is still found. A
question's filler words need not appear, so Ask ranks every meeting
by its words' weight instead.

#### Folded text is for matching only, never display
`LibrarySearch.folded`: Case- and accent-insensitive form used only for matching, never for
display: "izvestaj" finds "izveštaj" and "CAFE" finds "café".

#### Skip whitespace collapse when it would leave text unchanged
`LibrarySearch.folded`: Collapsing whitespace walks every character; skip it when it would
rebuild the text unchanged, as it does for most sentences.

#### Single spaces before ASCII make whitespace collapsing a no-op
`LibrarySearch.hasOnlySingleSpaces`: Whether the only whitespace is single spaces, none first or last and
each before an ASCII character. Such a space is either a character of
its own, which the split turns back into one space, or the end of the
character before it ("\u{600} "), which the split keeps; either way
splitting on whitespace and joining with spaces returns the text as
it was.

#### CJK runs stay one word and match inside unspaced sentences
`LibrarySearch.searchTerms`: Distinct words in query order. A run of CJK characters stays one word
and still matches inside an unspaced sentence.

#### Drop single Latin letters unless they are the whole query
`LibrarySearch.searchTerms`: A single Latin letter ("t" from "don't") matches nearly everything;
keep one only when it is the whole query.

#### Short Latin words and numbers must match whole words only
`LibrarySearch.wordRange`: The first match of `needle`; a short Latin word or number must stand
alone, since inside longer words ("rapid", "banana") it mostly matches
by accident.

### `LokalBot/CLISupport/LibrarySearchPrefilter.swift`

#### Conservative byte-level fold: a no is certain, a yes runs the matcher
`LibrarySearchPrefilter`: A conservative byte-level test that tells `LibrarySearch.hits` which
transcripts and texts cannot match, so it skips decoding and folding them.

It folds each character on its own, the way `LibrarySearch.folded` folds
whole text (case and accents), and decomposes the result. Of that, it keeps
only letters and digits. ASCII spaces and punctuation, which folding never
removes, become a separator. Every other character, such as a combining
mark, is dropped, which only joins its neighbors. The result therefore
holds every run of letters and digits the real matcher could find, so a
"no" is certain and a "yes" just runs the matcher as before.

#### Each term holds the words that must all appear
`LibrarySearchPrefilter.terms`: For each search term, the words of it that must all appear.

#### Cache non-ASCII folds; nil for combining marks whose own fold is a letter
`LibrarySearchPrefilter.foldedScalars`: What each non-ASCII character becomes, filled as characters appear.
Nil for a combining mark whose own fold is a letter (U+0345 folds to
"ι" alone but vanishes after a letter), which the test cannot place.

#### Nil when a term has unplaceable characters so nothing is skipped
`LibrarySearchPrefilter.init`: Nil when a term has a character the test cannot reason about, such as
a combining mark or punctuation only, so nothing may be skipped.

#### Answer yes for non-plain-UTF-8 JSON since the decoder may still read it
`LibrarySearchPrefilter.mayMatch(transcriptJSON:)`: Whether a `"text"` value in transcript JSON could contain one of the
terms. Answers yes for anything it cannot read as plain UTF-8 JSON,
such as UTF-16 or a `\u` escape, since the decoder may still read it.

#### UTF-16 and UTF-32 JSON always contain zero bytes; UTF-8 never does
`LibrarySearchPrefilter.mayMatch(transcriptJSON:)`: UTF-16 and UTF-32 JSON always holds zero bytes; UTF-8 never does.

#### Collect only text-key values; false for content it cannot reason about
`LibrarySearchPrefilter.appendTextValues`: Appends every string value whose key is `"text"`. False when the bytes
hold something the test cannot reason about.

#### Closing quote follows an even run of backslashes
`LibrarySearchPrefilter.appendTextValues`: The closing quote is the first one after an even run of backslashes.

#### JSON escapes are two-byte ASCII; false for non-UTF-8 or unplaceable characters
`LibrarySearchPrefilter.appendText`: Appends what `bytes[start..<end]` folds to. With `jsonEscapes`, a
backslash starts a two-byte escape (`\u` excluded by the caller), each
of which stands for ASCII punctuation or whitespace. False when the
bytes are not UTF-8 or hold a character the test cannot place.

#### ASCII and escapes write at most one byte per byte read
`LibrarySearchPrefilter.appendText`: ASCII and escapes write at most one byte per byte read.

#### Non-ASCII folds never yield separators; combining marks add nothing
`LibrarySearchPrefilter.fold`: The letters and digits `scalar` folds to on its own, decomposed. Never
a separator: a character outside ASCII may vanish in context. A
combining mark folds with the letter before it, usually to nothing, so
it adds nothing; nil when its own fold is a letter.

#### Needles keep only characters that don't attach to the previous one
`LibrarySearchPrefilter.isKeptInNeedle`: Lowercase ASCII letters and digits, and other letters and digits that
do not attach to the character before them.

#### Reuse one growable output buffer for every text
`LibrarySearchPrefilter.Output`: Growable bytes the folded text is written to, reused for every text.

### `LokalBot/CLISupport/LibraryToolProvider.swift`

#### Failure codes are stable and machine-readable for MCP tool calls
`ToolErrorCode`: Stable machine-readable failure codes for MCP tool calls.

#### CLI refusals print [code] message like MCP, ask and settings commands
`CodedCommandError`: A refusal a CLI command prints as `[code] message`, the form the MCP
tools, `ask` and the settings commands use, so an agent can tell which
switch is off whichever way it asked.

#### Provider separates MCP wire layer from the meeting library owner
`LibraryToolProvider`: Separates the MCP wire layer from the owner of the meeting library.

### `LokalBot/CLISupport/LlamaServerRole.swift`

#### Each app copy gets its own ports and helper folder after orphan embedder incident
`LocalRuntimeOwner`: Which copy of LokalBot owns a set of local helpers. Each copy gets its own
llama-server ports and its own folder for helper binaries, PID markers and
bearer tokens, so a helper one copy leaves behind cannot hold a port the
installed app needs. (2026-10-09: an orphaned UI Test Host embedder held
17873 for days and the installed app's embeddings silently stopped.)

#### Release covers installed app, embedded CLI and release-identity Xcode builds
`LocalRuntimeOwner.release`: The installed app, its embedded CLI, and release-identity builds run
from Xcode build products.

#### Unit test host shares release bundle id; only this case isolates it
`LocalRuntimeOwner.unitTests`: The LokalBotTests host. It carries the release bundle id, so only this
case keeps it away from the installed app's helpers and markers.

#### Port offsets in blocks of ten leave room for new roles
`LocalRuntimeOwner.portOffset`: Added to every release port. Blocks of ten leave room for new roles.

#### Ports follow the owning copy; residency ids follow the role
`LlamaServerRole`: The bundled llama-server instances. Ports follow the owning copy; residency
ids follow the role, so the model ledger and the Resource Monitor read the
same in every copy.

#### Media embedder indexes Files folders; searches embed words on embedder
`LlamaServerRole.mediaEmbedder`: EmbeddingGemma 2 with its image and audio projector, for indexing the
folders chosen under Files. Searches embed their words on `embedder`.

#### qwenASR is Qwen3-ASR 1.7B, matching QwenLlamaASR.accuracy
`LlamaServerRole.qwenASR`: Qwen3-ASR 1.7B with its audio projector (`QwenLlamaASR.accuracy`).

#### Compact Qwen ASR has its own server because tiers can run concurrently
`LlamaServerRole.qwenASRCompact`: Qwen3-ASR 0.6B (`QwenLlamaASR.compact`). Its own server, because
dictation and meetings can use different tiers at the same time.

#### Release ports are relied on by CLI, MCP clients and docs; never move
`LlamaServerRole.releasePort`: The installed app's ports. The CLI, MCP clients and DEVELOPMENT.md
rely on them, so they never move.

#### Residency id is the role's row in the ModelResidency ledger
`LlamaServerRole.residencyID`: The role's row in the model-memory ledger (`ModelResidency`).

### `LokalBot/CLISupport/LokalBotCLIInstaller.swift`

#### Binary stays symlinked into app for Sparkle updates; skills linked or copied
`LokalBotCLIInstaller`: Installs the bundled CLI and skill for shell agents. The binary always
stays symlinked into the app so Sparkle updates keep it current; skills can
be linked or copied. Both ~/.agents/skills and ~/.claude/skills are served.

#### Resolve bundle from real helper path since PATH gives bare argv[0]
`LokalBotCLIInstaller.fromCurrentBinary`: Resolves the app bundle from the embedded helper's own path. A shell
that finds the helper on PATH passes only the bare name as argv[0].

#### Finish all copies and links before touching existing installation
`LokalBotCLIInstaller.install`: Finish every copy/link before touching any current installation.

#### Uninstall removes only links and copies stamped by this installer
`LokalBotCLIInstaller.uninstall`: Removes only LokalBot links and copies stamped by this installer.

### `LokalBot/CLISupport/MCPDispatcher.swift`

#### Initialize instructions tell models to orient before asking the user
`MCPDispatcher.instructions`: Sent with `initialize` so clients that surface server instructions
tell the model to orient itself before asking the user.

### `LokalBot/CLISupport/MCPProtocol.swift`

#### Codable tree encodes in one pass; literal conformances keep schemas readable
`JSONValue`: Minimal JSON model for JSON-RPC params, results, and tool schemas.
Codable so a whole response tree encodes in one pass; the literal
conformances keep dispatcher code and tool schemas readable.

#### Reject integers beyond Double-safe range and never trap
`JSONValue.intValue`: JSON numbers use Double here. Reject the range where decoding
can silently change an integer's identity, and never trap.

#### Buffer never grows on unterminated records; oversized lines are discarded to LF
`MCPStdioLineReader`: Incremental newline-delimited stdin reader for the MCP helper. Its buffer
never grows with an unterminated record: once the byte limit is crossed it
reports one rejection and discards bytes until LF/EOF without constructing
an oversized `String`.

#### Read what's available because read(upToCount:) blocks for full count on pipes
`MCPStdioLineReader.readAvailable`: Whatever is available now, up to `chunkBytes`; empty only at EOF.
`FileHandle.read(upToCount:)` waits for the full count on a pipe, so a
client that keeps stdin open and sends one short request never got a
reply.

#### Nil id means notification; server must not answer
`MCPRequest.id`: nil means a notification and the server must not answer it.

#### Responses use deterministic key order
`MCPResponse`: Encodes newline-delimited JSON-RPC 2.0 responses with deterministic keys.

### `LokalBot/CLISupport/PeopleReport.swift`

#### CLI/MCP directory exposes names only; attendee emails stay private join keys
`PeopleReport`: Read-only People directory for the CLI and MCP server, built with the
same rules as the app. Only names appear; attendee email addresses are
used as private join keys and never leave the directory builder.

#### Exclude sample meeting because its people are invented
`PeopleReport.people`: The sample meeting's people are made up.

#### Match opaque id, then exact name, then unique substring
`PeopleReport.find`: Opaque id, exact name, then a unique case-insensitive substring match.

### `LokalBot/CLISupport/PersonalContextAccess.swift`

#### Claim kinds are shared by app model and CLI, which sees only shared claims
`PersonalClaimKind`: What a personal claim is about. Shared by the app's personal model and the
CLI, which only ever sees claims the person chose to share.

#### App and CLI rank claims with the same rules via one protocol
`PersonalContextItem`: The fields relevance ranking needs, so the app (all claims) and the CLI
(the shared projection) rank with the same rules.

#### Priority order: always-use, principles/preferences, matching facts/goals, rest; newest first
`PersonalContextSelection`: Deterministic priority order for a task or question, newest first within
each step:
1. items marked Always use;
2. principles and preferences, which apply to most tasks;
3. facts and goals sharing a content word with the query, most shared
   words first;
4. the remaining facts and goals.

#### Stable sort by shared-word count keeps newest-first among ties
`PersonalContextSelection.ordered`: Stable sort by shared-word count keeps newest-first among ties.

#### Fold case and diacritics, 3+ letters, minus stopwords, any script
`PersonalContextSelection.contentWords`: Case- and diacritic-folded words of three or more letters, minus
stopwords. Works for any script, so Serbian Latin and Cyrillic match
themselves.

#### CLI never reads encrypted model; plaintext copy exists only while grant on
`PersonalContextProjection`: The claims a person shared with agents, as the app last wrote them. The
CLI never reads the encrypted personal model: this plaintext copy exists
only while the Personal context grant is on and holds only shared claims.

#### Typing source covers text typed to a coding agent or in Ask
`PersonalContextProjection.Claim.Source.learnedFromTyping`: From something the user typed to a coding agent or in Ask.

#### Work-memory source is a goal or project the overnight review kept for weeks
`PersonalContextProjection.Claim.Source.learnedFromWorkMemory`: A goal or project LokalBot's overnight review kept for weeks.

#### Personal context grant is separate; no Agent Mode capability satisfies it
`PersonalContextAccessGate`: Cross-process truth for the Personal context grant: a marker the app sets
from Settings → External Agents or Personal Context, plus the projection it keeps in sync. Separate
from meeting and screen access, and no Agent Mode capability satisfies it.

#### Revoking removes the shared projection so nothing lingers on disk
`PersonalContextAccessGate.disable`: Revoking removes the shared copy too, so nothing lingers on disk.

#### Return nil when grant is off or projection unreadable
`PersonalContextAccessGate.readProjection`: The shared claims, or nil when the grant is off or the app hasn't
written a readable projection.

#### One tool serves MCP get_personal_context and lokalbot-cli personal-context
`PersonalContextTool`: `get_personal_context` for MCP and `lokalbot-cli personal-context`.

#### Refusals map to coded CLI errors; bad arguments stay usage errors
`PersonalContextTool.Failure.commandError`: What a CLI command throws for a refusal, with its code. Nil for
bad arguments, which the command reports as a usage error.

### `LokalBot/CLISupport/ScreenMemoryAccessGate.swift`

#### Screen-memory gate must not reuse AgentAccessGate; meeting access never grants it
`ScreenMemoryAccessGate`: Cross-process marker-file truth for the more-sensitive screen-memory scope.

This deliberately does not reuse `AgentAccessGate`. Enabling meeting-library
access, or issuing an Agent Mode meeting capability, must never grant access
to window titles, OCR text, activity blocks, or screenshot metadata.

#### Empty marker from old binary gate keeps legacy authorization until user picks profile
`ScreenMemoryAccessGate.profile`: An empty marker was written by the earlier binary gate. Preserve
that user's existing authorization until they choose a profile.

#### Method parallels AgentAccessGate but accepts no environment-borne meeting capability
`ScreenMemoryAccessGate.isAuthorized`: Kept as a method to parallel `AgentAccessGate` at call sites while
intentionally accepting no environment-borne meeting capability.

#### Harden existing control directory explicitly; createDirectory does not reapply attributes
`ScreenMemoryAccessGate.enable`: `createDirectory(attributes:)` does not re-apply attributes when the
shared control directory already exists (for example after enabling
meeting access first), so harden the existing directory explicitly.

#### No wake watcher or inference lease; screen tools are read-only SQLite queries
`ScreenMemoryAccessManager`: Small app-side owner for the independent screen-memory marker.

Unlike `AgentAccessManager`, this has no wake watcher or inference lease:
every screen-memory MCP tool is a read-only SQLite query that works while
the app is closed.

### `LokalBot/CLISupport/ScreenMemoryReader.swift`

#### Lives in CLISupport so read-only DB layer avoids app-only digest types
`ScreenMemoryTextContext`: Full retained text for one capture. This lives in CLISupport so the shared
read-only database layer does not depend on app-only digest model types.

#### Truncation flag means list stopped at limit; lists are oldest first
`ScreenMemoryTimeline.activityTruncated`: True when that list stopped at the request's limit. Both lists are
oldest first, so the rest of the interval follows their last item.

#### Briefing shows only where work happened and outcome, never prompts or contents
`ScreenMemoryAgentSession`: One saved coding-agent burst, reduced to what an agent briefing shows:
where the work happened and what came out of it, never the prompts,
replies, or file contents.

#### One coding-agent session is stored as several activity bursts
`ScreenMemoryAgentSession.sessionID`: One coding-agent session is stored as several activity bursts.

#### Read-only query seam shared by MCP and daily evidence loader
`ScreenMemoryReading`: Read-only query seam shared by MCP and the canonical daily evidence loader.

#### Returns Claude Code and Codex bursts begun in interval, newest first
`ScreenMemoryReading.agentSessions`: Saved Claude Code and Codex bursts that began in the interval,
newest first.

#### Open SQLite read-only per request; never migrate or expose screenshot paths or pixels
`SQLiteScreenMemoryReader`: Opens LokalBot's SQLite store in `SQLITE_OPEN_READONLY` mode for every
request. It never creates or migrates schema and never exposes screenshot
file paths or decrypted pixels.

#### Skip scheduled runs, matching CodingAgentBurst.isScheduledRun
`SQLiteScreenMemoryReader.agentSessions`: Runs started by a schedule, not the person (as in
`CodingAgentBurst.isScheduledRun`), aren't their recent work.

#### FTS5 misses words inside CJK runs, so use substring search
`SQLiteScreenMemoryReader.search`: FTS5 cannot see words inside a run of CJK text; see `CJKSearch`.

#### Latin word glued to CJK is part of that token; fall back to substring
`SQLiteScreenMemoryReader.search`: A Latin word glued to CJK text ("比如logo再大") is part of that run's token.

#### Substring search ranks by matched terms then recency, snippets from stored text
`SQLiteScreenMemoryReader.substringSearch`: Substring counterpart of `ftsSearch`: any term in the text or window
title, ranked by how many terms matched and then by recency, with
snippets built from the stored text.

#### Fetch one row past limit to distinguish cut from complete list
`SQLiteScreenMemoryReader.timeline`: One row past the limit tells a cut list from a complete one.

#### Tables are created lazily, so check existence on fresh installs
`SQLiteScreenMemoryReader.daySummary`: Tables are created lazily by their writers, so a fresh install's
database can legitimately have none of them yet.

#### Keep wrapper private so CLI code cannot grow a write path
`ReadOnlySQLiteConnection`: Minimal query-only SQLite wrapper. Keeping it private prevents other CLI
code from accidentally growing a write path to the user's screen history.

#### Interpolated table and column names are internal constants only
`ReadOnlySQLiteConnection.columnExists`: Table and column names are internal constants at every call site.

### `LokalBot/CLISupport/SessionFormatter.swift`

#### Three output shapes: JSON default, text table, tagged Markdown; pure for testing
`SessionFormatter`: Renders `Meeting` lists and individual sessions for the CLI in three
shapes: JSON (default — easy for agents to consume), plain-text table
(for humans), and combined Markdown (the in-app export plus tagged
transcripts so `[user]` / `[transcript]` are distinguishable).

Mirrors Seminarly's `SessionFormatter`. Pure value-in / string-out so it
can be unit-tested without the file system.

#### Output-limited clients read transcripts in character windows; nil returns whole
`SessionFormatter.GetOptions.transcriptCharacters`: Clients with an output limit (MCP) read a long transcript in
windows: entries from `transcriptFrom` on, up to this many
characters. Nil returns the whole transcript, as the CLI does.

#### Listed summaries share one character budget; short ones leave room for long
`SessionFormatter.listSummaryBudget`: `list --include summary` (MCP: `list_meetings` with `include`): the
listed summaries share one character budget, so ten hour-long
meetings fit a small model's context. A short summary comes whole and
leaves the rest of its share to longer ones; a cut one ends in "…"
with `summary_truncated`, and `get` reads it whole.

#### Metadata always included; transcripts are read per meeting with get
`SessionFormatter.listIncludesSummary`: Whether `list --include` (MCP `include`) asks for summaries. Entries
always carry metadata, so `metadata` changes nothing; transcripts are
read one meeting at a time with `get`.

#### Shortest first, each takes needed up to equal split of remainder and cap
`SessionFormatter.summaryShares`: Shortest first, each takes what it needs up to an equal split of
what is left (and at most `cap`), so short summaries leave room for
long ones.

#### Cut at last line break if it keeps half, then add ellipsis
`SessionFormatter.shortened`: The text when it has at most `limit` characters; otherwise its start,
cut at the last line break when that keeps at least half, and "…".

#### Always keep first entry so paging transcripts makes progress
`SessionFormatter.transcriptWindow`: Whole entries from `start` on, up to `maxCharacters`; `nextFrom` is the
stamp of the first entry left out. The first entry is always kept, so a
caller paging through a transcript always makes progress.

#### Accepted stamp formats: HH:MM:SS, MM:SS, or plain seconds
`SessionFormatter.seconds(fromStamp:)`: Seconds for "HH:MM:SS", "MM:SS", or a plain number of seconds.

#### match_kind values are title, summary or transcript
`SessionFormatter.SearchHit.match_kind`: "title" | "summary" | "transcript"

#### Transcript hit timestamps use HH:MM:SS format
`SessionFormatter.SearchHit.timestamp`: "00:14:32" for transcript hits

#### Sample flag only on LokalBot's made-up sample meeting with synthetic voices
`SessionFormatter.SearchHit.sample`: Only on LokalBot's sample meeting: made up, with synthetic voices.

### `LokalBot/CLISupport/SessionLookup.swift`

#### Shared read-only lookups, pure Foundation to keep CLI binary light
`SessionLookup`: Read-only lookups over the on-disk meeting library. Shared by the app and
the embedded `lokalbot-cli` so a single source of truth resolves paths,
short IDs, and "latest". Pure Foundation — no AppKit / SwiftUI deps so the
CLI binary stays light.

#### Hard-coded app bundle id lets CLI resolve app library; honors storage-root override
`SessionLookup.storageRootURL`: The app's meeting library. `AppDirectories` hard-codes the app's bundle
id (not `Bundle.main.bundleIdentifier`) so the CLI process, whose own
bundle id differs, resolves the same library the app writes — and it
honors the `LOKALBOT_STORAGE_ROOT` override, so the CLI can be pointed
at an isolated test library exactly like the app.

#### Short ID is stable lowercase 8-character UUID prefix accepted by get
`SessionLookup.shortID`: 8-character truncation of a Meeting's UUID — what `list` prints and
what `get <id>` accepts. Stable, case-insensitive.

#### Newest first; read-only, orphan repair stays in StorageManager
`SessionLookup.loadAllMeetings`: All meetings, newest first. Orphan repair (closing in-progress meetings
from the audio mtime) lives in `StorageManager` and isn't run here —
this is read-only on purpose.

#### Root-explicit variant avoids mixing production library into isolated output
`SessionLookup.loadAllMeetings(root:)`: Root-explicit variant for exporters and isolated-library callers. This
avoids accidentally mixing the default production library into output
generated for a caller-supplied storage root.

#### Match short prefix, full UUID or latest; ambiguous prefix returns nil
`SessionLookup.find`: Find by short ID (8-char prefix), full UUID string, or the literal `"latest"`.
Returns nil if no match or the short prefix is ambiguous.

#### Resolve root once per batch because resolving reads the environment
`SessionLookup.folderURL(for:root:)`: A caller reading many meetings resolves `root` once, since resolving
it reads the environment.

#### List reports only presence of summary or transcript without reading it
`SessionLookup.hasSummary`: Whether a meeting has a summary or a transcript to read, without
reading it: `list` reports only that, for every meeting it lists.

#### Raw transcript.json lets callers skip decoding based on its bytes
`SessionLookup.transcriptData`: The raw `transcript.json`, for callers that can tell from its bytes
that they need no decode.

### `LokalBot/CLISupport/SettingChange.swift`

#### Only preference and narrowing apply directly; widening needs in-app approval
`SettingChangeClass`: How one requested change is authorized. Only `preference` and `narrowing`
changes apply directly; `widening` needs the person's approval in the app.

#### Command-line values parse to config-get form; lists and structures accept JSON
`SettingSpec.parse`: Reads a value typed on the command line into the form `config get`
prints: tokens for choices, numbers, booleans, lists. Lists and
structured values also accept JSON.

#### Checks type, range and choice; app decoder still has last word
`SettingSpec.stored(fromPresented:)`: The value `AppSettings` stores for a presented value, after type,
range, and choice checks. The app's decoder still has the last word.

#### Consent setting widens when it captures, reads, records, keeps or sends more
`SettingSpec.classify`: Whether a change from `old` to `new` (both stored values) can apply
directly. A consent setting widens when it captures, reads, records,
keeps, or sends more; narrowing it is always allowed.

#### Requiring calendar match narrows auto-recording; dropping it widens
`SettingSpec.widens requireCalendarForBrowser`: Requiring a calendar match narrows auto-recording; dropping it widens.

#### Retention changes always need person's decision; shorter goes through reviewed cleanup
`SettingSpec.widens retentionDays`: Longer retention keeps more; shorter deletes, which goes through
the reviewed cleanup. Either way the person decides.

#### Later download sources add third-party hosts; only moving toward Hugging Face narrows
`SettingSpec.widens modelDownloadSource`: Each later source puts another third-party host ahead of the
earlier ones (ModelScope, then HF-Mirror, then Hugging Face), so
only moving back toward Hugging Face narrows.

#### Later companion history choices share more with paired devices
`SettingSpec.widens companionHistory`: Choices run from the shortest window to all history, so a later
choice shares more with paired devices.

#### Removing an exclusion entry widens capture or suggestions
`SettingSpec.widens commaSeparated`: Exclusions: removing an entry captures or suggests in more places.

#### New export or routine folder writes outside the library
`SettingSpec.widens path`: A new export or routine folder writes outside the library.

#### Adding an approved origin sends data to a new place
`SettingSpec.widens textList`: Approved origins: adding one sends data to a new place.

#### Plan is pure so app and tests share it; app then applies
`SettingsChangePlan`: What a `settings.set` request would do to the current settings: the
stored value each key gets and how each change is authorized. Pure, so the
app and the tests share it; the app then decodes and applies the result.

#### Nil removes key for optional setting reset to default
`SettingsChangePlan.Item.stored`: Nil removes the key, for an optional setting reset to its default.

#### Redacted URLs written back must not strip user info or query from real value
`SettingsChangePlan.plan`: `config list` and `export` show URLs without user info or query.
Writing that form back must not strip them from the real value.

#### Reclassify reviewed items from current settings with same keys and values
`SettingsChangePlan.rebasing`: Reviewed items again, from the settings as they are now: the same keys
and values, each classified from its current value.

#### Widens if a widening change was unreviewed or starts from another value
`SettingsChangePlan.widens(beyond:)`: Whether this plan widens something `reviewed` did not show: a widening
change that was not on it, or one that now starts from another value.

### `LokalBot/CLISupport/SettingRegistry.swift`

#### Mirrors AppState.SettingsTab without depending on app target
`SettingCategory`: Where a setting lives in Settings. Mirrors `AppState.SettingsTab` without
depending on the app target, so the CLI can group and describe settings.

#### Tier decides how terminal changes are authorized once external agents allowed
`SettingTier`: How a terminal change to a setting is authorized once the person allows
external agents to change settings.

#### Preference tier changes nothing captured, read, recorded or sent
`SettingTier.preference`: Changes nothing about what is captured, read, recorded, or sent.

#### Widening consent needs in-app approval; narrowing is a preference
`SettingTier.consent`: Widening it (turning it on, raising it, removing an exclusion,
approving an origin) needs the person's approval in the app.
Narrowing it is a preference.

#### Read-only settings are shown, never changed from terminal
`SettingTier.readOnly`: Shown, never changed from the terminal.

#### Token is stable agent-facing value; stored is what AppSettings keeps
`SettingChoice`: One allowed value: the stable token agents read and write, and the value
`AppSettings` stores for it (some enums store display strings or key codes).

#### Nested values are reported as stored
`SettingKind.structured`: A nested value (a shortcut, a model description) reported as stored.

#### Key is stored coding key, matching Settings search settings.\<key>
`SettingSpec`: One persisted `AppSettings` key as the terminal sees it. The key is the
stored coding key, which Settings search already uses as `settings.<key>`.

#### Choice values become tokens; unmatched stored values returned unchanged
`SettingSpec.presented`: The stored value presented to agents: choice values become tokens.
A stored value that matches no known choice is returned unchanged.

#### Registry covers every key; AppSettingsRegistryTests keeps it complete and choices identical
`SettingRegistry`: Every persisted `AppSettings` key, for `lokalbot-cli config` and the app's
control channel. `AppSettingsRegistryTests` keeps this table complete and
its choices identical to the real enums.

#### Bookkeeping keys are never listed or changed
`SettingRegistry.internalKeys`: Coding keys that are bookkeeping, not settings: never listed or changed.

#### Match every query word across key, title, aliases, summary, category; best first
`SettingRegistry.search`: Settings matching every word of the query in the key, title, aliases,
summary, or category, best matches first.

#### CLI cannot compile AppLanguage; SettingRegistryTests keeps list in step
`SettingRegistry.general appLanguage`: The CLI target doesn't compile AppLanguage; SettingRegistryTests keeps
this list in step with AppLanguage.allCases.

### `LokalBot/CLISupport/SettingsControlGate.swift`

#### Settings-control grant is separate from meeting and screen access; only app writes it
`SettingsControlGate`: Cross-process marker for "Allow external agents to change LokalBot
settings". Only the app writes it, from the Privacy toggle.

Like `ScreenMemoryAccessGate`, this is deliberately separate: meeting or
screen access never grants settings access, and this grant never grants
either of them.

#### Existing control directory keeps old mode unless explicitly hardened
`SettingsControlGate.enable`: An existing shared control directory keeps its old mode otherwise.

### `LokalBot/CLISupport/SettingsSnapshot.swift`

#### Reports registry keys with tokens and redacted URLs; pure for CLI and tests
`SettingsSnapshot`: Turns encoded `AppSettings` into what `config list` and `config get`
report: registry keys only, choice values as tokens, URLs without user info
or query. The app encodes its live settings and fresh defaults; this stays
pure so the CLI target and tests can share it.

### `LokalBotTests/CLISupport/AgentAccessGateTests.swift`

#### Error codes are what the skill and AGENT_SETUP.md tell agents to look for; Windows/Linux CLI matches
`AgentAccessGateTests.testACommandRefusedForASwitchThatIsOffNamesItsCode`: The skill and AGENT_SETUP.md tell agents to look for these codes, and
the Windows and Linux CLI prints the same ones.

### `LokalBotTests/CLISupport/AgentSetupTests.swift`

#### Runs against a real AppState in a temp library; nothing prompts or restarts
`AgentSetupTests`: `setup start` requests as the app reads and answers them, and the setup
methods an agent uses afterwards. Runs against a real `AppState` in a
temporary library; nothing here prompts or restarts.

#### Coding-agent evidence choice must be shown by agents as setup in the app does
`AgentSetupTests.testThePlanCoversTheSetupSettingsAndAPresetForThisMac`: Setup in the app shows this choice with the other capture choices;
an agent walking the person through the plan has to show it too.

#### The printed plan is what setup apply reads
`AgentSetupTests.testThePlanCoversTheSetupSettingsAndAPresetForThisMac`: The printed plan is what setup apply reads.

### `LokalBotTests/CLISupport/AskLibraryContextTests.swift`

#### Cache planning starts 2026-05-28 20:26 UTC, already May 29 in Tokyo
`AskLibraryContextTests.testMeetingDatesAreTheUsersLocalDays`: Cache planning starts 2026-05-28 20:26 UTC: already May 29 in Tokyo.

### `LokalBotTests/CLISupport/AskLibraryEngineTests.swift`

#### appRunning nil reads the library instance lock, as the CLI does
`AskLibraryEngineTests.makeEngine`: `appRunning: nil` reads the library's instance lock, as the CLI does.

#### Closed app is reported at once; it used to wait 60 one-second polls
`AskLibraryEngineTests.testAClosedAppIsReportedWithoutWaitingForAWake`: With the app closed nothing consumes a wake, so the answer is
immediate. It used to come after 60 one-second polls.

### `LokalBotTests/CLISupport/BriefingTests.swift`

#### Each briefing section appears only under the permission covering its data, inside the screen window
`BriefingTests`: `get_briefing` / `lokalbot-cli brief`: every section appears only under
the permission that already covers its data, inside the screen window.

#### Fixture: two bursts of one session naming the same pull request
`BriefingTests`: Two bursts of one session, naming the same pull request.

#### Due date resolves in the Mac's time zone, so only check it is shown
`BriefingTests.testMeetingAccessAloneShowsMeetingsActionsAndMeetingOnlyWork`: The due date resolves in the Mac's own time zone, so check only that it is shown.

#### Screen and digest evidence need the screen grant; unattributed items never show
`BriefingTests.testMeetingAccessAloneShowsMeetingsActionsAndMeetingOnlyWork`: Screen and digest evidence need the screen grant; unattributed items never show.

#### Two sentences for yesterday, one for older days, then weeks, then months
`BriefingTests.testAllGrantsShowEverySectionAtDecreasingDetail`: Two sentences for yesterday, one for older days, then weeks, then months.

#### Line whose reviews changed is stale; a month covered by shown weeks is skipped
`BriefingTests.testAllGrantsShowEverySectionAtDecreasingDetail`: A line whose reviews changed is stale; a month the shown weeks cover is skipped.

#### Screen evidence last seen yesterday is outside the window; meeting-only work is not
`BriefingTests.testTodayOnlyScreenWindowClampsTimelineAgentsAndScreenWork`: Screen evidence last seen yesterday is outside the window; meeting-only work is not.

#### CLI brief runs in a shell so it names commands, not MCP tools
`BriefingTests.testBriefNamesCLICommandsWhereGetBriefingNamesTools`: `lokalbot-cli brief` runs in a shell, so it names commands, not MCP
tools; everything else matches `get_briefing`.

#### Same night writes nothing more; the next night rebuilds stale rollups
`DreamRollupServiceTests.testRegeneratedReviewMakesItsLinesStaleAndTheyAreRebuilt`: The same night writes nothing more; the next night rebuilds it.

### `LokalBotTests/CLISupport/CJKKeywordSearchTests.swift`

#### unicode61 indexes CJK runs as one token, so words mid-phrase were not found
`CJKKeywordSearchTests`: SQLite's unicode61 tokenizer indexes an unbroken run of CJK text as one
token, so keyword search found a Chinese word only at the start of a phrase:
深色模式 matched 深色模式下设置页面…, but 对比度 and 三台设备 matched nothing.

#### Relaxed OR mode matches two-character pieces of a spaceless question and ranks by overlap
`CJKKeywordSearchTests.testRelaxedSearchRanksTheBestChineseMatchFirst`: The chat tool retries a natural-language question in relaxed (OR) mode.
A spaceless Chinese question is one long term, so its two-character
pieces are matched instead and the passage sharing the most ranks first.

#### Substring fallback runs only when FTS finds nothing, only over CJK rows
`CJKKeywordSearchTests.testLatinWordGluedToChineseIsFoundWithoutSubstringMatchingEnglish`: A Latin word glued to Chinese text is part of that run's token. The
substring fallback runs only when FTS finds nothing, and only over rows
that contain CJK text, so English rows never match by substring.

### `LokalBotTests/CLISupport/CJKSearchTests.swift`

#### Relaxed terms are two-character pieces, bounded so a long sentence is one scan
`CJKSearchTests.testRelaxedTermsTurnASpacelessQuestionIntoTwoCharacterPieces`: A spaceless question is one long term; relaxed matching ORs its
two-character pieces instead, bounded so a long sentence stays one scan.

#### Ask keyword passage strips markers and must be a contiguous source piece like FTS5 snippet
`CJKSearchTests.testSnippetMarksMatchesAndStaysAContiguousPieceOfTheSource`: Ask's keyword passage strips « », … and requires the rest to be a
contiguous piece of the source, as FTS5's snippet() output is.

### `LokalBotTests/CLISupport/FileLibraryToolProviderTests.swift`

#### Read-only CLI/MCP projection works before the app repairs an interrupted undo
`FileLibraryToolProviderTests.testMeetingToolsHideMergedSourcesAndRestoreThemAfterUndo`: Read-only CLI/MCP projection also works before the app repairs an
interrupted undo on its next launch.

#### include summary returns several summaries in one call sharing one character budget
`FileLibraryToolProviderTests.testListMeetingsIncludesSummariesWithinOneBudget`: `list --include summary` / `list_meetings` `include`: several
meetings' summaries in one call, sharing one character budget.

#### Budget numbers must match the Rust CLI's list_summaries_share_one_budget
`FileLibraryToolProviderTests.testListSummariesShareOneBudget`: The same numbers as the Rust CLI's `list_summaries_share_one_budget`.

#### Misspelt include part is refused, not returned as a meeting without that section
`FileLibraryToolProviderTests.testGetMeetingRefusesIncludeValuesItDoesNotKnow`: A misspelt part came back as the meeting without that section, as if
it had none. The message is the Windows and Linux server's.

### `LokalBotTests/CLISupport/FilesAccessTests.swift`

#### The folder walk reports the real path, /private/var for /var
`FilesAccessTests.testFindsFilesByTheirWordsOnlyInsideTheChosenFolders`: The walk reports the real path (/private/var for /var).

#### Folders and dates apply after ranking; a limit of 1 hid in-folder matches
`FilesAccessTests.testAMatchRankedBelowOnesOutsideTheChosenFoldersIsStillFound`: Folders and dates are applied after ranking. With a limit of 1 the
search looked at the best four matches only; when those were all in a
folder agents may not search, a match in the chosen folder was never
seen and the answer was "nothing". The eight files outside hold both
words of the query and the one inside holds one, so it ranks last.

#### Bag-of-words vectors: the agent search never uses them, the index needs them
`WordsEmbedder`: Bag-of-words vectors; the agent search never uses them, the index needs them.

### `LokalBotTests/CLISupport/HelperVersionTests.swift`

#### --version answers from the bundle via PATH symlink where argv0 is the bare name, library untouched
`HelperVersionTests.testEmbeddedHelperPrintsVersionThroughPATHSymlink`: `lokalbot-cli --version` answers from the app bundle alone. It runs
through a PATH symlink like `~/.local/bin/lokalbot-cli`, where argv[0]
is only the bare name, against a library root that must stay untouched.

### `LokalBotTests/CLISupport/LibrarySearchPrefilterTests.swift`

#### Prefilter search must equal the old search kept as ReferenceLibrarySearch
`LibrarySearchPrefilterTests`: `LibrarySearch.hits` skips transcripts and texts its byte-level prefilter
rules out, and folds sentences without rebuilding them. These tests hold
it to the search it replaced, kept below as `ReferenceLibrarySearch`:
the same hits in the same order, with the same snippets and timestamps.

#### Short words match whole words only; longer ones match inside words
`LibrarySearchPrefilterTests.testPrefilterMatchesReference`: Short words match whole words only; longer ones match inside words.

#### Compares both searches using the CLI's, MCP's and Ask's arguments
`LibrarySearchPrefilterTests.assertMatchesReference`: Compares both searches with the CLI's, the MCP's and Ask's arguments.
Returns whether the CLI search found anything.

#### Transcripts the prefilter must hand to the decoder: escapes, UTF-16, broken file
`LibrarySearchPrefilterTests.writeTrickyLibrary`: Transcripts the prefilter must hand to the decoder: escaped
characters, UTF-16, a broken file.

#### Splitmix64 so each run draws the same text
`SeededRandom`: Splitmix64, so each run draws the same text.

### `LokalBotTests/CLISupport/MCPDispatcherTests.swift`

#### Server instructions tell the model to orient with get_briefing first
`MCPDispatcherTests.testInitializeEchoesKnownProtocolVersionAndServerInfo`: Clients that surface server instructions tell the model to orient first.

### `LokalBotTests/CLISupport/MCPProtocolTests.swift`

#### Reader must return a line without waiting for a full chunk or EOF
`MCPProtocolTests.testReaderReturnsALineWhileThePipeStaysOpen`: Clients keep stdin open and send one short line at a time; the reader
must hand that line over without waiting for a full chunk or EOF.

### `LokalBotTests/CLISupport/PersonalContextAccessTests.swift`

#### A projection on disk without the marker is never served
`PersonalContextAccessTests.testRefusedWithoutItsOwnGrantEvenWithOtherAccess`: A projection left on disk without the marker is never served.

### `LokalBotTests/CLISupport/ScreenMemoryReaderTests.swift`

#### search_screen ORs exact FTS phrases, so Chinese words in a phrase need substring matching
`ScreenMemoryReaderTests.testSearchFindsAChineseWordInsideAPhrase`: The MCP `search_screen` reader ORs exact FTS phrases, so a Chinese word
inside a phrase found nothing at all. It now matches by substring.

### `LokalBotTests/CLISupport/SettingChangeTests.swift`

#### Consent setting with no narrowing rule would treat turning it off as widening
`SettingChangeTests.testEveryConsentSettingHasADirection`: A consent setting with no rule would treat every change as widening,
including turning it off. Check each one can be narrowed.

#### retentionDays and keepOCRTextForever need review in both directions on purpose
`SettingChangeTests.testEveryConsentSettingHasADirection`: both directions need review, on purpose

#### Adding an exclusion narrows; clearing the list would widen
`SettingChangeTests.testEveryConsentSettingHasADirection`: Adding an exclusion narrows; clearing the list would widen.

#### config export shows the URL redacted; importing it back is a no-op
`SettingChangeTests.testPlanResetsToDefaultsAndKeepsRedactedURLParts`: `config export` shows the URL redacted; importing it back is a no-op.

### `LokalBotTests/CLISupport/SettingRegistryTests.swift`

#### Terminal settings registry must match AppSettings keys and stored enum spellings
`SettingRegistryTests`: Keeps the terminal's settings registry identical to `AppSettings`: every
stored key described, every choice spelled as the real enum stores it.

#### Optional keys are encoded only when set
`SettingRegistryTests.testEveryStoredKeyHasExactlyOneSpecOrIsInternal`: Optional keys are encoded only when set.

#### companionHistory choices run shortest window first so later ones share more
`SettingRegistryTests.testChoiceSettingsListStoredValues`: Shortest window first, so a later choice shares more.

#### Retention and exclusions live with the capture they limit, not privacy
`SettingRegistryTests.testSnapshotSpecSelection`: Retention and exclusions live with the capture they limit.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
