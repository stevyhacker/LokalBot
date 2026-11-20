# 0081. Windows and Linux: app — state

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-app/src/state.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-app/src/state.rs`

#### Pages read AppData globally and change it only via its methods
App-wide state shared by every page: the library, settings, navigation,
recording and background-work status.

Pages read it with `AppData::global(cx).read(cx)` and change it only through
the methods below, so the engine wiring stays in one place.

#### Section mirrors the Mac NavSection; Settings has its own window
`Section`: A destination in the main window's sidebar (`AppState.NavSection`).
Settings is not one: it has its own window ([`AppData::open_settings`]).

#### Section icons must match the Mac sidebar symbols
`Section.icon`: The icon beside the section in the sidebar. Panels that lead to a
section show the same one (`NavSection.symbol`, as Lucide icons:
sun.max, checkmark.circle, waveform.circle, calendar.day.timeline.left,
person.2, folder, sparkle.magnifyingglass, wand.and.sparkles).

#### Page names: capture maps to Timeline, search and chat to Ask
`Section::named`: Section names accepted by `--page` and deep links. "capture" (the old
merged section) lands on Timeline and "search"/"chat" on Ask, as on
the Mac (`NavSection.init(captureName:)`). Settings pages have their
own window: see `SettingsCategory::named`.

#### One Settings page per feature, mirroring the Mac SettingsTab
`SettingsCategory`: A Settings page (`AppState.SettingsTab`). Each feature has one page with
everything that sets it up; the window lists them in
`pages::settings::CATEGORIES`.

#### Overview lists what needs attention, data location and shortcuts
`SettingsCategory::Overview`: The LokalBot row at the top of the list: what needs you, where your
data is, and the keyboard shortcuts.

#### Privacy page covers permissions and what leaves the computer
`SettingsCategory::Privacy`: Privacy & permissions: what LokalBot may use here, and what leaves.

#### DayMemory page is labelled Screen and activity
`SettingsCategory::DayMemory`: Screen & activity.

#### Ask page holds Quick Recall, selection actions and searchable sources
`SettingsCategory::Ask`: Quick Recall, selection actions and what Ask can search.

#### PersonalContext page is the About you page
`SettingsCategory::PersonalContext`: About you.

#### DailyReview covers digest, overnight review, routines and daily note
`SettingsCategory::DailyReview`: The day digest, the overnight review, routines and the daily note.

#### Writing page configures autocomplete
`SettingsCategory::Writing`: Autocomplete.

#### Agents page covers external agent access and the CLI
`SettingsCategory::Agents`: AI agents: what external agents may read or change, and the CLI.

#### Devices page is for phones and tablets
`SettingsCategory::Devices`: Phones & tablets.

#### Advanced page holds diagnostics
`SettingsCategory::Advanced`: Diagnostics.

#### Settings page names accept legacy names from before feature organization
`SettingsCategory::named`: The Settings page a `--page` name opens: "settings" is Overview, and
"settings-\<page>" names one page, by its name now or before Settings
was organized by feature (`SettingsTab.init(captureName:)`).

#### Key equals the Mac raw value stored in settings_page
`SettingsCategory::key`: The Mac's raw value (`SettingsTab.rawValue`), which is what
`Settings::settings_page` keeps.

#### Unknown saved page keys open Overview
`SettingsCategory::from_key`: The page a saved [`Self::key`] names; anything else opens Overview.

#### False when system audio could not be captured
`RecordingState::Recording.has_system_audio`: False when system audio could not be captured.

#### Progress is a fraction from 0.0 to 1.0 when known
`BackgroundItem.progress`: 0.0–1.0 when known.

#### Meeting ids limit the sources Ask searches
`AskRequest.meeting_ids`: Limit sources to these meetings.

#### Day limits sources for Ask About Today and This Day
`AskRequest.day`: Limit sources to this day (Ask About Today, Ask About This Day).

#### Records where Back returns after opening a meeting from evidence
`EvidenceReturn`: Where a meeting opened from evidence goes Back to (`evidenceReturnSection`).

#### Prompt from another page fills the draft and is never sent
`AgentRequest::Prompt`: A prompt from another page, for the selected task's draft. Never sent.

#### Session id is a WorkSession id
`TimelineFocus.session_id`: `WorkSession::id`.

#### Moment id is a ScreenMoment id
`TimelineFocus.moment_id`: `ScreenMoment::id`.

#### Visible meetings are kept newest first
`AppData.meetings`: Visible meetings, newest first.

#### Reload counters discard overlapping reads that finish out of order
`AppData.reloads_started`: How many [`Self::reload`]s have started, and the latest whose list was
taken: one that started earlier and finished later is out of date.

#### Revision bumps on library changes so pages reload lazily
`AppData.revision`: Bumped whenever library content changes, so pages can reload lazily.

#### Page the Settings window shows or opens on
`AppData.settings_category`: The page the Settings window shows, or opens on.

#### Setting to scroll to and highlight, as on the Mac
`AppData.settings_focus`: A setting for Settings to scroll to and highlight (`focusedSettingID`).

#### Remembers where evidence was opened from for Back
`AppData.evidence_return`: Where evidence was opened from, for the Back button (`evidenceReturnSection`).

#### Warnings belong to the recording in progress
`AppData.capture_warnings`: Warnings of the recording in progress.

#### Agent page acts on the request when it next draws
`AppData.agent_request`: For the Agent page to act on when it next draws.

#### Ctrl+F waits here until the meeting page opens Find
`AppData.meeting_find_requested`: Ctrl+F on the meeting page, waiting for the page to open Find.

#### Meeting whose follow-up draft should open
`AppData.follow_up_request`: A meeting whose follow-up draft should open.

#### Screen moment attached to the next question
`AppData.ask_screen`: A screen moment to attach to the next question ("Ask About This…").

#### Work session moments form the next question's boundary
`AppData.ask_screens`: A work session's moments, as the next question's boundary.

#### Some narrows next question's sources; None keeps the user's choice
`AppData.ask_sources`: The sources the next question searches, when the handoff narrows them
(Quick Recall's "Show all" for one kind). `None` leaves them as chosen.

#### Conversation Ask opens from Quick Recall's Continue in main window
`AppData.ask_open_conversation`: A conversation for Ask to open (Quick Recall's Continue in main window).

#### Screen ids stay in memory for retry; only days reach the conversation
`AppData.attached_asks`: The latest question of each conversation that attached screens. Their
ids stay in memory for a retry; only their days reach the conversation.

#### Holds the saved coding-agent note count or why none could be
`AppData.agent_notes`: How many coding-agent notes are saved, or why none could be.

#### PersonProfile id for People to select
`AppData.person_focus`: A person (`PersonProfile::id`) for People to select.

#### ProjectProfile id for Projects to select
`AppData.project_focus`: A project (`ProjectProfile::id`) for Projects to select.

#### Queued import file names, the one in progress first
`AppData.importing`: File names waiting to be imported, the one in progress first.

#### Settings wording about Think and its hosts
`AppData.inference_label`: What Settings says about Think and its hosts ([`inference_presentation`]).

#### Sidebar line stating where the library and AI are
`AppData.privacy`: The sidebar's line about where the library and the AI are.

#### Counts open user action threads; None until first counted
`AppData.open_action_count`: How many open action threads are the user's: the Actions row's count
(`OutcomeIndex.openUserActionThreads`). `None` until first counted.

#### Library revision at which the action count was taken
`AppData.open_actions_counted`: The library revision `open_action_count` was counted at.

#### Engine appends streamed answer text then saves the finished turn
`AppData.ask_stream`: The answer being written right now, if any. The engine appends text
as it streams and saves the finished turn into the conversation file.

#### Model downloads are keyed by catalog id
`AppData.downloads`: Model downloads by catalog id.

#### Tracks installed models and the runtime used for Think
`AppData.models`: Which models are present and which runtime the Think role uses.

#### Day whose digest is currently being written
`AppData.digest_running`: Day whose digest is being written.

#### Project ids whose Where it stands note is being written
`AppData.project_notes_running`: Project ids whose "Where it stands" note is being written.

#### Holds dictation text when output mode is Show in LokalBot
`AppData.last_dictation`: Text of the last dictation shown in LokalBot (output mode "Show in LokalBot").

#### How the last dictation came about, for Last result
`AppData.last_dictation_details`: How the last dictation came about, for Last result.

#### Latest dictations newest first so one can be copied again
`AppData.recent_dictations`: The latest dictations, newest first, for copying one again.

#### Settings and Today read overnight review status from here
`AppData.dream`: Settings and Today read this for the overnight review.

#### Microphone names for Settings pickers, filled by the engine
`AppData.audio_inputs`: Microphone names for the device pickers in Settings, filled by the engine.

#### Computer permissions probe, read via refresh_access
`AppData.access`: What this computer allows, as setup and Settings both show it
(`crate::access`), read by `refresh_access`.

#### Global shortcuts pause while Settings records a new shortcut
`AppData.shortcut_recording`: Settings is recording a new shortcut: global shortcuts should pause
so the keystroke reaches the recorder.

#### Dictation shortcut is enabled but failed to register
`AppData.dictation_shortcut_inactive`: Dictation's shortcut is on but didn't register.

#### Serial lets a timed dismissal check its notice is still showing
`AppData.dictation_notice_serial`: Tells a timed dismissal whether its notice is still the one showing.

#### Per-source status strings shown while recording
`AppData.recording_statuses`: "Mic · Receiving audio" / "System · Not attached" while recording.

#### Recovery time kept until the next recording starts
`AppData.last_audio_recovery`: When a lost track last came back; kept until the next recording starts.

#### Live transcript preview of the meeting is opt-in
`AppData.live_preview`: The opt-in live transcript preview of the meeting being recorded.

#### Read-aloud state: what is being read and its last failure
`AppData.speech`: Read aloud: what is being read, and its last failure.

#### Model setup check tracks the role checked and results so far
`AppData.model_checks`: Check model setup: the role being checked and the results so far.

#### Cancelled downloads are recorded so a model switch can stop
`AppData.cancelled_downloads`: Downloads cancelled since a model switch last started, so it can stop.

#### Pairing request whose question is currently on screen
`AppData.pairing_prompt`: The pairing request whose question is on screen.

#### Meeting preparation is held in memory only
`AppData.meeting_preparation`: Today's preparation for the next meeting (in memory only).

#### Try a sample meeting waits here for its models
`AppData.sample_setup`: "Try a sample meeting" waiting for its models (`sample.rs`).

#### Follow-up rewrite with Think mirrors the Mac FollowUpDraftSheet
`FollowUpWriting`: A follow-up being rewritten with Think (`FollowUpDraftSheet`).

#### Model name feeds the Written on this PC by disclosure
`FollowUpWriting::Written.model`: "Qwen3.5 4B", for "Written on this PC by …".

#### Overlay says starting until the microphone delivers audio
`DictationHud::Listening.microphone_live`: Until the microphone delivers audio the overlay says it is starting.

#### A microphone problem replaces the level bars
`DictationHud::Listening.capture_status`: A microphone problem, in place of the level bars.

#### Speech model loading or downloading, progress 0 to 1
`DictationHud::Preparing`: The speech model is loading, or downloading (how far, 0–1).

#### Speech model load failure; Retry keeps the audio
`DictationHud::PreparationFailed`: The speech model did not load; Retry keeps the audio.

#### Brief notice such as Copied to the clipboard
`DictationHud::Notice`: "Copied to the clipboard" and similar, shown briefly.

#### Pasted text the field did not show, offered with Copy
`DictationHud::Undelivered`: Pasted text the field did not show, with Copy.

#### Mirrors the Mac DictationView last result section
`LastDictationDetails`: How the last dictation came about (`DictationView.lastResultSection`).

#### Spoken text shown only when Compose wrote different text
`LastDictationDetails.spoken`: What was said, when Compose wrote something else from it.

#### Context summary lists what was used, such as focused window
`LastDictationDetails.context`: "Used: focused window; visible text".

#### Engine summary names speech model, writer model and location
`LastDictationDetails.engine`: "Parakeet v3 → Qwen3.5 4B · on this PC".

#### Streamed text carries meeting citations inline as [meeting:...]
`AskStream.text`: Assistant text so far, with `[meeting:…]` citations inline.

#### Activity steps render as a worked summary line
`AskStream.activity`: Steps shown as "worked: searched meetings · read “Design review”".

#### Status shows Preparing model name while the model loads
`AskStream.status`: "Preparing Qwen3.5 4B" while the model loads.

#### Installed lists only fully downloaded catalog ids
`ModelStatus.installed`: Catalog ids that are fully downloaded.

#### True when any screen text recognition engine can read
`ModelStatus.screen_text_ready`: Some screen text recognition engine can read now.

#### Reports which OCR engine, languages and helpful downloads
`ModelStatus.screen_text`: Which one, in which languages, and what download would help.

#### Backend is CUDA, Vulkan or CPU once runtime is installed
`ModelStatus.runtime_backend`: "CUDA", "Vulkan" or "CPU" for the selected built-in runtime, once installed.

#### CUDA downloaded but setup GPU check has not passed
`ModelStatus.runtime_needs_check`: CUDA is downloaded, but its setup GPU check has not passed.

#### Empty meeting ids means every meeting
`AskScope.meeting_ids`: Empty means every meeting.

#### Engine honours Files only while Files is on
`AskScope.include_files`: The folders chosen under Files; the engine honours it only while Files is on.

#### Engine honours agent notes only while they are read
`AskScope.include_agent_notes`: Saved coding-agent notes; the engine honours it only while they are read.

#### Screens the question is bound to or attaches
`AskScope.screen_ids`: Screens this question is bound to or attaches.

#### Screen ids were attached by the person as primary evidence
`AskScope.attached_screens`: `screen_ids` were attached by the person, as primary evidence.

#### Boundary saved with the question's turns
`AskScope.saved`: The boundary saved with the question's turns.

#### Unnamed devices are excluded because settings store the name
`microphone_names`: What the microphone pickers offer. A device with no name can't be chosen,
because the setting stores the name.

#### Overnight review periods get a start so updates skip older days
`AppData::new`: Each enabled period of the overnight review has a start, so an update
to a version that has it doesn't review older days.

#### Pages request engine work through one place instead of emitting
`AppData::request`: Asks the engine for work. Pages call this instead of emitting directly
so every request goes through one place.

#### List microphones off the UI thread because backends can be slow
`AppData::refresh_audio_inputs`: Lists microphones away from the UI thread: audio backends can be slow.

#### Probe runs off UI thread; session bus and portal waits; read-only
`AppData::refresh_access`: Reads what this computer allows away from the UI thread: the checks
can wait on the session bus and the screenshot portal for seconds.
Only reads; nothing prompts or turns on.

#### Re-read access only when the reading is 10 seconds old
`AppData::refresh_access_if_stale`: `refresh_access`, unless the reading is only a few seconds old, for
views that show it while open.

#### Combine the probe with what the running app observed itself
`AppData::access_observed`: What the running app has seen for itself, beside the reading.

#### Back returns to where evidence was opened, as on the Mac
`AppData::return_from_evidence`: Back to where evidence was opened from (`returnFromEvidence`).

#### Retry repeats only what failed and may download models
`AppData::retry_processing`: Repeats only what failed (`AppState.retryProcessing`). A person's retry
may download what it needs.

#### Opens Timeline on a moment, as the Mac moment detail view
`AppData::open_screen_moment`: Timeline with one screen moment open (`ScreenMomentDetailView`).

#### Opens the Actions page, matching Mac openActions
`AppData::open_actions`: The Actions page (`openActions`).

#### All routes to Settings go through one opener that keeps main window
`AppData::open_settings`: Opens the Settings window on `category`, or brings it forward there
(`AppState.openSettings(tab:)`). The main window stays where it was.
Every link, menu, command and notification that leads to Settings
comes through here.

#### Chosen Settings page is remembered across relaunch
`AppData::select_settings_category`: A category picked inside the Settings window, which is already open.
It is remembered, so Settings opens on it again after a relaunch
(`AppState.settingsTab`).

#### Settings page is saved without notifying the engine
`AppData::remember_settings_page`: Saves the page shown without telling the engine: nothing it does
depends on which page Settings shows.

#### Recount open actions only when library changed, off UI thread
`AppData::refresh_open_action_count`: Counts the user's open action threads again when the library changed
since the last count. The count runs off the UI thread.

#### A newer count in flight reports instead of the stale one
`AppData::refresh_open_action_count`: A newer count has started; it will report.

#### Question is sent with what a retry needs kept
`AppData::ask_question`: Sends a question, keeping what a retry of it would need.

#### Prompt goes into the Agent composer unsent
`AppData::open_agent`: Agent with `prompt` in its composer, unsent (`AppState.openAgent`).

#### Discard older overlapping reads so removed meetings do not return
`AppData::reload`: Reads overlap; a slower, older one would bring back a
meeting that a newer one no longer lists.

#### Pages that write meeting files bump revision so others reload
`AppData::mark_library_changed`: A page wrote meeting files itself (corrections, speaker names): pages
that show them reload on the next `revision`.

#### Any non-failed stage blocks merging, undoing and new boundaries
`AppData::is_processing`: Processing that blocks merging, undoing a merge or new boundaries:
anything but a failed run.

#### Imports sequentially, queues transcription, reports failures together
`AppData::import_recordings`: Imports files as meetings one at a time, then queues each for
transcription and, when on, notes (`AppState.importRecordings`).
Failures are reported together once the batch ends.

#### Keep file names out of the log; log extension only
`AppData::import_recordings`: The message names the file; keep file names out of the log.

#### Removes merged meeting and restores its sources, as on the Mac
`AppData::undo_merge`: Removes a merged meeting and restores its sources (`AppState.undoMerge`).

#### Undoing a merge removes its contributions from remembered voices
`AppData::undo_merge`: The merged meeting's own contributions leave remembered voices.

#### Cannot delete the meeting being recorded until recording stops
`AppData::delete_meeting`: The recorder is still writing into the folder of the meeting being
recorded; it can be deleted once the recording has stopped.

#### Saved screen moments are kept past the retention window
`AppData::save_screen_moment`: Saves a screen moment (or changes its note); saved moments are kept
past the retention window.

#### Deleting agent sessions withdraws journals; agents' own files stay
`AppData::delete_coding_agent_evidence`: Deletes every saved agent session, withdrawing the generated journals that
used them. The agents' own files stay.

#### Apply microphone_is_user immediately so meeting view redraws correctly
`AppData::update_settings`: The engine applies it too, but the meeting view redraws first.

#### Engine bridge in main.rs handles requests; results arrive as field changes
`AppEvent`: Requests that the engine bridge (in `main.rs`) handles. Results come back
as changes to `AppData` fields (`processing`, `ask_stream`, `downloads`,
`digest_running`, …) followed by `revision` bumps when files changed.

#### Remember a named voice and suggest it in other meetings
`AppEvent::LearnSpeakerVoices`: A name was given or applied: remember the voice and suggest it elsewhere.

#### Clears every overnight review and the work memory
`AppEvent::ClearWorkMemory`: Delete every overnight review and the work memory.

#### Covers Retry, Transcribe and Summarize, and Summarize again
`AppEvent::ProcessMeeting`: Transcribe and/or summarize a meeting again (Retry, "Transcribe & Summarize", "Summarize again").

#### A new conversation id starts a new conversation
`AppEvent::AskQuestion`: Ask a question in a conversation (a new id starts a new conversation).

#### Identifies the failed turn being asked again
`AppEvent::AskQuestion.retry_of`: The failed turn this asks again.

#### Catalog id covers Think, autocomplete, embeddings or speech
`AppEvent::DownloadModel`: Download a model by catalog id (Think, Autocomplete, embeddings or speech).

#### Downloads every model the current settings need
`AppEvent::PrepareModels`: Download every model the current settings need.

#### Writes the Where it stands note for a project id
`AppEvent::WriteProjectNote`: Write the "Where it stands" note for a project id.

#### Follow-up outline is rewritten with the local Think model
`AppEvent::WriteFollowUp`: Rewrite a meeting's follow-up outline with the local Think model.

#### Controls live preview: start, pause, resume or retry
`AppEvent::LivePreview`: Start, pause, resume or retry the live transcript preview.

#### UI-initiated dictation toggle used by Try here
`AppEvent::ToggleDictation`: Start or stop dictation from the UI ("Try here").

#### A call starting while recording asks the user first
`AppEvent::MeetingDetected`: A meeting app started a call while recording asks first.

#### API key lives in the credential store, never settings.json
`AppEvent::SaveApiKey`: Store the API key for the OpenAI-compatible server in the system
credential store (never in settings.json).

#### Blank value removes autocomplete's own server key
`AppEvent::SaveAutocompleteServerKey`: Saves, or when blank removes, autocomplete's own server key.

#### Capture Screen Now is offered in tray and Timeline
`AppEvent::CaptureScreenNow`: "Capture Screen Now" (tray and Timeline).

#### Today's Record action on a calendar event
`AppEvent::RecordCalendarEvent`: Today's Record on a calendar event.

#### Private calendar links are kept in the credential store
`AppEvent::SetCalendarLinks`: Replace the private calendar links kept in the credential store.

#### Gathers context for an upcoming meeting, writing a brief if generate
`AppEvent::PrepareMeeting`: Gather (and with `generate`, write a brief for) an upcoming meeting.

#### Settings' Think line and hosts; sidebar line is PrivacyLine
`inference_presentation`: Think's line and the hosts Settings names in its disclosures (Overview's
Models status, Compose dictation, phones' questions). The sidebar's own
line is [`PrivacyLine`].

#### Sidebar privacy line reflects the actual setup and names hosts once
`PrivacyLine`: The sidebar's line about where the library and the AI are
(`SidebarPrivacyLine`). It reflects the actual setup instead of a fixed
claim: with everything on this computer it is one line; a remote Think,
transcription or autocomplete server, or a Think connection that is
blocked, splits storage from AI and names each host once, because
meeting and workday text goes to those hosts.

#### Split shows storage line, AI line, then each host
`PrivacyLine::Split`: "Storage: this PC", the AI line, then each host.

#### AI line wording follows the Mac sidebar for split setups
`PrivacyLine::ai_label`: The AI line under "Storage: this PC": what the Mac's sidebar says for
a split setup.

#### Autocomplete's server must be listed or the UI falsely claims local
`remote_ai_hosts`: Every server that receives what this computer's AI features send, each
named once: Think's (while its connection is allowed), the transcription
server and, while autocomplete is on, the server it sends typing to
(`AppSettings.remoteAIHosts`). Leaving autocomplete out once read "on this
computer" while every suggestion request went to a server.

#### Sidebar Actions count equals open threads that are the user's
`open_user_action_count`: How many action threads are open and the user's: the number beside
Actions in the sidebar (`OutcomeIndex.openUserActionThreads.count`).

#### A model server on this computer still counts as local
`tests::everything_on_this_computer_is_one_line`: A model server on this computer is still this computer.

#### Subscription plans name their host only once approved
`tests::a_remote_think_server_splits_storage_and_names_its_host`: A subscription plan names the host it sends to once approved.

#### Autocomplete on Think's server lists that host once
`tests::autocomplete_names_its_server_only_while_on_and_each_host_once`: Autocomplete on Think's own server lists that server once.

#### On-device autocomplete adds no host
`tests::autocomplete_names_its_server_only_while_on_and_each_host_once`: On this computer it sends nothing anywhere.

#### Others' open work is not counted as the user's
`tests::the_actions_count_is_open_threads_that_are_yours`: Someone else's work is theirs to count.

#### Thread done in one meeting but open in another counts as open
`tests::the_actions_count_is_open_threads_that_are_yours`: Done in one meeting, still open in another: open.

#### Settings is a window, not a section name
`tests::page_names_reach_their_section_or_settings_page`: Settings is a window, not a section.

#### Former Settings page names must keep resolving
`tests::page_names_reach_their_section_or_settings_page`: Former page names still land on the page that holds them now.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
