# 0095. Windows and Linux: core — timeline

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-core/src/timeline.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-core/src/timeline.rs`

#### Timeline module mirrors TimelineWorkSession.swift and DayActivityProjection.swift
Day memory reads and writes: activity blocks, screen moments, work
sessions and Timeline's session rail (`TimelineWorkSession.swift`), and
the per-day projection Today and Timeline share
(`DayActivityProjection.swift`).

#### Blocks at most 5 minutes apart belong to one session
`SESSION_MAXIMUM_GAP_SECONDS`: Consecutive blocks at most this far apart belong to one session.

#### A 45-minute session starts a new one at next non-overlapping block
`SESSION_MAXIMUM_DURATION_SECONDS`: A session this long starts a new one at the next non-overlapping block.

#### Work on another project for 10 minutes starts a session
`PROJECT_SWITCH_SECONDS`: Work that moves to another project for this long starts a session.

#### A project names the session at 20% of its time
`PROJECT_TITLE_SHARE`: A project names the session once it holds this share of its time.

#### Burst overlapping no session joins nearest one within 15 minutes
`BURST_ATTACH_SECONDS`: A burst that overlaps no session joins the nearest one this close.

#### First five are the macOS list; the rest are Linux and Windows equivalents
`SYSTEM_APPS`: Shell, lock-screen and login processes that are never "work". The first
five are the macOS list; the rest are their Linux and Windows equivalents.

#### Trailing title segments that are browser chrome, not page content
`BROWSER_CHROME_MARKERS`: Trailing title segments that are browser chrome, not page content.

#### Strip browser chrome segments like audio playing and browser name from titles
`strip_browser_chrome`: "Page - Audio playing - Google Chrome" → "Page"; "Page — Mozilla Firefox" → "Page".

#### Linux and Windows titles end with the app name; macOS titles do not
`strip_app_suffix`: "Brief.odt - LibreOffice Writer" → "Brief.odt" when the app is
"LibreOffice Writer". Linux and Windows window titles usually end with the
app's name, which macOS titles do not.

#### Grouping title is None for generic or app-named titles
`cleaned_title`: The grouping title of a block, or `None` for generic or app-named titles.

#### Union length of block intervals, in seconds
`merged_duration`: Union length of the blocks' intervals, in seconds.

#### Block time per project, empty without agent evidence
`Titled.shares`: The block's time per project, empty without agent evidence.

#### Sessions drop system apps, merge 5-minute gaps, split at 45 minutes or sustained new title
`activity_sessions`: App activity grouped into human-scale sessions (`TimelineWorkSession.sessions`):
system apps dropped, gaps of at most 5 minutes merged, a new session after
45 minutes or when a sustained unseen title appears after 10 minutes.

#### With agent evidence, sessions end at project moves and take project names
`attributed_sessions`: With coding-agent evidence, sessions end where the work moves to another
project instead of at a fixed length, and take their names from the project
and its agents' tasks.

#### Ranked shares so each block's first share is its project
`attributed_sessions`: Ranked shares, so each block's first share is its project.

#### Cut at gaps, after 45 minutes, and when a new document holds attention
`app_groups`: Cuts at gaps, after 45 minutes, and where a new document holds attention
for a while.

#### Short tool switches stay together; sustained unseen document after 10 minutes is a boundary
`app_groups`: Short tool switches stay together; a sustained, unseen document
after ten minutes is a boundary. Overlapping blocks never split.

#### Cut where work moves project for 10 minutes; unclaimed stretches fall back to app rules
`project_groups`: Cuts at gaps and where the work moves to another project for at least ten
minutes. A brief look elsewhere stays inside the session, and a project
session has no length limit. A stretch too short to stand on its own joins
the work that follows it. Stretches no project claims, such as reading or
chat, fall back to the app rules.

#### Track time each other project held since current project was last seen
`project_groups`: Time each other project (or none) has held since the current one was
last seen, and the index where that run began.

#### Cut only at an edge no earlier block still runs across
`project_groups`: Wait for an edge no earlier block still runs across.

#### A stretch too short to stand alone joins the new project's session
`project_groups`: A stretch too short to stand alone joins the new project's.

#### Cut index never splits overlapping activity
`cut_index`: The first index at or after `from` where no earlier block is still running,
so a cut never splits overlapping activity.

#### Burst goes to the session it overlaps most, else the nearest
`assign_agent_work`: Lists each burst under the session it overlaps most, or the nearest one when
the agent worked between sessions, then names project sessions after the
task their agents worked on.

#### Name session by busiest project and task, plus a second fair-share project
`name_after_project`: "bizstats · Rehearse the audit runbook on staging": the busiest project,
then the task of its burst that overlaps the session most. A second project
that also holds a fair share is named too, as in "bizstats, alpha · …", so a
review in the browser beside agent work is not lost.

#### Session time per project, busiest first
`project_shares`: The session's time per project, busiest first.

#### Titles ranked by own active time; ties keep first appearance
`make_session`: Titles ranked by their own active time; ties keep first appearance.

#### Apps glanced at for seconds stay in apps but do not inflate title count
`make_session`: Apps glanced at for seconds (a password prompt, a notification) stay in
`apps` but don't inflate the title's count.

#### Title shows two busiest apps then a count of the rest
`app_summary`: "Claude", "Claude, Firefox" or "Claude, Firefox +2": the two busiest
apps, then how many more (`TimelineWorkSession.appSummary`).

#### Unrecorded stretches of 30 minutes or more get an Away row
`AWAY_MINIMUM_GAP_SECONDS`: Stretches with nothing recorded at least this long get an "Away" row.

#### Timeline rail row is a session, meeting or long gap
`RailRow`: A row of Timeline's session rail (`TimelineRailRow`): a session or
meeting by its index in the day's sessions, or a long stretch with no
recorded activity between them.

#### Gap starts at latest end seen because sessions overlap
`rail_rows`: The rail for `sessions`, ordered by start as `work_sessions` returns
them, with an away row wherever nothing was recorded for at least
`minimum_gap_seconds`. Sessions overlap (a meeting runs over the work
beside it), so a gap starts at the latest end seen so far.

#### Meeting end on the timeline mirrors CaptureTrackItem.meetingEnd
`meeting_end`: When a meeting item ends on the timeline (`CaptureTrackItem.meetingEnd`).

#### Sessions and meetings interleaved by start; meeting sessions have meeting_id set
`work_sessions`: Work sessions from `blocks` interleaved with `meetings`, by start
(`TimelineDayItem.items`). Meeting sessions have `meeting_id` set.

#### Blocks clipped to the half-open range with system apps removed
`clip_blocks`: Blocks clipped to `[start, end)`, system apps removed.

#### Per-app union time, longest first
`app_usage`: Per-app union time, longest first.

#### Text read via ocr_metadata, else ocr_fts scan for libraries never migrated
`screen_columns`: Columns for `screen_moment_from_row`. The text comes through the
`ocr_metadata` index when present, else by scanning `ocr_fts` (libraries
opened read-only before the app ever migrated them).

#### Read-only libraries may predate the similarity_group column
`screen_columns`: Libraries opened read-only may predate the column.

#### Adjacent captures in one similarity group collapse; newest represents the scene
`rewind_frames`: Oldest-first visual scenes (`ScreenRewindSequence.frames`): adjacent
captures in one persisted similarity group collapse into one, and the
newest of them stands for the scene.

#### Evenly spaced items at most limit, always keeping first and last
`representative`: At most `limit` items, spaced evenly and always keeping the first and last
(`CaptureModel.representativeFrames`).

#### Query matches window title, document name and retained text
`moments_matching`: A session's moments that match an app and a query, which looks in the
window title, the document name and any retained text
(`SessionMomentBrowser.filtered`).

#### Path empty for text-only captures; text empty when none kept
`NewScreenMoment`: A screen moment to store (`ActivityStore.insertScreenshot`). `path` is
empty for text-only captures; `text` empty when none was kept.

#### Allowed capture trigger values
`NewScreenMoment.trigger`: `app_switch`, `window_change`, `click`, `typing_pause`, `scroll_settled`,
`clipboard_change`, `interval` or `manual`.

#### Text source values, with _redacted suffix when redacted
`NewScreenMoment.text_source`: `accessibility`, `ocr` or `hybrid`, with `_redacted` when redacted.

#### Saving again keeps creation time; saved moments are exempt from retention
`Library.save_moment`: Saves (or re-notes) a moment; saving again keeps its creation time.
Saved moments are exempt from retention.

#### Unsaving removes the bookmark but the capture stays
`Library.unsave_moment`: Removes a saved moment's bookmark (the capture itself stays).

#### Saved moments are evidence: digest stays but is marked out of date
`Library.with_moment_revision`: Saved moments are evidence: a digest stays but is marked out of date.

#### Returns overlapping blocks unclipped, oldest first
`Library.activity_blocks`: Blocks overlapping `[start, end)`, oldest first, unclipped.

#### Moments oldest first with kept text and saved note
`Library.screen_moments`: Captured screen moments in `[start, end)`, oldest first, with their
text (when kept) and saved note.

#### One query per 400 ids; ids with no capture have no entry
`Library.screen_moments_by_id`: `screen_moment` for many ids, one query per 400 of them. An id with no
capture (retention, a delete) has no entry.

#### Apps used only seconds do not count toward the plus count
`untitled_session_names_its_two_busiest_apps_and_counts_the_rest`: Spotify's 50 seconds don't count toward "+1".

#### A second app with seconds of use stays evidence, not title
`untitled_session_names_its_two_busiest_apps_and_counts_the_rest`: Only seconds of a second app: it stays evidence, not part of the title.

#### A meeting running past the next session must not open a false gap
`rail_marks_long_gaps_from_the_latest_end_so_far`: The rail marks a long stretch with nothing recorded. A meeting that
runs past the next session must not open a gap that never happened.

#### Test numbers: 40-minute gap counts, under 30 minutes after meeting does not
`rail_marks_long_gaps_from_the_latest_end_so_far`: 600 → 3,000 is 40 minutes away. 3,300 → 4,000 is under 30 minutes,
and the meeting covers c.rs and ends 1,000 s before d.rs.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
