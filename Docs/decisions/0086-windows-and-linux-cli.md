# 0086. Windows and Linux: cli

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-cli/`, `LinuxWindows/crates/lokalbot-cli/src/ask.rs`, `LinuxWindows/crates/lokalbot-cli/src/briefing.rs`, `LinuxWindows/crates/lokalbot-cli/src/control.rs`, `LinuxWindows/crates/lokalbot-cli/src/files.rs`, `LinuxWindows/crates/lokalbot-cli/src/install.rs`, `LinuxWindows/crates/lokalbot-cli/src/json.rs`, `LinuxWindows/crates/lokalbot-cli/src/lib.rs`, `LinuxWindows/crates/lokalbot-cli/src/mcp.rs`, `LinuxWindows/crates/lokalbot-cli/src/notes.rs`, `LinuxWindows/crates/lokalbot-cli/src/personal.rs`, `LinuxWindows/crates/lokalbot-cli/src/reports.rs`, `LinuxWindows/crates/lokalbot-cli/src/screen.rs`, `LinuxWindows/crates/lokalbot-cli/src/search.rs`, `LinuxWindows/crates/lokalbot-cli/src/search/`, `LinuxWindows/crates/lokalbot-cli/src/session.rs`, `LinuxWindows/crates/lokalbot-cli/tests/`.

## Decisions

### `LinuxWindows/crates/lokalbot-cli/build.rs`

#### Embed version metadata so every signed Windows binary shares ProductName and ProductVersion
Embeds version metadata into the Windows CLI executable so every signed
LokalBot binary carries the same ProductName and ProductVersion.

### `LinuxWindows/crates/lokalbot-cli/src/ask.rs`

#### ask_library goes only to the local model server on 127.0.0.1; marker file gives port and token
`ask_library` (`AskLibraryEngine.swift`, `AskLibraryContext.swift`): the
question and matching meeting context go to the app's local model server
on 127.0.0.1; nothing leaves this computer.

The app records its server in `<root>/llama-server-17872.json`
(`port`, `pid`, `authenticationToken`). Without it the tool answers that
the app must be running.

#### JSON keeps text and sources apart so launchers can paste a draft without Sources
`Outcome::json`: `{"status": "answered" | "not_found" | "error", "code"?, "text", "sources"}`,
which keeps the text and its sources apart, so a launcher can paste a
draft without a Sources list.

#### Access check comes first so a disabled library says so before anything else
`answer`: Access comes first: a disabled library says so before anything else.

#### Retrieve by message words; a message nothing matches gets no draft
`draft_reply`: Drafts the user's reply to `message` from what their meetings say. Meetings
are retrieved by the message's own words (and the instruction's); a message
nothing matches gets no draft, since the point is to add what the user's
meetings know.

#### Waiting a minute for a wake only helps when an app can answer
`respond`: Waiting a minute for a wake only helps when an app can answer it.

#### Citations are (short id, title, YYYY-MM-DD), newest first
`ContextBundle.citations`: `(short id, title, YYYY-MM-DD)`, newest first.

#### Draft-reply prompt is word for word the Swift prompt
`reply_messages`: The draft-reply prompt, word for word (`AskLibraryContext.replyMessages`).

### `LinuxWindows/crates/lokalbot-cli/src/briefing.rs`

#### Briefing sections sit under their permission grant; with none, only permissions are listed
`get_briefing` and `lokalbot-cli brief` (`Briefing.swift`): the first read
of an agent session. Every section sits under the permission covering its
data; with nothing granted it only lists the permissions.

#### Briefing names MCP tools or CLI commands depending on what the agent can reach
`Vocabulary`: What the briefing tells the agent to call next: MCP tools for
`get_briefing`, `lokalbot-cli` commands for `brief`, so an agent that can
only run a shell isn't pointed at tools it can't reach.

#### Items need grants for every source behind them; unattributed items never shown
`work_memory`: Items need the grant of every kind of source behind them; unattributed
items are never shown.

#### Timeline stays in screen-memory window; lines with changed reviews never shown
`timeline`: Recent days in detail, older weeks and months as one line each, all inside the
screen-memory history window. A line whose reviews changed is never shown.

### `LinuxWindows/crates/lokalbot-cli/src/control.rs`

#### All settings reads and writes go through the running app; CLI can never approve requests
`config`, `secret`, `setup`, `models`, `permissions`, `status`, `doctor`,
`restart` and `open` (`CLI/Commands/*`, `AppControlClient.swift`). Every read
and write of a setting goes through the running app, so its decoding and
coupling rules apply once. Nothing here can approve a request: that happens
only in the app, with the person looking at it.

#### Distinct exit codes tell waiting, denied and expired requests apart for scripts
`EXIT_WAITING`: Exit codes for requests that need the person, so a script can tell a request
still waiting from one they declined or nobody answered.

#### Requests start the app in background when no copy runs for this library
`Client`: Sends one request to the running app, starting the app in the background
when no copy is running for this library.

#### Never start the app for an agent the person has not allowed
`Client::request`: Never start the app for an agent the person has not allowed.

#### Launch by path, never by name, so a different copy is not started
`Client::enclosing_app`: The LokalBot beside this CLI, resolved through the installed link.
Launching by path, never by name, keeps a CLI from starting a different
copy with another library.

#### Windows keeps command in Programs/LokalBot/bin and app one folder up
`app_beside`: `lokalbot` beside `cli`, or one folder up: Windows keeps the command in
`Programs\LokalBot\bin` and the app in `Programs\LokalBot`.

#### Polling never starts LokalBot because a request lives only in the copy that took it
`poll`: Polls the running app until the request is answered or `seconds` pass. Never
starts LokalBot: a request lives only in the copy that took it.

#### Waiting request exits 3; --wait follows until 0 approved, 4 denied, 5 expired
`send_for_approval`: Sends a request that may need the person and prints the reply. A request left
waiting prints as JSON and exits 3, or, with --wait, is followed until the
person answers: 0 approved, 4 denied, 5 expired.

#### The app socket opens right after the person allows the request
`setup request`: The socket opens right after the person allows it.

#### Running copy finds the request file within a second; hint when CLI cannot start app
`show_setup_request`: Opens LokalBot on the request. A running copy finds the file itself within a
second. Returns a hint when this CLI can't start LokalBot.

### `LinuxWindows/crates/lokalbot-cli/src/files.rs`

#### search_files does word search over Files index while app is closed; meaning search stays in Ask
`search_files` for MCP and `lokalbot-cli search-files` (`FilesSearchTool`): word
search over the Files index, which works while the app is closed. Search by
meaning needs LokalBot's embedding model, so it stays in Ask.

#### Cap on ranked matches examined for ones inside chosen folders and dates
`WIDEST_SEARCH`: The most ranked matches one search looks through for ones inside the
chosen folders and dates.

#### Passages over 1500 characters are cut with an ellipsis
`PASSAGE_CHARACTERS`: A passage longer than this is cut, with an ellipsis.

#### Validate arguments before grant checks so bad calls fail the same with or without grant
`files::report`: Arguments first, so a bad call says so with or without the grant; then the
grant, the folder list and the index.

#### A directory walk reports folders by real path, so match both forms
`files::report`: A walk reports a folder by its real path.

#### Folder and date filters apply after ranking, so widen the window until enough hits
`files::report`: The folders and dates are applied after ranking, so the best few
matches can all fall outside them: forty older invoices hid the one
from this month. Look further down the ranking until enough are
inside, or there is nothing more to look at.

#### Regression: many higher-ranked outside-folder files must not hide the in-folder match
`a_match_ranked_below_ones_outside_the_chosen_folders_is_still_found test`: Files with both words rank above the one in the chosen folder,
which has one. All are outside it, and there are more of them than
a search for one result looks at first, or used to look at in all.

#### Regression: long outside documents hold more passages than search once read
`a_match_below_a_thousand_passages_outside_the_chosen_folders_is_still_found test`: A few long documents outside the chosen folder hold more matching
passages than a search used to read at all.

### `LinuxWindows/crates/lokalbot-cli/src/install.rs`

#### install-skill layout on Linux and Windows; existing identical command path left in place; foreign paths never replaced
`install-skill` (`LokalBotCLIInstaller.swift`) for Linux and Windows.

Linux: `~/.local/bin/lokalbot-cli` links to this binary; the skill is
written once under `~/.local/share/lokalbot-cli/skill` and linked from
`~/.agents/skills/lokalbot-cli` and `~/.claude/skills/lokalbot-cli`
(copied with `--copy`). Windows: the binary is copied to
`%LOCALAPPDATA%\Programs\LokalBot\bin` and the skill copied into the same
skill folders under `%USERPROFILE%`. When this binary already sits at the
command path (`packaging/linux/install.sh` copies it there and the app runs
it from there), or an identical copy does, it is left in place and only the
skill is written. Paths this installer does not own are never replaced.

#### Bundled agent skill is the same file the macOS app ships
`SKILL`: The bundled agent skill (the macOS app ships the same file).

#### Command lives at ~/.local/bin or %LOCALAPPDATA%/Programs/LokalBot/bin, outside the library
`command_path`: Where `install-skill` puts the command for `home`:
`~/.local/bin/lokalbot-cli` on Linux and
`%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe` on Windows, outside
the library folder.

#### Path shown in Settings and the app's MCP setup commands
`command_path_for_current_user`: [`command_path`] for the current user, which the app shows in Settings and
in its MCP setup commands.

#### True if folder is on PATH or already in shell startup file; drives Settings PATH button
`on_path_for_current_user`: Whether the command's folder is on PATH or already added to the shell's
startup file, for the PATH button in Settings.

#### Skill text replaces macOS helper path with this platform's command path
`Installer::skill_text`: The skill with this platform's paths in place of the macOS ones.

#### Windows installs a copy into a folder only this installer uses
`Installer::is_owned`: Windows installs a copy into a folder only this installer uses.

#### install.sh puts command without skill, so command alone does not count as installed
`Installer::is_installed`: Whether `install-skill` has run: the command is there and so is a skill
this installer wrote. install.sh puts the command in place without the
skill, so the command alone does not count.

#### Command path already running this binary or identical copy is left as it is
`Installer::binary_in_place`: Whether the command path already runs this binary: it is the same file
(install.sh's copy that the app runs, or an earlier link to it), or a
regular file with the same contents. Either way it is left as it is.

#### Linux edits shell startup file; Windows changes user PATH, not system-wide
`Installer::add_bin_to_path`: Puts the command's folder on PATH (`addLocalBinToPath`) and says where.
Linux adds a line to the shell's startup file; Windows changes the user's
PATH, which leaves the system-wide one alone.

#### Test installer keeps all paths inside temp dir, never real home or LOCALAPPDATA
`installer_in test helper`: An installer with every path inside `dir`, so a test never touches the
real home folder or `%LOCALAPPDATA%`.

#### install.sh copies CLI to command path and app runs that copy with install-skill
`keeps_the_binary_that_already_sits_at_the_command_path test`: install.sh copies lokalbot-cli to the command path and the app runs
that copy with `install-skill`.

#### install.sh's copy is left for install.sh --uninstall
`keeps_the_binary_that_already_sits_at_the_command_path test`: install.sh's copy is left for `install.sh --uninstall`.

#### Case: install.sh copy while app runs from the extracted archive
`keeps_an_identical_copy_at_the_command_path test`: install.sh's copy while the app runs from the extracted archive.

#### install.sh's copy alone is not an installed Agent CLI
`installed_needs_the_command_and_this_installers_skill test`: install.sh's copy alone is not an installed Agent CLI.

#### Someone else's skill folder does not count as installed
`installed_needs_the_command_and_this_installers_skill test`: Someone else's skill folder does not count either.

### `LinuxWindows/crates/lokalbot-cli/src/json.rs`

#### Output matches Swift JSONEncoder: sorted keys, two-space indent, escaped slashes by default
JSON exactly as the macOS helper prints it: sorted keys, two-space
indentation, `"key" : value`, whole numbers without a fraction and, unless
asked otherwise, `/` escaped as `\/` (Swift's `JSONEncoder`).

#### escape_slashes mirrors Swift encoders lacking withoutEscapingSlashes
`pretty`: Pretty JSON with Swift's separators. `escape_slashes` mirrors encoders
without `.withoutEscapingSlashes`.

#### Compact sorted JSON with unescaped slashes is the MCP wire format
`compact`: Compact JSON with sorted keys and unescaped slashes (MCP wire format).

### `LinuxWindows/crates/lokalbot-cli/src/lib.rs`

#### CLI is read-only on the library and mirrors macOS helper commands, output and errors
`lokalbot-cli`: read-only access to the LokalBot library, a stdio MCP server
and settings through the running app, with the commands, output and errors
of the macOS helper (`CLI/`, `LokalBot/CLISupport/`). It opens the library
read-only and never writes into `meetings/`.

#### Hidden flag equals LOKALBOT_STORAGE_ROOT env var
`Cli.storage_root`: Read another library (same as LOKALBOT_STORAGE_ROOT).

#### Validation errors exit 64 like ArgumentParser; other failures exit 1
`CliError`: A failure printed as `Error: <message>`: validation errors exit 64
(ArgumentParser's `ValidationError`), others 1.

#### Agents recognise failures by [code] message, matching MCP tools
`coded`: A failure agents are told to recognise by its code: `[code] message`, as
the MCP tools, `ask` and the settings commands print it.

#### Mic speech labelled as the app does; Mac library has no settings file, keeps default
`run`: Transcripts label microphone speech as the app does. A Mac library has
no settings file here, so it keeps the default.

#### A disabled switch prints its code, as MCP tools do
`run notes failure`: A switch that is off prints its code, as the MCP tools do.

#### Failures exit 1 after printing the JSON that says why
`print_ask_outcome`: Prints JSON or text on standard output; failures exit with status 1 so
scripts notice, after the JSON that says why.

#### Engine checks character limit; stdin read only bounds memory
`read_message_from_stdin`: The engine checks the character limit; this only bounds memory.

#### A secret key is never accepted as a command argument
`control_commands_parse_like_the_mac test`: A key is never an argument.

#### Unknown config key suggests a real one before contacting the app
`schema_needs_no_permission test`: An unknown key suggests a real one before reaching the app.

### `LinuxWindows/crates/lokalbot-cli/src/mcp.rs`

#### Stdio JSON-RPC server: handshake and tools/list always work; tools need meeting or screen grant
The stdio MCP server (`MCPProtocol.swift`, `MCPDispatcher.swift`,
`FileLibraryToolProvider.swift`): newline-delimited JSON-RPC 2.0. The
handshake and `tools/list` always work; meeting tools need the meeting
grant, screen tools the separate screen grant.

#### Screen tools encode pretty, sorted, unescaped slashes, ISO dates
`screen_json`: Pretty, sorted, unescaped slashes, ISO dates (screen-memory encoder).

#### until filter lets an earlier week be asked for before newer meetings use the limit
`list_meetings`: As `list --until`: without it, one earlier week could not be asked
for, and newer meetings used up the limit first.

#### Misspelt include part errors instead of returning a meeting missing a section
`get_meetings include parsing`: As `get --include` and list_meetings do: a misspelt part
must not come back as a meeting without that section.

#### Independent of meeting, screen and Agent Mode grants; only Files marker and folders
`search_files`: Independent of meeting and screen access, and of Agent Mode capabilities:
only the Files marker and its folder list.

#### Independent of other grants; needs Agent notes marker and saved notes
`search_agent_notes`: Independent of every other grant: only the Agent notes marker, and the
notes LokalBot saved while Read coding agent notes is on.

#### Lines over 1 MiB are rejected without buffering them whole
`serve`: Serves stdin/stdout until EOF. Lines over 1 MiB are rejected without
buffering them whole.

### `LinuxWindows/crates/lokalbot-cli/src/notes.rs`

#### Word search over coding-agent notes, only while Read coding agent notes is on; works with app closed
`search_agent_notes` for MCP and `lokalbot-cli search-notes`
(`AgentNotesSearchTool`): word search over the notes the user's coding
agents saved for themselves, as LokalBot keeps them while **Read coding
agent notes** is on. Works while the app is closed.

#### Keys sort the way the Mac writes them
`Item`: Keys sort the way the Mac writes them.

#### Label is Claude Code's own: user, feedback, project or reference
`Item.kind`: Claude Code's own label: user, feedback, project, or reference.

#### Validate arguments before grant so bad calls fail the same either way
`notes::report`: Arguments first, so a bad call says so with or without the grant; then the
grant, then the saved notes.

#### No other grant opens the notes
`search_for_agents_needs_its_own_grant_then_saved_notes test`: No other grant opens the notes.

### `LinuxWindows/crates/lokalbot-cli/src/personal.rs`

#### Only user-shared claims, read from plaintext projection app keeps while grant is on
`get_personal_context` and `personal-context` (`PersonalContextAccess.swift`):
only claims the user chose to share, read from the plaintext projection
the app keeps under `control/` while the grant is on.

### `LinuxWindows/crates/lokalbot-cli/src/reports.rs`

#### Reports show owners and names only; email addresses never appear
Action items and people for the CLI and MCP (`ActionItemsReport.swift`,
`PeopleReport.swift`). Owners and names only; email addresses never
appear.

#### Sample meeting's made-up actions listed only when asked for by id
`action_entries`: The sample meeting's actions are made up: only listed when asked for by id.

#### Lookup order: person ID, exact name, then unique case-insensitive substring
`find_person`: Person ID, exact name, then a unique case-insensitive substring.

### `LinuxWindows/crates/lokalbot-cli/src/screen.rs`

#### Screen memory read-only per request; OCR text and titles only, never pixels or file paths
Read-only screen memory for MCP (`ScreenMemoryReader.swift`): OCR text,
window titles and activity metadata from `lokalbotv3.sqlite`, opened
read-only for every request. Never pixels or screenshot file paths.

#### Briefing gets where and what came out, never prompts, replies or file contents
`AgentSession`: One coding-agent session for the briefing: where and what came out, never
prompts, replies or file contents.

#### Query words are quoted and OR-ed, best match first
`ScreenReader::search`: OR of the quoted query words, best match first.

#### Scheduled runs excluded because they are not the person's work
`ScreenReader::agent_sessions`: Coding-agent sessions that began in the interval, newest first;
scheduled runs are not the person's work.

### `LinuxWindows/crates/lokalbot-cli/src/search.rs`

#### Index-free word search: all words match first, rare words weigh more, short ASCII words whole-word only
Word search over on-disk meeting artifacts (`LibrarySearch.swift`), so
the CLI and MCP need no index. A meeting matches when it contains every
query word (any order, case- and accent-insensitive); otherwise partial
matches follow. Rare words weigh more, exact-phrase hits lead and ties
keep recency. Words of up to three ASCII letters or digits match only
whole words; a quoted query matches only its exact phrase.

Each query still reads every meeting's files, but a quick byte scan
([`prefilter`]) skips the transcripts, titles, summaries and segments
that cannot contain a query word, so only those that may are decoded and
matched.

#### A single Latin letter is dropped unless it is the whole query
`search_terms`: Distinct alphanumeric words in query order. A single Latin letter is
dropped unless it is the whole query.

#### Words of up to three ASCII characters must stand alone
`word_range`: Byte range of the first match of `needle` in `text`; short ASCII words
must stand alone.

#### Sum weights in query order; set order made identical searches reorder tied meetings
`hits`: Summed in query order. A set's order changes from run to run, and with
it the last bits of the sum, so meetings that match the same words
could swap places between two identical searches.

### `LinuxWindows/crates/lokalbot-cli/src/search/equivalence_tests.rs`

#### Search must match pre-prefilter results; old_hits copy differs only in fixed-order weight sum
The search must return exactly what it did before the prefilter: same
hits, same order, same snippets and timestamps. `old_hits` is a copy of
`hits` from before it (master e1d8997b), changed only to sum meeting
weights in a fixed order; random libraries with tricky text are searched
both ways.

#### Only change from original: sum weights in query order, as hits now does
`old_hits`: The one change from the original: sum in query order, as `hits`
now does. Summing in a set's order made the order of meetings
that match the same words change from run to run.

#### Fixture meetings vary summary presence and transcript form: missing, escaped, broken, UTF-16, BOM
`library`: A few meetings, each with or without a summary, and a transcript that is
missing, written by the app, written with escapes, broken, UTF-16 or
behind a byte-order mark. Returns the texts written, for queries.

#### Use a copy so opening the database leaves nothing in the repository
`hits_match_the_old_search_on_the_macos_fixture test`: A copy, so opening its database leaves nothing in the repository.

#### Weights differ per word so sum order shows in the last bits
`meetings_that_match_the_same_words_keep_recency_on_every_run test`: The two newest meetings have every word; older ones fewer, so each
word weighs differently and the order of a sum shows in its last bits.

### `LinuxWindows/crates/lokalbot-cli/src/search/prefilter.rs`

#### Skeleton prefilter skips non-matching text; says maybe when unreadable; folding exceptions fall back to fold
Shortcuts that let [`super::hits`] skip text that cannot match, and fold
the rest faster, without changing a single hit.

[`fold`] decomposes (NFD), drops combining marks, lowercases and collapses
whitespace. Each step works on one character at a time, with two
exceptions: lowercasing turns a capital sigma into `ς` or `σ` depending on
its neighbours, and decomposing reorders characters with a nonzero
combining class (all of them combining marks in current Unicode, which
are dropped anyway). So:

- [`fold_fast`] folds one character at a time, with an ASCII shortcut, and
  hands a text with either exception to [`fold`].
- A *skeleton* is folded text with every run of characters that are not
  letters or digits written as one space, and `ς` written as `σ`. Whatever
  `fold(text)` contains, written the same way, the text's skeleton
  contains, and a whole word there is a whole word in the skeleton.
- [`Prefilter`] looks for each search word's skeleton in a text's
  skeleton, or in a `transcript.json` before it is decoded. It answers
  "no" only when no word can match. When it cannot read something
  (invalid UTF-8, a broken escape) it answers "maybe", and the decoder and
  matcher decide as before.

#### Branchless separator collapse; only stop branch is rare, giving few cycles per byte
`push_run`: Folds bytes until one `table` marks special and returns how many it
read. The hot loop: separators collapse without a branch, and the only
branch (the stop) is rarely taken, so it runs at a few cycles a byte.

#### Returns false if canonical ordering may move folds; never in current Unicode
`push_char`: Adds one character of the original text; `false` when canonical ordering
may move what it folds to (never in current Unicode).

#### Escaped byte and four hex digits of \u hold no quote
`json_string_end`: The escaped byte, then (for \u) four hex digits, hold no quote.

#### A key with an escape might spell text, so its value counts too
`transcript_skeleton`: The skeletons of a `transcript.json`'s `"text"` values, one after
another. A key with an escape might spell `text`, so its value counts
too. `false` when the file cannot be read this way.

#### Up to three ASCII characters match only as a whole word
`Needle.whole_word`: Up to three ASCII characters match only as a whole word.

#### A leading or trailing separator stands for the surrounding characters too
`Needle.open_start`: The word starts (ends) with a separator, which stands for the
characters around it as well.

#### A word without letters or digits means any text may match
`Prefilter.everything`: Some word has no letter or digit, so any text may match it.

#### False only when no search word can match fold(text)
`Prefilter::may_match`: `false` only when no search word can match `fold(text)`.

#### Shortcuts rely on non-zero combining class implying combining mark; else fall back
`fold_matches_skeleton test`: The shortcuts rely on this; they would fall back otherwise.

#### No search words: nothing matches, as in the matcher
`skips_what_cannot_match test`: No words: nothing matches, as in the matcher.

#### Keys spelled with escapes must still name the text field
`transcript fuzz test`: Keys spelled with escapes still name the field.

#### Unreadable input answers maybe and the decoder decides
`reads_only_text_values_and_gives_up_on_what_it_cannot_read test`: Unreadable: maybe, and the decoder decides.

#### UTF-16 never decodes, so skipping it changes nothing
`reads_only_text_values_and_gives_up_on_what_it_cannot_read test`: UTF-16 never decodes, so skipping it changes nothing.

### `LinuxWindows/crates/lokalbot-cli/src/session.rs`

#### Meeting lookups and output mirror Swift SessionLookup and SessionFormatter; read-only
Meeting lookups and output shapes (`SessionLookup.swift`,
`SessionFormatter.swift`). Read-only: nothing here writes to the library.

#### The CLI opens the library read-only
`Session`: The library the CLI reads, opened read-only.

#### Accepts latest, full UUID or unique prefix of 8-character short ID
`Session::find`: `latest`, a full UUID, or a unique prefix of an 8-character short ID.

#### Set only on LokalBot's sample meeting, which is made up with synthetic voices
`ListEntry.sample`: Only on LokalBot's sample meeting: made up, with synthetic voices.

#### Listed summaries share one character budget; short ones leave room for long ones
`LIST_SUMMARY_BUDGET`: `list --include summary` (MCP: `list_meetings` with `include`): the listed
summaries share one character budget, so ten hour-long meetings fit a
small model's context. A short summary comes whole and leaves the rest of
its share to longer ones; a cut one ends in "…" with `summary_truncated`,
and `get` reads it whole.

#### include metadata changes nothing; transcripts are read one meeting at a time with get
`list_includes_summary`: Whether `list --include` (MCP `include`) asks for summaries. Entries
always carry metadata, so `metadata` changes nothing; transcripts are read
one meeting at a time with `get`.

#### Shortest first, each takes up to equal split of remaining budget, capped
`summary_shares`: Shortest first, each takes what it needs up to an equal split of what is
left (and at most `cap`), so short summaries leave room for long ones.

#### Cut at last line break if it keeps at least half, then add ellipsis
`shortened`: The text when it has at most `limit` characters; otherwise its start, cut
at the last line break when that keeps at least half, and "…".

#### Summaries read only when printed; reading all for has_ flags made list scan whole library
`list_json`: `has_summary` and `has_transcript` only say a file is there. Reading
every summary and transcript for them made a plain `list` read the
whole library, so summaries are read only when they are printed.

#### First entry always kept so paging makes progress
`transcript_window`: Whole entries from `start` on, up to `max_characters`; the first entry is
always kept so paging makes progress.

#### One long line is cut mid-line rather than to almost nothing
`list_summaries_share_one_budget test`: One long line is cut mid-line rather than to almost nothing.

### `LinuxWindows/crates/lokalbot-cli/tests/cli.rs`

#### Disabled sources answer with the access-disabled codes agents look for
`commands_honor_the_access_gate`: Each source that is off answers with the code the skill tells agents
to look for, as its MCP tool does.

#### Brief and tool briefing differ only in names and four lines
`brief_names_cli_commands_where_get_briefing_names_tools`: The same briefing apart from the names: the meetings, screen, agent
notes and closing lines differ, nothing else.

#### search-notes needs its own grant and never creates or changes saved notes
`search_notes_needs_its_own_grant_then_saved_notes`: `search-notes` answers only under its own grant, and only while notes are
saved; the saved copy is never created or changed by a search.

#### Agent notes MCP tool is refused without its own grant
`mcp_search_agent_notes_is_refused_without_its_grant`: The MCP tool is refused without its grant whatever else is granted.

#### has_summary and has_transcript come from file presence, with or without include summary
`list_flags_say_which_files_a_meeting_has`: `has_summary` and `has_transcript` come from the files being there, not
from reading them, and say the same with and without `--include summary`.

#### Unknown include values used to silently return the summary alone
`mcp_get_meeting_refuses_include_values_it_does_not_know`: `get_meeting {"include": "summary,transcripts"}` used to come back as the
summary alone, with nothing saying the transcript was not included.

#### Timeline needs both grants; lines whose reviews changed are never shown
`the_briefing_shows_a_timeline_of_reviews_under_both_grants`: Days in detail, older weeks as a line, but only with both grants, and a line
whose reviews changed is never shown (`Briefing.timeline`).

#### A regenerated review makes the week's line stale immediately
`the_briefing_shows_a_timeline_of_reviews_under_both_grants`: A regenerated review makes the week's line stale at once.

#### Settings hints relayed by agents must name toggles that exist in this app
`agent_text_names_only_settings_this_app_has`: Agents relay these hints to the user, so every `Settings → \<page> →
"\<toggle>"` must exist in this app.

#### Exit codes 3 waiting, 0 approved, 4 declined, 5 expired
`requests_that_need_the_person_exit_by_their_state`: Exit 3 waiting, 0 approved, 4 declined and 5 expired, so a script can tell them apart.

#### API keys come from one line of stdin and never appear in output
`api_keys_come_from_standard_input_and_never_print`: A key comes from standard input, one line, and never appears in any output.

#### Stable app errors print as [code] message; no grant means no connection
`errors_from_the_app_print_their_code`: Stable errors print as `[code] message`, and no grant means no connection.

#### --files asks for Files access like other reads and grants nothing
`setup_start_can_ask_to_search_files`: `--files` asks for Files like the other read access, and asking grants nothing.

#### setup start leaves a request the app shows and grants nothing
`setup_start_waits_for_the_answer_in_the_control_folder`: `setup start` leaves a request the app shows, and asking grants nothing.

#### A running app finds the request itself, so nothing is launched
`setup_start_waits_for_the_answer_in_the_control_folder`: A running copy finds the request itself, so nothing is launched here.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
