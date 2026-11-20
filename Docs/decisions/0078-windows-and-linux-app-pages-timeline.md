# 0078. Windows and Linux: app — pages / timeline

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/pages/timeline/`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/agent_work.rs`

#### Recorded actions come from commands run; agent's own report omitted as a claim
How a day's coding-agent work reads on Timeline (`TimelineAgentTaskRow`,
`TimelineOutcomeText`, `DayActivityOverview.projectRows`). Recorded actions
come from the commands the agent ran; its own report is left out because it
is only a claim.

#### Count phrases are whole strings so each language can word them
`counted`: A whole count phrase, so each language can word it.

#### Scheduled runs are excluded from day outcomes, as in sessions
`day_outcomes`: What the day's agents recorded, scheduled runs left out like in the sessions.

#### At most three pull requests are shown per session
`links`: The pull requests a session linked, at most three, as "repository #number".

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/context.rs`

#### Main area shows session, meeting, raw activity, block or moment panels
Timeline's main area when something other than the day is chosen in the
rail (`TimelineContextPanel`): a work session, a meeting's short preview,
all captured activity, or one activity block or screen moment opened from
those. Each is a title panel, then one panel per section it has; "‹ Day
digest" above goes back.

#### Back link shows only the destination name as visible text
`TimelinePage::back_link`: The way back from a page opened inside another: an activity block to
its session, a moment to its activity. The destination alone is the
visible text.

#### Opening a title row lists the activity behind it
`TimelinePage::what_was_open`: The windows and documents the session had open, with their time.
Opening a row lists the activity behind the title, which stays
inspectable.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/day_list.rs`

#### Day list is display-only and mirrors the Swift Timeline files
What Timeline shows for one day, without drawing it: the rail's sessions
and meetings under Morning, Afternoon and Evening with Away gaps
(`TimelineDayList.swift`), the hour strip (`TimelineDayStrip.swift`), what
the arrow keys walk (`TimelineListSelection`), the rail's opening width
(`TimelineRailMetric`), the day's actions panel (`TimelineDayActions`) and
the digest's state (`TodayDigestLine`, `TimelineDigestPreview`).

Display only: nothing here is stored. A call app's session that folds into
its meeting keeps its activity in All captured activity.

#### Gap of this length with no recording becomes an Away line
`MINIMUM_GAP_SECONDS`: A stretch this long with nothing recorded gets its own "Away" line.

#### Call-app session folds into a meeting covering 60% of it
`FOLD_SHARE`: A call app's session folds into a meeting that covers this much of it.

#### Morning is before noon, afternoon before five, evening the rest
`Part`: Before noon, before five, and the rest of the day.

#### Returns the heading's localization catalog key
`Part::title`: The heading's catalog key.

#### Work row id is the WorkSession id
`RowKind::Work`: A work session, by `WorkSession::id`.

#### Second line shows project and outputs, apps, or Meeting with app; empty when title suffices
`Row.detail`: The second line: project and what was produced, or the apps, for
work; "Meeting · app" for a meeting. Empty when the title says it all.

#### Duration is a session's active time or a meeting's length, in seconds
`Row.duration`: A session's active time; a meeting's length, in seconds.

#### Colour key is project, else busiest app; None means other activity; meetings keep own tone
`Row.color_key`: What colours a session's dot and its bar: its project, or its busiest
app on a day without projects. `None` reads as other activity.
Meetings keep their own tone.

#### Title listing only apps renders quieter than one naming work
`Row.quiet`: A title that only lists apps reads quieter than one that names work.

#### Recorded meetings come from meetings, not sessions; blocks give apps; project colours flag
`DayList::new`: `sessions` are the day's sessions; recorded meetings among them are
left out and come from `meetings`. `blocks` are the day's activity,
for which apps a session used. `uses_project_colors`: the day's time
is split by project, so a session without one reads as other activity.

#### A meeting sorts before a session that starts at the same time
`DayList::new`: A meeting leads a session that starts with it.

#### Away gap closes the part of day where it began
`DayList::new`: The gap closes the part of the day it began in, as the list reads.

#### Folded call session is skipped; its time shows as the meeting row
`DayList::new`: A folded call is recorded time, shown as its meeting's row.

#### A session is shown by its own row or the meeting it folded into
`DayList::row_showing`: The row that shows a session: its own, or the meeting it folded into.

#### Old digest time ranges open the session they overlap most
`DayList::work_row_in_time_range`: The session a digest task's "09:00–10:30" covers most, so an older
digest's time range can open that session.

#### A range ending before it starts runs past midnight and is clipped to the day
`interval_from_time_range`: "09:00–10:30" on `day`. A range that ends before it starts runs past
midnight and is clipped to the day.

#### Project a session's title names supplies its colour
`session_project`: The project a session's title names, the one whose colour it takes.

#### Session title is 'projects · task'; without a task it is projects alone
`project_and_task`: A project session's title is "projects · task"; without a task it is the
projects alone.

#### Apps used under a minute are dropped unless none would remain
`used_apps`: Apps used for at least a minute, busiest first. Apps glanced at for
seconds are left out, unless that leaves none.

#### Project sessions lead with task; others lead with window then apps; app-only is one quiet line
`work_text`: A session's two lines. With a project the task leads and the project
moves to the second line beside what the agents produced. Without one,
the window that named the session leads and its apps follow. A session
only its apps describe is one quiet line.

#### Detail reads Meeting · app, or Recording · app while live
`meeting_detail`: "Meeting · Zoom", or "Recording · Zoom" while it is being recorded.

#### Session folds into meeting covering at least FOLD_SHARE; project and agent sessions never fold
`meeting_covering`: The meeting a call-app session belongs to: the one that covers most of
it, when that is at least `FOLD_SHARE`. Work with a project and agent
sessions never fold.

#### Sampler app names and meeting app names differ, so match by containment
`is_same_app`: The sampler stores an app's own name ("zoom.us", "Microsoft Teams") and
a meeting the name LokalBot gives its call app ("Zoom", "Teams"), so one
may contain the other.

#### Selection is the day page, a row, raw activity, or none opened elsewhere
`ListSelection`: What Timeline's main area shows: the day's page (`Digest`, with no row
chosen in the rail), a session or meeting row, or all captured activity.
`None` is something opened from elsewhere that belongs to no row.

#### Arrow-key order: day page, rows, then All captured activity
`ListSelection::order`: The rail from top to bottom, for the arrow keys. The day's page
stands before the first session; All captured activity, the rail's
bottom row, follows the last one.

#### Steps clamp at ends; unknown selection lands on the day page
`ListSelection::moved`: The selection `step` rows away, stopping at either end. From a
selection the rail does not show, any step lands on the day's page.

#### Bar positions are fractions 0 to 1 across the strip
`Bar`: One bar of the strip: the row it selects, where it starts and ends (0 at
the leading edge, 1 at the trailing one) and what colours it.

#### First hour and noon show AM or PM where the clock has them
`Tick.names_day_period`: The first hour and noon say AM or PM where the clock has them.

#### Meetings sit in a lane above work; positions span whole hours
`DayStrip`: The rail's hour strip: hours left to right, meetings in a lane above
work. Positions are fractions of a span of whole hours inside the day.

#### One tick per hour from first hour to last inside the span
`DayStrip.ticks`: One per hour, from the first hour to the last one inside the span.

#### Returns None when no rows fall inside the day bounds
`DayStrip::new`: `None` for a day with no rows inside `[day_start, day_end)`.

#### Span end on the hour adds no extra hour; otherwise rounds up
`DayStrip::new`: An end on the hour needs no extra hour; any other rounds up.

#### Thin labels to every second or third hour, keeping the first
`DayStrip::labelled_ticks`: The ticks that get a label when only `count` labels fit: every
second or third hour on a long day, always starting with the first.

#### Short bars keep a minimum width and stay inside the lane
`bar_frame`: A bar's place in a lane `width` wide. A short bar keeps `minimum` so it
can be seen, and never leaves the lane.

#### Click target widens to 12 around a thin bar, kept in lane
`bar_hit_frame`: Where a click counts for a bar: its own place, widened to 12 around its
middle when it is drawn thinner, and kept inside the lane.

#### Draw longest bars first so short bars' hit areas overlay neighbours
`hit_order`: Bars in the order to draw them: the longest first, so a short bar's
widened click area lies over its longer neighbour's edge.

#### Rail width in a roomy window
`RAIL_IDEAL_WIDTH`: The rail in a roomy window.

#### Rail width in the default window
`RAIL_MINIMUM_WIDTH`: The rail in the default window.

#### Rail takes 30% of body between minimum and ideal widths
`RAIL_SHARE`: The rail's share of the body while it is between those two.

#### Narrowest rail still fits a time, short title and duration
`RAIL_FLOOR_WIDTH`: The narrowest the rail gets: a time, a short title and a duration fit.

#### Widest width the divider can drag the rail to
`RAIL_MAXIMUM_WIDTH`: The widest the divider drags it.

#### Day page keeps the minimum width every detail pane has
`PAGE_MINIMUM_WIDTH`: The day's page keeps the minimum every detail pane has.

#### Opening rail width is a text-scaled share, leaving the page its minimum
`rail_width`: The rail's opening width in a body `available` wide, until the divider
is dragged: a share of the body between its two sizes, both grown with
the text size, and never so wide that the page drops under its minimum.

#### Day's user actions from meetings, done included, open first in index order
`day_threads`: The user's actions that a meeting of `day` mentioned, done ones
included: open work first, then the rest, each in the index's order.

#### None open but some deferred rather than done
`ActionsSummary::NoneOpen`: Nothing is open, and some are deferred rather than done.

#### Pill says N open or All done; deferred-only days say 0 open
`actions_pill`: "2 open" while anything is; "All done" once every action is done.
Deferred actions are neither, so a day with only those says "0 open".

#### Rows stay after the last action is ticked so the list does not vanish
`actions_show_rows`: The panel lists its actions while one is open. Once none is, it is a
header alone, except that rows the reader was just shown stay, so
ticking the last one does not take the list away.

#### Mirrors TodayDigestLine for where the day's digest stands
`DigestLine`: Where the day's digest stands (`TodayDigestLine`).

#### Digest being written by hand or on schedule
`DigestLine::Writing`: A digest is being written, by hand or on schedule.

#### New activity after the digest was written; Update rewrites it
`DigestLine::Stale`: Activity arrived after the digest was written; Update rewrites it.

#### Footer shows written time, Update when stale, progress while writing
`DigestLine::shows_footer`: The Highlights panel's footer: when the digest was written, Update
once it is stale, progress while it is rewritten.

#### Menu item names its action; digest is never rewritten unasked
`digest_menu_title`: The catalog key of the … menu item that writes the digest. It names what
choosing it will do; a digest is never rewritten without being asked.

#### 15 of 40 minutes is under share; other app never folds
`a_call_folds_only_when_the_meeting_covers_most_of_it`: 15 of 40 minutes is under the share; another app never folds.

#### Very short names like Go must not match Google Meet
`apps_match_when_one_name_contains_the_other`: Too short to tell apart.

#### Overlapping session means gap starts at latest end, 11:00
`rows_fall_under_morning_afternoon_and_evening_with_away_gaps`: 9:30–11:00 overlaps, so the gap starts at 11:00, not 10:00.

#### Widest rail must still fit beside the page in default window
`the_rail_opens_between_its_two_widths_and_leaves_the_page_its_minimum`: The widest rail fits beside the page in the default window.

#### First digest being written has no footer; the body says so
`the_digest_line_and_menu_name_what_happens_next`: The first digest being written has no footer: the body says so.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/day_page.rs`

#### Day page mirrors TimelineDigestPage with Highlights, actions, work, decisions panels
The day's page, Timeline's main area while nothing is chosen in the rail
(`TimelineDigestPage.swift`): Highlights, the actions from the day's
meetings, the work summary and the decisions, each on its own panel.

#### Older digest time ranges open the session they cover
`TimelinePage day page`: An older digest's "09:00–10:30" opens the session it covers.

#### Footer shows written time and Update when stale; missing or writing states say so
`TimelinePage::highlights_panel`: The digest's highlights as the page's first panel. Its footer says
when the digest was written and offers Update once there is newer
activity. A day without a digest, and one being written, say so here.

#### Digest time alone on its day, with date when written later
`TimelinePage::written`: "Digest written 6:02 PM": the time alone on the day itself, the date
too once it was written later.

#### Shared action rows under open-count header; none open shows All done
`TimelinePage::day_actions_panel`: The user's actions from the day's meetings, as the shared action rows
under a header that counts the open ones and leads to Actions. With
none open the panel is its header, "All done".

#### Panel title may take two lines beside badge and link
`TimelinePage::day_actions_panel`: The longest panel title on the page, beside a badge and a link.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/inspect.rs`

#### Thumbnails are decrypted in memory only and released with the day
Looking closer at a day: the session's moments with Find and an app filter
(`SessionMomentBrowser.swift`), one activity block with its related moments
(`activityPreview`), and the hour-indexed day track (`CaptureTrackView`).
Thumbnails are decrypted in memory only and released with the day.

#### Only 32 decrypted thumbnails per day; later rows show an icon
`MAX_THUMBNAILS`: Decrypted thumbnails kept for a day; later rows show an icon instead.

#### Released thumbnail textures are freed on the next frame
`TimelinePage::release_thumbnails`: Forgets the day's thumbnails; their textures are freed on the next frame.

#### Moment row mirrors relatedMomentRow: thumbnail, subject, time
`TimelinePage::moment_row`: A moment's row: thumbnail, what it shows, when (`relatedMomentRow`).

#### Session moments searchable by window, document, retained text, app
`TimelinePage::render_moment_browser`: Every moment of the session, findable by window, document or retained
text, and by app (`SessionMomentBrowser`). "Show all N" in the Screen
moments panel opens it.

#### Block preview shows app day figures then moments kept during it
`TimelinePage::render_block`: One activity block (`activityPreview`): its app, time and title with
the app's day in two figures, then the moments kept during it.

#### Meetings get own lane so they never hide overlapping activity
`TimelinePage::render_track`: The day on an hour-indexed track, with meetings in a lane of their own
so they never hide the activity they overlap (`CaptureTrackView`).

#### Session scenes are moments spaced evenly across its scenes
`TimelinePage::session_scenes`: Representative moments of a session, spaced evenly across its scenes.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/mod.rs`

#### Timeline layout mirrors the Mac: toolbar, day page panels, resizable remembered rail
Timeline: one day at a time (`CaptureView.swift`'s `TimelineContentView`).
The date is the toolbar's title and opens a calendar; arrows, Ask about
this day and one … menu sit at the trailing edge. The day's page fills the
main area as panels (Highlights, the actions from the day's meetings, the
work summary, decisions); a rail on the trailing side, a pane whose width
the divider changes and the app remembers, holds the tracked time with its
hour strip, the day's sessions and meetings, and All captured activity.
Choosing something in the rail shows its page as panels while the rail
stays (`TimelineRail.swift`, `TimelineDigestPage.swift`,
`CaptureDetailView.swift`, `ScreenMomentDetailView.swift`).

#### Rail divider position stored with other panes' widths
`RAIL_PANE_KEY`: The rail's divider position, kept with the other panes' (`pane_widths`).

#### Widest page panels, excluding gutters; mirrors TimelinePageMetric
`PAGE_MAXIMUM_WIDTH`: The page's panels, widest, without its gutters (`TimelinePageMetric`).

#### One day's data is loaded off the main thread
`DayModel`: One day's data, loaded off the main thread.

#### Looks done? suggestions keyed by thread
`DayModel.hints`: "Looks done?" suggestions, by thread.

#### A day with expired captures can still have a digest
`DayModel::has_day`: A day whose captures have expired can still have its digest.

#### None selection means the day's page
`TimelinePage.selection`: What the main area shows; `None` is the day's page.

#### Trail is what Back returns to, nearest last
`TimelinePage.selection_trail`: What Back returns to, nearest last ("Back to work session").

#### None thumbnail entry means still decrypting
`TimelinePage.thumbnails`: The day's small moment images: `None` while one is being decrypted.

#### Rows stay visible after the last open action is ticked
`TimelinePage.actions_had_open`: An action was open while this day's page showed, so its rows stay
after the last one is ticked.

#### Rail receives Up and Down arrow keys
`TimelinePage.rail_focus`: The rail takes Up and Down.

#### Row scrolls into view next frame after strip bar or arrow choice
`TimelinePage.rail_reveal`: A row to scroll into view on the next frame (a strip bar or an arrow key chose it).

#### Unshown images' textures are freed on the next frame
`TimelinePage.released_images`: Images no longer shown; their textures are freed on the next frame.

#### Changing day always returns to the day's page
`TimelinePage::set_day`: Changing the day always returns to its page.

#### Done suggestions only from text kept with consent
`TimelinePage::load_day`: Suggestions only, and only from text kept with consent.

#### Child selection pushes the parent onto trail so Back returns
`TimelinePage::open_child`: Opens something inside the current selection, so Back returns to it.

#### Choosing the current selection again returns to the day's page
`TimelinePage::select`: Shows `selection` in the main area; choosing what it shows again
returns to the day's page.

#### Rail highlights the root row or raw activity the page came from
`TimelinePage::list_selection`: What the rail shows as chosen: the row or All captured activity that
the main area's page came from.

#### Choosing the chosen target toggles back to the day page
`TimelinePage::choose`: Chooses a row of the rail, All captured activity or the day's page.
Choosing what is already chosen returns to the day's page
(`TimelineSelection.select`).

#### Clear selection first so a nested selection does not toggle off
`TimelinePage::choose`: A selection opened inside another must not toggle off against it.

#### Session question is bounded to its moments that day; one moment attaches alone
`TimelinePage::ask_session`: Ask about one work session, bounded to its moments on its day. A single
moment is attached instead, as "Ask About This…" does.

#### Title shows weekday and date, with year when not this year
`TimelinePage::day_title`: "Thursday, November 12", with the year for a day outside this one.

#### Some locales' own date already names the weekday
`TimelinePage::day_title`: Some locales' own date already names the weekday.

#### Menu holds digest actions, copy and export, day memory pause, reload
`TimelinePage::day_menu`: The … menu: write, update or rewrite the digest, copy or export it,
pause or resume day memory, and reload the day (`TimelineDayMenu`).

#### Shared page column fills width inside gutters up to a maximum
`TimelinePage::page_column`: The column every page in the main area shares: panels that fill the
width inside their gutters, up to the widest line
(`TimelinePageColumn`).

#### Day digest link returns from a session, meeting or raw capture
`TimelinePage::digest_link`: "‹ Day digest": from a session, a meeting or all captured activity
back to the day's page (`TimelineDigestLink`).

#### Link sits slightly nearer its panel than panels sit to each other
`TimelinePage::digest_link`: Sits a little nearer the panel it leads to than panels sit to
each other.

#### Empty day state mirrors TimelineEmptyDay
`TimelinePage::render_empty_day`: A day with nothing recorded and no digest (`TimelineEmptyDay`).

#### Pause shows at once like tray menu and sends same engine request
`set_day_memory_paused`: Pauses or resumes day memory, and shows it at once, as the tray menu
does; the engine gets the same request either way.

#### Date opens calendar beside Today or Yesterday; Back first when opened from search
`TimelinePage::title_control`: The date, opening a calendar, with "Today" or "Yesterday" beside it;
Back first when the day was opened from a search or an answer.

#### Capture Screen Now button exists only on this port, while capture is on
`TimelinePage::toolbar`: Port-only: a capture of the next window, while capture is on.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/moment.rs`

#### Moment detail mirrors ScreenMomentDetailView; image decrypted in memory
One captured screen moment (`ScreenMomentDetailView.swift`): its image
(decrypted in memory, or why it cannot be shown), the window title and
captured text, Save Moment and Ask About This, the saved note, capture
details, and Delete Moment.

#### Inspector image longest side is 960 pixels
`THUMBNAIL_PIXELS`: The inspector's image: longest side in pixels.

#### None means the image is still decrypting
`MomentImage.image`: `None` while it is being decrypted.

#### Image decrypts off the UI thread
`TimelinePage::load_moment_image`: Decrypts the selected moment's image off the UI thread.

#### Released image's texture is freed on the next frame
`TimelinePage::release_moment_image`: Forgets the inspector's image; its texture is freed on the next frame.

#### Capture trigger label matches the Mac: app_switch becomes App Switch
`trigger_label`: "app_switch" → "App Switch", as the Mac shows `capture_trigger`.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/rail.rs`

#### Rail layout mirrors TimelineRail with pinned All captured activity row
Timeline's rail, on the trailing side of the day's page
(`TimelineRail.swift`): the paused line, the tracked total with the hour
strip and its legend, then the day's sessions and meetings in time order
under Morning, Afternoon and Evening, with All captured activity pinned
as its bottom row. Choosing a row, or a bar of the strip, shows it on the
page beside; choosing it again returns to the day.

#### Rail edge to text matches the panels' own inset
`INSET`: From the rail's edge to its text, the panels' own inset.

#### Row padding before time; AXIS_WIDTH is the dot column
`ROW_LEADING`: The row's padding before its time, and the column the dots sit in.

#### Rows inset from rail edges so selection floats
`ROW_MARGIN`: Rows sit this far in from the rail's edges, so their selection floats.

#### Title and detail line heights; dot centre offset from row top
`TITLE_LINE`: A row's title and second line, and from its top to the centre of its dot.

#### Strip lanes: meetings above, work below, then hour labels
`MEETING_LANE_HEIGHT`: The strip's lanes: meetings above, work below, then the hour labels.

#### One hour label per 44 points keeps 12 PM clear of neighbours
`LABEL_WIDTH`: About one hour label every 44 points keeps "12 PM" clear of its neighbours.

#### Rail time drops AM/PM on 12-hour clocks since parts name the period
`list_clock`: A rail row's time: "9:10" on a 12-hour clock, without AM or PM (the list
is under Morning, Afternoon and Evening), the locale's own form otherwise.

#### AM/PM on first hour and noon only; 24-hour clocks show hour
`hour_label`: "9 AM" for the first hour and noon, "10" for the rest; a 24-hour clock
shows the hour either way.

#### Project or app own colour; neutral for other activity
`key_color`: A colour key's colour: a project's or app's own, neutral for other activity.

#### Tracked block omitted on days with no tracked time or meetings
`TimelinePage::tracked_block`: The day's total in large type, the meetings and what the agents
recorded, the hour strip, and where the time went as rows. Left out
on a day with no tracked time and no meetings.

#### Legend splits by project when agents name them, else by app
`TimelinePage::tracked_block`: By project when the day's agents name them, else by app.

#### Hours run left to right in every language, like a clock
`TimelinePage::day_strip`: The day strip: hour lines and labels, a thin lane of meetings above
the lane of work. A bar chooses its row in the list under it. Hours
run left to right in every language, like a clock's day.

#### Every entry is a direct child so a chosen row can scroll into view
`TimelinePage::session_rows`: The sessions and meetings under their part of the day, every entry a
direct child so a chosen row can be scrolled into view.

#### One spine line joins neighbouring dots, first dot to last
`TimelinePage::session_row`: One line runs through the dots of neighbouring rows, so the list
reads as a day. It starts at the first dot and ends at the last.

#### Time's side gets the small inset in either text direction
`TimelinePage::session_row`: The time's side gets the small inset, in either direction.

#### Each count uses its own catalog entry for pluralization
`capture_counts`: "3 activity entries · 0 screen moments", each count its own catalog entry.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/range_delete.rs`

#### Range deletion snaps to scenes and lists exactly what goes before deleting
Deletes the screen captures retained in a time range of one day
(`CaptureRangeDeletionView.swift`). Times snap to captured scenes, and a
review lists exactly what will be removed before anything is deleted.

#### Deletion interval is first.ts to last.ts plus 1 ms, as on Mac
`RangeDeletion::interval`: `[first.ts, last.ts + 1 ms)` (`ScreenRewindSequence.deletionInterval`).

#### Toggle keeps its name while open; absent when nothing is kept
`TimelinePage::range_deletion_toggle`: "Delete screen moments…": a toggle, so it keeps its name while the
range controls are open and reads as on. `None` with nothing kept.

#### Nothing deletes before the review lists what goes
`TimelinePage::render_range_deletion`: The range to delete while the toggle is on. Nothing is deleted before
the review lists what goes.

#### Clamp range because moments can shrink under an open range
`TimelinePage::render_range_deletion`: The moments can shrink under an open range.

#### Failures stay on screen with undeleted moments still present
`TimelinePage::range_deleted`: Failures stay on screen, with the moments that didn't go still there.

### `LinuxWindows/crates/lokalbot-app/src/pages/timeline/work_summary.rs`

#### Statused tasks group by Blocked, In progress, rest, folded Done; older digests list entries
The day's work and decisions as panels on Timeline's page
(`DayDigestView` in its timeline mode). A digest that gives its tasks a
status groups them: Blocked and In progress in full where a task has a
next step, the rest of the open work as one-line rows, and finished work
folded into a single Done line across the panel. An older digest lists
its entries.

#### Toggle key is a task index or one of the reserved keys
`TaskToggle`: Toggles a task's details by index, or one of the keys below.

#### Reserved toggle keys above task indices for follow-ups, show-more, done
`FOLLOW_UP_KEY`: Toggle keys past the task indices: follow-up rows, a group's "Show N
more" (plus the group's status), and the Done line.

#### Status column plus gap; details align to it
`TASK_TEXT_INSET`: The status column of a task row plus its gap; details align to it.

#### Blockers lead the work because they stop open tasks
`blockers_callout`: Blockers lead the work: they are what stops the day's open tasks.

#### Long lists show first rows until the rest is requested
`brief_list`: One-line rows for open tasks without a next step. A long list shows its
first rows until asked for the rest.

#### Finished tasks fold into one line naming them; opening lists each
`done_section`: Finished tasks fold into one line across the panel that names them;
opening it lists each.

#### Footer strip fill keeps supporting colour above 4.5:1 contrast
`done_section`: The footer strip's fill: the supporting colour stays above
4.5:1 on it.

#### Task without next step is one line; detail opens in place
`brief_row`: One line for a task without a next step; what was done opens in place.

#### Cited screens open on Timeline, mirroring DayDigestSourceLinks
`source_links`: The screens a task cites, each opening on Timeline (`DayDigestSourceLinks`).

#### Older digest time ranges open the session they cover
`task_row`: Status mark, title with its time range and tag, the "Next" step and the
details. An older digest's "09:00–10:30" opens the session it covers.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
