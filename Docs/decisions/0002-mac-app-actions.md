# 0002. Mac app: Actions

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Actions/`, `LokalBot/Services/Actions/`, `LokalBot/Views/Actions/`, `LokalBotTests/Models/Actions/`, `LokalBotTests/Services/Actions/`.

## Decisions

### `LokalBot/Models/Actions/ActionDuePresentation.swift`

#### Unsupported phrases stay unresolved, keeping phrase with source date
`ActionDuePresentation.date`: ISO dates and supported relative phrases resolve against the day they
were said (or corrected). Anything else stays unresolved rather than
guessed, and keeps the phrase with its source date.

### `LokalBot/Models/Actions/ActionDueResolver.swift`

#### Deterministic due parsing; ranges resolve to last day so action isn't overdue early
`ActionDueResolver`: Deterministically turns a spoken due phrase into a local calendar day,
using the day the phrase was said as the reference. It never asks a model
and never guesses: phrases outside the supported grammar stay unresolved.

Ranges resolve to their last day ("next week" is the Friday of next week,
"end of Q3" is September 30), so an action is not reported overdue while
the stated window is still open. The original phrase is always shown
beside the resolved date, and a user's due correction replaces both.

#### This Friday on a Friday is today; bare or next means following week
`ActionDueResolver.weekday`: "This Friday" said on a Friday is that day; a bare or "next"
weekday said on the same weekday means the following week.

#### Yearless date over 31 days before the meeting means next year
`ActionDueResolver.monthDay`: Without a year, a date well before the meeting refers to next year.

#### Friday is weekday 6 in Foundation's Gregorian numbering
`ActionDueResolver.endOfWorkWeek`: Friday is weekday 6 in the Gregorian numbering used by Foundation.

#### On Saturday the week already ended; keep stated day
`ActionDueResolver.endOfWorkWeek`: Saturday: the working week already ended; keep the stated day.

### `LokalBot/Models/Actions/ActionDueSort.swift`

#### Unknown dates sort last either direction; ties keep newest-meeting order
`ActionDueSort`: Unknown dates stay last in either direction. Equal dates retain the
existing newest-meeting order and a stable identity tie-break.

### `LokalBot/Models/Actions/ActionThreads.swift`

#### Thread is derived presentation; references stay source of truth
`ActionThread`: One continuing commitment assembled from compatible action mentions across
meetings. The references remain the source of truth; a thread is only a
derived presentation and never replaces or rewrites extracted evidence.

#### Due-soon window drives date coloring; overdue stands apart
`ActionThread.isDueSoon`: Open work due today or within the window that puts it near the top of
attention lists. Rows color these dates so they stand apart from later
ones, and overdue dates stand apart from both.

#### Open work unmentioned for 21 days with no future due is worth asking about
`ActionThread.staleAfterDays`: Open work last mentioned this long ago, with no due day still ahead,
is worth asking about.

#### Completed mention cannot hide unfinished work in another meeting
`ActionThread.status`: A completed mention cannot hide unfinished work in another meeting.

#### Order: overdue, due within a week, then recency
`ActionAttentionOrder`: Today's attention order: overdue work first, then work due within a week,
each by due day, then everything else in the existing recency order.

#### Three groups shown as headings; due phrase without a day counts as no date
`ActionAttentionOrder.Bucket`: The three groups of the order, which the Actions page shows as
headings. A due phrase that names no day counts as no date.

#### Only equal canonical commitments form threads; similar wording isn't enough
`ActionThreadClusterer`: Only equal canonical source commitments form threads. Similar wording is
not sufficient authority to share status, ownership, or corrections.

#### Newest-first input expires groups for good; normalize once per reference
`ActionThreadClusterer.cluster`: Input is newest first, so expired groups never become candidates
again. Normalize once per reference, never once per pair.

#### Short generic commitments recur and are unsafe to merge
`ActionThreadClusterer.sourceKey`: Short generic commitments recur naturally and are unsafe to merge.

#### Strip only harmless leading phrases; preserve verbs, negation, names
`ActionThreadClusterer.canonicalSourceText`: Remove only complete, harmless leading phrases; preserve verb,
negation, word order, names, and identifiers everywhere else.

#### Untouched values inherit; corrected or edited values persist verbatim incl. clears
`ActionCorrectionFieldIntent`: Converts an editor's visible optional field back to persistence intent.
Untouched extracted values continue to inherit; an existing correction or
a user edit is written verbatim, including an empty explicit clear.

### `LokalBot/Models/Actions/ActionsListPresentation.swift`

#### Use a distinct catalog key for Open as a state, not the verb
`OutcomeStatus.stateKey`: The catalog key for the status as a state. "Open" on its own is the
verb on buttons, which most languages translate differently.

#### Stale means open actions not mentioned for three weeks
`ActionsListFilter.staleOnly`: Open actions nobody has mentioned for three weeks (`ActionThread.isStale`).

#### Only Filter menu choices count as narrowing; each shows as a chip
`ActionsListFilter.hasMenuFilters`: Filter menu choices that narrow the list; each shows as a chip.

#### Leaving Open drops stale review; Done drops people and project filters
`ActionsListFilter.show`: Done actions are outside the People and Projects read models, and the
stale review is about open work, so leaving Open drops what cannot apply.

#### Chips follow the order the Filter menu lists choices
`ActionsListFilter.chips`: The active Filter menu choices, in the order the menu lists them.

#### Links come backwards from People and Projects read models; nothing new derived
`ActionThreadLinks`: The people and projects an action belongs to, looked up backwards from
the People and Projects read models. Those models list the user's open
and deferred work per person and per project; nothing new is derived here.

#### Threads found by references so re-threading keeps the link
`ActionThreadLinks.peopleByReference`: Action reference id to positions in `people` and `projects`. A thread
is found by its references, so re-threading does not lose the link.

#### Catalog keys go through localize so tests read plain English
`ActionListWording`: Day and due wording for the Actions page. Catalog keys go through
`localize`, so a view passes the interface language and a test reads
plain English.

#### Day wording: Today, Yesterday, weekday for past week, then date; year if not current
`ActionListWording.day`: "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
"Oct 27", with the year once it is not this year.

#### Due label tones: overdue Was due, soon amber, others quiet; Done shows completion
`ActionListWording.dueLabel`: The due text on a row. Overdue open work reads as "Was due", due
today or within the week keeps the amber tone, and a later date, a
phrase that names no day, and work that is no longer open stay quiet.
The Done list shows when the action was completed instead.

#### Under a meeting heading rows only say where else it was said
`ActionListWording.otherMeetings`: Under a meeting heading the row only says where else it was said.

#### Rows carry pre-made wording so row views do no work
`ActionsListContent`: The Actions list as it is drawn: filtered, ordered and grouped threads
with each row's wording already made, so rows do no work of their own.

#### Source omits the day when the group gives one; empty under meeting heading
`ActionsListContent.Row.source`: The meeting it came from, with a day where the group does not
already give one. Empty under a meeting heading.

#### Row ids top to bottom drive arrow keys and range selection
`ActionsListContent.order`: Row ids from top to bottom, for the arrow keys and range selection.

#### Open count is of the user's open actions regardless of the list shown
`ActionsListContent.openCount`: The user's open actions, whatever the list is showing.

#### Meeting titles are listed newest first
`ActionsListContent.meetingTitles`: Meeting titles the user's actions came from, newest first.

#### Kept threads stay listed so a ticked row does not vanish
`ActionsListContent.build`

- Parameter kept: threads whose status the user just changed in this
  view. They stay listed until the view or its filters change, so a
  ticked row does not vanish under the pointer.

#### Done threads with equal time keep list order (stable sort)
`ActionsListContent.build`: Threads done at the same moment keep their list order.

#### One row is always current, as in Mail; modifier clicks extend
`ActionListSelection`: Which rows the Actions list acts on. One row is always current, as in
Mail: the chosen rows that are still listed, or else the first row.
⌘-click adds or removes a row and Shift-click takes a range.

#### The last row cannot be deselected; one row stays current
`ActionListSelection.click`: The last row cannot be deselected: one row is always current.

#### Due control shows day, Pick a date for dayless phrase, or No date
`ActionDetailsPresentation.dueTitle`: The Due control: the resolved day, "Pick a date" for a phrase that
names no day, or "No date".

#### Due phrases newest first, excluding typed explicit dates
`ActionDetailsPresentation.saidDuePhrases`: Due phrases as they were said, newest meeting first, without the days
someone typed in.

#### Untouched fields keep a saved correction, otherwise stay as extracted
`ActionDetailsPresentation.Correction`: One call to `OutcomeIndex.correctAction`. Fields the change does not
touch keep a saved correction and otherwise stay as extracted.

#### Chosen due day is saved on the newest mention
`ActionDetailsPresentation.dueCorrection`: A due day chosen in the details pane, or none. It is saved on the
newest mention, whose correction a thread takes as its due date.

#### Not mine removes owner from every mention so it leaves the user's list
`ActionDetailsPresentation.notMineCorrections`: "Not mine": every mention loses its owner, so the action leaves the
user's list in each meeting it was said in.

### `LokalBot/Services/Actions/ActionCompletionHints.swift`

#### Completion hint is a suggestion; user confirms or dismisses
`ActionCompletionHint`: A suggestion, never a status change: a later screen capture that looks
like the user finished one of their open actions. The user confirms with
Mark Done, or dismisses it so the same capture is not offered again.

#### Hint needs two distinctive words plus verb-fitting completion phrase
`ActionCompletionDetector`: Deterministic matching of open actions to later screen captures. A hint
needs two things in the same capture after the action was last
mentioned: at least two of the action's distinctive words, and a
completion phrase that fits the action's verb ("message sent", "merged",
"submitted"). Only locally retained screen text and titles are read.

#### Distinctive words exclude stop words and need length, digit or capital
`ActionCompletionDetector.distinctiveTerms`: Distinctive words: not stop words or generic task verbs, and either
four or more letters, containing a digit, or capitalized in the source.

#### Queries read-only screen store off main actor
`ActionCompletionDetector.hints`: Queries a read-only screen store per open thread. Runs off the main
actor; the caller supplies a store opened read-only.

#### Defer snippets; build only when full OCR text unavailable
`ActionCompletionDetector.hints`: A hit's whole text is read below. Its snippet is built only when
that text cannot be read (a row from before captures had IDs).

### `LokalBot/Services/Actions/ActionOwnership.swift`

#### Ownership comes from cited speaker's voice, model claims are only checked
`ActionOwnership`: Decides whose task an extracted action is, from the speech it cites.

Identity comes from the voice: the cited row's speaker, as attributed by
the transcript. The model's owner, basis and quote are claims to check,
never proof. A task belongs to a speaker when that speaker's own words
around the cited rows undertake it, and to nobody when those words are a
question, a negation, or someone else's job.

#### Owner nil when model said source or unknown
`ActionOwnership.Claim.owner`: Speaker key the model named, nil when it said "source" or "unknown".

#### Anchor is transcript index of cited row holding evidence
`ActionOwnership.Finding.anchor`: Transcript index of the cited row the ownership evidence belongs to.

#### Refused means negated, question, or reported speech
`ActionOwnership.Finding.citesOnlyRefusedUndertakings`: The only undertakings in the cited rows are negated, questions,
or reported speech.

#### Suspected echo cannot prove ownership
`ActionOwnership.transcript`: Echo-marked transcript: suspected echo cannot prove ownership.

#### Wording checks are English only; elsewhere model claim stands
`ActionOwnership.isEnglish`: Wording checks read English; elsewhere the model's claim stands in.

#### Row text is nil when row lies outside this evidence
`ActionOwnership.text`: Text a row offers as evidence, nil when the row is outside this evidence.

#### Turn is one voice's consecutive rows around a cited row
`ActionOwnership.Turn`: One voice's consecutive rows around a cited row.

#### Follow sentence across rows; unpunctuated speech up to twelve words
`ActionOwnership.Turn.sentenceEnd`: Last word of a cue's sentence, across the rows it was cut over:
"My side, I'll." / "Try to." / "update the tickets." is one
sentence in three rows. Unpunctuated speech is followed for a
dozen words.

#### Cut reached mid-row is read to end of row
`ActionOwnership.Turn.spoken`: A cut reached mid-row is read to the end of that row.

#### Clause runs from subject to next subject or sentence end
`ActionOwnership.Turn.clause`: Words from a subject to the next subject or the end of its
sentence: the task that subject took.

#### Sentence of a row spans the cuts around it
`ActionOwnership.Turn.sentence`: The sentence a row belongs to, across the cuts around it.

#### All rows confirmed as user are one voice despite diarization labels
`ActionOwnership.sameVoice`: Rows of one person. Every row confirmed as the user's is the user, even
when diarization filed some under another microphone label.

#### Short remarks and impossibly fast text do not end a turn
`ActionOwnership.isInterjection`: A short remark from someone else does not end a speaker's turn, and
neither does text no one could have said in the time it spans.

#### Deadline evidence limited to cited single-speaker clauses
`ActionOwnership.supportsDeadline`: Deadline evidence stays within cited, single-speaker clauses. Adjacent
rows from the same turn can finish a clause split by transcription.

#### Strip due date from clause so title date cannot choose source
`ActionOwnership.supportsDeadline`: A date in the generated title must not help choose its own source.

#### Translated titles fall back to source quote within one clause
`ActionOwnership.supportsDeadline`: The title may be translated. The source quote still has to fit
within a single clause.

#### Short follow-up sentence can give preceding task's timing
`ActionOwnership.deadlineClauses`: A speaker can give the immediately preceding task's timing
in a short follow-up sentence: "It is due Thursday."

#### Accept swapped day and clock order from local model
`ActionOwnership.containsDeadline`: A local model can swap the day and clock: "today 16:00" for
"16:00 today". Match both components together in the same clause.

#### True when speaker's own unrefused commitment starts in the row
`ActionOwnership.statesCommitment`: The speaker's own unrefused commitment starts in this row.

#### Undertakings in cited rows or sentences running into them
`ActionOwnership.resolve`: Undertakings the cited rows carry: said in a cited row, or in a
sentence that runs into one.

#### Uncited undertaking must plainly concern the task to own it
`ActionOwnership.resolve`: An undertaking the model did not cite must plainly be about
this task before it can own it.

#### Quoted words choose among several undertakings
`ActionOwnership.resolve`: The quoted words choose among several undertakings.

#### Rank candidates by task alignment, then nearness to source row
`ActionOwnership.resolve`: Of one speaker's undertakings, the one that reads most like the
task; then the one nearest the row the model called its source.

#### Two people undertaking: only model quote decides ownership
`ActionOwnership.resolve`: Two people undertaking something in the cited rows: only the
model's quote can say whose task this is.

#### Carry earlier I'll over speaker's later list fragments
`ActionOwnership.resolve`: The speaker said "I'll…" a moment earlier and kept listing
their own work in fragments.

#### Voice wins over model claim only when task plainly matches
`ActionOwnership.attribution`: The model named someone else, or called this a request. The voice
wins only when the task is plainly the one this speaker took on.

#### Find who the model's source row gives work to
`ActionOwnership.attribution`: Who the row the model called the source gives work to.

#### Undertaking away from source row must match, answer, or be quoted
`ActionOwnership.attribution`: The undertaking is not where the model said the task is. It
must share words with the task, answer the request, or be the
model's quoted choice when the source row is one person's ask.

#### Other actors' clauses in the same turn are not this speaker's task
`ActionOwnership.attribution`: "I'll prepare the policy, and you will send the measurements":
sending the measurements is not this speaker's task.

#### Store whole spoken quote; model quotes can clip conditions
`ActionOwnership.attribution`: The stored quote is what was said, whole: a model's quote can clip
a condition or tidy a stumble.

#### Undertaking can answer source row without naming the task
`ActionOwnership.answersPrimary`: "Could you send the draft?" / "Yeah, I can do that", or "What I have
left is the review." / "So I'll do that today": the undertaking takes
on what the source row described, without naming it.

#### Fragments inherit earlier undertaking; full sentences inherit nothing
`ActionOwnership.carriedUndertaking`: The nearest undertaking earlier in the same turn, when the cited row
is a fragment of that speech and nothing in between is about anyone
else. A whole sentence of its own ("The deck is already shared.")
inherits nothing.

#### Cited rows must at least concern this task
`ActionOwnership.carriedUndertaking`: The cited rows must at least be about this task.

### `LokalBot/Services/Actions/MeetingOutcomeStore.swift`

#### Transfer state only on unambiguous two-way match with compatible evidence
`MeetingOutcomeStore.reconcileState`: Carry user-owned workflow state across a safe re-extraction. A transfer requires
an unambiguous match in both directions and compatible source evidence.
Unmatched edits remain available for review.

#### Action ID hashes content so model duplicates share one ID
`MeetingOutcomeStore.reconcileState`: An action's ID is a hash of its text, owner, due date and sources,
so one the model returned twice arrives here under one ID.

#### Keep sub-second dates; still read legacy second-precision dates
`MeetingOutcomeStore.fractionalISO8601`: Preserve sub-second edits while continuing to read the second-precision
ISO-8601 dates written by LokalBot before the outcome-state overlay.

### `LokalBot/Services/Actions/MeetingOutcomesGenerator.swift`

#### Deterministic dedup shared by unified notes extraction pass
`MeetingOutcomesGenerator`: Deterministic deduplication shared by the unified notes extraction pass.

#### Only primary citation anchors ownership resolution
`MeetingOutcomesGenerator.duplicateAction`: Context can support several tasks. Only the primary citation
anchors the undertaking used to resolve this task's ownership.

#### A repair can repeat spoken words of an extracted task
`MeetingOutcomesGenerator.duplicateAction`: A repair can repeat the spoken words of an already extracted task.

#### Task text equal to cited speech is not a written task
`MeetingOutcomesGenerator.repeatsItsSource`: The task text is just what its cited speaker said ("I'll ping Mira
to get that resolved"), not a task written from it.

#### Keep text, owner, deadline and primary citation together
`MeetingOutcomesGenerator.preferredAction`: Keep the text, owner, deadline, and primary citation together.

### `LokalBot/Services/Actions/OutcomeIndex.swift`

#### Shared read model; mutations persist atomically before publishing
`OutcomeIndex`: Read model shared by Today, Timeline, Meetings, Ask, and Agent. Every
mutation is persisted atomically in the relevant meeting folder before the
published projection is replaced.

#### Include other people's threads for stale-snapshot status changes
`OutcomeIndex.allActionThreads`: Every current thread, including other people's, so People and
Projects can change status through the same stale-snapshot check.

#### Preserve edits made while file validation ran
`OutcomeIndex.refreshInBackground`: Preserve edits/refreshes made while file validation was running.

#### Evidence lock held through writes; failed preflight changes nothing
`OutcomeIndex action state update`: The host holds its evidence-revocation lock through these writes.
A failed preflight cannot change either the source correction or
its derived narrative, and another process cannot regenerate
memory between revocation and the durable source mutation.

#### Summary keeps narrative; owner or text correction asks refresh
`OutcomeIndex action state update`: The summary keeps its narrative and shows the corrected action
list. An older free-text summary can name the old owner in its
prose, so an owner or text correction still asks for a refresh.

#### Archived extraction hidden but review corrections still persist
`OutcomeIndex action state update`: Archived extraction stays out of Today, Ask, and action threads.
Review can still persist corrections for the explicit refresh.

#### Action lists exclude the sample meeting's made-up actions
`OutcomeIndex.rebuildActionThreads`: Action lists come from the user's own meetings: the sample meeting's
made-up actions stay on its own page.

### `LokalBot/Services/Actions/OutcomesExtractor.swift`

#### Schema grammar-constrained on llama-server; tolerant parse for others
`OutcomesExtractor`: Prompt, JSON schema, and tolerant parsing for the outcomes extraction pass
that runs after summarization. Pure so every piece is unit-testable
without an engine; the pipeline owns the actual generate call.

The schema goes through `TextEngine.generate(system:prompt:context:schema:)`
— llama-server compiles it to a grammar so the reply is valid by
construction, while unconstrained backends (Apple Intelligence) fall back
to the prompt's format instructions plus the tolerant parse here.

#### Owner and due required-but-emptyable to keep strict grammar shape
`OutcomesExtractor.schema`: JSON schema matching `systemPrompt`'s shape, for grammar-constrained
backends. `owner`/`due` are required-but-emptyable rather than optional,
and `for_user`/`importance` are required so strict grammars keep the
object shape fixed.

#### Tolerant parse accepts fenced JSON; empty owner or due become nil
`OutcomesExtractor.parse`: Tolerant parse of the model's reply. Accepts fenced/prefixed JSON via
the same balanced-brace scan the chat agent uses; empty-string owner/due
collapse to nil. Nil when no parseable object is found.

#### Unknown or missing source IDs never become trusted rows
`OutcomesExtractor.parse`: Evidence-validating parse used by the processing pipeline. Unknown or
missing source IDs are never promoted into trusted action/decision rows.

### `LokalBot/Views/Actions/ActionDetailsPane.swift`

#### Status the list shows decides what a batch offers
`ActionDetailsPane.listing`: The status the list is showing, which decides what a batch offers.

#### Due note says what was said about the date, led by Overdue. when late
`ActionThreadDetails.dueNote`: What was said about the date, led by "Overdue." while it is.

### `LokalBot/Views/Actions/ActionEvidencePassages.swift`

#### Meeting name opens meeting at the quote; the time plays the passage in place
`ActionEvidencePassages`: One meeting's mention of an action in the Actions details pane: the
meeting and its day, then what was said. The meeting name opens the
meeting at the quote; the time plays the passage here.

#### A correction never replaces the originally extracted wording
`ActionEvidencePassages`: A correction never replaces what was extracted.

### `LokalBot/Views/Actions/ActionsListColumn.swift`

#### One row if it fits; extra chips and narrow search wrap to their own row
`ActionsFilterBar.body`: One row when it fits. More chips than the row holds go to a row
of their own, and in a narrow list so does the search field.

#### People and Projects filters only know open and deferred work
`ActionsFilterBar.filterMenu`: People and Projects only know open and deferred work.

#### Filter stores no choice as nil; the picker tags it as empty string
`ActionsFilterBar.optional`: A Filter menu submenu stores "no choice" as nil; its picker tags it "".

#### List is lazy; every row's wording is already prepared in content
`ActionsList`: The Actions list: the shared action row under the content's headings.
The list is lazy and every row's wording is already in `content`.

#### Returns the row to keep in view after moving selection
`ActionsList.onMove`: Moves the selection one row and returns the row to keep in view.

#### Held modifier keys choose single row, add row, or range
`ActionsList.click`: The modifier keys held at the click choose between one row, adding a
row, and a range.

#### Quiet bottom bar replaces per-row 'Still open?' question
`ActionsStaleBar`: "8 open actions haven’t been mentioned in 3 weeks. Review": the quiet bar
under the list that replaces the "Still open?" question on each row.

### `LokalBot/Views/Actions/ActionsWorkspaceView.swift`

#### Actions are deduplicated across meetings; status changes never alter extracted data
`ActionsWorkspaceView`: The user's own actions from meetings, each said once however many
meetings it came up in. The list shows one status at a time in attention
order; the pane beside it shows the selected action and the evidence
behind it. Status changes and corrections go through `OutcomeIndex` and
never alter what was extracted.

#### Observe connections object since People and Projects publish on their own object
`ActionsWorkspace`: People and Projects publish on their own object, so the page observes it
to show an action's people and project as soon as they are known.

#### Changed threads stay listed until the view or filters change
`ActionsWorkspace.kept`: Threads whose status just changed here; they stay listed until the
view or its filters change.

#### Multi-meeting status changes wait for confirmation
`ActionsWorkspace.PendingStatusChange`: A status change that reaches into several meetings waits for a yes.

#### One list serves rows, selection and details; rebuilt only when inputs change
`ActionsWorkspace.body`: One list serves the rows, the selection and the details pane, and
is rebuilt only when what it is made of changes.

#### Status changes spanning several meetings are confirmed first
`ActionsWorkspace.requestStatus`: One action said in several meetings changes in each of them, so that
change is confirmed first, for one row or for a batch.

#### Changed rows stay in place until the view changes
`ActionsWorkspace.applyStatus`: Changed rows stay where they are; the list closes up when the view changes.

#### Not mine clears every mention's owner through the editor's correction path
`ActionsWorkspace.markNotMine`: "Not mine" clears the owner of every mention through the same
correction path as the editor, so the action leaves this list.

#### Cache built list; recompute only when threads, filter, links, day or language change
`ActionsListCache`: Keeps the built list between renders. The page redraws for every change
to the app's state; filtering, ordering and wording run again only when
the threads, the filter, the people and projects, the day or the
interface language change.

#### Revision number avoids comparing two link dictionaries
`ActionsListCache.Key.linksRevision`: Which build of the links, so two dictionaries are never compared.

### `LokalBot/Views/Actions/OutcomeOverviewViews.swift`

#### Shared outcome blocks read OutcomeIndex so status changes show everywhere without touching sources
`NeedsAttentionSection`: Shared outcome-first building blocks used by Today, Timeline, People and
Projects. They read the same `OutcomeIndex` as Meetings, so status changes
are immediately reflected everywhere without modifying extracted source
files.

Today's open actions as a panel: the most urgent rows on the page itself,
how many are overdue beside the count, and the rest one link away.

#### Open threads the section leaves to the Actions page
`NeedsAttentionSection.remainder`: Open threads the section leaves to the Actions page.

#### No panel at all when nothing needs attention
`NeedsAttentionSection.body`: Nothing to act on means no panel at all: an empty "Needs attention"
is dead weight on a glanceable page.

#### Actions page owns selection, confirms status changes and keeps rows in view
`ActionListRowStyle`: How the Actions page shows the shared row: its own source and due wording,
a selection it owns, and status changes it confirms and keeps in view.
The links a row has elsewhere live in that page's details pane.

#### With several rows selected, a row's menu shows only under the pointer
`ActionListRowStyle.isBatch`: Several rows are selected: a row's menu shows only under the pointer.

#### Projects show whose work it is when someone else's
`ActionThreadRow.showsOwner`: Projects show whose work it is when it is someone else's.

#### People show deferred work as deferred and ask about weeks-old open work
`ActionThreadRow.showsStaleness`: People show deferred work as deferred and ask about open work nobody
has mentioned for weeks.

#### Timeline meeting preview already names the meeting, so rows omit its link
`ActionThreadRow.hidesSingleMeetingLink`: Timeline's meeting preview lists that meeting's actions, so a row from
one meeting does not name it again.

#### People show the moment as a play time opening the meeting from there
`ActionThreadRow.playsEvidence`: People show the moment as a ▶ time that opens the meeting playing
from there, like the notes beside it.

#### Only the Actions page sets this; other pages show the row with its links
`ActionThreadRow.list`: Set by the Actions page; every other page shows the row with its links.

#### Keep menu in view tree always so an open menu cannot vanish when pointer moves
`ActionThreadRow.listBody`: The menu shows on the selected row and under the pointer. It
stays in the view tree either way, so it cannot go away while
it is open and the pointer has moved onto its items.

#### Use WorkspaceMenu since SwiftUI Menu lacks Press/Show Menu actions for VoiceOver and Switch Control
`ActionThreadRow.optionsMenu`: The row's "…" menu. SwiftUI's Menu proxy leaves out the Press and Show
Menu accessibility actions, so VoiceOver and Switch Control could not
open it; `WorkspaceMenu` is the app's native pull-down that has them.

#### Native menu needs catalog strings in the app's chosen language
`ActionThreadRow.text`: A catalog string in the app's chosen language, for the native menu.

#### Menu used on Today, Timeline, People and Projects
`ActionThreadRow.defaultMenu`: The menu on Today, Timeline, People and Projects.

#### Actions page menu mirrors its context menu entries
`ActionThreadRow.listMenu`: The menu on the Actions page; the same entries as its context menu.

#### Hand-off lists Agent then external agents installed on this Mac
`ActionThreadRow.handOffItems`: Agent, then the external agents installed on this Mac.

#### Overdue red, due within the week amber, later quiet
`ActionThreadRow.dueColor`: Overdue reads red, due within the week amber, anything later quiet.

#### Completed thread leaves open-only lists; animate so rows close the gap
`ActionThreadRow.apply`: A completed thread leaves open-only lists; animate the change so
the rows below close the gap.

#### Looks-done hint never changes status itself; Mark Done uses the normal path
`ActionCompletionHintLine`: "Looks done?" evidence from a later screen capture. It never changes
status by itself; Mark Done goes through the normal status path.

#### Asks about weeks-old open work; deferred work stops asking
`StillOpenLine`: Asks about open work nobody has mentioned for weeks. Either answer goes
through the normal status path; deferred work stops asking.

### `LokalBotTests/Models/Actions/ActionDueResolverTests.swift`

#### Same weekday said on that day means the following week
`ActionDueResolver`: The same weekday means the following week, never the day it was said.

#### Said on a Saturday, next Monday is already in the following week
`ActionDueResolver`: Said on a Saturday, the next Monday is already in the following week.

#### A quarter already ended refers to next year's quarter
`ActionDueResolver`: A quarter that already ended refers to next year's quarter.

#### A past month and day without a year means next year
`ActionDueResolver`: Far in the past without a year means next year.

### `LokalBotTests/Models/Actions/ActionThreadRevisionTests.swift`

#### Status lives in per-meeting overlay; extracted commitments stay untouched
`ActionThread completion`: Status lives in the per-meeting overlay; extracted commitments stay untouched.

### `LokalBotTests/Models/Actions/ActionsListPresentationTests.swift`

#### Due phrases resolve in the current calendar, so tests use it
`ActionsListPresentationTests.calendar`: Due phrases resolve in the current calendar, so the tests keep to it.

#### Dated groups name the meeting; other rows also say which day
`ActionsListContent.build`: Dated groups name the meeting; the rest also say which day it was.

#### Stale review is about open work, so leaving Open ends it
`ActionsListFilter.show`: The review is about open work: leaving Open ends it.

#### Language supplies the words; the date follows its locale
`ActionListWording.dueLabel`: A language supplies the words; the date follows its locale.

#### System puts a narrow no-break space before PM
`ActionListWording.completionHint`: The system puts a narrow no-break space before "PM".

#### A due day goes on the newest mention and leaves other fields alone
`ActionDetailsPresentation.dueCorrection`: A due day goes on the newest mention and leaves other fields alone.

#### Not mine clears the owner of every mention and nothing else
`ActionDetailsPresentation.notMineCorrections`: "Not mine" clears the owner of every mention and nothing else.

#### A filter hiding the chosen row shows the first; choice returns with the row
`ActionListSelection.current`: A filter that hides the chosen row shows the first one instead,
and the choice returns with the row.

#### Threads arrive newest meeting first, as the outcome index publishes them
`ActionsListPresentationTests.build`: Threads arrive newest meeting first, as the outcome index publishes them.

### `LokalBotTests/Models/Actions/PersonalActionItemsTests.swift`

#### Microphone segments persist as transcripts did while microphone default was off
`PersonalActionItemsTests.microphone`: Persisted exactly as transcripts were while the microphone default was off.

#### A recap as source does not change who said they would do it
`MeetingNotesEvidence.validate`: The recap as source does not change who said they would do it.

#### Ownership comes from the cited row, not the model's possibly wrong quote
`MeetingNotesEvidence.validate`: A quote the model got wrong does not unsay what the cited row says.

#### Words the model was never shown prove nothing
`MeetingNotesEvidence.validate`: Words the model was never shown prove nothing.

#### Wording checks read English; other languages rely on cited voice and model claim
`MeetingNotesEvidence`: Wording checks read English. In any other language the cited voice
and the model's claim decide, or the user would never own a task.

#### Noise opening heard as another language must not make an English meeting foreign
`MeetingNotesEvidence.isEnglishMeeting`: Transcripts often open with noise heard as another language. That
opening used to switch the English checks off for the whole meeting.

### `LokalBotTests/Services/Actions/ActionOwnershipAuditTests.swift`

#### Opt-in local audit replays saved actions with and without a speaker claim
`ActionOwnershipAuditTests`: Opt-in, local-only audit of action ownership on real meetings. Normal
unit/CI runs skip it. The copied meetings and the report stay outside the
repository.

Saved outcomes keep the rows each action cites but not the model's answer.
The audit therefore replays every saved action through the current rules
twice: once as the model claiming the cited speaker committed to it, and
once with no claim, which is what the rows prove on their own.

### `LokalBotTests/Services/Actions/MeetingOutcomesGeneratorTests.swift`

#### Built-in 4B model repeated a row's words as a second task; merge it
`MeetingOutcomesGenerator`: Asked again about a row, the built-in 4B model returned the row's own
words as a second task beside the one already written from it.

### `LokalBotTests/Services/Actions/RunOnSpeechOwnershipTests.swift`

#### Fixtures are invented but shaped like recordings that left user commitments Owner unclear
`RunOnSpeechOwnershipTests`: Ownership of action items in speech as it is actually transcribed: run-on
clauses, stumbled words, and sentences cut across rows. Every transcript
here is invented, but shaped like the recordings that kept the user's own
commitments under "Owner unclear" (2026-10-05).

#### Tidied quote run over the row cut was the previously rejected answer
`RunOnSpeechOwnershipTests.testCommitmentBuriedMidSentenceIsMineHoweverTheModelQuotesIt`: Tidied, and run over the row cut: the answer that was rejected.

#### Each pause became its own row with a period the speaker never said
`RunOnSpeechOwnershipTests.fragments`: Each pause became its own row, with a period the speaker never said.

#### A model citing a fragment of the user's sentence for something else is not ownership
`RunOnSpeechOwnershipTests.testAnUncitedUndertakingOwnsOnlyATaskItIsAbout`: The model cited a fragment of the user's sentence for something else.

#### Once someone else is mentioned, fragments may be about them
`RunOnSpeechOwnershipTests.testAnEarlierIllCarriesAcrossFragmentsOnlyOnTheModelsClaim`: Once someone else is mentioned, the fragments may be about them.

#### A recognizer echoing its vocabulary hint between rows must not end a turn
`RunOnSpeechOwnershipTests.testTextNobodyCouldHaveSaidDoesNotEndATurn`: A recognizer echoing its vocabulary hint between two rows.

#### A passive or a question names no rival owner
`RunOnSpeechOwnershipTests.testMyTaskAndTheirsInOneBreathAreToldApartByTheTask`: A passive or a question names no rival.

#### A named owner is overruled only for the task the cited voice took on
`RunOnSpeechOwnershipTests.testTheCitedVoiceOwnsItsUndertakingWhateverSpeakerTheModelNames`: A named owner is overruled only for the task the cited voice took on.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
