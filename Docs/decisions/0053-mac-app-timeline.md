# 0053. Mac app: Timeline

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Timeline/`, `LokalBot/Services/Timeline/`, `LokalBot/Views/Timeline/`, `LokalBotTests/Models/Timeline/`, `LokalBotTests/Services/Timeline/`.

## Decisions

### `LokalBot/Models/Timeline/DayActivityProjection.swift`

#### One definition of active time for all day surfaces, clipped to civil day
`DayActivityProjection`: One definition of active time for every day surface: the union of valid,
non-system intervals, clipped to the selected civil day (including DST).
The day's coding-agent bursts, when there are any, name and cut the work
sessions by project.

### `LokalBot/Models/Timeline/DayDigestPresentation.swift`

#### Display projection of journal; journal stays the lossless export format
`DayDigestPresentation`: A display-oriented projection of the Markdown journal. The journal remains
the lossless export format; this model only gives the app a scannable,
backwards-compatible hierarchy for both old and newly generated digests.

#### Status is parsed from the journal's lead word, which summary drops
`DayDigestPresentation.FocusBlock.status`: Parsed from the journal's "Completed." style lead, which the
summary no longer repeats.

#### Next step shown with its task instead of a separate list
`DayDigestPresentation.FocusBlock.nextStep`: The journal's "Next — task: step" follow-up, shown with its task
instead of repeating the task title in a separate list.

#### Order tasks for scanning: open work first, finished last
`DayDigestPresentation.TaskGroup`: Tasks ordered for scanning: open work first, finished work last.

#### View names each task kind through the interface catalog
`DayDigestPresentation.TaskGroup.Kind`: The view names each kind through the interface catalog.

#### Free-form follow-ups show as task-like rows with continuing ids
`DayDigestPresentation.followUps`: Follow-ups that are neither a decision, a blocker, nor the next step
of a listed task, such as older journals' free-form items. Shown as
rows like tasks; their ids continue after the tasks' ids.

#### Collapse titled tasks only in task-first journals; older summaries stay visible
`DayDigestPresentation.collapsesDetails`: Whether a task row shows only its title and next step, with the
summary opening on demand. Task-first journals give tasks a status,
and there every titled task collapses, including the ones whose status
the generator left unknown. Older journals never carry a status; their
summary is the only description, so it stays visible.

#### Task-first journals give tasks a status; older journals never do
`DayDigestPresentation.isTaskFirst`: Task-first journals give their tasks a status; older journals never do.

#### Show next-step and blocked tasks in full; older journals show all in full
`DayDigestPresentation.timelineRows`: Timeline shows a group's tasks that carry a next step, and every
blocked task, in full; the rest of the group become one-line rows.
Older journals have neither statuses nor next steps, and their summary
is the only description, so all of their tasks stay in full.

#### Split trailing parenthetical off task title as a tag
`DayDigestPresentation.titleAndTag`: Splits a trailing parenthetical off a task title, such as the project
in "Review all open PRs (LokalBot)" or the pull request in
"Staging deployment (PR #487)", so the view can show it as a tag.

#### Suppress duplicated items from older journals at presentation time
`DayDigestPresentation.removingSimilarContent`: New journals give every fact one section. Older journals can contain
the same task in overview, task, and follow-up sections, so suppress
copied or lightly rephrased items at presentation time as well.

#### Split follow-ups into decisions, blockers, rest; attach Next to its task; drop duplicates
`DayDigestPresentation.followUps`: Splits the journal's follow-up list into decisions, blockers, and the
rest, and moves each "Next — task: step" onto the task it names. Items
already said by a task, the overview, or an earlier item are dropped.

#### Strip Decision and Blocker label leads from items
`DayDigestPresentation.removingLabel`: `Decision: …` and `**Blocker:** …` leads, without the label.

#### Longest shown title prefix wins since titles can contain colons
`DayDigestPresentation.nextStep`: `Next — <task title>: <step>`. Task titles can contain colons, so the
longest shown title that prefixes the item wins; otherwise the first
colon separates an unknown title from its step.

#### Default UI shows at most three overview bullets; legacy paragraphs intact
`DayDigestPresentation.conciseOverview`: The journal can retain a longer overview for export, but the default UI
should answer "what mattered?" in one glance. Paragraph-style legacy
summaries are kept intact; generated bullet lists show at most three.

#### Split task-first and legacy block shapes without exposing Markdown or evidence ids
`DayDigestPresentation.focusBlock`: Task-first journals store `**task** — summary`; previous journals used
`**time · topic** — summary [screen:id]`. Split both shapes for the UI
without exposing Markdown syntax or private evidence identifiers.

#### Task summaries open with the generator's settled status
`DayDigestPresentation.statusLead`: Task summaries open with the status the generator settled on.

### `LokalBot/Models/Timeline/TimelineDayLayout.swift`

#### Rail takes a width share, yields before page minimum, scales with text size
`TimelineRailMetric`: Timeline's body: the day's page on the leading side and a rail on the
trailing one, with a hairline between them. The rail takes a share of the
width between its two sizes, and gives way before the page gets tighter
than its minimum. Widths are in points at the default text size; the
rail's two sizes grow with larger text.

#### Minimum rail width applies at the default 1,180-point window
`TimelineRailMetric.minimumWidth`: The rail in the app's default 1,180-point window.

#### Rail takes 30% of body while between ideal and minimum
`TimelineRailMetric.share`: The rail's share of the body while it is between those two.

#### Floor width keeps a time, short title and duration fitting a row
`TimelineRailMetric.floorWidth`: The rail in the narrowest window: a time, a short title and a
duration still fit a row.

#### Maximum drag width leaves page most of a normal window
`TimelineRailMetric.maximumWidth`: The widest the rail can be dragged: room for long session titles
while the page keeps most of a normal window.

#### Page keeps the minimum width every detail pane has
`TimelineRailMetric.pageMinimumWidth`: The page keeps the minimum every detail pane has.

#### Opening width; dragging changes it within floor and maximum and is remembered
`TimelineRailMetric.width`: The rail's opening width in a body `available` points wide. Dragging
the divider changes it between `floorWidth` and `maximumWidth`, and
the split remembers the dragged width.

#### Larger text can ask for a wider rail than a narrow window allows
`TimelineRailMetric.width`: Larger text asks for a wider rail than a narrow window can give.

#### Panels fill the main area inside gutters up to a widest line
`TimelinePageMetric`: The day's page: panels that fill the main area inside their gutters, up
to a widest line in a very wide window.

#### Maximum panel width excludes gutters
`TimelinePageMetric.maximumWidth`: The panels' widest, gutters not included.

#### Detail line is nil on a day with neither meetings nor outcomes
`TimelineTrackedSummary.detail`: "4 meetings · 4 PRs opened · 1 merged", or nil on a day with neither.

#### Meetings total is the legend's last row; zero omits it
`TimelineTrackedSummary.meetingSeconds`: The meetings' total, the legend's last row. Zero leaves the row out.

#### Block is left out for a day with no tracked time and no meetings
`TimelineTrackedSummary.init`: Nil for a day with no tracked time and no meetings: the block is left out.

#### Detail lists meetings then agent outcomes, each count its own catalog entry
`TimelineTrackedSummary.detail`: The meetings, then what the day's agents recorded, each count its own
catalog entry.

#### Widen thin bars' click area to minimum width, kept inside lane
`TimelineDayStrip.hitFrame`: Where a click counts for a bar: its own place, widened to
`minimumWidth` around its middle when it is drawn thinner, and kept
inside the lane. The bar itself is drawn no wider than its time.

#### Draw longest bars first so short bars' hit areas overlay neighbours
`TimelineDayStrip.hitOrder`: Bars in the order to draw them: the longest first, so a short bar's
widened click area lies over its longer neighbour's edge.

#### Pill says open count, or All done; deferred-only days say 0 open
`TimelineDayActions.pill`: "2 open" while anything is; "All done" once every action is done.
Deferred actions are neither, so a day with only those says "0 open".

#### Keep rows after ticking the last open action so list does not vanish
`TimelineDayActions.showsRows`: The panel lists its actions while one is open. Once none is, it is a
header alone, except that rows the reader was just shown stay, so
ticking the last one does not take the list away.

### `LokalBot/Models/Timeline/TimelineDayList.swift`

#### Display-only day list; sessions in a meeting's call app fold into it
`TimelineDayList`: The list in Timeline's rail for one day: its work sessions and meetings in
time order under Morning, Afternoon and Evening, with long stretches of
nothing kept as gaps. A session spent in the app a recorded meeting ran in folds into
that meeting, so a call is listed once. Display only; nothing here is
stored, and a folded session's activity stays in All captured activity.

#### Morning before noon, afternoon before five, evening after
`TimelineDayList.Part.part`: Before noon, before five, and the rest of the day.

#### Second line shows project and outcomes or apps; empty when title says it all
`TimelineDayList.Row.detail`: The second line: project and what was produced, or the apps, for
work; "Meeting · app" for a meeting. Empty when the title says it all.

#### Duration is a session's active time or a meeting's length
`TimelineDayList.Row.duration`: A session's active time; a meeting's length.

#### Color by project, else busiest app on days without projects; nil is other
`TimelineDayList.Row.colorKey`: What colours a session's dot and its bar in the day strip: its
project, or its busiest app on a day without projects. Nil reads
as other activity. Meetings keep their own tone.

#### Titles that only list apps read quieter than ones naming work
`TimelineDayList.Row.isQuiet`: A title that only lists apps reads quieter than one that names work.

#### Call-app sessions folded into this meeting
`TimelineDayList.Row.foldedSessionIDs`: Call-app sessions folded into this meeting.

#### Thirty minutes of nothing recorded gets an Away line
`TimelineDayList.minimumGap`: A stretch this long with nothing recorded gets its own "Away" line.

#### Call-app session folds into a meeting covering 60% of it
`TimelineDayList.foldShare`: A call app's session folds into a meeting that covers this much of it.

#### usesProjectColors makes sessions without a project read as other activity
`TimelineDayList.init`

- Parameters:
  - usesProjectColors: the day's time is split by project, so a
session without one reads as other activity.
  - localize: looks a catalog key up in the interface language.

#### A meeting sorts before a session starting at the same time
`TimelineDayList.init`: A meeting leads a session that starts with it.

#### Away gap closes the part of day where it began
`TimelineDayList.init`: The gap closes the part of the day it began in, like the list reads.

#### Folded call is recorded time shown as its meeting's row
`TimelineDayList.init`: A folded call is recorded time, shown as its meeting's row.

#### Fold call session into most-covering meeting at foldShare; never fold project or agent work
`TimelineDayList.meeting(covering:in:)`: The meeting a call-app session belongs to: the one that covers most
of it, when that is at least `foldShare`. Work with a project or
agent sessions is never folded.

#### Sampler app names differ from LokalBot call-app names, so match by containment
`TimelineDayList.isSameApp`: The activity sampler stores an app's own name ("zoom.us", "Microsoft
Teams") and a meeting the name LokalBot gives its call app ("Zoom",
"Teams"), so one may contain the other.

#### Project sessions lead with task; otherwise window leads and apps follow
`TimelineDayList.workText`: A session's two lines. With a project the task leads and the project
moves to the second line beside what the agents produced. Without
one, the window that named the session leads and its apps follow. A
session only its apps describe is one quiet line.

#### Meeting detail reads Recording while live, else Meeting
`TimelineDayList.meetingDetail`: "Meeting · Zoom", or "Recording · Zoom" while it is being recorded.

#### Older digest time ranges open the most-overlapping session
`TimelineDayList.workRow(inTimeRange:)`: The session a digest task's "09:00–10:30" covers most, so an older
digest's time range can open that session.

#### Range ending before start runs past midnight, clipped to the day
`TimelineDayList.interval(fromTimeRange:)`: "09:00–10:30" on `day`. A range that ends before it starts runs past
midnight and is clipped to the day.

#### Outcome counts are separate catalog entries for every language
`TimelineOutcomeWording`: "3 PRs opened · 1 merged", or the commits when no pull request moved.
Each count is its own catalog entry, so every language words it.

#### Selection none is a moment opened from another page, owning no row
`TimelineListSelection`: What Timeline's main area shows: the day's page (`digest`, with no row
chosen in the rail), a session or meeting row, or all captured activity.
`none` is a moment opened from another page, which belongs to no row.

#### Arrow-key order: day page first, rows, then All captured activity
`TimelineListSelection.order`: The rail from top to bottom, for the arrow keys. The day's page
stands before the first session, where no row is chosen: Up from the
first session returns to it, as choosing that session again does.
All captured activity, the rail's bottom row, follows the last one.

#### Stop at ends; unshown selection lands on the day's page
`TimelineListSelection.moved`: The selection `step` rows away, stopping at either end. From a
selection the rail does not show, any step lands on the day's page.

#### Build 12-hour pattern manually: FormatStyle pads hour on macOS 15 and 26
`TimelineListClock`: The time on a row of Timeline's list: "9:10" on a 12-hour clock, without
AM or PM (the list is under Morning, Afternoon and Evening) and without a
leading zero; a 24-hour clock keeps its locale's own form. The pattern is
built here because `Date.FormatStyle` with the day period omitted pads
the hour ("09:10") on macOS 15 and 26.

#### Cache last formatter since a list uses one locale
`TimelineListClock.cached`: The last formatter made: a list draws every row with one locale.

### `LokalBot/Models/Timeline/TimelineDayStrip.swift`

#### Strip spans whole hours within the civil day; bars select list rows
`TimelineDayStrip`: The day strip in Timeline's rail: the hours left to right, meetings in a
lane above work. Each bar stands for a row of the list under it, so
clicking one selects that row. Positions are fractions of the strip's
span, which runs over whole hours and never leaves the civil day.

#### Bar positions are fractions: 0 leading edge, 1 trailing
`TimelineDayStrip.Bar.start`: Where the bar starts and ends, 0 at the leading edge and 1 at the trailing one.

#### First hour and noon show AM or PM where clock has them
`TimelineDayStrip.Tick.namesDayPeriod`: The first hour and noon say AM or PM where the clock has them.

#### One tick per hour up to last hour starting inside span
`TimelineDayStrip.ticks`: One per hour, from the first hour to the last one that starts inside the span.

#### Strip is nil for a day with no rows inside it
`TimelineDayStrip.init`: Nil for a day with no rows inside it.

#### End on the hour needs no extra hour; otherwise round up
`TimelineDayStrip.init`: An end on the hour needs no extra hour; any other rounds up.

#### Step ticks by calendar so daylight-saving days keep their hours
`TimelineDayStrip.init`: Step by the calendar so a daylight-saving day keeps its hours.

#### Label every second or third hour on long days, starting with first
`TimelineDayStrip.labelledTicks`: The ticks that get a label when only `count` labels fit: every
second or third hour on a long day, always starting with the first.

#### Short bars keep minimum width so they are visible and clickable
`TimelineDayStrip.frame`: A bar's place in a lane `width` points wide. A short bar keeps
`minimumWidth` so it can be seen and clicked, and never leaves the lane.

#### Legend groups by project when agent sessions name projects, else by app
`TimelineDayLegend`: Where the day's tracked time went, for the strip's legend: by project
when coding-agent sessions name projects, else by app.

#### Only apps and projects get colour; folded entries are neutral
`TimelineDayLegend.Entry.colorKey`: An app or a project has its own colour; the folded entries are neutral.

#### Show four busiest projects, fold the rest, then unclaimed time
`TimelineDayLegend.projectEntries`: The four busiest projects, the rest folded together, then the time no
project claims.

#### Day's actions are those a meeting that day mentioned, done included
`TimelineDayActions`: The day's actions on Timeline's page: the user's actions that a meeting of
that day mentioned, done ones included.

#### None open but some deferred rather than done
`TimelineDayActions.Summary.noneOpen`: Nothing is open, and some are deferred rather than done.

#### Open work first, then rest, in the index's order
`TimelineDayActions.threads`: Open work first, then the rest, each in the index's order.

#### Menu title names the action; a digest is never rewritten unasked
`TimelineDigestPreview.menuTitle`: The catalog key of the menu item that writes the digest. It names what
choosing it will do: write the first digest, update one that has newer
activity, or rewrite a current one. Each is an explicit action; a
digest is never rewritten without being asked.

### `LokalBot/Models/Timeline/TimelineProjectAttribution.swift`

#### Deterministic project attribution by names and agent bursts; no model decides
`TimelineProjectAttribution`: Splits the day's foreground activity across the projects its coding-agent
sessions worked in. A window whose title names a project counts toward
it. Time in an app where an agent runs (Claude, Codex, a terminal, an
editor) goes to the agent bursts it overlaps, and only for the part those
bursts cover. Everything else stays unattributed. This is deterministic
matching on project and repository names; no model decides.

#### Only person-started bursts count, not scheduled runs
`TimelineProjectAttribution.bursts`: Bursts the person started, not scheduled runs, oldest first.

#### Two-minute margin: burst starts with a request typed just before
`TimelineProjectAttribution.edgeMargin`: Agent activity counts for a window this close to a burst's edges: a
burst starts with the request, which the person typed just before.

#### Busiest project wins a title naming two
`TimelineProjectAttribution.init`: The busiest project wins a title that names two.

#### Linked repositories name projects; day-project repos stay, others go to top linker
`TimelineProjectAttribution.init`: A repository a session linked names its project too, as when the
folder is "alpha" and the repository "logic-onchain". One named
after a project of the day stays that project's; any other goes to
the project that linked it most.

#### Shares never exceed block duration; remainder is unattributed
`TimelineProjectAttribution.shares(for:)`: The block's time per project, busiest first. The shares never add up
to more than the block's duration; the remainder is unattributed.

#### Match each distinct window title against projects once per day
`TimelineProjectAttribution.shares(for blocks:)`: Each block's shares, in order. A day repeats the same window titles
many times, so each distinct one is matched against the projects once.

#### Durations add up like perApp so totals agree
`TimelineProjectAttribution.split`: Tracked time per project for the day, busiest first. Durations add
up like `DayActivityOverview.perApp`, so the two totals agree.

#### Busiest project whose name or repository the title names
`TimelineProjectAttribution.namedProject`: The busiest project whose name or repository the window title names.

#### Fold the title once rather than folded search per name
`TimelineProjectAttribution.namedProject`: Folding the title once is far cheaper than a folded search per name.

#### Bursts in start order so later ones cannot overlap; stop early
`TimelineProjectAttribution.agentShares`: Bursts are in start order, so none after this one can overlap.

#### Covered time is measured inside the block itself
`TimelineProjectAttribution.agentShares`: The covered part is measured inside the block itself.

#### Ties break by name so order never flickers
`TimelineProjectAttribution.ranked`: Busiest first; equal times by name, so the order never flickers.

#### Only agent apps, terminals and editors count; chat apps never do
`TimelineProjectAttribution.hosts`: The app can be where the person drives this agent: its own app, a
terminal, or an editor. A chat app with no coding agent never counts,
so time spent elsewhere while agents work stays unattributed.

#### Match apps whose names carry a channel suffix
`TimelineProjectAttribution.sharedHostPrefixes`: Apps whose name carries a channel, such as "T3 Code (Nightly)".

#### Resumed agent session's bursts read as one task
`TimelineAgentTask`: One agent session's work inside a work session. An agent session that
pauses and resumes leaves several bursts; they read as one task.

#### Group bursts by agent session in first-run order
`TimelineAgentTask.tasks`: Bursts grouped by agent session, in the order each session first ran.

#### Use latest name since sessions get renamed
`TimelineAgentTask.title`: The latest name: a session can be renamed as the work takes shape.

### `LokalBot/Models/Timeline/TimelineWorkSession.swift`

#### Present grouped sessions, not every sampler block; blocks stay in Raw capture
`TimelineWorkSession`: A human-scale stretch of continuous Mac activity. Timeline presents these
sessions instead of exposing every sampler-produced block as a separate
visual stripe. The underlying blocks remain available in Raw capture.

#### True when no window title covered enough; title lists apps
`TimelineWorkSession.titleNamesApps`: True when no window title covered enough of the session to name it,
so the title lists the session's apps instead.

#### Per-project time, empty without agent evidence for the day
`TimelineWorkSession.projectShares`: Tracked time per project, busiest first. Empty without coding-agent
evidence for the day.

#### Each burst belongs to one overlapping session so outcomes count once
`TimelineWorkSession.agentBursts`: The agent bursts listed under this session. Each burst belongs to the
one session it overlaps most, so its outcomes are counted once.

#### Title names project and agent task instead of window or apps
`TimelineWorkSession.titleNamesProject`: True when the title names the session's project and the task its
agents worked on, instead of a window or its apps.

#### Project label lists named projects; nil when title names window or apps
`TimelineWorkSession.projectLabel`: The projects the title names, as in "bizstats, alpha". Nil when the
title names a window or the session's apps.

#### Task is agents' task else naming window; nil when only project known
`TimelineWorkSession.taskTitle`: What a project session was about, without the project: its agents'
task, else the window that named it. Nil when only the project is known.

#### Apps under a minute are dropped unless none remain
`TimelineWorkSession.usedApps`: Apps used for at least a minute, busiest first. Apps glanced at for
seconds (a password prompt, a notification) are left out, unless that
leaves none.

#### Titles are observed names; keep source blocks so labels are inspectable
`TimelineWorkSession.TitleEvidence`: Titles are observed window/document names, not generated task claims.
Keep the source blocks so the label can always be inspected.

#### Ten minutes on another project starts a new session
`TimelineWorkSession.projectSwitch`: Work that moves to another project for this long starts a session.

#### Project names session at 20% share of its time
`TimelineWorkSession.projectTitleShare`: A project names the session once it holds this share of its time.

#### Unoverlapping burst joins nearest session within 15 minutes
`TimelineWorkSession.burstAttachDistance`: A burst that overlaps no session joins the nearest one this close.

#### Short gaps stay together; with agent evidence cut at project change and name by task
`TimelineWorkSession.sessions`: Collapse adjacent blocks into one work session. A short gap usually
represents reading, typing, or switching apps rather than a new task.
With coding-agent evidence, sessions end where the work moves to
another project instead of at a fixed length, and take their names
from the project and its agents' tasks.

#### Ranked shares make each block's first share its project
`TimelineWorkSession.sessions`: Ranked shares, so each block's first share is its project.

#### Cut at gaps, maximum duration, and sustained new document
`TimelineWorkSession.appGroups`: Cuts at gaps, after `maximumDuration`, and where a new document holds
attention for a while.

#### Cut only on sustained unseen documents; never cut overlapping blocks
`TimelineWorkSession.appGroups`: Short tool/app switches stay together. A sustained, previously
unseen document after ten minutes is an inspectable boundary.
Never cut overlapping blocks: that would double-count activity.

#### Cut at gaps and sustained project change; no length limit; unclaimed time uses app rules
`TimelineWorkSession.projectGroups`: Cuts at gaps and where the work moves to another project for at least
`projectSwitch`. A brief look elsewhere stays inside the session, and a
project session has no length limit. A stretch too short to stand on
its own joins the work that follows it. Stretches no project claims,
such as reading or chat, fall back to the app rules.

#### Track time other projects held since current was last seen
`TimelineWorkSession.projectGroups`: Time each other project (or none) has held since the current one
was last seen, and the index where that run began.

#### Wait for an edge no earlier block runs across before cutting
`TimelineWorkSession.projectGroups`: Wait for an edge no earlier block still runs across.

#### Too-short stretch joins the new project's session
`TimelineWorkSession.projectGroups`: A stretch too short to stand alone joins the new project's.

#### Cut only where no earlier block still runs to avoid splitting overlaps
`TimelineWorkSession.cutIndex`: The first index at or after `from` where no earlier block is still
running, so a cut never splits overlapping activity.

#### Assign bursts to most-overlapping or nearest session, then name project sessions
`TimelineWorkSession.assigningAgentWork`: Lists each burst under the session it overlaps most, or the nearest
one when the agent worked between sessions, then names project
sessions after the task their agents worked on.

#### Name busiest project plus top burst task; second project if share is fair
`TimelineWorkSession.nameAfterProject`: "bizstats · Rehearse the audit runbook on staging": the busiest
project, then the task of its burst that overlaps the session most.
A second project that also holds a fair share is named too, as in
"bizstats, alpha · …", so a review in the browser beside agent work
is not lost.

#### List shows project and task on separate lines
`TimelineWorkSession.nameAfterProject`: The list shows the project and the task on separate lines.

#### Fleeting pages stay inspectable without naming the session
`TimelineWorkSession.makeSession`: A fleeting page should remain inspectable without naming the whole session.

#### Seconds-long apps stay in apps but not in title count
`TimelineWorkSession.makeSession`: Apps glanced at for seconds (a password prompt, a notification)
stay in `apps` but don't inflate the title's count.

#### Summary shows two busiest apps then count of more
`TimelineWorkSession.appSummary`: "Claude", "Claude, Safari" or "Claude, Safari +2": the two busiest
apps, then how many more.

#### Do not truncate grouping key; views truncate visually
`TimelineWorkSession.cleanedTitle`: Do not truncate the grouping key: distinct long document names can
share a prefix. Views truncate visually and keep the full AX label.

#### Cut browser status and identity segments from page titles
`TimelineWorkSession.browserChromeMarkers`: Chromium-family windows append status and identity segments to the page
title ("Page - Audio playing - Google Chrome - Stevan"); Firefox appends
"Page — Mozilla Firefox". Those trailing segments are browser chrome,
not content — cut from the first marker segment onward so a session
reads as the page the user actually saw.

#### Chrome tab group names are browser chrome
`TimelineWorkSession.isBrowserChromeSegment`: Chrome names the tab group a tab belongs to ("Part of group Work").

#### Interleave work with meetings without conflating meeting duration with app sampling
`TimelineDayItem`: The primary Timeline stream interleaves grouped work with meetings without
conflating meeting duration with foreground-app sampling.

### `LokalBot/Services/Timeline/ActivityTracker.swift`

#### Activity blocks collapse contiguous app, title and idle samples into SQLite
`ActivityBlock`: M4 day tracking, layer 1 (design doc §3.1): sample the frontmost app +
window title + idle state, collapse contiguous samples into activity
blocks, persist them to the shared SQLite database.

#### Interval is half-open so adjacent ranges never return a capture twice
`ScreenSearchFilter`: Optional constraints shared by keyword and semantic screen-memory search.
The interval is half-open (`start <= timestamp < end`) so adjacent day or
selection ranges never return the same capture twice.

#### One connection per executor; background reads use separate read-only instances
`ActivityStore`: One connection per executor. The app owns its writer on the main actor;
background reads construct a separate read-only instance and never share it.

#### Older screenshots lack columns; ALTER keeps rows, fresh databases have full shape
`ActivityStore.migrateScreenshotColumns`: Screenshots taken by builds before event-driven capture lack the
`window_title` / `capture_trigger` columns. ALTER is cheap and keeps
existing rows; fresh databases already have the full shape.

#### FTS5 cannot ALTER-add columns, so legacy ocr_fts is rebuilt with metadata
`ActivityStore.migrateOCRTable`: FTS5 tables cannot ALTER-add columns, so a legacy `ocr_fts`
(text, ts, app) is rebuilt into the new shape with `window_title`
indexed (searchable) plus `text_source` / `snapshot_id` metadata.
`text_source` distinguishes Accessibility, OCR, and hybrid captures.

#### Idempotent launch repair of snapshot_id=0 rows by capture time via ocr_metadata index
`ActivityStore.backfillUnlinkedOCRRows`: An earlier migration version could create the six-column FTS table but
leave `snapshot_id = 0`. Repair those rows idempotently by capture time;
FTS row IDs are not screenshot IDs because empty OCR was never inserted.
Runs at every launch. Once `ocr_metadata` mirrors the FTS identities
(every insert writes both), its index finds unlinked rows without
reading every capture's text, which the FTS table stores first.

#### Range predicate lets SQLite use an index instead of scanning screenshots
`ActivityStore.backfillUnlinkedOCRRows`: The range lets SQLite search an index. `ABS` alone made every
row that never links scan all of `screenshots` at each launch.

#### Day loader reads share one deferred WAL snapshot so writers stay unblocked
`ActivityStore.withReadSnapshot`: A day loader's metadata, text, and watermark share one WAL read snapshot.
This is a deferred read transaction, so capture writers remain unblocked.

#### Set only on deferred-snippet hits until fillOCRSnippets replaces the empty snippet
`OCRHit.pendingSnippet`: Set only on hits from `searchOCR(deferringSnippets: true)` until
`fillOCRSnippets` replaces the empty `snippet`.

#### Returns screenshot rowid so the OCR row links back to its pixels
`ActivityStore.insertScreenshot`: Insert one paired capture row (pixels bookkeeping + searchable text).
Returns the screenshot rowid so the OCR row links back to its pixels.

#### Nil interval means all retained captures; app match is exact case-insensitive
`ActivityStore.screenshots(in:app:)`: Captures available for rewind/citation, oldest first. A nil interval
means all retained captures. App matching is exact but case-insensitive,
which maps cleanly to the app chips built from stored application names.

#### Destructive previews must distinguish a failed read from an empty scope
`ActivityStore.screenshotsChecked`: Destructive previews must distinguish a failed read from an empty scope.

#### Includes meeting-stamped captures plus unstamped ones from older builds, and text-only captures
`ActivityStore.screenshots(forMeeting:)`: Captures stamped with this meeting while it recorded, plus unstamped
captures inside its span from builds that predate meeting stamping.
Text-only captures are included; they carry titles, documents, and URLs.

#### Exact row lookup backs [screen:ID] citations and pinned context
`ActivityStore.screenshot(id:)`: Exact row lookup used by `[screen:ID]` citations and pinned context.

#### Batch lookup of 400 ids per query; deleted captures have no entry
`ActivityStore.screenshots(ids:)`: `screenshot(id:)` for many captures, one query per 400 ids. A capture
that is gone (retention, a delete) has no entry.

#### matchAll false relaxes to OR'd keywords; deferred snippets mark only shown hits
`ActivityStore.searchOCR`: FTS search over screen text (and window titles). `matchAll: false`
relaxes a natural-language query to OR'd content keywords — same
rescue the meeting search uses.
`deferringSnippets` returns hits with empty snippets for
`fillOCRSnippets`, so a caller showing only some hits marks only those.

#### FTS5 cannot see words inside CJK runs, so CJK queries use substring search
`ActivityStore.searchOCR`: FTS5 cannot see words inside a run of CJK text; see `CJKSearch`.

#### Latin word glued to CJK text is part of that run's token, needing substring fallback
`ActivityStore.searchOCR`: A Latin word glued to CJK text ("比如logo再大") is part of that run's token.

#### Snippets are built lazily because tokenizing row text cost more than ranking
`ActivityStore.fillOCRSnippets`: Fills the snippets `searchOCR(deferringSnippets: true)` left empty, in
one query per marking. Building a snippet tokenizes the row's whole
text, which cost more than ranking when every match got one.

#### Substring search ranks by terms matched; snippets built from stored text without MATCH
`ActivityStore.substringSearchOCR`: Substring counterpart of the FTS search, for text the tokenizer cannot
split. The rank is how many terms matched (most first, then newest), and
snippets are built from the stored text because `snippet()` marks
nothing without MATCH.

#### Results grouped into scenes; snippets built only for returned rows
`ActivityStore.runOCRSearch`: The screen search query, grouped into scenes unless `groupResults` is
false. `matchCondition` and `bindings` select the rows, and
`rankExpression` orders them (lower first) ahead of recency. Snippets
are built afterwards for the rows returned only.

#### Full OCR keeps line breaks and never falls to nearby timestamp, so citations resolve exactly
`ActivityStore.ocrText(snapshotID:)`: Full captured OCR for a stable citation/pinned Ask attachment. Unlike
FTS snippets this preserves line breaks and never falls through to a
nearby timestamp, so `[screen:ID]` always resolves exact source text.

#### Saving again updates the note but keeps original createdAt for stable exports
`ActivityStore.saveMoment`: Idempotently saves a capture. Saving it again updates the note without
changing its original `createdAt`, keeping daily exports stable.

#### Saved moments read once per retention pass instead of per candidate
`ActivityStore.bookmarkedSnapshotIDs`: Every saved moment, read once for a retention pass instead of one
query per candidate.

#### Returns one saved moment's note, nil when the capture is not saved
`ActivityStore.savedMomentNote`: One saved moment's note, or nil when the capture is not saved.
`savedMoments` returns only the newest ones.

#### Pixels are removed first so a failed file delete stays retryable from the row
`ActivityStore.deleteScreenshot`: Removes one capture and every derived/search row in one transaction.
The owning `ScreenshotService` removes encrypted pixels first so a
failed filesystem delete remains retryable from this database row.

#### FTS metadata is unindexed; batch in one transaction avoids rescans and partial state
`ActivityStore.deleteScreenshots`: Batch counterpart for Timeline range deletion. FTS metadata columns are
unindexed, so deleting chunks in one transaction avoids rescanning the
entire OCR table once per selected frame and prevents partial DB state.

#### No whole-day ceiling so chunks cover the full day; per-capture cap bounds pathological trees
`ActivityStore.screenContexts`: Every retained screen-text record for one local day, oldest first.
This has no whole-day character ceiling: callers can chunk the complete
evidence without a busy morning crowding out the afternoon. Individual
captures stay bounded to keep one pathological Accessibility tree from
dominating a chunk.

#### Interval OCR used for meeting-local participant hints, not the whole day
`ActivityStore.ocrText(from:to:)`: OCR text for a precise interval. Used for meeting-local participant
hints, where the current day's whole screen history would be too broad.

#### measuringBytes stats files for the review sheet; deletion passes skip it
`ActivityStore.retentionReview`: `measuringBytes` stats every candidate file for the review sheet's
"space recovered"; deletion passes skip it.

#### App names and durations persist; window titles are content and expire
`ActivityStore.retentionReview`: App names and durations remain useful aggregate history. Window
titles are content and expire even with the screen-text exception.

#### Agent requests and reports are text and follow the text retention rule
`ActivityStore.retentionReview`: Agent requests and reports are text: they follow the text rule.

#### FTS5 cannot index snapshot_id; resolve rowids via metadata index and delete in chunks
`ActivityStore.deleteScreenshots`: FTS5 cannot index its UNINDEXED snapshot_id column. Resolve the
exact FTS rowids through the ordinary metadata index and delete
bounded chunks instead of rescanning the full FTS table once per
screenshot. Keep every write bookmark-aware at execution time.

#### Legacy orphan OCR keeps exact row identities so revocation never authorizes a broad cutoff
`ActivityStore.OrphanedScreenEvidence`: Legacy OCR can have snapshot_id = 0, or point at a screenshot row that
no longer exists. Its own timestamp still establishes the evidence day.
Keep exact row identities so revocation never authorizes a broad cutoff.

#### Recheck orphan status before deleting since backfill can relink rows
`ActivityStore.deleteOrphanedScreenEvidence`: Backfill, new screenshots and new bookmarks can make a
reviewed orphan live again. Recheck before deleting it.

#### Clear path only after file removal; delete picture vector first so it never outlives pixels
`ActivityStore.clearScreenshotPath`: Clear only the row whose file was successfully removed. This avoids
losing the sole reference to an encrypted file when filesystem cleanup
fails (permissions, transient volume error, and so on).
Retention calls this once per expired capture on the main actor; the
partial path index keeps each call from scanning every capture row.
The capture's picture vector goes first: it was made from these pixels
and must not outlive them (`ScreenImageEmbeddings`). If the update then
fails, the pixels stay and are embedded again later.

#### Latest in-day evidence time tells whether a saved digest predates later evidence
`ActivityStore.latestEvidenceAt`: Latest activity or screen-text timestamp inside one local day. Used to
tell whether a saved digest predates evidence that arrived afterwards.

#### Bursts never cross midnight, so their start names their day
`ActivityStore.codingAgentBursts`: Settled coding-agent bursts that began inside `interval`, oldest
first. A burst never crosses midnight, so its start names its day.

#### Read-only connections can predate the coding_agent_bursts table
`ActivityStore.codingAgentBursts`: Read-only connections can predate the table's creation.

#### Only writes and throws, so failure never looks like an empty source
`ActivityStore.upsertCodingAgentBursts`: Insert or replace bursts by id. Callers compute what changed; this
only writes, so a failure never looks like an empty source.

#### Burst start times identify the days a full clear revokes
`ActivityStore.codingAgentBurstStarts`: Start times of every stored burst, for the days a full clear revokes.

#### One resolver at a time, same-PID callers share, other PIDs fail closed
`FocusedWindowTitleLookup`: Keeps cross-process Accessibility title reads off the main actor and bounds
both queue growth and caller latency. One resolver may be active at a time;
same-PID callers share it, while a different PID fails closed instead of
accumulating behind a wedged target process.

#### Never read own window off-main; SwiftUI would run off the main actor
`FocusedWindowTitleLookup.title`: Reading LokalBot's own window from this worker would run SwiftUI off
the main actor; see ScreenAccessibilityReader.isOwnProcess.

#### 5 s poll; blocks close on app/title change, 3 min idle, pause, or quit
`ActivitySampler`: The sampler: 5 s poll (cheap), block boundaries on app/title change,
idle > 3 min, pause, or app quit. No screenshots here — that's M5.

#### Used when no site is excluded so a sample needs no page address
`ActivitySampler.windowReader`: Used instead when no site is excluded, so a sample needs no page address.

#### Injected by AppState; matching apps are logged as Private
`ActivitySampler.excludedApps`: Injected by AppState; apps matching these are logged as "Private".

#### Event-driven capture fires at block boundaries; excluded apps arrive as Private
`ActivitySampler.onActivityBoundary`: Event-driven capture hook: fired when the sampled (app, title) pair
changes — i.e. at the same boundaries that close activity blocks.
`appChanged` distinguishes an app switch from a window/tab change
inside the same app. Excluded apps arrive as ("Private", "").

#### Window titles need Accessibility; unknown privacy state is anonymized
`ActivitySampler.hasAccessibility`: Window titles need Accessibility; unknown privacy state is anonymized.

#### Idle counts any input event type, session-wide
`ActivitySampler.sample`: Idle: any input event type, session-wide.

#### Exclusions and unknown AX state keep duration but drop title and URL
`ActivitySampler.recordSample`: Shared ingestion path for live samples and synthetic regression tests.
Exclusions and unknown AX state preserve duration without title or URL.

### `LokalBot/Services/Timeline/DailyDigestEvidence.swift`

#### Summary-only snapshots must load detailed activity before serving as freshness proof
`DailyEvidenceSnapshot.digestEvidence`: Shared by generation and validation. Summary-only snapshot callers must
load detailed activity before using this projection as a freshness proof.

#### Signature covers digest-consumed content, excluding file timestamps and unread fields
`DayDigestEvidence.contentSignature`: Content consumed by the digest, excluding filesystem timestamps and
optional daily-summary fields that the digest does not read.

#### Agent fields appended only when present so old journals still match
`DayDigestEvidence.contentSignature`: Appended only when present: journals of days without agent work
keep matching the signature they were generated with.

### `LokalBot/Services/Timeline/DailyEvidenceSnapshot.swift`

#### Extracted outcomes stay immutable; projection applies user corrections and workflow state
`DailyEvidenceMeeting`: One meeting as seen by every day-level consumer. Extracted outcomes stay
immutable; `projection` applies the user's corrections and workflow state.

#### Compatibility value projecting only actions; decisions and questions have no overlay
`DailyEvidenceMeeting.activeOutcomes`: Compatibility value for consumers that still render `MeetingOutcomes`.
Only the action array is projected because decisions and open questions
have no mutable overlay.

#### Generated prose excluded so derived artifacts never become circular evidence inputs
`DailyEvidenceSnapshot`: Immutable primary evidence for one local calendar day. Generated prose
such as the Day Digest and Dream is deliberately excluded so those derived
artifacts cannot become circular inputs to their own evidence snapshot.

#### Append sources one at a time; chained sum exceeds type-checker time limit
`DailyEvidenceSnapshot.latestEvidenceAt`: Appended one source at a time: a single chained sum of six arrays
exceeds the type checker's time limit on slower build machines.

#### Signature includes saved corrections whose meaning can change without extraction changes
`DailyEvidenceSnapshot.signature`: A deterministic content signature for cache and derived-artifact
invalidation. It includes saved corrections, whose meaning can change
even when the original extraction and meeting metadata do not.

#### Agent fields appended only when present so cached artifacts keep their signatures
`DailyEvidenceSnapshot.signature`: Appended only when present, so days without agent work keep the
signatures their cached artifacts were saved with.

#### Canonical read-only loader; in-memory snapshot overload shares implementation with background workers
`FileDailyEvidenceSource`: The canonical read-only loader for daily evidence. Callers that already
hold the app's in-memory meeting/activity snapshot can pass it through the
overload below; background workers use the same implementation with data
read from the library and SQLite store.

#### Sample meeting is made up and never becomes part of the day
`FileDailyEvidenceSource.snapshot`: The sample meeting is made up: it never becomes part of the day.

#### Agent bursts load under the activity-block rule so all consumers see same evidence
`FileDailyEvidenceSource.snapshot`: Loaded under the same rule as activity blocks, so every consumer
that proves a digest current sees the same agent evidence.

#### Stale digests are omitted rather than disagreeing with newer evidence
`DailyEvidenceArtifacts`: Derived daily artifacts are read only after their primary evidence
snapshot exists. A stale digest is omitted rather than allowed to disagree
with newer corrections, meeting artifacts, or screen evidence.

#### False once evidence changed after the digest was written
`DailyEvidenceArtifacts.GeneratedDigest.isCurrent`: False once the day's evidence changed after the digest was
written: new activity, or a source deleted or corrected.

#### Callers show only current digest but can report an out-of-date one exists
`DailyEvidenceArtifacts.generatedDigest`: The day's unedited generated digest and whether it still matches the
day's evidence. Callers show only a current one, but can say that an
out-of-date one exists.

### `LokalBot/Services/Timeline/DailyMemoryExportScheduler.swift`

#### Minute tick; today's note at export hour, past days catch up if note missing
`DailyMemoryExportScheduler`: Lightweight wall-clock scheduler for the optional daily Markdown export.
The app normally lives in the menu bar, so a minute tick is sufficient and
remains correct across sleep/wake and daylight-saving changes.

Today's note is written at the export hour and refreshed when its evidence
changes. A Mac asleep or off at that hour never wrote that day's note, so
past days within the digest's catch-up window get a note if the folder has
none, and a past day's note is rewritten once its digest is finalized.

#### Folder or format change re-exports even if today already succeeded
`DailyMemoryExportScheduler.Configuration.destinationID`: Folder + format identity. Changing either should export to the new
destination even when today's prior destination already succeeded.

#### Corrections reopen only the current day's export; historical exports stay user-controlled
`DailyMemoryExportScheduler.reconsider`: An action correction or late meeting artifact can change today's
export after its scheduled run. Reopen only the affected current day;
historical exports remain user-controlled and collision-safe.

#### Finished digest refreshes today's note and rewrites past notes within catch-up window
`DailyMemoryExportScheduler.digestDidChange`: A digest finished or rebuilt after its note was written. Today's note
refreshes as for any evidence change; a past day's note within the
catch-up window is rewritten with the finished digest.

#### Cancel in-flight export so it cannot mark a day done with changed evidence
`DailyMemoryExportScheduler.restart`: Cancels an in-flight export so it cannot record a day as done with
evidence that has since changed; policy then picks the next export.

#### Failed writes retry after 15 minutes so removable volumes can return
`DailyMemoryExportScheduler.tick`: A failed filesystem write should be visible but not retried every
minute. Fifteen minutes gives removable/network volumes time to return.

#### Structured utility child so cancellation reaches the filesystem worker
`DailyMemoryExportScheduler.tick`: The scheduler owns a structured utility-priority child. A
configure/stop cancellation therefore reaches the actual
filesystem worker instead of only cancelling an outer task
that is awaiting an unstructured detached task.

#### Retry wait applies to failures only; next export runs immediately after success
`DailyMemoryExportScheduler.tick`: The retry wait is for failures; the next export runs now.

#### Past day tried once per session so unwritable notes never block today's
`DailyMemoryExportScheduler.tick`: A past day is tried once per session, so a note that
cannot be written never holds back today's.

#### Order: reopened past days, unchecked past days oldest first, then today at its hour
`DailyMemoryExportScheduler.nextExport`: Reopened past days first, then past days not yet checked for a
missing note (oldest first), then today once its hour arrives.

### `LokalBot/Services/Timeline/DailyMemoryExportService.swift`

#### Catch-up writes a missed day only if no file exists and data was recorded
`DailyMemoryExportPass.catchUp`: A past day the export missed, because the Mac was asleep or off at
the export hour. Written only if the folder has no file for that day
and something was recorded.

#### Out-of-date digest is left out of the note until updated
`DailyMemoryExportSnapshot.digestIsOutOfDate`: A digest exists but no longer matches the day's evidence, so it is
left out until the digest is updated.

#### Injection seam keeps rendering and atomic file behavior testable without live library
`DailyMemoryExportSource`: Injection seam keeps rendering and atomic file behavior testable without a
live meeting library or SQLite database.

#### Screen data optional without a database; unreadable existing database fails loudly
`FileDailyMemoryExportSource`: Default source for the scheduler: existing journal Markdown plus read-only
meeting and screen-memory queries. Screen data is optional when day tracking
has never created a database; an existing-but-unreadable database still
fails loudly instead of silently publishing incomplete data.

#### Hidden sidecar hash prevents overwriting user edits; identical content keeps mtime; atomic replace
`DailyMemoryExportService.export`: Rewrites one deterministic day file. A hidden sidecar records the hash
of the exact bytes last emitted by LokalBot. Refresh is allowed only if
the current file still matches that hash, so a user edit made after
generation is never overwritten. Identical content keeps its mtime;
changed app-owned content uses same-directory atomic replacement.

### `LokalBot/Services/Timeline/DayDigestEvidence.swift`

#### Privacy-scrubbed local text only; pixels never enter this value
`DayScreenContext`: One retained, privacy-scrubbed screen-context record used by the day digest.
Pixels never enter this value; `text` is the same local Accessibility/OCR
text already stored in the screen-memory index.

#### Meeting evidence is pre-structured so the day pipeline need not parse artifacts
`DayDigestMeetingEvidence`: Meeting evidence folded into the workday summary without making the day
pipeline parse meeting artifacts itself.

#### Latest summary/outcomes write counts as evidence even if end time unchanged
`DayDigestMeetingEvidence.artifactModifiedAt`: Latest write among the summary/outcomes files consumed for this meeting.
It is evidence even when the meeting's own end time is unchanged.

#### Archive-only outcome-state corrections are not consumed by the digest
`DayDigestMeetingArtifacts.latestModifiedAt`: Archive-only corrections are not consumed by the current digest.

#### Cache segment answers in memory, bounded, purged with journal when evidence changes
`DayDigestSegmentCache`: Answers to day-digest prompts already asked today, keyed by the exact
prompt. A digest is regenerated whenever a meeting finishes or evidence
settles; without this every run re-asked the model about every segment,
including morning segments whose evidence had not changed (16 full runs on
2026-10-01). In memory only, bounded, and purged with a day's journal when
evidence is deleted or corrected, so no derived text outlives its source.

#### Character pressure may split sessions; idle gap always starts a new slice
`DayDigestSummarySegment`: One deterministic slice of the day that receives a substantive-work
eligibility pass. Character pressure may split a long active session, while
a real idle gap always starts a new slice. Metadata-only slices stay in the
lossless journal without becoming visible summary items.

#### Model sees bounded chunks; journal log rendered directly so nothing is omitted
`DayDigestEvidence`: Complete, ordered evidence for one local calendar day. The model consumes
bounded chunks of this value, while the journal's chronological log is
rendered directly so model brevity or failure can never omit activity.

#### Agent work is pre-structured and rendered in its own lossless section
`DayDigestEvidence.codingAgentBursts`: Settled coding-agent work. Like meetings, it arrives pre-structured
and is rendered in its own lossless journal section.

#### Each summary-worthy item in one segment; long blocks sampled proportionally; idle gap hard boundary
`DayDigestEvidence.summarySegments`: Full-day evidence for LLM summarization. Every summary-worthy activity
and meeting appears in exactly one segment, and each long block contributes
evenly spaced context in proportion to its duration rather than letting
the morning exhaust a global cap. An idle gap creates a hard boundary,
so short morning work cannot be obscured by an afternoon session.

#### Merge shortest adjacent sessions beyond the limit to keep every event
`DayDigestEvidence.summarySegments`: More isolated sessions than the day's limit are rare, but merging the
shortest adjacent pair preserves every event without letting a few
brief interruptions consume most of the bounded UI.

#### One segment per target duration of active time, not a fixed eight-segment plan
`DayDigestEvidence.summarySegments`: Each segment shows a bounded sample of its events, so a session gets
one segment per `targetSegmentDuration` of active time (never more
than it has events). A fixed eight-segment plan gave a six-hour,
809-event block the same sample budget as a one-event session.
Short days no longer split into extra calls just to reach a quota.

#### Agent section only on days with agent work so old journals keep their shape
`DayDigestEvidence.renderDocument`: Only days with agent work gain the section, so journals written
without the feature keep their existing shape.

#### Context breadth scales with active duration within a fixed character budget
`DayDigestEvidence.summaryContexts`: A long uninterrupted app/window block used to expose only three screen
samples—the same evidence depth as a five-minute task. Increase breadth
with active duration while keeping excerpts inside a fixed character
budget, so hours of work are represented across their full span.

#### recordedOutcome means committed, PR opened or merged, released, pushed, or ran tests
`DayDigestEvidence.SummaryEvent.Source.agentSession`: `recordedOutcome`: the burst committed, opened or merged a PR,
released, pushed, or ran tests.

#### Tie-break ordering for events that begin together
`DayDigestEvidence.SummaryEvent.order`: Tie-break for events that begin together.

#### Screen text in agent host apps during a session duplicates exact session evidence
`DayDigestEvidence.codingAgentHostApps`: Apps that host coding agents: their chat window, a terminal, or an
editor. Screen text captured there while a stored session ran is
mostly that session on screen, which the session evidence already
states more exactly.

#### Union intervals so overlapping evidence is not double-counted for narrative space
`DayDigestEvidence.coveredDuration`: Union the recorded intervals so overlapping meeting and app evidence is
not double-counted when deciding how much narrative space a segment gets.

#### Outcomes lead meeting text because front-truncation dropped actions and decisions
`DayDigestEvidence.summaryEvents`: Outcomes lead. A busy segment cuts each source to a few hundred
characters from the front, which kept the summary's generated
title and provenance line and dropped every action and decision.

#### Summary body drops generated title and provenance line already in meeting context
`DayDigestEvidence.summaryBody`: Login transitions are useful in the lossless activity log, but they are
not work topics and should not consume scarce overview space.
The summary without its generated title and provenance line; the
meeting event already carries both as task context and trace metadata.

#### Show a session once per segment with all bursts so parallel sessions share budget
`DayDigestEvidence.mergingAgentSessions`: A session often has several bursts in one segment. Show it once, with
every burst's requests, actions, and files, so parallel sessions do
not crowd each other out of the detail budget.

#### Reserve meetings and outcome-recording agent sessions before evenly filling detail budget
`DayDigestEvidence.summaryDetailIndices`: Meetings are already structured work evidence, so a busy interval must
not sample around them merely because it contains many short activity
events. Agent sessions that recorded an outcome get the same guarantee,
up to `reservedAgentSessions`, ahead of those that did not. Fill the
remaining detail budget evenly across the interval.

#### Section lists recorded facts only; agent reports are unverified claims
`DayDigestEvidence.agentSessionsSection`: Recorded facts only, one entry per session. The agent's own report is
a claim for the model to corroborate, so it stays out of this section.

#### Strip recurring Accessibility chrome only from model excerpt; journal keeps verbatim evidence
`DayDigestEvidence.summaryExcerpt`: Remove recurring Accessibility chrome only from the model-facing
excerpt. The deterministic journal below retains the original scrubbed
evidence verbatim, including source IDs, for inspection and export.

#### Conservative lexical overlap catches copied facts without flagging same-project mentions
`DayDigestTextSimilarity`: Conservative lexical overlap detection for short, structured digest text.
It catches copied or lightly rephrased facts without treating every mention
of the same project as redundant.

#### Coverage is active seconds of usable segments over all segments
`DayDigestCoverage`: How much of the day's tracked activity reached the digest: active seconds
of evidence segments whose extraction produced a usable block, over the
active seconds of all segments. Lost segments (truncation, provider stop,
unusable output) lower it.

#### Segment extraction is most of the work; aggregation is the final step
`DayDigestProgress`: How far a digest run has come, for progress surfaces. Segment extraction
is most of the work; aggregation is the final step.

#### Two model passes; code keeps every accepted candidate if aggregation fails
`DayDigestOverviewGenerator`: Converts deterministic, gap-aware evidence segments into the compact
human layer shown above the lossless journal. A first model pass rejects
metadata-only segments and extracts structured work candidates. A second
pass groups those candidates by task; code retains every accepted candidate
even if that aggregation pass fails or omits one.

#### Limits sized so titles wrap and summaries end on complete sentences
`DayDigestOverviewGenerator.FieldLimit`: Display limits for journal task copy. Sized so titles wrap and
summaries stay complete sentences instead of ending on an ellipsis.

#### Optional so answers saved before the field existed still decode
`DayDigestOverviewGenerator.FocusDraft.otherTasks`: Other distinct work in the same segment. Answers saved before it
existed decode with none.

#### Prompt depends only on segment evidence, so unchanged segments reuse cached answers
`DayDigestOverviewGenerator.generateResult`: The prompt depends only on the segment's own evidence, so an
unchanged segment can reuse its earlier answer.

#### Never cache a cancelled run's answer; evidence changed or was deleted
`DayDigestOverviewGenerator.generateResult`: A cancelled run is answering for evidence that just changed or
was deleted; never keep its answer.

#### Outcome-recording sessions added after aggregation because small models blend them
`DayDigestOverviewGenerator.generateResult`: Segment extraction keeps at most three items per segment, and a
small model rarely fills them all, so parallel sessions could still
vanish. Those that recorded an outcome are stated from their actions
and added after aggregation: a small model asked to merge them
blends unrelated sessions.

#### Substantive work leads; lighter identifiable work follows rather than disappearing
`DayDigestOverviewGenerator.generateResult`: Substantive work leads; lighter but identifiable work follows it
instead of disappearing whenever one segment clears the bar.

#### Token headroom for reasoning models that spend budget thinking
`DayDigestOverviewGenerator.focusTokens`: Routed reasoning models can spend most of a small budget thinking even
when asked not to. The compact focus JSON needs far less than this; the
headroom only matters for those models, and llama-server keeps its own
thinking budget independent of the larger cap.

#### About 150 tokens per candidate beyond eight; fixed 1,600 truncated 16-segment day
`DayDigestOverviewGenerator.aggregationTokens(candidates:)`: The first aggregation pass gets room for each candidate beyond eight
(about 150 tokens per task), now that a long day can produce up to 16.
A fixed 1,600 tokens was truncated on the first 16-segment day.

#### Replay one remote 429/5xx once; managed local engines already replay
`DayDigestOverviewGenerator.generateReplayingTransientFailure`: Remote providers intermittently answer 429/5xx or drop the connection.
Replay that one request after the shared policy delay instead of
losing the rest of the day. Managed local engines already relaunch and
replay inside `LeasedTextEngine`, so they are never retried twice.

#### Candidates only from recorded facts; scheduled runs left to segment extraction
`DayDigestOverviewGenerator.agentSessionCandidates`: One candidate per agent session that recorded an outcome, from
recorded facts only. Scheduled runs are left to segment extraction:
their reports often describe other days.

#### Tasks are named by the work, not first request or start folder
`DayDigestOverviewGenerator.sessionCandidates`: Tasks are named by the work, not by the first request or the folder
the session started in.

#### Fallback names what was present without inventing accomplishments
`DayDigestOverviewGenerator.bestAvailableFallbackBlocks`: Last-resort output for engine failures or evidence that every model
pass rejected. Prefer meeting content, then the most sustained named
activity contexts. This path stays deliberately conservative: it names
what was present without inventing an accomplishment or outcome.

#### Agent sessions name work and actions without claiming an outcome
`DayDigestOverviewGenerator.bestAvailableFallbackBlocks`: Agent sessions name their work and record their actions, which
says more than a window title without claiming an outcome.

#### At most two other tasks per schema; repeats do not use a slot
`DayDigestOverviewGenerator.parseFocus`: At most two others, as the schema asks; a repeat of a task already
kept does not use a slot.

#### Session merges into a task matching by title, PR, or all name words
`DayDigestOverviewGenerator.mergeSessionCandidate`: A session already described by a task adds its recorded facts to that
task; otherwise it becomes its own task after the model's. A task
describes the session when its title says the same, names one of the
session's pull requests, or holds every word of the session's name.

#### Recorded merge or release settles status; weaker evidence never overrides model
`DayDigestOverviewGenerator.mergeSessionCandidate`: A recorded merge or release settles the status; nothing weaker
overrides what the model concluded.

#### Bare numbers could belong to another repository, so require repo context
`DayDigestOverviewGenerator.namesPullRequest`: The title names one of the session's pull requests: `owner/repo#12`,
or `#12` or `PR 12` beside the repository's name. A number alone could
belong to another repository's pull request.

#### Same-work match needs all name words, same project, and no differing pull requests
`DayDigestOverviewGenerator.describesSameWork`: Every word of the session's name is in the task's title, the task is
about the session's project, and the two name no different pull
requests: "Review all open PRs" in LokalBot is "LokalBot open PR
review and fixes", while "Review PR" is not "LokalBot PR #290 review".

#### Singular lowercase words with pull request as pr so phrasings share words
`DayDigestOverviewGenerator.workWords`: Lowercased content words in singular form, with "pull request" as "pr",
so "Review the pull requests" and "open PR review" share their words.

#### Merged sessions add only unmentioned PRs; number match must not be a prefix
`DayDigestOverviewGenerator.unmentionedOutcome`: The part of a session's outcome a task does not state yet. Several
sessions can merge into one task, so each adds only pull requests it
has not already named; `#10` is not mentioned by `#105`.

#### Avoid per-call DateFormatter; thousands of stamps made formatter creation the cost
`Calendar.clockStamp`: "HH:mm" in this calendar's time zone, as a POSIX-locale `DateFormatter`
writes it. A digest asks for thousands of these, and building a
formatter for each was most of the cost.

#### Durable repair budget stops a crashing model being relaunched forever
`DayDigestGenerationMetadataStore.record`: Records whether this journal still needs a model-backed repair. Repeated
degraded writes for unchanged evidence increment a durable budget so a
persistently crashing model cannot be relaunched forever.

#### Legacy journals use mtime; matching degraded sidecar counts as unfinished while repair eligible
`DayDigestGenerationMetadataStore.completedAt`: Legacy or externally edited journals keep their modification-time
semantics. A matching degraded sidecar returns nil while a bounded quiet
repair is still eligible, making the scheduler treat it as unfinished.

### `LokalBot/Services/Timeline/DayDigestJournalWriter.swift`

#### Capture revision before model, verify before commit; user edit or newer generation wins
`DayDigestJournalWriter`: Capture the journal revision before awaiting a model, then verify it again
immediately before committing. A user edit or a newer generation wins.

#### Two-file commit is not atomic; intent record lets readers recover ownership after crash
`DayDigestJournalWriter.PendingWrite`: A two-file journal commit cannot be made atomic by the filesystem. Keep
enough intent beside it to finish the ownership sidecar after a crash.
Readers recognize the intended digest while this record exists, so a
generated journal never becomes user-owned merely because the sidecar
write was interrupted.

#### Return recoverable ownership even if sidecar repair fails; later read retries
`DayDigestJournalWriter.recoverPendingMetadata`: Return recoverable ownership even when persisting the repaired sidecar
still fails. Callers can therefore retract generated text without ever
mistaking it for a user edit, and a later read retries the repair.

#### Ambiguous interrupted identical rewrite resolves toward user's prior ownership
`DayDigestJournalWriter.recoverPendingMetadata`: An interrupted rewrite of byte-identical user content is
indistinguishable from a commit that never reached the journal.
Resolve that ambiguity in favor of the user's prior ownership.

#### Transaction stays as durable ownership record when cleanup fails; later read retries
`DayDigestJournalWriter.recoverPendingMetadata`: The transaction remains the durable ownership record. A later
read retries once the filesystem failure is gone.

### `LokalBot/Services/Timeline/DayDigestLifecycle.swift`

#### Lifecycle owns evidence scope, journal location, freshness derivation, and repair scheduling
`DayDigestLifecycle`: Owns the complete Day Digest lifecycle shared by manual, scheduled, and
headless entry points. Callers choose when to request a digest; this module
owns what evidence belongs to that request, where the journal lives, how
freshness is derived, and how automatic repair is scheduled.

#### Bring slow sources like agent transcripts current before reading evidence
`DayDigestLifecycle.prepareEvidence`: Brings slower sources, such as coding-agent transcripts, up to date
before a day's evidence is read for generation.

#### Runs ordered by start; manual and scheduled runs may overlap
`DayDigestLifecycle.activeRuns`: Runs in start order; manual and scheduled runs may overlap.

#### True across entry points so a second request cannot race the journal write
`DayDigestLifecycle.isGenerating`: True while any entry point is generating the digest for `day`, so a
second request cannot race the first one's journal write.

#### App settles evidence for 20 s before a fresh automatic run
`DayDigestLifecycle.init`: The app settles evidence for 20 s before a fresh automatic run.

#### Unchanged generated digests are removed with evidence; edited journals are user-owned
`DayDigestLifecycle.retractGeneratedJournals`: An unchanged generated digest is a derived copy of its evidence. Remove
it before withdrawing that evidence; edited and unsigned journals are
user-owned documents with an explicitly independent lifetime.

#### Past retention window a mismatch is expiry, not new activity, so no rewrite
`DayDigestLifecycle.evidenceHasExpired`: Scheduled retention thins a day's sources after its digest was written,
and the digest outlives them (PRIVACY.md). Past the window a fingerprint
mismatch is expiry, not new activity, so it must not invite a rewrite
from what is left.

#### Capture meetings on owner; validate files and fingerprints on the day-read worker
`DayDigestLifecycle.backgroundSnapshotLoader`: Capture the meeting list on its owner, then validate files and complete
evidence fingerprints on the worker that owns the day read connection.

#### Deleted last meeting still leaves an owned journal to repair
`DayDigestLifecycle.configureAutomaticGeneration`: A deleted last meeting still leaves an owned journal to repair.

#### User corrections can stale a journal without metadata change; re-evaluate immediately
`DayDigestLifecycle.reconsiderEvidence`: A user correction or completion can make the current journal stale
without changing meeting metadata. Re-evaluate immediately instead of
waiting for the next minute tick.

#### Revalidate original sources at commit; later arrivals stale but not invalidate; synchronous on main actor
`DayDigestLifecycle.evidenceValidator`: Revalidate the original sources at the final commit boundary. New
activity, captures, and meetings may arrive while generation is running;
they make the saved snapshot stale, but do not invalidate its sources.
The validator is synchronous and main-actor isolated, so evidence cannot
change between this check and the journal write that immediately follows.

#### Stored bursts are settled; new id is new work, original set must be unchanged
`DayDigestLifecycle.evidenceValidator`: Stored bursts are settled, so a new id is new work; only the
original set must be unchanged.

#### Filter before projection since new blocks or captures alter absorption and dedup
`DayDigestLifecycle.evidenceValidator`: Filter before building the digest projection: a newly closed
block can otherwise absorb an originally standalone context,
and a new capture can alter context deduplication.

#### Summary, outcome and overlay writes advance the evidence watermark
`DayDigestLifecycle.latestArtifactWriteAt`: Summaries, outcomes, and the user's outcome overlay are consumed by
`ProcessingPipeline.generateDayDigest`. Their writes must therefore
advance the evidence watermark even when `endedAt` is unchanged.

#### Keep once-per-evening policy but invalidate marker when consumed meeting artifacts are newer
`DayDigestLifecycle.automaticCompletionAt`: Preserve the scheduler's once-per-evening policy for ordinary activity,
but invalidate its completion marker when a digest predates meeting
artifacts it actually consumes. This makes the next quiet tick repair
the journal without regenerating it for every later activity sample.

#### Manual edits are preserved even if file timestamp is restored
`DayDigestLifecycle.automaticCompletionAt`: Preserve manual edits even if the file's timestamp is restored.

#### Check ownership before quality so editing a degraded digest opts out of replacement
`DayDigestLifecycle.automaticCompletionAt`: Ownership is checked before quality: editing even a degraded digest
must opt it out of automatic replacement.

### `LokalBot/Services/Timeline/DayDigestScheduler.swift`

#### Minute tick; journal mtime is durable marker; past days finalized once; empty days retry
`DayDigestScheduler`: Wall-clock scheduler for the automatic day digest. Same minute-tick design
as `DailyMemoryExportScheduler` (correct across sleep/wake and DST), with
two digest-specific twists:

- the durable marker is the journal file's modification time:
  written at/after today's scheduled hour means done (survives relaunch,
  and a manual regenerate after the hour counts too), while a digest the
  user generated in the morning is refreshed at the scheduled hour with
  the fuller day;
- past days are finalized once after the local date changes, oldest first
  and at most `catchUpDays` back. Rewriting a journal after its day ended
  makes the mtime a durable finalization marker, so late work after the
  evening preview is included without an extra database flag;
- a day with nothing to digest yet is not a failure — the generate closure
  reports it and the scheduler simply retries on a later tick, so a
  meeting that ends at 19:00 still gets digested the same evening.

#### Local hour 0-23 after which today's digest is generated
`DayDigestScheduler.Configuration.hour`: Local wall-clock hour (0...23) after which today's digest is
generated.

#### Degraded journal stays readable and gets quiet repair under failure backoff
`DayDigestScheduler.Generate`: Generates and persists the digest for the day containing `date`. A
degraded journal remains readable but receives a quiet later repair
under the same backoff as a failed generation.

#### Skip proven-final days without rereading evidence; yesterday always re-evaluated
`DayDigestScheduler.scanCursorDay`: Oldest day before yesterday not yet proven final, for the current
`scanToday`. Days before it are skipped without re-reading evidence;
yesterday is always re-evaluated because its evidence may still settle.

#### Deferred past days skipped until evidence changes so empty day cannot block others
`DayDigestScheduler.deferredDays`: Past days whose generation deferred (no usable evidence). Skipped until
evidence changes, so one empty day cannot block later days or today.

#### Per-day repair time so other missed days are not blocked by shared backoff
`DayDigestScheduler.repairAfter`: Past days whose digest needs a quiet repair, with the time the repair
may run. Other missed days proceed meanwhile instead of waiting behind
the shared failure backoff.

#### Prevents chained catch-up tick reselecting a day before its marker is observed
`DayDigestScheduler.justFinishedDay`: A past day that just finished, so the chained catch-up tick cannot
select it again before its durable marker is observed.

#### Quiet period after evidence change gives one rerun instead of start-cancel bursts
`DayDigestScheduler.evidenceSettleDelay`: Quiet period after an evidence change before a fresh run starts, so a
meeting finishing (notes, outcomes, search index) produces one rerun
instead of a start-cancel-start burst.

#### Cancel snapshot-bound run on evidence change; model failure backoff kept after 2026-10-01 incident
`DayDigestScheduler.reconsiderEvidence`: Primary evidence changed while the scheduler may have been awaiting a
model. Cancel that snapshot-bound run and let policy choose a fresh one.

A recent model failure keeps its backoff: on 2026-10-01 every finished
meeting cleared it, so a rate-limited provider was asked again at once.

#### Failed generation waits failure backoff so it is not retried every minute
`DayDigestScheduler.tick`: A failed generation (model unreachable, disk error) should be
visible but not retried every minute; generation itself can take a
while, so give the system room between attempts.

#### Busy system is not downtime; skip tick without consuming backoff
`DayDigestScheduler.tick`: Not downtime yet — recording, processing, dictation, or cotyping is
active. Don't burn the backoff; just wait for a quieter tick.

#### Degraded journal stays visible; past day backs off alone so later days run
`DayDigestScheduler.tick`: The fallback/partial journal stays visible. Its
sidecar keeps the durable completion marker absent,
and the backoff prevents a retry every minute. A
past day backs off alone so later days still run.

#### Chain catch-up ticks to finish backlog without a minute wait per day
`DayDigestScheduler.tick`: Finish the missed-day backlog without waiting a minute per day.

#### Run after today's hour unless journal written at or after it; morning manual digests refresh
`DayDigestScheduler.shouldRun`: Pure policy: run once the clock passes today's configured hour, unless
the journal file was already written at/after that time. A morning
manual digest (mtime before the target) is refreshed; an evening one
(manual or scheduled) suppresses the run for the rest of the day.

#### Past days oldest-first until rewritten after own midnight, then today's preview policy
`DayDigestScheduler.generationDay`: Past days (oldest first) take priority until each has been rewritten
after its own midnight. Afterwards the normal scheduled preview policy
applies to today. Pure so DST and durable-marker behavior stay
regression-tested.

#### Past day with evidence is final once journal written after next day starts
`DayDigestScheduler.needsFinalization`: A past day with evidence is final once its journal was written at or
after the start of the following day.

### `LokalBot/Services/Timeline/MemoryRoutines.swift`

#### Crashed running row is not success so scheduler retries after relaunch
`MemoryRoutineRunStore`: Durable audit trail for every routine attempt. A `running` row left by a
crash is intentionally not success, so the scheduler can retry it after the
next launch instead of silently losing a due output.

#### Scheduled tokens terminal on success or failure to prevent tight retry loops
`MemoryRoutineRunStore.hasFinished`: A scheduled token is terminal after either success or failure. This
prevents a bad destination or malformed source from becoming a tight
retry loop; manual runs use unique tokens and remain available. A stale
`running` row is deliberately non-terminal so launch recovery can retry.

#### Reuse only latest revision so reverted corrections A-B-A are not suppressed
`MemoryRoutineRunStore.revisionToken`: Reuse only the latest revision in this scope. A correction can be
reverted (A -> B -> A), so an older success for A must not suppress it.

#### Fixed-scope local renderers: no shell, no network, one private Markdown write
`MemoryRoutineRunner`: Fixed-scope local renderers. They do not invoke a shell, contact a network,
mutate meeting data, or accept arbitrary prompts. The sole write is one
private Markdown file under the user-selected destination.

#### Rebuild after changes; finished revisions stay in audit trail with new token
`MemoryRoutineScheduler.reconsiderEvidence`: Rebuild prepared output after a correction, completion, or deletion.
Finished revisions remain in the audit trail; changed bytes get a new token.

#### Preparation failure recorded once; read-only preparation can recover next tick
`MemoryRoutineScheduler.tick`: Preparation may fail before output has a fingerprint. Record
the failure once; read-only preparation can recover next tick.

### `LokalBot/Views/Timeline/DayDigestCard.swift`

#### Top actions matching recorded candidates are real threads checkable here; others are advice
`YesterdayBriefPanel.priorities`: The brief's top actions, in its order. One taken from the recorded
candidates is the real thread: it can be checked off here and stays in
sync. The rest are numbered advice.

### `LokalBot/Views/Timeline/DayDigestView.swift`

#### Timeline sets it so a digest time range opens that work session
`DayDigestTimeRangeAction`: Opens the work session a task's time range covers. Timeline sets it, so
"09:00–10:30" in an older digest leads to that session.

#### Action is nil when no session of the day falls inside the range
`DayDigestTimeRangeAction.action`: The action for a range such as "09:00–10:30", or nil when no session
of the day falls inside it.

#### Project names keyed by lowercase name so a task tag takes the project colour
`EnvironmentValues.dayDigestProjects`: The day's project names by lowercased name. A task tag that names one
takes that project's colour.

#### Human-first view of the lossless Markdown journal; evidence trail only on demand
`DayDigestView`: Human-first rendering of the lossless Markdown day journal. Summary and
focus stay visible; the forensic activity/evidence trail is available on
demand without making every captured moment compete for attention.

#### Timeline shows highlights and actions itself; this view adds work and decisions panels
`DayDigestView.Mode.timeline`: Timeline's day page shows the highlights and the day's actions
itself, and this view under them: the work as one panel, with
its tasks by status, then the decisions as another.

#### Every task stays one visible line; only the description opens on demand
`DayDigestView.fullContent`: Every task stays visible as one scannable line; only
the description of what was done opens on demand.

#### Blockers lead the digest as they stop the day's open work
`DayDigestView.blockersCallout`: Blockers lead the digest: they are what stops the day's open work.

#### Status-grouped digests show Blocked/In progress in full, rest one-line, Done folded
`DayDigestView.workSummaryPanel`: One panel for the day's work. A digest that gives its tasks a status
groups them: Blocked and In progress in full where a task has a next
step, the rest of the open work as one-line rows, and finished work
folded into a single Done line. An older digest lists its entries.

#### Task row shows status, title, next step; what was done opens in place
`DayDigestTaskRow`: One task at a glance: status, title, and its next step. What was done
opens in place, so a day of tasks reads as a short list.

#### Inset is status column width plus spacing; details and dividers align to it
`DayDigestTaskRow.textInset`: Status column width plus spacing; details and dividers align to it.

#### Timeline shows a title's trailing (Project) as a tag
`DayDigestTaskRow.showsTag`: Timeline shows a title's trailing "(Project)" as a tag.

#### Project tag uses the project's colour, same as its sessions in list and strip
`DayDigestTaskTag`: A project or pull request split off a task title. A project of the day
carries its colour, the one its sessions have in the list and the strip.

#### Long lists of next-step-less tasks show first rows until asked for the rest
`DayDigestBriefTaskList`: One-line rows for open tasks without a next step. A long list shows its
first rows until asked for the rest.

#### Fold only when it hides 2+ rows; hiding one costs as much room
`DayDigestBriefTaskList.body`: Hiding a single row would cost as much room as showing it.

#### Footer strip fill keeps the supporting colour above 4.5:1 contrast
`DayDigestDoneSection`: The footer strip's fill: the supporting colour stays above 4.5:1 on it.

#### Legacy journal screen moments no longer kept get no link
`DayDigestSourceLinks`: Screen moments a legacy journal cited for a task. A moment that is no
longer kept gets no line: a link appears only when there is a source.

### `LokalBot/Views/Timeline/TimelineDigestPage.swift`

#### Lifecycle reflects scheduled digest runs so manual requests cannot start a competing generation
`TimelineDigestPage.lifecycle`: Reflects every digest run for the day, a scheduled one included, so a
manual request cannot start a competing generation.

#### Day actions panel keyed by day so each day starts with its own rows
`TimelineDigestPage.body`: Each day starts with its own rows, shown or not.

#### No identifier on the digest group; SwiftUI merges it with Work Summary and replaces the panel's
`TimelineDigestPage.body`: No identifier here: when the digest's only section
is Work Summary, SwiftUI merges this group with that
panel and an identifier here replaces the panel's.

#### Project names by lowercase name so a task tag takes its sessions' colour
`TimelineDigestPage.projects`: Project names of the day, by lowercased name, so a task's project tag
takes the colour its sessions have.

#### Highlights panel footer shows digest time and Update; missing and writing states say so
`TimelineHighlightsPanel`: The digest's highlights as the page's first panel. Its footer says when
the digest was written and offers Update once there is newer activity. A
day without a digest, and one being written, say so here.

#### Digest is scheduled, so a missing one will come
`TimelineHighlightsPanel.writesEachEvening`: The digest is written on a schedule, so a missing one will come.

#### Show time only on the day itself; add the date if written later
`TimelineHighlightsPanel.written`: The time alone on the day itself; the date too once it was written later.

#### With no open actions the panel collapses to its All done header
`TimelineDayActionsPanel`: The user's actions from the day's meetings, as the shared action rows
under a header that counts the open ones and leads to Actions. With none
open the panel is its header, "All done".

#### Title allows two lines as the longest panel title beside a badge and link
`TimelineDayActionsPanel.body`: The longest panel title on the page, beside a badge and a link.

### `LokalBot/Views/Timeline/TimelineRail.swift`

#### Rail layout: tracked total, hour strip, sessions by period, All captured activity pinned last
`TimelineRail`: Timeline's rail, on the trailing side of the day's page: the tracked total
with the hour strip and its legend, then the day's sessions and meetings in
time order under Morning, Afternoon and Evening, with All captured activity
pinned as its bottom row. Choosing a row, or a bar of the strip, shows it
on the page beside; choosing it again returns to the day.

#### Tracked summary is nil on a day with no tracked time and no meetings
`TimelineRail.tracked`: Nil on a day with no tracked time and no meetings.

#### Scene count gives a session row's spoken value
`TimelineRail.sceneCount`: Screen moments kept during a session, for its row's spoken value.

#### Scroll to a selected row since a strip bar or arrow key can choose an off-screen one
`TimelineRail.body`: A bar of the strip, or an arrow key, can choose a row the list
has scrolled away from.

#### Observes the sampler itself because it publishes too often for the whole page
`TimelinePausedLine`: "Day memory is paused" with Resume, at the top of the rail while tracking
is paused. It observes the sampler itself, which publishes too often for
the whole page to follow.

#### Legend per project, or per app without projects; names shown as captured
`TimelineTrackedBlock.legend`: Each project's time, or each app's on a day without projects, then
the meetings' total. App and project names are shown as captured.

#### One hour label per 44 points keeps 12 PM clear of neighbours
`TimelineDayStripView.body`: About one label every 44 points keeps "12 PM" clear of its neighbours.

#### Strip is forced left-to-right since bars are placed by offset, which does not mirror
`TimelineDayStripView.body`: Hours run left to right in every language, like a clock's day; the
bars are placed by offset, which does not mirror.

#### Strip reads as one picture because the list under it has each row's name and times
`TimelineDayStripView.body`: The list under the strip has the same rows, each with its name and
times, so assistive technologies read the strip as one picture.

#### Image trait needed or the strip has no accessibility role
`TimelineDayStripView.body`: Without a trait the strip has no role at all.

#### Day period shown on first hour and noon only; 24-hour clock shows hour either way
`TimelineDayStripView.hourStyle`: "8 AM" for the first hour and noon, "9" for the rest; a 24-hour clock
shows the hour either way.

#### Bar width equals its time; hit area is widened so thin bars stay clickable
`TimelineDayStripView.segment`: The bar is as wide as its time. A click a little to either side of a
thin one still chooses it.

#### List matches the Meetings list: 13-point title over 12-point second line
`TimelineListStyle`: The list reads like the Meetings list: a 13-point title over a 12-point
second line.

#### Selected row uses the unemphasized selection colour lists show when another pane has keyboard
`TimelineListStyle.selection`: The selected row, as a list shows its selection while another pane has the keyboard.

#### Time column omits AM/PM under period headings and follows text size
`TimelineListMetrics`: Column widths of a row. The time has no AM or PM, since the list is
already under Morning, Afternoon and Evening, and follows the text size.

#### Marker height centres the dot on dotCenterY under the 5-point row top padding
`TimelineListMetrics.markerHeight`: The marker's height, which centres the dot on `dotCenterY` under the
row's 5-point top padding.

#### Meetings keep waveform and accent; sessions use their project's strip colour
`TimelineListRow.marker`: Meetings keep the waveform and the accent; a session shows the colour
of its project, the same one its bar has in the day strip.

#### One line runs through neighbouring dots, starting at the first and ending at the last
`TimelineListRow.spine`: One line runs through the dots of neighbouring rows, so the list reads
as a day. It starts at the first dot and ends at the last.

#### Spine uses padding, not offset, so it follows right-to-left layouts
`TimelineListRow.spine`: Padding, not an offset, so the line follows a right-to-left layout.

#### Accessibility label goes on the text, since a label-only container has no role
`TimelineListAwayRow.body`: The label is on the text, which keeps its role; a
container with only a label has none.

#### One colour per project, or per app on days without projects; other activity is grey
`TimelineRowColor`: One colour per project, or per app on a day without projects, from the
app's existing name-hashed palette. Other activity is neutral.

### `LokalBotTests/Models/Timeline/DayDigestPresentationTests.swift`

#### Timeline gives full rows to open tasks with next step and blocked tasks; others one line
`DayDigestPresentationTests.testTimelineRowsKeepNextStepsAndBlockersInFull`: Timeline gives full rows to open tasks with a next step and to blocked
tasks; the rest of a group, and all of Done, become one-line rows.

#### Timeline page leads with highlights itself, above the day strip
`DayDigestPresentationTests.testEmbeddedModesDoNotRepeatHostOwnedSections`: Timeline's page leads with the highlights itself, above the day strip.

### `LokalBotTests/Models/Timeline/TimelineDayLayoutTests.swift`

#### Roomy case is a 1440-point window beside the 216-point sidebar
`TimelineDayLayoutTests.testTheRailIsItsIdealWidthInARoomyWindowAndItsMinimumInTheDefaultOne`: A 1440-point window beside the 216-point sidebar.

#### Default 1180-point window leaves the page 663 points
`TimelineDayLayoutTests.testTheRailIsItsIdealWidthInARoomyWindowAndItsMinimumInTheDefaultOne`: The default 1180-point window: the page keeps 663 points.

#### Smallest captured window is 1000 points; rail keeps 300, page exceeds minimum
`TimelineDayLayoutTests.testTheRailGivesWayBeforeThePageGetsTighterThanItsMinimum`: The smallest captured window, 1000 points: the rail keeps 300 and
the page has more than its minimum.

#### Narrower windows keep the page at minimum and shrink the rail to its floor
`TimelineDayLayoutTests.testTheRailGivesWayBeforeThePageGetsTighterThanItsMinimum`: Narrower still, the page stays at its minimum and the rail shrinks
to its floor.

#### Default window offers less than larger text asks; rail takes scaled minimum
`TimelineDayLayoutTests.testTheRailGrowsWithLargerTextWhereTheWindowHasRoom`: The default window offers less than larger text asks for: the
rail takes its scaled minimum, and the page still has its own.

#### At default window panels have the whole main area inside their gutters
`TimelineDayLayoutTests.testPanelsFillTheMainAreaUpToTheirWidestLine`: At the default window the panels have the whole main area inside
their gutters.

### `LokalBotTests/Models/Timeline/TimelineDayListTests.swift`

#### A fifteen-minute stretch is not a gap in the day list
`TimelineDayListTests.testALongStretchWithNothingRecordedIsKeptAsAGapInThePartItBegan`: Fifteen minutes is not a gap.

#### A gap starts at the latest end seen so far
`TimelineDayListTests.testAGapStartsAtTheLatestEndSoFar`: A meeting that runs past the next session must not open a gap that
never happened: a gap starts at the latest end seen so far.

#### Zoom's name in the activity sampler is zoom.us
`TimelineDayListTests.testACallAppSessionFoldsIntoTheMeetingThatCoversIt`: Zoom's own name in the activity sampler is "zoom.us".

#### Other apps during a call, and a call app for most of a morning, are not folded
`TimelineDayListTests.testOtherWorkDuringAMeetingStaysListed`: Another app during the call, and the call's app for a morning
of which the call was a small part.

#### A manual recording names no app, so nothing folds into it
`TimelineDayListTests.testCallAppNamesMatchAcrossTheirTwoSpellings`: A manual recording names no app; nothing folds into it.

#### Commits are named only when no pull request moved
`TimelineDayListTests.testAProjectSessionShowsItsTaskThenProjectAndWhatWasProduced`: Commits are named only when no pull request moved.

#### Without a project the subtitle starts with the time range
`TimelineDayListTests.testASessionsPageNamesItsProjectTimeAndApps`: Without a project the line starts with the time range.

#### A digest time range ending past midnight is clipped to the day
`TimelineDayList.interval(fromTimeRange:day:calendar:)`: A range that ends past midnight is clipped to the day.

#### List times drop AM/PM and leading zero; macOS 15 and 26 showed 09:10
`TimelineListClock.text`: The list is under Morning, Afternoon and Evening, so a 12-hour clock
shows "9:10" and "1:05": no AM or PM, and no leading zero (the hosted
runs on macOS 15 and 26 showed "09:10" from `Date.FormatStyle`).

#### The day period goes wherever the language puts it
`TimelineListClock.text`: The day period goes wherever the language puts it.

#### Pattern is the locale's own with the day period removed, independent of macOS formatting
`TimelineListClock.pattern`: The pattern is the locale's own with the day period taken out, so it
does not depend on how a macOS release formats an hour without one.

#### Rail lists sessions and meetings plus All captured activity; the day's page has no row
`TimelineListSelection`: The rail lists sessions and meetings, with All captured activity as
its bottom row. The day's page has no row: it is what shows while no
row is chosen, and it stands before the first one for the arrow keys.

#### Arrow ends hold; a moment opened from another page steps onto the day's page
`TimelineListSelection.moved(by:in:)`: The ends hold, and a moment opened from another page steps onto the day's page.

### `LokalBotTests/Models/Timeline/TimelineDayStripTests.swift`

#### The first hour and noon tick labels name AM or PM
`TimelineDayStrip.ticks`: The first hour and noon say AM or PM.

#### A bar has a three-point minimum width, shifted left to stay in the lane
`TimelineDayStrip.frame(of:in:)`: One minute of ten hours is a point wide; it shows as three, moved
left so it does not leave the lane.

#### Thin bars are drawn at their own width but accept clicks over a wider area
`TimelineDayStrip.hitFrame(of:in:)`: In the rail a ten-minute session is a few points wide. It is drawn at
its own width and answers a click a little to either side.

#### A thin bar's click area is 12 points, centred on the bar
`TimelineDayStrip.hitFrame(of:in:)`: Ten minutes of ten hours in a 320-point strip: 5.3 points drawn,
12 to click, centred on the bar.

#### The Other activity entry is neutral-coloured like the sessions it stands for
`TimelineDayLegend.entries`: Other activity is neutral, like the sessions it stands for.

#### Open actions come first; the rest keep the index's order
`TimelineDayActions.threads`: Open work first; the rest keeps the index's order.

#### Deferred work is not done, so a day with only deferred actions shows nothing open
`TimelineDayActions.pill`: Deferred work is not done: the day has nothing open, and says so.

#### A day whose actions were all done before opening shows a header alone
`TimelineDayActions.showsRows`: A day whose actions were all done before it was opened is a header alone.

#### Ticking the last open action leaves the rows where they were
`TimelineDayActions.showsRows`: Ticking the last open action leaves the rows where they were.

#### While a digest is written the menu item says so regardless of prior state
`TimelineDigestPreview.menuTitle`: While a digest is written the item says so, whatever was there before.

### `LokalBotTests/Models/Timeline/TimelineProjectAttributionTests.swift`

#### Agent app time counts the burst plus a two-minute margin after its last event
`TimelineProjectAttribution.shares`: The burst plus the two-minute margin after its last event.

#### A page naming no project stays unattributed even while agents work
`TimelineProjectAttribution.dominantProject`: A page naming no project stays unattributed even while agents work.

#### A project session is not cut at the 45-minute limit
`TimelineWorkSession.sessions`: A project session is not cut at the 45-minute limit.

#### Time no project claims is cut at 45 minutes, as without agents
`TimelineWorkSession.sessions`: Sixty minutes of chat is still cut at 45 minutes, like without agents.

### `LokalBotTests/Models/Timeline/TimelineWorkSessionTests.swift`

#### A brief window title stays evidence without joining the session title
`TimelineWorkSession`: Eight seconds of Safari stay evidence without joining the title.

#### Apps with only seconds of use don't count toward the +N in an untitled session
`TimelineWorkSession.title`: Spotify's 50 seconds don't count toward "+1".

### `LokalBotTests/Services/Timeline/ActivityStoreTests.swift`

#### Ask reads up to 2,000 ranked captures at once; gone captures omitted
`ActivityStore batched screenshot lookup`: Ask reads the records of up to 2,000 ranked captures in one go; each
must match the single-capture lookup, and gone captures are left out.

#### Detail page read note from newest 200 moments; older moments opened empty
`ActivityStore saved moment note`: The moment's detail page read its note out of the newest 200 saved
moments, so an older one opened with an empty note field.

#### EmbeddingGemma 2 scores unrelated screen text ~0.61, above Harrier's 0.45 floor
`ActivityStore semantic screen floor`: EmbeddingGemma 2 scores unrelated screen text around 0.61, so Harrier's
0.45 floor would let nearly every capture into semantic results.

#### Snippets built after ranking only for returned rows; must equal eager ones
`ActivityStore.searchOCR`: Snippets are built after ranking, only for the rows returned; deferred
snippets filled later must equal them, for FTS and CJK substring search.

#### Empty OCR never entered legacy FTS, so FTS rowid diverges from screenshot id
`ActivityStore legacy OCR migration`: Empty OCR was never inserted in the legacy FTS table, so this
row's FTS rowid is 1 while its real screenshot id is 2.

#### AX title and frame identify one focused window, not array order
`ScreenshotCaptureLayout.selection`: The AX title and frame identify one focused window rather than
selecting a different window of the same app by array order.

#### Other windows stay outside the filter; background browser's excluded domain unknown
`ScreenshotCaptureLayout.selection`: All other windows stay outside the filter, including an ordinary
background browser whose excluded domain is not known here.

#### Only the excluded site is anonymous; unreadable address and timeouts keep app without title
`ActivitySampler`: Only the excluded site is anonymous. An unreadable address under
site rules and a timed-out read keep the app without a title; an
unknown secure-field state keeps the window title.

#### Browsers were recorded as Private whenever browsing mode could not be verified
`ActivitySampler`: Regression: browsers and web-based apps were recorded as "Private"
whenever their browsing mode could not be verified.

### `LokalBotTests/Services/Timeline/DailyMemoryExportSchedulerTests.swift`

#### Missed past days are checked first; test targets today's note
`DailyMemoryExportSchedulerTests.testFreshExport`: Missed past days are checked first; this test is about today's note.

#### Days older than the digest catch-up window are not exported
`testNextExportPutsReopenedDaysFirstThenMissedDaysThenToday`: Older than the digest's catch-up window.

#### The usual retry wait applies before the next export
`testPastDayThatFailsIsTriedOnceAndDoesNotHoldBackToday`: The usual retry wait applies before the next export.

### `LokalBotTests/Services/Timeline/DailyMemoryExportServiceTests.swift`

#### Today's note is written even when nothing happened; catch-up skips
`testCatchUpSkipsADayWithNothingRecorded`: Today's note is still written when nothing happened.

#### Fresh install has lazily created tables; read-only snapshot must see empty day
`testSnapshotToleratesDatabaseFileWithoutSchema`: A freshly booted install has a `lokalbotv3.sqlite` file whose tables
are created lazily — a read-only snapshot taken in that window (the
headless `--dream` case) must see an empty day, not throw.

### `LokalBotTests/Services/Timeline/DayDigestEvidenceTests.swift`

#### Clock stamp must match POSIX formatter hour and minute everywhere
`testClockStampMatchesAPOSIXFormatterAcrossCalendarsAndTimeZones`: Digest times were written with a new `DateFormatter` each; the
calendar's own hour and minute must read the same everywhere.

#### Test samples every 37 minutes across 2026 spring clock change
`testClockStampMatchesAPOSIXFormatterAcrossCalendarsAndTimeZones`: Every 37 minutes across the 2026 spring clock change, and one day in each season.

#### Digest ran 16 times on 2026-10-01 re-asking unchanged segments
`testRerunReusesUnchangedSegmentAndAggregationAnswers`: The digest ran 16 times on 2026-10-01 and re-asked the model about
every segment each time, including morning segments whose evidence had
not changed.

#### Fragmented day squeezed the six-hour main block into one segment
`testLongSessionGetsSegmentsInProportionToItsActiveTime`: On 2026-10-01 a fragmented day used all eight segments on separate
sessions, so the six-hour main block (809 events) was squeezed into a
single segment's sample budget and then judged not substantive.

### `LokalBotTests/Services/Timeline/DayDigestLifecycleTests.swift`

#### Retention expiry of evidence must not mark the digest out of date
`testExpiredEvidenceDoesNotMarkTheDigestOutOfDate`: Retention clears a day's titles and screen text after its digest was
written. The digest outlives them, so expiry must not read as new work.

### `LokalBotTests/Services/Timeline/DayDigestSchedulerTests.swift`

#### Journal mtime at or after target hour is the durable once-per-day marker
`testDigestWrittenAfterTargetHourSuppressesTheRun`: The journal file's mtime is the durable once-per-day marker: written
at/after today's target hour (by the scheduler or a manual regenerate)
means done — including across an app relaunch.

#### Morning manual digest is refreshed at scheduled hour for whole day
`testMorningManualDigestIsRefreshedAtScheduledHour`: A digest the user generated in the morning is refreshed at the
scheduled hour so the journal reflects the whole day.

#### Empty day is not a failure; scheduler stays quiet and retries later
`testEmptyDayIsNotReportedAsAnError`: An empty day is not a failure: the generate closure reports it and the
scheduler stays quiet, ready to retry once the day has content.

#### Finished meetings must not clear failure backoff for rate-limited providers
`testEvidenceChangeKeepsTheFailureBackoff`: Every finished meeting cleared the failure backoff on 2026-10-01, so a
rate-limited provider was asked for the whole digest again at once.

#### 220 characters of slack cover joining text and non-conflict clauses
`testCustomPromptIsBoundedByCeiling`: joining + non-conflict clauses

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
