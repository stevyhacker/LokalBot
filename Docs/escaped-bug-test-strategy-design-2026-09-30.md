# Escaped-bug test strategy — design

Date: 2026-09-30
Status: implemented. Each step below has its code; "Implementation refinements" at the end and Testing in [DEVELOPMENT.md](../DEVELOPMENT.md#testing) describe it as built
Delivery: one pull request, one commit (or small commit group) per step

## Why

About 24 bugs reached users between 0.7 and 0.9.2. Nearly all came through
two gaps:

1. **The UI tests never run the parts that broke.** The UI test host returns
   early in `AppState` (`if Self.isUITesting { return }`, currently
   `LokalBot/AppState.swift:987`), before tracking, screen capture,
   recording, schedulers, and startup repairs start. The 97 UI tests drive
   three canned meetings with silent audio and pre-written digests
   (`LokalBotUITests/SyntheticFixture.swift`). They catch layout and
   interaction regressions, not capture, recording, or digest bugs.
2. **Unit tests encode our assumptions about other software.** The largest
   category (about 9 bugs) is Chrome, Teams, or Meet behaving differently
   than the code assumed: Chrome reports no keyboard focus until its
   accessibility tree is read, and ScreenCaptureKit window titles lag behind
   the real ones. Hand-built fakes pass when the fake is wrong. Language
   models are the same: the digest stub in `DayDigestEvidenceTests.swift`
   mostly returns every segment as substantive, so #117's dropped lighter
   work passed, and digest truncation from a too-small token budget
   happened twice (e5077c3, then #117).

## Goal and success criteria

Each class of escaped bug fails a check before it reaches users, cheapest
checks first. Concretely, after this work:

- Master cannot go red unnoticed: Build, unit tests, UI tests, lint,
  XcodeGen, and the day-in-the-life job are required on every PR.
- A regression like #109 (browser time recorded as Private) or #113
  (scheduled digests silently stopped) is reported on the developer's
  installed build within a day.
- Reverting the fixes for #116, #109, #98, #40, #97, #113, #115, and the
  #117 token budget each makes at least one test fail.
- Model behaviour drift for the preset remote models is detected nightly.

## Non-goals

- Running UI tests locally (AGENTS.md: hosted CI only).
- Covering Cotyping's accessibility code with replay (no escaped bugs there).
- Judging model output quality; model tests check pipeline behaviour and
  budgets, not prose.
- Sending any user data to CI or to model providers. Every committed
  fixture, recording, and prompt is synthetic or scrubbed.

## Decisions made during design

| Question | Decision |
|---|---|
| Scope | All 8 steps plus the logging enabler, one PR |
| Health-check alerting | macOS notification on failure + dated report + `--health` CLI |
| Real-model nightly | OpenRouter via the `OPENROUTER_API_KEY` repo secret |
| Drift / recording models | `qwen/qwen3.8-flash` and `z-ai/glm-5.3-flash` only, for now |
| Recording safety | Scripted sessions **and** a mandatory scrubber, enforced in CI |
| Replay architecture | Approach A: one `CaptureEnvironment` seam; real services run on replayed input |

## Architecture overview

Three fakes, each sitting at a real boundary so the app's own code runs:

- **Model boundary:** an OpenAI-compatible stub server (Bun) behind the
  real `OpenAICompatibleEngine`.
- **OS capture boundary:** `CaptureEnvironment` (workspace, accessibility,
  windows, audio processes, clock) with `Live`, `Recording`, and `Replay`
  implementations.
- **Audio input boundary:** `AudioBufferSource` inside the mic and
  system-audio recorders; only the input is swapped, the writer, tee,
  recovery journal, and health sampler stay real.

One evaluator, `LibraryHealth`, judges a library the way a user would
notice problems. It runs daily on developer builds and doubles as the
assertion layer for the day-in-the-life runs.

Test-only hooks (golden transcription replay, host background mode) are
compiled only when `LOKALBOT_TEST_HOOKS` is set, which release builds never
set.

---

## Step 1 — Keep master green

- **PR template** (`.github/PULL_REQUEST_TEMPLATE.md`): new section
  "Changed test expectations". For each test whose expected result changed:
  old expectation → new expectation, and why the old expectation was wrong.
  "To match the new behaviour" is not a reason. Three escaped bugs came from
  tests rewritten to match the bug (automation approval default, mic speech
  made unresolved, browser windows marked Private).
- **UI Tests always reports.** Remove the `paths:` filter from the
  `pull_request` trigger in `ui-tests.yml`. Add a first `changes` job that
  computes whether any currently filtered path changed (`LokalBot/**`,
  `LokalBotUITests/**`, `project.yml`, `Scripts/ui-tests.sh`,
  `Scripts/ci/**`, `Scripts/fetch-llama.sh`, `Scripts/fetch-sherpa.sh`,
  `.github/workflows/ui-tests.yml`, plus new fixture paths used by UI
  tests). Shard jobs depend on it and skip when nothing relevant changed; the
  existing aggregate job `XCUITest (macOS)` passes in that case. Push runs
  on master/dev always run everything (release gates unchanged).
- **PR size warning:** a non-blocking annotation when a PR touches more than
  60 files.
- **Branch protection (after merge, with explicit go-ahead):** via
  `gh api repos/stevyhacker/LokalBot/branches/master/protection`, require
  `xcodebuild (macOS)`, `xcodebuild test (macOS)`, `XCUITest (macOS)`,
  `SwiftLint`, `project.yml generates cleanly`, and `Day in the life
  (macOS)`. Not strict (no forced rebase), no required reviews,
  `enforce_admins: false` so the owner can override in an emergency.

## Step 2 — Daily health checks on the installed build

### `LibraryHealth` (pure evaluator)

Inputs: the SQLite library (`activity_blocks`, `screenshots`,
`pipeline_jobs`, `memory_routine_runs`, `indexed_meetings`,
`deleted_meetings`), the meetings folder, journal `*.meta.json`, and the
scheduler settings. Output: `LibraryHealthReport` with one finding per
check, each `pass | warn | fail`, plus the measured numbers.

| Check | Rule |
|---|---|
| Capture rate per app | **fail** when an app with ≥ 30 min tracked in the day has 0 screen captures (text or pixel) |
| Private share | **warn** when > 15 % of tracked time is `Private`, or when it at least doubles against the 7-day median and exceeds 10 % |
| Activity vs wall clock | **fail** on overlapping blocks, or tracked time > elapsed wall-clock time for that day |
| Finished recordings | **fail** for a finished recording with no transcript and no pending/running pipeline job (merged-meeting gaps included, per `MissingTranscription`) |
| Scheduler fired | **fail** when a day digest or dream was due, its conditions were met (approval, power for dreams), and no run/journal exists after the due time plus a 2-hour grace |
| Digest coverage | **warn** when the digest covers < 60 % of tracked seconds |

Digest coverage needs data the digest does not persist today: the digest
writes `coveredSeconds` and `trackedSeconds` into its journal `meta.json`
(covered = union of the time ranges of focus blocks that reached the
rendered summary).

### Scheduling and output

- Runs automatically only in Debug builds (the reinstall script's default)
  or when the hidden defaults key `LokalBotDailyHealthCheck` is true.
  Release builds never run it on their own.
- Daily at 09:00 local on the existing minute-tick pattern; catches up at
  launch if the last run is older than 24 h. Evaluates the previous day and
  the current partial day.
- Writes `diagnostics/health/YYYY-MM-DD.json` and `.md` under the library
  root. Posts a macOS notification only when any check fails; clicking it
  opens the Markdown report.
- `LokalBot --health [--day YYYY-MM-DD] [--json]` runs it on demand
  (headless), prints the report, and exits 1 when any check fails.

## Enabler — logs and diagnostics export

- `FileLogSink` default: 8 MB cap, 5 rotated files (≈ 40 MB, a full day).
- **Export Diagnostics…** in Settings and
  `LokalBot --export-diagnostics <path>`: a zip of recent logs, the last 14
  health reports, settings with secrets removed (API keys, tokens), library
  row counts, and scrubbed capture traces (step 4) if any. Never meeting
  audio, transcripts, notes, screenshots, or OCR text.

## Step 3 — Fake model server with realistic failures

### Stub server

`LokalBotTests/Fixtures/stub-openai.ts` becomes scenario-driven. It serves
`/v1/models` and `/v1/chat/completions` (streaming and non-streaming,
`response_format` JSON schema, llama-server / OpenRouter / OpenAI parameter
dialects), plus control endpoints:

- `POST /__scenario` loads an ordered rule list. Rules match by call index,
  by `response_format.json_schema.name`, or by a system-prompt substring.
- `GET /__requests` returns every received request (body and timing) so
  tests can assert `max_tokens`, reasoning fields, and retry spacing.
- `POST /__reset` clears scenario and request log.

Rule behaviours:

| Behaviour | Effect |
|---|---|
| `reply` | fixed content, optionally chunked for streaming, with `usage` |
| `http` | status (429, 503, …), `Retry-After`, error JSON body |
| `truncate` | stops mid-answer with `finish_reason: "length"` |
| `reasoning` | consumes a share (or fixed count) of `max_tokens` as hidden reasoning, ignoring `effort: none`; truncates when the remainder is too small for the answer (tokens ≈ characters / 4) |
| `malformed` | invalid JSON, missing required fields, or code-fenced JSON |
| `slow` | delays first byte and/or spaces chunks |
| `drop` | closes the connection mid-stream |

A synthetic `reasoning-heavy` scenario (not tied to any model) reproduces
the muse-spark behaviour behind #117.

### Bun in CI

`Scripts/ci/fetch-bun.sh` downloads Bun at `AgentRuntimeManifest.bunVersion`
(1.4.2) and verifies the checksum already pinned in
`LokalBot/Agent/AgentRuntime.swift`. No new third-party action. Tests read
the Bun path from `LOKALBOT_TEST_BUN`; when `CI=true` a missing Bun fails
the test, locally it skips with a message.

### `ModelServerScenarioTests`

Through the real `OpenAICompatibleEngine` (dialect forced to OpenRouter,
endpoint `http://127.0.0.1:<port>`), exercise:

- day digest (`DayDigestOverviewGenerator.generateResult`): 503 then
  success keeps the segment; 429 honours `Retry-After` (injected sleep);
  truncation recovers on the larger retry; reasoning-heavy scenario
  succeeds within the retry budget; malformed JSON takes the retry prompt;
  drop stops cleanly with partial quality;
- meeting notes (`MeetingNotesGenerator`): same failure set, including the
  expanded structured-output retry;
- Ask: streamed answer with citations, slow stream, drop.

**Budget guard test:** for each recorded model and the synthetic
reasoning-heavy scenario, replay recorded reasoning usage against the
current digest and notes token budgets; fail if any first-attempt-plus-retry
path would truncate.

### Recordings and nightly drift

- Recordings: `LokalBotTests/Fixtures/model-recordings/<model-id>/<case>.json`
  holding request metadata, response content, `finish_reason`,
  `usage` (including `reasoning_tokens`), and latency, for fixed synthetic
  prompts (digest focus, digest aggregation, notes extraction, Ask answer,
  and the step 5 seeded day).
- Models: `Scripts/ci/model-drift-models.json` lists only
  `qwen/qwen3.8-flash` and `z-ai/glm-5.3-flash`.
- The `model-drift` job of `.github/workflows/nightly.yml` (03:00 UTC, and
  `workflow_dispatch` with a `jobs` input so it can run alone on a branch):
  runs the synthetic prompts
  against both models with `OPENROUTER_API_KEY` and the no-data-collection
  routing policy, ≤ 40 requests per night. Drift = truncation at our
  budgets, reasoning > 60 % of budget, parse or schema failure, or p95
  latency doubling versus the committed recording. On drift: upload fresh
  recordings as an artifact and open or update a "Model drift: <model>"
  issue. Committed recordings change only through a normal PR.
- Only synthetic fixture text is ever sent.

## Step 4 — Record and replay real app behaviour

### `CaptureEnvironment`

A `Sendable` protocol returning value types only:

- **workspace:** frontmost app (pid, bundle id, name), running apps,
  activate/terminate events (`AsyncStream`);
- **accessibility:** `snapshot(pid) -> ScreenAccessibilitySnapshot?` (the
  existing resolver output), focused-window and browser-tab value queries
  used by `ActivityTracker` and `BrowserMeetingSession`;
- **windows:** ScreenCaptureKit on-screen windows as
  `[ScreenshotCaptureLayout.Window]`, `captureImage(windowID)`;
- **audio:** Core Audio processes (pid, bundle id, input/output running),
  default-input-device running state, change events;
- **permissions:** screen recording and accessibility granted;
- **clock:** `now`, `uptime`, `sleep(for:)`.

`LiveCaptureEnvironment` receives today's raw calls, unchanged in
behaviour: `AXUIElement*`, `SCShareableContent`, `SCScreenshotManager`,
`NSWorkspace`, and the `CoreAudioUtils` process lists, currently spread
across `ScreenshotService`, `ScreenAccessibilityReader`, `ActivityTracker`,
`MeetingDetector`, and `BrowserMeetingSession`. Those services take the
environment at init (default: live) and route `Date()`, `systemUptime`, and
`Task.sleep` through its clock.

### Recorder and scrubber

- `RecordingCaptureEnvironment` wraps the live environment and logs every
  query, result, and latency while the app runs normally. Started by
  `LokalBot --record-capture <seconds> [--scenario <name>]` or a Debug-menu
  item, Debug builds only.
- Trace format: JSON header (schema version, macOS version, app bundle ids,
  `origin: scripted | real | reconstructed`, `scrubberVersion`) and
  timestamped events per domain. Replay answers each query from the
  recorded sequence for that pid and time, so ordered behaviours (unknown
  focus, then plain focus after the tree is read) reproduce exactly.
- `CaptureTraceScrubber` runs before any file is written: keyed,
  character-class-preserving substitution for all text, titles, URLs, and
  document names (letters → letters, digits → digits, punctuation kept), so
  patterns like Meet codes survive while content does not. An allowlist
  keeps detection-relevant vocabulary verbatim (product and UI terms such as
  "Meet", "Microsoft Teams", meeting domains, bundle ids, AX roles and
  subroles). Frames, counts, secure-field flags, and timing are kept.
- `Scripts/ci/check-capture-recordings.py` fails CI for any trace without
  the current scrubber stamp or with a string outside the placeholder
  grammar and allowlist.
- `Scripts/record-capture/` serves a local page with synthetic text, a
  password field, and a Meet-like title, and drives Chrome and Safari
  through the recorder on the developer's Mac.

### `CaptureReplayTests`

Run the real services on `ReplayCaptureEnvironment` in virtual time and
assert user-visible outcomes (capture taken or the logged skip reason,
activity keeps its app name, meeting starts and stops). First traces,
reconstructed from escaped bugs and verified to fail with the fix reverted:

- #116 — Chrome focus appears only after the tree is read; ScreenCaptureKit
  title lags the accessibility title;
- #109 — browser and web-app windows recorded as Private;
- #98 — Meet call controls unreadable while the call tab stays open;
- #40 — Teams detected only through Core Audio process lists.

Every future escaped capture bug adds a trace and a replay test
(documented in DEVELOPMENT.md).

## Step 5 — Day-in-the-life runs through the real pipelines

- `Scripts/seed_demo_library.py --profile full-day`: an 8–10 h workday with
  activity blocks (including browser, Electron, and Private time), OCR
  screen-text rows, calendar events, and two meetings with synthetic
  dual-track audio from `say`, one merged. `--profile large`: six months,
  about 200 meetings, 50k activity blocks, 20k screenshot rows. The existing
  screenshot profile stays the default. All content synthetic.
- `Scripts/day-in-the-life.sh` drives a Debug build (with
  `LOKALBOT_TEST_HOOKS`) through `--process`, `--digest`, `--search`, and
  `--health` on a throwaway `LOKALBOT_STORAGE_ROOT`. Fakes only:
  - model: the step 3 stub replaying GLM 5.3 Flash / Qwen3.8 Flash
    responses recorded for this seeded day, keyed by schema name and call
    order so prompt rewording does not break replay;
  - transcription: golden transcripts produced once by real Parakeet from
    the seeded audio (PR runs); the nightly run uses real Parakeet (Actions
    cache, ~600 MB) and flags drift from the goldens;
  - capture input from step 4 traces where needed.
- Assertions (mostly through `LibraryHealth` on the seeded day):
  - digest covers ≥ 60 % of tracked hours with no lost segment;
  - activity hours ≤ wall-clock hours, no overlaps;
  - the golden meeting produces ≥ 1 action owned by the user after the
    app's ownership checks;
  - every finished recording (including the merged one) has a transcript or
    a queued job;
  - after a meeting-boundary review (XCTest integration through the same
    service the review UI uses), the meeting is still found by `--search`;
  - `--search` finds seeded meeting text, OCR text, and notes.
- CI: new job `Day in the life (macOS)` in `build.yml` on every PR (a
  required check); failures upload the kept library. Nightly: same run with
  real Parakeet and live models via the drift workflow.
- `Scripts/ci/record-day-responses.sh` refreshes the recorded responses
  (locally with a key, or by dispatching `nightly.yml`'s `model-drift` job on
  a branch).
- `Scripts/e2e.sh` remains the local real-everything suite; it is not run
  in CI.

## Step 6 — UI test host with background work running

- UI Test Host mode `LOKALBOT_UI_TEST_BACKGROUND=1`: `AppState` does not
  return early; tracking, detection, recording, the processing pipeline, and
  schedulers start on fakes:
  - `ReplayCaptureEnvironment` with a scripted trace (e.g. a Meet call from
    t = 5 s to t = 40 s);
  - `AudioBufferSource` seam in `MicRecorder` and `SystemAudioRecorder`
    (live: today's AVAudioEngine tap and process tap; replay: golden WAV
    per track as PCM buffers); `RecordingController` takes the sources at
    init;
  - golden-transcript hook and the Bun stub (started by the UI test
    process, port passed through the launch environment);
  - schedulers on the environment clock, accelerated, with due times just
    after launch;
  - Sparkle, real network, and system notifications stay off.
- `BackgroundFlowUITests`:
  1. record → stop → transcribe → notes → action appears in Actions → Ask
     finds it → review meeting boundary → still searchable (#115);
  2. select another meeting while recording, then stop: no crash, recording
     saved (#97);
  3. a Meet call detected from the trace starts and stops recording (#98);
  4. the scheduled digest fires on an existing library, appears in
     Timeline, and shows progress in the sidebar card (#113).
- New `UI background` shard in `ui-tests.yml`, counted by the aggregate
  `XCUITest (macOS)` job. Hosted CI only. Failure artifacts include the
  screen recording and the host debug log.

## Step 7 — Upgrade tests

- `.github/workflows/upgrade-fixtures.yml` (`workflow_dispatch`, clean
  hosted Mac only, because it writes the app's real defaults domain). For
  each of 0.6.2, 0.7.2, 0.8.5, 0.9.0, 0.9.1, 0.9.2:
  1. run that tag's own `Scripts/seed_demo_library.py`;
  2. write that version's settings keys from a per-version profile
     (approved remote origins, schedules, remote backend);
  3. open the library headlessly (`--search`) with that release's signed
     build from GitHub Releases so the old app builds its own schema and
     migration markers;
  4. export the library, the defaults domain, and the test encryption key
     into an artifact that is committed through a normal PR to
     `LokalBotTests/Fixtures/upgrade/<version>/`. The key protects only
     synthetic data.
- `UpgradeMigrationTests` per fixture: current `DataMigration` and library
  load succeed without a recovery window; approvals and schedule settings
  survive; digest and dream schedulers would fire when due (#113); meetings
  are searchable with no stale tombstones; encrypted chats and screenshots
  decrypt. The key moves behind a small key-provider seam if not already
  injectable.
- Release process: RELEASING.md gains "add the upgrade fixture for the
  previous stable version", and `release-preflight.py --candidate` fails if
  that fixture is missing.

## Step 8 — Scale and concurrency (nightly, non-blocking)

`nightly.yml` holds the model drift run, the real-Parakeet day-in-the-life
run, and:

- large library (`--profile large`): launch, library load, and the startup
  retention sweep finish within a time budget; the main thread is never
  blocked > 1 s (startup retention hang);
- `--digest` while a second process inserts activity: the digest completes
  and marks the new evidence (0.9.1);
- two headless instances on one library root: the second exits on
  `LibraryInstanceLock`; the library stays intact (#115).

Failures open or update an issue.

## Commit order

1. CI guardrails (template, UI `changes` job, size annotation)
2. Log retention and Export Diagnostics
3. `LibraryHealth`, daily run, notification, `--health`, digest coverage
   metadata
4. Stub server, Bun fetch, `ModelServerScenarioTests`, recordings, budget
   guard, drift workflow
5. `CaptureEnvironment` with a behaviour-neutral live implementation
6. Recorder, scrubber, CI check, scripted-session tooling, reconstructed
   traces, `CaptureReplayTests`
7. Seed profiles, test hooks, day-in-the-life script and CI job
8. `AudioBufferSource`, background UI host mode, `BackgroundFlowUITests`
9. Upgrade fixture workflow, fixtures, `UpgradeMigrationTests`, preflight
10. Nightly scale and concurrency
11. Docs: DEVELOPMENT.md testing section, RELEASING.md, AGENTS.md
    references

After merge, separately and only with explicit go-ahead: branch protection.

## Dependencies on the owner

- `OPENROUTER_API_KEY` repository secret (owner sets it; the implementer
  never handles the value) with a spending cap on the key.
- Approval before each GUI step: recording scripted sessions, and a
  reinstall to confirm capture and recording behave the same after commits
  5 and 8.
- Go-ahead for branch protection after merge.
- Running `upgrade-fixtures.yml` requires downloading the project's own
  signed releases on a hosted runner.

## Risks

- Commits 5 and 8 refactor capture and recording hot paths. Mitigation:
  behaviour-neutral live implementation first, existing unit tests, new
  replay tests, and an installed-build check must all agree before merge.
- The PR is very large by the owner's choice; it will trigger its own size
  warning. Review commit by commit.
- Hosted-runner flakiness in the new UI shard and day-in-the-life job would
  block merges once required; both keep failure artifacts, and flaky
  assertions are fixed rather than retried.
- Recorded model responses go stale as prompts change; replay keys on
  schema name and call order, and the nightly run refreshes them.

## Implementation refinements

Found while planning:

1. Every request's `response_format.json_schema.name` is `"response"`, so
   replay keys on a system-prompt marker plus call order, not on schema name.
2. Focus blocks carry no time ranges. Digest coverage is the active seconds of
   evidence segments whose extraction produced a usable block, divided by the
   active seconds of all segments.
3. `CaptureEnvironment` is a struct of five small protocols (workspace,
   accessibility, windows, audio, clock), installed process-wide as
   `CaptureEnvironment.current`. Services read `.current` on every call rather
   than caching it, so a replay or recorder installed after a service exists
   still applies.
4. Nightly jobs get compiled products by calling `build.yml` as a reusable
   workflow, so same-run product verification keeps working.
5. Headless commands skip the library lock by design, so the two-instance check
   launches two normal app processes against one `LOKALBOT_STORAGE_ROOT`.
6. The daily health run evaluates yesterday (a complete day); `--health --day`
   evaluates any day, including today.
7. Golden transcripts are the exact synthetic lines, and the boundary-review
   check is the test-only headless command `--set-boundaries`.

Found while implementing:

- `MeetingDetector` is `@MainActor` (it already ran only on the main thread);
  its static helpers stay `nonisolated` for their off-main callers.
- A system-audio tap is checked with `resolves(processID:)` before the running
  tap is torn down, so a reattach to a vanished process keeps capturing, as
  `RecordingController` assumes.
- Boundary reviews re-transcribe sliced regions; golden transcripts answer a
  slice through a test-only task-local naming the source track and region.
- A boundary review revokes the day's digest, so the workday run writes the
  digest last.
- `--search` searches meetings only; the workday run checks screen text with
  the test-only `--search-screen`.
- The file system-audio tap delivers a process tap's format (Float32 stereo,
  48 kHz), because the recorder's AAC writer cannot open a 16 kHz mono file.
