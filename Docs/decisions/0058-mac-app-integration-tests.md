# 0058. Mac app: integration tests

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBotTests/Integration/`.

## Decisions

### `LokalBotTests/Integration/CaptureReplayTests.swift`

#### Each replay test must fail with its bug's fix undone
`CaptureReplayTests`: Real services on replayed traces. Each test must fail with its bug's fix
undone (see the plan's Step 7 for how that was verified).

#### Audio process snapshot and capture-target memory outlive a test and must be reset
`CaptureReplayTests.replay`: Both outlive a test: the process list is cached by (virtual) time,
and capture remembers which sibling last emitted per bundle.

#### Chrome's first read fails while its tree settles; retry after 0.75 s
`CaptureReplayTests.testChromeTextIsCapturedAfterATransientRead`: \#116: Chrome's first read fails while its tree settles; one retry 0.75 s
later must capture the page text instead of skipping.

#### A hung text recognition must not make later captures skip as in flight
`CaptureReplayTests.testCapturesGoOnWhenTextRecognitionNeverAnswers`: 2026-11-09: one text-recognition request never returned. The capture
waiting for it kept its turn, and every capture after it was skipped as
"already in flight" for the rest of the day. A window whose accessible
text is thin is still captured, and so is the next one.

#### Failed embedding backfill must be retried without a screen search
`CaptureReplayTests.testCapturedTextIsEmbeddedWithoutASearchAfterAFailedPass`: 2026-10-12: screens captured after 2026-10-08 never got vectors. Only
a screen search started a backfill, and a pass that failed (another
embedder held port 17873) was never retried. A capture in a library
that searches screens by meaning must reach semantic search on its own.

#### Chrome framed pages are web areas; page keeps its address under unrelated exclusions
`CaptureReplayTests.testFramedPageKeepsItsAddress`: Chrome exposes framed pages as their own web areas; the page keeps its
address under unrelated site exclusions.

#### Browser web content without a readable URL keeps its app name, not Private
`CaptureReplayTests.testBrowserTimeKeepsItsAppName`: \#109: a browser window with web content and no readable address keeps
its app name; it must not become Private.

#### Unreadable Meet controls keep the meeting running ten minutes, ending only with the call
`CaptureReplayTests.testMeetCallSurvivesUnreadableControlsUntilItEnds`: \#98: an open call tab whose controls cannot be read keeps the meeting
running for ten minutes; it ends only when the call ends.

#### Meet rooms under /meet/ path must be recognised as call documents
`CaptureReplayTests.testMeetCallUnderMeetPathStartsAndEnds`: \#372: Meet showed the room as /meet/abc-defg-hij, which was not taken
for a call document, so no meeting started and system audio never
attached. The call starts, binds to the room's canonical URL, and ends.

#### A verified call in another room ends the stale unverified session
`CaptureReplayTests.testCallInAnotherRoomReplacesAnUnverifiedCall`: 2026-10-03: Meet's page after the first call was not recognized as an
end, so that call stayed bound but unverified, and the next meeting, in
another room, was never detected. A verified call in another room must
end the stale session and start its own, with its calendar event.

#### Manual start must not join or be labeled by an unverified call's session
`CaptureReplayTests.testManualStartDoesNotJoinAnUnverifiedCall`: The same evening's manual Start from the menu bar: while the first call
is unverified, the recording must neither join its session (whose later
end would stop it) nor be labeled with its room.

#### Next event in the same Meet room splits the recording; another room does not
`CaptureReplayTests.testNextEventInTheSameRoomSplitsTheCall`: Back-to-back events on one Meet link: the call never ends, so the next
event must split the recording, as it does for a native app. An event
in another room means the current call is running over and must not.

#### Teams launch sound must not start a meeting; sustained audio must after confirmation
`CaptureReplayTests.testTeamsLaunchBlipDoesNotStartAMeetingButTheCallDoes`: Teams (#49/#56): a launch sound must not start a meeting; sustained call
audio must, after the native-audio confirmation window.

#### New Teams plays meetings via modulehost, whose stream is open while idle
`CaptureReplayTests.testManualRecordingHoldsTheTeamsCallOnModuleHost`: \#179: new Teams plays a scheduled meeting only through modulehost, whose
stream is open even while Teams is idle, so nothing counted as a source
and a manual recording stayed microphone-only. It must hold modulehost.

#### Idle Teams is only held and yields to a readable Meet call
`CaptureReplayTests.testAHeldTeamsStreamGivesWayToTheMeetCall`: The case 2fde15d guards: Teams sits idle while the Meet call being
recorded cannot be read yet. Teams is only held, the call replaces it
once readable, and a recording bound to the call never holds Teams.

#### Tencent Meeting is a dedicated conferencing app starting like Zoom
`CaptureReplayTests.testTencentMeetingCallStartsWithoutTheChatAppWait`: Tencent Meeting was not a known app, so its calls never started a
recording and a hand-started one saved only the microphone. As a
dedicated conferencing app it now starts like Zoom: as soon as the call
is audible, with no sustained-audio wait.

#### Feishu calls play through ByteDance-named helpers outside com.electron.lark
`CaptureReplayTests.testManualRecordingCapturesAFeishuCallOnItsHelper`: Feishu plays calls through ByteDance-named Electron helpers outside the
`com.electron.lark` namespace. A hand-started recording must find the
call and tap the helper, not save only the microphone.

#### Webex media helper lies outside its host's bundle namespace
`CaptureReplayTests.testManualRecordingCapturesAWebexCallOnItsMediaHelper`: \#363: Webex's media helper is outside its host's dot-separated bundle
namespace. A manual recording must verify the call and select its audio.

#### Process-family mapping must hold before speech, in pauses and across helper PID changes
`CaptureReplayTests.testWebexCaptureFollowsItsMediaHelperAcrossSilenceAndRestart`: The same process-family mapping must work before speech starts, through
a quiet pause, and when recovery sees a replacement helper with a new PID.

### `LokalBotTests/Integration/DailyEvidenceIntegrationTests.swift`

#### Revising or expiring sources keeps the day digest; only deleting withdraws it
`DailyEvidenceIntegrationTests.testOnlyDeletingSourcesWithdrawsTheDayDigest`: On 2026-10-07 a summary rerun started 17 s after a manual digest and
deleted it before any new notes existed. Revising or expiring a day's
sources keeps its digest; only deleting them withdraws it.

#### A block closing during generation can start before the request and include standalone context
`DailyEvidenceIntegrationTests.assertNewEvidenceDuringGeneration`: A block that closes during generation can start before the request
and contain a context that was standalone in the original snapshot.

#### Late capture ingestion may add context to an original block
`DailyEvidenceIntegrationTests.assertNewEvidenceDuringGeneration`: Late capture ingestion may also add context to an original block.

### `LokalBotTests/Integration/DayDigestBenchmarkTests.swift`

#### Digest benchmark opt-in via LOKALBOT_DIGEST_BENCH, driven by run.sh and score.py
`DayDigestBenchmarkTests`: Runs the day digest over `Benchmarks/think/DayDigest/cases.json` against a live
OpenAI-compatible server and writes every digest and model call for
`Benchmarks/think/DayDigest/score.py`. Skipped unless `LOKALBOT_DIGEST_BENCH=1`;
`Benchmarks/think/DayDigest/run.sh` starts the server and sets the variables.

#### Forward to production engine unchanged so streaming, truncation and retries match the app
`DayDigestBenchmarkTests.CapturingEngine`: Forwards to the production engine unchanged and keeps each reply, so
streaming, truncation, and retries behave as they do in the app.

#### Write results after every day so a capped run keeps finished days
`DayDigestBenchmarkTests`: Write after every day so a capped run keeps what finished.

### `LokalBotTests/Integration/FilmedBugRegressionTests.swift`

#### Regression tests for bugs the 2026-11-05 landing films exposed
`FilmedBugRegressionTests`: Bugs the landing page films exposed on real footage (2026-11-05). Each
expectation is the filmed input and what should have come out of it.

#### Writing state must be set synchronously before any suspension point
`FilmedBugRegressionTests.testWritingIsVisibleBeforeTheWriteTaskRuns`: No suspension point since the call: a view updating now already sees it.

### `LokalBotTests/Integration/LibraryPerformanceBenchmarkTests.swift`

#### Opt-in benchmarks need LOKALBOT_PERF_DB and LOKALBOT_NEMOTRON_MODEL_DIR copies
`LibraryPerformanceBenchmarkTests`: Opt-in timings on copies of a real library and real models. Each test is
skipped unless its variable is set (`TEST_RUNNER_` prefix in the runner):
`LOKALBOT_PERF_DB` is a copy of `lokalbotv3.sqlite`, and
`LOKALBOT_NEMOTRON_MODEL_DIR` a copy of the Nemotron diarization folder.

#### Stored vectors serve as queries so no embedding model runs
`LibraryPerformanceBenchmarkTests.testSemanticRetrievalTimings`: Stored vectors serve as queries, so no embedding model runs.

#### App runs the liveness check on the main actor after ranking
`LibraryPerformanceBenchmarkTests.testSemanticRetrievalTimings`: The app runs this check on the main actor after ranking.

#### Measures Recall keyword stage of 2,000 hits in 41 sessions and chat tool 12 rows
`LibraryPerformanceBenchmarkTests.testKeywordScreenSearchTimings`: Ask and Quick Recall's keyword screen stage (2,000 ranked hits, grouped
into 41 sessions) and the Ask chat tool's grouped search (12 rows).

#### Stores open on main actor at launch; upgrade, cold and warm opens differ
`LibraryPerformanceBenchmarkTests.testLaunchDatabaseOpenTimings`: The activity store and embedding index open on the main actor at
launch. "upgrade" is the first open after updating (one-time schema
work), "cold" a fresh file afterwards, "warm" the same file again.

#### Capture processing of caret-only frame differences with real hashing and HEIC
`LibraryPerformanceBenchmarkTests.testCaptureProcessingTimings`: Screen capture processing for one window's frames that differ only
by a blinking caret, with real hashing and HEIC encoding.

#### Autocomplete reread cost: recognition before, image fingerprint after
`LibraryPerformanceBenchmarkTests.testWindowTextRereadTimings`: One autocomplete reread of an unchanged window: text recognition
before, the image fingerprint after.

#### First recognition loads Vision models so is excluded from timing
`LibraryPerformanceBenchmarkTests.testWindowTextRereadTimings`: The first recognition loads Vision's models.

#### Daily retention clears expired captures on the main actor
`LibraryPerformanceBenchmarkTests.testRetentionPathClearTimings`: One day of expired captures, cleared the way the daily retention pass
does on the main actor.

#### Measures Nemotron speaker model memory and release after idle
`LibraryPerformanceBenchmarkTests.testDiarizationModelMemoryIsReleasedWhenIdle`: Memory the Nemotron speaker model holds while loaded, and whether the
engine releases it once processing has been idle.

#### Physical footprint in MB, matching Activity Monitor
`LibraryPerformanceBenchmarkTests.footprint`: Physical footprint in MB, as Activity Monitor reports it.

### `LokalBotTests/Integration/LiveTurnLatencyBenchmarkTests.swift`

#### Opt-in replay benchmark of turn-by-turn vs window live preview latency; inputs and env vars
`LiveTurnLatencyBenchmarkTests`: Opt-in measurement, run by hand: how soon after a speaker stops could the
live preview show that turn's text with a model on this Mac?

It replays a finished recording as if it were being recorded. A "turns"
pass cuts each track at pauses with the voice-activity model and the app's
`LiveTurnCutter`, and transcribes a turn once its pause is long enough. A "windows" pass repeats
what the preview does today: 4 to 12 second windows, track after track.
Decoding is timed for real; the recording's clock is simulated, so a
3½-minute recording takes as long as its decoding.

A recording is `label=mixed[|track|track]`: the mixed file alone stands for
one track that carries several voices, and the optional files are the same
call with one voice per track, as the microphone and call audio are
recorded. Benchmarks/transcribe/LiveTurns has the scripts and the last results.

TEST_RUNNER_LOKALBOT_LIVE_TURN_BENCH=/folder/for/results \
TEST_RUNNER_LOKALBOT_LIVE_TURN_AUDIO='en=/p/mixed.m4a|/p/a.wav|/p/b.wav' \
TEST_RUNNER_LOKALBOT_LIVE_TURN_MODELS=parakeet-v3,qwen3-asr-1.7b \
TEST_RUNNER_LOKALBOT_LIVE_TURN_LANGUAGES=sr=hr \
TEST_RUNNER_LOKALBOT_LIVE_TURN_RULES=2:4,2:off \
xcodebuild test-without-building ... \
-only-testing:LokalBotTests/LiveTurnLatencyBenchmarkTests

Only models already downloaded are run; nothing is fetched.

#### Decision is the recording time the piece could be handed over
`LiveTurnLatencyBenchmarkTests.Piece.decision`: Recording time at which the piece could be handed over: the pause
was long enough, or the window was full.

#### Ready is recording time the text exists, decoding one piece at a time
`LiveTurnLatencyBenchmarkTests.Piece.ready`: Recording time at which the text exists, pieces decoded one at a time.

#### Rule is quiet chunks in a row plus turn length enabling one quiet chunk
`LiveTurnLatencyBenchmarkTests.Rule`: How turns are closed: quiet chunks in a row, and the turn length from
which one quiet chunk is enough (nil: never).

#### Rule syntax: 2:4 means two quiet chunks, one after 4 s; 2:off never
`LiveTurnLatencyBenchmarkTests.Rule.init`: `2:4` is two quiet chunks, one once the turn is 4 s long; `2:off` never.

#### Rule label must be safe in file names on every system
`LiveTurnLatencyBenchmarkTests.Rule.label`: Safe in a file name on every system.

#### Step covers 160 ms of audio; most only buffer, one in a few runs the model
`LiveTurnLatencyBenchmarkTests.Stream.stepSeconds`: Time to take in 160 ms of audio; most steps only buffer, one in every few runs the model.

#### Token age is seconds from word end to its text existing
`LiveTurnLatencyBenchmarkTests.Stream.tokenAges`: Seconds from the end of a word to its text existing, one entry per token.

#### Layouts are mixed and, with per-voice files, tracks
`LiveTurnLatencyBenchmarkTests.Recording.layouts`: "mixed" and, when the per-voice files were given, "tracks".

#### Pause rules compared without a model, beside the app's own
`LiveTurnLatencyBenchmarkTests.studied`: Pause rules compared without a model, beside the app's own.

#### First decode after a load pays compilation and caching, so warm up
`LiveTurnLatencyBenchmarkTests.testTurnByTurnDelay`: The first decode after a load pays for compilation and caches.

#### Streaming recognizer is Nemotron 3.5, unused by the app; fresh stream per turn
`LiveTurnLatencyBenchmarkTests.testStreamingRecognizerDelay`: The same replay through a streaming recognizer, which reads the audio
as it arrives and puts words out while the speaker is still talking.
The speech library the app links has one (Nemotron 3.5 streaming); the
app does not use or download it, so point this at a folder that holds
one variant's compiled models (Benchmarks/transcribe/LiveTurns/fetch_stream_model.py):

TEST_RUNNER_LOKALBOT_LIVE_STREAM_MODEL=/folder/multilingual-560ms \
TEST_RUNNER_LOKALBOT_LIVE_TURN_LANGUAGES=en=en-US,sr=hr-HR

Each turn is a fresh stream, opened a little before its first word and
closed when the pause after it is long enough.

#### Real-time replay through LiveMeetingTranscriber shows end-to-end preview timing
`LiveTurnLatencyBenchmarkTests.testPreviewReplayInRealTime`: The call played into the app's own live preview at the speed it was
recorded. The two tracks grow as the recorder writes them, and
`LiveMeetingTranscriber` runs turn by turn as it does in a meeting,
with the real speech detection and the first model named. It shows
that the feature works end to end and when each line reached the
preview; it takes as long as the stretch it plays.

TEST_RUNNER_LOKALBOT_LIVE_REPLAY_SECONDS=90

#### A meeting's first line pays model load; benchmark measures later lines
`LiveTurnLatencyBenchmarkTests.testPreviewReplayInRealTime`: A meeting's first line pays for loading the model; this measures the ones after it.

#### Wait three seconds after the last sample for the last turn's text
`LiveTurnLatencyBenchmarkTests.testPreviewReplayInRealTime`: Three more seconds after the last sample, for the last turn's text.

#### Append a second of quiet so the last turn can close as in live recording
`LiveTurnLatencyBenchmarkTests.recordings`: A second of quiet after the last word, so the last turn can close
as it would while a recording goes on.

#### LOKALBOT_LIVE_TURN_RULES overrides pause rules; default is the app's own
`LiveTurnLatencyBenchmarkTests.rules`: `LOKALBOT_LIVE_TURN_RULES=2:4,1:off` times those pause rules; without it, the app's own.

#### Language hint syntax: sr=hr remaps the code, sr=auto passes none
`LiveTurnLatencyBenchmarkTests.hints`: `sr=hr` hands the model another language code for a recording; `sr=auto` hands it none.

#### Stream 256 ms chunks through VAD; max-length turns cut at quietest of last 1.5 s
`LiveTurnLatencyBenchmarkTests.cut`: Streams each track through the voice-activity model one 256 ms chunk
at a time, as a live feed arrives, and lets the app's `LiveTurnCutter`
close the turns. A turn that runs to the maximum length is cut at the
quietest point of its last 1.5 s, as the preview cuts its windows.
Pieces come back in the order they close.

#### A chunk's verdict exists only once the whole chunk has been recorded
`LiveTurnLatencyBenchmarkTests.cut`: The verdict on a chunk exists once the whole chunk has been recorded.

#### Simulates current preview windows: 4 s minimum, 12 s maximum, quiet-point cut, 1 s idle poll
`LiveTurnLatencyBenchmarkTests.windows`: `LiveMeetingTranscriber.run` and
`LiveMeetingAudioPreparationWorker.prepareNextChunk` on a simulated
clock: each track in turn gives up a window once 4 s are waiting (12 s
at most), cut at a quiet point and checked for speech; with nothing to
do the preview looks again a second later.

#### Last seconds of a track wait for the recording to stop
`LiveTurnLatencyBenchmarkTests.windows`: The last few seconds of a track wait for the recording to stop.

#### Preview hands models 16 kHz mono float audio
`LiveTurnLatencyBenchmarkTests.write`: 16 kHz mono float, the format the preview hands a model.

#### CPU time excludes models in helper processes such as Granite Speech
`LiveTurnLatencyBenchmarkTests.cpuSeconds`: CPU time this process has used, all threads. A model that runs in a
helper process (Granite Speech) is not counted.

#### assert is compiled out of optimized builds whatever flags are set
`LiveTurnLatencyBenchmarkTests.isOptimized`: `assert` is compiled out of optimized builds, whatever flags are set.

### `LokalBotTests/Integration/MCPServerIntegrationTests.swift`

#### Real MCP clients keep stdin open; server must answer initialize first
`MCPServerIntegrationTests.testAnswersInitializeWhileStdinStaysOpen`: Real clients (Claude Code, Claude Desktop) keep stdin open; the server
must answer initialize before the client sends anything else.

### `LokalBotTests/Integration/ModelReplayTests.swift`

#### Replays nightly-recorded GLM 5.3 Flash and Qwen3.8 Flash answers
`ModelReplayTests`: Real GLM 5.3 Flash / Qwen3.8 Flash answers (recorded nightly), replayed
through the real engine and generators.

#### Real models tidy quotes and cite adjacent rows; user's commitments must stay theirs
`ModelReplayTests.testRecordedRunOnStandupKeepsBothOfMyCommitmentsMine`: Real models tidy what they quote and cite a row beside the one that
carries "I have to". Both of the user's commitments in the run-on
standup must still come out as theirs, and nobody else's as theirs.

### `LokalBotTests/Integration/ModelServerScenarioTests.swift`

#### Digest and Ask run through real engine against the scenario stub
`ModelServerScenarioTests`: Digest and Ask through the real `OpenAICompatibleEngine` (OpenRouter
dialect) against the scenario stub, so request shaping and recovery are
exercised end to end.

#### Always-reasoning models reject none; retry once at low
`ModelServerScenarioTests.testRejectedReasoningLevelRetriesOnceAtLow`: A model that always reasons rejects `none`; the chosen level must not
fail the request, and the retry must be the only extra call.

#### Reasoning of 2,030 tokens leaves no room for the answer in 2,048
`ModelServerScenarioTests.testReasoningHeavyModelFitsOnTheLargerRetry`: ~40-token answer no longer fits in 2,048

#### Refused streams once reported empty error because the body was never read
`ModelServerScenarioTests.testARefusedStreamKeepsTheProvidersReason`: A refused streamed request reported "empty error response": the
error was built without reading the body the provider sent.

### `LokalBotTests/Integration/PerformanceReadPathTests.swift`

#### Presentation adds display-only speaker names such as Speaker 3
`PerformanceReadPathTests.testLongTranscriptNamePreparationBenchmark`: The presentation adds display-only names ("Them 3" → "Speaker 3").

#### Migration must handle FTS rows whose row IDs differ from capture IDs
`PerformanceReadPathTests.testOCRIndexMigrationKeepsHistoricalIdentityAndRetention`: Exercise migration of real FTS rows whose row IDs differ from capture IDs.

#### Quiet browser windows rewalked only on title change or age: 2 walks a minute not 30
`PerformanceReadPathTests.testQuietBrowserWindowIsWalkedAgainOnlyOnTitleChangeOrAge`: Meet detection polls every 2 s. A browser window whose complete read
found no Meet document is walked again only when its title changes or
the entry ages out: 2 walks a minute instead of 30.

#### Microphone changes such as a call starting clear the whole cache
`BrowserMeetingSession.QuietWindowCache`: Microphone changes (a call starting) clear everything.

#### Sampler reads page addresses only to apply site exclusions
`PerformanceReadPathTests.testActivitySamplesWalkPagesOnlyWhenSitesAreExcluded`: Activity samples (every 5 s) need a page address only to apply site
exclusions; without any, the sampler reads the window, not its pages.

#### Retention clears one path at a time via the partial path index
`PerformanceReadPathTests.testRetentionPathClearUsesThePathIndex`: Daily retention clears one expired capture's path at a time on the main
actor; each clear must use the partial path index, not scan every row.

### `LokalBotTests/Integration/PiIntegrationTests.swift`

#### End-to-end with real Bun and pinned pi against stub; skips without runtime
`PiIntegrationTests`: End-to-end: real Bun, real pinned pi runtime, our real extension, talking to a
stub OpenAI server. Skips when the vendored runtime isn't installed
(enable Agent Mode in the app once to install it).

#### Host app bundles pi resources so the test never reads the checkout
`PiIntegrationTests.testPromptRoundTripsThroughRealPi`: The host app bundles LokalBot/Resources/pi, so the test never
reads the checkout.

#### Collector task returns the verdict; deadline cancels it so value resolves to false
`PiIntegrationTests.testPromptRoundTripsThroughRealPi`: No mutable capture: the collector Task RETURNS the verdict.
If the reply never arrives, the deadline task cancels the collector,
the for-await loop ends, and `collector.value` resolves to false.

### `LokalBotTests/Integration/RedesignContractTests.swift`

#### Relevance order can differ from chronology; source grouping must stay complete
`RedesignContractTests.testScreenGroupingPreservesRelevanceAndAllMomentsInLongSessions`: Relevance order can be unrelated to chronology, including a bridge
between initially distant hits. Source grouping must still be complete.

#### Recall fills snippets per session; groups must equal filling every hit first
`RedesignContractTests.testLazilyFilledScreenGroupsMatchFillingEveryHit`: Recall fills snippets one session at a time; the groups must equal
filling every hit first, including sessions an unreadable hit splits.

#### New random seed each run, named in failures for reruns
`RedesignContractTests.testLazilyFilledScreenGroupsMatchFillingEveryHit`: A new seed on every run, named in each failure so the round can be run again.

#### Every fifth hit lacks a snippet; windows 9 to 11 are untitled and unreadable
`RedesignContractTests.testLazilyFilledScreenGroupsMatchFillingEveryHit`: Every fifth hit has no snippet; in windows 9–11, which have no title, it is unreadable.

### `LokalBotTests/Integration/ReuseSubsystemsTests.swift`

#### 8 GB band: comfortable up to 4.8, too large above 6.4; model needs 1.3x
`ModelFit.evaluate`: 8 GB → comfortable ≤4.8, too-large >6.4. 4 GB model needs ~5.2 → tight.

#### A 6 GB model needs about 7.8 GB, over the 6.4 limit on 8 GB
`ModelFit.evaluate`: 8 GB, 6 GB model needs ~7.8 > 6.4 → too large.

#### Retries of the same URL share a stash to resume; different URLs never do
`ParallelRangeDownloader.stashName`: Two attempts at the same URL must land on the same stash so a retry
resumes; different URLs must never share one.

#### Disk precheck credits stashed bytes by allocated size, 0 when nothing stashed
`ParallelRangeDownloader.stashedByteCount`: The disk-space precheck credits stashed bytes against the expected
download size, so the count must read the actual partial for that URL
(by allocated size) and be 0 — never an error — when nothing is stashed.

#### Precheck is an early courtesy that never blocks unknown sizes
`DiskSpacePrecheck.advisory`: Unknown size or unreadable volume must not block a download — the
precheck is an early courtesy, not a gate that can wedge shut.

#### Unreadable volume must not block recording, same courtesy posture
`DiskSpacePrecheck.recordingAdvisory`: An unreadable volume must not block recording — same courtesy-not-gate
posture as the download precheck.

#### Task instruction must survive at the tail of the composed prompt
`AppleIntelligenceEngine.composePrompt`: task instruction must survive at the tail

### `LokalBotTests/Integration/ScaleTests.swift`

#### Nightly scale test on large seed profile; budgets reflect launch-time user perception
`ScaleTests`: Nightly only (`LOKALBOT_SCALE_LIBRARY` points at a copy of the `large`
seed profile). Budgets reflect what a user notices at launch.

### `LokalBotTests/Integration/SeedLibraryCompatibilityTests.swift`

#### Reading the demo seed via app stores keeps its schema in step with the app
`SeedLibraryCompatibilityTests`: The day-in-the-life run seeds its library with `Scripts/test/seed_demo_library.py`.
Reading that seed through the app's own stores keeps the script's schema in
step with the app, so a drift fails here instead of in the slower workday job.

#### Test bundle carries a copy of seed_demo_library.py, per project.yml
`SeedLibraryCompatibilityTests.testFullDaySeedIsReadableByTheAppStores`: A copy of Scripts/test/seed_demo_library.py; see project.yml.

#### Demo seed makes upgrade fixtures, so About you must decode every stored origin
`SeedLibraryCompatibilityTests.testDemoSeedAboutYouIsReadableByThePersonalModel`: The demo seed is also what upgrade fixtures are made from, so its About
you file must decode with every origin the app stores.

#### Test bundle carries a copy of seed_demo_library.py, per project.yml
`SeedLibraryCompatibilityTests.testDemoSeedAboutYouIsReadableByThePersonalModel`: A copy of Scripts/test/seed_demo_library.py; see project.yml.

### `LokalBotTests/Integration/UpgradeMigrationTests.swift`

#### Every committed release fixture from 0.6.2 must survive migration and load
`UpgradeMigrationTests`: Every committed release fixture (0.6.2 … current) must survive today's
migration and library load with its approvals, schedules, search, and
encrypted data intact.

#### Personal Context sealed with chat key; first fixture with it follows 0.10.7
`UpgradeMigrationTests.testAboutYouFromEveryReleaseStillLoads`: Every release's chats (plain files from its seed, or sealed ones the
app wrote) must still open with today's chat store.
Personal Context is sealed with the chat key, as each release wrote it.
Releases before it have no file; the first fixture with one is the
release after 0.10.7.

#### Run real migration without its launch gate, with fixture defaults and synthetic keys
`UpgradeMigrationTests.testMigrationLeavesEveryReleaseReady`: Runs the real migration (without its launch gate, which skips every
test host) on each release's library, with the fixture's defaults and
its synthetic keys in place of the Keychain.

#### Fixture screenshot paths point at the CI seed folder and need relocating
`UpgradeMigrationTests.relocateScreenshotPaths`: Each release wrote absolute screenshot paths under the folder it seeded
on the CI runner. An in-place upgrade finds them under the library's
own location, so point them at the copy before migrating.

#### Releases since 0.6.2 store screenshots as AES.GCM sealed with screenshot key
`UpgradeMigrationTests.sealSeededScreenshots`: Seeds write plain demo images; every release from 0.6.2 on stores
screenshots as `AES.GCM.seal(image, screenshot-key).combined`. Seal
them the same way so key recovery sees what a release wrote.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
