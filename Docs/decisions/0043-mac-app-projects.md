# 0043. Mac app: Projects

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Projects/`, `LokalBot/Services/Projects/`, `LokalBot/Views/Projects/`, `LokalBotTests/Models/Projects/`.

## Decisions

### `LokalBot/Models/Projects/ProjectCuration.swift`

#### Tracked and declined suggestions saved in projects/tracked.json; all else derived
`ProjectCuration`: The projects the person chose to follow and the suggestions they turned
down. Saved as `projects/tracked.json` in the library. Everything else on
a project page is derived from the library each time it is shown.

#### Other names matched like the name: merged names, codenames, clients
`ProjectCuration.TrackedProject.otherNames`: Other names for the same work, matched like the name: a merged
project's names, a codename, a client.

#### Stores normalized names of suggestions marked Not a Project
`ProjectCuration.hiddenNames`: Normalized names of suggestions marked "Not a Project".

#### Confirmed names feed speech-model vocabulary
`ProjectCuration.trackedNames`: Names the person confirmed, for speech-model vocabulary.

#### Read-only load for code without the app store, such as transcription vocabulary
`ProjectCuration.load`: Read-only load for code without the app's store, such as the
processing pipeline's transcription vocabulary.

#### Summaries are withdrawn when a used meeting is deleted, stale when evidence changes
`ProjectStatusSummary`: A short "Where it stands" note for one tracked project, written by the
Think model from the project's meetings and overnight review notes.
Saved in `projects/summaries.json`; withdrawn when a meeting it used is
deleted, and marked out of date when its evidence changes.

#### Location value marking a note written by a model on this Mac
`ProjectStatusSummary.localLocation`: `location` of a note written by a model on this Mac.

#### Nil for overnight review notes
`ProjectStatusSummary.Point.meetingID`: The meeting the point came from; nil for overnight review notes.

#### Lists every meeting whose evidence was in the prompt
`ProjectStatusSummary.meetingIDs`: Every meeting whose evidence was in the prompt.

#### Different hash than the prompt evidence hash means newer evidence
`ProjectStatusSummary.evidenceFingerprint`: Hash of the prompt evidence; a different hash means newer evidence.

#### Where the model ran: this Mac or the server's host
`ProjectStatusSummary.location`: Where the model ran: "this Mac" or the server's host.

### `LokalBot/Models/Projects/ProjectLinks.swift`

#### Project joins evidence by deterministic word matching on names; no model decides
`ProjectProfile`: A project joined to the evidence behind it: meetings, open action threads,
decisions, overnight review notes, people, and tracked window time.
Tracked projects are the ones the person chose to follow; suggestions are
names that recur across meetings and overnight review projects nobody
tracks yet. Matching is deterministic word matching on the project's
names; no model decides what belongs to a project.

#### Mention is a line naming the project, cut around the name
`ProjectProfile.Mention`: A line that names the project, cut to fit around the name.

#### Prefer summary lines, then transcript lines, then action or decision
`ProjectProfile.MeetingRef.mentions`: Summary lines naming the project, else transcript lines, else the
action or decision that names it.

#### Others' open work mentioned recently or due ahead
`ProjectProfile.othersActions`: Other people's open work mentioned recently or due ahead.

#### Others' work last mentioned long ago, shown on request
`ProjectProfile.olderOthersActions`: Other people's open work last mentioned long ago; shown on request.

#### Tracked time in the reviewed window, newest day first
`ProjectProfile.days`: Tracked time in the reviewed window, newest day first.

#### Newest of meeting, review note, or tracked window time
`ProjectProfile.lastActive`: The newest meeting, review note, or tracked window time.

#### Counts every window with tracked time; windows lists only the longest
`ProjectProfile.windowCount`: Every window with tracked time in the reviewed days; `windows` lists
only the longest.

#### Others' actions move behind Show older after 14 days without due day ahead
`ProjectLinks.recentOthersActionDays`: Other people's open actions move behind "Show older" when their last
mention is older than this and no due day lies ahead.

#### Callers cache folded transcript so refresh does not re-read and re-fold
`ProjectLinks.TranscriptText`: A meeting's transcript lines and their normalized words, cached by the
caller so a refresh does not re-read and re-fold every transcript.

#### Folded lines allow a quick substring check
`ProjectLinks.TranscriptText.foldedLines`: Each line case- and diacritic-folded, for a quick substring check.

#### Fold the whole transcript once; far cheaper than per line
`ProjectLinks.TranscriptText.init`: One fold over the whole transcript is far cheaper than one per line.

#### People, user, and apps in use are never offered as topics
`ProjectLinks.Input.excludedTopicWords`: Words never offered as topics (people, the user, apps in use).

#### Covers meeting title and calendar title
`ProjectLinks.MeetingText.titleWords`: Title and calendar title.

#### Covers title, calendar title, summary, and outcome text
`ProjectLinks.MeetingText.words`: Title, calendar title, summary, and outcome text.

#### Folded copy enables a substring check before the costlier word match
`ProjectLinks.FoldedLines`: Text split into lines, with a case- and diacritic-folded copy for a
quick substring check before the costlier word match.

#### Recurring names excluded when tracked, hidden, or already a review suggestion
`ProjectLinks.build`: Names that recur across meetings, unless tracked, hidden, or
already offered as a review suggestion.

#### Topic suggestions ordered by the meeting count each row shows
`ProjectLinks.build`: Ordered by the meeting count each row shows.

#### Meeting titled for project owns all its actions; others only naming ones
`ProjectLinks.profile`: A meeting named for the project owns all of its actions; any other
meeting contributes only the actions that name the project.

#### Others' work is recent if mentioned recently or due ahead
`ProjectLinks.isRecent`: Other people's work stays in view while it was mentioned recently or
its due day is still ahead.

#### First summary line naming every term, stripped of markers, stamps, labels
`ProjectLinks.mention`: The first summary line naming every term, without markdown markers,
transcript timestamps, or speaker labels, cut to fit around the name.

#### Short transcript lines borrow following lines so excerpt reads as a sentence
`ProjectLinks.transcriptMentions`: Transcript lines naming the project. A short line borrows the next
lines so the excerpt reads as a sentence.

#### Long lines are windowed starting slightly before the name, marked with ellipsis
`ProjectLinks.excerpt`: The line itself when it fits; otherwise a window that starts a little
before the project's name, cut at word boundaries and marked "…".

#### Excerpt starts at next word but never after the name
`ProjectLinks.excerpt`: Begin at the next word, but never after the name itself.

#### Parse by hand: Swift regex took 1.9 s over 31,000 lines; labels dropped
`ProjectLinks.transcriptLines(fromMarkdown:)`: "**[00:13:21] Them 3:** text" lines from `transcript.md`; speaker
labels are dropped because they are only meaningful inside one meeting.
Parsed by hand: a Swift regex took 1.9 s over a 31,000-line library.

#### Identifying terms are at least three characters and not generic work words
`ProjectLinks.significantTerms`: Words of a project name that can identify it: at least three
characters and not a generic work word.

#### Every significant term must appear as a whole word
`ProjectLinks.matches`: Every significant term must appear as a whole word.

#### Substring prefilter rules out most text before costly word folding
`ProjectLinks.matches`: Any one of a project's names matches. A substring check rules most
text out before the costlier fold into words.

#### Day key format yyyy-MM-dd is the key of ProjectProfile.DayTime
`ProjectLinks.dayKey`: "2026-11-10", the key of `ProjectProfile.DayTime`.

### `LokalBot/Models/Projects/ProjectTopicDetector.swift`

#### Topics are recurring, nearly always capitalized terms across meetings; sentence starters need mid-sentence evidence
`ProjectTopicDetector`: Finds the proper nouns that recur across meetings (products, protocols,
clients, codenames) so Projects can suggest names worth tracking.
Deterministic and local: it counts capitalized terms in meeting titles,
summaries, actions, and decisions, and keeps only terms that are nearly
always capitalized, appear in several meetings, and are not people, apps,
or generic work vocabulary. A capitalized word that starts a sentence
("**Them 4:** Vireo shipped…") counts only for terms also seen
capitalized mid-sentence, so sentence starters stay out.

#### Keep sentence-initial capitals apart until mid-sentence use shows a name
`ProjectTopicDetector.topics`: Sentence-initial capitals, kept apart until mid-sentence use
shows the term is a name rather than a sentence starter.

#### A known name spelled one letter differently is still that person
`ProjectTopicDetector.topics`: A known name spelled one letter differently ("Milana" for Milena)
is still that person.

#### Apps and services mentioned are not the user's projects
`ProjectTopicDetector.commonApps`: Apps and services people mention without it being their project.

#### Company suffixes like Labs name no project on their own
`ProjectTopicDetector.stopWords`: Company suffixes ("Corvid Labs") name no project on their own.

### `LokalBot/Models/Projects/ProjectsListPresentation.swift`

#### Tracked projects by last activity, then suggestions with their source
`ProjectsListContent`: The Projects list as it is drawn: tracked projects by last activity, then
suggestions with where each came from, with every row's wording made.

#### Activity is newest meeting, review note, or window-time day
`ProjectsListContent.Activity`: How recently anything named a project: its newest meeting, overnight
review note, or day with window time.

#### Recent means within the last quietAfterDays days
`ProjectsListContent.Activity.recent`: Within the last `quietAfterDays` days.

#### Quiet rows drawn fainter when nothing named project for weeks
`ProjectsListContent.Row.isQuiet`: Drawn a little fainter: nothing has named the project for weeks.

#### Counts the user's own open actions on the project
`ProjectsListContent.Row.openActions`: The user's own open actions on the project.

#### Quiet after 14 days, same cutoff as others' recent work
`ProjectsListContent.quietAfterDays`: A project nothing has named for this many days reads "Quiet since…".
The same two weeks after which the page stops treating other people's
open work as recent.

#### Suggestions keep offered order: meeting names by count, then review's
`ProjectsListContent.build`: Suggestions keep the order they are offered in: names from
meetings by how many meetings, then the overnight review's.

#### After a suggestion leaves, select next suggestion, else first tracked project
`ProjectsListContent.selection(afterRemoving:)`: What opens once a suggestion leaves the list: the suggestion after
it, else the first one left. Nil when it was the last suggestion, and
then the page opens the first tracked project.

#### Suggestion's home project chosen deterministically from shared meetings
`ProjectSuggestionHome`: Which tracked project a suggestion probably belongs to. Deterministic:
it compares the meetings that name each.

#### Shared count counts only when at least half the suggestion's meetings
`ProjectSuggestionHome.sharedMeetings`: How many of the suggestion's meetings the project already has, when
that is at least half of them; nil otherwise, and for a suggestion no
meeting names.

#### Pick project sharing most meetings, at least half; first wins ties
`ProjectSuggestionHome.match`: The tracked project that already has at least half of the
suggestion's meetings; the one sharing the most when several do, and
the first in the list on a tie.

#### Side column shows last seven days, one bar each
`ProjectTimePresentation`: The side column's time: the last seven days, one bar each.

#### Zero for a day with no window time naming the project
`ProjectTimePresentation.Day.seconds`: Zero for a day with no window time that names the project.

#### Time under a minute is hidden, as on Timeline
`ProjectTimePresentation.minimumSeconds`: Time under a minute is not shown, as on Timeline.

#### Cover ProjectLinks.reviewDays oldest first ending today, zero where no time
`ProjectTimePresentation.days`: The days `ProjectLinks` measures (`ProjectLinks.reviewDays`), oldest
first and ending today, with zero for a day it reports no time on.

#### Bar height is fraction 0 to 1 of the tallest day
`ProjectTimePresentation.fraction`: How tall a day's bar is, from 0 to 1 of the tallest day.

#### Project counts every window but lists only the longest
`ProjectTimePresentation.rest`: The windows behind "N more windows" and their time together. The
project counts every window; it lists only the longest.

#### Empty when no meeting, action, decision, note, person, or window time
`ProjectPagePresentation.isEmpty`: Nothing names the project yet: no meeting, action, decision,
overnight review note, person, or window time.

#### Recent or due-ahead others' work first, then older work
`ProjectPagePresentation.othersActions`: Other people's open work in one list: what was mentioned recently or
is due ahead first, then the older work.

#### Wording built from counts, dates, names; localize looks up catalog keys
`ProjectsWording`: Wording on the Projects list and a project's page that is put together
from counts, dates and names. `localize` looks a catalog key up in the
interface language.

#### Own singular localization key because list's Suggested heading is not in every language
`ProjectsWording.subtitle`: Its own key: beside one project the word is singular, and the
list's "Suggested" heading is not in every language.

#### Spoken accessibility wording for the number on a row
`ProjectsWording.openActions`: "2 open actions for you", read out for the number on a row.

#### Durations under a minute still read as one minute
`ProjectsWording.duration`: "40h 10m", "35m"; under a minute still reads as one.

#### Read out for a day's bar; a day without time says zero
`ProjectsWording.dayTime`: "Wed, Nov 4: 8h 20m", read out for a day's bar; a day without time
says so with a zero.

#### Show when, which model, and where it ran, including server host
`ProjectsWording.provenance`: When "Where it stands" was written, by which model, and where it
ran: "Written today, 9:12 AM, by Qwen3.5 4B on this Mac", or with the
server's host for a model that ran elsewhere.

#### Explain offered answer: tracked project with most shared meetings, or none covers it
`ProjectsWording.suggestionReason`: Why the first answer is the one offered: the tracked project that
already has most of the suggestion's meetings, or that none covers it.

### `LokalBot/Services/Projects/ProjectStatusGenerator.swift`

#### Status notes are grounded, cited and staleness-aware via evidence hash
`ProjectStatusGenerator`: Writes a tracked project's "Where it stands" note with the Think model
from the lines of its recent meetings that name it, the decisions and
actions that name it, and its overnight review notes. Grounded (only that
evidence), cited (each point names its meeting), and explicit about
staleness: the evidence hash shows when newer evidence exists.

#### Meeting label M1 is the newest meeting
`ProjectStatusGenerator.Evidence.MeetingEvidence.label`: "M1" is the newest meeting.

#### Other actions are open actions from meetings older than those listed
`ProjectStatusGenerator.Evidence.otherActions`: Open actions from meetings older than the ones listed.

#### Prompt context carries no date so its hash changes only with evidence
`ProjectStatusGenerator.promptContext`: The evidence as prompt text. It carries no date of its own, so its
hash changes only when the evidence does.

#### Stamp the note at finish time, not prompt time
`ProjectStatusGenerator.generate`: `now` dates the prompt. `finishedAt` stamps the note once the model has
written it: a note that took minutes was still written just now.

#### Strip only the exact bracketed detail shape that small models copy
`ProjectStatusGenerator.removingEvidenceFormat`: Small models copy the bracketed details `actionLine` gives them. Only
that exact shape goes: a sentence that says "the owner" or "still open"
in its own words stays.

### `LokalBot/Services/Projects/ProjectStore.swift`

#### Last failure per project, cleared by the next attempt
`ProjectStore.errors`: The last failure per project, cleared by the next attempt.

#### Automatic writes tried once per session so a failing model isn't retried each visit
`ProjectStore.automaticAttempts`: Automatic writes already tried this session, by project and evidence,
so a failing model is not asked again on every visit.

#### Tracking an already-known name returns the existing project
`ProjectStore.track`: Starts tracking a project, or returns the tracked project already
known by that name.

#### Merging turns source names into other names and discards its note
`ProjectStore.merge`: Folds one tracked project into another: its names become the
target's other names, and its note is discarded.

#### Not a Project hides the name from future suggestions
`ProjectStore.hideSuggestion`: "Not a Project": the name is no longer suggested.

#### Outdated means newer or changed evidence since the note was written
`ProjectStore.SummaryState.outdated`: Newer or changed evidence since the note was written.

#### Mark writing before returning so the page shows Writing in its first frame
`ProjectStore.startWritingSummary`: Marks the project as being written before returning, so a page opening
it draws "Writing…" in its first frame instead of "No note yet".

#### Drop the note if the project was untracked while the model wrote
`ProjectStore.finishWritingSummary`: The project may have been dropped while the model wrote.

#### Deleting a meeting withdraws every note citing it, per PRIVACY
`ProjectStore.withdrawSummaries(citing:)`: A deleted meeting takes every note that used it along (PRIVACY.md).

#### Safety net for meetings removed outside the app's delete path
`ProjectStore.withdrawSummaries(missingFrom:)`: Safety net for meetings removed outside the app's delete path.

### `LokalBot/Views/Projects/ProjectPageView.swift`

#### Where it stands is the only model-written block; the rest are library facts
`ProjectDetailView`: One project's page. A tracked project leads with "Where it stands", the
only block a model wrote, marked with the sparkle and one line saying
when, by which model and where. Everything outside that card is a fact
from the library: your actions, what is waiting on others, decisions, and
the meetings with the line that names the project. Window time, people
and names sit in a side column. A suggestion opens on the decision
instead, and a project nothing names yet is one message.

#### Suggestion home is the tracked project holding at least half its meetings
`ProjectDetailView.home`: For a suggestion: the tracked project that already has at least half
of its meetings.

#### Others' open work shows three rows, the rest on request
`ProjectDetailView.othersActions`: Other people's open work, recent first: three rows, then the rest on
request.

#### Show the line naming the project so the link is explained
`ProjectDetailView.meetings`: Each meeting with the line that names the project, so it is clear why
it is linked. A line from the transcript plays from its moment.

#### Stale note stays, marked, until updated by person or approved automatic update
`WhereItStandsCard`: The tracked project's "Where it stands" note, the only model-written
text on the page: overview, points with the meeting each comes from, and
open questions. Its heading says when it was written, by which model and
where that ran. A note whose evidence has changed stays, marked, until
the person updates it or an approved automatic update replaces it.

#### Just-tracked project starts its note once evidence arrives if automatic writing allowed
`WhereItStandsCard.body`: A project tracked a moment ago starts its note as soon as its
evidence arrives, when automatic writing is allowed.

#### Replaced note stays readable while the new one is written
`WhereItStandsCard.body`: The note being replaced stays readable while the new one
is written.

#### Provenance moves under the title when the card is narrow
`WhereItStandsCard.heading`: The sparkle and title, then who wrote the note and the button. The
provenance moves under the title when the card is too narrow for one
line.

#### Provenance always comes from the saved note
`WhereItStandsCard.provenance`: Always from the saved note: when it was written, the model's name,
and this Mac or the server it ran on.

#### Overnight-review points say so and link nowhere
`ProjectNoteText`: The note's text. Each point ends with the meeting it comes from as a
link; a point from the overnight review says so and links nowhere.

#### Add to existing project first when it holds half the meetings; otherwise track
`ProjectSuggestionCard`: A suggestion's page opens on the decision: where it came up, then the
answers. When a tracked project already has at least half of its
meetings, adding it there is the first answer; otherwise tracking is.

#### Overnight review text is model-written so it carries the sparkle
`ProjectSuggestionCard.reviewNote`: The overnight review's own words, which a model wrote, so they carry
the sparkle too.

#### Zero-time days keep a hairline so the week reads as seven days
`ProjectDayBars`: A bar for each of the last seven days, today's in the full accent. A day
without time keeps a hairline, so the week reads as seven days.

### `LokalBot/Views/Projects/ProjectsWorkspaceView.swift`

#### Projects list is tracked by activity then suggestions; state lives in ProjectStore
`ProjectsWorkspaceView`: Projects the person tracks, plus suggestions: names that recur across
meetings and overnight review projects nobody tracks yet. The list shows
tracked projects by last activity, then suggestions with where each came
from. The page beside it leads with "Where it stands", the one block a
model wrote, and lists the facts that name the project under it: actions,
decisions, meetings, and, in a side column, window time, people and names.
Tracked projects, their names, and hidden suggestions live in
`ProjectStore`.

#### Review notes come from Dream memory, which other sections load lazily
`ProjectsWorkspaceView.body`: Review notes come from Dream memory, which other sections load lazily.

#### With nothing chosen, select the most recent tracked project, else first suggestion
`ProjectsWorkspaceView.selectedProject`: With nothing chosen, the page opens on the first row: the most
recently active tracked project, else the first suggestion.

#### Just-tracked suggestion stays shown as tracked until refresh; nothing written from it
`ProjectsWorkspaceView.settlingProfile`: A suggestion that was just tracked stays on screen, already marked as
tracked, until the next refresh delivers its tracked profile. Nothing is
written from this copy: its evidence is about to be replaced.

#### Tracked copy replaces settling suggestion so the row moves and stays selected
`ProjectsWorkspaceView.listProjects`: The projects the list and the page draw: while a just-tracked
suggestion settles, its tracked copy stands in for the suggestion, so
the row moves under Tracked at once and stays selected.

#### Hiding the open suggestion advances selection; hiding another row leaves page
`ProjectsWorkspaceView.commands`: The open suggestion makes way for the next one; hiding
another row from its menu leaves the page where it is.

#### Just-tracked project appears after the next refresh, so show loading
`ProjectsWorkspaceView.detail`: A project tracked a moment ago appears after the next refresh.

#### Hide Ask for a project nothing names yet
`ProjectsWorkspaceView.toolbar`: A project nothing names yet has nothing to ask about.

#### Not a project: the name is no longer suggested
`ProjectCommands.hide`: "Not a project": the name is no longer suggested.

#### Page shows the first row before any choice
`ProjectsListColumn.selectedID`: The project the page shows, which is the first row before any choice.

#### Scroll to a project opened from elsewhere since it may be below the fold
`ProjectsListColumn`: A project opened from Actions, People or Timeline may sit
below the fold.

#### Heading rows scroll with projects and arrow keys skip them
`ProjectsListColumn.heading`: A heading row, as in the People and Meetings lists: it scrolls with
its projects and arrow keys pass over it.

#### Selection from list; supporting grey does not read on highlight
`ProjectRow.isSelected`: From the list's selection, like the meeting and people rows: the
supporting grey does not read on the highlight.

### `LokalBotTests/Models/Projects/ProjectLinksTests.swift`

#### A review project covering the same name is offered instead of the topic
`ProjectLinksTests.testRecurringTopicsAndReviewProjectsAreSuggestions`: A review project covering the same name is offered instead.

#### Regression 2026-10-16: mention after speaker label counted as sentence start, dropping newest standup
`ProjectLinksTests.testSpeakerLabelledMentionKeepsTheNewestMeeting`: 2026-10-16: a project's newest standup was missing because its only
mention followed a speaker label and counted as a sentence start.

#### Long summaries name projects late and transcript-only meetings must still link
`ProjectLinksTests.testWholeSummariesAndTranscriptsLinkATrackedProject`: Long summaries name a project late, and summary-less meetings only
in the transcript; both still link.

#### Capitalized sentence-start word that is mostly lowercase, in only two meetings, is not a topic
`ProjectLinksTests`: "Launch" starts sentences but is mostly lowercase; "Kestrel"
appears in only two meetings.

### `LokalBotTests/Models/Projects/ProjectsListPresentationTests.swift`

#### Days are calendar days; late yesterday is yesterday, not today
`ProjectsListPresentationTests.testQuietBeginsWhereOthersWorkStopsBeingRecent`: Days are calendar days: late yesterday is yesterday, not "today".

#### A profile built without the count still sums what it lists
`ProjectsListPresentationTests.testWindowsBeyondTheFirstThreeAreSummedInOneLine`: A profile built without the count still sums what it lists.

#### A model that ran elsewhere is named with its server, never as local
`ProjectsListPresentationTests.testProvenanceSaysWhenWhichModelAndWhere`: A model that ran elsewhere is named with its server, never as local.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
