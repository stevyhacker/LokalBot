# 0027. Mac app: Engines tests

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBotTests/Engines/`.

## Decisions

### `LokalBotTests/Engines/AnthropicEngineTests.swift`

#### Current Claude models reject non-default sampling; omit temperature and thinking
`testRequestUsesMessagesAPIWithCacheBreakpointsAfterSharedMaterial`: Current Claude models reject non-default sampling.

#### Anthropic compat layer rejected maxItems in meeting notes schema (2026-10-08)
`testMeetingNotesSchemaFitsAnthropicsSubset`: Anthropic's OpenAI compatibility layer rejected meeting notes with
"For 'array' type, property 'maxItems' is not supported" (2026-10-08).

#### Opus 4.8 does not think unless asked; Automatic leaves effort unset
`testEffortFollowsTaskBudgetAndChosenLevel`: Opus 4.8 does not think unless asked, so Automatic leaves it alone.

#### A schema rejection never permits weakening structured output
`testOtherRejectionsAreReportedWithAnthropicsRequestID`: A schema rejection is not permission to weaken structured output.

### `LokalBotTests/Engines/AnthropicLiveTests.swift`

#### Live test sends synthetic text; needs ANTHROPIC_API_KEY, optional model override
`AnthropicLiveTests`: Sends synthetic text to Anthropic's API. Runs only when `ANTHROPIC_API_KEY`
is set (pass `TEST_RUNNER_ANTHROPIC_API_KEY` through xcodebuild);
`LOKALBOT_ANTHROPIC_MODEL` overrides `claude-sonnet-5-5`.

### `LokalBotTests/Engines/FunASRNanoModelTests.swift`

#### Same-size in-place file replacement must change checkpoint; size and folder insufficient
`FunASRNanoModelTests`: Same-size in-place replacement: size and folder alone are insufficient.

### `LokalBotTests/Engines/FunASRNanoRuntimeTests.swift`

#### Partial Fun-ASR results fail so the caller retains the recording for retry
`FunASRNanoRuntimeTests`: Expected: the caller retains the recording for a retry.

#### Exit wait must not depend on launching thread's run loop; runs stranded
`testRepeatedRunsAllReturn`: Each await in runBatch may resume on another thread. While the exit
wait depended on the launching thread's run loop, a few dozen runs
were enough to strand one forever.

#### Stuck runtime fails within a timeout instead of stalling CI
`FunASRNanoRuntimeTests.run`: A stuck runtime fails the test within `timeout` instead of stalling CI
until the job's time limit.

### `LokalBotTests/Engines/InferenceRedirectTests.swift`

#### Loopback fixture waits for full body so 307/308 replay is observable
`RedirectHTTPFixture`: Loopback-only HTTP fixture. It waits for the full request body before
replying, making 307/308 replay observable without real work data.

### `LokalBotTests/Engines/LanguageVoteTests.swift`

#### Length-weighted vote over segments decides track language and whether to pin
`LanguageVoteTests`: Auto-detected language handling for Qwen transcripts: a length-weighted
vote over segments decides the track's language and whether to pin it.

#### Qwen auto-detect misfire from benchmark standup must not decide the track
`testAMisdetectedOpeningDoesNotDecideTheTrack`: A Qwen auto-detection misfire from the benchmark's standup meeting.

#### Aligner still gets a dominant language for word splitting on mixed tracks
`testMixedLanguageTracksStayOnPerWindowDetection`: The aligner still gets a dominant language for word splitting.

#### Apple reads Latin Serbian as Croatian, unlisted by Qwen; pin to Croatian
`testSerbianCroatianAndBosnianTracksPinToCroatianInEitherScript`: Apple's recognizer reads Latin-script Serbian as Croatian, which Qwen
does not list, so these tracks used to stay on auto and drift into
Chinese, Japanese, Hindi, Macedonian or Russian script.

#### Without aliases the two scripts split one language into two votes
`testSerbianCroatianAndBosnianTracksPinToCroatianInEitherScript`: Without the aliases, the scripts split the same language in two.

### `LokalBotTests/Engines/LlamaCoreSmokeTests.swift`

#### Pinned runtime defaults n_gpu_layers to -1, meaning full Metal offload
`testBackendInitAndDefaultParamsLink`: The n_gpu_layers field must be reachable through the imported struct.
The pinned runtime defaults it to -1 ("a negative value means all layers" per
llama.h) — i.e. full Metal offload, exactly what the runtime wants.

#### Never call llama_backend_free in the shared test process
`testBackendInitAndDefaultParamsLink`: Intentionally NOT calling llama_backend_free(): this runs in the shared
test process, and freeing the global backend here would be a footgun for
any test class that loads a model (LlamaCotypingRuntime's once-let init).
The smoke test's purpose — LlamaCore imports, dylib links, default-params
structs resolve — needs no teardown.

### `LokalBotTests/Engines/LlamaServerIsolationTests.swift`

#### Each app copy uses own llama-server ports; dead copy's orphan must not block start
`LlamaServerIsolationTests`: Each LokalBot copy runs its llama-servers on its own ports, and a helper a
dead copy left behind does not block the next start. 2026-10-09 to 10-12:
an orphaned UI Test Host embedder held 127.0.0.1:17873, the installed app's
embedder could not start, and meeting and screen embeddings silently
stopped; the unit-test host also wrote the installed app's PID marker.

#### Unit-test host carries the release bundle id
`testRuntimeOwnerFollowsIdentityAndTheUnitTestHost`: The unit-test host carries the release bundle id.

#### Owner with unreadable start time may still be the owner
`testOnlyAMarkerWithALiveOwnerProtectsAHelper`: An owner whose start time cannot be read may still be the owner.

#### Real processes: a copy of nc named llama-server stands in for a helper
`OrphanedLlamaServerReclaimTests`: Real processes: a copy of `nc` named llama-server stands in for a helper.

#### Marker reproduces the incident: owner UI Test Host has exited
`testStopsAHelperLeftBehindByAnotherAppCopy`: The incident's marker: its owner, the UI Test Host, has exited.

#### Helper listens on loopback; reparented makes launchd its parent as when app dies
`OrphanedLlamaServerReclaimTests.startHelper`: Listens on 127.0.0.1:`port` from `<root>/<folder>/llama-cpp/test/llama-server`.
`reparented` makes launchd its parent, as when the owning app dies.

#### Copied platform binary is killed at launch until re-signed
`OrphanedLlamaServerReclaimTests.startHelper`: A copied platform binary is killed at launch until it is re-signed.

#### Fail not skip: listeningPIDs is the code under test
`OrphanedLlamaServerReclaimTests.startHelper`: Not a skip: `listeningPIDs` is the code under test, and every test
here would go quiet if it stopped seeing a listener.

### `LokalBotTests/Engines/LlamaServerTests.swift`

#### Chunks split lines like pipe reads; shape of real corrupt-model output
`testOutputTailSaysWhyAStartFailed`: Chunks split lines, as pipe reads do.
The shape of llama-server's real output for a corrupt model file.

#### Once serving, server errors can quote request text; keep only crash lines
`testOutputTailKeepsOnlyCrashLinesOnceServing`: Once the server answers requests, its errors can quote request text.

#### Built-in servers must be loopback-only; otherwise data exfiltration
`testSharedServersAreLoopbackOnlyAndOnDistinctPorts`: The privacy story requires every built-in server to be reachable only
via loopback. A non-loopback base URL here would be a data-exfiltration
bug, not a configuration choice.

#### Private instance on unused port keeps test off production token files
`testAuthenticationTokenIsStableAndHighEntropy`: A private instance on an unused port: the token path is derived from
the port, so this never touches the production token files.
The persisted token file is removed on both ends of the test.

#### Opt-in replay never downloads models or touches production ports; artifacts stay private
`testLocalGraniteRegionReplayKeepsOneProcess`: Opt-in native replay; never downloads models or touches production
ports. Audio, responses and timing artifacts stay in the private folder.

### `LokalBotTests/Engines/ModelBudgetGuardTests.swift`

#### Token budget cuts truncating shipped presets fail before release; happened twice
`ModelBudgetGuardTests`: A token budget cut that would truncate a model we ship presets for fails
here, before release. This happened twice (e5077c3, then #117).

#### muse-spark uses ~1,400 reasoning tokens despite effort none, then ~300-token answer
`ModelBudgetGuardTests.reasoningHeavyTokens`: The muse-spark behaviour behind #117: about 1,400 reasoning tokens
regardless of `effort: none`, then a ~300-token focus answer.

#### Repairs get no expanded retry; truncated one doubles up to 4K
`ModelBudgetGuardTests.retryBudget`: Repairs get no expanded retry; a truncated one doubles up to 4K.

### `LokalBotTests/Engines/ModelDownloadRoutingTests.swift`

#### HF-Mirror and ModelScope serve pinned files in China; mismatches rejected
`ModelDownloadRoutingTests`: huggingface.co is blocked in mainland China. HF-Mirror and ModelScope serve
the same pinned files there, and a file is accepted only if it matches the
pin, so a source can fail a download but never change a model.

#### ModelScope follows branches, so fetch only when listed SHA-256 equals the pin
`testModelScopeServesOnlyTheExactPinnedFile`: ModelScope follows branches, not Hugging Face revisions, so only a file
whose listed SHA-256 equals the pin is fetched there.

#### Mirror file missing the pin is deleted and next source tried
`testAMirrorFileThatMissesThePinIsDiscardedForTheNextSource`: A mirror's file that misses the pin is deleted and the next source is
tried, instead of the whole download failing its integrity check.

### `LokalBotTests/Engines/ModelResidencyTests.swift`

#### Same-runtime model swap replaces in place; its old row is not evicted
`testIncomingIDIsNeverAVictim`: A model swap on the same runtime replaces in place: its old row must
not be evicted (the runtime restart handles the old weights).

### `LokalBotTests/Engines/OpenRouterModelCatalogTests.swift`

#### Settings view's task is cancelled on disappear; lookup must continue
`testACancelledCallerDoesNotCancelTheLookup`: A Settings view's task is cancelled when the view disappears.

#### Failed lookup keeps last context window so meeting part plan survives relaunch
`testKeepsTheLastPublishedWindowWhenALookupFails`: A relaunched app whose lookup fails keeps the same window, so the
meeting's part plan and partial notes survive.

### `LokalBotTests/Engines/ParallelRangeDownloaderTests.swift`

#### Ranged downloads tested end to end through the app's URLSession path
`ParallelRangeDownloaderTests`: End-to-end ranged downloads against an in-process server, so the bytes
that reach the partial file (and how many times they are written) are
checked through the same URLSession path the app uses.

#### Write each model byte once; macOS flags apps dirtying GBs of file-backed memory daily
`testRangedDownloadWritesEachByteToDiskOnce`: macOS flags an app once it dirties gigabytes of file-backed memory a
day. Each byte of a model must be written once: landing every part in
a download task's temp file and then copying it into the partial wrote
it twice (137 GB in one 0.10.8 session).

#### Failed part stops attempt; completed parts survive; retry fetches only missing
`testRetryFetchesOnlyMissingPartsAndAssemblesExactBytes`: A failed part stops the attempt, completed parts survive it, and the
retry fetches only what is missing while still assembling exact bytes.

#### Whole-file answer to a ranged GET is refused before writing
`testWholeFileAnswerToARangeIsRejectedBeforeWriting`: A server that answers a ranged GET with the whole file must be
refused before any of that body lands at the part's offset.

#### Each 4-byte word holds its index so misplaced parts cannot compare equal
`ParallelRangeDownloaderTests.numberedBytes`: Every 4-byte word holds its own index, so a part written at the wrong
offset cannot compare equal.

#### Counter matches macOS disk-writes report: file-backed memory dirtied by the process
`ParallelRangeDownloaderTests.logicalWriteBytes`: The counter macOS's disk-writes report reads: bytes of file-backed
memory this process has dirtied.

#### Stub mimics Hugging Face CDN HEAD and Range GETs in 64 KB chunks
`RangeServerStub`: Serves HEAD and `Range: bytes=a-b` GETs for one in-memory file, like the
Hugging Face CDN, in 64 KB chunks so each part arrives in many callbacks.

### `LokalBotTests/Engines/QwenASREngineTests.swift`

#### speech-swift uses Hub layout base/models/org/model for aligner and MLX cleanup
`testHubStyleCacheDirMatchesPackageLayout`: speech-swift's loaders use the Hub layout `base/models/<org>/<model>`.
The forced aligner lives there, and both Qwen tiers find the MLX
weights they replaced there to delete them.

#### Crash on 30 s + 11-sample WAV: empty features made encoder stack empty array
`testSubFrameAudioRetainsSamplesAndProducesEncoderFrames`: The crash left a 30 s + 11-sample WAV. Its final split had no
features, causing Qwen3AudioEncoder to stack an empty array.

### `LokalBotTests/Engines/QwenLanguageSampleReplayTests.swift`

#### Opt-in replay compares before and after language sampling; env vars name job and models
`QwenLanguageSampleReplayTests`: Opt-in replay for Benchmarks/transcribe/QwenLanguageSample. Decodes
benchmark tracks on Qwen3-ASR 1.7B's llama-server with the language on
auto-detect, as the engine did before language sampling (`before`: every
window on auto, then the whole track again when its vote holds) and as it
does now (`after`: `QwenASREngine.decodeOnAuto`). Windows come from the
app's own VAD path, in the plain layout (`transcribe`) or the merged
word-attribution layout. Each track, layout and mode appends one JSON line
with every window decode, its time and its language vote, and the result.

LOKALBOT_QWEN_SAMPLE_MANIFEST names the job (see make_manifest.py there);
LOKALBOT_QWEN_LLAMA_TEST_MODEL_DIR holds both 1.7B GGUFs. Runs resume.

#### Modes before and after run in this order per track and layout
`QwenLanguageSampleReplayTests.Manifest.modes`: "before" and/or "after", run in this order for each track and layout.

#### Alternate mode order so each pair shares machine state for timing
`QwenLanguageSampleReplayTests.Manifest.alternate`: Reverse the order of `modes` on every other track and layout, so
the two paths of a pair share the machine's state for timing.

#### Plain layout uses VAD spans up to 15 s; word layout uses merged windows
`QwenLanguageSampleReplayTests.Manifest.layouts`: "plain" (VAD spans of at most 15 s) and/or "word" (merged windows).

#### Sample sizes whose spans are recorded for offline simulation
`QwenLanguageSampleReplayTests.Manifest.sampleSizes`: Sample sizes whose spans are recorded for the offline simulation.

#### nil language means auto-detect
`QwenLanguageSampleReplayTests.Window.language`: nil: auto-detect.

#### Auto windows record aliased language vote and character weight; nil and 0 if none
`QwenLanguageSampleReplayTests.Window.vote`: Auto windows: the language this window's text votes for, aliased
as the engine's vote does, and its weight (characters); nil and 0
when it does not vote.

#### Warm up: first decode after launch pays Metal shader compilation
`QwenLanguageSampleReplayTests`: The first decode after launch pays Metal's shader compilation.

#### Engine's decoder timed per window; no prompt so no echoes to drop
`QwenLanguageSampleReplayTests`: The engine's decoder, timed per window (no prompt, so no echoes to drop).

#### Reproduces pre-sampling auto path: all auto, whole-track vote, redecode unless aligner cannot time
`QwenLanguageSampleReplayTests.decodeAsBefore`: The engine's auto-detect path before language sampling, line for line:
every window on auto, the whole-track vote, and every window again in
the voted language unless the aligner cannot time it.

### `LokalBotTests/Engines/QwenLanguageSampleTests.swift`

#### Qwen votes language on a sample of spans then decodes once, pinned
`QwenLanguageSampleTests`: Qwen on auto-detect votes the track's language on a sample of its spans,
then decodes the track once, pinned, instead of twice
(Benchmarks/transcribe/QwenLanguageSample).

#### Aligner cannot time Croatian; speaker regions decode it so rest would be wasted
`testCroatianTrackForWordAttributionStopsAfterTheSample`: The aligner cannot time Croatian, so the track goes to speaker regions
decoded in it; decoding the rest of the track here would be thrown away.

#### A language change in the last stretch reaches the sample; do not pin opening language
`testLateLanguageChangeKeepsTheTrackOnAuto`: A language change in the last stretch reaches the sample, so the track
is not pinned to the language it opened in.

#### Sample hitting misdetected windows falls back to whole-track vote
`testTrackTheSampleMisjudgedIsStillPinnedByTheWholeTrackVote`: The sample can land on a track's few misdetected windows. The rest
then decodes on auto and the whole track votes, as it did before
sampling, so the track is still pinned.

#### Sample pins only on a clearer vote than the whole track needs
`testSampleBelowItsShareFallsBackToTheWholeTrackVote`: The sample pins only on a clearer vote than the whole track needs:
one other-language span in eight is too coarse a reading of a track
that may sit near 80%. The whole track then votes as before.

### `LokalBotTests/Engines/QwenLlamaASRTests.swift`

#### Prompt must match speech-swift Qwen3ASRModel token for token for benchmarked hints
`testPromptMatchesSpeechSwiftLayout`: The prompt must match speech-swift's Qwen3ASRModel token for token, or
the language hint and vocabulary stop working as benchmarked.

#### Each Qwen ASR tier has its own server; dictation and meetings may use different tiers
`testQwenServersHaveTheirOwnPortsAndTranscribeRows`: Each tier has its own server: dictation and meetings can use different
tiers at the same time.

#### Opt-in end-to-end needs both GGUFs and a public clip; server must honor media marker
`testCachedModelsTranscribeAWindowOnTheAppServer`: Opt-in end to end: the app's `qwen-asr` llama-server with the pinned
GGUFs transcribes real speech through `QwenASREngine.transcribeWindow`.
A request fails if the server ignores LLAMA_MEDIA_MARKER, since the
prompt then lacks its randomized marker. Needs a folder with both GGUFs
and a public speech clip (FLEURS or AMI); only the first 15 s is sent.

#### Env var TIER=0.6b runs the compact tier's pair
`testCachedModelsTranscribeAWindowOnTheAppServer`: LOKALBOT_QWEN_LLAMA_TEST_TIER=0.6b runs the compact tier's pair.

### `LokalBotTests/Engines/RemoteInferenceGateTests.swift`

#### Notes failed after one replay while digest and Dream rate-limited; now wait on cooldown and retry
`testMeetingNotesSurviveARunOfRateLimits`: Tonight's meeting notes failed after one replay seven seconds later
while the day digest and Dream kept the provider rate limited. Notes now
wait on the origin's cooldown and retry until the provider recovers.

### `LokalBotTests/Engines/RemoteTranscriptionEngineTests.swift`

#### Server sends audio off the Mac; tests pin approval, HTTPS rules, request contents, timings
`RemoteTranscriptionEngineTests`: The transcription server sends meeting audio off the Mac, so these tests
pin where it may go (approval, HTTPS outside the user's own network), what
each request carries, and how chunked results keep their timing.

#### Revoking the server mid-meeting must keep remaining audio on this Mac
`testUploadsStopOnceTheServerIsRevoked`: A long meeting is hundreds of uploads from one engine. Revoking the
server after the first must keep the rest of the audio on this Mac.

#### Changing the model while waiting to retry must stop the upload
`testRetryDoesNotSendTheClipOnceTheModelChanges`: The person changes the model while the engine waits to retry.

#### Server on this Mac sends nothing off it, so never cut short
`testConsentCheckFollowsTheLiveSettings`: A server on this Mac sends nothing off it, so it is never cut short.

#### Cutting at every turn sent each sub-second fragment as its own request
`testSpeakerTurnsAreAttributedAfterTranscription`: Cutting at every turn sent each sub-second fragment as its own request.

#### A 50 ms span holds no words
`testSpansTooShortToHoldWordsAreNotUploaded`: 50 ms holds no words

#### Fixture recorded from MAI-Transcribe-2 on OpenRouter 2026-10-19, synthetic say clip
`RemoteTranscriptionEngineTests.recordedVerboseJSON`: MAI-Transcribe-2 on OpenRouter, 2026-10-19: a synthetic `say` clip,
Samantha from 0 s and Daniel from 5.0 s.

### `LokalBotTests/Engines/RemoteTranscriptionLiveTests.swift`

#### Live test needs OPENROUTER_API_KEY; model overridable by env var
`RemoteTranscriptionLiveTests`: Sends a synthetic two-voice `say` clip to OpenRouter. Runs only when
`OPENROUTER_API_KEY` is set (pass `TEST_RUNNER_OPENROUTER_API_KEY` through
xcodebuild); `LOKALBOT_OPENROUTER_TRANSCRIPTION_MODEL` overrides
`microsoft/mai-transcribe-2`.

#### Second voice starts 5 s into a window starting 1 s into the track
`testServerWordTimesSplitTwoVoicesOnTheTrackTimeline`: The second voice starts 5 s into a window that starts 1 s into the track.

### `LokalBotTests/Engines/RuntimeAssetSafetyTests.swift`

#### Fixture models a version folder left behind by a quit app
`RuntimeAssetSafetyTests.unusedVersion`: A version folder as an app that has since quit leaves it behind.

#### A running LokalBot holds a shared flock claim on each version
`RuntimeAssetSafetyTests.testInstallKeepsVersionAnotherAppClaimsUntilItQuits`: What a running LokalBot holds on each version it uses.

### `LokalBotTests/Engines/ServerContextWindowCatalogTests.swift`

#### vLLM reports its context window in max_model_len
`ServerContextWindowCatalogTests.testModelListsNameTheWindowInEachServersOwnField`: vLLM

#### Groq reports its context window in context_window
`ServerContextWindowCatalogTests.testModelListsNameTheWindowInEachServersOwnField`: Groq

#### Together and DeepInfra report context_length
`ServerContextWindowCatalogTests.testModelListsNameTheWindowInEachServersOwnField`: Together, DeepInfra

#### Mistral reports its context window in max_context_length
`ServerContextWindowCatalogTests.testModelListsNameTheWindowInEachServersOwnField`: Mistral

#### Cerebras and OpenAI model lists report no context window
`ServerContextWindowCatalogTests.testModelListsNameTheWindowInEachServersOwnField`: Cerebras, OpenAI: none

#### Reported window beats the documented one; silent providers keep documented
`ServerContextWindowCatalogTests.testReportedWindowsComeBeforeDocumentedOnes`: The reported window beats the documented one, and a provider that
reports nothing keeps its documented window.

### `LokalBotTests/Engines/SpanAudioReaderTests.swift`

#### SpanAudioReader decodes one span window at a time to save memory
`SpanAudioReaderTests`: `SpanAudioReader` is the memory fix for transcription: engines decode one
span's window at a time instead of holding a whole decoded track. These
tests pin the window arithmetic (position, clamping, resampling) against
real files written to a temp directory.

#### Ramp samples encode position, proving the seek; 16-bit WAV needs tolerance
`SpanAudioReaderTests.testWindowReadsTheRequestedRegion`: A 2 s ramp at 16 kHz: sample i encodes i, so a window's first decoded
sample proves the seek landed on the right frame (16-bit WAV quantizes,
hence the tolerance).

#### AVAudioConverter withholds about 100 tail frames, immaterial given 100 ms VAD padding
`SpanAudioReaderTests.testResamplesNon16kSources`: A 32 kHz source must come out resampled to 16 kHz. AVAudioConverter's
rate-conversion filter withholds a tail of ~100 frames (a few ms) even
when drained — immaterial for ASR, where VAD pads every span by 100 ms —
so the count assertion carries a matching tolerance.

#### PCM16 matches speaker-region WAVs and exposes converter extra tail samples
`SpanAudioReaderTests.testResamplerTailCannotExtendASRWindow`: PCM16 matches the speaker-region WAVs and avoids a partial
float-CAF read hiding the converter's extra tail samples.

### `LokalBotTests/Engines/TextEngineTests.swift`

#### GLM 5.3 on OpenRouter offers low, high, max and cannot be switched off
`ReasoningSupport`: GLM 5.3 on OpenRouter: low/high/max and no way to switch it off.

#### Automatic must turn reasoning off for no-reasoning tasks; Cerebras Qwen returned no notes 2026-10-07
`ReasoningSupport.requestLevel`: On 2026-10-07, on Automatic, Cerebras Qwen reasoned at its default for
every notes request and returned no notes.

#### Cerebras reasoning levels follow its documented values
`ReasoningSupport.known`: Cerebras's documented values.

#### GPT-6 levels come from OpenAI model pages of 26 October 2026
`ReasoningSupport.known`: OpenAI's model pages on 26 October 2026. GPT-6 models used to have no
levels, so Settings showed "Set by the model" and a chosen level never
reached the request.

#### OpenAI treats GPT-6 as reasoning: no temperature, Automatic maps budget to effort
`OpenAICompatibleEngine.makeChatRequest`: OpenAI's API treats GPT-6 as a reasoning model: no temperature, and
Automatic maps a task's budget onto an effort.

#### Stop cancellation must surface as CancellationError, not serverUnreachable shown red
`OpenAICompatibleEngine.generate`: Pressing Stop cancels the Task mid-request; `send` must surface that as
cancellation, not a `serverUnreachable` error the chat UI renders red.

#### Blackholed TEST-NET address so the request resolves only via cancellation
`OpenAICompatibleEngine.generate`: Blackholed TEST-NET address (RFC 5737): the request can only resolve
via cancellation, never a real connection or a fast refusal.

### `LokalBotTests/Engines/ThinkChatTests.swift`

#### A later user message such as the nudge is what is asked
`ThinkChat.request`: A later user message, such as the last turn's nudge, is what is asked.

### `LokalBotTests/Engines/ThinkExecutionTests.swift`

#### External servers are wrapped in the shared per-origin request gate
`ThinkExecution.makeTextEngine`: External servers are wrapped in the shared per-origin request gate.

### `LokalBotTests/Engines/TranscriptionModelStoreTests.swift`

#### Removed Granite Turbo selection decodes as Parakeet v2, not corrupted settings
`TranscriptionModelChoice decoding`: Granite Speech 5 TurboCTC was removed: a saved selection, by raw value
or by its old display name, decodes as Parakeet v2 instead of resetting
the settings as corrupted.

#### Retired Granite Turbo folder deleted by exact path; symlinks and others left alone
`TranscriptionModelStore.removeRetiredModels`: The retired Granite Turbo folder is deleted by exact path; other model
folders and a symlink in its place are left alone.

#### Qwen tiers run on llama.cpp; old MLX weights alone do not count
`TranscriptionModelStore.isDownloaded`: Both tiers run on llama.cpp now: their GGUFs count as downloaded, the
old MLX weights alone do not, and deleting a tier removes both.

#### Launch readiness must not reach into ~/Documents
`TranscriptionModelStore.isDownloaded`: Readiness runs at launch and must not reach into ~/Documents.

#### Skip listing legacy ~/Documents cache once Application Support has a model
`TranscriptionModelStore.migrateLegacyWhisperKitModels`: Whisper prepares on every app start for people who use it, so once
Application Support has a model the legacy ~/Documents cache is not
even listed: listing it makes macOS ask for Documents access.

#### FluidAudio counts a model folder only with coremldata.bin and no .partial
`TranscriptionModelStoreTests.writeFluidAudioComponent`: FluidAudio counts a compiled model only when it is a folder with its
`coremldata.bin` and no `*.partial` download left inside.

### `LokalBotTests/Engines/WithdrawnTranscriptionServerTests.swift`

#### Withdrawn-server error must reach the pipeline because it decides the meeting's fate
`WithdrawnTranscriptionServerTests`: A transcription server withdrawn while a meeting is being transcribed: the
error that says so has to reach the pipeline, whatever else went wrong on
the way, because it decides what happens to the meeting next.

#### A revoked server in a later track wins over an earlier server error
`ProcessingPipeline.trackFailure`: The microphone track failed with a server error, then the server was
revoked during the system track. The first error used to win, and the
meeting was marked failed instead of starting over.

#### A withdrawn server is never skipped as a rejected sliver
`AttributedTrackTranscriber.transcribe`: With speaker turns, a region under a second that the engine rejects is
skipped. A withdrawn server is not such a sliver: skipped, the track
finished without the rest of its audio.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
