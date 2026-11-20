# 0105. Windows and Linux: engine — other modules

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-engine/examples/`, `LinuxWindows/crates/lokalbot-engine/src/agent_notes/`, `LinuxWindows/crates/lokalbot-engine/src/ask.rs`, `LinuxWindows/crates/lokalbot-engine/src/autocomplete_measure.rs`, `LinuxWindows/crates/lokalbot-engine/src/autocomplete_window_text.rs`, `LinuxWindows/crates/lokalbot-engine/src/calendar.rs`, `LinuxWindows/crates/lokalbot-engine/src/capture_health.rs`, `LinuxWindows/crates/lokalbot-engine/src/daymemory.rs`, `LinuxWindows/crates/lokalbot-engine/src/detector.rs`, `LinuxWindows/crates/lokalbot-engine/src/diagnostics.rs`, `LinuxWindows/crates/lokalbot-engine/src/dictation_context.rs`, `LinuxWindows/crates/lokalbot-engine/src/digest.rs`, `LinuxWindows/crates/lokalbot-engine/src/dreaming.rs`, `LinuxWindows/crates/lokalbot-engine/src/exports/`, `LinuxWindows/crates/lokalbot-engine/src/health_check.rs`, `LinuxWindows/crates/lokalbot-engine/src/indexing.rs`, `LinuxWindows/crates/lokalbot-engine/src/lib.rs`, `LinuxWindows/crates/lokalbot-engine/src/library_ops.rs`, `LinuxWindows/crates/lokalbot-engine/src/live.rs`, `LinuxWindows/crates/lokalbot-engine/src/model_checks.rs`, `LinuxWindows/crates/lokalbot-engine/src/models.rs`, `LinuxWindows/crates/lokalbot-engine/src/project_notes.rs`, `LinuxWindows/crates/lokalbot-engine/src/recording.rs`, `LinuxWindows/crates/lokalbot-engine/src/resources.rs`, `LinuxWindows/crates/lokalbot-engine/src/retention.rs`, `LinuxWindows/crates/lokalbot-engine/src/routines.rs`, `LinuxWindows/crates/lokalbot-engine/src/sample.rs`, `LinuxWindows/crates/lokalbot-engine/src/screen.rs`, `LinuxWindows/crates/lokalbot-engine/src/screen_vectors.rs`, `LinuxWindows/crates/lokalbot-engine/src/secrets.rs`, `LinuxWindows/crates/lokalbot-engine/src/selection.rs`, `LinuxWindows/crates/lokalbot-engine/src/speak.rs`, `LinuxWindows/crates/lokalbot-engine/src/speech.rs`, `LinuxWindows/crates/lokalbot-engine/src/upcoming.rs`, `LinuxWindows/crates/lokalbot-engine/src/voice.rs`, `LinuxWindows/crates/lokalbot-engine/tests/`.

## Decisions

### `LinuxWindows/crates/lokalbot-engine/examples/autocomplete_eval.rs`

#### Autocomplete eval downloads model and runtime, measures wait after last keystroke
Autocomplete on a real model, without the desktop: downloads the
Autocomplete model and the llama.cpp runtime into a scratch library
through the catalog and runtime code, seeds the demo library there, then
types realistic text into simulated fields through the engine and reports
the wait from the last keystroke to the suggestion.

```sh
cargo run -p lokalbot-engine --example autocomplete_eval -- <scratch dir> \
    [--backend auto|cpu|vulkan|cuda] [--model <catalog id>] [--debounce <ms>] [--key-ms <ms>]
```

The scratch directory must be empty or an earlier run's. Each case focuses
a field with all but the last few characters, types the rest one key at a
time, and waits for the first suggestion after the last key.

#### Downloads go through catalog and runtime manager; Autocomplete never downloads itself
`main`: Downloads through the catalog and the runtime manager, as Settings →
Models does. Nothing here is downloaded by Autocomplete itself.

#### Warm-up starts server and loads model, not measured
`main`: Starts the server and loads the model; not measured.

#### Word-by-word acceptance keeps ghost ahead; top-up appends at two words left
`main`: Accepting word by word keeps the ghost a few words ahead: each Tab
shortens it at once, and a top-up appends more once two words are left.

#### Presses Tab like the desktop: insert chunk, report it, field shows it
`accept_word_by_word`: Types a case, then presses Tab `presses` times the way the desktop does:
it inserts `accept_chunk` of the ghost, reports it, and the field shows it.

#### On focus the engine reads the prompt ahead and looks up facts
`run`: Focus: the engine reads the field's prompt ahead and looks up facts.

### `LinuxWindows/crates/lokalbot-engine/examples/check_models.rs`

#### Prepare downloads models Transcribe needs before checking
Runs Check model setup without the UI, as Settings does.

`cargo run -p lokalbot-engine --example check_models -- <library> [--prepare] [transcribe|think|autocomplete]...`

`--prepare` downloads what the current settings need for Transcribe first.

### `LinuxWindows/crates/lokalbot-engine/examples/process_meeting.rs`

#### Prepare downloads models settings.json selects, like Settings Models
Runs one recording through the real pipeline without the UI: transcription,
speaker attribution, notes and actions, indexing, and optionally Ask.

`cargo run -p lokalbot-engine --example process_meeting -- <library> <mic.wav> [system.wav] [--prepare] [--ask "question"]`

`--prepare` first downloads the models `settings.json` selects, the way
Settings → Models does; without it the library must already hold them.
`--ask` then asks a question across the library and prints the answer.

### `LinuxWindows/crates/lokalbot-engine/examples/read_aloud.rs`

#### Read-aloud example downloads Kokoro when missing
Reads text with the real pipeline, without the UI: downloads Kokoro if it
is missing, saves the speech to a WAV file and tries the speakers.

`cargo run -p lokalbot-engine --example read_aloud -- <library> <out.wav> ["text"]`

### `LinuxWindows/crates/lokalbot-engine/examples/screen_capture.rs`

#### Screen capture check never writes to a library database; flags and defaults
Captures the window in front the way screen context does, reads its text
through accessibility and OCR, and saves the pixels for inspection.

```text
cargo run -p lokalbot-engine --example screen_capture -- \
    [--library <dir>] [--download-ocr] [--notepad "text to show"] [--delay <seconds>] [--save <file.jpg>]
```

- `--library`: where the OCR models are kept (`<dir>/models/ocrs`); default
  `lokalbot-screen-check` in the temporary folder.
- `--download-ocr`: download the pinned OCR models first (about 12 MB).
- `--notepad`: Windows only; opens Notepad with this text, brings it to
  the front and captures it.
- `--delay`: seconds to wait before capturing (default 3), time to bring
  another window to the front.
- `--save`: where the captured pixels go (default `<library>/screen-capture.jpg`).

Nothing is written to a LokalBot library's database.

### `LinuxWindows/crates/lokalbot-engine/src/agent_notes/claude.rs`

#### Claude notes are per-project memory files; MEMORY.md is an index, not a note
Reads Claude Code's notes from `~/.claude/projects/<cwd-slug>/memory/*.md`
(`ClaudeCodeMemoryReader`).

Each note is one Markdown file with a short header (name, description,
type). `MEMORY.md` is the folder's index of those files: it supplies titles
and is not a note itself. Nothing else in a project folder is read except
the opening of one session file, for the folder's real path.

#### Read 256 KiB of a session file to find its working directory
`SESSION_PEEK_BYTES`: How much of a session file is read to find its working directory.

#### Visible entries sorted by name; links are not regular files
`listed`: A folder's visible entries, sorted by name, with whether each is a regular
file (a link is not).

#### Leading block as flat fields; file without block is all body
`front_matter`: The leading `---` block as flat fields (`name`, `metadata.type`), and the
text after it. A file without the block is all body.

#### Titles come from MEMORY.md index lines linking file names
`index_titles`: File name to title, from index lines such as
`- [Release gotchas](release-gotchas.md) — per-release lessons`.

#### Folder name loses separators; read real path from sessions and verify slug
`working_directory`: The folder a project's sessions ran in. The project folder's name is that
path with its separators lost, so the path is read from the newest session
files and kept only if it produces the same name.

### `LinuxWindows/crates/lokalbot-engine/src/agent_notes/codex.rs`

#### Codex memory files map to notes; raw_memories.md, skills, extensions not read
Reads Codex's memories from `~/.codex/memories` (`CodexMemoryReader`).

- `MEMORY.md`: one note per top-level heading (a task group).
- `memory_summary.md`: one note per section.
- `rollout_summaries/*.md`: one note per session summary.

`raw_memories.md` repeats the session summaries and is not read. The
`skills` and `extensions` folders hold procedures and tools, not notes.

#### Duplicate headings get a numeric suffix so ids stay distinct
`anchor`: A second section with the same heading gets `#2`, so ids stay distinct.

#### Task group scope is summary; folder comes from applies_to cwd
`task_groups`: `MEMORY.md`: each `# Task Group: …` with its `scope:` line as the summary
and the folder from `applies_to: cwd=…`.

#### Headings by folder path make notes about that folder
`summary_sections`: `memory_summary.md`: one note per `##` or `###` section. A section headed
by a folder path is about that folder.

#### Header key-value lines, blank line, then summary under title
`rollout_summary`: A session summary: `key: value` header lines (`cwd`, `updated_at`), a blank
line, then the summary under its `#` title.

#### Folder is extracted from the cwd field of applies_to
`cwd`: The folder in `cwd=/path; reuse_rule=…`.

### `LinuxWindows/crates/lokalbot-engine/src/agent_notes/exclusions.rs`

#### Notes about folders inside an excluded folder never leave the reader
The person's project-folder exclusions, applied to notes
(`AgentMemoryExclusions`). A note about a folder inside an excluded one
never leaves the reader.

#### Standardized absolute folder paths with slash separators
`Exclusions.folders`: Standardized absolute folder paths, with `/` separators.

#### Slug loses separators, so sibling like app-old is excluded too, the safe direction
`Exclusions.excludes_claude_project`: Claude Code names a project folder after its working directory with
every character that is not an ASCII letter or digit turned into "-".
That loses which dashes were separators, so a sibling such as `app-old`
reads as inside `app` and is left out too: the safe direction.

#### Windows paths are case-insensitive and drive letter written either way
`Exclusions.excludes_claude_project`: Windows paths don't care about case, and a drive letter is
written either way.

#### Windows folder is written with either separator in any case
`Exclusions.mentions_excluded_folder`: A Windows folder is written with either separator, in any case.

#### Match folder or inside it, not same-prefix siblings like app-old
`mentions`: `folder` occurs in `text` as the folder itself or something inside it, not
as a sibling whose name merely starts the same (`app-old`, `app.bak`).

#### Windows paths give same slug with either separator
`claude_project_slug`: The name Claude Code gives a working directory's project folder. A Windows
path gives the same name with either separator: `C:\Code\app` and
`C:/Code/app` are both `C--Code-app`.

### `LinuxWindows/crates/lokalbot-engine/src/agent_notes/mod.rs`

#### Agent notes read only when enabled, search source only, instruction files never read
Keeps the saved coding-agent notes in step with the agents' files
(`AgentMemoryReaders.swift`, `AgentMemoryIngestor`).

Coding agents keep notes for their own later sessions. While **Read coding
agent notes** is on, the readers here collect Claude Code's notes
(`~/.claude/projects/*/memory/*.md`) and Codex's memories
(`~/.codex/memories`), and `lokalbot_core::agent_notes::store` makes
`agent-notes.sqlite` in the library match what they found. Instruction
files such as `CLAUDE.md` and `AGENTS.md` are never read.

Scans run on a background thread, one at a time. Nothing under the agents'
folders is opened until the person turns the feature on, and turning it off
deletes what was saved. The notes are a search source only: nothing here
feeds the day digest, the overnight review or Personal Context.

#### First notes read waits only for app start, files are small
`FIRST_REFRESH_DELAY`: Notes are small files, so the first read only waits for the app to start.

#### Folder exclusions apply before a note leaves its reader
`scan`: Notes from every agent in `agents`, newest first, with the person's folder
exclusions applied before a note leaves its reader.

#### No agents selected means nothing read and nothing kept
`Configuration`: What a scan reads. No agents means nothing is read and nothing is kept.

#### Counts follow CodingAgentKind::ALL order, agents with none omitted
`AgentNotesStatus.counts`: Saved notes per agent, in `CodingAgentKind::ALL` order; agents with
none are left out.

#### One scan or deletion at a time so toggling cannot delete fresh notes
`Ingestor`: The refresh state: one scan or deletion runs at a time, so turning the
setting off and on again cannot delete what the new read just saved.

#### Refresh reads notes or deletes saved copy while off, returns whether changed
`Ingestor.refresh`: Reads the agents' notes now, or deletes the saved copy while the
feature is off. Returns whether the saved notes changed.

#### Feature-off check happens before any file opens: consent gate
`Ingestor.refresh_with`: Before anything opens a file: this is the consent gate.

#### Discard scan result if settings changed mid-read; the change triggers its own refresh
`Ingestor.refresh_with`: Turned off or narrowed while reading: its result must not be kept.
The settings change starts its own refresh, which waits for this one.

#### Retry deletion on Windows because a search briefly holds the file open
`Ingestor.remove_all`: On Windows a search holds the file open for a moment.

#### Notes read at launch and every ten minutes; setting changes read in between
`start`: Reads at launch and every ten minutes; a setting change reads in between.

### `LinuxWindows/crates/lokalbot-engine/src/agent_notes/tests.rs`

#### Tests mirror the Swift AgentMemoryReaderTests and AgentNotesTests
`AgentMemoryReaderTests.swift`, and the background reader's part of
`AgentNotesTests.swift`.

#### A session that moved elsewhere still names its start folder first
`claude::working_directory test`: A session that later moved elsewhere still names its start folder first.

#### Test file is written with Windows CRLF line endings
`codex_summary_sections_and_session_summaries`: Written on Windows, with its line endings.

#### An exclusion added during a read waits for the next read
`a_scan_that_outlives_its_setting_is_not_kept`: An exclusion added during the read waits for the next one.

### `LinuxWindows/crates/lokalbot-engine/src/agent_notes/text.rs`

#### Memory files over 4 MiB are treated as not written by a person
`MAX_FILE_BYTES`: A memory file larger than this is not a note someone wrote.

#### Per-agent note cap so a runaway folder cannot fill the library
`MAX_NOTES_PER_AGENT`: Per agent, so a runaway folder cannot fill the library.

#### Windows line endings folded so one set of rules splits lines
`contents`: A file's text with Windows line endings folded, so one set of rules splits
lines wherever the agent wrote them.

#### Body is redacted, trimmed, capped at a line end, Markdown layout kept
`body`: Credentials redacted, line endings folded, edges trimmed, capped at a line
end. Markdown layout is kept so a quoted passage reads as written.

#### Text before first heading gets level 0; headings in fenced code are text
`sections`: Splits Markdown at headings of the given levels. Text before the first such
heading comes back with level 0 and an empty heading. Headings inside
fenced code are text.

### `LinuxWindows/crates/lokalbot-engine/src/ask.rs`

#### Follow-up outline is written only by a model running on this PC
`AskWorker.write_follow_up`: Rewrites a meeting's follow-up outline with Think. Like macOS, only a
model running on this PC may write it; the outline stays available.

#### Question saved as sent so failures leave a retryable error turn
`run_question`: `ChatViewModel.sendResolved` and `run`. The question is saved as it is sent,
so a failed or stopped answer leaves it in the conversation with an error
turn to retry; `Err` means nothing could be saved at all. `model` answers from
the turns allowed to reach it.

#### Remember statements are saved locally without a model, unless a screen is attached
`run_question`: "Remember …" is saved locally, without a model call or a model. With an
attached screen it stays a question about that screen.

#### Only complete pairs within the question's boundary reach the model
`run_question`: Only complete pairs asked within this question's boundary reach the model.

#### A conversation deleted during answering stays deleted
`run_question`: Deleted while it was being answered: it stays deleted.

#### Partial answers before Stop are not kept so they do not read as finished
`STOPPED_TURN`: What a stopped turn says (`finalizeInterruptedTurn`). What arrived before
Stop isn't kept: an answer cut short shouldn't read as a finished one.

#### Refusals keep their reason because only the person can change them
`friendly_failure`: `ChatViewModel.friendlyFailureMessage`. A refusal keeps its reason: only the
person can change what's refused, and it holds nothing from the library.

#### Files are included only when enabled with a folder, which offers search_files
`ask_model`: Files only while it's on with a folder: then `search_files` is offered.

#### Agent notes are included only while read and saved, which offers search_agent_notes
`ask_model`: Agent notes only while they are being read and some are saved: then
`search_agent_notes` is offered.

#### CPU-only or small-window models answer in one retrieve-first turn, avoiding per-tool model calls
`ask_model`: Each tool call is a model call: a CPU-only or small-window model
answers in one retrieve-first turn instead.

#### Unnamed boundary defaults to enabled sources so nothing reads as everything
`question_scope`: The boundary to save with a question. A caller that named none gets the
sources it enabled and the ids it bound, so nothing reads as "everything".

#### A failed save keeps the answer on screen for this run
`save`: A failed save keeps the answer on screen for this run instead of losing it;
Ask says it isn't saved.

#### Scoped questions get no distilled memory that would carry content past their boundary
`is_unscoped`: A question limited to some sources or days doesn't get what was distilled from
everything: work memory and learned items would carry content past its
boundary. The person's own statements carry no source, so they still apply.
Leaving out agent notes limits nothing while none are being read, so
questions asked before that source existed stay as they were.

#### File moments are heard through the person's transcription model
`moment_words`: The assistant hears a file's moment through the person's transcription model.

#### Attached screen context is primary evidence while the chat shows only the question
`attached_screen_context`: Screen context the person attached, as primary evidence for the model, while
the conversation shows only their question (`ScreenAskContext.prompt`).

#### The question is on disk before the model hears it
`Fixture.ask`: The question is on disk before the model hears it.

#### Narrower questions never hear earlier wider answers; turns keep their boundary
`a_narrower_question_doesnt_hear_earlier_wider_answers`: The model never hears an earlier, wider answer in a narrower question, and
each turn keeps the boundary it was asked within.

#### A retried failed turn is excluded from history and not doubled
`a_failed_answer_stays_in_the_conversation_and_retrying_replaces_it`: Not part of what the model hears next, and asked again without doubling.

#### The Mac reads the stopped-turn text to show a stopped turn
`a_failed_answer_keeps_its_question_and_scope_and_says_what_to_do`: The Mac reads this text to show a stopped turn.

#### A refusal keeps its reason so the person can act on it
`failures_read_as_the_mac_words_them`: A refusal keeps its reason, so the person can act on it.

#### Questions from before agent notes existed count as unscoped
`restricted_questions_are_told_apart`: A question from before agent notes existed names every other source.

### `LinuxWindows/crates/lokalbot-engine/src/autocomplete_measure.rs`

#### Measurements infer typing from field reads, approximate; mirrors Swift, counts and timings only
Local measurements of how autocomplete behaves while typing in other apps
(`CotypingCoordinator+Measurement.swift`). Counts and timings only.

The Mac watches keys. Nothing here taps the keyboard, so typing is worked
out from reads of the field: what was added since the last read, less
anything an accept typed. Reads can coalesce keys, so these counts and the
gaps between keys are approximate; the UI words them that way.

#### A deletion within 5 s of an accept counts as correcting it
`CORRECTION_WINDOW`: A deletion this soon after an accept counts as correcting it.

#### Waits over 10 s are restored suggestions, not typing latency
`MAX_MEASURED_VISIBLE`: Longer waits are a suggestion restored later, not typing latency.

#### Once the field shows the accept, a deletion takes it back
`AcceptAwaiting.shown`: The field has shown the accept, so a deletion now takes it back.

#### Text typed by accepts not yet read back is not user typing
`Measures.pending_inserted`: Text accepts typed that no read has shown yet: not the user's typing.

#### counts is false in LokalBot's own practice editor
`Measures.note_read`: A newer read of the same field, as (before, after) the caret. `counts`
is false in LokalBot's own practice editor.

#### Text an accept typed is stripped from user typing
`Measures.note_read`: What an accept typed is not the user's typing.

#### The first key after an accept shows it was kept
`Measures.note_read`: The first key after an accept shows it was kept.

#### Deletion or caret move means an unread accept can no longer be read back
`Measures.note_read`: A key that takes text back or moves the caret changes what is before
the caret, so an accept still unread can no longer be read back.

#### Browsers publish a trailing space as a non-breaking space
`Measures.strip_inserted`: Browsers publish a trailing space as a non-breaking space.

#### A partly shown accept is still arriving, not taken back
`Measures.note_deletion`: A partly shown accept is still arriving, not being taken back.

#### Without a shown suggestion nothing is marked used
`Measures.note_accept`: Without a shown suggestion nothing is marked used.

#### An unshown previous accept is checked together with the new one
`Measures.note_accept`: The app has not shown the previous accept yet: check both together.

#### An accept not read back by focus loss never will be
`Measures.note_left_field`: Focus left the field: an accept not read back by now never will be.

#### An app ignoring an insertion publishes nothing, so unread accepts time out
`Measures.check_due`: When an unread accept stops being waited for. An app that ignores an
insertion publishes nothing, and typing may stop there.

#### Usage history is written only when it changed
`Measures.take_unsaved`: What to write now: the counters, and the usage history only when it
changed. `None` when nothing did.

#### A second accept from the same suggestion is not a second use
`an_accept_is_not_typing_and_arrives_confirmed`: A second accept from the same suggestion is not a second use.

### `LinuxWindows/crates/lokalbot-engine/src/autocomplete_window_text.rs`

#### Window text is captured per window, OCR on device, image dropped, never downloads, logs counts only
Reading the focused window for autocomplete (`CotypingWindowTextCapture`):
captures only that window, recognizes its text with the on-device OCR
engine, and drops the image at once. Never downloads: without an engine
there is no window text. An image unchanged outside the field reuses the
last lines. Logs carry counts and times only, never text.

#### Captured window longest side is 3000 px as on macOS
`MAXIMUM_DIMENSION`: The longest side of a captured window, as on macOS.

#### Lines outside the field are cached with the source image fingerprint
`WindowReader.recognized`: The last lines read for the field in use, outside the field, with the
fingerprint of the image they came from.

#### Returns None when nothing can read or the front window is not the asked one
`WindowReader.read`: `None` when nothing here can read, or the window in front is not the one
asked about.

#### The draft in the field is never prompt context so it is not cached
`WindowReader.read`: The draft is never prompt context, so it is not kept either.

### `LinuxWindows/crates/lokalbot-engine/src/calendar.rs`

#### Calendar cache refresh intervals and window; detection never waits on network
The user's calendars, kept fresh in the background
(`EventKitCalendarEventProvider` on macOS).

Detection and recording read the cached events and never wait on the
network: a refresh thread reads Evolution every minute and private links
every five minutes, from yesterday to a week ahead (so the detector's
−15/+90 minute window works across midnight, Today sees the whole day and
People sees who is coming up in the next seven days). Nothing is read while
calendar detection is off.

#### Recordable meetings from yesterday to a week ahead, sorted by start
`CalendarSnapshot.events`: Recordable meetings from yesterday to a week ahead, by start.

#### One line per unreadable source with links redacted
`CalendarSnapshot.problems`: One line per source that could not be read (links redacted).

#### NoSources means on with no saved link and no usable Evolution
`CalendarStatus::NoSources`: On, but no link is saved and Evolution is not used or not installed.

#### Links cache is None until first read from the credential store
`Calendar.links`: Links from the credential store; `None` until first read.

#### Reload rereads links from credential store then every source
`Calendar.reload`: Reads the links from the credential store again, then every source
(Refresh in Settings, or calendar use turned back on).

#### Links go to the credential store first, then refresh
`Calendar.set_links`: Replaces the saved links (credential store first) and refreshes.

#### Failed link reads are not retried every minute because a locked store would prompt each time
`Calendar.links`: Not retried every minute: a locked store would ask each time.

#### Calendar window is yesterday to a week ahead matching People's seven-day Coming up
`window`: Yesterday 00:00 to the end of the day a week from today, local time:
People's "Coming up" reads the next seven days
(`PeopleUpcomingMeetings.windowDays`).

### `LinuxWindows/crates/lokalbot-engine/src/capture_health.rs`

#### Live capture warnings shown in the meeting; saved health report drives later page warnings
Live capture warnings and `recording-health.json`
(`RecordingController.updateCaptureWarnings`). The meeting view shows every
warning as it happens; the saved report is what its page warns from later.

#### Checks run at most once a second and report only changes
`CaptureMonitor.tick`: At most once a second: what to show and notify, when that changed.

#### Microphone warning is dropped when recording went on from system audio alone
`CaptureMonitor.tick`: The recording went on from system audio alone.

#### Report saved on change or every interval; failed save retries next check
`CaptureMonitor.save_when_due`: Saves the report when it changed, and otherwise every `REPORT_INTERVAL`
since the last save. False when a due save failed; the next check
tries again.

#### Per-second checks once moved last-saved time so the interval never passed
`an_unchanged_report_is_saved_again_every_interval`: Checks run once a second. They used to move the last-saved time
forward each time, so the interval never passed.

### `LinuxWindows/crates/lokalbot-engine/src/daymemory.rs`

#### Samples focused app and window every five seconds into contiguous activity blocks
Day memory: samples the focused app and window every five seconds and
stores contiguous stretches as activity blocks (`ActivityTracker.swift`).

#### 180 seconds of inactivity closes the current block
`IDLE_SECONDS`: Inactivity that closes the current block.

#### Blocks shorter than five seconds are never stored
`MIN_BLOCK_SECONDS`: Blocks shorter than this are never stored.

#### on_boundary runs at new block start; screen context captures there
`DayMemory.start`: `on_boundary(app_changed)` runs when a new activity block begins
(`ActivitySampler.onActivityBoundary`); screen context captures there.

#### Browser meeting detection needs window titles for Google Meet tabs
`run`: Browser meeting detection needs window titles (Google Meet tabs).

### `LinuxWindows/crates/lokalbot-engine/src/detector.rs`

#### Calendar event backs the call, titles it, and splits back-to-back recordings
Meeting detection and the recording mode it follows (`MeetingDetector.swift`):
record automatically, ask through a notification, or never auto-record.

With calendar detection on, the active calendar event backs the call
([`CalendarHint`]), titles the recording, and splits a recording the
detector started when back-to-back events hand over within one call.

#### A new call from another app replaces the old, which ended first
`run`: Another app's call took over; the old one ended first.

#### Back-to-back events split detector recording; if user stopped, next auto-records
`hand_over`: Back-to-back events within one call: the recording the detector started
splits; with nothing recording (the user stopped the previous event), the
next event records in automatic mode.

#### Title precedence: calendar title, Meet tab name, then App meeting
`title`: The calendar title when titling is on, else the Meet tab's meeting name,
else "\<App> meeting".

### `LinuxWindows/crates/lokalbot-engine/src/diagnostics.rs`

#### Diagnostics zip never reads meetings, screenshots or screen text
Export Diagnostics (`DiagnosticsExporter.swift`,
`DiagnosticsSettingsSanitizer.swift`): recent logs, health reports, settings
without secrets, library row counts and capture traces in one zip the person
saves themselves. It never reads the meetings folder, screenshots or screen
text, so meeting audio, transcripts, notes and screen content can't end up in
the archive.

#### Keys sorted at every depth to match Mac sortedKeys output
`sorted`: Sorted keys at every depth, as the Mac's `.sortedKeys` writes them.

#### Deny-list removes credential keys and reduces URLs to host and path
`sanitized_settings`: Settings without any key that names a credential, and with URLs reduced to
their host and path. A deny-list, as on the Mac.

#### Only row counts, never row contents
`library_counts`: Row counts only; never row contents.

#### Archive written beside destination then swapped in; folder is an error
`export`: Writes the archive beside `destination`, then swaps it in: an earlier archive
is replaced only once the new one exists. A folder is an error.

### `LinuxWindows/crates/lokalbot-engine/src/dictation_context.rs`

#### Compose context from window, text above field, saved facts; separate grants, nothing saved
Where a Compose writing request gets its context
(`DictationScreenContextCapture`, `DictationVisibleContextCapture`,
`DictationGrounding`): the focused window, the text above the field, and
saved facts. Each has its own grant, and nothing read here is saved.

#### Compose waits up to 20 s for capture begun during recording
`SCREEN_WAIT`: How long Compose waits for a capture that began during recording.

#### App and field with focus at press, when context may be read
`ContextTarget`: The app and field that owned focus at the press, when context may be read
from it (`DictationScreenPrivacy.allowsCapture`).

#### Context keyed to exact window; process too broad, document switch invalidates
`ScreenIdentity`: The exact window a context belongs to. A process is too broad: switching
documents in one app must invalidate the captured title and address.

#### Pasted-into window read once, in memory, only with Learn from dictation on
`LearningSurface`: The window a dictation was pasted into, read once, only while Learn from my
dictation is on. Held in memory to decide whether to keep the words.

#### Only text into identifiable fields kept; password or blocked fields keep nothing
`ContextTarget.of_learning`: The target and what its window shows. Only text pasted into a field it could
identify is kept; a password field or a blocked field keeps nothing.

#### Same exclusions as nearby text; unreadable browser address keeps nothing
`learning_permits`: `DictationLearningPolicy.permits`: the same app, website and private-window
exclusions as nearby text. A browser whose page address can't be read can't be
checked against the website exclusions, so its dictation isn't kept.

#### Never prompt from a shortcut; portal-needing desktops get metadata only; nothing written to disk
`capture_screen`: Reads the focused window for one request: its title and address always,
its accessible text when it shares enough, otherwise on-device OCR when
installed. The portal can prompt, and a shortcut must never prompt, so a
desktop that needs it gets metadata only. Returns `None` rather than any
other window; nothing here is written to disk.

#### Window context comes from capture begun during recording; rest read at Compose
`LiveProviders`: The focused window's context arrives from a capture that began during
recording; the rest is read when Compose asks.

#### Window title joins memory query only when a window grant allows it
`LiveProviders.memory`: A spoken writing request, not typed shell or code input. The title
joins the query only when a window grant allows it.

#### Source edits and deletion invalidate facts; lookup must find the same ones
`LiveProviders.memory_is_current`: Source edits and deletion invalidate the facts: looking up again must
find the same ones.

### `LinuxWindows/crates/lokalbot-engine/src/digest.rs`

#### Past days finalized once after date change, up to seven back; journal rewrite is marker
The day digest: written automatically after `dayDigestHour`, or on request
(`DayDigestScheduler.swift`). Past days are finalized once after the local date
changes, oldest first and at most seven days back: rewriting a journal after
its day ended is a durable marker, so late work after the evening preview is
included, and a past day's new digest reopens that day's overnight review.

#### Degraded past day backs off alone so later days still run
`digest scheduler repair_after`: A degraded past day backs off alone, so later days still run.

#### Days before yesterday proven final are not reread each tick
`digest scheduler settled`: Days before yesterday proven final, so ticks don't re-read them.

#### Busy checks are not downtime; do not burn the failure backoff
`digest scheduler tick`: Not downtime yet: don't burn the backoff.

#### Degraded journal stays readable and is quietly repaired later
`Outcome.NeedsRepair`: A degraded journal stays readable and is quietly repaired later.

#### Edited journal is the person's, never replaced; degraded not final; changed source reopens
`past_day`: `automaticCompletionAt` and the day's evidence, for `needs_finalization`. An
edited journal is the person's, so it is never replaced; a degraded one isn't
final; a changed source reopens the day when its signature no longer matches.

#### Deleted last meeting still leaves an owned journal to repair
`past_day`: A deleted last meeting still leaves an owned journal to repair.

#### Refresh coding-agent sessions first so settled ones join the digest
`generate`: Sessions that settled since the last refresh belong in this digest.

#### Export may have run while the replacement digest awaited a model
`generate`: Export may have run while the replacement digest was awaiting a model.

### `LinuxWindows/crates/lokalbot-engine/src/dreaming.rs`

#### Overnight review: report is durable marker; quiet, on mains, no downloads, 7 days
The overnight review's schedule (`DreamScheduler`, `AppState.applyDreamingSetting`):
a minute tick, correct across sleep and clock changes. The durable marker is
the report itself, so a night the computer slept through is caught up at the
next launch or wake. A review waits until LokalBot is quiet and the computer is
on mains power, never starts a model download, and never reaches further back
than seven days or the start of this enabled period.

#### Failed review is visible but retried only after 15 minutes
`FAILURE_BACKOFF`: A failed review is visible but not retried every minute.

#### Eligible days through this one have reports, so ticks skip looking
`State.complete_through`: Every eligible day through this one has a report, so ticks needn't look.

#### Bumped to abandon a run; its results are thrown away
`Dreams.generation`: Bumped to abandon a run: what it finishes with is thrown away.

#### Review now ignores schedule, hour, existing report and idle gate; one at a time
`Dreams.review_now`: "Review now": ignores whether reviews are scheduled, the hour, an existing
report and the idle gate. Still one at a time.

#### Running review checks its sources at commit; only active day change stops it
`Dreams.reconsider`: A report changed behind the marker (`reconsiderReports`). A run in flight is
checked against its own sources when it commits, so only a change to the
day it is reviewing stops it early.

#### Malformed boundary narrows to yesterday; valid future boundary waits
`oldest_missing_target`: The oldest day without a report, from the enabled period's start through
yesterday, looking back at most seven days. A malformed boundary is narrowed to
yesterday; a valid future one waits (`oldestMissingTarget`).

#### Never competes with recording, processing, dictation or autocomplete; no battery, no downloads
`can_run`: The downtime gate. Never competes with recording, processing, dictation or an
autocomplete request, never drains the battery, and never starts a download.

#### Gate failure is not downtime; do not burn backoff, wait for quieter tick
`tick`: Not downtime yet: don't burn the backoff, wait for a quieter tick.

#### Deferred review retries after usual backoff and is not shown as an error
`run`: Retried after the usual backoff; not surfaced as an error.

#### Best-effort up to three learned items; failure never affects the review
`learn_about_person`: After the review: up to three facts, goals or suggested preferences from the
person's own words that day. Best effort; a failure never affects the review
(`AppState.learnAboutPerson`).

#### Day rebuilds on source change; rereading same lines only rewords items
`learn_about_person`: The review rebuilds a day whenever one of its sources changes. Reading
the same lines again would only reword the same items.

#### Local embedder checks translated items; without it they are dropped
`learn_about_person`: The local embedder checks items the model translated; without semantic
search, or with its model not downloaded, those are dropped.

#### Day's dictation read once then removed, never kept past its pass
`learn_about_person`: Read once, then gone: the day's dictation is never kept past its pass.

#### Stale summaries always removed; new ones written only with full screen history access
`roll_up_reviews`: After the review: the one-line week and month summaries the agent briefing
shows below recent days. Stale lines are always removed; new ones cost a model
call, so they are written only while agents may read all retained screen
history, which the briefing's older timeline needs (`rollUpReviews`).

#### App moves period start to today so prior week is not reviewed back in
`clear_work_memory`: Clear work memory: stops a run in progress and deletes every report and the
memory. The app moves the enabled period's start to today, so the week before
isn't reviewed straight back into memory.

#### Past day digest change withdraws that day's review; today's digest ignored
`digest_changed`: A day digest for a past day changed, so that day's review goes
(`dayDigestDidChange`). Today's digest changes all day and no report reads it.

#### CLI --dream reviews one day, ignoring hour, idle and power gates
`review_once`: `lokalbot --dream [yyyy-MM-dd]`: reviews one day and returns, past the hour,
idle and power gates like Review now. The person asked.

#### First tick waits too so launch recovery can claim the queue
`start`: The first tick waits too, so launch recovery can claim the queue.

### `LinuxWindows/crates/lokalbot-engine/src/exports/daily.rs`

#### Daily note is deterministic; a hash sidecar prevents overwriting person's edits
The optional daily Markdown note (`DailyMemoryExportService.swift`): one
deterministic file per day with the digest, meeting links, app time and saved
moments. A hidden sidecar records the hash of the exact bytes LokalBot wrote,
so a person's edit is never overwritten.

#### Catch-up writes a missed day only if no file exists and data was recorded
`Pass::CatchUp`: A past day the export missed, because the computer was asleep or off at
the export hour. Written only if the folder has no file for that day and
something was recorded.

#### An out-of-date digest is left out until the digest is updated
`Snapshot.digest_is_out_of_date`: A digest exists but no longer matches the day's evidence, so it is left
out until the digest is updated.

#### The sample meeting never becomes part of the day
`snapshot`: The sample meeting is made up: it never becomes part of the day.

#### Identical content keeps its mtime; changed app-owned content is replaced atomically
`export`: Rewrites one deterministic day file. Identical content keeps its modified
time; changed app-owned content is replaced atomically.

#### Daily note keeps a value's own spacing, unlike meeting notes
`inline`: Unlike a meeting note's, this keeps a value's own spacing.

### `LinuxWindows/crates/lokalbot-engine/src/exports/meeting_notes.rs`

#### Note names are stable; edited, deleted or moved notes are never rewritten
Optional one-note-per-meeting export to a folder the person picks, such as an
Obsidian vault or a Logseq graph's `pages` folder (`MeetingNoteExportService`):
the summary with the action list as LokalBot shows it, people and tracked
projects as links, and optionally the transcript.

A note is named when it is first written and keeps that name, so links to it
from other notes survive a renamed meeting. It is refreshed only while it
still holds the bytes LokalBot wrote. A note the person edited, deleted or
moved is theirs: LokalBot leaves it alone and does not write that meeting
again. Deleting a meeting in LokalBot leaves its note in place.

#### Bump RENDER_VERSION to refresh all notes after a look change
`RENDER_VERSION`: Part of every fingerprint: changing how notes look refreshes them all.

#### Per-meeting source fingerprints let the next pass render only changed notes
`Report`: What one pass did. Fingerprints are of each meeting's sources, so the next
pass renders only the meetings whose notes could have changed.

#### Left means edited, deleted, moved, or name held by a foreign file
`Outcome::Left`: Edited, deleted or moved by the person, or a file LokalBot did not write
holds the name.

#### Fingerprint is SHA-256 over length-prefixed fields, matching the Swift ContentFingerprint
`fingerprint`: `ContentFingerprint.fields`: SHA-256 over `<byte length>:<bytes>` per field.

#### Meetings with unchanged fingerprint are skipped without being read
`export`: Writes or refreshes the note of every finished meeting with a summary, or a
transcript when transcripts are included. A meeting whose fingerprint matches
`previous` is skipped without being read.

#### The sample meeting never lands in the person's notes
`export`: The sample meeting is made up, so it never lands in the person's notes.

#### Stamp sources before reading so later file changes change the next stamp
`export`: Sources are stamped before anything is read from them: a file that changes
after its stamp is taken changes the next pass's stamp too.

#### Action list matches the app: grouped like summary.md, corrections and completions applied
`action_lines`: The action list as LokalBot shows it, grouped like `summary.md`, with the
person's corrections applied and completed actions checked off.

#### Note name has date, title and short meeting id so renames stay findable
`file_name`: "2026-09-29 Atlas release sync (4f7c2a91).md": the date sorts notes, the title
reads well in a vault, and the meeting's short id finds the note again after
the meeting is renamed.

#### Stamp is names, sizes and mtimes; edits to artifacts each rewrite one
`source_stamp`: Names, sizes and modification dates of the files in a meeting folder.
Processing, a correction, a completed action and a renamed speaker or meeting
each rewrite one of them.

#### A note missing while its ownership sidecar remains means the person removed it
`NoteIndex`: The export folder's notes by meeting short id, and the meetings whose note is
gone while its ownership sidecar remains: the person deleted the note or moved
it elsewhere in the vault.

#### With two notes for one meeting keep the one LokalBot wrote
`(scan)`: Two notes for one meeting: keep to the one LokalBot wrote.

#### People and projects joined with the same rules as the app pages, once per pass
`Connections`: People and tracked projects per meeting, joined with the same rules as the
People and Projects pages, once per pass.

#### Key changes when a project is tracked, renamed or dropped, relinking all notes
`Connections.projects_key`: Changes when a project is tracked, renamed or dropped, so every note's
project links are looked at again.

#### Transcript lines count only the spoken words, not timestamp and name
`transcript_words`: `**[HH:MM:SS] Name:** text` lines count only for what was said.

### `LinuxWindows/crates/lokalbot-engine/src/exports/mod.rs`

#### Exports tick each minute, survive sleep and DST, wait 15 minutes after failure
Runs the optional exports (`MeetingNoteExportScheduler`,
`DailyMemoryExportScheduler`). Each has a one-minute tick, stays correct
across sleep and daylight-saving changes, and waits fifteen minutes after a
failed write so a removable or network volume has time to return.

#### Catch-up covers yesterday plus six days before, same as the digest
`CATCH_UP_DAYS`: Yesterday plus the six days before it, as for the digest.

#### Changing folder, format or transcript choice re-exports every meeting
`NoteConfiguration.destination`: Folder, format and transcript choice. Changing any of them exports every
meeting again into the chosen folder.

#### People and Projects choice changes trigger relinking of notes
`NoteState.curation_stamp`: When People and Projects choices last changed: names notes link to.

#### Changing folder or format exports again even if today's already succeeded
`DailyConfiguration.folder`: Changing the folder or format exports to the new destination even when
today's prior destination already succeeded.

#### Order: reopened days, unchecked past days oldest first, then today at its hour
`next_daily_export`: Reopened past days first, then past days not yet checked for a missing note
(oldest first), then today once its hour arrives.

#### Only the current day reopens after a correction; history stays unchanged
`Exports::reconsider_daily`: An action correction or late meeting artifact can change today's export
after its scheduled run. Only the affected current day reopens; historical
exports stay as they are.

#### Rewrite past notes with finished digest only while the day is fully retained
`Exports::digest_did_change`: A digest finished or rebuilt after its note was written. Today's note
refreshes as for any evidence change; a past day's note within the
catch-up window is rewritten with the finished digest, while all of that
day is still retained: a digest rebuilt from what retention left would
replace a fuller note.

#### Write notes only while processing is idle to avoid half-finished rewrites
`note_tick`: Notes are written while processing is idle, so a meeting's note is
not written half-finished and rewritten moments later.

#### A folder changed mid-pass restarts on the next tick with the new one
`note_tick`: A folder changed mid-pass: the next tick starts over with the new one.

#### A failed write is visible but not retried every minute
`daily_tick`: A failed filesystem write is visible but not retried every minute.

#### Retry wait applies to failures only; next export runs immediately
`daily_tick`: The retry wait is for failures; the next export runs now.

#### A past day is tried once per session and never reported or blocks today
`daily_tick`: A past day is tried once per session, so a note that can't be
written never holds back today's. A past day's file is the
person's: their own note in that folder, or one they edited. It
stays as it is, so there is nothing to report.

### `LinuxWindows/crates/lokalbot-engine/src/health_check.rs`

#### Released builds check only on request; dev builds check daily
Runs the library health check (`AppState.runHealthCheckNow`,
`LibraryHealthScheduler`). Released builds check only on request; development
builds check the previous day each morning and catch up at launch when the
last run is over a day old.

#### Scheduled checks are development builds only per PRIVACY.md
`health_check::start`: Development builds only: PRIVACY.md promises released builds check on request.

### `LinuxWindows/crates/lokalbot-engine/src/indexing.rs`

#### Startup reindex: keyword index first, then meaning vectors
Brings search up to date at startup, for meetings this app did not just
process: the keyword index first, then meaning-search vectors for meetings
without current ones (`SemanticIndexer` on macOS).

#### Runtime availability is checked once per launch after any update finishes
`indexing::start`: This looks for the runtime once per launch.

#### Embedding waits until nothing is capturing audio
`indexing::start`: Embedding is heavy; wait until nothing is capturing audio.

### `LinuxWindows/crates/lokalbot-engine/src/lib.rs`

#### Heavy work waits while a meeting or dictation captures audio
`Shared.capture_active`: True while a meeting or dictation is capturing audio; heavy work waits.

#### Screen captures link to the meeting being recorded
`Shared.recording_meeting`: The meeting being recorded, which screen captures are linked to.

#### A recording may not start over a dictation in progress
`Shared.dictation_state`: Where the dictation in progress is, which a recording may not start over.

#### A recording started during a detected call carries its calendar event
`Shared.detected_call`: The app of the call the detector is following, if any, so a recording
the user starts during it carries the calendar event too.

#### Holds whose sound to record and the room when known
`Shared.detected_meeting`: That call in full: whose sound to record, and its room when known.

#### Meeting notes wait while the processing queue has work
`Shared.pipeline_busy`: The processing queue has work, so meeting notes wait for it to finish.

#### Recording start or stop makes Files and screen vectors wait or resume
`Shared::background_conditions_changed`: A recording started or stopped: Files and picture vectors wait or go on.

#### One route for source changes keeps exports, routines and digests consistent
`Shared::evidence_changed`: One route for every source change, so exports, routines and reused digest
answers can't diverge from what changed (`primaryEvidenceDidChange`).

#### Deleted or corrected evidence must not survive in reused digest answers
`Shared::evidence_changed`: Deleted or corrected evidence must not survive in reused answers.

#### Learned items are retracted with the source they came from
`Shared::evidence_changed`: Learned items go with the source they came from.

#### None when semantic search is off or model missing; never downloads
`query_vector`: A search's words as a vector, on the small text embedder: `None` while search
by meaning is off or its model isn't downloaded. Never downloads anything.

#### on_event is called from engine threads and must be cheap
`Engine::start`: Starts every background service. `on_event` is called from engine
threads; it must be cheap (forward into a channel).

#### Library write observer holds a weak handle since it can outlive the engine
`Engine::start`: Library writes anywhere in this process report here. The observer can
outlive this engine, so it holds a weak handle.

#### Quit saves the recording; false means stay open so a later quit can retry
`Engine::prepare_for_quit`: Stops any recording and saves it, leaving its processing for the next
launch. Blocks until that is done, and false means something could not
be saved: stay open, as the macOS app does, so a later quit can retry.

#### Gives up after a wait when the app quits regardless; timeout answers false
`Engine::prepare_for_quit_within`: [`Self::prepare_for_quit`] that gives up after `wait`, when the app is
going regardless. An engine that took longer answers false.

#### Agent Mode leases the Think server so both share one process on port 17872
`Engine::runtime`: The llama.cpp runtime the engine's model roles share. Agent Mode leases
the Think server from it so both use one process on port 17872.

#### A refused start while recording began nothing, so the live transcript stays
`newly_recording`: The folder of the recording a start request began, given the recording
folder `before` and `after` it. A request refused because a recording was
already running began nothing, so that recording keeps its live transcript.

#### Autocomplete commands carry typed text and are never logged
`dispatch`: Autocomplete's commands carry typed text, which is never logged.

#### A recording started during a detected call belongs to that call and event
`dispatch`: A recording the user starts during a detected call is for
that call and its calendar event (`recordingContext(for:)`).

#### Agent session reading starts on allow; new exclusions apply immediately
`dispatch`: Reading starts as soon as the person allows it, and a new
exclusion takes effect without waiting for the next refresh.

#### Agent notes are read, narrowed or deleted as soon as settings change
`dispatch`: Notes are read, narrowed or deleted as soon as their setting,
an agent switch or an exclusion changes.

#### Turning dictation learning off deletes all kept dictations; on drops expired
`dispatch`: Off deletes every kept dictation at once; on drops expired ones.

#### A refused Record press must not disturb the running recording's live transcript
`a_refused_start_is_not_a_new_recording`: Record pressed during a recording is refused, and the recording that
is running must keep its live transcript.

### `LinuxWindows/crates/lokalbot-engine/src/library_ops.rs`

#### Library changes run on a background task then queue ProcessMeeting; device uploads share import
Library changes people make from Meetings: importing recordings, merging
meetings and undoing a merge, and changing a meeting's boundaries
(`AppState.importRecordings`, `mergeMeetings`, `undoMerge`,
`setMeetingBoundaries`). The app runs them on a background task, then
queues processing with `Command::ProcessMeeting`. A recording a paired
device sends takes the same import from the companion host.

#### A device title is capped at 200 characters
`MAX_DEVICE_TITLE_CHARACTERS`: A device can send any title; a meeting keeps at most this much of one.

#### Folder title slug stays well within 255 bytes including day and counter
`MAX_DEVICE_FOLDER_BYTES`: Well inside the 255 bytes a folder name can have, day and counter included.

#### lokalbot-sync rejects a bad id before any audio is sent
`ImportFailure::localized`: `lokalbot-sync` refuses a bad id before any audio is sent.

#### Meeting appears only when complete: convert, move into reserved folder, meta.json last
`import_recording`: Makes `source` a meeting whose system track is the file's audio. The
meeting appears only once complete: the audio is converted beside the
library, moved into a reserved folder, and `meta.json` is written last.

#### Id becomes the meeting UUID so re-sending makes no second meeting
`DeviceRecording.id`: The UUID the meeting takes, so sending it again makes no second one.

#### started_at is ISO 8601 by the device's clock
`DeviceRecording.started_at`: ISO 8601, by the device's clock.

#### False when already present from an earlier attempt
`DeviceImport.is_new`: False when it was already here, from an earlier attempt.

#### Device audio is the person's microphone track, with no screen context
`import_device_recording`: Makes a meeting of a recording from a paired device, or returns the one that
already has its id, untouched. It is the device's microphone, the person's
own, so it becomes the microphone track: their speech counts as theirs, and
other voices in the room are treated as this computer's microphone treats
them, not as call participants. Like any import it takes no screen context,
because the person wasn't at this computer.

#### Sample meeting is dated now, titled in its language, marked so memory omits it
`import_sample`: Adds LokalBot's sample meeting through the same import, or returns the
one the library already has. It is dated now, titled in its own language
and marked with its id, so personal memory leaves it out.

#### The sample counts as recorded just now whatever its file says
`import_file`: The sample was "recorded" just now, whatever its file says.

#### The device upload's own file name is meaningless so it is replaced
`import_file`: The upload's own name means nothing to anyone.

#### Fit titles by slug bytes since a Hangul syllable takes nine bytes
`device_folder_title`: The start of a device's title whose slug fits a folder name. Characters
aren't enough to count: a Hangul syllable takes nine bytes in a slug.

#### Merged meeting is indexed for search and sources leave the index
`merge_meetings`: Merges `meetings` into a new one with WAV tracks. On success the
merged meeting is indexed for search; the sources leave it.

#### Sample starts minutes before now, which just after midnight is yesterday
`the_sample_imports_once_and_stays_out_of_personal_memory`: The own meeting's day: the sample starts minutes before now, which just
after midnight is yesterday.

#### Phone uploads are ADTS AAC; fixture is one second of 440 Hz
`ADTS_TONE`: The audio phones and tablets send: one second of a 440 Hz tone, as an
ADTS AAC stream.

#### Partial uploads keep lokalbot-sync's name format
`device_file`: A partial upload's name, as `lokalbot-sync` keeps it.

#### A retry with any title leaves the meeting untouched even with audio gone
`a_device_recording_arrives_once`: Whatever a retry says, and even with its audio gone.

#### A device name must not be interpreted as a template
`a_device_recording_without_a_title_says_where_it_came_from`: A device name can't be read as a template.

#### Phone clocks ahead, absent or nonsensical must not yield future end
`a_device_recording_never_ends_in_the_future`: A phone whose clock runs ahead, one that says nothing, and nonsense.

#### A macOS-recorded AAC track imports through the MP4 path
`imports_a_macos_aac_recording`: A macOS-recorded AAC track imports through the MP4 path.

### `LinuxWindows/crates/lokalbot-engine/src/live.rs`

#### Live preview is opt-in, 4-12 s chunks cut at quiet moments, no speakers
Live transcript preview while recording (`LiveMeetingTranscriber`,
`LiveTranscriptChunker`). It is opt-in: nothing loads or runs until the
user starts it. Each track is read in 4–12 s chunks cut at a quiet moment
and transcribed without speakers; the full transcript replaces it after
the meeting.

#### Generation bumps on start, pause and stop so stale workers drop work
`Inner.generation`: Bumped on every start, pause and stop; a worker from an older
generation drops whatever it was doing.

#### Cursors set by first start only so accepted chunks are not retranscribed
`State.initialized`: Cursors are set by the first start only; resume and retry keep them so
accepted chunks are never transcribed twice.

#### from_beginning applies only to the first start
`LiveTranscriber::start`: Starts, resumes or retries. `from_beginning` applies only to the first start.

#### Starts both tracks at the latest 12 s of the longer track
`recent_start`: The latest 12 seconds of the longer track, as one start for both tracks.

#### At the live edge wait for a pause unless 12 s have built up
`next_chunk`: At the live edge someone may still be mid-sentence: wait for a pause
rather than cut a sentence in two, unless 12 s have built up.

#### Chunks are at least 4 s and at most 12 s, matching the Mac chunker
`chunk_range`: `LiveTranscriptChunker.nextChunk`: at least 4 s available, at most 12 s.

#### A pause is the last 400 ms quiet relative to the chunk
`ends_quietly`: Whether the last 400 ms are a pause relative to the chunk.

#### Cut at the middle of the quietest 200 ms window to avoid mid-word
`refined_cut_offset`: `LiveTranscriptChunker.refinedCutOffset`: the middle of the quietest
200 ms window, so a chunk does not end mid-word.

#### Only silence and low-frequency drift are dropped; the VAD detects speech
`speech_candidate`: `LiveTranscriptChunker.speechCandidate`: drops silence and low-frequency
drift only; speech detection itself is left to the VAD.

### `LinuxWindows/crates/lokalbot-engine/src/model_checks.rs`

#### Checks confirm the path ran, not accuracy, using no personal content
Checks that a role's model responds, using sample content
(`ModelCheckController`). Checks confirm the path ran; they don't measure
accuracy. No meeting, screen or clipboard content is used.

#### Check audio is synthetic macOS say speech holding no personal audio
`SPOKEN_SAMPLE`: The first ten seconds of a synthetic recording made with macOS `say`
(`Resources/ModelChecks`). It holds no meeting or personal audio.

#### Identity covers only the exercised configuration so unrelated changes keep results
`identity`: Identifies just the configuration a role's check exercises, so unrelated
changes don't invalidate its result (`ModelCheckIdentity`).

#### A spoken-sample check passes if the answer contains any words
`has_words`: A check that found words only in a spoken sample's answer passes.

#### Cancel stops publishing; an already sent request runs out
`ModelChecks::cancel`: Stops publishing. A request already sent runs out on its own.

#### A result computed from outdated form values is discarded
`ModelChecks::check_connection`: The form changed while this ran, so the answer is about old values.

#### Autocomplete check uses fixed text and reads no field
`check_autocomplete`: `previewSuggestion(precedingText:sampleOnly:)`: fixed text, no field read.

### `LinuxWindows/crates/lokalbot-engine/src/models.rs`

#### Model ids are shared with the UI: catalog, speech, runtime, OCR
Which models are installed, and downloading the ones a feature needs.

Ids are shared with the UI: GGUF catalog ids (`qwen3.5-4b`), speech model
ids (`qwen3-asr-0.6b`), `llama-runtime` for the llama.cpp binaries, and
`ocrs-text` and `tesseract-languages` for screen text recognition.

#### A transcription server needs no download, only approval
`Models::transcription_ids`: A transcription server has nothing to download; it needs the approval
[`Self::transcription_server_blocked`] checks.

#### OCR requirement depends on this computer and may be nothing
`Models::screen_requirements`: Screen context reads text with OCR when accessibility has little. What
that takes depends on this computer: maybe nothing at all.

#### Test hook holds a caller at waiting for the model
`Models::pretend_downloading`: Counts `id` as downloading without fetching anything, so a test can
hold a caller at "waiting for the model".

#### Some(None) means a download not yet reported; None means none running
`Models::download_progress`: How far the first running download among `ids` is. `Some(None)` is one
that hasn't reported yet; `None` means nothing is downloading.

#### User-requested downloads let the user choose the llama.cpp runtime
`Models::ensure_installed`: [`Self::ensure`] for a download the user asked for, so the llama.cpp
runtime is the one they chose. Fails with why `ids` are not installed.

#### Built-in models stay ready on Vulkan or CPU while CUDA setup waits
`Models::publish_status`: Built-in models stay ready on Vulkan or CPU while a CUDA selection
waits for setup; `runtime_backend` reports the selected runtime.

#### A server needs no download, only finished setup
`Models::publish_status`: A server needs no download, only its setup finished.

#### Think and search share the runtime; download it once
`Models::prepare_for_settings`: Think and search both need the runtime; download it once.

#### Waits for downloads others started; false if missing and downloads disallowed
`Models::ensure`: Ensures the given ids are installed, downloading them when allowed.
Returns `Ok(false)` when something is missing and downloads are not allowed.
A download someone else started is waited for, and `Ok(true)` means
every id is installed.

#### Background work gets CPU or Vulkan runtime, not CUDA, unless asked
`Models::ensure`: Nobody asked to set up CUDA here, so built-in models get what they
run on until they do.

#### Fetch new llama.cpp build in background after update, retry, remove old; CUDA stays explicit
`Models::finish_runtime_update`: Run at launch. An app update can move to another llama.cpp build, and
every feature counts the runtime as missing until it's there. Someone
who had set it up shouldn't have to find that out, so this fetches the
new build in the background, keeps trying when that fails, and removes
what the older versions installed once it's there. CUDA stays an
explicit download; built-in models run on Vulkan or CPU until then.

#### For work that checks for the runtime once per launch
`Models::runtime_updating`: [`Self::finish_runtime_update`] may still bring the runtime. For work
that checks for it once per launch.

#### Delete the digest sidecar so it cannot vouch for a later file
`Models::uninstall`: With its digest sidecar: a sidecar left behind would vouch for
whatever file is put at that path later.

#### With explicit false the runtime is never CUDA
`Models::download_tracked`: With `explicit` false, the llama.cpp runtime is what built-in models
run on, never CUDA.

#### Backoff after failed runtime update; offline at launch is common and apps stay open for days
`runtime_update_delay`: How long to wait after a failed runtime update. Offline at launch is the
usual reason, and an app can stay open for days.

#### Cancelling in Settings ends retries for this launch; failures only logged
`retry_runtime_update`: Tries until nothing is pending. Cancelling in Settings ends it for this
launch; a failure is only logged, since nobody asked for this download.

#### Test library has the CPU archive preloaded so tests fetch nothing
`updated_library`: A library an older LokalBot used, with this build's CPU archive already
in the download folder, so these tests fetch nothing.

#### Without finish_runtime_update think, search and autocomplete stay unavailable after update
`launching_after_an_update_brings_the_runtime_back`: The upgrade check: without [`Models::finish_runtime_update`], think,
search and on-device autocomplete all stay unavailable after an update.

#### Only the CPU archive exists so a CUDA download would fail
`background_work_never_starts_a_cuda_download`: Only the CPU archive is there; a CUDA download would fail this.

#### Processing used to go on without a model Settings was downloading and failed
`ensure_waits_for_a_download_someone_else_started`: Processing a meeting while Settings was downloading the same model
went on without it, and the job failed.

### `LinuxWindows/crates/lokalbot-engine/src/project_notes.rs`

#### Where-it-stands notes: button on request, auto on open once per evidence if Think may run unattended
"Where it stands" notes on tracked projects (`ProjectStore.writeSummary`).
The button writes one on request. Opening a tracked project writes or
refreshes its note by itself, if the Think model is ready and may run
unattended, and at most once for the same evidence.

#### Automatic tries are remembered per run so failing notes are not retried on each open
`ProjectNotes.attempts`: `<project><evidence fingerprint>` of every automatic try this run, so a
note that keeps failing isn't retried each time the project opens.

#### Mirrors shouldWriteAutomatically for opening a project
`due_automatically`: Whether opening `project` should write its note (`shouldWriteAutomatically`).

#### Opening a project never asks the person anything; failure just leaves the button
`ProjectNotes::opened`: A tracked project was opened. Nothing here asks the person for
anything: a failure just leaves the Write Note button.

#### Re-check approval and project existence after the model finishes writing
`ProjectNotes::write_now`: The approval may have gone, or the project been dropped, while the
model wrote.

### `LinuxWindows/crates/lokalbot-engine/src/recording.rs`

#### Recording start and stop mirrors RecordingController.swift
Starting and stopping meeting recordings (`RecordingController.swift`).

#### Remember the stopped calendar event so detection cannot restart it immediately
`Recording.last_stopped_event`: The calendar event of the last recording the user stopped, and when,
so detection cannot immediately restart a meeting they ended
(`lastCalendarEventID`, `calendarRepeatCooldown`).

#### Unsaved stopped recordings are retried on quit, which stays open if still failing
`Recording.pending`: Stopped recordings whose details or processing job could not be saved.
Quitting saves them again and stays open if it still can't
(`pendingFinalizations`).

#### Detector-started recordings may be stopped when their call ends
`Active.automatic`: Started by the detector; its call's end may stop it.

#### Health monitor feeds live warnings and recording-health.json
`Active.health`: Live warnings and `recording-health.json`.

#### A recording naming a room accepts only that room; query parameters ignored
`accepts_call`: Whether a detected call can be the one a recording is for
(`CaptureIntent.accepts`): a recording that names a room accepts only that
room. Calendar links can carry query parameters such as `?authuser=0`.

#### A call found during recording binds its sound and room from then on
`bind_detected_call`: A call found during a recording: its sound from now on, and its room.

#### Automatic starts are suppressed for an event the user just stopped
`StartSource::Detector`: Automatic mode; suppressed for an event the user just stopped.

#### Every way to start a recording funnels through start
`Recording::start`: Every way to start a recording ends here: the buttons, the tray, the
palette, a second `lokalbot` process, the detector, a notification and
Today's calendar rows.

#### Calendar handoff continues a recording so skips the dictation-busy refusal
`Recording::start`: A calendar handoff continues a recording, which dictation can't be
running over; every other start asks first (`startRecording`).

#### Refuse clearly on low disk before creating anything rather than losing a meeting mid-record
`Recording::start`: A recording that dies mid-meeting from a full disk loses the meeting;
a clear refusal doesn't. Nothing has been created yet.

#### User stop blocks detection restarting that calendar event for a while
`Recording::stop`: The user stopped the recording: detection may not restart its
calendar event for a while.

#### A call ending on its own stops the detector recording without repeat cooldown
`Recording::call_ended`: The detector's call ended on its own: stop the recording it started.
A call that ended this way never starts the repeat cooldown.

#### Back-to-back events: detector recording ends and next event's begins
`Recording::split_for_calendar_handoff`: Back-to-back events in one call (`splitForCalendarHandoff`): the
recording the detector started ends and the next event's begins.

#### Quit saves recordings and defers processing; refuses while anything unsaved
`Recording::prepare_for_quit`: On quit: saves what was recorded and leaves processing for the next
launch. False while anything stopped could not be saved
(`prepareForTermination`).

#### Warn when audio is much shorter than the session because a device dropped out
`Recording::finish`: The wall clock can outlast the audio: a device that dropped out
truncates the tracks while the session stays live.

#### Disk-failing stop steps are separated from the capture device and report whether saved
`Recording::finalize`: The part of stopping that can fail on a full or read-only disk, apart
from the capture device. Says whether it was all saved (`finalize`).

#### Failed save steps stay pending and tell the person what to do
`Recording::persist`: Saves one stopped recording's details, then its processing job. A step
that fails stays pending and tells the person what to do
(`persistFinalization`).

#### A meeting deleted while pending is forgotten
`Recording::persist`: Deleted while its details couldn't be saved: nothing is left to keep
(`forgetFinalization`).

#### On-disk details may be newer than what the recording started with
`current_metadata`: The meeting as it is on disk now, if it is still the same one. Its title and
boundaries may be newer than what the recording started with.

#### Latest saved details win; stopping only fills capture facts
`merging_finalization`: The latest saved details win for anything the person can edit. Stopping only
fills in the capture facts an in-progress `meta.json` can't know yet
(`mergingFinalization`).

#### Close crashed recordings at audio end; call only under library lock before engine starts
`recover_unfinished_recordings`: Closes recordings a crash or power loss left open. Their `meta.json` has no
`endedAt`, so they would stay "recording" for good: processing skips live
meetings and the player refuses them. As the macOS app does when it loads
a library, each one ends at its audio's last write, or where its longest
track ends if that is later, once the WAV headers are repaired; then it is
queued the way a stopped recording is.

Call only while holding the library's single-instance lock and before the
engine starts, so a recording that is still running is never closed.
Returns the meetings it closed.

#### Read file modification time before the repair writes to the file
`recover_unfinished_recordings`: Before the repair, which writes to the file.

#### Crashed recording has no endedAt and WAV headers still saying empty
`tests::crashed_recording`: A meeting whose recording stopped without `finish`: no `endedAt`, and
WAV headers that still say the files are empty, as after a crash.

#### Writer had not updated RIFF and data sizes at crash
`tests::crashed_recording`: The writer had not updated the RIFF and data sizes yet.

#### Mac quit leaves a finished meeting and a job for next launch, no notification
`quitting_saves_the_recording_and_defers_its_processing`: The Mac's quit: stopping leaves a finished meeting and a job for the
next launch, with no notification and nothing processing now.

#### A queued job requested during retry survives the deferral
`a_durable_request_outranks_the_deferred_one`: A queued job a person asked for during the retry survives the deferral.

#### Mac crash audio closes like native: unfinished AAC and unknown-size tee
`closes_a_mac_recording_from_its_crash_audio`: The Mac's crash audio is closed like this app's own: no `endedAt`, an
AAC that never finished and a tee with a data chunk of unknown size.

#### Mimics the CAF AVAudioFile leaves for the tee when the process dies
`growing_caf`: What `AVAudioFile` leaves behind for the tee when the process dies.

#### End time is file write time, long after the meeting started
`closes_a_recording_left_open_and_queues_it`: The files were written just now, long after the meeting started.

### `LinuxWindows/crates/lokalbot-engine/src/resources.rs`

#### Resource figures are local only; nothing stored or sent; mirrors Mac monitor
What LokalBot and its helpers use right now, and which models are in memory
(`ResourceMonitorSection`, `ModelResidency`, `ModelRuntimeRegistry`). Local
figures only; nothing is stored or sent.

#### None for in-process models because their share cannot be told apart
`LoadedModel.memory_bytes`: `None` for a model inside LokalBot's own process, whose share of the
total can't be told apart.

#### CPU is 0-100 across all cores, unknown until second reading
`ResourceSnapshot.cpu_percent`: Across all cores, 0–100; unknown until a second reading.

#### Recent generation timings kept in memory only
`GenerationMetrics`: The last generations, in memory only (`GenerationMetricsStore`): these
numbers matter only while someone is watching them.

#### Token estimate matches TokenCountEstimator: chars over 4 per word, minimum 1
`estimated_tokens`: `TokenCountEstimator`: per word, characters / 4, at least 1.

#### A falling total from an exited helper yields no CPU reading
`cpu_percent`: A helper that exited makes the total fall; that reading says nothing.

### `LinuxWindows/crates/lokalbot-engine/src/retention.rs`

#### Retention runs at startup and every six hours; scheduled passes keep digests and memory
Applies the retention window from Privacy settings: at startup, then every
six hours (`ScreenshotService.performRetentionPrune`). Window titles older
than the window are cleared; meetings are never touched.

A scheduled pass isn't a deletion: nobody deleted or corrected what expired,
so digests and overnight memory stay. Exports and routines still look again,
and answers reused from those days are forgotten
(`AppState.withScheduledRetention`).

#### A pass from before this launch still counts for Settings
`retention::start`: A pass from before this launch still counts for Settings.

### `LinuxWindows/crates/lokalbot-engine/src/routines.rs`

#### Routines are fixed-scope: no shell, network, meeting mutation or arbitrary prompts; one private file
Fixed-scope local routines (`MemoryRoutines.swift`). They do not invoke a
shell, contact a network, mutate meeting data or accept arbitrary prompts. The
sole write is one private Markdown file under the folder the person chose.

#### Output folder must resolve inside the chosen one so links cannot redirect
`routines::write`: Writes a prepared routine under `destination`. The folder it lands in must
resolve inside the chosen one, so a link can't carry the file elsewhere.

#### Weekday numbering matches the Mac: 1 is Sunday, 7 Saturday
`most_recent_weekly_target`: The newest instant at or before `now` on `weekday` (1 is Sunday, 7 Saturday,
as on the Mac) at `hour`.

#### Lists due jobs whether run or not; finished tokens skipped when output known
`candidate_jobs`: What's due at `now`, whether or not it has run; finished tokens are skipped
when a job's output is known.

#### Stuck read or write cannot be interrupted so is left to finish
`with_time_limit`: Runs `work` on its own thread and gives up after the safety limit. A stuck
read or write can't be interrupted, so it is left to finish on its own; its
run is already recorded as failed.

#### Unchanged bytes for a finished token do nothing
`run_job`: Prepares and writes one job, recording the attempt. Unchanged bytes for a
finished token do nothing.

#### Preparation failure is recorded once; read-only preparation recovers next tick
`run_job`: Preparation may fail before output has a fingerprint. Record the
failure once; read-only preparation can recover next tick.

#### Corrections rebuild output; finished revisions stay in audit trail
`Routines::reconsider_evidence`: Rebuilds prepared output after a correction, completion or deletion.
Finished revisions stay in the audit trail; changed bytes get a new token.

#### Recording and dictation take priority over routines
`can_run`: Meeting recording and dictation take priority over routines.

#### 2026-10-15 is Thursday, the Mac's weekday 5
`weekly_targets_look_back_to_the_chosen_weekday_sunday_first`: 2026-10-15 is a Thursday, the Mac's weekday 5.

#### Follow-ups look back fourteen days and exclude the sample meeting
`due_jobs_follow_the_enabled_routines_and_the_hour`: Fourteen days back, never the made-up sample.

### `LinuxWindows/crates/lokalbot-engine/src/sample.rs`

#### Sample meeting is synthetic, imported normally, hidden from personal memory, built by sample_meeting.py
LokalBot's sample meeting (`LokalBot/Resources/SampleMeeting`): a made-up
call between two synthetic voices, bundled so a new library can show a
cited answer before anything is recorded. It goes through the ordinary
import (`library_ops::import_sample`) and carries `sampleID`, so Ask,
search and agents see it while personal memory leaves it out.

`Scripts/dev/sample_meeting.py` builds the audio and its reference transcript,
and scores a transcript of it.

#### Stored as the meeting's sampleID: script then language
`Sample.id`: Stored as the meeting's `sampleID`: the script, then its language.

#### Sample picked by interface language, falling back to English
`for_language`: The sample spoken in `language` (an interface language such as "de" or
"sr-Latn"), else the English one.

#### Sample audio is an MP4 container the importer reads as AAC
`matches_the_bundled_scripts`: An MP4 container, which the importer reads as AAC.

#### Traditional Chinese gets the Mandarin recording titled in Simplified
`follows_the_interface_language_then_english`: Traditional Chinese gets the Mandarin recording too, titled in Simplified Chinese.

### `LinuxWindows/crates/lokalbot-engine/src/screen.rs`

#### Screen context triggers, cooldown, redaction, privacy gates and differences from macOS
Screen context (`ScreenshotService.swift`): when the user turns it on,
day memory also keeps the focused window's visible text and, in "Text +
visual context", an encrypted image of it.

Captures follow interaction boundaries: app and window changes from the
day-memory sampler, a pause after typing or pointer input, a clipboard
change, an idle interval (Settings: "at least every N min"), and "Capture
Screen Now". Event triggers share a 20 s cooldown and unchanged screens
are skipped. Text comes from accessibility first, then on-device OCR when
it is thin; secrets are redacted before anything is stored, and a capture
with a redaction keeps no pixels. Nothing is captured while tracking is
off, day memory is paused, the session is locked, or LokalBot, an
excluded app or site, a private window or a password field is in front.

Differences from macOS: "Text context" may read the window's pixels in
memory for OCR when accessibility has little text (the pixels are never
stored), because many Linux and Windows apps expose less through
accessibility; and private browser windows are skipped.

#### Event-driven captures are 20 s apart, mirroring ScreenCapturePolicy
`EVENT_COOLDOWN`: Minimum time between event-driven captures (`ScreenCapturePolicy.eventCooldown`).

#### Meeting frames are at most once a minute
`MEETING_CAPTURE_COOLDOWN`: Frames during a meeting come at most once a minute.

#### Nothing is captured after 180 s of inactivity
`IDLE_LIMIT_SECONDS`: Inactivity after which nothing is captured.

#### Longest frame side is 1500 px, matching macOS
`MAX_DIMENSION`: Longest side of a processed frame (`ScreenshotCaptureDimensions.maximumDimension`).

#### At most 36000 characters of screen text kept per capture
`MAX_TEXT_CHARS`: Most screen text kept per capture.

#### Accessibility reads bounded to 250 ms like the Mac reader
`READ_DEADLINE`: Accessibility reads are bounded like `ScreenAccessibilityReader`.

#### Tab switch or page load can change the window during a read
`SETTLE_DELAY`: A tab switch or page load can change the window during a read.

#### Capture Screen Now waits 10 s for a non-LokalBot window
`MANUAL_WAIT`: "Capture Screen Now" waits this long for a window other than LokalBot.

#### Raw value is stored in screenshots.capture_trigger, matching ScreenCaptureTrigger
`Trigger`: What caused a capture; the raw value is `screenshots.capture_trigger`
(`ScreenCaptureTrigger`).

#### last_check also set on skipped captures so they do not retry every event
`CapturePolicy`: Rate limiting (`ScreenCapturePolicy`): event triggers respect the
cooldown, the interval trigger waits for the idle window, manual always
wins. `last_check` is also set when a capture was skipped as unchanged or
private, so those do not retry on every event.

#### Idle interval from Settings has a one-minute floor
`idle_interval`: The idle interval from Settings, at least a minute.

#### Settings changing during a capture discard it
`Consent`: The settings a capture was started under (`ScreenshotCaptureConsent`).
Anything that changes them while a capture runs discards it.

#### Counts redactions so far: text, title, address, document name
`Request.prior_redactions`: Redactions made so far (text, title, address, document name).

#### Pixels kept only in Text plus visual mode with an image key
`Request.may_keep_pixels`: Whether this capture may keep pixels at all ("Text + visual context"
with an image key).

#### Content hash compared with last stored frame so identical screens are skipped
`Processor`: Hash, text-source choice, OCR and redaction in one order
(`ScreenshotProcessingWorker`). The content hash is compared with the
last frame that was stored, so an identical screen is skipped.

#### A detected credential keeps only redacted text and drops pixels
`Processor::process`: A detected credential keeps only its redacted text: dropping the
pixels is safer than guessing where on screen it was.

#### Hash covers frame size and pixels, matching Swift contentHash
`content_hash`: SHA-256 of the frame's size and pixels (`ScreenshotImageProcessing.contentHash`).

#### Text-only capture identity prevents re-storing an unchanged window
`text_fingerprint`: A text-only capture's identity, so an unchanged window is not stored
again (`ScreenshotService.storeTextContext`).

#### Day-memory sampler calls it when a new activity block begins
`ScreenContext::boundary_hook`: Called by the day-memory sampler when a new activity block begins.

#### Restart reopens capture devices and re-asks the credential store for the image key
`ScreenContext::restart`: Closes the capture devices and opens them afresh on the next look, and asks
the credential store for the image key again.

#### Note skips also start the capture cooldown
`Skip`: Why a capture attempt kept nothing. `Note` also starts the cooldown.

#### Model files and backend limits change rarely so probed every 5 s
`Worker::refresh`: The model files and the backend's limits change rarely.

#### Pending manual capture runs once another window is in front, or gives up
`Worker::poll_manual`: A pending "Capture Screen Now" runs once a window other than
LokalBot is in front, or gives up after [`MANUAL_WAIT`].

#### Mirrors ScreenshotService.captureIfAppropriate
`Worker::capture`: `ScreenshotService.captureIfAppropriate`.

#### Meeting frames are opt-in, off by default, low frequency and linked to the meeting
`Worker::capture`: Off by default: low-frequency frames linked to the meeting.

#### X11 cannot exclude the ghost-text window so no capture while a suggestion shows
`Worker::capture`: X11 cannot leave the ghost-text window out of a screen grab (Windows
excludes it from capture), so no capture while a suggestion shows.

#### Window or password-field change during pixel read discards the capture
`Worker::capture`: The window, its address or its password-field state can change
while the pixels are read; any change discards them. The activity
sample is read again too: some backends (the portal) cannot name
the window they captured.

#### A file is not a capture until its rows commit
`Worker::capture`: A file is not a capture until its rows commit.

#### Image key created on first use; no credential store means no images, reported once
`Worker::image_key`: The image key, created on first use. Without a credential store no
image is kept; that is reported once in the status.

#### OCR engine loads on first use and is kept while still needed
`load_ocr`: The OCR engine, loaded on first use and kept while screen context is on and
this computer still calls for it.

#### Retry once after a moment if the window changed; timeout fails closed
`read_accessibility`: Reads accessibility once, and once more after a moment when the window
was changing (`lastTextReadFailure(...).isTransient`). `None` when this
desktop or app offers no accessibility; a timeout fails closed.

#### Without accessibility focus is unknown and no password field is assumed visible
`observation`: What is known about the window for [`privacy::permits_content`]. Without
accessibility the focus is unknown and no password field is known to be
visible.

#### Same window, title, address and password-field state, mirroring Swift focus validation
`focus_still_matches`: `ScreenshotWindowFocusValidation.matches`: the same window is still in
front with the same title, address and password-field state.

### `LinuxWindows/crates/lokalbot-engine/src/screen_vectors.rs`

#### Screen vectors start only after meaning search is used; pictures decrypted in memory, paced, battery-limited
Vectors of saved screens, so screen search finds a screen by what it says and
shows (`EmbeddingIndex` screen backfill, `ScreenImageEmbeddings`).

Both start only once screens have been searched by meaning, so nobody downloads
the image model for a search they never make. Text vectors need only the
embedder. Picture vectors run on the media embedder Files uses, only while
search by meaning is on and pictures are captured (Text + visual context). A
capture is decrypted in memory, sized for a 280-token budget and never written
to disk. A vector goes with its pixels: retention clears both, and deleting a
capture deletes both.

The first pass over a library is a big read, so it is paced while the person
uses the computer, and on battery a pass stops after the newest few dozen
captures: the rest wait for a charger.

#### On battery a pass reads at most 48 newest captures
`BATTERY_LIMIT`: On battery, a pass reads at most this many captures, newest first.

#### New captures wait 15 minutes so one pass embeds a batch
`NEW_TEXT_DELAY`: New captures wait this long, so one pass embeds a batch of them.

#### Pictures need meaning search on, visual capture mode, and prior meaning search
`pictures_allowed`: Pictures are read only while search by meaning is on and pictures are captured
(Text + visual context), and only once screens have been searched by meaning.

#### On battery with captures left beyond the limit
`PassOutcome::WaitingForPower`: On battery, with more left after the newest `BATTERY_LIMIT`.

#### New captures are covered by one batched pass later
`ScreenVectors::captures_arrived`: New captures were stored: one batched pass later covers them all.

#### A search may have occurred before this thread was listening
`Worker::launch`: A search may have come before this thread was listening.

#### Text vectors need only the embedder already downloaded by meaning search
`Worker::text_pass`: Embeds captures' text until none is left. Needs only the embedder, which
search by meaning already downloaded.

#### Picture pass embeds newest first until done, paused, failed, or battery limit
`Worker::picture_pass`: Embeds retained captures without a picture vector, newest first, until none
are left, a pause condition appears, the embedder fails, or, on battery,
`BATTERY_LIMIT` captures are through.

#### Pixels may be deleted meanwhile; store checks
`Worker::picture_pass`: The pixels may be gone by now: `store` checks.

#### First picture pass downloads the projector, as the notice says
`Worker::start_session`: The first picture pass downloads the projector, as the notice says.

#### Unreadable captures are marked so they are not retried every pass
`Embedded::Unreadable`: The pixels could not be read or the server rejected them: marked, so a
broken capture isn't tried on every pass.

#### Decrypts in memory; nothing written to disk
`embed_capture`: Decrypts in memory: nothing is written to disk.

### `LinuxWindows/crates/lokalbot-engine/src/secrets.rs`

#### Secrets live only in the system credential store, never settings.json or library
API keys, private calendar links and the keys that seal screen images and
recent dictations live in the system credential store (Windows Credential
Manager, the Secret Service on Linux), never in `settings.json` or the
library.

#### Uses the Mac's Keychain account name
`save_remote_transcription_api_key`: Saves (or, when blank, removes) the transcription server's own key, under
the Mac's Keychain account name.

#### ChatGPT plan items use Mac account names; sign-in fails without a credential store
`PlanStore`: The ChatGPT plan's session, registration and per-install id, under the
account names the Mac uses in its Keychain (`chatgpt-plan-*`). They are
kept nowhere else: without a credential store the sign-in fails.

#### Tokens split across items: Credential Manager holds 1280 characters per item
`install_plan_store`: Lets Think and Settings keep the ChatGPT plan in the credential store.
Tokens are split across items: Credential Manager keeps at most 1,280
characters in one.

#### Per-install key, created on first use, cached; unreachable store never yields a new key
`screen_image_key`: The per-install key that seals screen images (`ScreenshotService.encryptionKey`,
Keychain account `screenshot-key`). It is created on first use when
`create` is set, kept only in the credential store, and cached for the
life of the process so captures do not ask the store each time. A store
that cannot be reached never leads to a new key: images are then not kept.

#### Without a reachable store recent dictations stay in memory only
`recent_dictations_key`: The per-install key that seals recent dictations, kept like the screen
image key. Without a reachable store they stay in memory only.

#### Without a reachable store nothing about a voice is kept
`speaker_identity_key`: The per-install key that seals remembered voices and speaker evidence
(`KeychainSecrets`, account `speaker-identity-key`). Without a reachable
store nothing about a voice is kept.

#### Seals Ask, Personal Context and learning log; unreachable store never makes a new key
`chat_key`: The per-install key that seals Ask conversations, Personal Context and the
dictation learning log, under the Mac's account name. It is created on first
use when `create` is set. A store that can't be reached never leads to a new
key: those stay unsaved, or kept as they are, until it can.

#### Seals autocomplete learned examples under the Mac's account name
`cotyping_learning_key`: The per-install key that seals autocomplete's learned examples, under the
Mac's account name, kept like the screen image key.

#### Read the key back so a store that drops secrets does not leave unopenable files
`sealing_key`: Read it back: a store that silently drops secrets must not
leave files that nothing can open.

#### Long-term phone-pairing key; with no store sharing stays off and says why
`companion_static_key`: This computer's long-term key for paired phones and tablets, under the
Mac's account name, kept like the screen image key. Created when sharing
first starts, never written anywhere else: with no reachable store,
sharing stays off and says why.

#### Calendar links grant read access so live only in the credential store, split across items
`calendar_links`: Private calendar links (iCal feeds and CalDAV collections), one per line.
They grant read access to the user's calendar, so like API keys they live
only in the credential store.

Several links are longer together than Credential Manager keeps in one
item (1,280 characters), so they are split across items like the ChatGPT
sign-in. A short list stays one item, as it always was.

#### Test store mimics Credential Manager's per-item limit
`tests::SmallItems`: A store with Credential Manager's limit on one item.

### `LinuxWindows/crates/lokalbot-engine/src/selection.rs`

#### Selection actions: shortcut reads selection, Think runs on it, nothing persisted or logged
Selection actions (`SelectionActionsController.swift`): a system-wide
shortcut reads the text selected in the frontmost app, the panel runs the
Think model on it (optionally with matching work memory), and the result
replaces the selection, goes in at the cursor, or is copied. Nothing here is
persisted or logged.

#### Panel state lives in memory only while the panel is open
`SelectionView`: Everything the panel shows. Lives in memory while the panel is open.

#### Explains why the result could not be pasted back
`SelectionView.notice`: Why the last result could not be pasted back; shown above it.

#### Not pasted for the given reason; result is on the clipboard
`DeliveryOutcome::Copied`: Not pasted, for this reason; the result is on the clipboard.

#### Setting off means nothing is read
`Host::enabled`: The setting is on. Off means nothing is read.

#### Bumped per request so a superseded one never writes state
`Inner.generation`: Bumped by every new request, so a superseded one never writes state.

#### Selection is read before the panel opens because opening moves focus
`Controller::invoke`: The shortcut was pressed. Reads the selection first, because opening
the panel moves focus away from it.

#### Shortcut while LokalBot is in front keeps any open panel's state
`Controller::invoke`: Pressed while LokalBot is in front: keep any open panel's state.

#### Error is not logged in detail because it can quote the selection
`Controller::run`: The error can quote the prompt, which holds the selection.

#### Copy hands focus back to the source app ready for Ctrl+V
`Controller::copy_output`: Copies the result and hands focus back to the app it came from, ready
for Ctrl+V. The panel closes.

#### Replace or insert; if the field changed the panel returns with result copied
`Controller::insert_output`: Replaces the selection with the result, or inserts it at the cursor
when nothing was selected. The panel closes; if the field changed
meanwhile, the panel comes back with the result already copied.

#### Reopen the panel only if nothing newer took it
`Controller::insert_output`: Nothing newer took the panel meanwhile.

#### Gives the app time to return keyboard focus before the field check
`FOCUS_SETTLE`: Lets the app give keyboard focus back to its field before checking it.

#### Mirrors SelectionDelivery.message(for:)
`check_message`: `SelectionDelivery.message(for:)`.

#### Replacement needs the exact selection; dictation's app-only fallback is looser
`field_check`: Replacement requires the exact selection, including a range having been
cleared to a caret. Dictation's app-only fallback is less strict.

### `LinuxWindows/crates/lokalbot-engine/src/speak.rs`

#### Read aloud: one at a time, model loads on demand and is released after two idle minutes
Read aloud (`MeetingWorkspaceView.readSummary`, `ChatView.readAssistantTurn`,
`ModelSpeechSettingsSheet`). One thing reads at a time. The model loads when
first needed, downloading if it must, and is released after two idle minutes.

#### Marks an export's failure in SpeechStatus.error
`EXPORT_KEY`: Marks an export's failure in [`SpeechStatus::error`].

#### Session that started the model download stops it when stopped
`Session.downloading`: This session started the model download, so stopping it stops the download.

#### One synthesis at a time: Mac uses a process each and espeak state is shared
`Inner.synthesis`: One synthesis at a time: the Mac runs a process for each, and espeak's
state inside sherpa-onnx is shared.

#### Stopped or replaced sessions leave status to their replacement
`Inner::end_session`: Clears the session if it is still `id`. Stopped or replaced sessions
leave the status to whatever replaced them.

#### Say nothing about a missing model when there is nothing to read
`Inner::synthesize`: Say nothing about a missing model when there is nothing to read.

#### Download the model if missing or wait for a running download
`Inner::prepare_model`: Downloads the model if it is missing (`KokoroSpeechEngine.preparedModelDir`),
or waits for a download that is already running.

#### Another download may start between the check and ensure
`Inner::prepare_model`: Someone else may have started it between the check and `ensure`.

#### Freeing the model leaves a running synthesis its own reference
`Inner::release_if_idle`: Frees the model; a synthesis still running keeps its own reference.

### `LinuxWindows/crates/lokalbot-engine/src/speech.rs`

#### Share one speech model span by span; meeting passes yield to waiting calls
One loaded transcription model, shared by meeting processing and dictation,
released after two idle minutes like the macOS speech engines.

The model is shared span by span. Dictation, the live previews and the
model check are answered while someone waits, so a meeting pass stands
aside for them between spans ([`SpeechCache::stand_aside`]).

#### Count calls someone is waiting on so meeting passes yield
`SpeechCache.urgent`: Calls in progress that someone is waiting on.

#### Cache dictation names for a day or until library changes
`SpeechCache.dictation_terms`: Dictation's known names, kept for a day or until the library changes.

#### Model id doubles as server, model and key identity for remote servers
`Loaded.model_id`: The model id, or the server, model and key behind a transcription server.

#### Waited-on work lets an in-progress meeting pass go first
`SpeechCache::with`: Runs `f` with the transcriber for `model_id`, loading it first if
needed. For work someone is waiting on: a meeting pass in progress
lets it go first.

#### Count urgent only once model is in hand to avoid deadlock
`SpeechCache::with`: Counted once the model is in hand: while this call waits for a pass
to give up another model, that pass must not wait for this call.

#### Meeting passes call stand_aside between spans so nobody waits long
`SpeechCache::with_in_background`: [`Self::with`] for a whole meeting. `f` calls [`Self::stand_aside`]
between spans, so nobody waits for more than the span being decoded.

#### Check server approval every call so revocation applies next clip
`SpeechCache::transcriber`: Checked each time, so a revoked approval counts from the next clip.

#### Never hold two models in memory; wait for the other to finish
`SpeechCache::transcriber`: Two models never share memory: a call still using the other one
finishes first, as it did when the model was held for a whole call.

#### A model still loading does not count as loaded
`SpeechCache::is_loaded`: Whether `model_id` is in memory. One still loading is not there yet.

#### Read aloud reports its voice model entering or leaving memory
`SpeechCache::set_voice_loaded`: Read aloud's voice model came into or left memory.

#### Loading model is missed in a reading; never blocks the caller
`SpeechCache::loaded_models`: Speech models held in this process, with the role each serves. A model
still loading is missed for that reading; it never blocks the caller.

#### Dictation adds recent attendee and project names to vocabulary, as on Mac
`SpeechCache::dictation_prompt`: Dictation has no meeting of its own, so prompt-capable models get recent
attendee and project names beside the manual vocabulary
(`AppState.dictationTranscriptionSettings`).

#### In-progress calls hold a reference so long passes are never idle
`SpeechCache::release_if_idle`: Frees the model when it has not been used for a while. A call in
progress holds its own reference, so a long pass is never idle.

#### Waiting call for another model must not make the pass wait in turn
`a_call_for_another_model_waits_for_the_pass_and_does_not_stop_it`: The other call is waiting for this model to be freed, so
it must not make this pass wait in turn.

#### Other call then tries loading its own model, not installed in test
`a_call_for_another_model_waits_for_the_pass_and_does_not_stop_it`: Then it tries to load its own model, which is not installed here.

### `LinuxWindows/crates/lokalbot-engine/src/upcoming.rs`

#### Evidence gathered per request; brief cached in memory, never saved or auto-downloaded
Preparation for the next meeting on Today (`UpcomingMeetingPreparationModel`).

The evidence is gathered on every request; a brief written by the local
Think model is cached in memory by the evidence's signature and never
saved. Automatic briefs never download a model: they run only when the
Think model is on this computer and already installed. "Generate brief"
may prepare it.

#### Failed automatic briefs retry only on explicit request
`Briefs.failed`: Signatures whose automatic brief failed; only an explicit request retries.

#### Collapse queued requests so only the newest per event runs
`Preparation job loop`: Only the newest request for the same event matters.

### `LinuxWindows/crates/lokalbot-engine/src/voice.rs`

#### One VoiceMemory per library, hourly expiry, background learning; mirrors Mac
Voice memory beside the pipeline (`AppState.learnSpeakerVoices`,
`MeetingSpeakerIdentityService.maintainRetention`): one [`VoiceMemory`] per
library, evidence expiry every hour, and a background pass that learns the
names people already gave.

#### Automatic speaker naming stays off until TitaNet is measured on real calls
`NAME_SPEAKERS_AUTOMATICALLY`: Whether a strong voice match names a speaker without asking, as on the Mac.
Off until TitaNet has been measured on real calls (see
`lokalbot_core::voice::matcher`): a wrong name attributes words to the wrong
person, and until then a person confirms each one with Apply Names.

#### Credential store opens only when a sealed file is needed
`memory`: The library's voice memory. Nothing opens the credential store until a
sealed file is actually needed.

#### Read the call track only if a sample needs it
`microphone_evidence`: The microphone checks, reading the call track only if a sample needs it.

#### Unavailable voice model is an error so the meeting is revisited
`call_samples`: Unavailable is not "no voices": the meeting is revisited later.

#### Name saves to transcript alone when voices cannot be remembered
`save_choice`: Applies a person's choice and saves the transcript (`saveSpeakerAlias`,
`AppState.saveTranscript`). A name still counts when voices can't be
remembered here, say with no credential store or a library whose sealed
files came from another computer: it goes on the transcript alone.

#### Repair transcript when name was recorded but save was interrupted
`recover_saved_names`: Repairs a transcript when a name was recorded but the save was interrupted.

#### Delete proceeds when voices cannot open; cleanup deferred and reported honestly
`delete_meeting`: Deletes a meeting and takes it and its merged sources out of remembered
voices first. The delete goes ahead when voices can't be opened: it is what
the person asked for, the upkeep pass finishes the cleanup once they can,
and the returned text says so rather than claiming it happened.

#### Test adds transcript-only sources after the journal was written
`a_stale_journal_doesnt_block_a_name_for_a_newer_transcript`: Transcript-only sources were added after the journal was written.

### `LinuxWindows/crates/lokalbot-engine/tests/e2e_media.rs`

#### Ignored e2e checks Linux/Windows media embedder matches Mac request shapes and text vectors
The media embedder with the real llama-server and the real projector. Needs the
network and about 1 GB of disk; run on a development machine:

```sh
LOKALBOT_E2E_ROOT=~/scratch-root cargo test -p lokalbot-engine --test e2e_media -- --ignored --nocapture
```

The Mac's 30 October parity run qualified its own build; this checks that the
Linux or Windows build takes the same request shapes and that a text's vector
matches the text-only embedder's, as search relies on.

#### Media text vector must match text-only embedder since searches score against it
`the_projector_embeds_pictures_sound_and_text_and_a_pass_finds_them`: A text's vector here must match the text-only embedder's: searches embed
their words there and score against the index.

#### Text longer than one batch is cut to fit, not refused
`the_projector_embeds_pictures_sound_and_text_and_a_pass_finds_them`: A text longer than one batch is cut to fit, not refused.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
