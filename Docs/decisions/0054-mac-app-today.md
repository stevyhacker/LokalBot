# 0054. Mac app: Today

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Models/Today/`, `LokalBot/Views/Today/`, `LokalBotTests/Models/Today/`.

## Decisions

### `LokalBot/Models/Today/TodayAgenda.swift`

#### Display-only merged list of recorded and calendar meetings
`TodayAgenda`: Today's one list of meetings: what was recorded and what the calendar
holds, in time order. Display-only; nothing here is stored or sent.

#### Calendar meeting earns top card within an hour, kept while under way unrecorded
`TodayAgenda.nextMeetingWindow`: A calendar meeting earns the card at the top of Today once it starts
within the hour, and keeps it while under way and not being recorded.

#### Soon means within nextMeetingWindow; status reads in accent
`TodayAgenda.Entry.isSoon`: Starts within `nextMeetingWindow`, so its status reads in the accent.

#### Recorded events listed once as recording, never offered as next meeting
`TodayAgenda.recordedEventIDs`: Calendar events some recording is already linked to. They are listed
once, as that recording, and never offered again as the next meeting.

#### A recording storing its calendar event stands in for that event
`TodayAgenda.entries`: Today's recordings and calendar events as one list, earliest first. A
recording that stores its calendar event stands in for that event.

#### Any recording claims its event, merged source included
`TodayAgenda.entries`: Any recording claims its event, a merged source included.

#### At same minute the recording sorts first
`TodayAgenda.entries`: At the same minute the recording is the thing that happened.

#### Now line goes before first upcoming entry; none when nothing ahead
`TodayAgenda.rows`: The list with the now line before the first entry still ahead. A day
with nothing ahead has no line.

#### Skip recorded and live events; menu bar uses shorter window
`TodayAgenda.nextMeeting`: The meeting for the card at the top of Today: the one under way, or
the next one once it is within `window`. Events already recorded, and
the one being recorded now, are passed over. The menu bar asks with
its own, shorter window (`MenuBarStatus.soonWindow`).

#### Recap taken from saved summary; no model runs
`TodayMeetingRecap`: One line saying what a recorded meeting was about, taken from the summary
already saved beside it. No model runs for this.

#### First sentence-like line under TL;DR/Summary/Overview/Recap; nil otherwise
`TodayMeetingRecap.line`: The first sentence-like line under the summary's TL;DR (or Summary,
Overview, Recap) heading; nil when the summary has no such section.

#### Checkbox bullets are actions, not a recap
`TodayMeetingRecap.line`: Checkbox bullets are actions, not a recap.

#### Reads summary.md files; caller must run off main thread
`TodayMeetingRecap.lines`: Reads each meeting's saved `summary.md`. Small files, read off the
main thread by the caller.

#### Today shows only a few digest lines; rest is on Timeline
`TodayDigestHighlights`: The few lines of the day digest that Today shows. The rest of the digest
(tasks, decisions, follow-ups, the activity log) is on Timeline.

#### Use At a glance lines, else first task titles
`TodayDigestHighlights.markdown`: The digest's "At a glance" lines; a digest without them falls back to
the titles of its first tasks.

#### Stale means activity arrived after digest; Update rewrites it
`TodayDigestLine.stale`: Activity arrived after the digest was written; Update rewrites it.

#### Getting started stays under sections until hidden
`TodayPageLayout.sections`: The day's sections. Getting started stays under them until hidden.

#### Email whose latest message asks something unanswered
`TodayPreparation.Row.awaitingReply`: An email whose latest message asks something still unanswered.

#### One row per kind; fall back to closest earlier meeting when none
`TodayPreparation.primaryRows`: One row of each kind the evidence holds. A meeting with no decisions,
commitments or projects falls back to the closest earlier meeting.

#### Always show model-written brief; template brief only when no rows
`TodayPreparation.showsBrief`: A brief the model wrote is always shown. The template brief only
restates the rows, so it is shown when there are no rows to read.

### `LokalBot/Models/Today/TodayPanels.swift`

#### Two columns only when width fits readable leading beside fixed trailing
`TodayColumns`: One column or two. Today's panels sit side by side when the page is wide
enough for a readable leading column beside the fixed trailing one, and
stack in reading order otherwise. Widths are in points at the default
text size and grow with larger text.

#### Narrowest leading column that reads well beside trailing
`TodayColumns.leadingMinimumWidth`: The narrowest leading column (Needs attention, Meetings today) that
still reads well beside the trailing one.

#### Content width inside side padding needed for two columns
`TodayColumns.twoColumnMinimumWidth`: The narrowest page content, inside its side padding, that shows two
columns.

#### Width excludes side padding; a side without panels gives one column
`TodayColumns.count`: `width` is the page content's width inside its side padding. A side
with no panels leaves no gutter: the page is one column.

#### Two columns use full width; single-column pages keep reading width
`TodayColumns.pageMaximumWidth`: The page's widest, side padding included. Two columns and the cards
that span them use the full width; panels that can only ever form one
column keep the narrower reading width.

#### Fraction is 0 to 1 with longest row at 1
`TodayAppBars.Bar.fraction`: 0...1, where the longest row is 1.

#### Folded long tail has no colour of its own
`TodayAppBars.Bar.isOther`: The folded long tail, which has no colour of its own.

### `LokalBot/Views/Today/TodayColumnsLayout.swift`

#### Single Layout for both column modes so panels keep state across the width change
`TodayColumnsLayout`: Lays Today out as cards that span the page with the panels between them,
side by side when `TodayColumns` finds room and stacked in reading order
otherwise. One layout for both, so a panel keeps its state when the window
crosses the width where the page changes.

### `LokalBot/Views/Today/TodayLiveCard.swift`

#### Sound levels read the same health snapshot as the recording strip
`TodayRecordingLevels`: Whether each source is producing sound right now, from the same health
snapshot the recording strip reads, on one line.

### `LokalBot/Views/Today/TodayMeetingsSection.swift`

#### When calendar use is off, offer to turn it on once under the list
`TodayMeetingsSection.offersCalendar`: Calendar use is off: offer to turn it on, once, under the list.

#### No hairline before the now line, which draws its own rule; last row ends at panel
`TodayMeetingsSection.hasHairline`: A hairline divides two meetings. The now line draws its own rule, so
the meeting before it has none, and the last row ends at the panel.

#### Above the first meeting the now rule replaces the header hairline
`TodayMeetingsSection.nowLine`: "Now · 10:48 AM" under a rule the width of the panel. Above the first
meeting the rule takes the place of the header's hairline.

#### Text is the accessibility element; a label-only container has no role and fails the audit
`TodayMeetingsSection.nowLine`: The text is the element: a container with only a label has no
role, which the accessibility audit reports.

### `LokalBot/Views/Today/TodaySoFarSection.swift`

#### Lifecycle reflects scheduled digest runs so manual requests cannot start a competing generation
`TodaySoFarSection.lifecycle`: Reflects every digest run for today, a scheduled one included, so a
manual request cannot start a competing generation.

#### Bar name and duration columns grow with text size like Meetings today time column
`TodaySoFarSection.nameColumnWidth`: The bar's name and duration columns, which grow with the text size
like the time column of Meetings today.

#### Name and time carry the information; the bar only illustrates it
`TodaySoFarSection.appBar`: The name and the time say everything; the bar only shows it.

#### Leading alignment makes the bar grow from the right in right-to-left languages
`TodayAppBarShape.body`: Leading, so the bar grows from the right in
right-to-left languages.

### `LokalBot/Views/Today/TodayView.swift`

#### Home answers what is live, next and needs you; cards lead only while relevant
`TodayView`: The home screen answers three things: what is live, what is next, and what
needs you. A card leads only while it matters (a recording in progress, a
meeting within the hour); the rest is the day's actions, meetings and
activity, each in its own panel, in two columns when the window has room.
Timeline stays the hour-by-hour view of the same day.

#### False until the day loads once so an empty page is not mistaken for a first day
`TodayView.dayLoaded`: False until the day's activity has loaded once, so an empty page is
not mistaken for a first day while it loads.

#### Recording in progress leads so it is found before the library lists it
`TodayView.recordings`: The recording in progress leads, so it is found even before the
library lists it.

#### Header accessibility marker is what UI tests wait for before using the window
`TodayView.body`: The marker tests wait for before they use the window.

#### No recording bar on Today; Record is in the toolbar and the live card holds the only Stop
`TodayView.body`: The page has no recording bar: Record lives here, and the
live card holds the only Stop.

#### Publisher reports every change, also when a fast load starts and ends between renders
`TodayView.body`: The publisher reports every change, also when a fast load starts
and ends between two renders.

#### A midnight report arrives while the view is mounted; re-anchor every section before selecting it
`TodayView.body`: A report normally arrives after midnight while this view may
have remained mounted since yesterday. Re-anchor every section,
not just the dream card, before selecting the new report.

#### A column with no panels leaves the page one column at reading width
`TodayView.page`: The panels each column would hold. A side with none leaves the
page one column at its reading width.

#### Nothing-yet is shown only once library and day activity both answered
`TodayView.isSettled`: The library and the day's activity have both answered, so "nothing
yet" is a fact and not a page still loading.

#### Today adds only the top card title size; panel titles use SectionPanelMetric.titleFont
`TodayType`: Type sizes Today adds to the shared set: the title of the card at the
top. Panel titles are `SectionPanelMetric.titleFont`.

#### Card looks back up to 5 days for a substantive brief
`TodayDreamSelection.lookbackDays`: How many days back (yesterday included) the card will reach for a
substantive brief before going quiet.

#### Empty-day stubs are never surfaced; returning users see the last real brief
`TodayDreamSelection.report`: Yesterday's brief when there is one; otherwise the newest substantive
brief within the lookback. Empty-day stubs exist only to mark their day
dreamed — they are never surfaced, and a returning user sees their last
real morning brief instead of "nothing was recorded".

#### Report older than yesterday is labelled instead of presented as fresh
`TodayDreamSelection.isCurrent`: False when the report covers an older day than yesterday, so the card
can label it instead of presenting it as fresh.

#### Inline retry only for current model-failure briefs; retrying older would replace yesterday's report
`TodayDreamSelection.isRetryableFailure`: Only a current evidence-only brief caused by model generation deserves
an inline retry. Empty days have nothing to regenerate, and retrying an
older card would silently replace yesterday's report instead.

#### Covered day named by weekday within the last week, date beyond
`TodayDreamSelection.PrioritiesSource.day`: The covered day by name: its weekday within the last week, its
date beyond that.

#### Only yesterday's brief earns Priorities for today; older ones carry their own day
`TodayDreamSelection.prioritiesSource`: A brief from yesterday earns "Priorities for today"; anything older is
framed with its own day so a Friday brief on Monday never reads as
current. Weekday alone within the lookback window, full date beyond it.

#### English heading for text that is not interface text
`TodayDreamSelection.prioritiesHeading`: `prioritiesSource` in English, for text that is not interface text.

### `LokalBotTests/Models/Today/TodayAgendaTests.swift`

#### The live meeting can be both the current recording and in the library
`TodayAgenda.entries`: The live meeting can be both the current recording and in the library.

#### A meeting being recorded or already recorded is not coming up again
`TodayAgenda.nextMeeting`: The one being recorded, or already recorded, is not coming up again.

### `LokalBotTests/Models/Today/TodayPanelsTests.swift`

#### One-sided panels keep the reading width; both sides or cards alone get the wide page
`TodayColumns.pageMaximumWidth`: One-sided panels keep the reading width; both sides, or cards
alone, get the wide page.

#### Only trailing panels on a wide page use one column with no gutter
`TodayColumnsLayout.frames`: Only trailing panels in a wide page: one column, no gutter.

#### Many short apps fold into Other, which can outweigh the top app
`TodayAppBars.bars`: Many short apps fold into Other, which can outweigh the top app.

#### An app itself named Other keeps its own identity
`TodayAppBars.bars`: An app that is itself called Other keeps its own identity.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
