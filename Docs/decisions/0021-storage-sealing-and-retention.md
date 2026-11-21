# 0021. Storage, sealing and retention

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers where LokalBot keeps its data and how it protects and expires it. It includes the library layout that both the Mac app and the Windows and Linux app read and write, app identities and their migration, keys in the system credential store, files sealed with AES-GCM, overnight memory that is withdrawn when its evidence changes, screen and activity retention, and what logs and diagnostics may hold. The phone companion keeps its own protected copy. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Library location and storage

### The Mac library is rooted at the bundle id, not at "LokalBot"

The Mac library lives in `~/Library/Application Support/me.dotenv.LokalBot/`, with meetings under `meetings/YYYY/MM/dd-slug/`. An unrelated app may own `~/Library/Application Support/LokalBot/` on some machines, and its `Meetings` folder would collide with our `meetings` on the default case-insensitive filesystem.

Where: `LokalBot/Services/Storage/StorageManager.swift` (`StorageManager`).

### Mac model stores and the agent runtime ignore the storage-root override; catalog GGUFs follow it

Transcription model stores and the agent runtime stay in the app identity's Application Support even under `LOKALBOT_STORAGE_ROOT` isolation, so fixture runs share them only with their own app identity (llama-server state is in `localServerSupport`). Catalog GGUFs are the exception: they download under the overridable library root (`ModelCatalog.localURL`), and `Scripts/test/e2e.sh` symlinks the real `models/` into its temp root so they stay shared too.

Where: `LokalBot/Models/App/AppDirectories.swift` (`AppDirectories.applicationSupport`).

### Agent Mode's sessions and tasks are library data; its runtime is a machine cache

On Windows and Linux the Agent Mode runtime (Bun, pi and LokalBot's pi extension) is a machine-local cache in `<library>/runtimes/`, next to the llama.cpp runtime, not user data. pi's session files, the task list and pi's own configuration live in `<library>/agent/`, where macOS keeps them, so they follow `LOKALBOT_STORAGE_ROOT`. Task metadata (`tasks.json` in `<library>/agent/sessions`) is kept apart from pi's append-only conversation, so archiving never deletes history and browsing a task never needs a running process.

Where: `LinuxWindows/crates/lokalbot-agent/src/layout.rs`, `LinuxWindows/crates/lokalbot-agent/src/tasks.rs`.

### Model archives may contain only ordinary files and directories

Paths and entry types are validated before a model archive is extracted; links and special files are rejected.

Where: `LokalBot/Engines/SherpaOnnxRuntime.swift` (`ArchiveExtractor.extractBzip2Tar`).

### The library is owner-only

The Windows and Linux app opens the library owner-only (0700 on Unix), which also repairs an older library whose files were created world-readable under the usual umask.

Where: `LinuxWindows/crates/lokalbot-core/src/library.rs` (`Library::open`).

### One app process per library, held by a kernel lock

A second copy writing the same activity database, journals and schedules double-counts tracked time and races scheduled model runs, so each library is held by one process through a kernel lock. The kernel releases it when the holder exits, including after a crash.

Where: `LokalBot/Support/LibraryInstanceLock.swift` (`LibraryInstanceLock`).

### SQLite runs in WAL mode with `synchronous = NORMAL`

Several app components hold independent connections to the same database; WAL lets readers proceed during a writer's transaction. `NORMAL` is the durability trade-off that suits indexes and queues that can be rebuilt locally. The raw handle is configured before `db` is assigned, so a failed failable initializer has exactly one close path.

Where: `LokalBot/Services/Storage/SQLiteDatabase.swift` (`SQLiteDatabase.init`).

### Database backups are taken out of WAL mode

A backup inherits WAL mode from the source header, so its journal mode is normalized while it is still writable. A read-only verifier can then open the standalone file without needing a new WAL/SHM pair in the recovery directory.

Where: `LokalBot/Services/Storage/SQLiteDatabase.swift` (`SQLiteDatabase.backup`).

### The legacy screen text table is rebuilt, not altered

FTS5 tables can't add columns, so a legacy (`text`, `ts`, `app`) table is rebuilt, linking each row to the capture taken within a second of it.

Where: `LinuxWindows/crates/lokalbot-core/src/screen.rs` (`screen::migrate`).

### Wiping a synced library vacuums and empties the WAL

Wiping rebuilds the file without the freed pages, then moves the result out of the WAL into the main file and empties the WAL, so old text leaves the file.

Where: `LinuxWindows/crates/lokalbot-sync/src/client/store.rs` (`ClientStore::wipe_library`).

## A format both apps read

### The Windows and Linux app writes the Mac's library format

One folder per meeting with `meta.json`, `transcript.json`, `summary.md`, `outcomes.json` and friends, plus `lokalbotv3.sqlite` for search indexes, activity blocks and screen context, as the Mac's `StorageManager.swift` lays it out, so a library written by either app opens in the other. Audio tracks are the one difference: Windows and Linux record, import and merge into 16 kHz 16-bit `mic.wav`/`system.wav`, the Mac writes `mic.m4a`/`system.m4a`, and each app reads the other's, so a library shared with a Mac still plays and transcribes those meetings.

Where: `LinuxWindows/crates/lokalbot-core/src/lib.rs`, `LokalBotTests/Services/Meetings/MeetingAudioAssetTests.swift` (`testWindowsAndLinuxWAVTracksAreReadWhenNoAACTrackExists`).

### Shared JSON files use the Mac's `Codable` encoding

Files both apps read keep the keys and encoding of the Swift `Codable` types: dates as seconds since 2001-01-01, uppercase UUID strings, `file://` URLs, sets as arrays, and empty optionals left out. This covers Agent Mode's `tasks.json`, learned autocomplete examples (`CotypingLearningExample`) and the voice store's state and profile.

Where: `LinuxWindows/crates/lokalbot-agent/src/tasks.rs`, `LinuxWindows/crates/lokalbot-ai/src/autocomplete/learning.rs` (`Example`), `LinuxWindows/crates/lokalbot-core/src/voice/tests.rs` (`reads_the_macs_state_and_profile_json`).

### ISO dates are written with whole seconds

`meta.json`, chats and projects get ISO-8601 dates with whole seconds and a `Z` suffix, because Swift's `ISO8601DateFormatter` rejects fractional seconds. Readers accept fractions anyway.

Where: `LinuxWindows/crates/lokalbot-core/src/time.rs` (`iso_seconds`).

### Unknown `meta.json` keys are kept

Keys this build doesn't know, written by macOS or a newer release, are kept as they are, so saving `meta.json` never drops them.

Where: `LinuxWindows/crates/lokalbot-core/src/model/meeting.rs` (`Meeting.extra`).

### The port's evidence revision hash is local to the port

The evidence revision (`Transcript.evidenceRevision`) is a SHA-256 over the transcript's sorted-key JSON and identifies the evidence a summary or checkpoint was made from. Its bytes differ from Swift's encoder, so the value is only comparable within the Windows and Linux app.

Where: `LinuxWindows/crates/lokalbot-ai/src/notes/view.rs` (`evidence_revision`).

### Only the recorded hash grants permission to replace a generated file

Exports and routines share one ownership contract: a marker identifies a generated file, and only the recorded hash, kept in a hidden sidecar beside the file, grants permission to replace it, so a file the person edited is never overwritten.

Where: `LokalBot/Services/Storage/GeneratedFileWriter.swift` (`GeneratedFileWriter`), `LinuxWindows/crates/lokalbot-core/src/generated_file.rs`.

## App identity and migration

### The release bundle id is frozen

Existing libraries and Keychain items are keyed by the release identity, so it never changes.

Where: `LokalBot/Models/App/AppIdentifiers.swift` (`AppIdentifiers.appBundleID`).

### Development copies keep their own library and settings

Development builds use `me.dotenv.LokalBot.dev`, with their own Application Support home, identity-scoped runtimes and mutable process markers, so their retention settings can't affect release data. A release-identity app run from Xcode build products (DerivedData or a custom derived-data path) also keeps its own library and settings, so a development copy never writes the installed app's activity, journals or scheduled runs; `LOKALBOT_STORAGE_ROOT` can still point it anywhere.

Where: `LokalBot/Models/App/AppDirectories.swift` (`AppDirectories.applicationSupport`), `LokalBot/Models/App/AppIdentifiers.swift` (`UITestRuntime.isLocalBuild`).

### Identity migration runs first in `main()`, and `AppState` waits for it

A bundle-id rename re-keys the Application Support folder, the login Keychain (service = bundle id) and UserDefaults at once; without migration it looks like total data loss, including screenshots that can't be decrypted because their AES key lived under the old service. `DataMigration` copies all three forward on the first launch after a rename, at the very top of `main()`, before `AppSettings.load()`, `StorageManager()` or any Keychain read, so `StorageManager` doesn't create an empty folder first. `AppState` is never constructed after an incomplete migration: its `StorageManager` would create the destination library and turn a transient failure into a persistent old/new conflict on the next launch. The embedded `lokalbot-cli` doesn't migrate; it reads what the app has already migrated.

Where: `LokalBot/Services/App/DataMigration.swift` (`DataMigration`), `LokalBot/LokalBotApp.swift` (`LokalBotMain.routeStartup`).

### Migration never runs inside an XCTest host

A unit-test run launches the app as its XCTest host, which still executes `main()`. When `XCTestConfigurationFilePath` is set, migration bails before it marks itself done or touches the real library, so `xcodebuild test` never moves the user's data.

Where: `LokalBot/Services/App/DataMigration.swift` (`DataMigration.shouldRun`), `LokalBotTests/Services/App/DataMigrationTests.swift` (`DataMigration.runIfNeeded`).

### Keys are migrated before the encrypted files they open

Identity-scoped keys are prepared before migrated encrypted files are exposed; a denied Keychain read leaves the old library in place.

Where: `LokalBot/Services/App/DataMigration.swift` (`DataMigration.completeMigration`).

### The migrated database is installed with `RENAME_EXCL`, never over a live one

An existing database is never replaced, even one that looks empty: another SQLite connection can commit right after the emptiness check, and replacing its inode cuts that writer off from the active library path. `RENAME_EXCL` makes creation atomic, and a concurrent creator wins unchanged.

Where: `LokalBot/Services/App/DataMigration.swift` (`DataMigration.installDatabaseSnapshot`).

### The `chat-key` repair is its own versioned migration

Chat encryption shipped before the last identity rename, and the old migration left out `chat-key`, so a separate, versioned repair runs even where the main migration marker is already set. While a legacy library still conflicts, the check stays live, so chats copied during a later recovery are validated on the next launch.

Where: `LokalBot/Services/App/DataMigration.swift` (`DataMigration.recoverLegacyChatKeyIfNeeded`).

### The legacy `~/Documents` Whisper cache isn't listed once Application Support has a model

Whisper prepares on every app start for people who use it, and listing the legacy `~/Documents` cache makes macOS ask for Documents access, so it isn't even listed once Application Support has a model.

Where: `LokalBotTests/Engines/TranscriptionModelStoreTests.swift` (`TranscriptionModelStore.migrateLegacyWhisperKitModels`).

## Keys and the credential store

### Secrets live only in the system credential store

API keys (including the OpenAI-compatible server's), private calendar links, mail tokens and the keys that seal screen images and recent dictations live in the system credential store (the Keychain on the Mac, Windows Credential Manager, the Secret Service on Linux), never in `settings.json` or the library. The Meetings page doesn't open the credential store when there is no journal to read.

Where: `LinuxWindows/crates/lokalbot-engine/src/secrets.rs`, `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppEvent::SaveApiKey`), `LinuxWindows/crates/lokalbot-app/src/pages/meetings/model.rs` (`load`), `LokalBot/Services/Email/EmailStore.swift` (`EmailStore`).

### An existing key is never replaced

An AES-256 key is loaded, or created atomically on first use, and an existing item is never updated: a temporary read failure must not be mistaken for absence, and a concurrent creator wins without replacement. Migration writes keys the same way.

Where: `LokalBot/Models/App/AppIdentifiers.swift` (`KeychainSecrets.resolveSymmetricKey`), `LokalBot/Services/App/DataMigration.swift` (`DataMigration.writeData`).

### An unreachable credential store never leads to a new key

The per-install screen image key (Keychain account `screenshot-key`) is created on first use only when asked to, kept only in the credential store, and cached for the life of the process so captures don't ask the store each time. If the store can't be reached no key is created and images are not kept. A new key is read back before use, so a store that silently drops secrets can't leave files nothing can open.

Where: `LinuxWindows/crates/lokalbot-engine/src/secrets.rs` (`screen_image_key`, `sealing_key`).

### Long tokens are split across credential items

The ChatGPT plan's tokens, which Think and Settings keep in the credential store, are split across several items, because Credential Manager keeps at most 1,280 characters in one.

Where: `LinuxWindows/crates/lokalbot-engine/src/secrets.rs` (`install_plan_store`).

### The phone's device key stays on the phone

The phone keeps its long-term X25519 private key and device id in the Keychain for this device only: available after first unlock, so background refresh can sync, and never synchronized to other devices.

Where: `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Platform/DeviceIdentity.swift` (`DeviceIdentity`).

## Sealed files

### Sealed files share one layout, and a file sealed elsewhere is never overwritten

Files are sealed with AES-256-GCM as `nonce (12 bytes) ‖ ciphertext ‖ tag (16 bytes)` (`AES.GCM.SealedBox.combined`). Ask conversations, Personal Context and the dictation learning log share the per-install `chat-key` and use no associated data. A Mac seals the same files with its own Keychain key, so a copied file can't be opened on another install: it reads as an error, is reported, and stays as it is.

Where: `LinuxWindows/crates/lokalbot-core/src/sealed.rs`, `LinuxWindows/crates/lokalbot-core/src/voice/tests.rs` (`sealed_files_use_the_macs_layout_and_a_foreign_key_is_never_overwritten`).

### The voice store binds each file to its `/`-separated path

The voice store uses the file's path under its root as associated data, always `/`-separated, so a file's associated data never depends on the system that wrote it.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/store.rs` (`Store.seal`), `LinuxWindows/crates/lokalbot-core/src/voice/tests.rs` (`sealed_files_use_the_macs_layout_and_a_foreign_key_is_never_overwritten`).

### One sealed file per conversation; plaintext goes only after its sealed copy lands

Each Ask conversation is `chats/<UUID>.json.enc` under the `chat-key`: encode, AES-GCM seal, atomic write. Plaintext `chats/<UUID>.json`, written by earlier versions of the Windows and Linux app and the Mac's first versions, still opens and is re-sealed, and the save reports whether the sealed file landed so the plaintext is never discarded before its encrypted replacement exists. An encrypted copy wins over leftover plaintext, and a sealed file that can't be opened (key missing, library from another computer) is reported and never overwritten or replaced by a plaintext copy beside it.

Where: `LinuxWindows/crates/lokalbot-core/src/chats.rs`, `LokalBot/Services/Chat/ChatViewModel.swift` (`ChatStore.save`).

### Migrated chat turns get no invented date

Old messages recorded no per-turn date, and mixed version-1 scopes date-limited sources asymmetrically. Even an exact timestamp can't recover the originating time zone, so migration restores a turn's source types without fabricating a civil day or retrying under semantics the turn never had; its existing answer stays as safe history for full scope.

Where: `LokalBot/Services/Chat/ChatViewModel.swift`.

### The personal model is sealed with the `chat-key` and never saved over when unreadable

The personal model is `memory/personal-model.json.enc`, sealed under the same `chat-key` as conversations because its claims are as sensitive as the questions they came from; writes are atomic and 0600, only the app writes, and headless `--chat` reads. A plaintext `memory/personal-model.json` (demo seeds, upgrade fixtures) is accepted and re-encrypted on the next save, and an encrypted copy wins over leftover plaintext. Loading throws instead of returning empty for anything unreadable, so a caller never saves over it. Evidence-backed claims (RFC Phase 3) move it under `DreamStore`'s lock, so retraction updates them in the same critical section as Dream memory.

Where: `LokalBot/Services/PersonalModel/PersonalModelStore.swift` (`PersonalModelStore`, `PersonalModelStore.load`).

### Mail is sealed under its own key and kept out of everything plaintext

Downloaded mail lives under `email/` (`accounts.json.enc` for connected accounts and cursors, `<account-id>/threads/<thread-id>.json.enc`), every file sealed with AES-GCM under the per-install `email-key`, written atomically and 0600. Mail never goes into the plaintext search database, the embeddings, Dream reports or exports.

Where: `LokalBot/Services/Email/EmailStore.swift` (`EmailStore`).

### The dictation learning log is redacted, sealed and short-lived

Text dictated into other apps is kept only for the overnight learning pass (Personal Context → Learn from my dictation, off by default): raw spoken words only, never Compose's drafts, with card numbers and IBANs redacted, sealed with the `chat-key` in `memory/dictation-for-learning.json.enc`, 0600. Each entry goes once the pass has read its day and never lasts more than two days; turning the setting off deletes the file.

Where: `LinuxWindows/crates/lokalbot-core/src/personal/dictation_log.rs`, `LokalBot/Services/PersonalModel/DictationLearningLog.swift` (`DictationLearningLog`).

### Recent dictations are sealed and written durably

Recent dictations are kept on disk so a dictation left on the clipboard can be copied again after the next copy replaced it, even after a crash, a power cut or a restart. `recent-dictations.json.enc` is sealed (with the `chat-key` on the Mac, a per-install key in the credential store on Windows and Linux), owner-only, rewritten after every dictation and deleted by Clear; writes reach the drive before they replace the old file, on the Mac with `F_FULLFSYNC` off the main thread and in order, because plain `fsync` only reaches the drive's cache. The two apps' keys differ, so a file from the other app reads as empty and the next save replaces it.

Where: `LinuxWindows/crates/lokalbot-core/src/dictation_history.rs`, `LokalBot/Dictation/DictationHistory.swift` (`DictationHistoryStore`, `DictationHistoryStore.writeDurably`).

### Text meant for a password field is never kept

A cancelled dictation delivered nothing and keeps nothing, and text meant for a password field never enters recent dictations.

Where: `LokalBot/Dictation/DictationHistory.swift` (`DictationHistory.outcome`).

### A locked sealed file is unavailable, not corrupt, and never blocks a summary

A locked or unreachable file is treated as unavailable, not as corrupt ciphertext. Speaker identity is optional enrichment: its sealed sidecar uses complete-file protection and can be unreadable while the Mac is locked, and that must not block summary recovery from an already saved transcript or use up an automatic retry.

Where: `LinuxWindows/crates/lokalbot-core/src/voice/store.rs` (`Failure::Io`), `LokalBot/Services/Meetings/ProcessingPipeline.swift` (`ProcessingPipeline.process`).

### Speaker evidence relies on POSIX user-only mode, not Foundation file protection

The payload is already authenticated AES-GCM ciphertext, and Foundation's file-protection option can create unreadable files on macOS when the process has no Data Protection entitlement, so the write stays atomic and enforces a user-only POSIX mode instead.

Where: `LokalBot/Services/Speakers/MeetingSpeakerEvidenceStore.swift` (`MeetingSpeakerEvidenceStore.write`).

### The phone's library copy is first-unlock protected and left out of backups

The phone keeps its copy in Application Support, protected until the first unlock after a restart, and excluded from device backups because the Mac can always send it again.

Where: `Companion/ios/LokalBotCompanionKit/Sources/LokalBotCompanionKit/Platform/DeviceIdentity.swift` (`CompanionStorage`).

## Overnight memory and evidence revocation

### The Dream store writes under a shared lock, and a pending revocation blocks reads

The overnight review keeps `dreams/<yyyy-MM-dd>.json` (its presence marks the day reviewed) with a readable `.md` copy, and work memory in `memory/memory.json` and `memory/memory.md`. Every check-then-write runs under the advisory `.dream-store.lock`, which the Mac takes too. Withdrawing changed evidence first records its intent in `.dream-revocation-pending.json`, and while that file exists nothing may read overnight memory, so a failed cleanup can't leave old facts in use.

Where: `LinuxWindows/crates/lokalbot-core/src/dream/store.rs`.

### Memory is withdrawn before its source changes, and the intent is recorded first

`memory/evidence-revisions.json` holds a revision counter and the revision at which each day and meeting last changed; Dream reports and work memory record the revision they were built at, and both apps drop anything built from a source that changed since. Under the shared lock a writer records the change, withdraws what depended on it, and only then changes the source; the intent is written before the state so a fresh process can't mistake a failed state write for no change. On the Mac the host holds its evidence-revocation lock through evidence-correcting writes such as action state updates, so a failed preflight changes neither the source correction nor its derived narrative, and no other process can regenerate memory between revocation and the durable source change.

Where: `LinuxWindows/crates/lokalbot-core/src/evidence.rs`, `LinuxWindows/crates/lokalbot-core/src/dream/store.rs` (`DreamStore::commit_revocation`), `LokalBot/Services/Actions/OutcomeIndex.swift`.

### The store lock is `flock` plus an in-process mutex

The lock macOS takes around every revision check and commit is `File::lock`, which is `flock` on Unix, so it excludes the Mac app on a shared folder as well as other processes. `flock` doesn't exclude a second handle in the same process, hence the mutex too. This app writes only under the lock, so holding it proves any lock-protected mutation is over, and an unprotected write can only come from a Mac run that isn't this process.

Where: `LinuxWindows/crates/lokalbot-core/src/evidence.rs` (`StoreLock`), `LinuxWindows/crates/lokalbot-core/src/dream/store.rs` (`DreamStore::evidence_revision`).

### Source revocation overrides pinning

A pinned memory item still goes when its source is revoked, and an item without provenance goes with the first change rather than guessing (`DreamMemory.retractingEvidence`).

Where: `LinuxWindows/crates/lokalbot-core/src/dream/store.rs` (`retracting`).

### A changed meeting invalidates its UTC day and two days either side

So a time-zone change can't hide a dependent report.

Where: `LinuxWindows/crates/lokalbot-core/src/evidence.rs` (`source_day_keys`).

### Deleting a source withdraws its unedited generated digest

When the person deletes a source, that day's unedited generated journal is withdrawn with it (PRIVACY.md, `DayDigestLifecycle.retractGeneratedJournals`).

Where: `LokalBot/AppState.swift` (`AppState.EvidenceChange.removal`), `LinuxWindows/crates/lokalbot-core/src/evidence.rs`.

## Screen retention

### What expires: pixels, screen text and window titles; never meetings

Captures older than the cutoff that aren't saved lose their pixels. Unless the person opted to keep screen text forever, their screen text, vectors, window titles, URLs, document names and coding-agent sessions go too, because screen text can be as sensitive as the pixels it came from. Activity window titles are content and always expire, even with the text exception, while app names and durations stay as aggregate history. Meetings are never touched.

Where: `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::retention_review`), `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotService.applyRetentionReview`), `LokalBot/Services/Timeline/ActivityTracker.swift` (`ActivityStore.retentionReview`).

### Shortening retention opens a review; changing a preference never deletes

Shortening how long screen context lasts, or no longer keeping screen text forever, opens a review first. The policy stays unchanged until the review is applied, and the caller sets the new policy only once the cleanup returns, so changing a preference never triggers an unreviewed cleanup.

Where: `LinuxWindows/crates/lokalbot-app/src/pages/settings/retention_review.rs`, `LokalBot/AppState.swift` (`AppState.settings`), `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::apply_retention_review`).

### A cleanup deletes exactly what its review listed

A pass deletes only the IDs its own review listed, never everything past a cutoff, so it can't remove evidence nobody looked at or whose days weren't revoked. A review that no longer covers what is there fails with `RetentionReviewError::ScopeChanged` and nothing is deleted; data found after the revocation scope was set waits for its own reviewed pass.

Where: `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::apply_retention_review`), `LokalBot/Services/ScreenMemory/ScreenshotService.swift` (`ScreenshotService.performRetentionPrune`, `ScreenshotService.applyRetentionReview`), `LokalBotTests/Services/ScreenMemory/ScreenshotProcessingWorkerTests.swift`.

### A reviewed cleanup counts as the person deleting the source

Dependent overnight memory and unedited generated journals are withdrawn before the reviewed cleanup deletes anything.

Where: `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::apply_retention_review`).

### Scheduled retention expires evidence but keeps digests and overnight memory

Scheduled retention expires screen text, titles and agent sessions on their own clock; nobody deleted or corrected them, so day digests, Dream reports and work memory stay, and go only when a source is deleted or the memory is cleared. Before, every pass wiped nearly all Dream memory, because each memory change inherits the sources of every other item, and each expiring day lost its digest. Exports and routines still look again, and answers reused from those days are forgotten.

Where: `LokalBot/AppState.swift` (`AppState.withScheduledRetention`), `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::apply_retention`), `LinuxWindows/crates/lokalbot-engine/src/retention.rs`, `LinuxWindows/crates/lokalbot-core/src/evidence.rs`.

### Retention runs at startup and every six hours; a shorter window or a clock rollback doesn't wait

The Windows and Linux app applies the retention window at startup and then every six hours. A shorter window is an explicit privacy action, so it bypasses the daily bound, and a clock rollback must not suspend cleanup until wall time catches up with the old timestamp.

Where: `LinuxWindows/crates/lokalbot-engine/src/retention.rs`, `LokalBotTests/Services/ScreenMemory/ScreenshotProcessingWorkerTests.swift` (`ScreenshotRetentionSchedule.shouldPrune`).

### Sources are established before anything is removed

A pass settles the exact sources before deleting anything, and a failed read must never look empty.

Where: `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::apply_retention`).

### Clearing retained text checks bookmarks at run time and finds rows through the metadata index

FTS5 can't index its unindexed `snapshot_id`, so the exact rowids come through the metadata index, in bounded chunks.

Where: `LinuxWindows/crates/lokalbot-core/src/retention.rs` (`Library::clear_retained_text`).

### Embedding backfill rechecks live text so it can't resurrect expired text

Retention or an explicit deletion may remove OCR text while embedding is suspended, so screen text reindexing rechecks the exact live text inside the write transaction, and an in-flight backfill can't bring expired plaintext back into the embedding table.

Where: `LokalBot/Services/Search/EmbeddingIndex.swift` (`EmbeddingIndex.performScreenTextReindex`).

## Logs, diagnostics and transcripts

### Export Diagnostics never reads meetings, screenshots or screen text

The archive holds recent logs, health reports, settings without secrets, library row counts and capture traces (already scrubbed when written), in one zip the person saves themselves. It never reads the meetings folder, screenshots or screen text, so meeting audio, transcripts, notes and screen content can't end up in it.

Where: `LokalBot/Services/Diagnostics/DiagnosticsExporter.swift` (`DiagnosticsExporter`), `LinuxWindows/crates/lokalbot-engine/src/diagnostics.rs`.

### Diagnostics settings are sanitized with a deny-list

Any key that names a credential is dropped, as on the Mac, and URLs are reduced to their host and path.

Where: `LinuxWindows/crates/lokalbot-engine/src/diagnostics.rs` (`sanitized_settings`).

### Health checks read counts and timestamps only, and released builds check only on request

Library health judges one day of a library the way a person would notice a problem, from counts and timestamps only, never window text or meeting content; reports stay in `diagnostics/health`. PRIVACY.md promises that released builds check on request, so only development builds start the check on their own.

Where: `LinuxWindows/crates/lokalbot-core/src/health.rs`, `LinuxWindows/crates/lokalbot-engine/src/health_check.rs` (`health_check::start`).

### Logs carry no file names or recognized words

Messages about imported recordings don't name the file. FluidAudio's debug and notice lines can contain recognized words, so they're filtered from both unified logging and stderr, including in headless commands.

Where: `LinuxWindows/crates/lokalbot-app/src/state.rs` (`AppData::import_recordings`), `LokalBot/LokalBotApp.swift` (`LokalBotMain.configureDependencyLogging`).

### llama-server's output tail keeps only crash lines once the server is healthy

The tail of llama-server's stderr is kept in memory to explain a failure. Until the first health check passes the server has seen no request, so every line is kept and a failed start can say why; after that only crash lines are kept, because request errors can echo request text and diagnostic logs never hold transcripts or screen text (PRIVACY.md).

Where: `LokalBot/Engines/LlamaServer.swift` (`LlamaServerOutputTail`).

### Voice evidence never joins the transcript in clear

The private voice evidence travels with a transcript but never joins it or anything saved beside it in clear.

Where: `LinuxWindows/crates/lokalbot-speech/src/transcriber.rs` (`DetailedTranscript`).

### Transcripts reference calendar participants by opaque IDs

Speaker aliases use opaque calendar-participant IDs; email addresses stay in meeting metadata and never enter the transcript.

Where: `LokalBot/Models/Transcription/Transcript.swift` (`Transcript.speakerCalendarIdentityIDs`).

## Consequences

- Anything both apps read stays in the Mac's layout and `Codable` encoding, sealed files included; a format change on one side needs the same change on the other.
- A failed read, a locked file or an unreachable credential store is never treated as empty or absent: no new key, no overwrite of a sealed file, no deletion beyond what a person reviewed.
- Deleting or correcting evidence withdraws dependent overnight memory and unedited digests under the shared `.dream-store.lock` before the source changes; scheduled retention never does.
