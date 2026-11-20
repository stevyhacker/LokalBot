# 0076. Windows and Linux: app — pages / projects

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/`, `LinuxWindows/crates/lokalbot-app/src/pages/projects/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/projects.rs`

#### With nothing chosen the page shows the first row
`ProjectsPage.selected`: The project the page shows; with nothing chosen, the first row.

#### Tracks project and revision last offered an automatic note, to ask again on change
`ProjectsPage.note_considered`: The tracked project and library revision last offered an automatic
note, so one is asked for when the project or its evidence changes.

#### Per-project page state resets when another project opens
`ProjectsPage.shows_all_others`: The page's own state, reset when another project opens.

#### Tracking an already-known name opens that project instead of adding (ProjectStore.track)
`ProjectsPage.track`: `ProjectStore.track`: adds a tracked project and opens it, or opens the
one already known by that name.

#### Stopping tracking is explicit removal and deletes the project's note
`ProjectsPage.stop_tracking`: Stopping is an explicit removal: the project's note goes with it
(`ProjectStore.stopTracking`).

#### Merge moves source names to target and discards the source note
`ProjectsPage.merge`: `ProjectStore.merge`: the source's names move to the target, and its
note is discarded.

#### A suggestion becomes a name of a tracked project, which opens
`ProjectsPage.add_name`: `ProjectStore.addName`: a suggestion becomes a name of a tracked
project, which opens.

#### Hiding the open suggestion advances to the next; hiding another row keeps the page
`ProjectsPage.hide_suggestion`: "Not a project": the name is no longer suggested. The open suggestion
makes way for the next one; hiding another row from its menu leaves
the page where it is.

#### A project focused from another page may be below the list fold, so scroll to it
`ProjectsPage.take_focus`: Opens a project another page asked to show; it may sit below the
fold of the list.

#### With nothing chosen, the most recent tracked project else first suggestion
`ProjectsPage.selected_project`: The project the page shows and whether it is still settling. With
nothing chosen, the first row: the most recently active tracked
project, else the first suggestion.

#### Opening a tracked project may refresh its note; engine decides; settling projects wait
`ProjectsPage.consider_note`: Opening a tracked project writes or refreshes its note when that is
due (`writeProjectSummary(for:automatic:)`); the engine decides. A
project still settling waits for its own evidence.

#### Looks done? hints for open project work are computed only with consent
`hints_for`: "Looks done?" for the open work of yours on each project, only with consent.

#### A project tracked a moment ago appears only after the next load
`ProjectsPage.render`: A project tracked a moment ago appears after the next
load.

### `LinuxWindows/crates/lokalbot-app/src/pages/projects/detail.rs`

#### Stale note stays marked until updated by the person or an approved automatic update
`ProjectsPage.where_it_stands`: The tracked project's "Where it stands" note, the only model-written
text on the page: overview, points with the meeting each comes from,
and open questions. Its heading says when it was written, by which
model and where that ran. A note whose evidence has changed stays,
marked, until the person updates it or an approved automatic update
replaces it.

#### Note being replaced stays readable, dimmed, while the new one is written
`ProjectsPage.where_it_stands`: The note being replaced stays readable while the new
one is written.

#### Each point links its meeting; overnight-review points say so and link nowhere
`ProjectsPage.note_text`: The note's text. Each point ends with the meeting it comes from as a
link; a point from the overnight review says so and links nowhere.

#### Add to tracked project is first answer when it already has half the meetings
`ProjectsPage.suggestion_card`: A suggestion's page opens on the decision: where it came up, then the
answers. When a tracked project already has at least half of its
meetings, adding it there is the first answer; otherwise tracking is.

#### Time panel shows seven days of window time: total, daily bars, longest windows
`ProjectsPage.time`: Window time over the last seven days: the total, a bar a day, and the
longest windows.

#### People column lists at most eight people from the project's meetings
`ProjectsPage.people`: Up to eight people from the project's meetings, each opening their
page.

#### Overnight review text is model-written so it carries the sparkle
`review_note`: The overnight review's own words about a suggestion, which a model
wrote, so they carry the sparkle too.

### `LinuxWindows/crates/lokalbot-app/src/pages/projects/list.rs`

#### Projects quiet for weeks are drawn fainter
`ProjectsPage.render_row`: One project in the list (`ProjectRow`): its monogram and name, when it
was last active or where the suggestion came from, and the user's
open actions. A project quiet for weeks is drawn fainter.

### `LinuxWindows/crates/lokalbot-app/src/pages/projects/model.rs`

#### Projects page model mirrors ProjectsListPresentation.swift, kept apart from drawing
The Projects list and a project's page as plain data
(`ProjectsListPresentation.swift`): tracked projects by last activity,
then suggestions with where each came from; which tracked project a
suggestion probably belongs to; the side column's week of window time;
and the wording put together from counts, dates and names. Kept apart
from drawing so it can be tested.

#### Quiet after two weeks, same cutoff as others' recent actions
`QUIET_AFTER_DAYS`: A project nothing has named for this many days reads "Quiet since…";
the same two weeks after which other people's open work stops counting
as recent.

#### Show three of others' actions before Show N more
`VISIBLE_OTHERS_ACTIONS`: Other people's actions shown before "Show N more".

#### Show four meetings before Show all N
`VISIBLE_MEETINGS`: Meetings shown before "Show all N".

#### List three windows before N more windows
`VISIBLE_WINDOWS`: Windows listed before "N more windows".

#### Time under a minute is hidden, matching Timeline
`MINIMUM_SECONDS`: Time under a minute is not shown, as on Timeline.

#### Side column shows REVIEW_DAYS days of window time
`REVIEW_DAYS`: The days of window time the side column shows.

#### Names in this many meetings become suggestions
`MINIMUM_MEETINGS`: Names that come up in this many meetings are suggested.

#### Below 720 px the Ask button shows only its icon
`COMPACT_TOOLBAR_WIDTH`: Below this width the toolbar's Ask button shows its icon alone.

#### Tracked project selection and note id is tracked:\<UUID>
`selection_id`: `tracked:<UUID>`, the selection and note id of a tracked project.

#### Activity is newest meeting, overnight review note, or window-time day
`Activity`: How recently anything named a project: its newest meeting, overnight
review note, or day with window time.

#### Recent means within the last QUIET_AFTER_DAYS days
`Activity::Recent`: Within the last `QUIET_AFTER_DAYS` days.

#### Row mirrors ProjectsListContent.Row in the Mac app
`Row`: One project in the list (`ProjectsListContent.Row`).

#### Row id doubles as the list selection
`Row.id`: The project's id, which is also the list's selection.

#### Quiet rows are drawn fainter when nothing named the project for weeks
`Row.is_quiet`: Drawn a little fainter: nothing has named the project for weeks.

#### Count only the user's own open actions
`Row.open_actions`: The user's own open actions on the project.

#### Tracked by last activity, then suggestions in offered order
`ListContent`: The list as it is drawn: tracked projects by last activity, then
suggestions in the order they are offered.

#### Query matches name or other names; just-hidden suggestions leave early
`ListContent::build`: `query` matches a project's name or any of its other names. A
suggestion hidden a moment ago leaves before the next refresh.

#### Suggestions keep offered order: meeting count, then overnight review
`ListContent::build`: Suggestions keep the order they are offered in: names from
meetings by how many meetings, then the overnight review's.

#### After removing a suggestion select the next, else first; None opens first tracked
`ListContent::selection_after_removing`: What opens once a suggestion leaves the list: the suggestion after
it, else the first one left. None when it was the last suggestion,
and then the page opens the first tracked project.

#### A heading leads each non-empty group in the list children
`ListContent::child_index`: The row's position among the list's children: a heading leads each
group that has rows.

#### Suggested (one project) has its own key: singular, and heading not in every language
`subtitle`: Its own key: beside one project the word is singular, and the list's
"Suggested" heading is not in every language.

#### Home mirrors ProjectSuggestionHome.Match in the Mac app
`Home`: The tracked project a suggestion probably belongs to
(`ProjectSuggestionHome.Match`).

#### Counts the suggestion's meetings the project already has
`Home.shared_meetings`: How many of the suggestion's meetings the project already has.

#### Shared meetings count only when at least half; None for no meetings
`shared_meetings`: How many of the suggestion's meetings the project already has, when that
is at least half of them; None otherwise, and for a suggestion no
meeting names.

#### Home is tracked project sharing most meetings, first on tie, no model
`suggestion_home`: The tracked project that already has at least half of the suggestion's
meetings: the one sharing the most when several do, the first in the
list on a tie. Deterministic; no model decides.

#### Just-tracked suggestion shows as tracked until load; nothing written from copy
`settling_profile`: A suggestion that was just tracked stays on screen, already as tracked,
until the next load delivers its tracked profile
(`ProjectsWorkspaceView.settlingProfile`). Nothing is written from this
copy: its evidence is about to be replaced.

#### Settling tracked copy replaces the suggestion so the row moves at once
`list_projects`: The projects the list and the page draw: while a just-tracked suggestion
settles, its tracked copy stands in for the suggestion, so the row moves
under Tracked at once and stays selected.

#### Others' work listed recent or due-ahead first, then older
`others_actions`: Other people's open work in one list: what was mentioned recently or is
due ahead first, then the older work.

#### Zero seconds for a day with no window time naming the project
`Day.seconds`: Zero for a day with no window time that names the project.

#### Days oldest first, ending today, zero-filled; mirrors ProjectTimePresentation.days
`days`: The days the window time covers, oldest first and ending today, with
zero for a day without time (`ProjectTimePresentation.days`).

#### Bar height is 0 to 1 of the tallest day
`fraction`: How tall a day's bar is, from 0 to 1 of the tallest day.

#### Project counts every window but lists only the longest
`rest`: The windows behind "N more windows" and their time together. The
project counts every window; it lists only the longest.

#### Durations under a minute still read as one minute
`duration`: "40h 10m", "35m"; under a minute still reads as one.

#### Port saves 'on this PC'; an empty location is never a server
`written_here`: Whether a note was written on this computer: the port saves "on this
PC", and an empty location is never a server.

#### GPUI cannot measure text first, so widths are estimated from characters
`provenance_fits_beside`: Whether the note's provenance fits beside "Where it stands" and its
button (`ViewThatFits`); otherwise it goes under the title. GPUI cannot
measure a line before laying it out, so this estimates the widths from
the text: half an em a character, a full em for wide (CJK) ones.

#### Title width adds sparkle, gaps, button and card padding
`provenance_fits_beside`: Sparkle and gaps, the button's padding, the card's own padding.

#### Fixed local-time Tuesday noon so day words ignore machine time zone
`tests::now`: A Tuesday at noon, local time, so day words do not depend on the
machine's time zone.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
