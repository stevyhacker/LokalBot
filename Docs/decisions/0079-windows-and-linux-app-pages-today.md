# 0079. Windows and Linux: app — pages / today

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/today/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/today/brief.rs`

#### Brief only reads saved review; never starts one; pinning is in Settings
Yesterday's brief on Today (`YesterdayBriefPanel`, `DreamBriefText`): the
overnight review's narrative, its priorities with their real checkable
actions, and its notes. Reads what the review saved; never starts one by
itself. Pinning the projects and goals it keeps is in Settings › Day
memory, as on the Mac.

#### Brief data is read off the main thread
`BriefModel`: What Today reads for the brief, off the main thread.

#### Provenance is translated for the page; saved Markdown keeps English
`provenance_line`: `DreamReport.provenanceDescription`, translated for the page. The saved
Markdown keeps the English.

#### Brief section looks selectable; cited meetings open on click
`brief_text`: One section of a brief: selectable-looking text whose cited meetings open.

#### Older-than-yesterday brief is titled with its own day
`TodayPage::render_yesterday`: Yesterday's overnight brief as a panel (`YesterdayBriefPanel`): what
happened, the priorities it leaves and its notes without a click,
"Open day", and the brief's own account of how it was written in the
footer. A brief older than yesterday is titled with its own day.

#### Top actions from recorded candidates are real threads; others numbered advice
`TodayPage::render_yesterday`: A top action taken from the recorded candidates is the real
thread: it can be checked off here and stays in sync. The
rest are numbered advice.

#### Priorities label is today's, a weekday in week, or a date
`priorities_label`: Whose priorities the brief holds: today's for yesterday's brief, an older
day's by its weekday within the week and its date beyond.

#### Reload before changing so a page can't overwrite review output
`set_pinned`: Reloads before changing, so a page can't overwrite what a review wrote since.

### `LinuxWindows/crates/lokalbot-app/src/pages/today/digest.rs`

#### Today shows only digest highlights and time; helpers shared from here
The Day Digest and the day's activity overview on Timeline
(`DayDigestCard.swift`, `DayDigestView.swift`, `DayActivityOverview.swift`).
Today's So far today shows only the digest's highlights and when it was
written, with `hm` and `digest_updated_at` from here.

#### Duration format: 3h 50m, 48m, \<1m, 0m for nothing
`hm`: `CaptureStyle.hm`: "3h 50m", "48m", "\<1m" (and "0m" for nothing).

#### Top five apps with at least a minute, then Other
`app_shares`: Top five apps with at least a minute, then "Other" (`ProportionBarMath`).

#### Digest time is sidecar generated_at, else file modified time
`digest_updated_at`: When the digest was written: its sidecar's time, else the file's.

### `LinuxWindows/crates/lokalbot-app/src/pages/today/getting_started.rs`

#### First-day steps lead empty Today, then stay until hidden
The first-day steps (`GettingStartedCard.swift`). On a day with nothing to
show yet they are Today's content; after that they stay under the day
until hidden.

#### Opens calendar switch when off, calendar links when on
`GettingStarted calendar step`: The switch while calendar use is off, else
the calendar links it reads.

#### Timeline explains and enables day tracking
`GettingStarted tracking step`: Timeline is where day tracking is explained and turned on.

#### Download transcription model before first recap needs it
`GettingStarted model step`: Get the transcription model onto disk before the first recap
needs it.

### `LinuxWindows/crates/lokalbot-app/src/pages/today/live.rs`

#### Live card holds the only Stop on the page
The recording in progress, at the top of Today (`TodayLiveCard.swift`):
what is being recorded, for how long, whether sound is arriving, and the
only Stop on the page.

#### Engine reports track states; levels fill in until first report
`TodayPage::render_live_card`: The engine reports each track's state (Mac words, looked up here);
levels fill in until its first report arrives.

#### Ten bars lit up to system audio level
`meter`: Ten small bars, lit up to the system audio's level (`TodayRecordingLevels`).

### `LinuxWindows/crates/lokalbot-app/src/pages/today/mod.rs`

#### Today shows cards only while relevant, then panels, then Get started
Today (`TodayView.swift`): what is live, what is next, and what needs you.
A card leads only while it matters (the recording in progress, a meeting
within the hour); the rest is the day's panels (Needs attention, Meetings
today, So far today, Yesterday), side by side when the page has room, and
Get started on the first days. Sessions, the digest's tasks and its menu
are on Timeline; planning the open actions is on Actions.

#### Card title is 21 on this port versus 20 pt on macOS
`CARD_TITLE`: The title of the card at the top (`TodayType.cardTitle`, 20 pt on macOS).

#### Compact title for next meeting during recording and Get started
`CARD_TITLE_COMPACT`: The next meeting's title while another one is being recorded, and Get
started's title (`TodayType.cardTitleCompact`).

#### Today data is loaded off the main thread
`TodayModel`: What Today shows, loaded off the main thread.

#### Most urgent open actions, overdue first, capped at ATTENTION_LIMIT
`TodayModel.attention`: The most urgent of the user's open actions, overdue first: at most
`model::ATTENTION_LIMIT`.

#### Looks done? suggestions keyed by thread
`TodayModel.hints`: "Looks done?" suggestions, by thread.

#### One line per finished recording today from its saved summary
`TodayModel.recaps`: One line per finished recording of today, from its saved summary.

#### Needs-attention count cached until library revision or day changes
`OpenActions`: Needs attention as last counted. Counting reads every meeting's outcomes,
so it is kept until the library changes (`AppData::revision`, which every
action edit, phone edit and engine write bumps) or the day turns, which
moves what is overdue.

#### Unreadable library yields None so next reload retries
`OpenActions::count`: Counts them; nil when the library couldn't be read, so the next
reload tries again rather than keeping an empty list.

#### Fetch every open action so panel can count total and overdue
`OpenActions::count`: Every open action of the user's, in attention order, so the panel
can say how many there are and how many are overdue.

#### Planted demo library never counts days toward GitHub star
`TodayPage.seeded_demo_library`: A planted demo library never counts days toward the GitHub star.

#### 30 s refresh re-anchors midnight; open actions recounted only on change
`TodayPage::new`: Today re-anchors after midnight, moves the now line and picks up
new activity. Open actions are counted again only when the library
or the day changed (`OpenActions`).

#### Done suggestions only from text kept with consent
`TodayPage::reload`: Suggestions only, and only from text kept with consent.

#### Redraw every second while recording for the timer
`TodayPage::sync_tick`: Redraws every second while recording, for the timer.

#### Counts active day toward star prompt like Mac; prompt only in Settings
`TodayPage::record_active_day`: Counts today once toward the GitHub star prompt's active days, as the
Mac does at launch. The prompt itself is no longer on Today: the
Mac shows "Star on GitHub" in Settings only.

#### Live recording leads the list so it is found before library lists it
`TodayPage::frame`: The recording in progress leads, so it is found even before the
library lists it.

#### Card is panel surface tinted for recording; mirrors todayCardSurface
`card_surface`: The raised card at the top of Today and around Get started
(`todayCardSurface`): the panel surface, tinted for a recording.

#### Meeting status words match Mac and the tray menu
`status_text`: A meeting's place in the day in words: "In 12 min", "Recording", "Ended"
(`TodayMeetingStatusText`). The tray menu's next meeting says it the same.

#### Saved recording's row shows app and length instead of Ended
`status_text`: A saved recording's row shows its app and length instead.

#### Record lives in toolbar; live card holds the only Stop
`TodayPage::toolbar`: Ask About Today and Record. The page has no recording bar: Record
lives here, and the live card holds the only Stop.

#### Say nothing about the day before first load completes
`TodayPage::render`: Nothing is said about the day before it has loaded once.

#### 30-second refresh with same library and day reuses count
`open_actions_are_counted_again_only_after_a_change_or_midnight`: The 30-second refresh: same library, same day.

#### Revision bumps from action edit, phone edit, finished summary
`open_actions_are_counted_again_only_after_a_change_or_midnight`: An action edit, a phone edit or a finished summary.

#### Midnight moves what is overdue so count is stale
`open_actions_are_counted_again_only_after_a_change_or_midnight`: Midnight moves what is overdue.

### `LinuxWindows/crates/lokalbot-app/src/pages/today/model.rs`

#### Today model is display-only, mirrors Swift Today files
What Today decides before it draws (`TodayPanels.swift`, `TodayAgenda.swift`,
`TodayDreamSelection`): when the panels form two columns, the bars of So far
today, what Needs attention says about itself, today's one list of
meetings, the recap line under a recorded meeting, the digest line, the
page's layout and the rows of "Before you join". Display-only: nothing here
is stored or sent.

#### So far today names four apps, folds rest into Other
`APP_LIMIT`: Apps So far today names before folding the rest into "Other".

#### Panels go two-column only when page fits; widths scale with text size
`columns`: One column or two (`TodayColumns`). The panels sit side by side when the
page is wide enough for a readable leading column beside the fixed
trailing one, and stack in reading order otherwise. Widths are logical
pixels at the standard text size and grow with larger text.

#### Trailing column holds So far today and Yesterday
`columns::TRAILING_WIDTH`: The trailing column (So far today, Yesterday).

#### Narrowest leading column that reads well beside trailing one
`columns::LEADING_MINIMUM_WIDTH`: The narrowest leading column (Needs attention, Meetings today) that
still reads well beside the trailing one.

#### Gap applies between columns and between stacked panels
`columns::GAP`: Between the columns, and between panels in a column.

#### Widest page includes side padding; mirrors WorkspaceMetric.todayMaxWidth
`columns::WIDE_PAGE`: The page's widest, side padding included: two columns, or cards that
span the page (`WorkspaceMetric.todayMaxWidth`).

#### Single-column pages use reading width; mirrors todayReadingMaxWidth
`columns::READING_PAGE`: A page whose panels can only form one column
(`WorkspaceMetric.todayReadingMaxWidth`).

#### Factor is column width relative to standard text size
`columns::factor`: How much wider than at the standard text size the columns are.

#### Minimum is measured inside side padding
`columns::two_column_minimum_width`: The narrowest page content, inside its side padding, that shows two
columns.

#### Width excludes side padding; a side without panels means one column
`columns::count`: `width` is the page content inside its side padding. A side with no
panels leaves no gutter: the page is one column.

#### Only-one-column panels keep narrower reading width
`columns::page_maximum_width`: Two columns and the cards that span them use the full width; panels
that can only ever form one column keep the narrower reading width.

#### AppBar mirrors Swift TodayAppBars.Bar
`AppBar`: One app's row in So far today (`TodayAppBars.Bar`).

#### Folded tail has empty label and reads Other
`AppBar.label`: The app as captured; empty for the folded tail, which reads "Other".

#### Fraction is 0 to 1 relative to longest row
`AppBar.fraction`: 0…1, where the longest row is 1.

#### Apps under a minute fold into Other; shares relative to longest row
`app_bars`: The busiest apps with at least a minute each, up to `cap`, then the rest
as one "Other" row (`AppTimePresentation.rows`), each as a share of the
longest row.

#### Summary of open, overdue and remainder; mirrors TodayAttentionSummary
`AttentionSummary`: What Needs attention says about itself (`TodayAttentionSummary`): how
many actions are open, how many of those are overdue, and how many it
leaves to Actions.

#### Footer appears only when Actions holds more than shown rows
`AttentionSummary.shows_footer`: The footer appears only when Actions holds more than the rows shown.

#### One hour window earns top card and accent status
`NEXT_MEETING_WINDOW_SECONDS`: Within this a calendar meeting earns the card at the top of Today, and
its status reads in the accent (`TodayAgenda.nextMeetingWindow`).

#### Agenda line is a recording or an unrecorded calendar event
`Entry`: One line of Meetings today: a recording made today or a calendar event
nothing was recorded for (`TodayAgenda.Entry`).

#### Starting within the hour makes status read in accent
`Entry.is_soon`: Starts within the hour, so its status reads in the accent.

#### Now row separates started meetings from those still ahead
`AgendaRow::Now`: The line between what has started and what is still ahead.

#### A recorded event is listed once and never offered as next
`recorded_event_ids`: The calendar events in `events` some recording is linked to. They are
listed once, as that recording, and never offered again as the next
meeting. Any recording claims its event, a merged source included.

#### Recording storing its calendar event replaces that event, earliest first
`agenda_entries`: Today's recordings and calendar events as one list, earliest first. A
recording that stores its calendar event stands in for that event.

#### At equal start minute, the recording sorts first
`agenda_entries`: At the same minute the recording is the thing that happened.

#### Now line precedes first entry ahead; none if nothing ahead
`agenda_rows`: The list with the now line before the first entry still ahead. A day with
nothing ahead has no line.

#### Hairline only between meetings; now line draws its own rule
`has_hairline_after`: A hairline divides two meetings. The now line draws its own rule, so the
meeting before it has none, and the last row ends at the panel.

#### Card shows meeting under way or within hour, skipping recorded ones
`next_meeting`: The meeting for the card at the top of Today: the one under way, or the
next one once it is within the hour. Events already recorded, and the one
being recorded now, are passed over (`TodayAgenda.nextMeeting`).

#### Recap capped at 220 characters, cut at a word
`RECAP_MAXIMUM_CHARACTERS`: The longest recap line, in characters, before it is cut at a word.

#### Recap is first line under summary heading, no model involved
`recap_line`: One line saying what a recorded meeting was about: the first sentence-like
line under its summary's TL;DR (or Summary, Overview, Recap) heading
(`TodayMeetingRecap.line`). `None` when the summary has no such section.
No model runs for this.

#### Checkbox bullets are actions, excluded from recap
`recap_line`: Checkbox bullets are actions, not a recap.

#### Show At a glance, else first task titles; mirrors TodayDigestHighlights
`highlights_markdown`: The few lines of the day digest that Today shows: its "At a glance", or
the titles of its first tasks when it has none (`TodayDigestHighlights`).

#### Single line under So far today states digest status
`DigestLine`: The one line under So far today that says where the digest stands
(`TodayDigestLine`).

#### Stale means activity arrived after digest; Update rewrites it
`DigestLine::Stale`: Activity arrived after the digest was written; Update rewrites it.

#### Current digest with unknown time shows no footer
`DigestLine::shows_footer`: A current digest with no known time has nothing to say.

#### Page layout mirrors Swift TodayPageLayout
`PageLayout`: What the page is made of (`TodayPageLayout`).

#### Get started stays under day panels until hidden
`PageLayout::Sections`: The day's panels. Get started stays under them until hidden.

#### With nothing to show, Get started steps are the page
`PageLayout::GettingStarted`: Nothing to show yet: the Get started steps are the page.

#### Row mirrors Swift TodayPreparation.Row
`PreparationRow`: One thing to know before joining (`TodayPreparation.Row`).

#### User-owned source is None and displays as You
`PreparationRow.source`: Where it comes from: a meeting title or an owner. An owner who is the
user is `None` here and reads "You".

#### One row per kind; fall back to closest earlier meeting
`preparation_rows`: One row of each kind the evidence holds. A meeting with no decisions,
commitments or projects falls back to the closest earlier meeting
(`TodayPreparation.primaryRows`).

#### More rows are everything past first of each kind
`more_preparation_rows`: Everything past the first of each kind (`TodayPreparation.moreRows`).

#### Template brief shown only when there are no rows
`shows_brief`: A brief the model wrote is always shown. The template brief only restates
the rows, so it is shown when there are no rows to read.

#### Mirrors Swift TodayDreamSelection.PrioritiesSource
`PrioritiesSource`: Whose priorities a brief holds (`TodayDreamSelection.PrioritiesSource`).

#### Older brief named by weekday within a week, else date
`PrioritiesSource::Day`: An older brief's day: its weekday within the last week, its date
beyond that.

#### Only a brief covering yesterday is current
`brief_is_current`: A brief covering yesterday is the current one; anything older is labelled
with its own day (`TodayDreamSelection.isCurrent`).

#### Older briefs labelled with own day so Friday brief never reads current Monday
`priorities_source`: A brief from yesterday earns "Priorities for today"; anything older is
framed with its own day, so a Friday brief on Monday never reads as
current (`TodayDreamSelection.prioritiesSource`).

#### Build times from local day so tests pass in any timezone
`tests::at`: Noon-ish local times on one day, whatever the test machine's zone:
built from the local day so `local_day` agrees.

#### Test date is a Monday, so Friday brief is older
`priorities_are_today_s_for_yesterday_s_brief_and_named_for_older_ones`: a Monday

### `LinuxWindows/crates/lokalbot-app/src/pages/today/panels.rs`

#### Day panels mirror Swift NeedsAttention, Meetings and SoFar sections
Today's day panels: Needs attention (`NeedsAttentionSection`), Meetings
today (`TodayMeetingsSection.swift`) and So far today
(`TodaySoFarSection.swift`).

#### Time column width is at standard text size
`TIME_COLUMN_WIDTH`: The time column of Meetings today, at the standard text size.

#### Name and duration columns scale with text; 100 pt fits Google Chrome
`APP_NAME_WIDTH`: So far today's name and duration columns, which grow with the text size
like the time column. 100 pt fits "Google Chrome".

#### Total font 24 pt on Linux/Windows versus 22 pt on macOS
`TRACKED_TOTAL`: "2h 25m" over the bars (22 pt on macOS).

#### Now label 12 pt versus 11 pt bold on macOS
`NOW_LINE`: "Now · 10:48 AM" (11 pt bold on macOS).

#### Urgent open actions overdue first; no panel when none
`TodayPage::render_attention`: The most urgent of the user's open actions, overdue first, with how
many are overdue and how many more wait in Actions. Nothing to act on
means no panel at all.

#### Meetings panel merges recordings with recaps and calendar; sessions on Timeline
`TodayPage::render_meetings`: The day's meetings as one panel: what was recorded, with a line saying
what it was about, and what the calendar still holds, with a line at
now. Work sessions and apps are on Timeline.

#### Now rule replaces header hairline above first meeting
`TodayPage::render_meetings`: The rule above the words; above the first meeting it
takes the place of the header's hairline.

#### Connect Calendar opens switch if off, else calendar links
`TodayPage::render_meetings`: Calendar use and its sources are set up in
Settings: the switch while it is off, else the
calendar links it reads.

#### Recordings open on click; calendar events do not
`TodayPage::meeting_row`: One meeting: its time, title and where it stands, with the recap line
under a recorded one. A recording opens; a calendar event does not.

#### So far today shows total, app bars, highlights, digest footer; rest on Timeline
`TodayPage::render_so_far`: The day up to now: the tracked total, a bar per app, the digest's
highlights, and a footer saying where the digest stands, with Update
when there is newer activity. Sessions, tasks and the full digest are
on Timeline.

#### App bar is decorative; name and time carry the information
`TodayPage::render_so_far`: The name and the time say everything; the bar only
shows it, growing from the leading edge.

### `LinuxWindows/crates/lokalbot-app/src/pages/today/upcoming.rs`

#### Next-meeting card mirrors Swift TodayNextMeetingCard; calendar setup stays in Settings
The meeting that starts within the hour, at the top of Today
(`TodayNextMeetingCard` in `UpcomingMeetingView.swift`): when it is, who
is in it, Join and Record, and what to know before joining. Calendar setup
and access stay in Settings.

#### Preparation refreshes every five minutes and on library change
`PREPARATION_REFRESH`: Preparation is gathered again this often, and whenever the library changes.

#### Preparation open by default; folds while another meeting records
`UpcomingState.preparation_choice`: The reader's own choice for "Before you join". Without one it is open,
and folds to a count while another meeting is being recorded.

#### Choice forgotten when event or recording state changes
`UpcomingState.seen`: What the choice above was made for: the event and whether a meeting
was being recorded. A change of either forgets it.

#### Request evidence on event change, library change, every few minutes
`UpcomingState::sync`: Follows the card's event: forgets choices made for another event or
recording state, and asks the engine for the event's evidence when it
changes, when the library changes, and every few minutes.

#### Solo linkless event may not be a call; Record leaves card while recording
`TodayPage::render_next_meeting`: A solo event without a link may not be a call at all; the toolbar's
Record is still there for it. Record leaves the card while
something else is being recorded: the live card holds the only Stop.

#### Show model brief or none-else; one row per evidence kind
`TodayPage::preparation`: "Before you join": the brief when the model wrote one (or when there is
nothing else), and one row of each kind of evidence, the rest a click
away.

#### Model brief on request; needs local Think model, may load it
`TodayPage::brief_control`: The model's brief is on request: it may load the Think model, and the
engine writes it only with a Think model on this computer.

#### Engine's two fixed error messages are translated into interface language
`translated_error`: The engine reports these two fixed messages; show them in the interface language.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
