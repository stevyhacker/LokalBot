# Importing meetings from other apps

Part of the [development guide](../../DEVELOPMENT.md).

LokalBot brings in meetings that another app already holds — notes, transcripts, action items, and recordings — so a person can move their history onto their own disk and stop paying for the cloud copy. Sources: Granola, Otter, Fireflies, Fathom, Screenpipe, Zoom, Voice Memos, and MacWhisper. Importing audio and video files you already have stays [Import Recording](recording.md).

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `ExternalMeeting`, `ExternalMeetingSource`, `ExternalMeetingReader` | `LokalBot/CLISupport/MeetingImport/ExternalMeeting.swift` | The shape every source is read into, the list of sources, and the reader protocol. Shared with `lokalbot-cli`. |
| Readers | `LokalBot/CLISupport/MeetingImport/Readers/<Source>MeetingReader.swift` | One per source. They only read: no writes, no moves, databases opened read-only (`immutable=1`). |
| Shared parsing | `LokalBot/CLISupport/MeetingImport/ExternalImportText.swift` | Timestamps, ISO dates, text decoding, folder walks, stable ids, and `SubtitleTranscript` for SRT and WebVTT. |
| `ExternalMeetingReaders.scan` | same file as the model | Runs a source's reader over files, folders, and `.zip` archives (unpacked with `ditto` into a temporary folder), drops empty meetings and repeated source ids, and collects unreadable files as problems. Its `cleanup` removes the unpacked archives and any recording a reader staged in a `lokalbot-import-…` temporary folder (MacWhisper unpacks the one inside a `.whisper` document). |
| `ExternalMeetingWriter` | `LokalBot/Services/Meetings/ExternalMeetingWriter.swift` | Turns one `ExternalMeeting` into a meeting folder. |
| `AppState.runExternalImport` | `LokalBot/Services/Meetings/AppState+MeetingImport.swift` | Scans, skips what is already in the library, writes the rest, then indexes or queues them. |
| Menu and panel | Recording → Import Meetings From → *app*… (`ExternalImportPanel` in `Views/Meetings/RecordingImport.swift`) | The person picks the export or data folder; choosing is the consent. |
| `lokalbot-cli import` | `CLI/Commands/ImportCommand.swift` | `--dry-run` previews locally; otherwise asks the app, which asks the person. |

## What a meeting looks like after import

- **Id:** `ExternalMeetingWriter.meetingID` derives a UUID from `source/sourceID`, so the same source meeting always gets the same id.
- **`meta.json`:** `importSource` `{app, id, importedAt}` records the source and its id; `importedFileNames` names the file it came from, which keeps screen context away from it like any imported recording (`Meeting.isImported`). `appName` is the source's name. Participants become `participantNameHints`.
- **Transcript:** each named speaker gets a stable label (`them 1`, `them 2`, …) with their name as a speaker alias, so renaming works as for recorded meetings; lines a source marks as the person's own microphone are `me`. Lines without times are laid out one after another at about 150 words a minute and marked `coarse`, which keeps them out of anything that trusts exact timing. The engine is `import-<source>`.
- **Notes:** the source's notes become `summary.md`, followed by its action items unless the notes already list them. An untouched copy goes to `imported-notes.md`, so writing LokalBot notes for the meeting later never loses the original.
- **Recordings:** a meeting that comes with audio (Zoom and Voice Memos recordings, MacWhisper documents, and the MP3 or MP4 a person downloads beside an Otter, Fireflies, or Fathom export) goes through `MeetingImportService.importExternalRecording` first, then gets the source's transcript. Call audio goes on the system track like any imported file; Voice Memos are the person's own microphone, so they go on the mic track like a paired phone's recording. Only a recording with no transcript is queued for transcription.
- **No audio, no transcription:** `MissingTranscription` only queues meetings that have audio, so a text-only import is never re-transcribed.
- **Atomic:** `meta.json` is written last; the library lists only folders with it, so an interrupted import leaves nothing half-made. A failed text-only write removes its folder.
- **Indexing:** each written meeting goes through `AppState.meetingArtifactsWritten` — outcomes, full-text and semantic search, and day memory — the same path processing ends on.

Imported meetings are not summarized automatically. Two years of transcripts would keep the Think model busy for hours, and most sources already bring their own notes. The person can ask for LokalBot notes on any meeting.

## Re-importing

`runExternalImport` skips a meeting when the library already has its `importSource` key or its derived id, counting merged-away sources too. Importing the same export twice, or a newer export that overlaps an older one, adds only what is new. Nothing is ever updated in place: a meeting edited in the source after import keeps its imported version.

## Consent

`lokalbot-cli` and the MCP server stay read-only. An import changes the library, so:

- **In the app,** choosing files in the panel is the request.
- **From the terminal,** `lokalbot-cli import <source> [paths…]` sends `meetings.import` over the control socket (needs **Allow external agents to change LokalBot settings**). `AppControlHandler` reads the files itself — the CLI only names them, as absolute paths, at most 100 — and counts what is new. With nothing new, or with `dryRun`, it returns the counts. Otherwise it queues a `SettingsApprovals` request with subject `.meetingImport`, whose card shows the paths and counts in full, and replies `needs_approval`. Approving starts the import through `applyApprovedImport`, which reads the files again. `--wait` follows the request like `config set`: exit 0 approved, 3 waiting, 4 declined, 5 expired.
- `lokalbot-cli import <source> --dry-run` reads the files in the CLI process and prints titles, dates, and counts, never notes or transcripts. It needs neither the app nor any grant, since it reads only what the person names in their own terminal.

There is no MCP import tool.

## Privacy

Importing reads files on this computer that the person chose, or the source's own data folder when it has one LokalBot can read. Nothing is downloaded and no account is contacted: there are no API-token importers (see the open decision below). The source files are never changed. The log records counts only — never titles, paths, or content.

## Sources

| Source | Reads | Where it comes from | Status |
| --- | --- | --- | --- |
| Granola | The historical data export (`.csv`, or the emailed `.zip` of CSV parts: `document_id`, `document_title`, `document_created`, `summary`, `notes`, `transcript`); a note or transcript copied from Granola and saved as `.md`/`.txt`. Granola's own `cache-v6.json.enc` and `granola.db` are encrypted and never read | Settings → Profile → Export historical data → Generate CSV, then download from Granola's email; or Copy notes / the transcript panel's copy button, pasted into a file | Partial: the export has no audio, durations, line times, or structured participants, and starts are note-creation times; transcript labels (Me/Them/names) are parsed defensively because their exact CSV form is undocumented |
| Otter | TXT, DOCX and SRT exports, one file, a folder, or a bulk-export .zip, plus a same-named MP3 from the Audio toggle; PDF is reported, not read | Conversation → three dots → Export (TXT, DOCX or SRT with Show speaker names and Show timestamps); on Business or Enterprise, select conversations in My Conversations → Export, and Otter emails a ZIP | Partial: PDF unread; layout of summary sections and DOCX inferred, not confirmed; no Otter id, so an edited, re-exported transcript imports as new |
| Fireflies | Per-meeting downloads: Transcript as JSON, SRT, CSV or MD; Summary as JSON or MD; Audio MP3 or Video MP4, joined into one meeting by name or folder. Also API-shaped transcript JSON, and the account data export .zip (TXT transcripts and summaries, JSON metadata, MP3) | A meeting's Download icon at the bottom → Transcript / Summary / Audio (Pro plan or higher), or Fireflies' account data export, emailed as a .zip | Partial: PDF and DOCX aren't read; Fireflies doesn't document its JSON, CSV, MD or export layouts, so they're parsed defensively and haven't been checked against real downloads |
| Fathom | Text pasted from a call's Copy Transcript and Copy Summary (`.txt`/`.md`, plain or Markdown), the MP4 from Download Video, and meeting JSON shaped like Fathom's API and webhooks (one meeting, a list response's `items`, or an array); folders and `.zip` | Fathom has no export file: for each call, Copy Transcript / Copy Summary and paste into files, then three-dot menu → Download Video; JSON from the person's own API or webhook scripts | Partial: there is no bulk export, the copied header has a day but no year or time, and videos join calls by file name |
| Screenpipe | `~/.screenpipe`: `db.sqlite`, or the `storage/<generation>/index.sqlite` that `storage.json` names (the retained original `db.sqlite` is read second); a standalone `.sqlite` copy. Reads `meetings` (title, times, attendees, note and its action items), live `meeting_transcript_segments`, and background `audio_transcriptions` with `speakers`; input-device lines are the person's own; older audio is split into conversations at 5-minute silences; text only, no audio chunks | No export: the person picks the data folder (the default location) after choosing Quit screenpipe; for meetings whose text Screenpipe compressed, `screenpipe storage export-sqlite ~/.screenpipe <file>` writes a file to import | Partial: transcript text moved into compressed (Parquet) storage can't be read, so those meetings are skipped and reported; lines still only in the `-wal` file of a running Screenpipe are not seen |
| Zoom | Computer-recording folders in `~/Documents/Zoom/<YYYY-MM-DD HH.MM.SS Topic>/` (audio_only/audio<digits>.m4a, else zoom_N/video<digits>.mp4, plus any .vtt or saved captions .txt) and cloud downloads `GMT<stamp>_Recording.m4a/.mp4/.transcript.vtt/.cc.vtt` grouped by stamp; chat is skipped | Read in place from the Zoom app's recording folder (Settings › Recording › Local recording storage), or downloaded from the web portal's Recordings & Transcripts › Cloud recordings (Audio only + Audio transcript) | Partial: folder names and saved-caption .txt layouts aren't documented by Zoom (parsed defensively); cloud downloads have no topic; only the first segment of a restarted recording; no notes or action items in Zoom's files |
| Voice Memos | `.m4a`/`.qta` recordings (audio, plus the transcript Voice Memos embeds as a `tsrp` atom or `com.apple.VoiceMemos.tsrp` metadata) and `CloudRecordings.db` (titles, dates, lengths, ids; read-only, `immutable=1`) in `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings` | Drag recordings from Voice Memos to a Finder window and import the files, or choose the Recordings folder in the import panel (macOS privacy protection requires choosing it there or Full Disk Access) | Partial: Apple doesn't document the format, so the reader follows reverse-engineered descriptions and wasn't checked against a real library; recordings only in iCloud and rows not yet out of the database's write-ahead log are reported or read from their files; no speakers |
| MacWhisper | `.whisper` documents (transcript, speakers, recording); the library `~/Library/Application Support/MacWhisper/Database/main.sqlite` with recordings from `ExternalMedia` (default location); SRT, WebVTT, Segments/structured JSON, CSV, TXT, Markdown, and DOCX exports, plus a same-named recording beside an export | File › Save As… or drag a transcript from the history sidebar into Finder for `.whisper`; the Export button for the rest; or pick `main.sqlite` (nothing to export) | Partial: formats confirmed from third-party readers, not vendor docs; no "me" lines; meetings kept as separate mic/app tracks import without a recording; podcasts, downloads, HTML/PDF skipped |

All eight readers parse defensively: none of these vendors documents its export layout fully, so formats come from vendor help pages, open-source readers, and the apps' own bundles, and are cited in each reader's commit. No real export or library was read while building them.

## Open decisions

- **Account APIs.** Several sources could hand over a whole history without an export, but each would be LokalBot's first importer that contacts another company's server with the person's credential. Each needs a decision, a PRIVACY.md section, a stored-credential design, and an approval like any remote origin. None is built:
  - Granola: public REST API (notes, transcripts with speakers and times, attendees; Business/Enterprise API keys) and an MCP server.
  - Otter: an account API with plan limits to check; third-party tools use an unofficial web API, which LokalBot shouldn't.
  - Fireflies: GraphQL API with a Bearer key on every plan; signed audio and video links need Pro or higher.
  - Fathom: REST API with an API key (`GET /meetings` with transcripts, summaries, and action items); the reader already parses that JSON when a person saves it.
  - Zoom: the Cloud Recording API, which needs a Zoom Marketplace OAuth app.
  - Screenpipe: its local HTTP API on localhost (with `screenpipe auth token`) would recover meetings whose text Screenpipe moved into compressed Parquet storage.
- **Mic and app tracks as one recording.** Zoom recordings restarted mid-call and MacWhisper meetings kept as separate mic and app tracks import only one or none of their audio; `ExternalMeeting.audioURL` is a single file.

## Windows and Linux

Not ported yet; meetings imported on a Mac open there like any other meeting. `meta.json`'s `importSource` survives the Rust app today because `Meeting` keeps unknown keys in `extra` (`lokalbot-core/src/model/meeting.rs`). The port:

1. **Model and readers** in `lokalbot-core` as `import::external`: `ExternalMeeting`, the source list, and one reader module per source. They need only `serde_json`, the workspace's `rusqlite` (opened with `immutable=1`), and `zip` (already used by `lokalbot-agent`); the sources that are files on disk (Otter, Fireflies, Fathom, Granola exports, MacWhisper exports, Zoom folders) carry over unchanged, while Screenpipe's database lives in `%USERPROFILE%\.screenpipe` / `~/.screenpipe`. Voice Memos is Mac-only. Port the Swift tests' synthetic fixtures with them.
2. **Writer** in `lokalbot-engine::library_ops` beside `import_recording`, which already reserves a folder, sets `imported_file_names`, and moves converted audio; add `import_source` as a typed field on `Meeting`, the same derived UUID, `transcript.json`/`summary.md`/`imported-notes.md`, and the same skip rules.
3. **UI**: an "Import meetings from" menu next to the existing recording import in `lokalbot-app` (`state.rs::import_recordings`).
4. **CLI**: the Rust `lokalbot-cli` gets `import` with the same flags and the same approval through its settings-control channel.

## Tests

`ExternalMeetingWriterTests` (folder shape, speakers, coarse timing, notes, ids, plan counts), `ExternalImportTextTests` and `ExternalMeetingReadersTests` (parsing, zip, sources), `MeetingImportApprovalTests` (approval subject), and one `<Source>MeetingReaderTests` per source. Every fixture is synthetic and built inside the test; no real export is committed.
