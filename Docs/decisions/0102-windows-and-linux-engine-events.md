# 0102. Windows and Linux: engine — events

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/src/events.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/src/events.rs`

#### ReviewNow runs the overnight review for the previous day
`Command::ReviewNow`: The overnight review, now, for the previous day.

#### ClearWorkMemory deletes every overnight review and the work memory
`Command::ClearWorkMemory`: Delete every overnight review and the work memory.

#### Naming a speaker remembers the voice and suggests it elsewhere
`Command::LearnSpeakerVoices`: A name was given or applied: remember the voice and suggest it elsewhere.

#### On quit save recordings, defer processing, reply false to keep app open
`Command::PrepareForQuit`: Quitting soon: stop any recording and save it, leaving its processing
for the next launch. Answers false when something could not be saved,
and then the app stays open so the person can fix it and quit again.

#### User-initiated processing jobs may download missing models
`Command::ProcessMeeting`: Retry or redo processing. User-initiated jobs may download missing models.

#### Retry replaces the failed turn and its question
`Command::Ask.retry_of`: The failed turn this asks again; it and its question are replaced.

#### PrepareModels downloads every model the current settings need
`Command::PrepareModels`: Downloads every model the current settings need.

#### Opening a project writes its note only if due and Think may run unattended
`Command::ProjectOpened`: A tracked project's page opened: write or refresh its note if it is due
and the Think model may run unattended.

#### Follow-up uses local Think model; nothing sent or saved, draft returned
`Command::WriteFollowUp`: Writes a meeting's follow-up with the local Think model. Nothing is
sent or saved; the draft comes back for review.

#### Capture front window, or next window within seconds if LokalBot is front
`Command::CaptureScreenNow`: "Capture Screen Now": capture the window in front, or the next one
to come to the front within a few seconds when LokalBot itself is.

#### Today's Record on a calendar event records now, stamped with it
`Command::RecordCalendarEvent`: Today's Record on a calendar event: record now, stamped with it.

#### Calendar links are saved in the credential store, replacing old ones
`Command::SetCalendarLinks`: Saves the private calendar links in the credential store (replacing
the saved ones) and reads them.

#### Restart activity and screen capture after the desktop changed
`Command::RestartMemoryCapture`: Stops activity and screen capture and starts them afresh, for a desktop
that came back changed (`restartMemoryCapture`).

#### Gather meeting evidence; with generate also write the brief on-device
`Command::PrepareMeeting`: Gathers what LokalBot knows for an upcoming meeting; with `generate`,
also writes the brief with the on-device Think model.

#### Detected recording is suppressed for an event the user just stopped
`Command::StartDetectedRecording`: The detector found a call to record (automatic mode). Unlike
`StartRecording`, it is suppressed for an event the user just stopped.

#### Split a detected recording when the next calendar event begins mid-call
`Command::SplitForCalendarHandoff`: The next calendar event began within the call the detector is
recording: stop this recording and start one for the next event.

#### Read aloud takes voice and speed from the settings
`SpeechCommand`: Read aloud. Voice and speed come from the settings.

#### Read stops current speech; key lets the interface offer Stop in place
`SpeechCommand::Read`: Reads `text` aloud, stopping whatever is being read. `key` names what
it is, so the interface can offer Stop in the right place.

#### Preparing means downloading or synthesizing with no sound yet
`SpeechStatus.preparing`: Still downloading or synthesizing; no sound yet.

#### Error carries the failing key; SPEECH_EXPORT_KEY marks an export
`SpeechStatus.error`: The last failure and the key it belongs to (`SPEECH_EXPORT_KEY` for an export).

#### The shortcut never cancels speech already being prepared
`DictationCommand::Toggle`: The shortcut: never cancels speech already being prepared.

#### Menu and on-screen controls do cancel while text is being prepared
`DictationCommand::ToggleFromMenu`: The menu, the palette and other on-screen controls: their Cancel row
does cancel while the text is being prepared (`toggleAction`).

#### CopyRecent copies the newest dictation by default
`DictationCommand::CopyRecent`: Puts a recent dictation, the newest by default, on the clipboard.

#### ClearRecent forgets recent dictations and deletes their file
`DictationCommand::ClearRecent`: Forgets the recent dictations and deletes their file.

#### Copies the text a field did not show after a paste
`DictationCommand::CopyNotice`: Copies the text a field did not show after a paste.

#### Retry the speech model while keeping the recorded audio
`DictationCommand::RetryPreparation`: Tries the speech model again, keeping the audio.

#### Engine-originated: the numbered dictation's microphone stopped and could not reopen
`DictationCommand::MicrophoneLost`: From the engine itself: the microphone of the dictation with this
number stopped and could not be reopened.

#### Shortcut reads the selection first, then opens the panel
`SelectionCommand::Invoke`: The shortcut was pressed: read the selection, then open the panel.

#### Return to the action list while keeping the selection
`SelectionCommand::ChooseAgain`: Back to the list of actions, keeping the selection.

#### Insert replaces the selection or inserts at the cursor
`SelectionCommand::Insert`: Replace the selection with the result, or insert it at the cursor.

#### Closing the panel stops generating and forgets the selection
`SelectionCommand::PanelClosed`: The panel closed: stop generating and forget the selection.

#### Chosen Files folders only take effect while Files is on
`AskScope.include_files`: The folders chosen under Files. Only takes effect while Files is on.

#### Agent notes only take effect while Read coding agent notes is on
`AskScope.include_agent_notes`: Notes the person's coding agents saved. Only takes effect while Read
coding agent notes is on.

#### Screens bound to a question: asked-about results or attached ones
`AskScope.screen_ids`: Screens this question is bound to: the moments among asked-about results,
or the ones attached.

#### Attached screens are read as primary evidence
`AskScope.attached_screens`: `screen_ids` were attached by the person: they are read as primary evidence.

#### Sent when OCR capability changes outside the app's own downloads
`EngineEvent::ScreenText`: What screen text recognition can do changed: something was installed or
removed outside the app's own downloads.

#### Stage is None when the meeting is no longer being processed
`EngineEvent::Processing`: `None` when the meeting is no longer being processed.

#### Fired when a call starts in 'Ask via notification' recording mode
`EngineEvent::CallDetected`: A meeting app started a call while recording mode is "Ask via notification".

#### Selection state is sent whole; open_panel requests the panel
`EngineEvent::Selection`: Selection actions' state, whole. `open_panel` asks for the panel.

#### Recent dictations sent newest first after each change
`EngineEvent::RecentDictations`: The recent dictations, newest first, after each change.

#### Whole live transcript preview is sent on every change
`EngineEvent::LivePreview`: The whole live transcript preview, sent on every change.

#### A check result lasts only as long as its configuration
`ModelCheckResult.configuration`: The configuration it exercised; a result lasts as long as this does.

#### More roles may follow the one being tested
`ModelCheckStatus.testing`: More roles may follow `testing`.

#### The preparation brief stays in memory only
`MeetingPreparation`: What Today shows under the next meeting. The brief stays in memory only.

#### Start position applies to the first start only
`LivePreviewCommand::Start`: Start, resume or retry. The start position applies to the first start only.

#### Line time is seconds from the start of the recording
`LiveLine.start`: Seconds from the start of the recording.

#### Me means microphone rather than system audio
`LiveLine.me`: From the microphone ("Me") rather than system audio.

#### Status text shows preparation and retry progress
`LivePreview.status`: "Preparing the transcription model…", "Retrying live preview… (1/3)".

#### Preview start is in seconds from the start of the recording
`LivePreview.offset`: Where the preview starts, in seconds from the start of the recording.

#### Mirrors ScreenshotService state and MemoryHealthSection on macOS
`ScreenStatus`: Screen context capture as Settings shows it (`ScreenshotService`'s
published state and `MemoryHealthSection`).

#### Active needs screen context on, tracking on, day memory not paused
`ScreenStatus.active`: Text and images are being captured (screen context on, tracking on,
day memory not paused).

#### Why this desktop cannot capture window pixels or OCR
`ScreenStatus.capture_limitation`: Why this desktop cannot capture window pixels (and so cannot OCR), if so.

#### Why visible text cannot be read through accessibility
`ScreenStatus.text_limitation`: Why visible text cannot be read through accessibility, if so.

#### Images cannot be kept without a system credential store
`ScreenStatus.images_unavailable`: Why images cannot be kept (no system credential store), if so.

#### Values are accessibility, ocr, hybrid, optionally with _redacted
`ScreenStatus.last_text_source`: `accessibility`, `ocr`, `hybrid` (with `_redacted`) of the last capture.

#### Capture Screen Now waits for another window to come front
`ScreenStatus.waiting_for_window`: "Capture Screen Now" is waiting for another window to come to the front.

#### Sent only while autocomplete is on; never for secure fields or excluded apps
`FieldContext`: The text field the user is typing in, as the desktop integration reads
it (`CotypingSurfaceContext`). Sent on edits and caret moves while
autocomplete is on; never for secure fields or excluded apps.

#### Id changes with focus; updates for an old id are stale
`FieldContext.field_id`: Changes when focus moves to another field; updates for an old id are stale.

#### App id is an executable or desktop id such as firefox
`FieldContext.app_id`: Executable or desktop id: "firefox", "code.exe".

#### Text before the caret, bounded by the reader
`FieldContext.before`: Text before the caret (bounded by the reader).

#### After text is limited to the same paragraph
`FieldContext.after`: Text after the caret in the same paragraph.

#### Single-line means inputs where Enter sends
`FieldContext.single_line`: Inputs where Enter sends (search boxes, chat inputs).

#### Field frame is in pixels, when known
`FieldContext.field_frame`: The field on screen, in pixels, when known.

#### Accepted carries the shown suggestion start and the text typed for it
`AutocompleteCommand::Accepted`: The user accepted `text`, the start of the shown suggestion, and
`inserted` was typed for it.

#### Leaving every field also drops the suggestion's context
`AutocompleteCommand::LeftField`: Focus left every field the suggestion could belong to: its context
goes too.

#### With an unusable store, learning stays in memory and nothing is written
`AutocompleteLearning.problem`: Why the store cannot be used, worded for Settings. Learning then stays
in memory and nothing is written.

#### Saved facts behind a suggestion are rechecked before an accept
`AutocompleteUpdate::Suggestion.guard`: The saved facts behind it, checked again before an accept.

#### Source titles are listed by the grant that admitted them
`AutocompleteRehearsal.meeting_sources`: Titles of the saved sources used, by the grant that admitted them.

#### True when a lookup ran even if it found nothing
`AutocompleteRehearsal.searched_memory`: A saved-memory lookup ran, whether or not it found anything.

#### Model name fills 'Written on this PC by …'
`FollowUpUpdate.model`: "Qwen3.5 4B" for "Written on this PC by …".

#### Saved notification is absent on quit, matching macOS
`RecordingUpdate::Stopped.saved`: The "Recording saved" notification. Absent on quit, as on macOS.

#### CUDA is downloaded but its setup GPU check has not passed
`ModelStatus.runtime_needs_check`: CUDA is downloaded, but its setup GPU check has not passed.

#### Model loading or downloading while recording continues; progress 0-1
`DictationUpdate::Preparing`: The speech model is taking a moment to load, or downloading while the
recording goes on. `progress` is how far a download is, 0–1.

#### After a model load failure the audio waits for Retry
`DictationUpdate::PreparationFailed`: The speech model did not load; the audio waits for Retry.

#### inserted is false when text went to the clipboard instead
`DictationUpdate::Finished.inserted`: `inserted` is false when the text went to the clipboard instead.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
