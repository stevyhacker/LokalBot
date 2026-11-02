# Companion sync protocol, version 1

This is the wire contract between the Mac (the host) and paired phones and
tablets (the clients). The Rust crate `lokalbot-sync`
(`LinuxWindows/crates/lokalbot-sync`) implements both ends; the Mac app,
the iPhone/iPad app and the Android app call it through UniFFI
([ffi.md](ffi.md)). Records are specified in [records.md](records.md).

Goals, in order:

1. Nothing leaves the person's own devices.
2. Only a device the person approved on the Mac can connect.
3. A phone that reconnects gets only what changed, newest first.

## Network

- One TCP listener on the Mac, port **17890** by default (configurable).
  It runs only while sharing is on.
- **Address filter.** Before any handshake, the host drops peers whose IP
  address is outside these ranges:
  - loopback (`127.0.0.0/8`, `::1`), used by tests;
  - private LAN: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`;
  - link-local: `169.254.0.0/16`, `fe80::/10`;
  - IPv6 ULA: `fc00::/7`, which covers Tailscale's `fd7a:115c:a1e0::/48`;
  - Tailscale and CGNAT: `100.64.0.0/10`.
  IPv4-mapped IPv6 addresses are unwrapped before the check.
- **Bonjour.** On the LAN the Mac advertises `_lokalbot._tcp` with a neutral
  instance name `LokalBot-XXXX` (4 hex digits from the Mac's key hash) and a
  TXT record `k=<first 16 hex chars of SHA-256(mac static public key)>`.
  Bonjour is platform code (NetService on Apple, NSD on Android); the Rust
  crate only takes the resolved `host:port` strings.
- Clients try, in this order and with a 2-second connect timeout each:
  addresses passed in by the platform (Bonjour results), then the addresses
  stored at pairing (LAN, Tailscale IP, MagicDNS name). The first that
  completes the handshake wins.

## Framing

Everything on the socket is a sequence of **packets**: a 2-byte big-endian
length followed by that many bytes (max 65535).

1. The client's first packet is the **preface** (plaintext, 1 + n bytes):
   - `0x01` + 16-byte pairing id → a pairing handshake follows;
   - `0x02` → a session handshake follows.
2. Then the Noise handshake messages, one per packet.
3. Then Noise transport messages, one per packet. Each decrypts to a
   **frame**: 1 flag byte + payload. Flag bit 0 = "more frames follow for
   this message". A message is the concatenation of its frames' payloads:
   UTF-8 JSON, one object, with a `type` field. Senders split messages into
   frames of at most 60000 payload bytes.

Idle connections send `{"type":"ping"}` every 20 s; either side closes after
60 s without a packet.

## Keys and Noise

- Every device has a long-term X25519 **static key**. The Mac keeps the private
  key in its Keychain through the app's existing secret store (never
  synchronized, like the Ask history key); iPhone and iPad keep it in the
  Keychain as `AfterFirstUnlockThisDeviceOnly`, not synchronizable; Android
  keeps it encrypted under a hardware-backed Keystore AES key. The platform
  passes the 32 private bytes to the Rust crate at construction.
- Prologue for every handshake: the ASCII bytes `lokalbot-companion/1`.
- **Pairing**: `Noise_XXpsk3_25519_ChaChaPoly_BLAKE2s`, PSK = the 32-byte
  one-time secret from the QR code. The client initiates. After the handshake
  the client checks that the Mac's static key equals `macKey` from the QR
  code and aborts otherwise.
- **Sessions**: `Noise_IK_25519_ChaChaPoly_BLAKE2s`. The client knows the
  Mac's static key from pairing. The host reads handshake message 1, takes
  the initiator's static key, and closes the connection without replying
  unless that key belongs to a paired device.

## Pairing

1. The Mac creates an offer: a random 16-byte `pairingId`, a random 32-byte
   `secret`, an expiry 5 minutes ahead. Only one offer is open at a time; it
   is consumed by the first successful pairing handshake or cancelled.
2. The QR payload is the string
   `lokalbot://pair?d=<base64url-no-padding(JSON)>` with JSON:

   ```json
   {
     "v": 1,
     "macName": "Stevan's MacBook Pro",
     "macKey": "<base64url 32-byte X25519 public key>",
     "addrs": ["192.168.1.20", "100.101.102.103", "macbook.tail1234.ts.net"],
     "port": 17890,
     "pid": "<base64url 16-byte pairing id>",
     "psk": "<base64url 32-byte secret>",
     "exp": 1793440000
   }
   ```
3. The client connects, sends preface `0x01 + pairingId`, runs the pairing
   handshake, then sends
   `{"type":"pairRequest","deviceId":"<uuid>","deviceName":"Stevan's iPad","platform":"ipados"}`.
   `platform` is one of `ios`, `ipados`, `android`.
4. The host asks the person (blocking, up to 120 s). It replies
   `{"type":"pairResult","approved":true,"macName":"…"}` and, when
   approved, stores the device (id, name, platform, static public key,
   paired-at). A denial, timeout, expired or unknown pairing id closes the
   connection.

## Session messages

Client → host:

| type | fields | meaning |
| --- | --- | --- |
| `hello` | `protocolVersion` (1), `schemaVersion` (1), `deviceId`, `cursor` (u64), `purpose` (`"sync"` or `"ask"`) | First message of every session |
| `op` | `op` (see records.md, Ops) | A change made on the phone |
| `ask` | `request` (see records.md, Ask) | A question for the Mac |
| `ping` | — | Keep-alive |
| `bye` | — | Clean close |

Host → client:

| type | fields | meaning |
| --- | --- | --- |
| `welcome` | `macName`, `serverTime` (ISO 8601), `manifest` (record body or null) | Reply to `hello` |
| `records` | `items` (array of record envelopes), `lastSeq` (u64), `done` (bool) | A batch of changes; `done:true` marks the end of the catch-up |
| `opResult` | `opId`, `status` (`applied`, `unmatched`, `rejected`), `message`? | Outcome of one op |
| `askDelta` | `requestId`, `text` | Next part of the answer |
| `askDone` | `requestId`, `result` (see records.md, Ask) | Final answer |
| `askFailed` | `requestId`, `message` | The Mac could not answer |
| `revoked` | — | This device was removed; erase local data |
| `error` | `code`, `message` | Protocol error; the host closes |
| `ping` | — | Keep-alive |

Flow for `purpose: "sync"`:

1. `hello` → `welcome`.
2. The client sends any queued `op`s right after `welcome`.
3. The host sends every record with `seq > cursor`, newest first by
   `sortKey` (see records.md), in `records` batches of at most 512 KB of
   JSON, the last with `done: true`, then one `opResult` per op it applied.
   Records rebuilt by an op arrive before that op's `opResult`.
4. The connection stays open; the host pushes new `records` batches
   (`done: true`) as it publishes them, until either side sends `bye` or
   closes.

Flow for `purpose: "ask"`: `hello` → `welcome` → `ask` → `askDelta`* →
`askDone` or `askFailed` → close. No records are sent.

A removed device that completes a session handshake gets `revoked` and the
connection closes. (A device whose key the host never knew is dropped during
the handshake and learns nothing.)

## Versioning

`protocolVersion` and `schemaVersion` are both 1. A host that receives a
higher major version replies `error` with code `unsupported_version`.
Unknown JSON fields are ignored on both sides; unknown message types are
ignored.
