# 0006. Meetings and notes

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers recorded and imported meetings in the Mac app and the Windows and Linux app: the post-meeting queue that transcribes and summarizes them, the notes and outcomes extracted from transcripts, merging, deleting and exporting meetings, follow-up drafts, and the meeting page. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Notes generation

### Notes come from one extraction pass per part, and the app validates and renders them

Each transcript part gets one extraction pass that yields notes, actions, decisions and open questions. The model cites only `s#` row IDs; the app maps them to stable segment IDs, checks every record against the cited speech, repairs rejected records once or twice, and renders the Markdown itself.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/mod.rs`, `LokalBot/Services/Notes/MeetingNotesGenerator.swift`, `LokalBot/Services/Notes/MeetingNotesRecovery.swift`.

### The transcript travels as context, not inside the instruction

A server with prompt caching (Anthropic) then reuses the transcript across one meeting's requests. Every other server gets it joined in front of the instruction.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/mod.rs` (`request`).

### Notes parts are planned in fixed window steps

Notes parts target 6,000 estimated tokens on the built-in model and on servers whose window is unknown, for small windows, slow prefill and frequent checkpoints. A model with a known larger window takes bigger parts in steps, so a 20-minute meeting on Cerebras Qwen is two requests instead of four. Windows within one step plan identical parts, so a window that drifts between OpenRouter lookups does not re-plan a meeting and discard its saved parts. Even at one token per UTF-8 byte a part stays inside its step's window beside the output allowance.

Where: `LokalBot/Services/Notes/MeetingSummaryGenerator.swift` (`MeetingSummaryGenerator.standardNotesPartTokens`), `LokalBotTests/Services/Notes/MeetingNotesGeneratorTests.swift` (`MeetingNotesGenerator.makeChunks`).

### Parts stay under the provider's schema enum limit

On hosted servers, parts also fit the provider's limit on schema enum values, because each part's schema lists its source IDs three times. On 2026-10-07 a standup's 228 rows became one part whose schema held 709 enum values, and Cerebras rejected it ("cannot exceed 500").

Where: `LokalBot/Services/Notes/MeetingNotesGenerator.swift` (`MeetingNotesGenerator.makeChunks`), `LokalBotTests/Services/Notes/MeetingNotesGeneratorTests.swift` (`testPartsKeepTheirSchemaWithinTheProvidersEnumLimit`).

### A continuation of a part packed to the context limit shrinks its output

Without a provider tokenizer, parts are packed to a byte ceiling beside a full output reservation. The continuation ledger then pushed the page over that reservation, and every retry failed before sending a request.

Where: `LokalBotTests/Services/Notes/MeetingNotesGeneratorTests.swift` (`testContinuationOfAPartPackedToTheContextLimitShrinksItsOutput`).

### Continuation starts only from accepted records; a part cut off before any record is scanned again

On 2026-10-07 reasoning used every output token of a standup's first part. The next runs asked the model to continue from an empty list of accepted records, got empty answers, and stopped the part for good.

Where: `LokalBot/Services/Notes/MeetingNotesRecovery.swift` (`MeetingNotesGenerator.generatePart`), `LokalBotTests/Services/Notes/MeetingNotesGeneratorTests.swift` (`testAPartCutOffBeforeAnyRecordIsScannedAgain`).

### Automatic runs keep a stopped part stopped; an explicit "Summarize again" retries it

The stop keeps automatic runs from cycling on a provider that keeps failing. A person asking again may have changed the model or its reasoning; on 2026-10-07 every "Summarize again" failed in 0.2 s.

Where: `LokalBot/Services/Notes/MeetingNotesRecovery.swift` (`MeetingNotesGenerator.generatePart`).

### A complete repair that answers flagged rows without a task is final

The commitment check only matches wording ("I'll be honest" passes it), so a complete repair that answers its flagged rows without a task for the user stands. Asking again gets the same reply and would leave the part partial for good.

Where: `LokalBot/Services/Notes/MeetingNotesRecovery.swift` (`MeetingNotesGenerator.Recovery.answeredCommitments`).

### Checkpoints and partial notes go away only after the final notes are saved

Partial notes are a coherent, revision-checked snapshot for the meeting page; they never enter the completed outcome index or replace final notes. Checkpoint and partial files are removed only after the final notes are saved, so a crash between the two cannot lose the finished parts. The port's snapshot keeps `version` because the Mac's decoder requires it.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/partial.rs`, `LinuxWindows/crates/lokalbot-ai/src/notes/mod.rs` (`remove_checkpoint`), `LinuxWindows/crates/lokalbot-ai/src/notes/tests.rs` (`one_pass_renders_notes_outcomes_and_header`), `LokalBot/Services/Notes/MeetingNotesPartial.swift`.

### The summary language is voted over passages sampled across the meeting

Each bounded passage is detected on its own and the language with the most material support wins, because `NLLanguageRecognizer` can lock onto a foreign-language opening even when the rest is in another language, and a single prefix must never decide a meeting. The port detects with `whatlang` instead of `NLLanguageRecognizer`. A language outside the summary presets keeps the prompt's own "the transcript's language" rule.

Where: `LinuxWindows/crates/lokalbot-ai/src/language.rs`, `LokalBot/Models/Meetings/SummaryLanguage.swift` (`SummaryLanguage.detectTranscriptLanguage`), `LokalBot/Models/Transcription/LanguageCode.swift`.

## Outcomes and evidence

### Speaker identity comes from the transcript, never from the model

Whose task an action is comes from the voice: the cited row's speaker as the transcript attributes it, while the model's owner, basis and quote are claims to check. For summary claims the model selects and paraphrases, and the app resolves the speaker, never from the model's prose or a display alias.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/ownership.rs`, `LokalBot/Support/SpokenUndertaking.swift`, `LokalBot/Support/OutcomeEvidencePolicy.swift`, `LokalBot/Services/Actions/ActionOwnership.swift`, `LokalBot/Services/Notes/SummaryClaimEvidence.swift` (`SummaryClaimEvidence`).

### Suspected echo rows are dropped from the evidence

A suspected echo repeats a remote participant, whose own row carries the words.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/evidence.rs` (`Evidence::new`).

### Wording vetoes apply only to English

Unrecognized phrasing loses only the ownership claim, never the task. Negated or questioned undertakings and status reports are still not tasks, but those checks read English wording, so in other languages only a question mark can veto; otherwise every quoted commitment would look like a status report and be deleted.

Where: `LokalBot/Services/Notes/MeetingNotesEvidence.swift` (`MeetingNotesEvidence.validate`).

### The due field keeps only a due date that was spoken

The due date is the one spoken, or "" when there is none. The built-in Qwen3.5 4B sometimes copied a cited source ID ("s268") into `due`, which rendered as "due s268", and a year nobody said is the model's guess: an invented "2024-01-01" resolved into the past and topped Today as overdue. The action stays; only the unsupported due phrase goes.

Where: `LokalBot/Services/Notes/MeetingNotesEvidence.swift` (`MeetingNotesEvidence.spokenDue`).

### Validation errors never carry meeting content

They are safe to log or send as repair feedback, so they never contain model output, transcript text, speaker aliases or other meeting content.

Where: `LokalBot/Services/Notes/SummaryClaimEvidence.swift` (`SummaryClaimEvidence.ValidationError`).

### The user's own actions use the owner value macOS writes

The port stores the owner of the user's own action exactly as macOS writes it, and the core, follow-ups and notes read only that value as the user.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/dialogs.rs` (`OWNER_ME`).

### The outcome schema keeps a fixed object shape

For grammar-constrained backends, `owner` and `due` are required but may be empty rather than optional, and `for_user` and `importance` are required, so strict grammars keep the object shape fixed.

Where: `LokalBot/Services/Actions/OutcomesExtractor.swift` (`OutcomesExtractor.schema`).

### Outcome IDs are derived with FNV-1a

FNV-1a keeps an outcome's identity stable across app launches and re-extractions; Swift's `Hasher` is randomized per launch and cannot be persisted.

Where: `LokalBot/Models/Meetings/MeetingOutcomes.swift` (`MeetingOutcomes.stableID`).

### The recap's outcome sections are rendered from the outcomes

The outcome sections of the summary are replaced (or appended) with ones rendered from the outcomes, so the recap can never disagree with the cards.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/render.rs` (`synchronize`).

## Processing queue and transcripts

### Post-meeting processing is a durable queue that counts starts

The queue is persisted in `lokalbotv3.sqlite` with its own connection to the shared file, like `SearchIndex`, `ActivityStore` and `EmbeddingIndex`, so a crash, force-quit or reboot mid-transcription doesn't drop the job, as it could when the in-memory queue in `ProcessingPipeline` was the only record. A row is inserted on enqueue and deleted on success. `attempts` counts processing starts, not failures, so a job that crashes the app still burns an attempt, and once the cap is reached it stops auto-resuming instead of crash-looping every launch.

Where: `LinuxWindows/crates/lokalbot-core/src/jobs.rs`, `LokalBot/Services/Meetings/PipelineJobStore.swift` (`PipelineJobStore`), `LokalBotTests/Services/Meetings/PipelineJobStoreTests.swift` (`testJobStopsResumingAfterAttemptCap`).

### Queued requests merge transcription by OR but take the summary intent from the user

Transcription is the prerequisite for everything downstream, so it merges by OR whoever asked: "Re-summarize" on a meeting whose transcript is still queued must not cancel that transcription. Summarization is discretionary, and OR-ing it let a queued or parked job silently upgrade an explicit "Transcribe" click into "Transcribe & Summarize", so a user-initiated enqueue states the summary intent and the older job defers to it. Automatic work still merges, so a parked summary survives an automatic re-enqueue. The merge is a pure function, so the rule is testable without a live queue.

Where: `LokalBot/Services/Meetings/ProcessingPipeline.swift` (`ProcessingPipeline.merged(pending:incoming:origin:)`), `LokalBotTests/Services/Meetings/ProcessingPipelineAutomationGateTests.swift` (`ProcessingPipeline.merged`).

### Retry never overwrites a finished transcript without a saved request

With no saved request, Retry does not destroy a completed transcript just to avoid being a no-op; the Process menu stays there for a deliberate redo.

Where: `LinuxWindows/crates/lokalbot-core/src/meeting_review.rs` (`retry_work`), `LokalBotTests/Services/Meetings/ProcessingPipelineAutomationGateTests.swift` (`ProcessingPipeline.retryWork`).

### A job that committed its transcript is never transcribed again

A parked job that got as far as its notes has committed its transcript, so it goes on without asking for one: transcribing again would cost as long as the first time and replace a transcript people may have corrected. `Job::resumed` drops a finished transcription the same way at launch.

Where: `LinuxWindows/crates/lokalbot-engine/src/pipeline.rs` (`Inner::park`).

### A new transcript moves the notes written from the old one aside

When a fresh transcription differs from the saved transcript, the summary, claims and outcomes written from the old one move to `*.previous.*` first, so they are not shown, searched or asked about as current until notes are written again.

Where: `LinuxWindows/crates/lokalbot-core/src/library.rs` (`Library::save_new_transcript`).

### The port treats saved outcomes as current

macOS treats outcomes whose `transcriptRevision` no longer matches the transcript's SHA-256 (over Swift's exact JSON bytes) as stale. The port cannot reproduce those bytes, so it does not check the revision and relies on its own new transcriptions moving outcomes aside.

Where: `LinuxWindows/crates/lokalbot-core/src/library.rs` (`Library::outcomes`), `LinuxWindows/crates/lokalbot-core/src/model/outcomes.rs` (`MeetingOutcomes.transcript_revision`).

## Library, merging and deletion

### Merging builds a new meeting and leaves the sources intact

The merged meeting is the selected range of each completed source laid end to end. Source folders are never removed or changed beyond a marker that folds them into the merged meeting, so the library shows one row instead of duplicates and Undo can bring them back. Speaker keys are prefixed with their source, so "Me" in one recording cannot silently claim a voice in another.

Where: `LinuxWindows/crates/lokalbot-core/src/merge.rs`, `LokalBot/Services/Meetings/MeetingMergeService.swift` (`MeetingMergeService`), `LokalBot/Models/Meetings/Meeting.swift` (`Meeting.mergedSourceMeetingIDs`).

### Merged audio is transcribed again before any summary

A partial merged transcript must never satisfy the summary, so the joined audio is transcribed first and every source range is represented; this also handles two audio-only sources. In source intervals that had text but no audio the already merged transcript is kept, because silence in the concatenated audio would otherwise erase that source.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/dialogs.rs` (`MergeSheet`), `LokalBot/AppState.swift` (`AppState.mergeMeetings`), `LokalBot/Services/Meetings/MeetingMergeService.swift` (`MeetingMergeService.preservingTranscriptOnlySources`).

### Search tombstones are committed before the library or a merge marker changes

A merge tombstones both search indexes (FTS and embeddings share one tombstone table) before publishing the folded library, so it cannot leave searchable source rows behind if the app exits right after; the retry loop remains for a transient SQLite failure. Restoring a merged source commits its recovery before clearing the source's merge marker in `meta.json`, so an interrupted or failed repair always keeps enough to retry.

Where: `LokalBot/AppState.swift` (`AppState.mergeMeetings`), `LokalBot/Services/Search/SearchIndex.swift` (`SearchIndex.restoreMergedSource`).

### Merge markers are repaired when the library loads, never during a live session

On load, a merged meeting's source list covers a source marker an interrupted merge never wrote, and a source whose merged meeting is gone is shown again; a writable library saves those repairs, as `StorageManager.loadAllMeetings` does on macOS. Enumeration during a live session must never run startup orphan repair.

Where: `LinuxWindows/crates/lokalbot-core/src/library.rs` (`Library::list_meetings`), `LokalBot/Services/Storage/StorageManager.swift` (`StorageManager.loadAllMeetings`), `LokalBot/AppState.swift` (`AppState.undoMerge`).

### Deleting a merged meeting removes its sources first

Unlike Undo, permanent deletion removes every retained descendant before its parent, so an interrupted delete leaves the surviving sources folded and a retry skips those already gone. Overnight memory built from them is withdrawn first.

Where: `LinuxWindows/crates/lokalbot-core/src/library.rs` (`Library::delete_meeting`), `LokalBot/Services/Storage/StorageManager.swift` (`StorageManager.deletionOrder`).

### A meeting leaves the UI only after its folder is deleted

Callers remove a meeting from in-memory and UI state only after the folder delete succeeds; swallowing the filesystem error made failed deletions reappear on the next launch.

Where: `LokalBot/Services/Storage/StorageManager.swift` (`StorageManager.deleteMeeting`).

### The meeting being recorded is never deleted

The recorder is still writing into its folder.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/model.rs` (`deletable`).

### Stale overlapping library reloads are discarded

Library reads overlap, and a slower, older one would bring back a meeting that a newer one no longer lists.

Where: `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppData::reload`).

### Recording finalization keeps the user's edits

The latest durable metadata wins for user-editable fields; finalization fills only the capture facts an older in-progress `meta.json` cannot know yet.

Where: `LokalBot/Services/Recording/RecordingController.swift` (`RecordingController.mergingFinalization`).

### A damaged meeting length gives the start time

A length the calendar cannot hold (a damaged `meta.json`) gives the meeting's start itself, because chrono's `+` panics.

Where: `LinuxWindows/crates/lokalbot-core/src/model/meeting.rs` (`Meeting::started_plus`).

## Importing meetings

### An imported meeting appears only once it is complete

Audio is converted beside the library, moved into a reserved folder, and `meta.json` is written last, so the library never lists a half-made meeting; on Windows and Linux the file's audio becomes the system track. A meeting read from another app keeps the source's transcript as `transcript.json` and its notes as `summary.md`, with an untouched copy in `imported-notes.md`, and the source files are only read.

Where: `LinuxWindows/crates/lokalbot-engine/src/library_ops.rs` (`import_recording`), `LokalBot/Services/Meetings/ExternalMeetingWriter.swift` (`ExternalMeetingWriter`).

### Imported meetings get stable IDs from their source

The same meeting read twice, from the same or a newer export, gets the same source id, so importing again skips it: the source's own id when there is one, otherwise a hash of what can't change, such as the start time and title. The LokalBot meeting id is derived from the source, so an import interrupted after its audio was saved is still recognized.

Where: `LokalBot/CLISupport/MeetingImport/ExternalMeeting.swift` (`ExternalMeeting.sourceID`), `LokalBot/Services/Meetings/ExternalMeetingWriter.swift` (`ExternalMeetingWriter.meetingID`).

### Granola is imported only from what it exports

Granola keeps its own data on the Mac encrypted (`cache-v6.json.enc`, `granola.db`), so LokalBot never opens it and reads only what Granola hands over: the historical data export (Settings → Profile → Export historical data → Generate CSV, a `.csv` or a `.zip` of them), a copied note saved as `.md` or `.txt`, or a copied transcript. Transcript lines keep Granola's labels: "Me" for the microphone, "Them" for system audio, a display name from speaker tags, or "Speaker A" from diarization. Granola keeps no audio and no line times, so these meetings have neither.

Where: `LokalBot/CLISupport/MeetingImport/Readers/GranolaMeetingReader.swift` (`GranolaMeetingReader`).

### Other apps' databases are opened immutable

MacWhisper's database is opened with `immutable=1`, which never creates `-wal` or `-shm` files beside it. Its GRDB write-ahead log persists because MacWhisper doesn't fold it back on quit, and an immutable open can't see it, so when the log isn't empty the database and log are copied to a private temporary folder, read there and removed. A Voice Memos recording whose row is still only in the write-ahead log is read from its file, since an immutable read skips the log.

Where: `LokalBot/CLISupport/MeetingImport/Readers/MacWhisperMeetingReader.swift` (`MacWhisperDatabase`), `LokalBotTests/CLISupport/MeetingImport/Readers/VoiceMemosMeetingReaderTests.swift` (`testLibraryFolderRoundTrip`).

### Voice Memos are imported on the microphone track

Voice Memos are recorded on the person's own microphone, so "My microphone is me" applies to them; other sources' recordings are imported as calls.

Where: `LokalBot/Services/Meetings/ExternalMeetingWriter.swift` (`ExternalMeetingWriter.recordingTrack`).

### Audio without an index is converted with precise timing

Without precise timing AVFoundation guesses the length of a file with no index (ADTS, some MP3s) from its first frames and the export stops there: 27 minutes that started loud and went quiet came out as 3.5.

Where: `LokalBot/Services/Meetings/MeetingImportService.swift` (`MeetingImportService.makeMeeting`).

## Context and privacy

### Calendar attendee email addresses stay in local metadata

An attendee matched from the calendar event keeps its email address only in local meeting metadata, so the rename sheet can tell same-named attendees apart. The address is never shown, indexed, exported or prompted: transcript aliases keep the opaque `id`, and the notes prompt's calendar context carries only the scheduled title and invited names.

Where: `LinuxWindows/crates/lokalbot-core/src/calendar/identity.rs`, `LinuxWindows/crates/lokalbot-core/src/model/meeting.rs` (`CalendarParticipantIdentity.email_address`), `LokalBot/Models/Meetings/CalendarParticipantIdentity.swift` (`CalendarParticipantIdentity`), `LinuxWindows/crates/lokalbot-ai/src/notes/mod.rs` (`calendar_lines`).

### The calendar agenda is stripped and kept only when the user turns it on

Joining instructions, links, phone numbers, email addresses and markup are removed from the invitation's agenda. It is kept only when the user turns on agenda use; otherwise it is never persisted.

Where: `LokalBot/Models/Meetings/MeetingGenerationContext.swift` (`CalendarAgenda`).

### Meeting screen context comes from retained screen rows only

What was on screen during a meeting is built from retained screen rows (titles, document names, URLs and times) aligned to its audio; pixels and captured text are not read. Captures expire with screen retention, so this context can shrink.

Where: `LinuxWindows/crates/lokalbot-core/src/meeting_screen.rs`, `LokalBot/Models/Meetings/MeetingScreenContext.swift`.

### Stored page addresses drop their query and fragment

A page chosen by its query or fragment gets no link rather than one that opens the wrong page.

Where: `LinuxWindows/crates/lokalbot-core/src/meeting_screen.rs` (`reopenable_url`).

### Imported meetings take no screen context

The screen during an imported file's time span shows what the user was doing then, not that recording, so it must not reach the notes prompt. A merge keeps every imported source's file names, so the merged meeting stays imported.

Where: `LokalBot/Models/Meetings/Meeting.swift` (`Meeting.importedFileNames`), `LokalBotTests/Services/Meetings/MeetingImportServiceTests.swift` (`testImportedMeetingsTakeNoScreenTitles`).

### The bundled sample meeting stays out of personal memory

The sample meeting ("orders-api/en") is a made-up call with synthetic voices. Ask, search and agents still see it; personal memory (the day, digests, people, projects, action lists, Personal Context) leaves it out.

Where: `LokalBot/Models/Meetings/Meeting.swift` (`Meeting.sampleID`), `LinuxWindows/crates/lokalbot-core/src/model/meeting.rs` (`Meeting.sample_id`), `LokalBot/Models/Meetings/SampleMeeting.swift`.

### Automatic meeting preparation never downloads a model

Automatic preparation must never trigger a surprise multi-gigabyte download; the user can still ask for generation from the card.

Where: `LokalBot/Services/Calendar/UpcomingMeetingPreparation.swift` (`UpcomingMeetingLocalGenerationPolicy.shouldGenerateAutomatically`).

## Follow-ups and note export

### Follow-up drafts are explicit, grounded, local and never sent

A follow-up email draft is written only when the user asks, only from the meeting's recap, decisions, corrected actions and open questions, and LokalBot never sends it: the user reviews it, copies it or saves it with the meeting. Only a Think model running on this computer may write it: `FollowUpDraftGenerator.generate` takes any engine, but `FollowUpDraftSheet` refuses unless Think runs on this Mac (`UpcomingMeetingLocalGenerationPolicy`), and the port's `AskWorker.write_follow_up` does the same. The outline stays available either way.

Where: `LinuxWindows/crates/lokalbot-ai/src/follow_up.rs`, `LinuxWindows/crates/lokalbot-app/src/pages/meetings/follow_up.rs`, `LinuxWindows/crates/lokalbot-engine/src/ask.rs` (`AskWorker.write_follow_up`), `LokalBot/Services/Notes/FollowUpDraftGenerator.swift` (`FollowUpDraftGenerator`), `LokalBot/Views/Meetings/FollowUpDraftSheet.swift`.

### Exported meeting notes become the person's once they change them

The optional one-note-per-meeting export writes to a folder the person picks, such as an Obsidian vault or a Logseq graph's `pages` folder, and a note keeps the name it was first written with, so links to it survive a renamed meeting. A note is refreshed only while it still holds the bytes LokalBot wrote (the same hash sidecar as the daily export). A note the person edited, deleted or moved is left alone, and that meeting is not written again. Deleting a meeting in LokalBot leaves its note in place, like every other export.

Where: `LinuxWindows/crates/lokalbot-engine/src/exports/meeting_notes.rs`, `LokalBot/Services/Meetings/MeetingNoteExportService.swift` (`MeetingNoteExportService`).

### Export sources are stamped before they are read

A file that changes after its stamp is taken changes the next pass's stamp too, so the change is exported.

Where: `LinuxWindows/crates/lokalbot-engine/src/exports/meeting_notes.rs` (`export`).

## Meeting page

### Mic and system tracks play on separate players

`mic.m4a` and `system.m4a` were recorded together and play from the same offset, each on its own `AVAudioPlayer`, with the OS mixing them at the output device. The two files routinely differ in sample rate (device-native vs the 48 kHz tap) and channel count (mono vs stereo mixdown), and one `AVMutableComposition` with an `AVAudioMix` through `AVPlayer` garbles the mismatched track during real-time playback. Offline export can still use the composition (`MeetingAudioAsset`).

Where: `LokalBot/Services/Meetings/MeetingPlayer.swift` (`MeetingPlayer`), `LokalBot/Services/Meetings/MeetingAudioAsset.swift`.

### The audio reloads after a recording ends

A player opened while the recording was still being written knows only its first part.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/mod.rs` (`MeetingsPage::load_doc`).

### Undrawn transcript rows are revealed by putting the row before them at the top

Item 0 is the header, so row r is item r + 1. Rows the list has not drawn yet (the transcript tab was not open) have no height and revealing them would not move, so the row before is scrolled to the top instead.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/mod.rs` (`MeetingsPage::reveal_focus`).

### In-page search cuts match ranges on character boundaries

Lowercasing can change byte length: "İ" lowercases to two chars.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/page_search.rs` (`ranges_cut_on_character_boundaries_when_lengths_change`).

### A summary refresh after renaming speakers says where it runs

The refresh is offered only after speaker names changed, and the summary written before stays on the page until the refresh finishes. Where the refresh runs is said beside the button, because that is the consent boundary.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/meetings/detail.rs` (`MeetingsPage::render_refresh_banner`).

### Live preview transcription is an explicit opt-in

Opening a live meeting does not load a model or start speech inference; starting the preview does. The preview is undiarized and the pipeline transcript replaces it after the meeting, while quick notes are saved to `notes.md` in the meeting folder and folded into the summary. With fast live text on, the preview streams to Muse Voice Transcribe and shows each turn as it is spoken.

Where: `LokalBot/Views/Meetings/LiveMeetingDetailView.swift` (`LiveMeetingDetailView`).

## Consequences

- Model output is a claim. Speakers, owners, due dates and cited rows come from the transcript and the app's checks, so a prompt or schema change must keep the validation and repair paths, and saved notes parts depend on the part plan staying stable.
- Many steps are ordered for crash safety: `meta.json` written last, checkpoints removed after notes are saved, search tombstones committed before publishing, sources deleted before the merged meeting, attempts counted at start. Keep the order when changing them.
- The Windows and Linux port reads and writes the Mac's on-disk formats and owner values but cannot check `transcriptRevision`; a format change needs both sides. Calendar emails, agenda text, screen pixels, imported meetings and the sample meeting each have a privacy or memory boundary to keep.
