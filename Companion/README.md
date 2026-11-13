# LokalBot companion apps

iPhone, iPad and Android apps that show what LokalBot on your Mac remembers:
meetings, action items, the Timeline and Day Digests (including earlier days),
People and Projects. They also send questions for your Mac to answer, and
record meetings for it to process.

The Mac stays the source of truth. A phone or tablet holds an end-to-end
encrypted, allowlisted copy that it gets straight from the Mac over your
local network or your Tailscale network. There is no LokalBot server and no
cloud in between. The plan and its decisions are in
[Docs/plans/companion-apps-plan-2026-10-30.md](../Docs/plans/companion-apps-plan-2026-10-30.md).

## Layout

| Path | What |
| --- | --- |
| [protocol/](protocol/) | The contract: [protocol.md](protocol/protocol.md) (wire protocol), [records.md](protocol/records.md) (record schema), [ffi.md](protocol/ffi.md) (shared Rust API), [fixtures/sample-library.json](protocol/fixtures/sample-library.json) (sample library every part tests against) |
| [design/](design/) | `tokens.json` (the Mac app's design tokens) and `generate.mjs`, which writes the Swift and Kotlin copies |
| `../LinuxWindows/crates/lokalbot-sync/` | The Rust core shared by the Mac, iOS and Android: Noise sessions, pairing, records, the phone's local store and search, UniFFI bindings |
| [ios/](ios/) | The iPhone and iPad app (SwiftUI) and its `LokalBotCompanionKit` package |
| [android/](android/) | The Android app (Jetpack Compose, Material 3 Adaptive) |
| `../LokalBot/Services/Companion/` | The Mac side: record builders, publisher, host and Settings → Phones & tablets |

## How it works

1. On the Mac, turn on **Settings → Phones & tablets** and choose what to share.
   Nothing listens until you do.
2. Choose **Add a device** and scan the QR code with the phone. The code holds
   a one-time secret that expires after 5 minutes. Approve the device on the Mac.
3. The phone syncs whenever it can reach the Mac: on the same Wi-Fi (found by
   Bonjour), or from anywhere with Tailscale on both devices. It keeps a full
   local copy, so everything already synced stays readable offline.
4. Questions asked on the phone are answered by the Mac's Ask agent with your
   engine and approvals. When the Mac can't be reached, the phone searches its
   own copy or queues the question.
5. **Record** on the phone captures a meeting, carrying on with the screen
   locked. The file goes to the Mac as soon as it's reachable, resuming if the
   connection drops, and leaves the phone once the Mac has stored it. The Mac
   makes a meeting of it and processes it like any other, and it comes back to
   the phone with its transcript and summary. The audio is an ADTS AAC stream,
   so a crash or a dead battery costs only the last moments; a recording cut
   short goes to the Mac like any other at the next launch.

## Building

Everything needs Rust (`rustup`; the toolchain is pinned in
`LinuxWindows/rust-toolchain.toml`).

```sh
# Shared Rust core: tests
cd LinuxWindows && cargo test -p lokalbot-sync

# Swift package for the Mac app and the iOS app (writes Vendor/lokalbot-sync/)
Scripts/build/build-sync-xcframework.sh

# Android native libraries and Kotlin bindings (needs the Android NDK)
Scripts/build/build-sync-android.sh

# Design tokens after editing tokens.json
node Companion/design/generate.mjs
```

The iOS and Android READMEs in their folders cover building and installing
each app. The Android app is on [Google Play](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion), and each
LokalBot release also attaches the signed APK, under a different key from Play's
([Android releases](../Docs/releasing/android.md)). The iPhone and iPad app isn't in the
App Store yet, and has no download, because iOS installs apps only through the
App Store or TestFlight.

## Trying it without the Mac app

`lokalbot-sync` has a development host that serves the sample library, so a
phone can pair and sync before the Mac side is involved:

```sh
cd LinuxWindows
cargo run -p lokalbot-sync --example companion_host -- --name "Dev Mac"
```

It prints the pairing link and a QR code, asks `y`/`n` when a device pairs
(`--auto-approve` skips that), applies action changes, answers questions
with a canned reply and keeps the recordings devices send in its `uploads/`
folder. Type `pair` for a new code, `devices`, `remove <id>`,
`publish` or `quit`. `--port`, `--dir` and `--loopback` are optional. Both apps
also have **Try it without a computer**, which loads the same sample library on the
device.

## End-to-end tests

`Companion/e2e/` runs each app against that development host, and CI runs each
one when that app or the sync core changes. No desktop app or real phone is
involved.

- **Android** (`android_trip.py`) installs the shrunk release build on an emulator,
  opens the QR scanner, pairs, syncs, opens every screen, asks a question and
  records, including a recording cut off by a force-stop and one made while the
  host is away. Before that it cancels a pairing on the phone and then allows it
  on a host that asks first, and checks the pairing is kept and synced. It pairs
  through the link, so no QR code gets decoded. The
  emulator's microphone is silent, so it proves the recorder, its service and the
  upload, not how speech sounds.
- **iOS** (`ios_trip.py`) runs a Debug build in the Simulator: it pairs, syncs,
  changes an action item and sends a fixture queued with `-demoQueueRecording`,
  including one queued while the host is away. It never starts the recorder,
  because the Simulator's microphone is the Mac's.

The top of each script has the command to run it. On a machine other people use
at the same time, wrap the Android test in `own_emulator.py`, which boots an
emulator and adb server nobody else's adb can see. When the Android test fails in
CI, the job's reports hold a screenshot, the UI tree, logcat, the host's log and
the R8 mapping that decodes a stack trace. iOS keeps a screenshot, the app's log
and the host's log.

Check these on a real phone before a store release, because the tests can't: real
speech, recording with the screen locked, a phone call interrupting a recording,
and a phone recording transcribed on each desktop app.
