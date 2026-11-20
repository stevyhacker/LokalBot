# 0101. Windows and Linux: engine — dictation

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/dictation.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/dictation.rs`

#### Insert only if press-time app and field still focused, else copy; sealed history
Dictation: capture while the shortcut is held, transcribe on this PC,
optionally clean up or compose with Think, then insert at the cursor
(`DictationCoordinator.swift`). Insertion is allowed only while the app and
field that had focus at the press still do; otherwise the text is copied.
The latest results are kept, sealed on disk, so one left on the clipboard
can be copied again (`DictationHistory`).

#### Show preparation panel only after a short grace period
`PREPARATION_GRACE`: A status-only preparation reaches the overlay once it outlasts this. A warm
model's check ends at once and must not flash the panel.

#### Press focus read may still finish for up to two seconds
`PRESS_WAIT`: How long the press's focus read may still be finishing when speech ends.

#### MicCapture collects 16 kHz mono
`SAMPLE_RATE`: `MicCapture` collects 16 kHz mono.

#### Wait for sound still fading after a player pauses before mic opens
`MEDIA_SETTLE`: Sound already on its way out when a player paused, before the mic opens.

#### Earlier resume gets 1.5 s before new dictation proceeds without it
`MEDIA_CLEANUP_WAIT`: An earlier resume gets this long before a new dictation goes on without it.

#### Bumped on start, finish, cancel so superseded runs never deliver
`Dictation.session`: Bumped by every start, finish and cancel, so a superseded run never
delivers or writes state.

#### Pasted text the field did not show, one click from copying again
`Dictation.notice`: Pasted text the field did not show, one click from being copied again.

#### Under one second recorded before mic loss is not transcribed
`WORTH_TRANSCRIBING_SECONDS`: Less than this recorded when the microphone is lost is not worth
transcribing (`shouldTranscribeAfterMicrophoneFailure`).

#### Shortcut never cancels finished speech; menu and overlay controls keep Cancel
`toggle_action`: The shortcut never cancels finished speech: a second press while the text
is being prepared must not delete the recording and the transcript. While
the speech model needs attention it retries instead. The menu and other
on-screen controls keep their explicit Cancel (`toggleAction`).

#### Players resume when capture ends, however it ends
`Listening.media`: Resumed when the capture ends, however it ends.

#### Desktop with no focus info still pastes; refusing would make dictation copy-only
`Binding.Unknown`: This desktop says nothing about focus: paste as asked, since refusing
would make dictation copy-only on the whole desktop.

#### Bluetooth headsets need a moment to switch to headset mode
`idle_microphone_status`: A running microphone that is not delivering audio. A Bluetooth headset
takes a moment to switch into headset mode (`idleMicrophoneStatus`).

#### Load recent history off engine thread; credential store may ask to unlock
`Dictation::new`: Off the engine thread: the credential store may ask to unlock.

#### Rehearsal from Settings shows the result and never inserts
`Dictation.handle`: Trying it in Settings shows the result and never inserts.

#### Newer dictation ends read-back and notice from the previous one
`Dictation.start`: A newer dictation ends any read-back and notice from the last one.

#### Focus read begins at shortcut press, not during recording
`Dictation.start`: The focus read starts at the shortcut, alongside the microphone: a
read during recording would bind whichever app had focus by then.

#### Wait for earlier cancel's resume so it cannot interrupt this capture
`Dictation.start`: An earlier cancel may still be restoring the players it paused. Wait,
or its late resume could interrupt this capture. Then pause what is
playing now and give the sound a moment to stop.

#### Download missing model during recording so it is ready when speech ends
`Dictation.start`: The model is ready when the person finishes speaking, not after: one
that is missing downloads now, and the speech waits in memory.

#### Start cue plays only once audio actually arrives
`Dictation.start`: The cue plays only once audio arrives: pressing the
shortcut does not mean the microphone is listening.

#### Only real download progress shows while recording; warm model never flashes panel
`Dictation.start`: Only real download progress shows while recording,
so a warm model never flashes the panel
(`shouldShowModelPreparation`).

#### Lost mic ends dictation and keeps what was said
`Dictation.microphone_lost`: The microphone could not be reopened, so the dictation ends here
instead of listening to nothing until the shortcut is pressed again.
What was said before it stopped is kept (`refreshCaptureHealth`).

#### dictation_working is cleared by Runner::run however it ends
`Dictation.finish`: Cleared again by `Runner::run`, however that run ends.

#### Audio kept as WAV in library dictations folder, as on macOS
`keep_audio`: Keep dictation audio files: `<library>/dictations`, as on macOS, as WAV.

#### Digests and reviews wait while dictation_working is set, so every exit clears it
`Runner.run`: Day digests and overnight reviews wait while this is set, so every
way out clears it: a cancel or a failed load before the text too.

#### Audio stays in memory for Retry after model load failure
`Runner.run`: The audio stays in memory for Retry; nothing is lost.

#### Missing model download shows overlay progress while audio stays in memory
`Runner.install_model`: Finishes downloading a missing model, with its progress in the overlay.
The audio stays in memory for as long as that takes.

#### Cancelled dictation lets the download continue, as from Settings
`Runner.install_model`: Cancelled: the download goes on, as it would from Settings.

#### Show preparation only after delay; running preview pass is not preparation
`Runner.prepare_model`: Loads the speech model, showing that in the overlay only once it takes
a while (`shouldShowModelPreparation`). A preview pass still decoding
is not preparation: the final pass waits for its current window.

#### Overlapping windows stitched; shares speech model, final pass waits for it
`run_preview`: The rolling live transcript (`runLivePreviewLoop`): overlapping windows of
the recording, stitched together. It shares the loaded speech model with
the final pass, which waits for a pass in progress.

#### Too short and no speech advance; other failures retry same audio
`run_preview`: Too short and no speech still advance, so one silent window is not
retried forever; anything else tries the same audio again later.

#### Window reaching recording start is the complete prefix
`run_preview`: While the overlap reaches the recording's beginning,
this window is the complete prefix.

#### Direct sentences must not gain claims from nearby messages; stop screen capture
`process`: A direct sentence must not acquire claims from nearby messages, so the
capture that began during recording stops here.

#### Source and grant changes also block delivery
`process`: Sources and grants guard delivery too.

#### Compose failure must not lose transcribed speech; keep it as not inserted
`process`: Compose failing must not lose minutes of transcribed speech.

#### Text meant for a password field is never kept
`process`: Text meant for a password field is never kept.

#### Earlier paste may hold the queue, so recheck the field
`deliver_with`: An earlier paste may hold the queue; check the field again.

#### Notice only when readable field lacks text; unreadable Electron/web editors left alone
`ReadBack`: Reads the field back after a paste. Only a field that can be read and still
lacks the text raises the notice; an unreadable one (many Electron and web
editors) is left alone rather than guessed at. The read is compared here
and dropped.

#### Read back only the exact target field, never an excluded app
`ReadBack.of`: Only the exact field the text went to, and never an excluded app.

#### Reads window title and address once; keeps words only if exclusions pass
`keep_for_learning`: Learn from my dictation (`keepForLearning`): reads the pasted-into window's
title and page address once, and keeps the spoken words only if they pass the
same exclusions as nearby text. Anything unreadable keeps nothing.

#### Text dictated into a password manager is never kept
`StartedIn.password_manager`: Text dictated into a password manager is never kept.

#### Recent dictations sealed when credential store keeps key; else until quit
`Recent`: Recent dictations: in memory, and sealed in the library whenever the
credential store can keep their key. Without one they last until quit.

#### Orders writes and deletes; each writes history as it is then
`Recent.files`: Orders writes and deletes; each writes the history as it is then.

#### Pretend downloading for test duration so nothing is fetched
`waiting_for_the_model`: A recording waiting for its speech model, which is "downloading" for
as long as the test runs, so nothing is fetched.

#### Runs ending before text must clear dictation_working that blocks digests
`a_run_cancelled_while_its_model_loads_stops_counting_as_working`: Day digests and overnight reviews wait while `dictation_working` is
set, so a run that ends before the text must clear it too.

#### Model pretends to download so kept audio waits and nothing is fetched
`a_lost_microphone_ends_the_dictation_and_keeps_what_was_said`: The speech model "downloads" for as long as the test runs, so the
kept audio waits for it and nothing is fetched.

#### Dictation and meeting share a microphone; meeting recording wins
`dictation_does_not_start_during_a_meeting_recording`: The two share a microphone; the meeting recording wins.

#### Password field focused at press never becomes a target
`a_password_field_is_never_pasted_into`: It had focus at the press: no target is ever bound.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
