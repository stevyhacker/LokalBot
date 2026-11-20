# 0072. Windows and Linux: app — pages / actions

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/actions/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/actions/details.rs`

#### Details pane shows one action's facts, or shared changes for several
The pane beside the list (`ActionDetailsPane`, `ActionEvidencePassages`).
One selected action shows what the app knows about it: its status, its due
date with what was said about it, the people and project it belongs to,
and each meeting's quotes, which play in place. Several selected actions
show the changes that apply to all of them.

#### Completion hint is only a suggestion until Mark Done
`ActionsPage.render_hint`: "Looks done? Mail showed “Message sent” on Mon 5:48 PM, after this
was said." with Mark Done, Show the screen and Not Yet. A suggestion
only; nothing changes until Mark Done.

#### Due day is saved on the newest mention as a correction
`ActionsPage.due_control`: The Due control: the day, which opens a calendar with No date, Cancel
and Save. The day is saved on the newest mention as a correction.

#### Meeting name opens the quote; a time plays it in place
`ActionsPage.render_passages`: One meeting's mention: the meeting and its day, then what was said.
The meeting name opens the meeting at the quote; a time plays the
quote here.

#### A correction never replaces what was extracted
`ActionsPage.render_passages`: A correction never replaces what was extracted.

#### Open meeting audio off the UI thread when the shown action changes
`ActionsPage.sync_passages`: Opens the audio of each meeting the selected action was said in, off
the UI thread, when the details show a different action.

#### One quote plays at a time, whichever meeting it is from
`ActionsPage.toggle_passage`: One quote at a time, whichever meeting it is from.

### `LinuxWindows/crates/lokalbot-app/src/pages/actions/list.rs`

#### List column draws filter bar, list and stale Review bar mirroring Swift views
The list column (`ActionsFilterBar`, `ActionsList`, `ActionsStaleBar`):
Open / Deferred / Done, the Filter menu with a removable chip per active
choice and the search field; the list under its headings; and the Review
bar for open actions nobody has mentioned in three weeks.

#### CHIP_CHROME is chip padding plus close mark around its words
`CHIP_CHROME`: A chip's padding and close mark around its words.

#### FILTER_CHROME is Filter icon, caret and padding around its word
`FILTER_CHROME`: The Filter button's icon, caret and padding around its word.

#### Each status segment fits the longest status in the interface language
`ActionsPage::render_filter_bar`: Each segment fits the longest status in the interface language.

#### Controls wrap to extra rows when narrow, matching Swift ViewThatFits
`ActionsPage::render_filter_bar`: One row when it fits; more chips than the row holds go to a row of
their own, and in a narrow list so does the search field
(`ViewThatFits`).

#### People/Projects only know open and deferred; grouping and stale review are open-only
`ActionsPage::filter_menu`: The Filter menu: due, person, project, meeting, the stale review and
how the open list is grouped. People and Projects only know open and
deferred work, and grouping and the stale review are for open work.

#### Stale bar replaces the per-row Still open question
`ActionsPage::render_stale_bar`: "8 open actions haven’t been mentioned in 3 weeks. Review": the quiet
bar under the list that replaces the "Still open?" question on rows.

### `LinuxWindows/crates/lokalbot-app/src/pages/actions/mod.rs`

#### Actions page lists user's actions once each; status changes go through library, never alter extraction
Actions, a sidebar destination (`ActionsWorkspaceView.swift`): the user's
own actions from meetings, each said once however many meetings it came
up in. Open / Deferred / Done and one Filter menu choose what the list
shows, in attention order; the pane beside it shows the selected action
and the evidence behind it, or what changes several selected actions
together. Status changes and corrections go through the library and never
alter what was extracted.

`model` decides what is listed and how it reads, `list` draws the controls
and the list, `details` the pane beside it.

#### Details pane starting width matches Mac LBTokens detailsPaneWidth
`DETAILS_WIDTH`: The details pane's starting width (`LBTokens.Metric.detailsPaneWidth`).

#### Built list is rebuilt only when one of these key fields changes
`ContentKey`: What the built list was made of; it is rebuilt only when one changes.

#### One audio player per meeting, opened only when details show quotes
`Passages`: The audio behind the selected action's quotes, one player per meeting,
opened when the details show it (`ActionEvidencePassages`).

#### Counter drops results of an older reload that finishes late
`ActionsPage.reloads`: Reloads started; an older one that finishes late is dropped.

#### Generation is bumped whenever threads, hints or links change
`ActionsPage.generation`: Bumped whenever the threads, hints or links change.

#### Threads whose status just changed stay listed until view or filters change
`ActionsPage.kept`: Threads whose status just changed here; they stay listed until the
view or its filters change.

#### Load lazily when first shown, then whenever library revision changes
`ActionsPage::new`: Loads when first shown, then whenever the library changes.

#### Load threads and hints first for speed, then people and projects
`ActionsPage::reload`: Reads the user's threads and hints first, so the list shows quickly,
then the people and projects they belong to.

#### Completion hints are suggestions only, from text kept with consent
`ActionsPage::reload`: Suggestions only, and only from text kept with consent.

#### Actions are linked to people and projects by looking them up in those read models
`ActionsPage::reload`: People and Projects list the user's open and deferred work; the
page looks each action up in them.

#### Changing the view releases rows kept in place
`ActionsPage::update_filter`: Changes the filter; a changed view lets go of the rows kept in place.

#### List rebuilds only when inputs change; scroll position kept unless view changed
`ActionsPage::content`: The list for the current filter, rebuilt only when what it is made of
changed. Rebuilding keeps the scroll position unless the view changed.

#### Keyboard: Up/Down move selection, Shift extends, Escape collapses, Ctrl+A selects all
`ActionsPage::on_list_key`: Up and Down move the selection (Shift extends it), Escape goes back
to one row and Ctrl+A selects every listed row.

#### Status change reaching several meetings is confirmed first
`ActionsPage::request_status`: One action said in several meetings changes in each of them, so that
change is confirmed first, for one row or for a batch.

#### Changed rows stay in place until the view changes
`ActionsPage::apply_status`: Changed rows stay where they are; the list closes up when the view
changes.

#### Not mine uses the same correction path as the editor
`ActionsPage::not_mine`: "Not mine" clears the owner of every mention through the same
correction path as the editor, so the action leaves this list.

#### Edit corrects the newest mention via a sheet with date picker
`ActionsPage::edit`: "Edit…": the correction sheet for the newest mention, with its date
picker (`ActionEditorSheet`).

#### Subtitle shows open count like the Mac toolbar
`ActionsPage::subtitle`: "2 open", as the Mac's toolbar says under the title.

#### Plan in Agent drafts most urgent open threads and never sends
`ActionsPage::toolbar`: "Plan in Agent…" while anything is open (a new Agent task with the
most urgent open threads as its draft, never sent by itself), then the
Details toggle.

#### Page loads on first draw, which happens only while it is current
`ActionsPage::render`: Drawn only while it is the current page: the first time, load.

#### Details pane sits left of the list in right-to-left interface
`ActionsPage::render`: The pane sits on the trailing side: left of the list in a
right-to-left interface, as the window's other columns mirror.

### `LinuxWindows/crates/lokalbot-app/src/pages/actions/model.rs`

#### Model decides listing, order, headings, wording and corrections; display-only, mirrors Swift
What the Actions page decides before it draws (`ActionsListPresentation.swift`
and `ActionAttentionOrder` in `ActionThreads.swift`): which threads the
status, search and Filter menu list, in what order and under which
headings, the wording of every row, the chips of the active filters, the
people and projects an action belongs to, which rows are selected, and the
corrections the details pane saves. Display-only: nothing here is stored
or sent.

#### Filter menu offers at most 40 meetings, newest first
`MAXIMUM_MEETING_CHOICES`: Meetings the Filter menu offers, newest first.

#### Done list's first heading spans 7 days including today
`RECENTLY_DONE_DAYS`: The Done list's first heading reaches back this many days, today included.

#### Details pane names at most 4 people or projects per action
`MAXIMUM_LINKS`: People or projects the details pane names for one action.

#### Open on its own is a verb, so status uses a separate catalog key
`state_key`: The catalog key for a status as a state. "Open" on its own is the verb on
buttons, which most languages translate differently (`stateKey`).

#### ListFilter mirrors Swift ActionsListFilter: status, search and Filter menu choices
`ListFilter`: What the page lists: one status, a search, and the choices of its Filter
menu (`ActionsListFilter`).

#### Filter by meeting title so a weekly standup is one choice
`ListFilter.meeting_title`: Every meeting with this title, so a weekly standup is one choice.

#### Stale means open and not mentioned for three weeks
`ListFilter.stale_only`: Open actions nobody has mentioned for three weeks.

#### Stale review exists only among open actions
`ListFilter::is_stale_review`: The stale review only exists among open actions.

#### Leaving Open drops filters that cannot apply to other statuses
`ListFilter::show`: Done actions are outside the People and Projects read models, and the
stale review is about open work, so leaving Open drops what cannot
apply.

#### Link source holds a person's or project's open and deferred reference ids
`LinkSource`: What one person or project contributes to [`ThreadLinks`]: its own open
and deferred work for the user, as action reference ids.

#### Links are looked up backwards from People/Projects read models; nothing new derived
`ThreadLinks`: The people and projects an action belongs to, looked up backwards from the
People and Projects read models (`ActionThreadLinks`). Those models list
the user's open and deferred work per person and per project; nothing new
is derived here.

#### Threads are found by reference ids so re-threading keeps links
`ThreadLinks.people_by_reference`: Action reference id to positions in `people` and `projects`. A thread
is found by its references, so re-threading does not lose the link.

#### Tracked projects are listed before suggested ones
`ThreadLinks::from_sources`: Projects the user tracks lead; suggested ones follow.

#### Day label format: Today, Yesterday, weekday date for past week, then short date
`day`: "Today", "Yesterday", "Fri, Nov 6" for the rest of the past week, then
"Oct 27" (`lokalbot_i18n::day_label`), for a moment on its local day.

#### Due text rules: overdue Was due, amber within week, Done list shows completion
`due_label`: The due text on a row. Overdue open work reads as "Was due", due today or
within the week keeps the amber tone, and a later date, a phrase that
names no day, and work that is no longer open stay quiet. The Done list
shows when the action was completed instead.

#### Under a meeting heading the row only says where else it was said
`other_meetings`: Under a meeting heading the row only says where else it was said.

#### Control row arrangement mirrors Swift ActionsFilterBar ViewThatFits
`BarLayout`: How the row of controls above the list arranges itself in its width
(`ActionsFilterBar`'s `ViewThatFits`).

#### Widths exclude the bar's 16-point sides and 8-point gaps
`filter_bar_layout`: Chooses the first arrangement whose rows fit in `width`; widths are the
controls' own, without the bar's 16-point sides and 8-point gaps.

#### Source shows meeting plus day only where group gives none; empty under meeting heading
`Row.source`: The meeting it came from, with a day where the group does not already
give one. Empty under a meeting heading.

#### Wording is made before drawing so rows do no work
`ListContent`: The list as it is drawn: filtered, ordered and grouped threads with each
row's wording already made, so rows do no work of their own
(`ActionsListContent`).

#### Open count ignores what the list is showing
`ListContent.open_count`: The user's open actions, whatever the list is showing.

#### Attention buckets: overdue, due within week, later; mirrors Swift ActionAttentionOrder
`Bucket`: Overdue, due within the week, then later or undated (`ActionAttentionOrder.Bucket`).

#### A due phrase naming no day counts as no date
`bucket`: A due phrase that names no day counts as no date.

#### Just-changed threads stay listed so a ticked row does not vanish
`ListContent::build`: `kept`: threads whose status the user just changed in this view. They
stay listed until the view or its filters change, so a ticked row does
not vanish under the pointer.

#### Stable sort keeps order of threads from the same moment
`ListContent::build`: Stable: threads from the same moment keep their order.

#### Stable sort keeps list order for threads done at same moment
`ListContent::build`: Threads done at the same moment keep their list order.

#### Matching runs before just-changed rows are added back
`matches`: Whether the filter lists this thread, before the rows the user just
changed are added back.

#### One row is always current; Ctrl-click toggles, Shift-click ranges
`Selection`: Which rows the list acts on (`ActionListSelection`). One row is always
current, as in a mail list: the chosen rows that are still listed, or else
the first row. Ctrl-click adds or removes a row and Shift-click takes a
range.

#### Last selected row cannot be deselected
`Selection::click`: The last row cannot be deselected: one row is always current.

#### A YYYY-MM-DD phrase is a day someone chose, not said
`is_explicit_date`: "2026-11-12": a day someone chose rather than said.

#### Due control shows resolved day, Pick a date for vague phrase, or No date
`due_title`: The Due control: the resolved day, "Pick a date" for a phrase that names
no day, or "No date".

#### Said phrases listed newest meeting first, excluding typed-in days
`said_due_phrases`: Due phrases as they were said, newest meeting first, without the days
someone typed in.

#### Chosen due day saved on newest mention; text and owner unchanged
`due_correction`: A due day chosen in the details pane, or none. It is saved on the newest
mention, whose correction a thread takes as its due date. Text and owner
keep whatever they are.

#### Not mine clears owner of every user mention so action leaves list in each meeting
`not_mine_corrections`: "Not mine": every mention of the user's loses its owner, so the action
leaves the user's list in each meeting it was said in.

#### Test widths: 32 sides + 250 status + 8 + 80 filter = 370
`the_control_row_gives_way_like_view_that_fits`: 32 sides + 250 status + 8 + 80 filter = 370 before chips and search.

#### Test boundary: 370 + 80 chip + 8 + 8 + 230 search = 696
`the_control_row_gives_way_like_view_that_fits`: 370 + 80 chip + 8 + 8 + 230 search = 696.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
