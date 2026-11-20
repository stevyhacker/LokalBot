# 0032. Mac app: Health

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Health/`, `LokalBotTests/Services/Health/`.

## Decisions

### `LokalBot/Services/Health/LibraryHealth.swift`

#### Yesterday relative to now as digest scheduler sees it
`LibraryHealthInput.Schedulers.previousDay`: Yesterday relative to `now`, as the digest scheduler sees it.

#### Counts undreamed eligible days in catch-up window through yesterday
`LibraryHealthInput.Schedulers.missingDreamDays`: Undreamed eligible days in the catch-up window through yesterday.

#### Private share of each earlier active day in the last week
`LibraryHealthInput.privateShareHistory`: Private share of each earlier day in the last week that had activity.

#### Off means app never repairs missing transcript itself
`LibraryHealthInput.automaticTranscription`: Off means the app never repairs a missing transcript on its own.

#### Pure so daily run, --health and day-in-life runs share rules
`LibraryHealthEvaluator`: Judges one day of a library the way a user would notice a problem. Pure,
so the daily run, `--health`, and the day-in-the-life runs share one set
of rules.

#### Capture skips LokalBot's windows and lock screen by design
`LibraryHealthEvaluator.uncapturedApps`: Capture skips LokalBot's own windows and the lock screen by design.

### `LokalBot/Services/Health/LibraryHealthLoader.swift`

#### Reads counts and timestamps only, never window text or meeting content
`LibraryHealthLoader`: Gathers `LibraryHealthInput` for one day from the app's stores. Reads
counts and timestamps only; never window text or meeting content.

### `LokalBot/Services/Health/LibraryHealthScheduler.swift`

#### Daily check only on developer builds; release runs on demand
`LibraryHealthScheduler`: Runs the library health check once a day on developer builds (Debug, or
the hidden `LokalBotDailyHealthCheck` default) and catches up at launch
when the last run is over a day old. Release builds never run it on their
own; `--health` and Settings run it on demand.

### `LokalBotTests/Services/Health/LibraryHealthTests.swift`

#### Capture never records LokalBot or lock screen, so that time is not silence
`LibraryHealthTests.testCaptureRateIgnoresLokalBotsOwnWindowsAndTheLockScreen`: Capture never records LokalBot itself or the lock screen, so time
there must not read as an app capture has gone silent for.

#### With automatic transcription off, a missing transcript is user choice, not failure
`LibraryHealthTests.testFinishedRecordingsPassWhenAutomaticTranscriptionIsOff`: With automatic transcription off, the app never repairs a missing
transcript on its own, so that is the user's choice, not a failure.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
