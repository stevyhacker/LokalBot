# `lokalbot-sync` API (UniFFI)

The crate exposes this surface through UniFFI proc-macros to Swift (module
`LokalBotSync`) and Kotlin (package `me.dotenv.lokalbot.sync`). All calls are
blocking and thread-safe; call them off the main thread. Record bodies cross
the boundary as JSON strings in the shapes of [records.md](records.md), so
both apps decode them with their own `Codable` / kotlinx.serialization models.

Errors are one enum, `SyncError`, with variants carrying a `message`:
`Io`, `Protocol`, `Crypto`, `Storage`, `NotPaired`, `Unreachable`,
`PairingRejected`, `PairingExpired`, `Revoked`, `InvalidInput`.

## Shared

```text
fn generate_static_key() -> StaticKey            // { private_key: bytes(32), public_key: bytes(32) }
fn public_key_for(private_key: bytes) -> bytes   // X25519 public key
fn key_fingerprint(public_key: bytes) -> string  // first 16 hex chars of SHA-256, used in Bonjour TXT
fn local_addresses() -> [string]                 // this machine's private LAN + Tailscale IPs (address-filter ranges, no loopback)
fn parse_pairing_payload(payload: string) -> PairingInfo   // { mac_name, mac_key_b64, addresses, port, expires_at }
fn protocol_version() -> u32                     // 1
```

## Host (Mac): `SyncServer`

```text
constructor SyncServer.new(config: ServerConfig, delegate: ServerDelegate) -> SyncServer
  ServerConfig { db_path: string, mac_name: string, static_private_key: bytes, port: u16 }

start()                         // bind 0.0.0.0:port and [::]:port, apply the address filter, serve on background threads
stop()                          // close the listener and every session
is_running() -> bool
bound_port() -> u16

publish(kind: string, key: string, body_json: string) -> bool   // true if the record changed (new version + seq), pushed live to connected clients
remove(kind: string, key: string) -> bool                       // tombstone; true if it existed
set_manifest(body_json: string)                                 // publish(manifest, library, …)
record_keys(kind: string) -> [string]                           // live (non-deleted) keys, for reconciling deletions
current_seq() -> u64

begin_pairing(addresses: [string]) -> PairingOffer  // { qr_payload, pairing_id, expires_at }; replaces any open offer
cancel_pairing()
paired_devices() -> [PairedDevice]  // { device_id, name, platform, paired_at, last_seen_at?, last_address? }
remove_device(device_id: string)    // forget its key; a live session gets `revoked` and closes
connected_device_ids() -> [string]

callback interface ServerDelegate {
  approve_pairing(device_name: string, platform: string) -> bool   // may block up to 120 s waiting for the person
  apply_op(op_json: string) -> OpOutcome                          // { status: "applied"|"unmatched"|"rejected", message? }; the Mac republishes affected records before returning
  ask(request_json: string, sink: AskSink)                        // run the question; stream through sink; may return before finishing
  devices_changed()                                               // pairing, removal, connect, disconnect
}

object AskSink { delta(text: string); done(result_json: string); failed(message: string) }
```

The host's database (`db_path`, under `<library>/companion/companion.sqlite`)
holds the published records, the change counter and paired devices. It is
derived data plus device public keys: deleting it means re-pairing and a full
re-sync, nothing else.

## Client (phone/tablet): `SyncClient`

```text
constructor SyncClient.new(config: ClientConfig) -> SyncClient
  ClientConfig { db_path, device_id, device_name, platform, static_private_key: bytes }

// pairing and connection
pair(payload: string) -> PairedMac     // blocks until the person answers on the Mac; PairedMac { mac_name, mac_key_b64, addresses, port, paired_at }
paired_mac() -> PairedMac?
sync(extra_addresses: [string]) -> SyncReport   // connect, send queued ops, catch up, close. SyncReport { received, deleted, ops_applied, cursor, address, finished_at }
unpair()                                // erase the store and pairing (local only)
status() -> SyncStatus                  // { paired, last_sync_at?, last_address?, cursor, pending_ops, mac_name? }

// changes from the phone
set_action_status(meeting_id, action_id, status: string)   // queues an action.setStatus op and applies it to the local copy as pending

// questions
ask(request_json: string, extra_addresses: [string], listener: AskListener) -> string   // blocks; returns the result JSON; saves it to ask history
queue_question(request_json: string)    // keep for the next time the Mac is reachable
queued_questions() -> [string]
ask_history(limit: u32) -> [string]     // [{ request, result }] newest first

callback interface AskListener { on_delta(text: string) }

// reads (JSON bodies from records.md; lists are newest first)
manifest() -> string?
meetings(from_day: string?, to_day: string?, limit: u32) -> [string]
meeting(id: string) -> string?
transcript(meeting_id: string) -> string?
days(limit: u32) -> [string]                 // day keys that have a record, newest first
day(date: string) -> string?
actions(filter: ActionFilter) -> [string]    // ActionRow JSON, see below
people() -> [string]
person(id: string) -> string?
projects() -> [string]
project(id: string) -> string?
search(query: string, limit: u32) -> [SearchHit]   // { kind, key, meeting_id?, title, snippet, at?, date? }

// sample library ("Try it without a Mac")
import_records(envelopes_json: string) -> u32      // array of envelopes, e.g. fixtures/sample-library.json; marks the store as sample data
is_sample() -> bool
```

`ActionFilter { mine_only: bool, status: string? ("open"|"done"|"deferred"),
owner_unclear_only: bool, due_before: string? (YYYY-MM-DD) }`.

`ActionRow` JSON:
`{ "meetingId", "meetingTitle", "meetingStartedAt", "action": Action, "pending": bool }`,
sorted overdue first, then by `dueDate` ascending (none last), then by meeting
start descending. `pending` is true while a local status change waits for the
Mac.

Search uses SQLite FTS5 (unicode61, with the same CJK substring fallback as the
Mac) over meeting titles, summaries, notes, actions, decisions, transcript
segments and digests. `at` is the segment start for transcript hits.
