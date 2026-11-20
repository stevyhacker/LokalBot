# 0074. Windows and Linux: app — pages / ask

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/ask/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/composer.rs`

#### Composer shows status line only when remote or blocked model changes destination
The field (`AskView.composerPanel`): screens attached as context, the
input, the two scope menus (sources, time), Ask or Stop, and a line under
it only when a remote or blocked model changes where the question goes.

#### Inference mirrors Swift InferencePresentation for where answers are computed
`Inference`: Where answers are computed (`InferencePresentation`).

#### A think plan has its own approval entry, never a URL origin
`inference`: A plan has its own approval entry, never a URL origin.

#### Field is mid-page on new question, docked with fade in conversation
`AskPage.render_field_column`: The field and what belongs to it, at the reading width. On a new
question it sits mid-page; in a conversation it is docked below the
thread with a fade above it.

#### Pinned screens row mirrors pinnedContextRow, with remove one or all
`AskPage.render_pins`: `pinnedContextRow`: the screens attached to the next question, each by
its picture, with a way to take one or all off.

#### A menu that limits the question is tinted
`AskPage.menu_button`: The bordered look of the two menus; one that limits the question (to
earlier matches, a filter or dates) is tinted.

#### Sources menu names a limit to earlier matches and offers to widen
`AskPage.render_sources_menu`: Sources, their finer filters and the way to source permissions. When
the question is limited to earlier matches or to evidence another page
handed over, the button names that limit and the menu offers to widen it.

#### One date scope applies to search and answers across every source
`AskPage.render_time_menu`: One date scope for search and answers across every source: Any time,
Today, Yesterday, Last 7 days, a chosen day, and the way to choose one.

#### Inference status shows only for a remote model or blocked connection
`AskPage.render_inference_status`: Shown only when it changes where the question goes: a remote model, or
a model connection that is blocked.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/history.rs`

#### Conversation list mirrors Swift ChatConversationList
The conversation list (`ChatConversationList`).

#### Unsaved new question is listed and selected until it is asked
`render_history`: The unsaved new question is listed, selected, until it is asked.

#### Draft row mirrors ChatConversationList.row for a conversation with no question
`AskPage.render_draft_row`: "New question" and when it was started (`ChatConversationList.row` for
a conversation with no question yet).

#### List title mirrors Swift ChatViewModel.displayTitle
`display_title`: The list title (`ChatViewModel.displayTitle`).

#### Titles take first line, drop polite prefixes, cap at 38 characters
`compact_title`: `ChatViewModel.compactTitle`: first line, polite prefixes dropped, ≤ 38 characters.

#### Row timestamp: time today, Yesterday, else full date
`row_timestamp`: "10:42 AM" today, "Yesterday", else "Oct 8, 2026".

#### History groups: Today, Yesterday, Previous 7 Days, Earlier, filtered by query
`sections`: Today, Yesterday, Previous 7 Days and Earlier, filtered by `query`.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/matches.rs`

#### Matches rows appear under field, in tray, and under failed answers
The matches for what is typed in Ask (`AskMatchesList`, `AskMatchesHeader`):
a row per meeting, screen moment, file or saved agent note, each with the
lines that matched. The same rows sit under the field on a new question,
in the tray above the field inside a conversation, and under an answer
that failed. Clicking a title or a line opens it.

#### Card style has wider rows and a column for each line's kind
`ListStyle::Card`: Under the field or an answer: wider rows, a column for each line's kind.

#### A meeting lists three matching lines before folding the rest
`FOLDED_LINES`: How many matching lines a meeting lists before folding the rest.

#### Kind column width fits "0:35 · Other speaker"
`KIND_COLUMN`: Wide enough for "0:35 · Other speaker" beside the matched words.

#### Tray never covers more of the conversation than this height
`TRAY_MAX_HEIGHT`: The tray never covers more of the conversation than this.

#### Row frame (card, segment or tray) is supplied by the caller
`MatchRow`: One row of the list; its frame (card, segment or tray) is the caller's.

#### Header shows count, search progress and keys acting on matches
`AskPage.render_matches_header`: "Matches · 3 in 1 meeting", the search in progress, and the keys that act
on the matches.

#### Rows ordered meetings, screens, files, notes; selected tracks arrow keys
`AskPage.match_rows`: The rows of `found`, in list order: meetings, screen moments, files and
agent notes. `selected` is the row the arrow keys are on.

#### Matches shown as one card for an answer that failed
`AskPage.match_card`: The matches as one white card, for an answer that failed.

#### Each row is its own scroll child so arrow keys can scroll it into view
`AskPage.render_matches_under_field`: A new question: the matches sit under the field. Each row is its own
child of the scrolling column, so the arrow keys can bring one into view.

#### Empty state names what Activity alone can do and the way out of filters
`AskPage.render_no_matches`: "No matches for “…”", or what Activity alone can do, and the way out of
the filters that hid them.

#### In a conversation matches rise above docked field; empty means no tray
`AskPage.render_matches_tray`: Inside a conversation: the matches rise above the docked field and the
thread stays where it is. Nothing to list means no tray.

#### Note row opens the agent's own file, not a LokalBot copy
`AskPage.note_row`: A note a coding agent saved for itself: its title, the agent and
project, then the matched words. It opens the agent's own file.

#### Matched words keep own direction in RTL so a cut line loses its end
`AskPage.row_line`: Matched words keep their own direction in a right-to-left
interface, so a cut line loses its end, not its start.

#### Source tile mirrors AskSourceTile, shared by rows and answer sources
`source_tile`: `AskSourceTile`: the small rounded tile that leads a row here and in an
answer's sources list.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/mod.rs`

#### Ask flow: typing lists matches, Return asks, full question reads all sources
Ask (`AskView.swift`, `ChatView.swift`): saved conversations in a
resizable column; beside it one field, one flow. Typing lists what matches
(under the field on a new question, in a tray above it inside a
conversation, which stays put); Return asks, ↓ then Return opens a match.
A full question reads everything in the chosen sources and dates; a word
or short phrase is answered from its matches (`AskAnswerScope`).

#### A word's answer is limited to matches; a full question reads chosen sources
`Results`: What the field's text matches (`AskMatches`). A word's answer is limited
to these; a full question reads the chosen sources.

#### In the field Return asks; on a match it opens it
`Results.cursor`: In the field, Return asks; on a match, it opens it.

#### Used by Ask and Quick Recall to open a moment in Timeline
`open_screen_moment`: Opens a screen moment from Ask or Quick Recall in Timeline
(`ScreenMomentDetailView`).

#### Holds long questions the user expanded to show in full
`TurnState.questions`: Long questions shown in full.

#### Stale reads, including those before a delete, are discarded by counter
`AskPage.reloads_started`: How many reloads have started, and the latest one taken: a read that
started earlier and finished later is out of date, and so is every
read that started before a conversation was deleted here.

#### Records why saved conversations could not all be opened or saved
`AskPage.conversations_problem`: Why saved conversations couldn't all be opened or saved.

#### None means a new, empty conversation
`AskPage.selected`: The conversation on screen; `None` is a new, empty conversation.

#### Scope restored once a conversation selected before load is loaded
`AskPage.pending_restore`: Selected before it was loaded: its scope is restored once it is.

#### Evidence boundary from Ask This Meeting or asking about results
`AskPage.meeting_scope`: Evidence boundary from "Ask This Meeting" or from asking about results.

#### Screen moments among results asked about, or a Timeline session's moments
`AskPage.screen_scope`: The screen moments among the results a question was asked about, or a work
session's moments from Timeline.

#### Sources to restore when a session boundary is cleared
`AskPage.sources_before_evidence`: The sources to go back to when a session's boundary is cleared.

#### Asking about results keeps selected Activity, and Files with file rows
`AskPage.scope_from_results`: Asked about results: a selected Activity source stays, and Files with file rows.

#### Asking about results keeps Agent notes only if note rows were among them
`AskPage.scope_had_notes`: Asking about results kept Agent notes: note rows were among them.

#### Attached screens are primary evidence for the next question
`AskPage.pins`: Screens attached to the next question as primary evidence.

#### Filter limits screen results and assistant's screen search to one app
`AskPage.screen_app`: Limit screen results and the assistant's screen search to one app.

#### Question asked during a running search waits for its results
`AskPage.pending_question`: A question asked while its search was still running.

#### Escape folds the tray above a docked field to its heading
`AskPage.tray_collapsed`: Escape folded the tray above a docked field to its heading.

#### Press on a number closes its passage instead of reopening it
`AskPage.passage_dismissed`: The passage a press outside it just closed, so a press on its own
number closes it rather than opening it again.

#### Matches for a failed answer keyed by answer; None while loading
`AskPage.failed_matches`: Matches for a failed last answer, by answer; `None` while they load.

#### Placeholder is rewritten when page or language changes
`AskPage.placeholder`: The page and language the field's placeholder was written for.

#### Cited screen moments are loaded on demand
`AskPage.screen_citations`: Screen moments the answers cite, loaded on demand.

#### Only conversations that used claims wake the credential store
`AskPage.reload_conversations`: Only conversations that used it wake the credential store.

#### An answer still streaming must not bring a deleted conversation back
`AskPage.delete_conversation`: An answer still being written doesn't bring it back.

#### In-flight reads may still list a deleted conversation, so none are applied
`AskPage.delete_conversation`: A read already under way may still list it, so none of those is
taken; the read below, after the file is gone, replaces them.

#### Consumes question handed over by another page (navigationHandoff)
`AskPage.take_request`: Consumes a question handed over by another page (`navigationHandoff`).

#### Quick Recall's Show all for one kind searches only that source
`AskPage.take_request`: Quick Recall's "Show all" for one kind searches only that source.

#### A single moment is an attachment, not a retrieval boundary
`AskPage.take_request`: A single moment is an attachment, not a retrieval boundary.

#### A session's moments are a boundary, never copied into the prompt
`AskPage.take_request`: A session's moments are a boundary: never copied into the prompt.

#### Handed-over question is sent as is, within handed-over scope
`AskPage.take_request`: A handed-over question is sent as it is, within what was handed over.

#### Mirrors clearEvidence: undoes a session boundary's source narrowing
`AskPage.restore_sources`: `clearEvidence`: a session's boundary narrowed the sources; this undoes it.

#### Mirrors resetAskScope: reopen everything for a new question
`AskPage.reset_scope`: `resetAskScope`: everything open again, for a new question.

#### Composer returns to latest question's scope so follow-ups cannot reach further unnoticed
`AskPage.restore_question_scope`: `restoreAskScope`: the composer goes back to what the conversation's latest
question asked within, so what's asked next can't reach further unnoticed.

#### Handed-over question puts caret at end, as on the Mac
`AskPage.set_composer_text`: A multi-line field puts its caret at the start; a question
handed over from elsewhere goes on from its end, as on the Mac.

#### Mirrors AskRouter.phase: conversation once turns exist or streaming; typing when text
`AskPage.ask_phase`: `AskRouter.phase`: a conversation once the selected one has turns (or
one is being written), and typing whenever the field holds text.

#### Return asks; after arrow keys onto a match it opens that match
`AskPage.submit`: Return asks. After the arrow keys moved onto a match it opens that match
instead (`AskReturnAction`).

#### Question typed before matches arrive waits so it never reads stale rows
`AskPage.ask_about_results`: `askAboutResults`: the button and Return. A question typed before its
matches are in waits for them, so it never reads rows of earlier text.

#### Field questions apply AskAnswerScope; suggestions and handovers are sent as is
`AskPage.ask`: Sends `question`. `from_field` applies `AskAnswerScope`: asked from the
field, a word or short phrase is limited to its listed matches; a
suggestion or a handed-over question is sent as it is.

#### Full question reads chosen sources; short phrase limited to listed matches
`AskPage.ask`: A full question reads everything in the chosen sources and dates, so
the sources menu keeps saying what was chosen. A word or short
phrase is a search being asked about: its answer is limited to the
listed matches, and the menu then names that limit. A "Remember …"
statement is saved as is. Scope set on purpose before this (a meeting
handed over, an attached screen, the menu's "Only …" state) stays.

#### Listed matches bound meetings and screen moments to the rows
`AskPage.ask`: Bounds meetings and screen moments to the rows.

#### Attached screens stay the boundary for later questions; only text leaves
`AskPage.ask`: What it attached stays the boundary for the questions after it; only
the captured text leaves (`clearPins(restoringScope: false)`).

#### Retry re-asks within the original scope, not the composer's current one
`AskPage.retry`: `ChatViewModel.retry`: asks the question behind a failed turn again, within
the scope it was asked in, not whatever the composer holds now.

#### Ask again reuses the sources, dates and evidence of the original
`AskPage.ask_again`: `ChatViewModel.askAgain`: a finished answer's question, asked again as
a new turn within the sources, dates and evidence it was asked in.

#### Return can arrive before search; only a request for this exact text stays
`AskPage.on_query_changed`: Return can arrive before this; only a request for this exact text stays.

#### Never leave rows from a previous query available to Return
`AskPage.run_search`: Never leave rows from a previous query available to Return.

#### Word matches show first; meaning matches are fused in second
`AskPage.run_search`: Meaning second, so words show at once.

#### Attached moments outside chosen dates are dropped when dates change
`AskPage.toggle_pin`: Attaches a screen moment to the next question, or takes it off. Attached
moments outside the chosen dates are dropped as the dates change.

#### Returns false when key belongs to field (Up in field or no matches)
`AskPage.move_cursor`: The arrow keys move between the field and the matches. `false` when
the key is the field's (Up in the field, or nothing listed).

#### Under the field the heading is the scroll column's first child
`AskPage.move_cursor`: Under the field the heading is the scrolling column's first child.

#### Escape order: return to field, stop answer, fold tray; false if not Ask's
`AskPage.escape`: Escape first returns the keyboard to the field, then stops an answer
being written, then folds the tray. `false` when it isn't Ask's.

#### Widening lifts meeting/screen limit back to sources chosen before it
`AskPage.widen_sources`: Lifts the limit to particular meetings and screen moments, back to the
sources chosen before it (`widenSources`).

#### Explicit source choice supersedes an earlier temporary narrowing's way back
`AskPage.toggle_source`: An explicit source choice supersedes an earlier temporary narrowing's
way back (`chooseSources`).

#### Provides sources menu button text and its Only rows
`AskPage.scope_summary`: What the sources menu's button says, and its "Only …" rows.

#### Attached screens limit the screen source to themselves
`AskPage.scope_summary`: Attached screens limit the screen source to themselves.

#### Field sits about a sixth down, clamped between 28 and 150 pt
`AskPage render new question`: The field sits a sixth of the way down, never past 150 pt.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/model.rs`

#### Pure Ask logic mirroring AskRouting and AskPresentation; only AnswerScope changes reads
What Ask decides and shows, without drawing it (`AskRouting.swift`,
`AskPresentation.swift`): where matches sit, what Return does, what an
answer reads, what the sources menu says, how citations group into an
answer's sources list, and which questions an empty page suggests. Nothing
here changes what a question may read beyond `AnswerScope`.

#### Mirrors AskPhase.Page: new question mid-page, conversation docks field
`PageKind`: `AskPhase.Page`: a new question has the field mid-page; a conversation
docks it below the thread.

#### Typing never replaces the conversation
`AskPhase`: `AskPhase`: typing never replaces the conversation.

#### Question is 2+ words ending in ?, or 3+ words starting with question word
`is_question`: `AskIntent.isQuestion`: two or more words ending in "?", or three or more
that start with a question or request word.

#### Return asks; only after arrow keys onto a match does it open it
`ReturnAction`: What Return does in Ask (`AskReturnAction`): it asks. Only after the arrow
keys moved onto a match does it open that match.

#### Full question reads chosen sources; short phrase reads listed matches; Remember limits nothing
`AnswerScope`: What an answer asked from the field reads (`AskAnswerScope`). A full
question reads everything in the sources and dates the two menus show,
whether or not matches are listed. A word or short phrase is a search the
person then asks about, so its answer reads the listed matches. A
"Remember …" statement is saved as it is and limits nothing. Scope already
set on purpose (a meeting handed over, an attached screen, the menu's
"Only …" state) is not this type's to change.

#### Four words counts as a question in any language; is_question is English-only
`AnswerScope::FULL_QUESTION_WORDS`: Anything longer than a short phrase is a question in any language:
`is_question` only knows English question words.

#### Cursor None is the field where Return asks; on a match Return opens it
`MatchCursor`: Where the keyboard is (`AskMatchCursor`): in the field (`None`), where
Return asks, or on a match, where Return opens it.

#### Down enters and walks matches; Up from first returns; false lets field keep key
`MatchCursor.step`: Down moves from the field into the matches and along them; Up from the
first match returns to the field. `false` when the key isn't the
cursor's to handle, so the field keeps it.

#### Cursor is clamped so changing matches never strand it past the list
`MatchCursor.clamp`: Matches that arrive or leave never strand the cursor past the list.

#### Count label counts meetings, else sources; truncated list shows 40+
`matches_count_label`: "3 in 1 meeting" when only meetings matched, else the number of sources;
a list that was cut says "40+" (`AskMatches.countLabel`).

#### Summary names chosen sources, or the earlier-match or evidence limit
`ScopeSummary`: The sources menu's button and first rows (`AskScopeSummary`): the chosen
sources and finer filters, or, when the question is limited to earlier
matches or to evidence another page handed over, what that is.

#### Narrowed means limited to particular meetings or screen moments
`ScopeSummary.narrowed`: Limited to particular meetings or screen moments.

#### Text names the limit for the checked Only row
`ScopeSummary.narrowed_to`: What the question is limited to, for the checked "Only …" row.

#### What bound question still reads, when limit holds no meeting or screen
`ScopeInput.effective`: What the bound question still reads, for a limit that holds no meeting
and no screen moment.

#### A limit with no meeting or screen moment names what remains
`remaining_sources`: A limit that holds no meeting and no screen moment names what remains.

#### Grouping citations by source never renumbers answer citations
`SourceGroup`: One source an answer cited, with the numbers in the answer that point at
it (`AnswerSourceGroup`). Grouping never renumbers.

#### Numbers are 1-based as the answer displays them
`SourceGroup.entries`: 1-based numbers as the answer shows them, with their citations.

#### Rows ordered by first citation; meeting_key and file_key merge short ids and passages
`source_groups`: A row per meeting, screen moment, file or note, in the order the answer
first cites them (`AnswerSources.groups`). `meeting_key` names the meeting
a citation resolves to, so a short id and a full one share a row;
`file_key` names a cited passage's file, so two passages of one file do.

#### Transcript line a citation can quote, mirrors CitationPassage.Line
`PassageLine`: A transcript line a citation can quote (`CitationPassage.Line`).

#### Citations carry whole seconds: starting line wins, else current, else last before
`passage_line`: The line a meeting citation names (`CitationPassage.line`). Citations carry
whole seconds, so the line that starts in that second wins; otherwise the
line being said then, otherwise the last one before it.

#### Drops Markdown marks and joins lines but keeps matched markers
`plain_snippet`: A matched passage as reading text: a summary's Markdown headings, bullets
and emphasis marks dropped and its lines joined, the «matched» markers kept
(what `RecallPassage.excerpt` leaves on the Mac).

#### Quote strips search markers and breaks, cutting at a word when long
`quote`: Stored text as a short quote (`CitationPassage.quote`): search markers and
line breaks removed, cut at a word once it runs long.

#### No ask again for failed, Remember, unknown scope, or attached screens (text never saved)
`ask_again`: `ChatViewModel.askAgainQuestion`: a finished answer's question, and the
sources, dates and evidence limits it was asked within. Not for a failed or
"Remember …" turn, a question whose scope is unknown, or one with attached
screens (their captured text never reached disk).

#### General questions used when nothing personal can be named
`SUGGESTIONS`: The app's general questions, when nothing of the person's own can be named.

#### Personal project, meeting, colleague questions plus a word; else general questions, no word
`suggestions`: Questions about the person's own project, latest meeting and a colleague,
then one word to search for (`AskSuggestions.build`). With none of those
to name, the general questions stand in and no word is offered.

#### Keyword is first single-word name, else longest distinctive word
`keyword`: One word worth searching for: the first name that is a single word, else
the longest distinctive word in the names.

#### Moment label shows the year only when not this year
`moment_label`: "Nov 12 at 11:00 AM", with the year only once it isn't this year
(`AskDateLabel.moment`).

#### Day label shows the year only when not this year
`day_label`: "Nov 12", with the year only once it isn't this year (`AskDateLabel.day`).

#### No divider for a conversation starting today since each question has a time
`visible_date_divider`: The divider a question shows above it (`visibleDateDividerTitle`): a
conversation that starts today needs none, as each question has its time.

#### Approved key rule: keywords and questions alike are asked
`return_asks_unless_a_match_was_picked`: The approved key rule: keywords and questions alike are asked.

#### A question or four words in any language reads all chosen sources
`a_full_question_reads_the_chosen_sources`: A question, or four words in any language, reads everything chosen.

#### Nothing listed or a Remember statement leaves nothing to narrow to
`a_full_question_reads_the_chosen_sources`: Nothing listed, or a statement to remember: nothing to narrow to.

#### A file not known yet keeps its passage on its own row
`citations_group_by_source_without_renumbering`: A file not known yet keeps its passage on its own row.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/passage.rs`

#### Passage popover is read in place; nothing leaves Ask until a button is used
The passage a citation points at, read in place (`CitationPassagePopover`):
the source, its time and speaker, the quote, then a button to play from
there or show the file, and one to open the source. Nothing leaves Ask
until one of those is used. Everything shown is already stored here.

#### Citation number is 1-based as the answer shows it
`OpenPassage.number`: 1-based, as the answer shows it.

#### Screen moment text is quoted shorter than a transcript line
`SHORT_QUOTE`: A screen moment's text is quoted shorter than a transcript line.

#### Files and notes are read only while their sources are on
`AskPage.open_passage`: Files and notes are read only while they are on, as on
the rest of the page.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/remember.rs`

#### Personal Context receipt after Remember with Undo, plus list of claims used
What Personal Context adds to a conversation (`RememberReceiptCard`,
`PersonalContextDisclosure`): the receipt after "Remember …", with Undo, and
the list of what an answer was given.

#### Edit runs off main thread; failed save is surfaced so Undo never looks done
`AskPage.edit_claim`: Runs one edit off the main thread. One that could not be saved says
so, as in Settings → About you: Undo must not look done.

#### Last sources row lists what the person told LokalBot that fed the answer
`AskPage.render_used_claims`: The sources list's last row (`PersonalContextRow`): what the person told
LokalBot about themselves that went into this answer.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/scope.rs`

#### Files and Agent notes count in All sources whether on or off, offered only while on
What a question may draw on: sources and a date scope (`AskSourceScope`,
`AskDateScope`). Files and Agent notes are part of "All sources" whether or
not they are on, so turning one on or off never makes an earlier question
look narrowed; each is offered only while it is on.

#### Files and Agent notes are choosable only while each is on
`Source.available`: The sources a person can choose now: Files and Agent notes only while
each is on.

#### Toggle keeps at least one source selected
`Sources.toggle`: Toggles a source, keeping at least one selected.

#### Legacy turn with no saved sources means all sources
`Sources.from_saved`: The sources a saved question named, or all of them on a legacy turn.

#### Inclusive range keeps its days whenever a saved question is reopened
`DateScope::Range`: Both ends included: a saved question's range, which keeps its days
whenever it is reopened.

#### Bounds are [since, until) in UTC; None for any time
`DateScope.bounds`: `[since, until)` in UTC; `None` for any time.

#### Today is saved as the actual day it was
`DateScope.storage_key`: `AskDateScope.storageKey`: "Today" is saved as the day it was.

#### Unparseable key means no days, as on Mac; turn already marked ambiguous
`DateScope.from_storage_key`: The days a saved question was limited to. A key that doesn't parse names
no days, as on the Mac; such a turn was already marked ambiguous.

#### What a question is bound to beyond sources, mirroring RecallWorkspaceState
`Evidence`: What a question is bound to, beyond its sources (`RecallWorkspaceState`).

#### Evidence boundary from Ask This Meeting or asking about results
`Evidence.meetings`: Evidence boundary from "Ask This Meeting" or from asking about results.

#### Asking about results keeps Activity (no rows to bound), Files and Agent notes only if rows shown
`Evidence.from_results`: Asked about results: Activity has no result rows to bound, so a selected
Activity source stays, or "How long was I in Figma today?" would lose the
only tool that answers it. Files stays when file rows were among them,
and Agent notes when note rows were.

#### Civil days of attached screens, sorted, each once
`Evidence.pin_days`: The civil days of those screens, sorted, each once.

#### What Ask goes back to when a saved question is reopened
`Restored`: What Ask goes back to when a saved question is reopened
(`currentQuestionScope`, `restoreAskScope`).

#### Restored sources stay as named; nothing excluded returns and evidence stays bound
`restore`: A saved scope as Ask's selection. The sources it names stay as they are:
nothing that scope excluded comes back, and evidence stays bound.

#### Request for a retry or Quick Recall follow-up within saved scope
`scope_for`: The request for a question asked within a saved scope: a retry, or a follow-up
in Quick Recall.

#### Day key per moment mirrors AskDayScope.key
`pin_days`: `AskDayScope.key` of a moment, for the days of attached screens.

#### Without agent notes offered, all-other-sources reads All sources for pre-notes questions
`question_scope_summary`: `questionScopeSummary`: "Meetings, Screen · Oct 1 · attached screen: Oct 1".
While agent notes aren't offered, a question that names every other source
reads as "All sources": that is how questions from before that source
existed were saved.

#### A session's moments leave its screens, or the day's meetings if none
`session_sources`: The sources a session's moments leave (`selectEvidence`): its screens, or the
day's meetings when it has none.

#### Without named sources use what evidence holds; only screens is a session
`evidence_sources`: `selectEvidence` with no sources named: whichever of them the evidence holds,
when the meetings are bound too. Only screens is a session.

#### Attached screens grant screen source for that question without widening dates
`ask_scope`: The request sent to the engine for one question. Attached screens grant the
screen source for that question, and never widen its dates.

#### No meeting boundary (session screens) leaves meeting source as chosen
`ask_scope`: No meeting boundary (a session's screens) leaves the source as chosen.

#### Empty saved source list would read as all, so name the boundary's source
`ask_scope`: Nothing left to read within the boundary. A saved empty list would read as
every source, so it names the boundary's own source, which stays empty.

#### Session screens are searched by the model, not placed in the prompt
`a_session_bounds_the_question_to_its_screens`: Nothing attached: the model searches them, they aren't in the prompt.

#### Files off does not make the question look narrowed
`files_is_offered_only_while_on`: Off, it doesn't make the question look narrowed.

#### Serialized name matches Mac so shared conversations read the same
`agent_notes_is_part_of_all_sources_but_offered_only_while_on`: The Mac's name for the source, so a shared conversation reads the same.

#### Only files matched: no meeting or screen source widens to all
`asking_about_results_keeps_activity_and_files_with_file_rows`: Only files matched: no meeting or screen source widens to "all".

#### Reopening keeps every limit; follow-up or retry asks within it
`a_reopened_question_never_widens`: Reopening keeps every limit, and a follow-up or retry asks within it.

#### Attached moment stays the boundary but is no longer in the prompt
`a_reopened_question_never_widens`: An attached moment stays the boundary, no longer in the prompt.

#### Last 7 days is saved as days and still labelled while it holds
`a_saved_range_keeps_its_days_when_reopened`: Last 7 days is saved as its days, and still labelled while it is that.

#### Pre-agent-notes questions read All sources until notes are offered
`a_question_says_what_it_was_limited_to`: Saved before agent notes were a source: still everything, until
they are offered and the question can be seen to leave them out.

#### Legacy turns and answers name no scope summary
`a_question_says_what_it_was_limited_to`: Legacy turns name nothing, and answers aren't questions.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/search.rs`

#### Words first, then meaning fused at meeting level, on a background thread
Results for Ask and Quick Recall (`RecallSearch`): meeting hits grouped by
meeting, then screen moments. Words first; for Ask, meaning is then fused in at
the level of meetings. Runs on a background thread.

#### Snippet marks matched words with « » markers
`Hit.snippet`: Snippet with «matched» words.

#### Opening a hit lands on a transcript moment, none for summary
`Hit.moment`: Where opening this hit lands: a transcript moment, or `None` for the summary.

#### Ask lists at most 40 meetings or screen sources per search
`DISPLAY_LIMIT`: Meetings, or screen sources, that Ask lists for one search (`displayLimit`).

#### Meaning search reads 200 passages, matching EmbeddingIndex limit
`SEMANTIC_PASSAGES`: Passages by meaning read for one search (`EmbeddingIndex.search`'s limit here).

#### Keyword search reads 2000 rows before grouping
`KEYWORD_ROWS`: Keyword rows read for one search, before grouping.

#### hits[0] is the best match in the meeting
`MeetingGroup`: All matches in one meeting; `hits[0]` is the best one.

#### A screen result stands for several similar captures
`ScreenResult`: A screen moment and how many similar captures it stands for.

#### Folders chosen under Files; empty while Files is off
`Query.file_folders`: The folders chosen under Files; empty while Files is off.

#### Notes searched only when source chosen and Read coding agent notes is on
`Query.agent_notes`: Saved coding-agent notes are searched: the source is chosen and Read
coding agent notes is on.

#### True when more meetings or notes matched than limit
`Results.truncated`: More meetings or notes matched than `limit`.

#### Facet queries stay keyword-only: meaning matches cannot say their kind
`Query.searches_meeting_meaning`: Keyword hits for every kind of document can be fused with meaning. A facet
asks for one kind, and a meaning match can't say it's of that kind.

#### Saved moments match by note or title even with no text, as own results
`saved_matches`: Saved moments whose note or window title holds the query, among the hits as
their own results (`keywordScreens`): a note is searched even with no text.

#### Saved moments lead in saved order; meaning-only matches are not saved matches
`screens_with_saved_first`: `QuickRecallRowModel.screens` with a query: saved moments lead, in the order
they were saved, then the other hits. A match by meaning alone isn't a saved
match, and a saved moment keeps its place in the rest. Without a query the
list is just the latest saved moments.

#### Index changed meetings once per library per run so imports are searchable
`ensure_indexed`: Indexes meetings whose files changed since they were last indexed, once
per library and run, so a fresh or imported library is searchable.

#### Files match words first; query vector adds meaning later in refine
`run`: Files match words first; the query vector adds meaning in `refine`.

#### Notes match words only, no vectors; date scope uses last-changed
`note_hits`: Saved coding-agent notes matching the query's words, and whether more
matched than are listed. A date scope keeps the notes last changed inside
it. Notes have no vectors, so meaning never changes this list.

#### Note row shows matched words, else agent description, else path
`note_snippet`: What a note row shows under its title: the matched words, or the agent's
own description, or where the note is.

#### LokalBot keeps a search-only copy and never edits the agent's file
`open_note`: Opens the agent's own file for a note in its default app. LokalBot keeps a
copy for search only and never edits the file.

#### Text and picture vectors share one scale; first meaning search starts backfill
`refine`: Screens and files again, with the query's vector: text and picture vectors on
one scale, ranked with the keyword hits. With no vectors yet the keyword results
stay. The first search by meaning is what starts their backfill.

#### Meaning passages fuse into meetings; keyword results stay without vectors
`fuse_meetings`: Ask's meetings again, with passages found by meaning fused in (`fusedMeetings`).
With no vectors yet the keyword results stay.

#### Fuse per meeting so keyword-heavy meetings cannot bury meaning-only matches
`fused_meetings`: Fuses at the level of meetings, so a meeting with many keyword rows can't bury
a relevant one found by meaning alone. Keyword snippets stay, and one passage
found both ways is listed once. Says whether more meetings matched than `limit`.

#### Keyword evidence breaks ties only, never outranks higher meaning-ranked meeting
`fused_meetings`: Keyword evidence goes first only for equal relevance, never ahead
of a higher-ranked meeting found by meaning alone.

#### Primary hit prefers word-matched transcript passage, then any word match, then first
`primary`: `MeetingRecallGroup.primary`: a transcript passage matched by its words, else
any passage matched by its words, else the first one.

#### Generic kind icon because Linux/Windows lack the Mac's system file icons
`file_icon`: What kind of file a result is, at a glance. The Mac shows the file's own icon
from the system, which has no equivalent across Linux desktops and Windows here.

#### Opens in default app; Mac's page/moment-aware PDF window and player absent
`open_file`: Opens a file found by search in its default app. The Mac's own PDF window and
player, which open at the matched page or moment, aren't here.

#### Them reads as Other speaker, Them N as Speaker N
`speaker_label`: `SpeakerDisplayName.label`: "Them" reads as "Other speaker", "Them 2" as "Speaker 2".

#### Saved moment found only by meaning does not jump the queue
`saved_matches_lead_screens`: Found only by meaning, a saved moment doesn't jump the queue.

#### Equal fused scores go to keyword evidence, then earlier rank
`many_keyword_rows_cannot_bury_a_meeting_found_by_meaning`: Equal fused scores go to keyword evidence, then to the earlier rank.

#### Word-hit transcript leads and same passage is not listed twice
`a_meeting_found_both_ways_leads_and_shows_its_words_first`: The transcript hit by words leads; the same passage isn't listed twice.

#### A facet asks for one document kind and stays keyword-only
`a_meeting_found_only_by_meaning_joins_the_list_within_its_scope`: A facet asks for one kind of document, and stays keyword-only.

#### Windows cannot delete the database while the library holds it open
`searches_the_demo_library`: Windows can't delete the database while the library holds it open.

### `LinuxWindows/crates/lokalbot-app/src/pages/ask/transcript.rs`

#### Ask transcript: flat answers, one sources list, failed answers keep matches
The conversation (`ChatTranscriptView`, `EditorialTurn`): each question
with its time, then the answer as flat text, one sources list that ends it,
and quiet actions; a failed answer keeps its matches. Also the questions an
empty page suggests.

#### Stop answer speech when the answer leaves the screen
`stop_answer_speech`: The answer being read is leaving the screen (`ChatView.onDisappear`).

#### User turn scope is shown only in the time's tooltip
`Turn::User.scope`: What it was limited to, for the time's tooltip.

#### Failed last answer keeps its question so matches stay
`Turn::Assistant.failed_question`: The question a failed last answer replied to: its matches stay.

#### Streamed answer uses a placeholder id until the engine saves it
`STREAM_ID`: Id of the streamed answer before the engine saves it.

#### Older turns dated from their conversation show no time
`AskPage::turns`: An older turn dated from its conversation shows no time.

#### Scroll to end while streaming; Quick Recall reuses this view
`AskPage::render_transcript`: The conversation, scrolled to its end while an answer streams. Quick
Recall shows the same view for its one conversation.

#### Treat as near bottom while the matches tray covers the end
`AskPage::render_transcript`: The tray of matches covers the end of the conversation while typing.

#### Scope is chosen in composer menus, shown only in the time tooltip
`AskPage::render_user_turn`: The question in its own words, with the time it was asked. What it was
limited to is in the time's tooltip; the composer's two menus are where
scope is chosen.

#### Sources list ends an answer and replaces the Evidence disclosure
`AskPage::render_sources_list`: The list that ends an answer (`AnswerSourcesList`): a row per meeting,
screen moment, file or note it cited, with the answer's numbers and
times, and one row for what the person told LokalBot when that went into
the answer. It replaces the Evidence disclosure.

#### Failed answers re-find matches within the question's recorded limits
`AskPage::render_failed_matches`: The matches for a question whose answer failed, found again here within
the sources, dates and evidence limits recorded with the question.

#### Empty-page suggestions: latest meeting, a colleague, a project, then a keyword
`AskPage::render_suggestions`: Questions about the person's own latest meeting, a colleague and a
project, then one word to search for.

#### Read suggestion names off the UI thread once per library change
`AskPage::load_suggestion_names`: A colleague and a project to name, read off the UI thread once per
library change.

#### File citations do not resolve while Files is off
`AskPage::load_file_citations`: Reads the cited files that are not loaded yet, off the UI thread. Nothing
resolves while Files is off: the index is gone with it.

#### Note citations do not resolve while reading agent notes is off
`AskPage::load_note_citations`: Reads the cited coding-agent notes that are not loaded yet, off the UI
thread. Nothing resolves while Read coding agent notes is off: the saved
copy is gone with it.

#### Cited notes open only while coding agent notes are enabled
`AskPage::open_citation`: A cited note opens the agent's own file, while notes are read.

#### Mirrors the Mac date divider; previous Some(None) means no saved time
`date_divider`: `ChatTranscriptPresentation.dateDividerTitle`. `previous` is the previous
question's time (`Some(None)` when that one had no saved time).

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
