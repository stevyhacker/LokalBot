# 0051. Mac app: Storage

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LokalBot/Services/Storage/`, `LokalBotTests/Services/Storage/`.

## Decisions

### `LokalBot/Services/Storage/CompleteJSONRecords.swift`

#### Read only complete array records; never close partial or invent fields
`CompleteJSONRecords`: Reads only complete top-level array records. It never closes a partial
object/string or invents missing fields, and handles escaped quotes/braces.

#### Strict envelope must start with an object, not prose
`CompleteJSONRecords.parse`: The strict envelope starts with an object, not arbitrary prose.

### `LokalBot/Services/Storage/GeneratedFileWriter.swift`

#### Marker identifies generated file; only recorded hash allows replacement
`GeneratedFileWriter`: Shared ownership contract for exports and routines. A marker identifies a
generated file; only the recorded hash grants permission to replace it.

#### False when bytes identical; legacy files adopted only then
`GeneratedFileWriter.write`: Returns false when identical bytes were already present. Legacy files
can be adopted only in that case, without replacing their content.

#### Finish permissions after commit even if task cancelled
`GeneratedFileWriter.write`: Complete permissions/ownership after committing bytes, even if the
calling task was cancelled immediately after the write.

### `LokalBot/Services/Storage/SQLiteDatabase.swift`

#### Checked APIs throw typed errors; legacy APIs log failures
`SQLiteDatabase`: Small SQLite wrapper shared by the app's indexes and durable queues.

The checked APIs preserve SQLite failures as typed errors. The legacy
boolean/empty-result APIs remain for source compatibility, but now log the
same failure instead of silently hiding it.

#### WAL and NORMAL for shared connections; configure raw handle before assigning db
`SQLiteDatabase.init`: Multiple app components own independent connections to the same
database. WAL lets readers proceed during a writer transaction;
NORMAL keeps the durability/performance tradeoff appropriate for
locally reconstructible indexes and queues. Configure the raw handle
before assigning `db`, so a failed failable initializer owns exactly
one close path.

#### Backup is consistent standalone snapshot including WAL; caller cleans up errors
`SQLiteDatabase.backup`: Makes a consistent standalone snapshot, including committed WAL rows.
The caller owns the new destination and any cleanup after an error.

#### Normalize backup to DELETE journal so read-only verifier opens without WAL/SHM
`SQLiteDatabase.backup`: A backup inherits WAL mode from the source header. Normalize it while
writable so a read-only verifier can open the standalone file without
requiring a new WAL/SHM pair in the recovery directory.

#### Reset and rebind so one statement serves a batch
`SQLiteDatabase.runChecked`: Executes an already-prepared statement, resetting and rebinding it so
callers can reuse one statement for a batch of rows.

#### Any thrown error rolls back whole write group
`SQLiteDatabase.withTransaction`: Runs a group of writes atomically. Any thrown error rolls the whole
group back before it is propagated to the caller.

#### Returning false stops iteration intentionally; earlier failures still throw
`SQLiteDatabase.forEachRowChecked`: Stream rows without building an intermediate array. Returning `false`
from `row` intentionally stops iteration (useful for bounded context
assembly); SQLite failures encountered before that point still throw.

### `LokalBot/Services/Storage/StorageManager.swift`

#### Root at bundle id to avoid collision with other app's Meetings folder
`StorageManager`: Owns the on-disk layout (design doc §6):
~/Library/Application Support/me.dotenv.LokalBot/
  meetings/YYYY/MM/dd-slug/{mic.m4a, system.m4a, meta.json}

Rooted at the bundle id, NOT "LokalBot": an unrelated app may own
~/Library/Application Support/LokalBot/ on some machines, and its
"Meetings" folder would collide with our "meetings" on the default
case-insensitive filesystem.

#### Env var redirects storage for UI tests; production never sets it
`StorageManager.init`: UI-test isolation hook: when the env var points at a directory,
every read/write goes there instead of the user's real library.
Production launches never set it, so default behaviour is unchanged.

#### Library lists only folders with meta.json so files can move in first
`StorageManager.reserveMeetingFolder`: Creates an empty, uniquely named folder for a meeting on `startedAt`'s
day and returns its library-relative path. The library lists only
folders that hold `meta.json`, so a caller can move finished files in
before the meeting appears.

#### Repair killed recordings by closing endedAt at last audio write
`StorageManager.loadMeetings`: Orphan repair: app killed mid-recording leaves endedAt nil
forever ("in progress"). Close it at the audio's last write.

#### Finalize recovery checkpoints before inspecting orphan; never new capture
`StorageManager.loadMeetings`: Materialize independent checkpoints before inspecting an
orphan. This finalizes existing media, never new capture.

#### Keep merge marker on repair failure so later load retries
`StorageManager.loadMeetings`: Keep the old marker if either SQLite or metadata repair
failed. A later load retries instead of losing the journal.

#### On-disk source marker is recovery journal until indexes reopened
`StorageManager.restoreMergedSource`: Only call after removing the generated parent. The on-disk source
marker is the recovery journal until both indexes have been reopened.

#### Delete descendants before parent so interruptions leave sources folded
`StorageManager.deletionOrder`: Permanent deletion is different from Undo: remove every retained
descendant before its parent. A failed/interrupted delete therefore
leaves surviving sources folded, and retries skip already removed ones.

#### Update UI only after deletion succeeds; swallowed errors resurrected meetings
`StorageManager.deleteMeeting`: Delete the durable meeting folder. Callers must only remove the meeting
from in-memory/UI state after this succeeds; swallowing the filesystem
error made failed deletions reappear on the next launch.

#### Cap slug at 120 bytes since APFS allows 255
`StorageManager.folderSlug`: The slug, short enough for a folder name. APFS allows 255 bytes, which
about 85 CJK characters already fill, and a title a device sent can be
longer than that.

#### Keep folderURL out of Meeting.swift so lokalbot-cli stays dependency-free
`Meeting.folderURL`: Resolve this meeting's on-disk folder against a `StorageManager`'s
root. Lives on `StorageManager.swift` (not `Meeting.swift`) so the
embedded `lokalbot-cli` — which doesn't compile `StorageManager` —
keeps the `Meeting` value type dependency-free.

### `LokalBotTests/Services/Storage/StorageManagerTests.swift`

#### A directory at intent-file path rejects the write without touching permissions
`StorageManagerTests.testDeleteMeetingDoesNotRemoveSource`: A directory at the intent-file path deterministically rejects the
write without changing real filesystem permissions or user data.

#### One instant can be a +14 timezone's next day; timezone changes shift evidence days
`DreamEvidenceInvalidation.sourceDayKeys`: This instant can represent a +14 timezone's Sep 25 midnight. Its
day's later evidence can belong to Sep 26 after changing timezone.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
