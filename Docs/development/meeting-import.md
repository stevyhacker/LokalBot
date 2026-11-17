# Importing meetings from other apps

Part of the [development guide](../../DEVELOPMENT.md).

LokalBot brings in meetings that another app already holds — notes, transcripts, action items, and recordings — so a person can move their history onto their own disk and stop paying for the cloud copy. Sources: Granola, Otter, Fireflies, Fathom, Screenpipe, Zoom, Voice Memos, and MacWhisper. Importing audio and video files you already have stays [Import Recording](recording.md).

## Pieces

| Piece | Where | What it does |
| --- | --- | --- |
| `ExternalMeeting`, `ExternalMeetingSource`, `ExternalMeetingReader` | `LokalBot/CLISupport/MeetingImport/ExternalMeeting.swift` | The shape every source is read into, the list of sources, and the reader protocol. Shared with `lokalbot-cli`. |
| Readers | `LokalBot/CLISupport/MeetingImport/Readers/<Source>MeetingReader.swift` | One per source. They only read: no writes, no moves, databases opened read-only (`immutable=1`). |
| Shared parsing | `LokalBot/CLISupport/MeetingImport/ExternalImportText.swift` | Timestamps, ISO dates, text decoding, folder walks, stable ids, and `SubtitleTranscript` for SRT and WebVTT. |
| `ExternalMeetingReaders.scan` | same file as the model | Runs a source's reader over files, folders, and `.zip` archives (unpacked with `ditto` into a temporary folder), drops empty meetings and repeated source ids, and collects unreadable files as problems. |
| `ExternalMeetingWriter` | `LokalBot/Services/Meetings/ExternalMeetingWriter.swift` | Turns one `ExternalMeeting` into a meeting folder. |
| `AppState.runExternalImport` | `LokalBot/Services/Meetings/AppState+MeetingImport.swift` | Scans, skips what is already in the library, writes the rest, then indexes or queues them. |
| Menu and panel | Recording → Import Meetings From → *app*… (`ExternalImportPanel` in `Views/Meetings/RecordingImport.swift`) | The person picks the export or data folder; choosing is the consent. |
| `lokalbot-cli import` | `CLI/Commands/ImportCommand.swift` | `--dry-run` previews locally; otherwise asks the app, which asks the person. |

## What a meeting looks like after import

- **Id:** `ExternalMeetingWriter.meetingID` derives a UUID from `source/sourceID`, so the same source meeting always gets the same id.
- **`meta.json`:** `importSource` `{app, id, importedAt}` records the source and its id; `importedFileNames` names the file it came from, which keeps screen context away from it like any imported recording (`Meeting.isImported`). `appName` is the source's name. Participants become `participantNameHints`.
- **Transcript:** each named speaker gets a stable label (`them 1`, `them 2`, …) with their name as a speaker alias, so renaming works as for recorded meetings; lines a source marks as the person's own microphone are `me`. Lines without times are laid out one after another at about 150 words a minute and marked `coarse`, which keeps them out of anything that trusts exact timing. The engine is `import-<source>`.
- **Notes:** the source's notes become `summary.md`, followed by its action items unless the notes already list them. An untouched copy goes to `imported-notes.md`, so writing LokalBot notes for the meeting later never loses the original.
- **Recordings:** a source that has audio (Zoom, Voice Memos, MacWhisper) goes through `MeetingImportService.importExternalRecording` first, then gets the source's transcript. Only a recording with no transcript is queued for transcription.
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

<!-- Filled in per source as the readers land. -->

| Source | Reads | Where it comes from | Status |
| --- | --- | --- | --- |
| Granola | | | |
| Otter | | | |
| Fireflies | | | |
| Fathom | | | |
| Screenpipe | | | |
| Zoom | | | |
| Voice Memos | | | |
| MacWhisper | | | |

## Open decisions

- **Account APIs.** Otter, Fireflies, Fathom, and Granola offer APIs that could pull a whole history with a token, without an export. That would be LokalBot's first importer that contacts another company's server with the person's credentials, so it needs a decision, a PRIVACY.md section, and an approval like any remote origin. Not built.

## Windows and Linux

Not ported yet. The readers are pure Foundation and SQLite and would move to a `lokalbot-import` crate beside `lokalbot-core`; the writer maps to `library_ops.rs`, which already writes imported recordings, and `meta.json`'s `importSource` survives the Rust app today through `Meeting.extra`.

## Tests

`ExternalMeetingWriterTests` (folder shape, speakers, coarse timing, notes, ids, plan counts), `ExternalImportTextTests` and `ExternalMeetingReadersTests` (parsing, zip, sources), `MeetingImportApprovalTests` (approval subject), and one `<Source>MeetingReaderTests` per source. Every fixture is synthetic and built inside the test; no real export is committed.
