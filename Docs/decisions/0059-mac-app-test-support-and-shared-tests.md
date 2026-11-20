# 0059. Mac app: test support and shared tests

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBotTests/`, `LokalBotTests/Fixtures/`, `LokalBotTests/TestSupport/`.

## Decisions

### `LokalBotTests/AppDelegateLifecycleTests.swift`

#### SwiftUI quits on last Window close unless delegate says no (issue 248)
`AppDelegateLifecycleTests.testClosingTheLastWindowKeepsTheAppRunning`: SwiftUI quits an app whose main scene is a single `Window` once that
window closes, unless the app delegate answers otherwise. Closing the
main window used to quit LokalBot, menu-bar-only included (issue #248).

### `LokalBotTests/AppStateFanOutTests.swift`

#### High-frequency state must reach only views that draw it, not all AppState observers
`AppStateFanOutTests`: Every AppState change re-renders every view observing AppState, so
high-frequency state must reach only the views that draw it.

#### Changes no menu, window title or status glyph reads must not rebuild scenes
`AppStateFanOutTests.testAppScenesRefreshOnlyWhenTheirValuesChange`: AppState changes no menu, window title or status glyph reads.

#### Status dot follows an error message or a terminal settings change AppState does not republish
`AppStateFanOutTests.testTheStatusGlyphFollowsWhatNeedsAttention`: The status item carries a dot while something waits for the person:
an error message, or a settings change from the terminal, which
AppState itself does not republish.

#### AppState forwards exactly the readiness publisher
`AppStateFanOutTests.testDownloadProgressReachesModelViewsButNotAppState`: AppState forwards exactly this publisher.

### `LokalBotTests/AppStateNavigationTests.swift`

#### Actions is its own sidebar destination separate from Today
`AppStateNavigationTests`: Actions is its own sidebar destination, so routes to Today and to Actions
each land on their own section.

#### Day digest and overnight review live on Today and open there from any section
`AppStateNavigationTests.testBackgroundActivityForTodayOpensToday`: Today's digest and the overnight review are shown on Today. Opening
their background activity lands there from any section, Actions
included.

### `LokalBotTests/Fixtures/stub-openai.ts`

#### Scenario stub prints port first and defaults to STUB-REPLY used by PiIntegrationTests
`stub-openai.ts`: Scenario-driven OpenAI-compatible stub for LokalBot tests. Prints the chosen
port on stdout as its first line. Without a loaded scenario it streams the
legacy fixed "STUB-REPLY" message (PiIntegrationTests relies on that).

#### requests excludes the current request, so its number is seen plus one
`stub-openai.ts select`: `requests` does not yet include this request: it is number seen + 1.

#### Stub ignores reasoning.effort and spends a fixed reasoning amount first
`stub-openai.ts reasoning behaviour`: Ignores reasoning.effort by design: spends a fixed amount first.

### `LokalBotTests/TestSupport/LokalBotTestObservation.swift`

#### Unit tests refuse model downloads; refusal may surface in a later test
`LokalBotTestObservation`: The test bundle's principal class (`NSPrincipalClass` in project.yml), so
XCTest creates it before the first test runs.

Unit tests share the app's code but must stay off the network. A model
download a test reaches is refused (`UITestRuntime.refuseDownloadInUnitTests`)
and fails that test here. Background work can outlive the test that started
it, so a refusal can also surface in the next test to finish.

### `LokalBotTests/TestSupport/ModelRecording.swift`

#### Recordings live in vendor__model folders; purpose markers sit beside them
`ModelRecording.committed`: Every committed recording in the test bundle. Recordings live in one
`<vendor>__<model>` folder per model; other files (the purpose
markers) sit beside those folders.

### `LokalBotTests/TestSupport/ModelRecordingTests.swift`

#### Recording runs only in nightly model-drift job with env vars set
`ModelRecordingTests`: Records real responses to `SyntheticModelPrompts` for the drift models.
Runs only when `LOKALBOT_RECORD_MODELS=1` with `OPENROUTER_API_KEY`,
`LOKALBOT_RECORD_MODEL_IDS` (comma-separated), and
`LOKALBOT_RECORDINGS_OUT` set — i.e. in the nightly `model-drift` job.

### `LokalBotTests/TestSupport/ModelRequestPurpose.swift`

#### Requests are classified by system prompt phrase; scenario tests guard prompt rewrites
`ModelRequestPurpose`: Which LokalBot stage sent a request, recognised by a stable phrase of its
system prompt (every request's `response_format` is named "response").
`ModelServerScenarioTests` checks each phrase still appears in the real
prompt, so a prompt rewrite cannot silently break replay.

#### The concise-writer marker is shared by task and best-available recaps
`ModelRequestPurpose.systemMarker`: shared by the task and best-available recaps

### `LokalBotTests/TestSupport/ModelStubServer.swift`

#### CI requires Bun for the stub server; locally a missing Bun skips
`ModelStubServer`: Runs `Fixtures/stub-openai.ts` under Bun for one test. CI (`CI=true`)
requires Bun (`LOKALBOT_TEST_BUN`); locally a missing Bun skips the test.

### `LokalBotTests/TestSupport/SyntheticModelPrompts.swift`

#### Prompts are synthetic and fixed; changing them invalidates committed recordings
`SyntheticModelPrompts`: Fixed, synthetic inputs sent to real models by the recorder. Nothing here
comes from a real library; changing it invalidates committed recordings.

#### Realistic standup transcript where commitments do not start with I'll
`SyntheticModelPrompts.runOnStandupTranscript`: A standup the way it is actually transcribed: little punctuation,
stumbled words, and one speaker's sentence cut across rows. The user
commits to two things mid-sentence; neither starts with "I'll".

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
