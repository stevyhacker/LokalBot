# 0023. Mac app: Dictation

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Dictation/`, `LokalBot/Views/Dictation/`, `LokalBotTests/Dictation/`.

## Decisions

### `LokalBot/Dictation/DictationAudioHandoff.swift`

#### Owns scratch audio during media restore; cancel discards immediately
`DictationAudioHandoff`: Owns closed scratch audio while media restoration finishes. Cancellation
can discard it immediately, before the suspended transcription task resumes.

#### Taking transfers audio cleanup duty to transcription or retry
`DictationAudioHandoff.take`: Transfers cleanup responsibility to the transcription/retry lifecycle.

### `LokalBot/Dictation/DictationComposition.swift`

#### Value snapshot of focused app prevents context switching across suspension points
`DictationScreenTarget`: The application that owned focus when dictation began. Keeping this as a
value snapshot prevents the later ScreenCaptureKit suspension points from
silently switching the compose context to a different application.

#### No image or OCR output written to disk; lives until text delivered
`DictationScreenContext`: Ephemeral context for one compose request. No image or OCR output is ever
written to disk; this value lives only until the generated text is delivered.

#### Exact AX window identity; switching documents invalidates title and URL
`DictationScreenContextIdentity`: The exact Accessibility window whose metadata may be attached to a compose
request. A process ID is too broad: switching documents inside the same app
must invalidate the captured title and URL just like switching apps does.

#### Require unique focused-window match; never substitute another document
`DictationWindowSelector`: A unique focused-window match is required. Missing/ambiguous identity must
never substitute another document belonging to the same application.

#### Five second OCR wait on top of speaking time, started at record begin
`DictationScreenText.recognitionLimit`: How long Compose waits for the window's text. Dictation started the
read when recording began, so this is on top of the time spent speaking.

#### Auto language detection because en-US default cannot read CJK
`DictationScreenText.recognize`: Same as screen OCR: the en-US default cannot read CJK text.

#### Capture only the focused window; without Screen Recording send metadata only
`DictationScreenContextCapture`: Captures only the window that was focused when dictation began. Screen
Recording is optional: without it the caller still receives safe app/window
metadata and composition continues from the spoken request.

#### Never prompt for Screen Recording from a global shortcut
`DictationScreenContextCapture.capture`: Never prompt from a global shortcut. The Dictation permissions UI is
the explicit place where the user can grant Screen Recording access.

#### Metadata-only fallback only while it matches bound field and window
`DictationScreenContextCapture.capture`: Screen Recording denial and capture errors are allowed to fall
back to metadata only while it still belongs to the exact bound
field and window. Never return a stale same-app document title.

#### Without recognized text, caller falls back to window name alone
`DictationScreenContextCapture.captureVisibleText`: Without the text, the caller falls back to the window's name alone.

#### Re-read focused AX element after await; same-process document may change
`DictationScreenContextCapture.contextStillMatches`: Re-read the exact focused AX element after the awaited window capture.
A same-process document change can happen while that reader is busy.

#### Rejected: Compose answered a question instead of cleaning it (2026-10-08 benchmark)
`DictationCleanupPrompt.composeDecides`: The Compose prompt itself decides whether speech is an instruction. It
answered "Can you tell me when the 9 boxes arrive?" with "I don't know…"
(Benchmarks/transcribe/Dictation/results/2026-10-08-routing-window).

#### Transcript sent as JSON data kept sentences 16/16 versus 13/16
`DictationCleanupPrompt.transcriptAsData`: The transcript is sent as JSON data under a cleanup-only system prompt
that forbids answering or carrying it out (as FluidVoice and Handy do).
Kept direct sentences 16/16 against 13/16 on a set frozen before it ran
(Benchmarks/transcribe/Dictation/results/2026-10-08-cleanup).

#### Only names and terminology help spelling; cleanup must not rewrite style
`DictationCleanupPromptText.system(profile:)`: Names and terminology from the writing profile help spelling; style and
language preferences are left out because cleanup must not rewrite.

#### Small models echo the JSON envelope or add quotes
`DictationCleanupPromptText.normalizedOutput`: Small models sometimes echo the envelope or wrap the text in quotes.

#### Keep last 2,000 characters; first 12,000 dropped newest message
`DictationWindowTextPolicy`: How much of the focused window's OCR text a Compose prompt keeps, and from
which end. The replay benchmark varies it; production uses `.production`.
Keeping the first 12,000 characters dropped the newest message of a long
window (it sits at the bottom, next to the input field) and Compose answered
from a stale one; the last 2,000 answered every window case.

#### Single behavior: speech is lightly cleaned or executed as writing instruction
`DictationComposePrompt`: Pure prompt construction for the single dictation behavior: spoken input is
either lightly cleaned as direct text or executed as a writing instruction.

#### Strip echoed titles and markdown unless the speaker asked for them
`DictationComposePrompt.insertableText`: The model's text as it will be inserted. Small models sometimes open
with the window title they were given, or format plain text as
markdown, even when told not to. What the person said always wins: a
title or markdown they asked for stays.

### `LokalBot/Dictation/DictationContextReplay.swift`

#### Synthetic replay uses Compose path with no mic, library or live AX
`DictationContextReplay`: Synthetic post-ASR replay through the same preparation/selection/engine
path as Compose. No microphone, AppState, user library or live AX access.

#### Optional so older fixtures still decode
`DictationContextReplay.Input.useScreenContext`: The focused-window (OCR) option. Optional so older fixtures decode.

### `LokalBot/Dictation/DictationCoordinator.swift`

#### Keep results so clipboard loss or crash does not lose dictation
`DictationCoordinator.history`: Recent results, so one left on the clipboard can be copied again after
something else replaced it, even after a crash or restart.

#### HUD shows why dictation failed or a local model transcribed
`DictationCoordinator.problemNotice`: Why the last dictation ended without its text, or why a model on this
Mac transcribed it. The HUD shows it over whatever app is in front.

#### Waveform moves only with audio in last second, not while reconnecting
`DictationCoordinator.isReceivingAudio`: Whether the microphone delivered audio within the last second. The HUD
waveform moves only while this is true, so it cannot look healthy while
the microphone is reconnecting.

#### HUD shows starting until microphone first delivers audio
`DictationCoordinator.hasMicrophoneAudio`: The microphone has delivered audio in this recording. Until then the
HUD shows that the microphone is still starting.

#### Show preparation panel only after a short grace period
`DictationCoordinator.modelPreparationOutlastedGrace`: A status-only preparation reaches the HUD once it outlasts a short
grace period. A warm model's check ends at once and used to flash the
preparation panel at the start of every transcription.

#### Spoken words passed only when learning is on, after allowed paste
`DictationCoordinator.onDictatedForLearning`: Spoken words (not Compose's draft) and the app they went to, for
Personal Context → Learn from my dictation. Called only while that is on,
after a paste into an identified field that passes the exclusions.

#### Chain all ASR passes so cancelled decoder cannot overlap the next
`DictationCoordinator.asrHandoffTask`: Every preview and authoritative pass joins this chain. A cancelled
decoder that does not cooperate immediately therefore remains owned and
cannot overlap the shared model runtime with the next dictation.

#### Shortcut must not cancel an earlier dictation it did not start
`DictationCoordinator.shortcutStartedGeneration`: The session a push-to-talk shortcut actually started. The shortcut can
be held while an earlier dictation is still transcribing; `start` then
does nothing, and the shortcut must not cancel that earlier dictation.

#### Read shortcut from stored settings per key event, skipping vocabulary build
`DictationCoordinator.init`: Read on every key event, so go straight to the stored settings
rather than the dictation provider, which also builds vocabulary.

#### Use press-time settings while starting so HUD keeps its size
`DictationCoordinator.shouldShowLiveTranscriptPanel`: While the microphone starts, the settings captured at the press decide,
so the HUD opens at the size recording keeps instead of growing from a
pill into the transcript panel once audio flows.

#### Recording waits for real progress; warm model never flashes the panel
`DictationCoordinator.shouldShowModelPreparation`: Whether the HUD surfaces model preparation. Preparation begins
synchronously on every recording start, so `.recording` waits for
real download progress (or a failure) — a warm model never flashes
the panel — while `.transcribing` shows any status at all.

#### Describe in-flight recording's settings even if Settings are edited
`DictationCoordinator.presentedConfiguration`: Describe the same intent, context and models that the in-flight
recording will use, even if the user edits Settings in another view.

#### Shortcut never cancels finished speech; retries model instead
`DictationCoordinator.toggleAction`: The shortcut never cancels finished speech: in Toggle mode a second
press while the text is being prepared (to start the next dictation, or
because the HUD looked slow) used to delete the recording and the
transcript. Push-to-talk already ignored it. While the speech model
needs attention, the shortcut retries instead. Menu and on-screen
controls keep their explicit Cancel.

#### Modifier chord turned out to be another shortcut
`DictationCoordinator.cancelShortcutStart`: A modifier chord turned out to be another shortcut (⌃⌥ then T).

#### Cancel only this shortcut's recording before transcription handoff
`DictationCoordinator.shouldCancelShortcutStart`: Only the recording this shortcut started, and only before it has been
handed to transcription.

#### One focus read at shortcut press binds destination; later read binds wrong app
`DictationCoordinator.start`: One focus read, started at the shortcut. The microphone opens
alongside it; recording begins once it answers or its short deadline
passes, and a slow app's answer to the same read can still bind the
destination later. A fresh read during recording would bind
whichever app had focus by then.

#### Queue new start behind cancelled start's media cleanup
`DictationCoordinator.start`: A cancelled start keeps its task until its media pause and resume
finish. Queue behind it instead of ignoring the press: the shortcut
used to do nothing at all until that cleanup ended.

#### Newer start owns screen-context task once begun
`DictationCoordinator.start`: A newer start owns the screen-context task once it begins.

#### Finish earlier media restore before new snapshot to avoid late resume
`DictationCoordinator.start`: An earlier cancel may still be restoring the exact players it
paused. Finish that bounded transition before taking a new media
snapshot, otherwise its late resume could interrupt this capture.

#### Open microphone while focus read finishes; waiting delayed start and lost words
`DictationCoordinator.start`: The microphone opens while the focus read begun at the press
finishes. Waiting for that read first delayed every start by
up to its deadline, and words spoken meanwhile were lost.

#### Remember push-to-talk release arriving during start instead of cancelling
`DictationCoordinator.finishRecordingAndTranscribe`: Push-to-talk key-up can arrive while permission, focus, or media
setup is still finishing. Remember the release instead of
cancelling the start and silently dropping the invocation.

#### Server failure falls back to a model already on this Mac
`DictationCoordinator.transcribeAndDeliver`: The server failing (a rejected key, no connection) does not
lose the dictation: a model already on this Mac transcribes it.

#### Newer session may own coordinator after delivery waits
`DictationCoordinator.transcribeAndDeliver`: Delivery can wait for the target app; a newer session may own
the coordinator by the time it returns.

#### HUD always reports server failure; message skipped if delivery problem exists
`DictationCoordinator.transcribeAndDeliver`: The HUD always says the server failed. LokalBot's own
message says it too, unless it already holds a delivery
problem, which matters more there.

#### Compose failure must not lose transcribed speech; keep in history
`DictationCoordinator.transcribeAndDeliver`: Compose failing must not lose minutes of transcribed speech.

#### Stand-in model is on disk; load shown in HUD when slow
`DictationCoordinator.prepareStandInModel`: Loads the model on this Mac that stands in for the server. It is on
disk already, so this is a load, shown in the HUD when it is slow.

#### Cancelled session reports cancelled and never types the fallback
`DictationCoordinator.pasteDeliveryResult`: The paste waits up to 1.5 s for the app to read the text. If the
dictation was cancelled meanwhile (and another may already be
recording), report it as cancelled so nothing touches the new session,
and never type the fallback.

#### Skipped paste while current copies so session completes
`DictationCoordinator.pasteDeliveryResult`: Not pasted while this dictation is still current: copy it so
the session completes instead of waiting forever.

#### Recheck field when an earlier paste held the queue
`DictationCoordinator.deliver`: An earlier paste held the queue; check the field again.

#### Notice only for readable field lacking text; unreadable fields left alone
`DictationCoordinator.checkInsertion`: Reads the field back after a paste. Only a field that can be read and
still lacks the text raises the notice; an unreadable field (many
Electron and web editors) is left alone rather than guessed at.

#### No field identity means no read; focus may be another or secure field
`DictationCoordinator.checkInsertion`: Without a field identity the paste went to "the app"; reading
whatever field is focused now could be another (or a secure) one.

#### Keep spoken words only if window and URL pass exclusions
`DictationCoordinator.keepForLearning`: Reads the pasted-into window's title and page address once, and hands
the spoken words on only if they pass the same exclusions as nearby
text. Anything unreadable keeps nothing.

#### Read stored settings because dictation provider also builds vocabulary
`DictationCoordinator.keepForLearning`: The stored settings: the dictation provider also builds vocabulary.

#### LokalBot itself is left unnamed in history
`DictationCoordinator.dictatedAppName`: The app dictation started in, for the history. LokalBot itself (Try
here) is left unnamed.

#### Paste check off critical path gets longer deadline for slow apps
`DictationCoordinator.deliveryCheckDeadlineMilliseconds`: The paste check is not on the shortcut's critical path, so slow apps
(Electron, Chromium) get longer to answer than the start snapshot.

#### Wait for slow start snapshot rather than clipboard-copying every dictation
`DictationCoordinator.bindLateDeliveryTarget`: The start snapshot has a short deadline so the microphone opens without
delay. When it times out, wait for the same read rather than copying
every dictation into a slow app to the clipboard.

#### Accept late focus answer only for app frontmost at press
`DictationCoordinator.lateDeliveryBinding`: The late answer to the shortcut's focus read, accepted only for the app
that was frontmost when the shortcut was pressed.

#### Timeout result leaves the capture running for later readers
`DictationCoordinator.focusCapture`: `capture`'s result if it arrives within `deadline`, otherwise a
timeout; `capture` itself keeps running for a later reader.

#### Do not cancel media pause; retain task until restoration finishes
`DictationCoordinator.invalidateStartingSession`: Do not cancel an in-flight media pause: it is bounded, and allowing
it to return gives that task the exact resume token it needs. The
generation guard prevents the recorder from starting afterward. Keep
the task retained until that pause-and-resume cleanup finishes so a
new start cannot race ahead of its late media restoration.

#### Message goes to app window, notice to HUD for other-app dictation
`DictationCoordinator.completeWithMessage`: Ends a dictation that delivered nothing. `message` goes to LokalBot's
own window and `notice` to the HUD, which is what the person sees when
they dictated into another app.

#### Retry begins preparation while panel shows error so panel stays up
`DictationCoordinator.retryModelPreparation`: Both paths begin preparation, which clears the error while the
panel is still showing it, so the panel stays up for the retry.

#### Retry without hint when clear speech was dropped as vocabulary-only
`DictationCoordinator.shouldRetryWithoutVocabulary`: The engines drop rows made only of vocabulary-hint terms, because a
near-silent span decodes to the hint itself. A dictation can genuinely
be only those words ("Mila Novak, Orion Launch"), and it then ended as
"No speech detected". With clear speech, decode once more without the
hint, which cannot echo anything.

#### Window starting at zero is complete prefix and replaces earlier preview
`DictationCoordinator.livePreview`: While the overlap still reaches the recording's
beginning, this window is the complete prefix and
can replace the earlier preview outright.

#### Advance past tiny short window instead of retrying forever
`DictationCoordinator.livePreview`: A valid snapshot can still be a fraction shorter than
the recorder's health counter. Advance past that tiny
silent/short window rather than retrying it forever.

#### Materialize only unprocessed suffix plus overlap to bound preview I/O
`DictationCoordinator.makeIncrementalLivePreviewWindow`: Opens the append-safe CAF at its current length and materializes only the
unprocessed suffix plus a short overlap. This keeps preview I/O bounded
as dictation grows instead of copying the full recording on every pass.

#### Tick twice a second so waveform follows microphone
`DictationCoordinator.startTick`: Twice a second so the waveform follows the microphone closely.

#### Recover after settle delay; main-thread rebuild raced and blocked shortcut
`DictationCoordinator.refreshCaptureHealth`: Recover after the recorder's settle delay. Rebuilding here
ran on the main thread, raced the reconfiguration notice,
and blocked the keyboard shortcut while a device reopened.

#### HUD and start cue wait until audio actually arrives
`DictationCoordinator.microphoneDidDeliverFirstAudio`: The HUD switches from "starting" to recording, and the optional cue
plays, only once audio actually arrives: pressing the shortcut does not
mean the microphone is listening yet.

#### Bluetooth headset takes a moment to switch to headset mode
`DictationCoordinator.idleMicrophoneStatus`: Status for a running microphone that is not delivering audio. A
Bluetooth headset takes a moment to switch into headset mode.

#### Retry panel and notices show even when floating status is off
`DictationCoordinator.refreshOverlay`: The preparation-error panel holds the only Retry button, so it shows
even when the floating status is turned off. So do the notices:
without them a dictation that failed looks like nothing happened.

### `LokalBot/Dictation/DictationGrounding.swift`

#### relays routed 'Tell him I am running late' as request; referencedRelays never did
`DictationRequestRouting`: Which spoken openings count as a writing request that may use context.
Production uses `.production`; the replay benchmark compares the others
(Benchmarks/transcribe/Dictation/results/2026-10-08-routing-window). `relays`
answered more requests but routed "Tell him I am running 10 minutes late"
as one and copied a screen fact into it; `referencedRelays` never did.

#### Skips filler and accepts relay verbs aimed at others, not 'tell me'
`DictationRequestRouting.relays`: Also skips leading filler ("hey", "okay so", "dobro") and accepts relay
verbs aimed at someone else: "tell him…", "let her know…", "email
Marko…", "reci mu…", never "tell me…" or "javi mi…".

#### Relay verb counts only when request points at context
`DictationRequestRouting.referencedRelays`: Like `relays`, but a relay verb counts only when the request also
points at context ("…from the message above", "…iz poruke").

#### Dictation has own grants; reuse lookup without enabling Autocomplete or history
`DictationGrounding`: Dictation has its own grants. Reuse the current-source lookup without
enabling Autocomplete or inheriting its permissions or writing history.

#### Direct sentences must not gain claims from nearby messages
`DictationGrounding.requestsContext`: Context can complete an explicit writing instruction. A direct sentence
must not acquire claims from nearby messages, even in Compose mode.
Unknown/ambiguous phrasing conservatively gets ordinary cleanup.

#### Capitalized second word is a name; lowercase 'email works' is a sentence
`DictationGrounding.requestsContextWithRelays`: A capitalized second word is a name ("Email Marko…"); lower-case
"email works" is a sentence about email.

#### Query is a spoken writing request, not shell or code input
`DictationGrounding.field`: This query is a spoken writing request, not typed shell/code input.

### `LokalBot/Dictation/DictationHistory.swift`

#### Keep long dictations that went to clipboard, across crash or power cut
`DictationHistory`: The latest dictations, newest first. A long dictation that finishes after
focus moved goes to the clipboard, where the next copy replaces it; this
keeps it, across a crash or power cut too (see `DictationHistoryStore`).

#### Repeated words (retry) move to top instead of duplicating
`DictationHistory.record`: The same words again (a retry) move to the top instead of repeating.

#### Cancelled delivered nothing; text for password fields never kept
`DictationHistory.outcome`: What a finished delivery keeps. A cancelled dictation delivered
nothing, and text meant for a password field is never kept.

#### Encrypted with chat-key, 0600, full-fsync writes off main thread
`DictationHistoryStore`: Recent dictations on disk, so a crash or power cut doesn't lose them.
Sealed with the `chat-key` like the dictation learning log, 0600, and
rewritten after every dictation; Clear deletes the file. Writes reach the
drive (F_FULLFSYNC) off the main thread, in order.

#### Missing file skips Keychain; unreadable file reads empty, next save replaces
`DictationHistoryStore.savedEntries`: No file reads as empty without touching the Keychain; an unreadable
one reads as empty, and the next save replaces it.

#### Temp file, flush, rename so power cut leaves whole version
`DictationHistoryStore.writeDurably`: Writes a 0600 temporary file, flushes it to the drive, then renames it
over the old one, so a power cut leaves either version whole.

#### Use F_FULLFSYNC because plain fsync only reaches drive cache
`DictationHistoryStore.writeDurably`: Plain fsync only reaches the drive's cache.

### `LokalBot/Dictation/DictationInputMonitor.swift`

#### Key shortcuts consumed; modifier-only shortcuts observed without consuming
`DictationInputMonitor`: Global shortcut watcher for Handy-style dictation. It consumes a key
shortcut so the trigger never leaks a stray Space into the focused app. A
modifier-only shortcut (⌃⌥) is observed without consuming anything, so
other shortcuts that start with the same modifiers keep working.

#### Esc consumed only while dictating; Tap or hold uses it to finish
`DictationInputMonitor.isDictationActive`: Whether a dictation is starting or recording. Esc is consumed only
then, and Tap or hold uses it to tell a finishing tap from a start.

#### Press shorter than 0.3 s keeps recording after release
`DictationInputMonitor.tapHoldThreshold`: Tap or hold: a press shorter than this keeps recording after release.

#### Hold 0.2 s before chord starts so quick other keys never open mic
`DictationInputMonitor.chordHoldDelay`: How long a modifier-only push-to-talk chord is held before dictation
starts, so ⌃⌥ followed quickly by another key never opens the microphone.

#### Pass every key through while Settings records a shortcut
`DictationInputMonitor.isSuspended`: While Settings records a new shortcut, every key passes through so the
current shortcut can be pressed (and recorded) without starting dictation.

#### Nil when press finished a dictation so release does nothing
`DictationInputMonitor.tapHoldPressedAt`: Tap or hold: when the current press began, or nil when that press
finished a running dictation and its release must do nothing.

#### Esc during held shortcut swallows its release
`DictationInputMonitor.heldShortcutCancelledByEscape`: Esc cancelled while the key shortcut was held; its release is swallowed.

#### Chord pressed while dictating finishes on clean release
`DictationInputMonitor.chordFinishesOnRelease`: Tap or hold: the chord was pressed while dictating, so a clean
release finishes instead of starting.

#### Disabled event tap may swallow key-up; treat as release to avoid endless recording
`DictationInputMonitor.handle`: A disabled event tap can swallow the physical key-up. Treat the
disable notification as a fail-safe release before re-enabling,
otherwise push-to-talk may record indefinitely.

#### Esc counts with held shortcut modifiers, e.g. option set
`DictationInputMonitor.isEscape`: Esc alone, or with only the modifiers of the shortcut being held: Esc
pressed while holding ⌥ Space arrives with ⌥ set.

#### Esc cancelled dictation so shortcut release must not finish it
`DictationInputMonitor.releaseHeldShortcutAfterEscape`: Esc cancelled the dictation; the shortcut's release must not finish it.

#### Toggle fires on clean release so chords in other shortcuts never toggle
`DictationInputMonitor.handleModifiers`: Push to talk starts after `chordHoldDelay` and stops on release. Toggle
fires on a clean release, so ⌃⌥ used as part of another shortcut never
toggles dictation.

#### Extra modifier means a different shortcut unless dictation already running
`DictationInputMonitor.handleModifiers`: Another modifier joined (⌃⌥⌘): a different shortcut, unless
dictation is already running from this hold.

#### Hold finishes on release; tap keeps recording
`DictationInputMonitor.releaseChord`: A hold finishes on release; a tap keeps recording.

#### Release before hold delay is a tap, so start now
`DictationInputMonitor.releaseChord`: Released before the hold delay: a tap, so start now.

### `LokalBot/Dictation/DictationInsertionCheck.swift`

#### Compare last few words since apps reformat pasted text
`DictationInsertionVerdict`: Whether pasted dictation reached the field, judged from the text before
the caret. Apps reformat pasted text (smart quotes, emoji, Markdown), so
the check compares the last few words rather than exact characters.

#### Read field at 250, 650, 1200 ms; apps publish change late
`DictationInsertionCheck.readDelaysMilliseconds`: When to read the field after the paste, in milliseconds. An app can
take a moment to publish the change.

#### Probe is last 24 letters and digits of insertion
`DictationInsertionCheck.probeLength`: Letters and digits from the end of the insertion that must appear.

#### Read only exact bound non-secure field; app-only target never read
`DictationInsertionCheck.allowsReadBack`: The field is read back only when it is the exact field the text was
pasted into and not a secure one. An app-only target (no field
identity) is never read: focus may have moved to another field.

#### Compare letters and digits only; unsegmented scripts match inside runs
`DictationInsertionCheck.verdict`: Compares letters and digits only, so spacing, punctuation, emoji and
Markdown changes do not matter, and scripts without spaces between
words (Chinese, Japanese, Thai) match inside a longer run.

### `LokalBot/Dictation/DictationMicrophone.swift`

#### Empty follows default input; MacBook mic keeps Bluetooth headset high quality
`DictationMicrophone`: The microphone dictation records from. Empty means the macOS default
input, which follows AirPods when they connect; choosing the MacBook
microphone keeps a Bluetooth headset in its high-quality audio mode.

#### Keep a disconnected chosen microphone visible in picker
`DictationMicrophone.options`: Picker rows: the default, every connected microphone, and a chosen one
that is currently disconnected (so the choice stays visible).

#### Secure Input hides key presses from event taps, so shortcut undetectable
`DictationSecureInput`: While another app has Secure Input on (Terminal's Secure Keyboard Entry,
a password field, some password managers), macOS hides key presses from
event taps, so the dictation shortcut cannot be detected.

### `LokalBot/Dictation/DictationModels.swift`

#### Quick tap starts and second tap finishes; hold acts like push to talk
`DictationTriggerMode.tapOrHold`: A quick tap starts and a second tap finishes; holding past the tap
threshold works like push to talk.

#### Insert only if same destination still has focus, else copy
`DictationDeliveryTarget`: The app/field that owned focus when dictation began. Final transcription
may take long enough for focus to move; insertion is allowed only when the
same destination still owns focus, otherwise the text is copied safely.

#### Paste replaces exactly the prior selection; any other selection blocks
`DictationDeliveryTarget.selection`: Text the person selected before dictating. Pasting replaces exactly that
selection, the way typing would; any other selection blocks the paste.

#### Blocked snapshot beats app-only fallback; never allow same-app password paste
`DictationDeliveryTarget.check`: A blocked snapshot always wins over the app-only fallback. In
particular, a target captured before AX exposed a field must never
become permission to paste into a same-app password field later.

#### Unreadable when Accessibility missing or app times out
`DictationDeliveryCheck.fieldUnreadable`: The field could not be read: Accessibility access is missing, or the
app did not answer in time.

#### Non-empty selection as UTF-16 offsets from Accessibility
`DictationTextSelection`: A non-empty text selection, as UTF-16 offsets reported by Accessibility.

#### Minimal AX state; carries no field text or geometry
`DictationFocusSnapshot`: The minimum Accessibility state needed to bind and later validate a
dictation destination. It intentionally carries no field text or geometry.

#### Never read context from secure field or with selection
`DictationFocusSnapshot.blocksContextCapture`: Screen and nearby-text context are never read from a secure field or
while text is selected.

#### Serialized background reads with one deadline; wedged app fails closed
`DictationFocusSnapshotExecutor`: Serializes lightweight dictation focus reads on a background queue and
gives every caller one wall-clock deadline. A wedged target app therefore
fails closed without blocking the main actor or accumulating AX workers.

#### Longer deadline for callers off the shortcut's critical path
`DictationFocusSnapshotExecutor.capture`: `deadlineMilliseconds` lengthens the wait for callers that are not on
the shortcut's critical path, such as the check before pasting.

#### Overlap 2.5 s so ASR finishes boundary words without re-decoding all
`DictationPreviewWindowPlanner`: Pure planning for the rolling dictation preview. Each pass starts slightly
before the last completed pass so the ASR model hears enough context to
finish a word that crossed the boundary, without decoding the whole growing
recording again.

#### Newest window wins overlap; append without two-word overlap rather than lose speech
`DictationPreviewTextStitcher`: Deterministically joins overlapping ASR windows. The newest window replaces
the matched suffix so revised capitalization or punctuation at the boundary
wins, while a window with no trustworthy two-word overlap is appended rather
than risking the loss of already-visible speech.

#### Grapheme fallback only for unsegmented scripts; avoids false English matches
`DictationPreviewTextStitcher.stitch`: Keep the character fallback for unsegmented scripts. Applying it to
ordinary text can mistake an English word suffix for the beginning
of an unrelated word (for example, broadcast/cast iron), even when
only one side contains whitespace.

#### Unspaced languages tokenize as one word; use conservative grapheme match
`DictationPreviewTextStitcher.stitchByGrapheme`: Languages such as Chinese and Japanese generally do not put spaces
between words, so whitespace tokenization turns an entire ASR window
into one token. Fall back to a conservative grapheme match, retaining
the incoming window's latest punctuation and capitalization just as the
word-based path does.

#### Ignore punctuation when matching; keep original indices for verbatim output
`DictationPreviewTextStitcher.semanticGraphemes`: Ignore punctuation and spacing while matching, but retain each
grapheme's original index so the stitched output preserves the newest
window verbatim from the overlap onward.

#### List only scripts without word spaces; Arabic and Cyrillic excluded
`DictationPreviewTextStitcher.isUnsegmentedScript`: Scripts whose orthography commonly omits spaces between words. Keep
this deliberately narrower than "non-Latin" because Arabic, Cyrillic,
Devanagari, and many other scripts still use word separators.

#### Key shortcut consumed system-wide so avoid typed keys; modifier-only observed
`DictationShortcut`: The global dictation shortcut: a key plus modifiers, or modifiers alone
(⌃⌥, the way Wispr Flow and similar apps are often set up). The event tap
consumes a key shortcut system-wide, so it must not be something people
type; a modifier-only shortcut is observed without consuming anything.
The Quick Recall shortcut uses the same type, but always with a key.

#### Control-Shift-Space opens Ask
`DictationShortcut.quickRecallDefault`: ⌃⇧ Space opens Ask.

#### Control-Shift-W (write) opens selection actions
`DictationShortcut.selectionActionsDefault`: ⌃⇧ W ("write") opens selection actions.

#### Control-Shift-H hands off window; Control-Option conflicts with VoiceOver
`DictationShortcut.windowHandoffDefault`: ⌃⇧ H ("hand off") hands off the focused window. Not ⌃⌥, which
VoiceOver uses for its own commands.

#### Single modifier alone fires whenever used for anything else
`DictationShortcut.problem`: One modifier alone fires whenever it is used for anything else.

#### Quick Recall and selection actions use Carbon hot keys needing a key
`DictationShortcut.quickRecallProblem`: Why this combination cannot be the Quick Recall or selection actions
shortcut, or nil. Both register a Carbon hot key, which needs a key and
never observes modifiers alone.

### `LokalBot/Dictation/DictationOverlayContent.swift`

#### One value sizes panel and content; closing HUD fades showing last content
`DictationOverlayContent`: Everything the dictation HUD draws, copied from the coordinator. The panel
and its SwiftUI content both size themselves from this one value, so they
cannot disagree, and a closing HUD fades out showing what it last showed
instead of an empty idle capsule.

#### Starting and recording look alike so HUD shape stays stable
`DictationOverlayContent.Activity.listening`: Starting or recording. The two look the same: a grey dot and flat
bars until the microphone delivers audio, so the HUD does not
change shape when recording begins.

#### Even widths and margins keep panel on whole points when centered
`DictationOverlayContent.Layout`: The HUD's shapes. Widths and margins are even, so the panel and the
capsule stay on whole points when centered on the screen.

#### One radius for all shapes, matching the composer
`DictationOverlayContent.Layout.cornerRadius`: One radius for every shape, so a pill growing into the transcript
panel reads as the same surface changing size. The same radius as
the app's other floating surface, the composer.

#### Starting counts as listening so first frame has recording's shape
`DictationOverlayContent.make`: What the HUD shows for a coordinator state, or nil when it shows
nothing. Starting counts as listening, so the first frame already has
the shape recording will keep.

#### Notice for possibly lost text outranks server failure, which recurs
`DictationOverlayContent.make`: Text that may be lost comes first; the server's failure will
show again at the next dictation.

#### Fixed-size canvas never moves; panel is a window onto its bottom-center
`DictationOverlayGeometry`: Where the HUD panel sits. The SwiftUI canvas has one fixed size and never
moves on screen; the panel is only a window onto its bottom-center, so
resizing the panel cannot shift what is drawn.

#### Canvas stays at same screen place whatever the panel size
`DictationOverlayGeometry.canvasOrigin`: The canvas's origin inside a panel of `panelSize`, which keeps the
canvas at the same place on screen whatever the panel's size.

### `LokalBot/Dictation/DictationOverlayView.swift`

#### Fixed-size canvas with panel as a window onto its bottom-center; resize never clips
`DictationOverlayController`: Shows the dictation HUD in a floating panel near the bottom of the screen.

The SwiftUI canvas has one fixed size and stays put on screen; the panel
is a window onto the canvas's bottom-center. A capsule that grows makes
the panel grow first, and a capsule that shrinks shrinks inside the panel
before the panel follows, so resizing never shifts or clips what is drawn.

#### Anchor stays fixed while HUD is up so focus changes cannot move screens
`DictationOverlayController.anchor`: The capsule's bottom-center while the HUD is up. Fixed until it hides,
so a focus change cannot move it to another screen mid-dictation.

#### Shrink delay lets the capsule resize settle before the panel shrinks
`DictationOverlayController.shrinkDelay`: Long enough for the capsule's resize to settle before the panel shrinks.

#### Order-out delay matches the exit transition length
`DictationOverlayController.orderOutDelay`: Long enough for the exit transition before the panel leaves the screen.

#### Follow every published change once per turn, since some reshape HUD without update
`DictationOverlayController.observe`: Some changes reshape the HUD without a call to `update`, such as a
model check that ends. Follow every published change, once per turn.

#### Insert capsule on next turn after empty canvas draws so entrance runs
`DictationOverlayController.show`: Insert the capsule on the next turn, once the empty canvas has
drawn, so its entrance transition runs.

#### Short rise entrance because the HUD is summoned many times a day
`DictationOverlayRoot`: The fixed-size canvas: the capsule sits at its bottom-center and enters
with a short rise, the HUD being summoned many times a day.

#### Animate on the canvas so position springs with size and bottom edge stays
`DictationOverlayRoot.body`: On the canvas rather than the capsule, so the capsule's position
springs together with its size and its bottom edge stays put.

#### Each content kind laid out at final size, cross-fades; surface springs and clips
`DictationOverlayView`: The capsule. Each kind of content is laid out at its own final size and
cross-fades, while the surface springs between sizes and clips whatever
does not fit yet.

#### Bars move only with real audio; mic problems show words, not a fake wave
`DictationOverlayView.pill`: The bars move only while audio arrives, and a microphone problem
replaces them with words: the HUD once animated a fixed wave while the
microphone reconnected, so recording looked fine when it was not.

#### Offer pasted text the field did not show again instead of losing it
`DictationOverlayView.noticeRow`: Pasted text the field did not show: offer it again instead of losing it.

#### Problem notice reason is shown as written because it can quote a server
`DictationOverlayView.problemRow`: Why a dictation ended without its text, or why a model on this Mac
transcribed it. The reason is shown as written: it can quote a server.

#### Same square slot in every shape so indicator and close button stay put
`DictationOverlayView.slot`: Square cell for the leading indicator and the close button, the same
in every shape so they stay put when the capsule changes.

#### Transcript panel keeps one face across activities so text does not blink
`DictationOverlayContent.Face`: What cross-fades. The transcript panel keeps one face across its
activities, so its text does not blink when recording ends.

#### HUD surface: glass, material or opaque under Reduce Transparency, with soft shadow
`View.dictationHUDSurface`: The app's floating surface (glass on macOS 26, material before it, an
opaque fill under Reduce Transparency), clipped to the capsule, with a
soft shadow so it lifts off the app underneath.

#### Shadow drawn only outside capsule so glass/material sampling is not darkened
`HUDShadow`: A shadow drawn only outside the capsule: glass and material sample what
lies behind them, and a shadow shape underneath would darken the surface.

#### Grey and still until mic delivers audio; Bluetooth headsets can take a second
`DictationRecordingDot`: Grey and still until the microphone delivers audio (a Bluetooth headset
can take a second to switch), then the pulsing recording dot.

#### Bars show measured loudness, flat when silent, drawn in Canvas to avoid layout at 30 fps
`AudioLevelBars`: Bars drawn from the microphone's measured loudness: the newest reading in
the middle, older ones rippling outward. Flat and dim while nothing
arrives, so a silent or reconnecting microphone is visible instead of
hidden behind a decorative animation. Drawn in a Canvas, so the 30 fps
redraw causes no layout.

#### Recent levels oldest first, newest in the middle
`AudioLevelBars.mirrored`: Recent levels, oldest first, laid out newest-in-the-middle.

#### Outer bars stand shorter so shape reads as a voice
`AudioLevelBars.envelope`: Outer bars stand a little shorter, so the shape reads as a voice.

#### Quick rise, slow fall like a level meter smooths a dozen readings a second
`AudioLevelFollower`: Eases the bars toward the measured levels, quick to rise and slower to
fall like a level meter, so a dozen readings a second move smoothly.

### `LokalBot/Dictation/DictationShortcutKeyNames.swift`

#### Named keys from a fixed table; character keys read from current keyboard layout
`DictationShortcutKeyNames`: Names for the virtual key codes a dictation shortcut can use. Named keys
(Space, arrows, function keys) come from a fixed table; character keys are
read from the current keyboard layout, so a German or French layout shows
the letter printed on its own key.

#### Named keys are the ones that do not type a character
`DictationShortcutKeyNames.isNamedKey`: Keys that do not type a character.

#### Fall back to ASCII layout for input methods without key layout; main thread only
`DictationShortcutKeyNames.layoutCharacter`: The unmodified character the current layout prints on `keyCode`.
Input methods without a key layout (Japanese, Chinese) fall back to
the ASCII-capable layout. Text Input Sources are main-thread only.

### `LokalBot/Dictation/DictationTextPreparation.swift`

#### Intent boundary shared with hermetic tests; Transcribe never builds a model or reads screen
`DictationTextPreparation`: The intent boundary is shared by production and hermetic runtime tests.
Transcribe cannot construct a language model or request screen context.

#### Records what Compose read; nil for Transcribe
`DictationTextPreparation.Result.contextUse`: What Compose read for this request; nil for Transcribe.

#### No thinking, low temperature, output ceiling above long dictated messages
`DictationTextPreparation.composeOptions`: No thinking turn, a low temperature for faithful cleanup, and an output
ceiling well above a long dictated message.

#### Direct speech goes to cleanup prompt as data, not as an instruction
`DictationTextPreparation.prepare`: Direct speech is text to insert, so it goes to a cleanup prompt as
data rather than to a prompt that may treat it as an instruction.

#### Pass options because the built-in server would allow an 8K-token thinking turn
`DictationTextPreparation.prepare`: Someone is waiting to insert this text. Without options the built-in
server would allow an 8K-token thinking turn before any visible text.

#### Shown under Last result so context settings can be judged by contribution
`DictationContextUse`: Which context a Compose request actually used, shown under Last result so
the context settings can be judged by what they contributed.

#### Context is read only for writing requests such as reply or draft
`DictationContextUse.wasWritingRequest`: Context is read only for writing requests ("reply…", "draft…").

#### Summary is the Last result line, in the interface language
`DictationContextUse.summary`: The line under Last result, in the interface language.

### `LokalBot/Dictation/DictationTranscriptionFallback.swift`

#### On server failure a local model transcribes and the HUD says why; 2026-11-10 401 incident
`DictationTranscriptionFallback`: What dictation does when the transcription server cannot transcribe: a
speech model already on this Mac transcribes the same audio, and the HUD
says why (`DictationProblemNotice`).

On 2026-11-10 OpenRouter stopped accepting a saved key. Every dictation
recorded, got HTTP 401, and ended with a message only LokalBot's own window
shows, so in any other app the shortcut seemed to do nothing.

#### Nil when the selected model transcribed
`DictationTranscriptionFallback.Spoken.fallback`: Nil when the selected model transcribed.

#### Only broad multilingual models stand in; narrow ones could write wrong text
`DictationTranscriptionFallback.multilingual`: Multilingual models, best first. The narrow ones (SenseVoice, GigaAM,
Fun-ASR-Nano, Cohere) are left out: a stand-in must not turn speech in
another language into wrong text in someone's document.

#### English-only model used only when language is set to English
`DictationTranscriptionFallback.englishOnly`: Used only when the language is set to English.

#### Hint appended when server failed and no local model could take over
`DictationTranscriptionFallback.nothingDownloadedHint`: Added to the message when the server failed and nothing could take over.

#### Fallback never starts a multi-gigabyte download; nil if nothing suitable on disk
`DictationTranscriptionFallback.localChoice`: The downloaded model that transcribes when the server fails. Nil when
the selected model is not the server, or nothing suitable is on disk:
a failed dictation never starts a multi-gigabyte download.

#### If fallback also fails, report the server's error since that is what to fix
`DictationTranscriptionFallback.transcribe`: Transcribes with the selected model (`selected`). When the server
fails, `onThisMac` transcribes with settings that name the stand-in.
If that fails too, the server's error is the one reported: it is the
one the person has to fix.

#### Show in HUD because messages in LokalBot's own window were rarely seen
`DictationProblemNotice`: Shown in the dictation HUD when a dictation ended without its text, or when
a model on this Mac transcribed it because the server could not. These
messages used to reach only LokalBot's own window, which is rarely in front
while dictating into another app.

#### Title is a localization catalog key
`DictationProblemNotice.title`: A catalog key.

#### Reason shown as written since it can quote a server
`DictationProblemNotice.detail`: The reason, shown as written: it can quote a server's own words.

### `LokalBot/Dictation/DictationVisibleContextCapture.swift`

#### One background reader with wall-clock deadline; wedged AX app cannot hold workers or leak late context
`DictationVisibleContextCapture`: One background reader, no queued captures, and a wall-clock deadline.
A wedged AX application cannot occupy additional workers or return late
context to the next recording. No field value, pixels or OCR are read.

#### Keep the worker occupied until it actually returns
`DictationVisibleContextCapture`: Keep the worker occupied until it actually returns.

### `LokalBot/Views/Dictation/DictationView.swift`

#### A recording keeps the settings it started with
`DictationSettingsSections.busy`: A recording keeps the settings it started with.

#### Header reports missing permission; only relaunch after granting stays here
`DictationSettingsSections.mainSections`: The page header says which permission is missing and asks for it;
only the relaunch a granted shortcut may need stays here.

#### Anchor identifier on label; on a container it would replace inner identifiers
`DictationSettingsSections.shortcutSection`: The page's anchor for tests and captures. On a container it
would replace the identifier of every row inside.

#### When writer is a service, row says dictated words go there
`DictationSettingsSections.writerRow`: Where the dictated words become the text that is pasted. When that is
a service, the row says that what is dictated goes there.

#### Disclose in full what else travels with dictated words
`DictationSettingsSections.writerRow`: What else travels with the dictated words, said in full.

#### Compose shares writing profile with Autocomplete, so edit its fields here
`DictationSettingsSections.profileSection`: Compose takes tone, name and terminology from the writing profile it
shares with Autocomplete, so its fields are edited here too.

#### Try it: result shown here, nothing pasted, clipboard untouched
`DictationTrySheet`: "Try it…" on Dictation: speak, and the result shows here. Nothing is
pasted into another app and the clipboard is left alone.

#### Only microphone and model lines block try-out; header shows them only while shortcut on
`DictationTrySheet.blockers`: The header's lines that stop a try-out: the microphone and the model.
The header shows them only while the shortcut is on.

#### Nil when Secure Input off; otherwise holding app if known
`DictationView.secureInputHolder`: Nil when Secure Input is off; otherwise the app holding it, if known.

#### Verbatim text: saved-fact titles are user text, not markdown
`DictationView.lastResult`: Verbatim: saved-fact titles are user text, not markdown.

### `LokalBot/Views/Dictation/RecentDictationsViews.swift`

#### Menu bar recovers dictation finished after focus moved and clipboard lost it
`LastDictationMenuRow`: The menu bar's way back to a dictation the clipboard lost: a dictation that
finished after focus moved is left on the clipboard, where the next copy
replaces it. One row copies the newest and shows its start; earlier ones
are in the row's context menu and on the Dictation page.

#### Entries are newest first
`LastDictationMenuRow.entries`: Newest first.

### `LokalBotTests/Dictation/DictationFeedbackTests.swift`

#### Chinese has no word spaces; correct continuation looked like a failed paste
`testInsertionCheckMatchesScriptsWithoutWordSpaces`: Review finding on 719b3dc: Chinese has no spaces between words, so a
correct continuation looked like a failed paste.

#### App-only target let read-back inspect any focused field, including secure
`testReadBackRequiresTheBoundFieldAndNeverASecureOne`: Review finding on 719b3dc: an app-only target (no field identity) let
the read-back inspect whatever field had focus, including a secure one.

#### Levels expire after half a second so a stalled mic does not freeze bars
`testStaleLevelsReadAsSilence`: Review finding on 719b3dc: levels never expired, so a stalled
microphone froze the bars at its last loudness.

#### Esc while holding Option-Space carries Option; must cancel, not transcribe on release
`testEscWhileHoldingThePushToTalkShortcutCancelsWithoutFinishing`: Review finding on 719b3dc: Esc pressed while holding ⌥ Space carries
⌥, was not recognized, and releasing the shortcut then transcribed.

### `LokalBotTests/Dictation/DictationGroundingTests.swift`

#### Relay rule needs a context pointer; otherwise self-contained relays never routed
`testProductionRoutingRequiresAPointerForRelays`: Benchmarks/transcribe/Dictation/results/2026-10-08-routing-window: the relay rule
that needs a pointer to context answered new requests without ever
routing a self-contained relay ("Tell him I am running late").

#### Direct speech goes to cleanup as data so questions are inserted, not answered
`testDirectSpeechIsCleanedAsDataNotAsAnInstruction`: Benchmarks/transcribe/Dictation/results/2026-10-08-cleanup: direct speech is sent as
data to a cleanup prompt, so "What is the status of the Birch invoice?"
is inserted instead of answered.

#### Turning Overnight review off stops new reviews, not the grant to read saved ones
`testMixedWorkMemoryRequiresBothDictationGrants`: Turning Overnight review off stops new reviews; it does not withdraw
a grant to read what is already saved.

#### Two ordinary words name no topic for typing or dictation
`testGenericSpokenInstructionDoesNotRetrieveAnotherProjectsFacts`: Two ordinary words name no topic, for typing or for dictation.

#### Typed text may match a saved sentence by shared name; dictation must name the source
`testGenericSpokenInstructionDoesNotRetrieveAnotherProjectsFacts`: A shared name lets typed text match a saved sentence; dictation
still needs the source itself to be named.

### `LokalBotTests/Dictation/DictationHistoryTests.swift`

#### Recent dictations keep long clipboard-fallback results across copies and restarts
`DictationHistoryTests`: A long dictation that finished after focus moved went to the clipboard, and
the next copy replaced it. Recent dictations keep it, across a restart too.

### `LokalBotTests/Dictation/DictationIntentTests.swift`

#### A stale stored screen-context opt-in cannot widen Transcribe intent
`DictationIntentTests`: Even a stale stored opt-in cannot widen Transcribe.

### `LokalBotTests/Dictation/DictationModelPreparationVisibilityTests.swift`

#### Recording stays quiet until real download progress or failure; warm model never flashes HUD
`DictationModelPreparationVisibilityTests`: The dictation HUD's model-preparation visibility policy. Preparation
begins synchronously on every recording start, so `.recording` must stay
quiet until real download progress (or a failure) exists — a warm model
never flashes the panel — while `.transcribing` keeps the historical
behavior of showing any status at all.

### `LokalBotTests/Dictation/DictationOverlayLayoutTests.swift`

#### HUD jumped because panel and content were sized by separate rules
`DictationOverlayLayoutTests`: The dictation HUD's shapes and placement. The HUD used to jump at startup
and between states: the panel and its SwiftUI content were sized by two
separate rules, starting showed a different capsule from recording, and a
resized panel re-centered whatever was drawn inside it.

#### Server-refused dictation ended silently with a message only the app window showed
`testAProblemShowsOnceDictationIsIdle`: 2026-11-10: a dictation the server refused ended with nothing typed
and a message only LokalBot's own window shows.

#### Next dictation's states and text that may be lost take priority over problems
`testAProblemShowsOnceDictationIsIdle`: The next dictation's own states come first, and so does text that
may be lost.

#### Canvas never moves; every capsule's bottom-center sits on the anchor
`testCanvasStaysPutOnScreenAcrossPanelSizes`: The canvas never moves on screen, whatever size the panel takes, and
every capsule sits with its bottom-center on the anchor.

### `LokalBotTests/Dictation/DictationReliabilityTests.swift`

#### Covers AirPods dictation failures and delivery problems found investigating them
`DictationReliabilityTests`: Dictation failures reported from a Bluetooth headset (AirPods) and the
delivery problems found while investigating them.

#### Successful rebuild must not reset the flap budget; AirPods loop recorded fragments forever
`testRecorderDegradesWhenTheInputKeepsDroppingAfterSuccessfulRecoveries`: The AirPods loop: every rebuild succeeded, reset the retry budget, and
the device dropped again, so dictation recorded fragments forever and
never told anyone. A successful rebuild must not reset the flap budget.

#### Late focus answer must come from the shortcut's own read, not a fresh one
`testSlowFocusReadStillBindsTheFieldFocusedAtTheShortcut`: Review finding: the retry took a fresh focus read during recording, so
switching apps right after the shortcut made the second app the paste
destination. The late answer must come from the shortcut's own read.

#### Cancelled dictation after paste wait must not complete or type fallback
`testCancelledDictationNeverFinishesDeliveryAfterThePasteWait`: Review finding: after waiting for the paste, a cancelled dictation
still completed (resetting a newer recording) and could type its
fallback text.

#### Queued paste must be dropped if its dictation was cancelled
`testQueuedPasteIsDroppedWhenItsCallerIsCancelled`: Review finding on b323141: a paste queued behind another ran even after
its dictation was cancelled, into whatever app had focus by then.

#### Modifier chord cancels only the recording it started, not an earlier transcription
`testChordCancelsOnlyTheRecordingItStarted`: Review finding on b323141: holding ⌃⌥ while an earlier dictation was
transcribing, then pressing another key, cancelled that transcription.

### `LokalBotTests/Dictation/DictationShortcutTests.swift`

#### Poll for the start; fixed sleep just over the hold delay loses on busy runners
`DictationShortcutTests.waitForStart`: The start fires on the main queue after the hold delay; a fixed sleep
only just longer than the delay loses to a busy runner.

### `LokalBotTests/Dictation/DictationTranscriptionFallbackTests.swift`

#### Rejected remote key (HTTP 401) left dictation silent; fall back to a local model
`DictationTranscriptionFallbackTests`: 2026-11-10: OpenRouter stopped accepting the saved key. Every dictation
recorded, was refused with HTTP 401, and ended with nothing typed and a
message only LokalBot's own window shows.

#### HUD reports the server's reason so the key gets fixed
`testAModelOnThisMacTranscribesWhenTheServerRefuses`: The HUD says what the server said, so the key gets fixed.

#### If the stand-in fails too, report the server error; the key needs fixing
`testTheServerErrorIsReportedWhenNothingCanTakeOver`: The stand-in failed too: the key is still what needs fixing.

#### Only server failures trigger fallback; no-speech and cancellation keep meaning
`testOnlyAServerFailureIsReplaced`: "No speech", a cancelled dictation and the like keep their meaning.

#### English-only models stand in for English only; narrow ones never
`testTheStandInIsADownloadedModelThatFitsTheLanguage`: English-only models stand in for English alone, and narrow ones never.

#### Qwen cannot be told to write Ukrainian; Whisper can
`testTheStandInIsADownloadedModelThatFitsTheLanguage`: Qwen cannot be told to write Ukrainian; Whisper can.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
