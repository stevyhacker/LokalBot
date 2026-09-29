# Background work: single approval, catch-up, and progress card

Date: 2026-09-29. Status: approved design.

## Problem

Scheduled Day Digests and overnight Dreams stopped silently after
`4b62969` (2026-09-25) added `approvedRemoteAutomationOrigins`, a second
per-origin approval for unattended runs. Existing installs with an approved
remote Think origin were not migrated, so `allowsAutomaticMainInference`
returned false and both schedulers skipped every tick without logging or UI.

Separately, Dreams waited for three minutes of system idle, AC power, and no
Low Power Mode, so a Mac in active use rarely dreamed. Digests only finalized
yesterday, so any older missed day stayed missing. Long-running model work
(meeting processing, digests, dreams, downloads, reindexing) has no shared
progress surface.

## 1. One approval per remote origin

- Remove `approvedRemoteAutomationOrigins` from `AppSettings` (property,
  coding key, encode, decode). The decoder ignores the stale key in saved
  blobs; no migration is needed.
- `allowsAutomaticMainInference` is true when the Think backend is on-device
  or its endpoint is allowed by `approvedRemoteInferenceOrigins` (loopback
  never needs approval). Callers are unchanged.
- Settings: remove the second toggle from the connection editor and the
  Models overview. The remaining approval disclosure states that scheduled
  summaries and overnight review also use the approved server. Revoking still
  cancels pending scheduled work.
- `AppState.automaticInferenceChanged` drops the removed field.
- `PRIVACY.md` replaces the "separate approval" paragraph.

## 2. Catch-up at launch (7-day window)

Both schedulers look back at most `catchUpDays = 7` local days (yesterday and
the six days before it).

### Dreams

- Gates kept: configured hour, LokalBot idle (not recording, processing,
  dictating, or cotyping), Think ready, library ready, automatic inference
  allowed, and AC power.
- Gates removed: three-minute system idle and Low Power Mode.
- Scan start is the later of the persisted `dreamingFirstEligibleDayKey` and
  `yesterday - 6 days`. The persisted opt-in boundary is unchanged; days
  outside the window remain available through manual Dream now.

### Digests

- `DayDigestScheduler.generationDay` returns the oldest past day within the
  window that has evidence and is not finished, otherwise today once the
  configured hour has passed (existing preview policy).
- A past day is finished when its completion marker (the existing
  `automaticCompletionAt`) is at or after the start of the following day.
  User-edited journals return `.distantFuture`; fallbacks that exhausted their
  repair attempts return their modification time; days without evidence are
  skipped.
- An in-memory cursor records the first day not yet proven finished, so the
  minute tick does not re-read seven days of evidence. `reconsiderEvidence`,
  configuration changes, and calendar changes reset it.

## 3. Sticky progress card

### Model

`BackgroundActivity` is a value type: `id`, `kind` (`meetingProcessing`,
`dayDigest`, `dream`, `download`, `reindex`), `title`, `detail`, optional
`fraction` (0...1), and a `destination` used for navigation.

`BackgroundActivityMonitor` (main-actor `ObservableObject`, owned by
`AppState`) subscribes to owner publishers and publishes `activities`, sorted
by kind priority (the order above), through a pure
`BackgroundActivity.derive(...)` function that unit tests exercise directly.

Sources, each remaining the source of truth:

| Kind | Owner state |
| --- | --- |
| Meeting processing | `ProcessingPipeline.stages` (active stage + queued count) |
| Day digest | new `DayDigestLifecycle.activeRun` (day, completed and total segments, phase) for manual, scheduled, and headless runs |
| Dream | `DreamScheduler.isDreaming` plus new published `activeDayKey` and `remainingCatchUpDays` |
| Download | `ModelDownloadManager.progress`, with model names from the catalog |
| Reindex | new `AppState.embeddingBackfill` count over meetings that actually need re-embedding |

Digest progress is reported through an optional progress callback passed from
`DayDigestLifecycle` into `ProcessingPipeline.generateDayDigest`, called when
planning finishes, after each segment, and during aggregation.

### Card

- Placed in `SidebarPrivacyFooter` between the Recording card and the Storage
  card, using the same surface styling.
- Shows the top activity: icon, title, detail, and a determinate bar when a
  fraction is known (spinner otherwise). With more than one activity, a
  "+N more" affordance opens a popover listing all of them.
- Tapping an item navigates: meeting processing to the meeting, today's
  digest to Today and an earlier digest to Timeline on that day, dream to
  Today, download to Settings → Models; reindex and a queued-only meeting
  summary have no destination.
- Hidden when nothing is running. Failures keep the existing error surfaces.

Out of scope: "waiting" states such as a dream deferred for AC power.

## Testing

- Unit: approval merge in `AppSettingsTests` and `DayDigestLifecycleTests`;
  7-day window, finished rules, and cursor for `DayDigestScheduler`; window
  clamp for `DreamScheduler`; `BackgroundActivity.derive` mapping and order.
- UI: no hosted UI test; the card only appears while real model work runs,
  and seeding it would need a test-only hook. Its content and ordering are
  covered by the `BackgroundActivity.derive` unit tests.
