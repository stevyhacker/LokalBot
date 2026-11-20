# 0008. Mac app: Ask

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Ask/`, `LokalBot/Views/Ask/`, `LokalBotTests/Models/Ask/`, `LokalBotTests/Views/Ask/`.

## Decisions

### `LokalBot/Models/Ask/AskDateScope.swift`

#### Single-day keys stay readable; ranges use inclusive end dates
`AskDateScope`: One civil-date boundary shared by recall, answer tools and saved questions.
Existing single-day keys remain readable; ranges use inclusive end dates.

### `LokalBot/Models/Ask/AskPresentation.swift`

#### Keyword asked with matches showing is answered from them; full question reads sources
`AskMatches`: What one search lists under (or above) the Ask field. A keyword asked
while these show is answered from them; a full question reads the chosen
sources whether or not anything is listed (`AskAnswerScope`).

#### Rows ordered meetings, screens, files, agent notes
`AskMatches.count`: Rows in list order: meetings, screen moments, files, agent notes.

#### A truncated list shows 40+ instead of a total
`AskMatches.countLabel`: "3 in 1 meeting" when only meetings matched, else the number of
sources. A list that was cut says "40+" instead of a total.

#### Down enters matches, Up from first returns to field; unhandled keys stay with field
`AskMatchCursor.move`: Down moves from the field into the matches and then along them; Up
from the first match returns to the field. False when the key is not
this cursor's to handle, so the field keeps it.

#### Scope is shown only in the sources menu
`AskScopeSummary`: The sources menu's button and its first rows. Scope is shown only here:
the chosen sources, the finer filters, and, when a question is limited to
earlier matches or to evidence another page handed over, what that is.

#### Nil when the limit holds no meetings or screens so sources are named
`AskScopeSummary.narrowedLabel`: One meeting by its title; otherwise how many meetings and screen
moments. Nil when the limit holds neither (files only, say), so the
caller names the sources that remain.

#### A limit with no meeting or screen leaves unaffected sources
`AskScopeSummary.remainingSourcesLabel`: A limit that holds no meeting and no screen moment (only files
matched, say) leaves the sources it does not empty.

#### Grouping never renumbers the citation numbers used in the answer
`AnswerSourceGroup`: One source an answer cited, with the numbers that point at it. The numbers
are the ones in the answer; grouping never renumbers them.

#### Rows in first-cited order; fileKey merges passages of one file
`AnswerSources.groups`: A row per meeting, screen moment or file, in the order the answer
first cites them. `fileKey` names the file a cited passage belongs to
(its path), so two passages of one file share a row; without it each
passage stays its own row.

#### Passages read only from what is already stored on this Mac
`CitationPassage`: The words a citation points at, read from what is already stored on this
Mac: a transcript line, a screen moment's text, a file's excerpt.

#### Citations carry whole seconds; match by start second, then spoken, then last before
`CitationPassage.line`: The transcript line a meeting citation names. Citations carry whole
seconds, so the line that starts in that second wins; otherwise the
line being said then, otherwise the last one before it.

#### With nothing to name, general suggestions stand in and no keyword offered
`AskSuggestions.build`: Questions about the person's own project, latest meeting and a
colleague, then one word to search for. With none of those to name,
the app's general suggestions stand in and no word is offered.

### `LokalBot/Models/Ask/AskRouting.swift`

#### Raw value Today kept so persisted conversations decode; UI says Activity
`AskSourceScope.today`: The raw value stays `Today` so existing persisted conversations decode.
In the UI this is the Activity source; calendar filtering is independent.

#### Files and Agent notes always in All sources so toggling never looks narrowed
`AskSourceScope.defaults`: Every source. Files and Agent notes are part of "All sources" whether
or not they are on, so turning one on or off never makes an earlier
question look narrowed.

#### Persist selected day as YYYY-MM-DD to survive time-zone changes
`AskDayScope`: Stable civil-day persistence for Ask. A `Date` is an instant, so saving a
local midnight and formatting it after a time-zone change can silently move
the scope to the previous or next day. Store the selected YYYY-MM-DD instead.

#### Disabled sources absent from prompt and denied at execution too
`ScopedChatToolRunner`: A question-scoped tool catalogue. Disabled sources are absent from the
agent prompt and are still denied at execution as a second boundary.

#### Skip telling the model about limits that only hide never-theirs meetings
`ScopedChatToolRunner.namesMeetingLimit`: False when `meetingIDs` holds everything the asker may read and so is
not worth telling the model about: it only leaves out what is never
theirs, such as the sample meeting.

#### Earliest moment activity_summary may read; meetings held by meetingIDs
`ScopedChatToolRunner.activityNotBefore`: The first moment `activity_summary` may read, for an asker whose
history starts there. Meetings are held by `meetingIDs`.

#### Focus is where the answer starts, never a limit on tools
`ScopedChatToolRunner.focus`: What the question was asked about, e.g. "the day 4 Nov 2026": where
the answer starts, never a limit on the tools.

#### Attached screens obey search_screen boundary; caller's range only if none
`ScopedChatToolRunner.attachedScreenEvidence`: Attached screens get the same boundary as `search_screen`: the screen
source must be on and the pinned set still applies. A caller's date
range applies only when this question has none of its own.

#### Scoped questions get no ambient meeting titles outside the exact scope
`ScopedChatToolRunner.libraryOverview`: Source-limited and day-limited questions must not receive ambient
meeting titles outside the exact scope enforced by the tools below.

#### Meeting lists state their limit so a short list is not read as everything
`ScopedChatToolRunner.run`: A short list read as the whole library ("the only one in your
library"), so the meeting lists say what they were held to.

#### New question centers field; conversation docks it; typing never replaces thread
`AskPhase`: What the Ask page shows. A new question has the field in the middle with
suggestions or matches under it; a conversation keeps its thread on
screen with the field docked below and matches in a tray above the field.
Typing never replaces the conversation.

#### Full-question heuristic; Laya run.py extracts and measures this enum
`AskIntent`: Whether typed input reads as a full question rather than search keywords:
two or more words ending in a question mark, or three or more words that
start with a question or request word. Return asks either way; this
decides what the answer reads (`AskAnswerScope`). `Benchmarks/search/Laya/run.py`
extracts this enum from the file and measures it.

#### Return asks unless arrow keys moved into matches; Quick Recall differs
`AskReturnAction`: What Return does in Ask: it asks. Only after the arrow keys moved into the
matches does it open the selected one. Quick Recall keeps its own rule.

#### Full questions read chosen sources; keywords read listed matches; Remember limits nothing
`AskAnswerScope`: What an answer asked from the Ask field reads. A full question reads
everything in the sources and dates chosen in the composer's two menus,
whether or not matches are listed. A keyword or short phrase is a search
the person then asks about, so its answer reads the listed matches. A
"Remember …" statement is saved as it is and limits nothing. Scope that
was already set on purpose (a meeting handed over, an attached screen, the
menu's "Only …" state) is not this type's to change: it applies to both.

#### Four or more words count as a question since AskIntent is English-only
`AskAnswerScope.fullQuestionWordCount`: A search is a word or a short phrase. Anything longer is treated as a
question in any language, because `AskIntent` only knows English
question words and a question typed without "?" in Serbian or Japanese
would otherwise be answered from its matches alone.

#### Screen, Files and Agent notes use separate indexes, so kind is nil
`AskFacet.kind`: The FTS index kind this facet narrows to; `nil` for All (no filter),
Screen (which queries the OCR store instead of the FTS index), Files
(the file index) and Agent notes (their own index).

### `LokalBot/Models/Ask/QuickRecallResults.swift`

#### Show all narrows Ask to a source; commands and recent not searched
`QuickRecallGroup.Kind.askSource`: The Ask source a "Show all" link narrows the full Ask screen to.
Commands and recent items are not searched there.

#### Search hit its limit so total is only a floor
`QuickRecallGroup.isCapped`: The search stopped at its own limit, so `total` is a floor.

#### Show 40+ when capped so a count never reads as exact
`QuickRecallGroup.totalLabel`: "7", or "40+" when the search stopped at its limit: never a count
that reads as exact when it is not.

#### Cap three rows per kind; many screen matches buried meetings
`QuickRecallGrouping.rowsPerKind`: Rows of one kind listed before "Show all". A large number of screen
matches used to push every meeting out of view.

#### Loose command matches listed last so they do not take Return
`QuickRecallGrouping.Found.looseCommands`: Commands that only hold the typed words somewhere. They are listed
last, so a search word that happens to sit inside a command's name
does not put that command under Return.

#### Folded saved moments can hide that the screen list was cut
`QuickRecallGrouping.Found.screenSourceCount`: Screen sources the search listed. Saved moments can fold two of
them into one row, so the rows alone can hide that the list was cut.

#### Fixed group order; commands only on match; empty groups omitted
`QuickRecallGrouping.groups`: The groups for a typed search, in a fixed order: commands (only when
the typed words match one), meetings, screens, files, then agent
notes while that source is on. Empty groups are left out. `expanded`
lists the kinds whose heading was asked to show everything in place.

#### Meeting lists before a moment of the same instant
`QuickRecallRecent.Entry.order`: A meeting and a moment of the same instant list the meeting first.

#### Return opens a row or asks on Ask row; Command-Return asks anywhere
`QuickRecallCursor`: Where the keyboard is in the list: on a row, or on the Ask row pinned
under the results. Return opens a row and asks on the Ask row; ⌘Return
asks from anywhere.

#### Nil selection makes Return do nothing instead of asking by surprise
`QuickRecallCursor.index`: The selected position: rows first, then the Ask row. Nil when nothing
is selected, so Return does nothing instead of asking by surprise.

#### First row selected; with no rows Ask row waits for arrow or Command-Return
`QuickRecallCursor.reset`: The first row is selected when there is one. With no rows nothing is,
and the Ask row waits for an arrow key or ⌘Return.

#### Short phrase answers limited to listed matches; full question reads all sources
`QuickRecallAskScope`: What an answer asked from Quick Recall reads. A word or a short phrase is
a search the person then asks about: the answer is limited to the listed
meetings and screen moments, as ⌘Return always was. A full question reads
everything in every source, by the rule the Ask screen uses
(`AskAnswerScope`); so does a "Remember …" statement, and a search that
listed no meeting or screen moment to limit it to.

#### While matches are being found, count as reading them; question waits
`QuickRecallAskScope.readsListedMatches`: Whether the Ask row should say the answer comes from the listed
matches. While a word's matches are still being found it does: the
question waits for them.

#### Name a remote model so nothing is sent by surprise
`QuickRecallAskScope.askRowDetail`: The Ask row's grey line: what the answer will read, and where it is
written. A remote model is named, so nothing is sent by surprise.

### `LokalBot/Models/Ask/QuickRecallRowModel.swift`

#### Speaker field holds speaker or meeting part of the match
`QuickRecallRowModel.meeting`: `speaker` is who said the matching line, or the part of the meeting it
came from (`meetingLead`).

#### Lead is speaker for transcript lines else location; title match needs none
`QuickRecallRowModel.meetingLead`: What starts a meeting's matching line: the speaker of a transcript
line when the search hit names one, otherwise where the words are
(your notes, the summary, an outcome). A title match needs neither.

#### Keyword-saved captures lead; semantic-only saved keep ranked place
`QuickRecallRowModel.screens`: Saved keyword matches lead the Screens group. Use their own matching
capture, even when another capture is the group's primary search result.
A saved capture related only by meaning keeps its ranked place, so it
cannot bury a capture that contains the searched words.

### `LokalBot/Models/Ask/RecallSearch.swift`

#### Limits apply after ranking and flag truncation; Meetings filter has none
`RecallSearch`: Shared grouping and lexical retrieval for Ask and Quick Recall. Limits are
applied to groups after ranking, and a result that hit one says so. The
Meetings list filter uses `SearchIndex.matchingMeetingIDs`, which has none.

#### Ask lists at most 40; more sets isTruncated so no total shown
`RecallSearch.displayLimit`: Meetings, or screen sources, that Ask lists for one search. A search
that finds more sets `Result.isTruncated`, so the count is not shown
as a total.

#### Fuse by source so lexical-heavy meeting cannot bury semantic-only one
`RecallSearch.fusedMeetings`: Fuse at the source level so a meeting with many lexical rows cannot
bury a relevant semantic-only meeting. Preserve lexical excerpts and
deterministically deduplicate the same source passage across both lists.

#### Lexical preferred only on equal fused score, not over higher semantic rank
`RecallSearch.fusedMeetings`: Prefer lexical evidence only for equal fused relevance, never
ahead of a higher-ranked semantic-only source.

### `LokalBot/Models/Ask/RecallWorkspaceState.swift`

#### Only Ask observes it so keystrokes avoid re-rendering AppState observers
`RecallWorkspace`: Ask's query and retrieval state for the session. Only Ask observes it:
AppState does not relay its changes, so a keystroke in the query field
re-renders Ask rather than every AppState observer.

#### Session-lived state survives opening evidence
`RecallWorkspaceState`: Shared, session-lived navigation state. Opening evidence does not discard
the selected filters, attachments, result or unfinished question.

#### Ask about results keeps Activity, Files and Agent notes sources
`RecallWorkspaceState.selectResultEvidence`: "Ask about results" bounds meetings and screen moments to the displayed
rows. Activity has no result rows to bound, so a selected Activity
source stays; otherwise "How long was I in Figma today?" lost the only
tool that answers it whenever the question also matched a result.
Files has no per-row bound yet either, so a selected Files source stays
when file rows were among the results.
Agent notes follow the same rule as Files.

#### Explicit source choice supersedes earlier temporary narrowing
`RecallWorkspaceState.chooseSources`: An explicit source choice supersedes any earlier temporary narrowing.

#### Pass one group beyond displayLimit so a cut list is detected
`RecallSearch.Result.setMeetings`: Pass one group more than `displayLimit` so a cut list is detected.

#### Relax strict query when empty; include saved moments; return limit plus one
`RecallSearch.keywordScreenGroups`: Keyword screen matches (relaxed when the strict query finds nothing)
and saved moments whose note or title matches, as source sessions.
One group more than `displayLimit` is returned so a cut list shows.

#### Fill snippets lazily for hits reaching the first limit groups
`RecallSearch.readableScreenGroups`: `screenGroups(readableScreens(fill(hits), query:), limit:)`, filling
only the hits that can reach the first `limit` groups. Dropping an
unreadable hit can only split a session, never merge two, so sessions
are settled in order of their best hit until no later one can rank
above the `limit`th group. Typically 5–20% of 2,000 hits get snippets.

#### fill preserves order so filled hits follow the batch offsets
`RecallSearch.readableScreenGroups`: `fill` keeps order, so the filled hits follow the batch's offsets.

#### Classify each timestamp once to avoid quadratic scans on long sessions
`RecallSearch.screenGroups`: Group adjacent moments per source/day, then restore relevance order.
Each timestamp is classified once; long sessions avoid quadratic scans.

#### Session means same app, window, day, gaps under five minutes
`RecallSearch.sessions`: Hit offsets per source session (same app, window and day, no gap over
five minutes), each in relevance order, sessions by their best hit.

#### Date scope keeps agent notes last modified inside it
`RecallSearch.search`: A date scope keeps the notes last changed inside it.

#### Text and picture vectors share one scale and rank with keyword hits
`RecallSearch.search`: Text and picture vectors on one scale, ranked with the keyword
hits (`ScreenSearch`). With no vectors yet the keyword results stay.

#### Read and rank 2,000 captures off the main actor for responsiveness
`RecallSearch.search`: Up to 2,000 captures' records and passages: read and ranked
off the main actor, which keystrokes and drawing need.

### `LokalBot/Views/Ask/AskAnswerSources.swift`

#### Records which citation passage is open and whether from answer text or sources list
`OpenCitation`: Which citation's passage is showing, and where it was opened: at the
number in the answer's text, or at the number in the sources list.

#### Row per cited source with numbers and times, plus a row for personal context
`AnswerSourcesList`: The list that ends an answer: a row per meeting, file, screen moment or
saved agent note it cited, with the answer's numbers and their times, and one row for what the
person told LokalBot about themselves when that went into the answer.

#### Number opens passage here; meeting time opens meeting at that moment
`AnswerSourcesList.citationGroups`: Each number opens its passage here; a meeting time opens the meeting
at that moment.

#### Notes are read only while Read coding agent notes is on
`AnswerSourcesList.loadCitedNotes`: Notes are read only while Read coding agent notes is on, as on the
rest of the page.

#### Shows what the person told LokalBot that went into the answer; Quick Recall shares it
`PersonalContextRow`: What the person told LokalBot about themselves that went into this answer.
Quick Recall's sources end with the same row.

#### Citation pill is filled while its passage is showing
`CitationPill`: A citation number as a small pill. Filled while its passage is showing.

#### Passage read in place; nothing leaves Ask until play, show or open is used
`CitationPassagePopover`: The passage a citation points at, read in place: the source, its time and
speaker, the quote, then a button to play from there or show the file,
and one to open the source. Nothing leaves Ask until one of those is used.

#### Locate click in answer text since the single selectable text has no per-link frame
`CitationClickProbe`: Finds where in an answer's text a citation number was clicked, so its
passage opens at the number. The answer is one selectable text, which has
no frame per link; the click that activated the link has a location.

#### Nil when link not activated by an in-bounds click (keyboard, VoiceOver)
`CitationClickProbe.clickRect`: The clicked spot in the text's own coordinates, or nil when the link
was not activated by a click inside it (the keyboard, VoiceOver).

#### Probe sits behind answer text and shares its bounds
`CitationClickProbeView`: Sits behind the answer text and shares its bounds.

#### SwiftUI coordinates start at the top leading corner
`ProbeView.isFlipped`: SwiftUI's coordinates start at the top leading corner.

### `LokalBot/Views/Ask/AskMatchesList.swift`

#### Same list under field, in tray in a conversation, and under failed answers
`AskMatchesList`: The matches for what is typed in Ask: a row per meeting, screen moment,
file or saved agent note, each with the lines that matched. The same list sits under the field
on a new question, in the tray above the field inside a conversation, and
under an answer that failed. Clicking a title or a line opens it.

#### Searched text so a file opens with its words marked
`AskMatchesList.query`: The searched text, so a file opens with its words marked.

#### Page keeps expansion state when the tray lays the list out more than once
`AskMatchesList.expandedRows`: Rows whose folded lines are showing. The page keeps this when it
lays the list out more than once (the tray, which may scroll).

#### 148 pt fits '0:35 · Other speaker' beside matched words
`AskMatchesList.kindColumnWidth`: Wide enough for "0:35 · Other speaker" beside the matched words.

#### Return pressed while matches arrive; question sends once they are in
`AskMatchesHeader.isWaitingToAsk`: Return was pressed while matches were still arriving; the question
goes out once they are in.

#### Hidden from accessibility since the field's own hint announces the keys
`AskMatchesHeader.hintRow`: The keys are announced by the field's own hint.

### `LokalBot/Views/Ask/AskView.swift`

#### One field: matches mid-page for new question, tray above docked field in conversation
`AskView`: One field, one flow: typing lists what matches, Return asks about it. A
new question has the field mid-page with its matches underneath; inside a
conversation the field is docked and the matches rise in a tray above it,
so the conversation stays on screen.

#### Keyword answer limited to matches; full question reads chosen sources
`AskContent.matches`: What the field's text matches. A keyword's answer is limited to
these; a full question reads the chosen sources (`AskAnswerScope`).

#### Return asks; after arrow keys onto a match it opens that match
`AskContent.cursor`: In the field, Return asks. Once the arrow keys move onto a match,
Return opens that match.

#### Escape folds the matches tray to its heading
`AskContent.trayCollapsed`: Escape folds the tray to its heading so the conversation is clear.

#### Field is one view on both pages, keeping text and focus
`AskContent.page`: The field is the same view on both pages, so it keeps its text
and focus when the first answer turns the page into a thread.

#### Return can precede observer; keep queued question only for exact same text
`AskContent.searchContent`: Return can arrive before this observer. Preserve only a request
for this exact text; editing a queued question cancels it.

#### Saved conversation selection is explicit mode switch; clear old search query
`AskContent.body`: A saved conversation selection is an explicit mode switch. An
old search query must not stay in the selected conversation's field.

#### Single moment is attached; collections are retrieval boundaries, not copied into prompt
`AskContent.consumeNavigationHandoff`: A single moment is an attachment; a result/session collection is a
retrieval boundary. Do not eagerly copy an entire session into a prompt.

#### Return asks; after arrow keys moved onto a match it opens it
`AskContent.submitQuery`: Return asks. After the arrow keys moved onto a match it opens that
match instead.

#### Escape first returns keyboard to field, then folds the tray
`AskContent.leaveMatches`: Escape first returns the keyboard to the field, then folds the tray.

#### Keyword answer reads listed sessions' screen moments plus any attached screen
`AskContent.answerScreenIDs`: The screen moments a keyword's answer reads: the listed sessions and
any attached screen.

#### Never submit previous text's rows if Return beats onChange
`AskContent.askAboutResults`: Never submit rows belonging to the previous text if Return beats
onChange. Completion below uses the same scoped submission path.

#### Answer scope: full question reads chosen sources; keyword limited to listed matches; Remember limits nothing
`AskContent.askAboutResults`: A full question reads everything in the chosen sources and dates,
so the sources menu keeps saying what was chosen. A keyword is a
search being asked about: its answer is limited to the listed
matches, and the menu then names that limit. A "Remember …"
statement is saved as is and limits nothing. Scope set on purpose
before this (a handed-over meeting, an attached screen, the menu's
"Only …" state) stays in `recall.state` either way.

#### Sources button names a narrowing limit and menu offers to widen it
`AskContent.sourcesMenu`: Sources, their finer filters and the way to source permissions. When
the question is limited to earlier matches or to evidence another page
handed over, the button names that limit and the menu offers to widen it.

#### Widening lifts evidence limit back to previously chosen sources
`AskContent.widenSources`: Lift the limit to particular meetings and screen moments, back to the
sources that were chosen before it.

#### A source not offered never counts as the last one
`AskContent.toggleSource`: A source that is not offered (Files while it is off) never counts as the last one.

#### One date scope applies to search and answers across every source
`AskContent.timeMenu`: One date scope for search and answers across every source.

#### Show inference status only when remote or blocked changes where the question goes
`AskContent.inferenceStatus`: Shown only when it changes where the question goes: a remote model,
or a model connection that is blocked.

#### Sending turns page into conversation; day scope prepended so agent uses right date
`AskContent.escalate`: Hand the question to the assistant. The send appends messages, which
turns the page into the conversation; clearing the field folds the
matches away. A day scope from Capture is prepended so the agent
reaches for its activity-summary tool with the right date.

#### In a conversation matches rise above docked field; no matches means no tray
`AskContent.matchesTray`: Inside a conversation: the matches rise above the docked field and
the thread stays where it is. Nothing to list means no tray.

#### Never leave previous query's rows available to Return
`AskContent.runSearch`: Never leave rows from a previous query available to Return.

#### UI-test host can hold retrieval in flight for deterministic Return tests
`AskContent.runSearch`: Hold retrieval in flight for deterministic hosted Return tests.

#### Empty-page suggestions come from already loaded data, plus one search word
`AskContent.suggestions`: Questions about the person's own latest meeting, a colleague and a
project, read from what is already loaded, then one word to search.

#### Menu that limits the question is tinted
`AskMenuChrome`: The bordered look of the composer's two menus. A menu that limits the
question (to earlier matches, a filter, or dates) is tinted.

### `LokalBot/Views/Ask/FileSearchResultRow.swift`

#### Open PDFs and media in LokalBot windows; no QuickTime scripting avoids Automation permission
`FileSearchOpener`: Opens a file found by search. A PDF opens in a LokalBot window at the
matched page with the query's words marked; a recording or video plays in
a LokalBot window from the matched moment (no QuickTime scripting, so no
Automation permission); anything else opens in its default app.

#### Close observer block holds the player, so remove it with window
`FileSearchOpener.closeObservers`: Each window's close observer. Its block holds the player, so it is
removed with the window.

#### Playback starts at the 30-second sound window start or frame time
`FileSearchOpener.play`: Plays from the matched moment: the start of its 30-second sound
window, or the frame's time.

#### Highlight query words of three or more letters
`FileSearchOpener.highlights`: The query's words (three letters or more) wherever they occur on the page.

### `LokalBot/Views/Ask/QuickRecallAnswer.swift`

#### Answer sources numbered as in answer; meeting row carries jump time; opening shows main window
`QuickRecallAnswerSources`: The sources under an answer in the Quick Recall window: a row per
citation, numbered as in the answer, laid out like that window's results.
A meeting's row carries the time it jumps to; the second line quotes the
passage with the question's words marked. Opening a row shows the source
in the main window.

#### Citation details are read from data already stored on this Mac
`QuickRecallAnswerSources.sources`: What each citation points at, by its number. Read from what is
already stored on this Mac.

#### Files and agent notes read only while their settings are on
`QuickRecallAnswerSources.load`: Files and agent notes are read only while their own settings are on,
as on the Ask screen.

#### A Remember receipt was saved without any model, so no inference label
`QuickRecallAnswerFoot.body`: A "Remember …" receipt was saved here without any model.

#### Scope label uses the Ask sources menu's wording
`QuickRecallAnswerFoot.scopeLabel`: What the last question was limited to, in the words the Ask screen's
sources menu uses: "All sources", one meeting's title, or how many
meetings and screen moments.

### `LokalBot/Views/Ask/QuickRecallRow.swift`

#### Command-Return asks from anywhere; Return asks once arrow keys are on row
`QuickRecallAskRow`: The quiet row pinned under the results. ⌘Return asks from anywhere;
Return asks once the arrow keys are on this row.

#### Trailing padding ends where a row's time ends
`QuickRecallGroupHeader.body`: Ends where a row's "when" ends.

#### Answer sources reuse these lines, with meeting time after title
`QuickRecallRowText`: The two text lines of a row. An answer's sources use the same lines, with
a meeting's time after the title.

#### Return mark slot always reserved so selection never reflows a line
`QuickRecallReturnHint`: The Return mark at the end of the selected row. Its slot is always
reserved, so selection never reflows a line.

### `LokalBot/Views/Ask/QuickRecallTextField.swift`

#### One AppKit responder owns insertion and list keys to avoid doubled typed characters
`QuickRecallTextField`: The Quick Recall field. One AppKit responder owns both text insertion and
the keys that move through the list, as the ⌘K palette's field did:
combining SwiftUI's text-field bridge with ancestor `onKeyPress` handlers
can deliver the same printable key through two input paths on macOS, so a
typed character arrived twice.

#### Placeholder is a localization catalog key
`QuickRecallTextField.placeholder`: A catalog key.

#### Hint set on AppKit field; SwiftUI accessibility modifier would hide identifier and value
`QuickRecallTextField.hint`: What the keys do, for VoiceOver. A catalog key. It is set on the
AppKit field itself: a SwiftUI accessibility modifier here would wrap
the field and hide its identifier and value.

#### Each new focusRequest value moves keyboard focus to the field
`QuickRecallTextField.focusRequest`: Each new value moves keyboard focus to the field.

#### Command-Return handled here when it reaches field instead of Ask row shortcut
`QuickRecallTextField.onCommandSubmit`: ⌘Return, when it reaches the field instead of the Ask row's shortcut.

#### Up is -1, Down is 1; false leaves the key to the field
`QuickRecallTextField.onMove`: Up (-1) or Down (1). False leaves the key to the field.

#### Take focus once in a window even if not key; never activate app
`QuickRecallField`: Takes keyboard focus as soon as it is in a window, whether or not that
window is key yet: Quick Recall opens while LokalBot is still coming
forward from another app, and must be ready for typing when it arrives.
The field never activates the app or orders a window itself.

#### Window shown again after Escape can come back with nothing focused
`QuickRecallField.viewDidMoveToWindow`: A window shown again after Escape can come back with nothing focused.

#### Text field edits through the window's field editor, so check it
`QuickRecallField.attemptFocus`: A text field edits through the window's field editor.

### `LokalBot/Views/Ask/QuickRecallView.swift`

#### Quick Recall: grouped results, Return opens, Command-Return asks, recents before typing
`QuickRecallView`: The small window the system-wide shortcut and ⌘K open: type to search
meetings, screen history and files, run a command, or ask. Results are
grouped by kind; Return opens the selected one and ⌘Return asks, with the
answer shown here. Before anything is typed it lists recent items and the
commands.

#### Size is the window including title bar
`QuickRecallView.size`: The window, title bar included.

#### Groups whose heading expanded in place (commands)
`QuickRecallContent.expanded`: Groups whose heading was asked to list everything here (commands).

#### Command-Return pressed while word matches were still being found
`QuickRecallContent.pendingQuestion`: ⌘Return arrived while a word's matches were still being found.

#### Build groups once per update; hidden window redraws on every AppState change
`QuickRecallContent.body`: Built once per update: rows clean every result snippet, and the
window stays alive while hidden, redrawing on every AppState change.

#### Title bar counts in window height, so content gives it up
`QuickRecallContent.body`: The title bar is part of the window's height, so the content gives it up.

#### Return to results when conversation deleted or replaced elsewhere
`QuickRecallContent.body`: The conversation was deleted or replaced elsewhere.

#### Reset cursor when main window page's commands appear or vanish
`QuickRecallContent.body`: The commands of the main window's page came or went.

#### Field handles Escape; this covers a button focused via Full Keyboard Access
`QuickRecallContent.body`: The field handles Escape while it has the keyboard; this covers a
button that took focus with Full Keyboard Access.

#### Non-lazy stack: short list, commands reachable by VoiceOver before scrolling
`QuickRecallContent.resultList`: Not lazy: the list is short, and every command stays
reachable by VoiceOver and by name before it scrolls in.

#### Ask row pinned under results; Command-Return asks from anywhere
`QuickRecallContent.askRow`: Pinned under the results. ⌘Return asks from anywhere in the window.

#### Main window page's commands offered when window opened from it
`QuickRecallContent.commands`: Every palette command. Those of the page the main window is showing
(the Agent screen's) are offered when the window was opened from it.

#### app.meetings is newest first; merged source listed by merged meeting
`QuickRecallContent.recentMeetings`: The newest few meetings. `app.meetings` is kept newest first; a meeting
merged into another is listed by the merged one.

#### Agent notes are a source only while their setting is on
`QuickRecallContent.groups`: Agent notes are a source only while their own setting is on.

#### Matching commands listed at once; Return runs the first
`QuickRecallContent.search`: Matching commands are listed at once; Return runs the first.

#### Up/Down cycle rows and Ask row; inside an answer the field keeps them
`QuickRecallContent.move`: Up and Down go round the rows and the Ask row. Inside an answer the
field keeps them.

#### Return opens selected row; on Ask row and inside answer it asks
`QuickRecallContent.submit`: Return opens the selected row; on the Ask row, and inside an answer,
it asks.

#### Files open in own window or app, not main window
`QuickRecallContent.open`: Files open in their own window or app, not in LokalBot's main window.

#### Agent note opens the agent's own file, not main window
`QuickRecallContent.open`: A note opens the agent's own file, not LokalBot's main window.

#### Recording and dictation commands act on the app the person came from
`QuickRecallContent.runCommand`: Recording and dictation act on the app the person came from.

#### Show all opens Ask on this search narrowed to source; commands list in place
`QuickRecallContent.showAll`: "Show all N": a kind of result opens the full Ask screen on this
search, narrowed to that kind's source. Commands list here instead.

#### From results starts new conversation; in answer it is follow-up with prior scope
`QuickRecallContent.ask`: Asks here. From the results this starts a new conversation; inside an
answer it is a follow-up with the scope of the question before it.

#### If answer already being written, show it instead of dropping the key
`QuickRecallContent.ask`: An answer is already being written (asked here or in the main
window): show it instead of dropping the key.

#### Word or short phrase waits for matches; full question does not
`QuickRecallContent.ask`: A word or short phrase is answered from its matches, so it waits
for them. A full question does not depend on what is listed.

#### Select Ask row to show key was taken while matches arrive
`QuickRecallContent.ask`: Show that the key was taken while the matches arrive.

#### Back arrow restores results with the search that led to answer
`QuickRecallContent.showRecall`: The back arrow: the results, with the search that led to the answer.

#### Both surfaces share the conversation; opening it never asks again
`QuickRecallContent.continueInMainWindow`: Both surfaces share this conversation; opening it never asks again.

#### Meetings and screen moments open main window; files and notes open on their own
`QuickRecallContent.sourceOpened`: A source was opened from the answer. Meetings and screen moments show
in the main window; files and agent notes open on their own.

### `LokalBotTests/Models/Ask/AskPresentationTests.swift`

#### Saved agent notes come last when that source is on
`AskPresentationTests.testMatchesListMeetingsThenScreenMomentsThenFiles`: Saved agent notes, when that source is on, come last.

#### Files counts as part of All sources even while not offered
`AskPresentationTests.testSourcesMenuNamesTheChosenSources`: Files is part of "All sources" even while it is not offered.

#### All sources includes Agent notes whether or not the setting is on
`AskPresentationTests.testSourcesMenuNamesAgentNotesOnlyWhileTheyAreOffered`: "All sources" holds Agent notes whether or not the setting is on.

#### When only notes matched, the limit holds no meeting or screen moment
`AskPresentationTests.testSourcesMenuNamesAgentNotesOnlyWhileTheyAreOffered`: Only notes matched: the limit holds no meeting or screen moment.

#### When only files matched, no meeting or screen moment is left to name
`AskPresentationTests.testSourcesMenuShowsWhatAFollowUpIsLimitedTo`: Only files matched: no meeting or screen moment is left to name.

### `LokalBotTests/Models/Ask/AskRoutingTests.swift`

#### Ask page routing; typing never replaces the conversation
`AskRoutingTests`: What the Ask page shows: a new question or a conversation, and whether the
field's text lists matches. Typing never replaces the conversation.

#### A device's starting question is a focus, never a limit
`AskRoutingTests.testLimitedQuestionNamesItsLimitToTheModel`: Where a device's question started is a focus, never a limit.

### `LokalBotTests/Models/Ask/QuickRecallResultsTests.swift`

#### Many screen matches pushed meetings below the fold; loose command matches must not take Return
`QuickRecallResultsTests.testLooselyMatchingCommandsComeAfterTheSearchResults`: Forty screen matches used to push every meeting below the fold.
A search word that only sits inside a command's name ("ion" in "Start
dictation") must not put that command under Return.

#### A kind filling displayLimit while more matched reads 40+, never 40
`QuickRecallResultsTests.testACappedKindNeverReadsAsAnExactTotal`: The search lists at most `displayLimit` of a kind. A kind that filled
it while the search says more matched reads "40+", never "40".

#### Saved moments can fold sources, so fewer rows than cut sources still shows capped
`QuickRecallResultsTests.testScreensFoldedBySavedMomentsStillSayTheListWasCut`: A saved moment can stand for a whole screen source, so there can be
fewer rows than the sources the search listed and cut.

#### Capped kind keeps Show all; commands are counted, never capped
`QuickRecallResultsTests.testCommandsExpandInPlaceAndAreNeverCapped`: A capped kind keeps "Show all" even when its three rows are all it
lists here; commands are counted, never capped.

#### Up to three words answer from listed matches, as Cmd-Return always did
`QuickRecallResultsTests.testAWordOrShortPhraseReadsTheListedMeetingsAndScreens`: A word, or a phrase of up to three words, is answered from the listed
meetings and screen moments, as ⌘Return always was.

#### Quick Recall follows Ask's isFullQuestion rule: full question reads all sources
`QuickRecallResultsTests.testAFullQuestionReadsEverySource`: The Ask screen's rule (`AskAnswerScope.isFullQuestion`): a full
question reads everything in the sources, whatever is listed.

### `LokalBotTests/Models/Ask/QuickRecallRowModelTests.swift`

#### Regression: semantic-only saved moment ranked above keyword match
`QuickRecallRowModelTests.testSemanticOnlySavedCaptureKeepsItsRankBelowTheKeywordMatch`: Searching "onboarding" in the demo library listed the saved Slack
moment, related only by meaning, above the one capture with the word.

#### Meeting row line two starts with speaker, else where the words are
`QuickRecallRowModelTests.testAMeetingRowStartsItsLineWithWhoSaidIt`: Line two of a meeting row starts with who said it, from the search
hit's speaker, or with where the words are when nobody said them.

### `LokalBotTests/Models/Ask/RecallSourceScopeTests.swift`

#### A second handoff or restored conversation must keep the original source choice
`RecallSourceScopeTests.testClearingResultEvidenceRestoresExplicitSourceChoice`: A second handoff or a restored conversation must retain the original choice.

### `LokalBotTests/Views/Ask/AskReturnActionTests.swift`

#### Return in Ask always asks unless arrows picked a match; Quick Recall differs
`AskReturnActionTests`: Return in Ask asks, whatever was typed. It opens a match only after the
arrow keys moved onto one. (Quick Recall keeps Return for opening.)

#### AskIntent shapes the answer, not Return; Laya benchmark measures it
`testQuestionsAreRecognized`: `AskIntent` does not decide what Return does (it always asks). It
decides what the answer reads, and the Laya benchmark measures it.

#### Four or more words read as a question in any language
`testAFullQuestionReadsTheChosenSourcesEvenWhileMatchesAreListed`: The last three have no English question word and no question mark:
four or more words read as a question in any language.

#### With Ask memory off, short phrase is search and sentence reads sources
`testARememberStatementLimitsNothing`: With Ask memory off the words are judged like any others: a short
phrase is a search, a sentence reads the chosen sources.

#### Full question leaves scope unchanged; keyword names its limit in sources menu
`testTheSourcesMenuTellsTheTruthForBothKindsOfInput`: What the two cases leave in Ask's scope, and what the sources menu then
says: a full question changes nothing, a keyword names its limit.

#### Deliberately set scope stays for a full question
`testTheSourcesMenuTellsTheTruthForBothKindsOfInput`: Scope set on purpose stays for a full question: a meeting handed
over ("Ask about this meeting"), or the menu's "Only …" state.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
