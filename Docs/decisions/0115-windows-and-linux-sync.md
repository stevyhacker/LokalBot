# 0115. Windows and Linux: sync

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-sync/examples/`, `LinuxWindows/crates/lokalbot-sync/src/bin/`, `LinuxWindows/crates/lokalbot-sync/src/client/`, `LinuxWindows/crates/lokalbot-sync/src/error.rs`, `LinuxWindows/crates/lokalbot-sync/src/keys.rs`, `LinuxWindows/crates/lokalbot-sync/src/lib.rs`, `LinuxWindows/crates/lokalbot-sync/src/messages.rs`, `LinuxWindows/crates/lokalbot-sync/src/net.rs`, `LinuxWindows/crates/lokalbot-sync/src/pairing.rs`, `LinuxWindows/crates/lokalbot-sync/src/records.rs`, `LinuxWindows/crates/lokalbot-sync/src/server/`, `LinuxWindows/crates/lokalbot-sync/src/tests/`, `LinuxWindows/crates/lokalbot-sync/src/wire.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-sync/examples/companion_client.rs`

#### Stand-in phone for developing against a host; commands and usage
A stand-in phone for developing against a host (the Mac app or the
`companion_host` example). It keeps its key and copy in one directory.

```text
cargo run -p lokalbot-sync --example companion_client -- [--dir PATH] [--name NAME] <command>

  pair <payload>                        pair using a lokalbot://pair?d=… code
  sync [address…]                       sync, trying these host:port addresses first
  status | meetings | people | days
  actions [--mine] [--open]             action items, overdue first
  set-status <meeting> <action> <status>
  ask "<question>" [address…]           ask the Mac, printing the answer as it arrives
  search "<query>"
  unpair
```

### `LinuxWindows/crates/lokalbot-sync/examples/companion_host.rs`

#### Stand-in Mac for companion app development; options and console commands
A stand-in Mac for developing the companion apps: serves the sample
library, prints a pairing code, applies action status changes and answers
questions with a canned reply.

```text
cargo run -p lokalbot-sync --example companion_host -- [--port 17890] [--dir PATH]
    [--name "Dev Mac"] [--auto-approve] [--loopback]
```

While it runs, type `pair` for a new code, `devices`, `remove <device id>`,
`publish` to bump today's day record, or `quit`. Answer a pairing request
with `y` or `n`.

#### Keep host key beside database so pairings survive restarts
`static_key`: The host's static key, kept next to its database so pairings survive
restarts.

#### Next y/n on stdin answers the pending pairing request
`DevMac.pending_approval`: Where the next `y`/`n` on stdin goes.

#### Stand-in keeps audio beside database since it has no pipeline
`Delegate::receive_recording`: Keeps the audio beside the database and reports it; the stand-in has
no pipeline to send it through.

#### Each run restarts from sample library; old status changes republish as new versions
`main`: Each run starts from the sample library again; status changes from an
earlier run are published back as new versions.

### `LinuxWindows/crates/lokalbot-sync/src/bin/uniffi-bindgen.rs`

#### Build bindgen from this crate so scripts need only Rust
The UniFFI binding generator, built from this crate so the build scripts
need nothing installed besides Rust.

### `LinuxWindows/crates/lokalbot-sync/src/client/mod.rs`

#### SyncClient pairs, keeps a local copy, asks questions, sends recordings
The phone's end: `SyncClient` pairs with a Mac, keeps a local copy of
its records, asks it questions and sends it recordings.

#### Refuse codes 120 s past expiry locally; the Mac's clock decides the rest
`EXPIRY_GRACE_SECS`: A code this many seconds past its expiry on this device's clock is
refused without trying; the Mac's clock decides the rest.

#### Device id is a UUID the app keeps per installation
`ClientConfig.device_id`: A UUID the app keeps for this installation.

#### Platform is ios, ipados or android
`ClientConfig.platform`: `ios`, `ipados` or `android`.

#### Pairing time is ISO 8601 UTC
`PairedMac.paired_at`: ISO 8601 UTC.

#### Address is the ip:port that answered
`SyncReport.address`: The `ip:port` that answered.

#### Finish time is ISO 8601 UTC
`SyncReport.finished_at`: ISO 8601 UTC.

#### Only one pairing or sync runs at a time
`SyncClient.sync_lock`: One pairing or sync at a time.

#### Separate upload lock so long uploads block neither sync nor Ask
`SyncClient.upload_lock`: One upload pass at a time. Separate, so a long upload holds up neither
syncing nor Ask.

#### Recordings live in recordings/ beside the database
`SyncClient.recordings_dir`: Where recordings live: `recordings/` beside the database.

#### No handshake means not LokalBot or code unknown or expired
`PairAttempt::NoHandshake`: No Noise handshake: not LokalBot, or the code is unknown or expired.

#### Handshake reached a Mac whose key differs from the code's
`PairAttempt::WrongMac`: The handshake reached a Mac whose key is not the one in the code.

#### Pairing blocks for the Mac user and keeps unsent recordings
`SyncClient::pair`: Pairs with the Mac in a scanned code. Blocks until the person answers
on the Mac. Replaces any earlier pairing and local data, apart from
recordings that haven't reached a Mac yet.

#### Try extra addresses first, then stored; send queued ops, catch up, close
`SyncClient::sync`: Connects (`extra_addresses` first, e.g. Bonjour results, then the
stored ones), sends queued ops, catches up and closes.

#### Unpair erases local data without telling Mac; sample library keeps recordings
`SyncClient::unpair`: Erases the local copy, recordings that haven't reached the Mac and the
pairing. The Mac is not told. With no pairing, as when closing the sample
library, it erases the copy alone: recordings kept after the Mac removed
this device stay until they are discarded one by one or sent.

#### Queue the op and show status immediately as pending
`SyncClient::set_action_status`: Queues an `action.setStatus` op and shows the status at once, marked
pending. In the sample library the change is simply kept.

#### A dropped connection queues the question; asking again resumes the answer
`SyncClient::ask`: Asks the Mac, or answers from the unpaired sample library, streaming
text to `listener`. Returns the result JSON and saves it to history.

If the connection drops once the Mac has the question, the Mac keeps
answering: this queues the question and fails with `Interrupted`.
Asking the same request again picks the answer up, with the text so
far as the first delta.

#### Drop store lock before callback because it may re-enter the client
`SyncClient::ask`: A callback may call the client again, so don't hold the store lock.

#### Queued questions are oldest first and removed once answered
`SyncClient::queued_questions`: Queued questions (request JSON), oldest first. `ask` removes one once
it is answered.

#### History is request/result JSON, newest first, 0 means all
`SyncClient::ask_history`: `{ "request": …, "result": … }` JSON, newest first; 0 = all.

#### Meetings newest first, merged hidden, 0 means no limit
`SyncClient::meetings`: Meetings newest first; merged meetings are hidden. 0 = no limit.

#### Day keys newest first, 0 means no limit
`SyncClient::days`: Day keys that have a record, newest first. 0 = no limit.

#### ActionRow JSON ordered overdue first by this device's date
`SyncClient::actions`: ActionRow JSON (ffi.md), overdue first by this device's date.

#### Limit 0 means default of 50 hits
`SyncClient::search`: Full-text search. 0 = the default of 50 hits.

#### Import marks the store as sample data
`SyncClient::import_records`: Imports an array of envelopes (e.g. fixtures/sample-library.json) and
marks the store as sample data. Returns how many records changed.

#### Test helper points phone at a faked host without pairing
`SyncClient::pair_with_key`: Points this phone at a computer without pairing, for hosts a test fakes.

#### Return session after catch-up unclosed so tests watch live pushes
`SyncClient::open_live`: Opens a sync session and returns it after the catch-up, without
closing, so tests can watch live pushes.

#### Session right after handshake; test sends hello itself
`SyncClient::connect_raw`: A session right after the handshake; the test sends `hello` itself.

#### On revocation wipe library but keep unsent recordings
`SyncClient::finish`: Wipes the local copy when the Mac revoked this device. Recordings that
haven't reached it stay: they exist nowhere else, and removing a device is
often the first step of pairing it again.

#### Pairing handshake first message pattern: e
`SyncClient::pair_over`: -> e

#### Pairing handshake second message pattern: e, ee, s, es
`SyncClient::pair_over`: \<- e, ee, s, es

#### Verify the Mac's key before revealing ours in last message
`SyncClient::pair_over`: Check the Mac's key before revealing ours in the last message.

#### Pairing handshake final message pattern: s, se, psk
`SyncClient::pair_over`: -> s, se, psk

#### Closing without an answer means the Mac did not accept the code
`SyncClient::request_pairing`: The Mac answers every request it accepted, a refusal or timeout
included; closing without an answer means it did not accept the
code (a wrong secret, or an offer that is gone).

#### Session handshake first message pattern: e, es, s, ss
`SyncClient::open_session_handshake`: -> e, es, s, ss

#### Session handshake second message pattern: e, ee, se
`SyncClient::open_session_handshake`: \<- e, ee, se

#### Only a finished batch moves the cursor so interrupted catch-up repeats safely
`SyncClient::catch_up`: Only a finished batch moves the cursor, so an
interrupted catch-up repeats safely.

#### Lock screen or Wi-Fi change drops connection; Mac answers anyway
`SyncClient::ask`: A lock screen or a Wi-Fi change; the Mac answers anyway.

#### Request must name requestId and question
`parse_request`: The request's id and body; the request must name `requestId` and
`question`.

#### Try each socket address once with connect timeout; resolve names lazily
`connections`: TCP connections to `addresses` in order, each socket address tried once
with the connect timeout. Names resolve lazily, one address at a time.

### `LinuxWindows/crates/lokalbot-sync/src/client/queries.rs`

#### Read queries return records.md JSON with local action states applied
Read queries over the phone's copy (ffi.md, reads). Bodies come back as
the JSON records.md describes, with local action states applied.

#### Status is open, done or deferred; all when absent
`ActionFilter.status`: `open`, `done` or `deferred`; all when absent.

#### Due-before is exclusive YYYY-MM-DD
`ActionFilter.due_before`: Only actions due before this day (`YYYY-MM-DD`, exclusive).

#### Limit 0 means no limit
`take`: `0` means no limit.

#### Overlay pending flag and syncNote onto meeting actions
`apply_states`: Applies pending statuses (`"pending": true`) and op notes (`"syncNote"`)
to a meeting body's actions.

#### Newest first, merged hidden, optional inclusive day range
`ClientStore::meetings`: Meetings newest first, merged ones hidden, optionally within days
`from_day..=to_day`.

#### Filter in SQL so a page reads only its rows; missing day counts as empty
`ClientStore::meetings`: In SQL, so a day or a page reads only its own rows: `is_merged`, and
a day that is missing or not a string counting as "".

#### Order overdue first, then due date, then meeting start newest
`ClientStore::actions`: ActionRow JSON: overdue first, then by due date (none last), then by
meeting start, newest first. `today` is `YYYY-MM-DD`.

#### People ordered most recently met first
`ClientStore::people`: People, most recently met first.

#### Projects ordered by most recent meeting first
`ClientStore::projects`: Projects, the one with the most recent meeting first.

### `LinuxWindows/crates/lokalbot-sync/src/client/recordings.rs`

#### ADTS AAC recording survives crashes; file removed after Mac confirms
Recordings made on the phone, on their way to the Mac (protocol.md, Flow
for `purpose: "upload"`). The platform's recorder writes an ADTS AAC file
here, which is readable however it ends, so a crash or a dead battery
loses only the last moments. The file goes once the Mac confirms it has it.

#### Upload format value; only aac-adts exists so far
`FORMAT`: What `format` says in an upload. Only this exists so far.

#### Uploaded recording stays listed 7 days if its meeting never returns
`UPLOADED_LISTED_FOR`: How long a recording that reached the Mac stays listed when its meeting
never comes back, as when the Mac doesn't share meetings.

#### Recording id is a UUID reused as the Mac meeting id
`RecordingInfo.id`: A UUID; the meeting it becomes on the Mac has the same id.

#### Empty title lets the Mac pick one
`RecordingInfo.title`: Empty until the person names it; the Mac then picks one.

#### State is recording, waiting, failed or uploaded
`RecordingInfo.state`: `recording`, `waiting`, `failed` or `uploaded`.

#### Start time is ISO 8601 UTC
`RecordingInfo.started_at`: ISO 8601 UTC.

#### Recorder's path, gone once the Mac has the file
`RecordingInfo.file_path`: Where the recorder writes. Gone once the Mac has it.

#### Waiting counts every recording still to go
`UploadReport.waiting`: Recordings still to go, whatever kept them.

#### Failed recordings stay until retried or discarded
`UploadReport.failed`: Recordings the Mac refused; they stay until retried or discarded.

#### A deleted recording stops uploading and leaves the rest here
`Trip::Withdrawn`: The person deleted it on the way, so the rest stays here.

#### Recording needs a paired Mac since that is the only destination
`SyncClient::begin_recording`: Starts a recording: returns where the recorder writes. It needs a
paired Mac, because that is the only place it can go.

#### An empty file leaves no recording and fails InvalidInput
`SyncClient::finish_recording`: The recorder stopped: the recording can go to the Mac. A file with
nothing in it leaves no recording and fails with `InvalidInput`.

#### Recover interrupted recordings at launch only, never while recording
`SyncClient::recover_recordings`: Recordings left `recording` by an app that stopped without finishing
them: the file holds everything up to then, so they go to the Mac like
any other. Call at launch, never while a recorder runs. Returns how
many were kept.

#### Empty title leaves naming to the Mac
`SyncClient::set_recording_title`: Empty leaves the name to the Mac.

#### Uploaded recording listed until its meeting arrives here
`SyncClient::recordings`: Recordings on this device or just sent, newest first. One that reached
the Mac stays listed until its meeting arrives here.

#### Upload oldest first, resume, return at once if busy; error kinds
`SyncClient::upload_recordings`: Sends every waiting recording, oldest first, picking up where an
earlier attempt stopped. Blocks for as long as that takes and returns
at once when another pass is running or nothing waits. Whatever
doesn't get through stays waiting; a dropped connection fails with
`Io`, an absent Mac with `Unreachable`. Call `sync` afterwards to fetch
the new meetings.

#### Older Mac says welcome then refuses upload purpose
`SyncClient::run_uploads`: A Mac from before uploads says `welcome`, then refuses the purpose.

#### Re-read row so a title set mid-pass goes along
`SyncClient::upload_each`: A title set since this pass began goes along.

#### Deleted recording must not become a meeting from partial data
`SyncClient::upload_one`: Deleted here means deleted: the Mac makes no meeting of what's left.

#### A file that shrank mid-upload is reported missing
`SyncClient::upload_one`: The file got shorter under us; it can't be sent as described.

#### recv closes after idle timeout, the only limit while chunks move
`await_reply`: The Mac's next word about this recording. `inbox.recv` itself closes after
the idle timeout, which is the only limit while chunks are moving.

### `LinuxWindows/crates/lokalbot-sync/src/client/sample.rs`

#### Sample library answers are extractive, never use an engine or network
Extractive answers from the unpaired sample library. Real questions are
answered by the paired computer; this never invokes an engine or a network.

### `LinuxWindows/crates/lokalbot-sync/src/client/search.rs`

#### FTS5 unicode61 like Mac, plus CJK substring fallback
Full-text search over the phone's copy: SQLite FTS5 with the unicode61
tokenizer, like the Mac's `SearchIndex`, plus the Mac's substring
fallback for Chinese, Japanese and Korean text (`CJKSearch.swift`).

#### Hit kind is meeting, transcript or day
`SearchHit.kind`: The record kind: `meeting`, `transcript` or `day`.

#### Key is meeting id, or the day for digests
`SearchHit.key`: The record key: the meeting id, or the day for digests.

#### Title is meeting title, or date for a day digest
`SearchHit.title`: The meeting title; the date for a day digest.

#### Snippet marks matched terms in guillemets
`SearchHit.snippet`: Words around the match, matched terms in « ».

#### At is segment start seconds for transcript hits
`SearchHit.at`: Segment start in seconds, for transcript hits.

#### Date is the meeting's day or the digest's date
`SearchHit.date`: The meeting's day, or the digest's date.

#### Stop words dropped in OR mode; mirrors lokalbot-core search
`STOP_WORDS`: Function words dropped from natural-language queries in OR mode
(`lokalbot-core::search::STOP_WORDS`).

#### Search documents per record; merged meetings are not indexed
`Document`: Search documents for one record. Merged meetings are not indexed.

#### Every term must match, last as prefix for search-as-you-type
`MatchMode::All`: Every term, the last as a prefix (search as you type).

#### Any term matches; stop words dropped unless all terms are stop words
`MatchMode::Any`: Any term, stop words dropped unless every term is one.

#### Quote terms so punctuation cannot cause FTS5 syntax errors
`fts_query`: The FTS5 expression for `raw`, terms quoted so punctuation cannot cause
syntax errors (`lokalbot-core::search::fts_query`).

#### Hide documents of merged meetings like the meetings
`NOT_MERGED`: Documents of meetings merged into another are hidden like the meetings.

#### Search order: all terms, any term, then CJK substring as on the Mac
`search`: Keyword search: all terms first, then any term, then (for CJK text) a
substring match, as on the Mac.

#### Latin word glued to CJK is one token FTS cannot see
`search`: A Latin word glued to CJK text ("比如logo再大") is part of that
run's token, so FTS cannot see it.

#### Shorter documents first like bm25; relaxed results rank by pieces matched
`substring_search`: Substring counterpart of `fts_search` (`SearchIndex.substringSearch`).
Shorter documents first, as bm25 favours them; relaxed (OR) results rank
by how many pieces matched.

#### CJK has no spaces so unicode61 indexes a run as one token; use substring
`cjk`: Chinese, Japanese and Korean text has no spaces between words, so
unicode61 indexes a whole run as one token. Queries with CJK text match
by substring instead (`CJKSearch.swift`).

#### Terms are distinct, in order, and all must occur
`cjk::terms`: Distinct terms in order; every one must occur.

#### Relaxed OR terms: overlapping two-character pieces, drop singles unless alone
`cjk::relaxed_terms`: Terms for OR matching of a spaceless question: CJK runs of three or
more characters become overlapping two-character pieces; single
characters are dropped unless nothing else is left.

#### Escape LIKE wildcards and backslash for ESCAPE clause
`cjk::like_pattern`: A `LIKE` pattern matching `term` anywhere, with `%`, `_` and `\`
escaped for `ESCAPE '\'`.

#### Excerpt marks matches with guillemets and ellipsis; None without a match
`cjk::snippet`: An excerpt around the first match with « » around every match in it
and … where text was cut; `None` when no term occurs.

### `LinuxWindows/crates/lokalbot-sync/src/client/store.rs`

#### Recording file path is derived from its id
`RecordingRow`: A recording as stored; the file's path comes from its id.

#### Wipe removes recordings too; caller deletes their files
`ClientStore::wipe`: Erases everything: records, index, pairing, queues and history.
Empties everything, recordings included. The caller deletes their files.

#### Library wipe keeps recordings, which exist nowhere else until sent
`ClientStore::wipe_library`: Empties everything that came from a Mac, and the pairing. Recordings
stay: they exist nowhere else until they reach a computer.

#### VACUUM then checkpoint WAL so erased data leaves the file
`ClientStore::wipe_library`: Rebuild the file without the freed pages, then move the result out
of the WAL into the main file and empty the WAL.

#### Uploaded recording pruned once meeting arrives or after cutoff
`ClientStore::recordings`: Everything still worth showing, newest first. A recording that reached
the Mac leaves once its meeting arrived, or after `prune_before` when
the Mac doesn't share it back.

#### Active means recorder was writing when app last stopped
`ClientStore::recordings_active`: Recordings a recorder was writing when the app last stopped.

#### Recording stays waiting; message says why it has not gone
`ClientStore::set_recording_message`: Stays waiting; `message` says why it hasn't gone yet.

#### Upsert batch keeping the higher version of each record
`ClientStore::apply`: Upserts a batch, keeping the higher version of each record.

#### SQLite filters and stops so only returned rows are parsed
`ClientStore::bodies_matching`: Live bodies of one kind that meet `condition`, in `ORDER BY` order, at
most `limit` of them (`0`: all). SQLite filters and stops, so only the
returned rows are parsed. `condition` binds `values` as `?3` onwards.

#### SQLite reads a negative LIMIT as no limit
`ClientStore::bodies_matching`: SQLite reads a negative LIMIT as none.

#### In-place body write is for sample library edits only
`ClientStore::replace_body`: Writes a body in place (sample library edits only; no new version).

#### Show status locally until Mac answers; replace unsent ops per action
`ClientStore::queue_op`: Queues an op and shows its status locally until the Mac answers.
Unsent ops for the same action are replaced.

#### Ops go in creation order and are marked sent
`ClientStore::take_ops_for_sending`: Queued ops in the order they were made; marks them sent.

#### Applied clears pending; unmatched and rejected revert and keep a note
`ClientStore::finish_op`: Records the Mac's answer to an op. `applied` clears the pending
status (the rebuilt meeting has already arrived); `unmatched` and
`rejected` revert it and keep a note.

#### An answer picked up twice is stored once
`ClientStore::save_answer`: Saves an answer and drops the question from the queue. An answer
picked up twice (two attempts attached to the same answer) is kept
once.

#### Store only newer versions; keep index and pending states in step
`upsert`: Stores one envelope unless an equal or newer version is present. Keeps the
search index and pending action states in step. Returns whether it
changed anything.

#### A newer meeting settles pending statuses and drops old notes
`settle_actions`: A newer meeting record settles local action states: a pending status the
Mac now shows is no longer pending, and notes from older versions go.

### `LinuxWindows/crates/lokalbot-sync/src/error.rs`

#### Variants carry readable messages; Swift SyncError.Io, Kotlin SyncException.Io
`SyncError`: Errors crossing the FFI. Each variant carries a human-readable message;
Swift sees `SyncError.Io(message:)`, Kotlin `SyncException.Io`.

#### Dropped after Mac had the question; it keeps answering, ask again
`SyncError::Interrupted`: The connection dropped after the Mac had the question. The Mac keeps
answering; the question is queued, and asking it again picks up the
answer.

#### Covers both a declined pairing and no answer
`SyncError::PairingRejected`: The person declined the pairing on the Mac, or did not answer.

#### Mac removed device and local copy has been erased
`SyncError::Revoked`: The Mac removed this device; the local copy has been erased.

### `LinuxWindows/crates/lokalbot-sync/src/keys.rs`

#### Platform keeps private key in Keychain or Keystore and returns it
`StaticKey`: An X25519 key pair. The platform keeps the private half in the Keychain
or behind the Android Keystore and hands it back at construction.

#### Fingerprint is first 16 hex chars of SHA-256, Bonjour TXT k
`fingerprint`: First 16 hex characters of SHA-256 over the public key (Bonjour TXT `k`).

### `LinuxWindows/crates/lokalbot-sync/src/lib.rs`

#### Host/client roles and the protocol documents defining the wire contract
Companion sync for LokalBot's phone and tablet apps.

The Mac (the host, [`SyncServer`]) publishes allowlisted JSON records and
serves paired devices over the local network or Tailscale; phones and
tablets (the clients, [`SyncClient`]) keep an end-to-end encrypted copy,
search it, change action status, ask the Mac questions and send it
recordings made on the device. The wire
contract is `Companion/protocol/protocol.md`, the records
`Companion/protocol/records.md`, and this crate's foreign API
`Companion/protocol/ffi.md`; Swift and Kotlin call it through UniFFI.

#### Fingerprint matches the Bonjour TXT record k
`key_fingerprint`: First 16 hex characters of SHA-256 over a public key, as in the Bonjour
TXT record `k`.

#### Lists private LAN, Tailscale, link-local IPv4; never loopback
`local_addresses`: This machine's private LAN, Tailscale and link-local IPv4 addresses (the
address filter's ranges), never loopback.

### `LinuxWindows/crates/lokalbot-sync/src/messages.rs`

#### Session messages follow protocol.md; envelope follows records.md
The JSON messages inside a session (protocol.md, Session messages) and
the record envelope (records.md, Envelope).

#### Unknown message types and fields are ignored
`Message`: Every message type, both directions. Unknown types parse as `Unknown`
and are ignored; unknown fields are ignored.

#### Chunk data is standard base64
`Message::UploadChunk.data`: Standard base64.

### `LinuxWindows/crates/lokalbot-sync/src/net.rs`

#### Peer filter, advertised addresses, and address-string resolution
Which peers the Mac accepts, which of its own addresses it advertises,
and how a phone turns stored address strings into sockets.

#### Allow loopback, LAN, link-local, IPv6 ULA, Tailscale CGNAT; unwrap mapped IPv4
`is_allowed_peer`: The address filter (protocol.md, Network): loopback, private LAN,
link-local, IPv6 ULA (Tailscale's `fd7a:115c:a1e0::/48` included) and
Tailscale/CGNAT `100.64.0.0/10`. IPv4-mapped IPv6 addresses are unwrapped.

#### Advertise in-range addresses by priority; skip loopback and IPv6 link-local
`local_addresses`: This machine's addresses inside the filter ranges, for the pairing code:
private LAN first, then Tailscale/CGNAT, then IPv6 ULA, then IPv4
link-local. Loopback is never listed, and neither is IPv6 link-local,
which is unusable without the interface's zone id.

#### Accepted address forms; names resolve via DNS such as MagicDNS
`resolve`: Socket addresses for one stored address: `ip`, `ip:port`, `[v6]:port`,
`host` or `host:port` (names resolve through DNS, e.g. MagicDNS).

### `LinuxWindows/crates/lokalbot-sync/src/pairing.rs`

#### QR payload is defined in protocol.md, Pairing
The QR code payload (protocol.md, Pairing).

#### Phone may show only parsed info; the secret stays in Rust
`PairingInfo`: What the phone may show about a scanned code. The secret stays in Rust.

#### Expiry is ISO 8601 UTC
`PairingInfo.expires_at`: ISO 8601 UTC.

#### Payload JSON keys follow the order protocol.md shows
`PayloadJson`: The JSON inside the code, keys in the order protocol.md shows.

### `LinuxWindows/crates/lokalbot-sync/src/records.rs`

#### Record conventions shared by both ends per records.md
Record conventions shared by both ends (records.md): kinds, canonical
JSON for change detection, and timestamps.

#### A meeting sorts before its transcript within the same sortKey
`kind_rank`: Order among records with the same `sortKey`: a meeting goes before its
transcript.

#### Sorted keys, no whitespace so equal content gives equal bytes
`canonical_json`: JSON with object keys sorted and no whitespace, so equal content always
serialises to the same bytes.

#### Record timestamps are ISO 8601 UTC with milliseconds
`iso`: An instant in the records' format: ISO 8601 UTC with milliseconds.

#### Today uses this device's time zone, YYYY-MM-DD
`local_today`: Today's date in this device's time zone, `YYYY-MM-DD`.

### `LinuxWindows/crates/lokalbot-sync/src/server/answers.rs`

#### Answers outlive the connection; same requestId resumes the answer
Answers outlive the connection that asked. A phone that locks or leaves
Wi-Fi drops its connection, but the Mac finishes the answer and keeps it;
asking again with the same `requestId` picks the answer up: the text so
far at once, then the rest as it arrives, or the finished result.

#### Keep at most 100 finished answers, oldest dropped first
`MAX_FINISHED`: At most this many finished answers are kept; the oldest go first.

#### Failed answers are never kept so asking again asks the Mac again
`Answers::begin`: The answer to `request_id` from this device, and whether it is new
(the Mac still has to be asked). Finished answers older than
`retention` are forgotten first, and failed ones are never kept, so
asking again after a failure asks the Mac again.

#### A failed answer leaves so the next ask starts over
`Answers::forget`: A failed answer leaves, so the next ask starts over.

#### Closed listener sessions are dropped at the next send
`State.listeners`: Sessions waiting for this answer; a closed one is dropped at the next
send.

#### Send text so far as one askDelta, then new deltas, then end
`Answer::attach`: Starts sending this answer to a session: the text so far as one
`askDelta`, then each new delta, then the end. A finished answer is
sent whole at once.

#### Notify waiting sessions, then forget the answer
`Answer::failed`: Tells every waiting session, then forgets the answer.

### `LinuxWindows/crates/lokalbot-sync/src/server/mod.rs`

#### Cap simultaneous connections at 64, above any person's device count
`MAX_CONNECTIONS`: More simultaneous connections than any person's devices need.

#### Companion database lives at \<library>/companion/companion.sqlite
`ServerConfig.db_path`: `<library>/companion/companion.sqlite`.

#### Default port 17890; 0 picks a free port, see bound_port
`ServerConfig.port`: 17890 by default; 0 picks a free port (see `bound_port`).

#### QR text is a lokalbot://pair?d=... URL
`PairingOffer.qr_payload`: `lokalbot://pair?d=…`, the text of the QR code.

#### pairing_id is base64url, matching pid in the payload
`PairingOffer.pairing_id`: base64url, as `pid` in the payload.

#### expires_at is ISO 8601 in UTC
`PairingOffer.expires_at`: ISO 8601 UTC.

#### Platform is one of ios, ipados or android
`PairedDevice.platform`: `ios`, `ipados` or `android`.

#### paired_at is ISO 8601 in UTC
`PairedDevice.paired_at`: ISO 8601 UTC.

#### Op status is applied, unmatched or rejected
`OpOutcome.status`: `applied`, `unmatched` or `rejected`.

#### Upload status: accepted (device may delete), deferred (retry), rejected
`UploadOutcome.status`: `accepted` (the Mac keeps it; the device may delete its copy),
`deferred` (try again later) or `rejected` (it can't be used).

#### meeting_id is set only when the upload was accepted
`UploadOutcome.meeting_id`: The meeting it became, when accepted.

#### Delegate is implemented by the Mac app and called on background threads
`ServerDelegate`: Implemented by the Mac app. Called on background threads.

#### Approval may block up to 120 s; no answer means refusal
`ServerDelegate.approve_pairing`: Asks the person whether to pair this device. May block up to 120 s;
no answer by then counts as a refusal.

#### Republish affected records before returning so they precede the op result
`ServerDelegate.apply_op`: Applies a phone's op. Republish the affected records before returning;
they reach the phone before the op's result.

#### Ask may return before finishing; the sink works from any thread
`ServerDelegate.ask`: Answers a question through `sink`. May return before the answer is
finished; the sink works from any thread.

#### Fired when a device pairs, is removed, connects or disconnects
`ServerDelegate.devices_changed`: A device paired, was removed, connected or disconnected.

#### While false devices keep recordings and retry later without sending audio
`ServerDelegate.accepts_recordings`: Whether this Mac takes recordings from devices right now. While false
a device keeps them and tries again later, sending no audio.

#### Return only once the meeting is stored; the device then deletes its copy
`ServerDelegate.receive_recording`: A device's recording arrived whole and matches its checksum. Reads
`file_path` (an ADTS AAC stream the crate owns and deletes) and makes
a meeting from it. May block for as long as that takes; return only
once the meeting is safely stored, because the device then deletes
its copy. `recording_json` is protocol.md's recording plus `deviceId`,
`deviceName` and `platform`, which come from the pairing.

#### Mac finishes an answer even if the phone disconnects; same requestId retrieves it
`AskSink`: Streams one answer to the phone that asked. The Mac finishes it even if
the phone disconnects, and the phone gets it by asking again with the
same `requestId` (see `answers`). Calls after the answer finished are
ignored.

#### Final answer is the Ask result from records.md, as JSON
`AskSink.done`: The final answer: records.md's Ask result, as JSON.

#### Tracks recordings being received or imported by the Mac
`ServerInner.active_uploads`: Recordings a session is receiving or the Mac is importing.

#### Binds 0.0.0.0 and [::] on the port; either may be missing
`SyncServer.start`: Binds `0.0.0.0:port` and `[::]:port` (either may be missing on this
machine) and serves on background threads.

#### Returns the actually bound port while running, else the configured one
`SyncServer.bound_port`: The port actually bound while running, else the configured one.

#### Loopback-only listening for dev hosts and tests, applies at next start
`SyncServer.set_loopback_only`: Listens on 127.0.0.1 and ::1 only, for development hosts and tests.
Takes effect at the next `start`, which then fails if 127.0.0.1 is
taken on the configured port; port 0 finds one free on both.

#### Publish returns true only when content changed, then pushes to devices
`SyncServer.publish`: Publishes a record body. Returns true when it changed (a new version
and seq), and pushes it to connected devices.

#### Removal writes a tombstone and returns whether the record existed
`SyncServer.remove`: Replaces a record with a tombstone. Returns true if it existed.

#### Manifest is the record of kind manifest with key library
`SyncServer.set_manifest`: Publishes the `manifest` record (key `library`).

#### Lists only live (not deleted) record keys of a kind
`SyncServer.record_keys`: Keys of the live (not deleted) records of one kind.

#### A new offer replaces any open one; empty addresses use local_addresses
`SyncServer.begin_pairing`: Opens a pairing offer, replacing any open one. `addresses` go into the
code; an empty list uses `local_addresses()`.

#### Removed device's live session gets revoked; later connections refused the same way
`SyncServer.remove_device`: Forgets a device's key. A live session from it is told `revoked` and
closes; later connections are refused the same way.

#### Offer is consumed once after handshake; losers of the race fail
`ServerInner.consume_offer`: Consumes the offer after a successful handshake; false if another
handshake got there first or it was cancelled.

#### Bind IPv6 first, then IPv4
`listen_hosts`: What a host binds, IPv6 first.

#### Retry fresh ports when the IPv6 loopback port is taken on IPv4
`LOOPBACK_PORT_ATTEMPTS`: Fresh ports a loopback host tries when the one `[::1]` got is already
taken on 127.0.0.1.

#### Listen on IPv6 then IPv4 on one port
`bind`: Listeners for IPv6 and IPv4, IPv6 first, on one port.

#### Injectable bind function lets tests simulate a taken port
`bind_with`: `bind`, with each socket bound by `bind_one`, so tests can hand it a
port that is taken.

#### Dual-stack IPv6 may block IPv4 bind; IPv6 alone serves both
`bind_wildcard`: Where `[::]` is dual-stack (Linux, macOS) the IPv4 bind may fail with
"address in use" and the IPv6 listener serves both; where IPv6 is
missing, IPv4 alone serves.

#### Loopback hosts must serve IPv4 so pairing codes reach this host
`bind_loopback`: Every loopback host hands out 127.0.0.1 (the tests, the engine's
development host, the example host), so IPv4 must be served: a host on
`[::1]` alone would send phones to whatever else holds 127.0.0.1 on that
port, and pairing would fail as if the code were wrong. `[::1]` is extra,
for clients that resolve `localhost`, and may be missing.

IPv4 and IPv6 ephemeral ports are handed out separately, so with port 0
the port `[::1]` got may be taken on 127.0.0.1; then another is tried.
A fixed port that is taken on 127.0.0.1 is an error.

#### Hold rejected listeners so Linux does not hand the same port back
`bind_loopback`: Held until this returns: closed, Linux may hand the same port back.

#### Windows reports exclusive or reserved ports as access denied
`bind_loopback`: Windows reports a port another socket holds exclusively, or
one in a reserved range, as "access denied".

### `LinuxWindows/crates/lokalbot-sync/src/server/session.rs`

#### Session uses a reader thread and a worker thread handling events serially
One accepted connection: the preface, then either pairing or a session.

A session has two threads. The reader turns packets into events; the
worker (this connection's thread) handles events one at a time: hello,
catch-up, ops, questions, recordings, live pushes, pings and revocation.

#### Wait for phone to close after final message so data is not cut off
`LINGER`: How long the host waits for the phone to close after a final message, so
closing never cuts off data the phone has not read yet.

#### Unknown, expired or cancelled offers get no handshake at all
`serve_pairing`: An unknown, expired or cancelled offer gets no handshake at all.

#### Pairing handshake message 1: initiator ephemeral key
`serve_pairing`: -> e

#### Pairing handshake message 2: responder ephemeral and static keys
`serve_pairing`: \<- e, ee, s, es

#### Pairing handshake message 3 fails on a wrong pre-shared secret
`serve_pairing`: -> s, se, psk (fails on a wrong secret)

#### Ask delegate on its own thread so pings continue; timeout means refusal
`await_approval`: Asks the delegate on its own thread, so the connection keeps pinging
while the person decides. No answer within the timeout is a refusal.

#### Session handshake message 1 notation: e, es, s, ss
`serve_session`: -> e, es, s, ss

#### Unpaired keys get no reply, not even confirmation of LokalBot
`serve_session`: A key this Mac never paired learns nothing, not even that it
reached LokalBot.

#### Session handshake message 2 notation: e, ee, se
`serve_session`: \<- e, ee, se

#### Close sessions that finish handshake after stop was called
`run_session`: `stop` closes the sessions it finds; one that finished its handshake
just after must not live on.

#### All records up to sent_seq have already been sent
`Worker.sent_seq`: Every record with a seq up to this one has been sent.

#### Next event pings while idle and returns None at deadline
`Worker.next`: The next event, pinging while idle. `None` at the deadline.

#### Catch-up sends records newest first and ends with done true
`Worker.catch_up`: Everything after the phone's cursor, newest first, ending `done: true`.

#### A cursor beyond the database means it was recreated; send everything
`Worker.catch_up`: A cursor beyond this database means it was recreated: send all.

#### Batches capped at batch_bytes; oversized record goes alone; last is done
`Worker.send_records`: Sends the records' current state in batches of at most `batch_bytes`
of JSON (one larger record goes alone); the last is `done: true`.

#### Send republished records before the op result
`Worker.apply`: Applies one op through the delegate, then sends the records it
republished, then the op's result.

#### Repeat ask attaches to an answer being written or kept
`Worker.ask`: Asking again for an answer the Mac is writing or kept attaches to it.

#### Starting a new recording releases the previous one, kept for later
`Worker.upload_begin`: Starting another recording lets go of the last one, kept for later.

#### Import runs on its own thread; disconnected phone learns outcome on resend
`Worker.upload_finish`: Checks the recording and hands it to the Mac on its own thread, so
the connection keeps pinging meanwhile. A phone that disconnects
doesn't stop it; it hears the outcome when it sends the recording
again.

### `LinuxWindows/crates/lokalbot-sync/src/server/store.rs`

#### Companion database is derived; deleting it forces re-pairing and full re-sync
The Mac's companion database: published records, the change counter and
paired devices. Derived data plus device keys; deleting it means
re-pairing and a full re-sync.

#### Publish is a no-op when canonical body is unchanged
`HostStore.publish`: Stores a new version unless the canonical body is unchanged. Returns
the new seq, or `None` for a no-op.

#### sortKey per records.md: startedAt, date, transcript's meeting start, else publish time
`HostStore.sort_key`: `sortKey` (records.md): a meeting's `startedAt`, a day's date, a
transcript its meeting's `startedAt`, everything else the publish time.

#### Remove replaces a live record with a tombstone, None if absent
`HostStore.remove`: Replaces a live record with a tombstone. Returns the new seq, or
`None` when there was nothing to remove.

#### Newest first by sortKey, meeting before transcript on ties
`HostStore.changed_keys`: Records with `after < seq <= upto`, newest first by `sortKey`; a
meeting before its transcript on equal keys.

#### Re-pairing replaces the old entry and clears revocation
`HostStore.add_device`: Stores a newly paired device. A device that pairs again replaces its
old entry, and its key is no longer revoked.

#### Removed key is remembered as revoked so the device erases its copy
`HostStore.remove_device`: Forgets a device and remembers its key as revoked, so a later session
from it is told to erase its copy. Returns whether it existed.

#### Remember received uploads so lost confirmations resolve even after meeting deletion
`HostStore.received_upload`: Whether this recording already arrived, and the meeting it became.
Answers a device that never saw the confirmation, even after the
person deleted the meeting.

### `LinuxWindows/crates/lokalbot-sync/src/server/uploads.rs`

#### Partial file length is the resume point; nothing else kept until whole
Recordings arriving from paired devices (protocol.md, Flow for
`purpose: "upload"`). A partial file's length is how far it got, so a
dropped connection resumes where it stopped; nothing else about an upload
is kept until it is whole.

#### 4 GiB cap, far above a day of 64 kbit/s audio
`MAX_BYTES`: Far more than a day of the apps' 64 kbit/s audio.

#### Decoded chunk limit of 1 MiB
`MAX_CHUNK_BYTES`: Base64 of a chunk may not decode to more than this.

#### Limit concurrent uploads to stop one device stacking imports by reconnecting
`MAX_ACTIVE`: Recordings arriving or being imported at once, which keeps one device from
stacking up imports by reconnecting. Nobody has this many devices recording.

#### Device folder named by hash since device ids are untrusted
`device_directory`: The folder of one device's partial files. Device ids come from the device,
so its name is a hash of the id.

#### Directory removal failing while non-empty is expected
`remove_stale`: Fails while the folder still holds something, which is fine.

#### Claim stops a reconnected phone writing the same upload file concurrently
`Claim`: Holds an upload id for one session or import, so a phone that reconnected
can't write to the same file at once. Dropping it lets go.

#### Done means outcome is already known, nothing to send
`Begin::Done`: Nothing to send: the outcome is already known.

#### Chunk at wrong position tells phone to seek to the returned offset
`Append::Elsewhere`: The chunk wasn't for this position; the phone should seek here.

#### Upload id names a file and meeting id so must be a UUID
`begin`: The id names a file and becomes the meeting's id: only a UUID will do.

#### Partial named for AVFoundation and Symphonia types; checksum in name prevents mixing files
`open_partial`: The partial file, named so AVFoundation and Symphonia can tell its type,
and how much of it is already here. The checksum is in the name, so bytes
of a different file can never continue this one.

#### After partial write the file length is the true position
`Incoming.append`: A partial write leaves the file's length as the true position.

#### Damaged file is deleted so the next attempt restarts
`complete`: Damaged somewhere along the way: the next attempt starts over.

#### Failed arrival record is safe because Mac import is idempotent by id
`complete`: The Mac's import is idempotent by id, so a resend is safe.

#### Deferred outcome keeps the whole checked file so no audio is resent
`complete`: Whole and checked: the next attempt needs no audio sent again.

### `LinuxWindows/crates/lokalbot-sync/src/tests/address.rs`

#### Dev host asks for loopback and never gets the wildcard
`listen_hosts_follow_the_loopback_choice`: A development host asks for loopback and never gets the wildcard.

#### IPv6 ULA allowed, including Tailscale's range
`address_filter_table`: IPv6 ULA, Tailscale's range included.

#### IPv4-mapped IPv6 addresses are unwrapped before filtering
`address_filter_table`: IPv4-mapped IPv6 is unwrapped first.

#### IPv4-compatible IPv6 addresses are not unwrapped
`address_filter_table`: IPv4-compatible (not mapped) addresses are not unwrapped.

### `LinuxWindows/crates/lokalbot-sync/src/tests/client_queries.rs`

#### Actions without due date sort newest meeting first
`actions_sort_overdue_first_then_by_due_date`: no due date, newest meeting first

#### Deferred actions are not overdue
`actions_sort_overdue_first_then_by_due_date`: A deferred action is not overdue, so overdue open ones go first.

#### Open actions due within six days become overdue a week later
`actions_sort_overdue_first_then_by_due_date`: A week on, every open action due within six days is overdue.

#### FFI entry point uses the device's own date
`action_filters`: The FFI entry point uses this device's date.

#### Direct lookup still finds merged meetings so mergedInto links work
`merged_meetings_are_hidden`: A direct lookup still finds it, so links can follow `mergedInto`.

#### Merged-away newer meetings must not appear on any page
`a_page_of_meetings_counts_only_what_it_shows`: Newer than every sample meeting, but merged away: not on any page.

#### Explicit null mergedInto means not merged
`a_page_of_meetings_counts_only_what_it_shows`: An explicit null is not merged.

#### Meetings without a day sort before every day
`a_page_of_meetings_counts_only_what_it_shows`: No day: before every day, as an empty one.

#### Older versions cannot resurrect a tombstone
`a_record_keeps_its_highest_version`: An older version cannot resurrect a tombstone.

#### Unpairing must leave no old text in the database or its WAL
`unpairing_erases_everything`: Neither the file nor its WAL holds any of the old text.

### `LinuxWindows/crates/lokalbot-sync/src/tests/host_store.rs`

#### Republishing revives a removed record with the next version
`removal_writes_a_tombstone`: Publishing again revives it with the next version, even unchanged.

#### People, projects and manifest use publish time as sort key
`sort_keys_follow_records_md`: People, projects and the manifest use the publish time.

#### Orphan transcript falls back to publish time
`sort_keys_follow_records_md`: A transcript published before its meeting falls back to the publish time.

### `LinuxWindows/crates/lokalbot-sync/src/tests/keys.rs`

#### Test vector from RFC 7748 section 6.1, Alice
`public_key_follows_rfc_7748`: RFC 7748 section 6.1, Alice.

### `LinuxWindows/crates/lokalbot-sync/src/tests/listen.rs`

#### Loopback host must serve 127.0.0.1 despite separate ephemeral ports per family
The host's listeners. A loopback host hands out 127.0.0.1, so it must
serve it, even though IPv4 and IPv6 ephemeral ports are picked
separately and the port `[::1]` gets may already be taken on 127.0.0.1.

#### Simulates kernel handing out colliding IPv4 and IPv6 loopback ports
`collision`: A listener on 127.0.0.1 that isn't the host's, and one on `[::1]` at the
same port: what the kernel can hand a host whose two binds collide.
None where this machine has no IPv6 loopback.

#### Pairing code port must reach this host, not another socket
`a_loopback_host_moves_off_a_port_taken_on_ipv4`: What a pairing code names reaches this host, not the other socket.

#### Fixed port is the person's choice, so report clash instead of moving
`a_loopback_host_does_not_start_on_a_port_taken_on_ipv4`: A fixed port is what the person chose, so the host doesn't move; it
reports the clash instead of listening where its codes don't point.

### `LinuxWindows/crates/lokalbot-sync/src/tests/mod.rs`

#### Test dates come from the fixture so moving the sample library needs no test edits
Dates come from the fixture rather than being written into the tests, so
moving the sample library in time needs no test changes.

#### Do not hold the host database guard across server calls
`Host.server_store`: The host database. Don't hold it across calls into the server.

### `LinuxWindows/crates/lokalbot-sync/src/tests/pairing.rs`

#### Code long past expiry is refused before connecting
`an_expired_offer_fails`: A code long past its expiry is refused before connecting.

#### Phone aborts after Mac's message so the offer stays open
`a_mismatched_mac_key_fails_before_the_phone_reveals_itself`: The phone aborted after the Mac's message, so the offer is still open.

#### Approval outlasting idle timeout survives because pings carry it
`a_slow_approval_keeps_the_connection_alive_with_pings`: Longer than the phone's idle timeout; pings carry it.

#### Use a local socket's port nobody listens on and nobody else can be given
`an_unreachable_mac_is_reported`: The local end of a connection: nothing listens on its port, and no
other host can be given it, as one can a port a dropped host freed.

### `LinuxWindows/crates/lokalbot-sync/src/tests/recordings.rs`

#### Mac publishes meeting keys in uppercase
`a_recording_stays_listed_until_its_meeting_arrives`: The Mac publishes meeting keys in its own case.

#### Mac releases the upload after noticing the dropped connection
`an_interrupted_upload_resumes_where_it_stopped`: The Mac notices the connection is gone and lets go of the upload.

#### Failed recordings are not resent automatically
`a_recording_the_mac_cannot_use_is_kept_until_the_person_decides`: Failed recordings aren't sent again on their own.

#### Removal often precedes re-pairing and unsent recordings exist nowhere else
`a_revoked_device_keeps_what_has_not_arrived_until_it_pairs_again`: Removing a device is often how someone starts pairing it again, and these
exist nowhere else.

#### Closing a sample library keeps recordings; only person's removal erases
`a_revoked_device_keeps_what_has_not_arrived_until_it_pairs_again`: Closing a sample library leaves them too; only a removal by the person does not.

#### Older Macs refuse the upload purpose, leaving recordings waiting
`a_mac_too_old_for_recordings_leaves_them_waiting_and_says_why`: A Mac from before uploads existed, which refuses the session's purpose.

#### Fake old Mac holds connection until the phone has read the refusal
`a_mac_too_old_for_recordings_leaves_them_waiting_and_says_why`: Holds the connection until the phone has read that.

### `LinuxWindows/crates/lokalbot-sync/src/tests/search.rs`

#### Natural-language questions fall back to any content word
`search_covers_titles_notes_decisions_and_questions`: Natural-language questions fall back to any content word.

#### Longer spaceless CJK queries match by two-character pieces
`cjk_text_is_found_by_substring`: A longer spaceless question matches by two-character pieces.

### `LinuxWindows/crates/lokalbot-sync/src/tests/session.rs`

#### Mac closes silently on unknown devices, sending no bytes
`an_unknown_device_is_dropped_during_the_handshake`: The Mac closes without sending a single byte back.

#### A copied phone store with another key cannot sync
`an_unknown_device_is_dropped_during_the_handshake`: A copy of a paired phone's store with another key cannot sync either.

#### A new Mac version of the meeting retires the sync note
`an_unmatched_op_reverts_and_keeps_a_note`: A new version of the meeting from the Mac retires the note.

#### Asking the sample library must never connect, even with an address
`sample_ask_answers_from_the_real_store_without_connecting`: Even if an address is supplied, asking the sample must never connect.

#### Keep prompts in sync with AskModel.suggestions(for: .sample) on iOS
`sample_ask_ios_suggestions_return_cited_fixture_facts`: Keep these prompts in sync with AskModel.suggestions(for: .sample).

#### Ask agent may think for minutes; pings must outlast idle timeout
`a_slow_answer_without_text_keeps_the_connection`: The Mac's Ask agent can think for minutes before writing a word; pings
must keep the session open past the idle timeout.

#### Simulates phone giving up on an answer, as locked phone or lost Wi-Fi
`impatient`: A phone that stops waiting for the next part of an answer after `wait`,
as a locked phone or a lost Wi-Fi connection does.

#### Asking again returns the whole answer without asking the Mac twice
`an_answer_the_phone_left_is_finished_and_picked_up`: The Mac finishes without the phone; asking again gets the whole
answer at once and does not ask the Mac a second time.

### `LinuxWindows/crates/lokalbot-sync/src/tests/wire.rs`

#### Trickle peer returns one byte per read declaring a 65,535-byte packet
`Trickle`: A peer that hands over one byte per read and never runs dry. The first two
bytes declare a 65,535-byte packet.

#### Bytes read before the deadline are kept for later completion
`a_trickled_packet_stops_at_the_deadline`: The byte it brought is kept: without a deadline the packet completes.

#### A byte every 10 ms stays inside the 100 ms read timeout
`the_handshake_timeout_holds_against_a_peer_that_trickles_bytes`: A byte every 10 ms always lands inside the 100 ms read timeout.

#### Phone learns the Mac's key before sending its own
`a_pairing_handshake_with_the_wrong_psk_fails_on_the_mac`: The phone learns the Mac's key before it sends its own.

### `LinuxWindows/crates/lokalbot-sync/src/wire.rs`

#### Defaults follow the protocol; tests shorten them
`Tuning`: Timings and sizes. The defaults are the protocol's; tests shorten them.

#### Mac keeps a finished answer for phones that disconnected mid-answer
`Tuning.answer_retention`: How long the Mac keeps a finished answer for a phone that
disconnected while it was written.

#### Chunk size counts bytes before base64 encoding
`Tuning.upload_chunk_bytes`: Bytes of a recording in one `uploadChunk`, before base64.

#### Blocked reads wake to ping and check timeouts, clamped 20 ms to 5 s
`Tuning.tick`: How often a blocked read wakes up to send pings and check timeouts.

#### Packet is a 2-byte big-endian length plus bytes
`encode_packet`: A 2-byte big-endian length followed by the bytes.

#### Read timeout returns None and keeps partial packet
`PacketReader`: Splits packets off a byte stream. A read timeout returns `None` and keeps
any partial packet, so callers can wake up periodically without losing
their place.

#### Deadline stops peers trickling bytes inside each read timeout
`PacketReader.read_until`: Like `read`, and also returns `None` once `deadline` has
passed without a whole packet, so a peer that keeps sending a few bytes
inside every read timeout cannot hold the caller past it.

#### Frame is a flag byte (bit 0 = more) plus at most 60000 bytes
`split_frames`: A message's frames: flag byte (bit 0 = more follow) plus at most
[`MAX_FRAME_PAYLOAD`] bytes each.

#### Waits at most the handshake timeout for a packet
`RawConn.recv_packet`: The next packet, waiting at most the handshake timeout.

#### All frames of a message are written under one lock to prevent interleaving
`Channel`: The sending half of an encrypted connection, shared by every thread that
writes to it. A message's frames are written under one lock, so messages
from different threads never interleave.

#### Shutting down the socket also wakes a blocked reader
`Channel.close`: Shuts the socket down, which also wakes a reader blocked on it.

#### Pings while idle; fails after idle timeout or at deadline
`Inbox.recv`: Waits for the next message, sending pings while idle. Fails after the
idle timeout without a packet, or at `deadline`.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
