# LokalBot companion apps

iPhone, iPad, and Android apps that record meetings offline right after install
and sync with what LokalBot on your Mac, Windows, or Linux computer remembers:
meetings, action items, the Timeline and Day Digests (including earlier days),
People, and Projects. They also send questions for your computer to answer, and
transfer recordings made on your phone or tablet for it to transcribe and
summarize.

Your computer stays the source of truth. A phone or tablet holds an end-to-end
encrypted, allowlisted copy that it gets straight from your computer over your
local network or your Tailscale network. There is no LokalBot server and no
cloud in between. Before you pair, you can still record meetings directly onto
your device; those recordings stay in private on-device storage with zero
network traffic until you pair. The plan and its decisions are in
[Docs/plans/companion-apps-plan-2026-10-30.md](../Docs/plans/companion-apps-plan-2026-10-30.md).

## Layout

| Path | Role |
| --- | --- |
| [protocol/](protocol/) | Wire contract, record schema, FFI API, sample fixture |
| [design/](design/) | Shared design tokens and Swift/Kotlin generator |
| `../LinuxWindows/crates/lokalbot-sync/` | Shared Rust core (Noise sessions, pairing, local store, UniFFI) |
| [ios/](ios/) | iPhone and iPad app (SwiftUI) and `LokalBotCompanionKit` |
| [android/](android/) | Android app (Jetpack Compose, Material 3 Adaptive) |
| [store-metadata/](store-metadata/) | App Store and Google Play ASO copy, review notes, screenshot lists |
| `../LokalBot/Services/Companion/` | macOS host, record builders, publisher, settings UI |
| `../LinuxWindows/crates/lokalbot-app/` | Windows and Linux host integration |

Protocol references live in [protocol.md](protocol/protocol.md),
[records.md](protocol/records.md), [ffi.md](protocol/ffi.md), and
[sample-library.json](protocol/fixtures/sample-library.json).

## How it works

1. **Record right away, even before pairing.** Open the app on a cold install
   and tap **Record a meeting** (or record while exploring the sample library).
   Audio streams directly to a crash-safe ADTS AAC file in private on-device
   storage excluded from device backups, continuing with the screen locked.
   Nothing is transmitted over the network while unpaired. Held recordings show
   their title, timestamp, and duration, and can be renamed or deleted on the
   device at any time.
2. **Pair with Mac, Windows, or Linux.** On your computer, open LokalBot
   **Settings > Phones & tablets**, turn sharing on, and choose what to share.
   Nothing listens until you do. Choose **Add a device** and scan the QR code
   with the phone (or paste the link). The code holds a one-time secret that
   expires after 5 minutes. Approve the device on your computer.
3. **Sync over Wi-Fi or Tailscale.** The phone syncs whenever it can reach your
   computer on the same Wi-Fi (discovered via Bonjour/mDNS) or from anywhere
   with Tailscale on both devices. It keeps a full local copy, so synced
   meetings, actions, Timeline, and digests stay readable offline.
4. **Ask with citations.** Questions asked on the phone are answered by your
   computer's Ask engine using your model and approvals. When your computer is
   unreachable, the phone searches its local copy or queues the question.
   Sharing an answer includes its cited meeting titles.
5. **Automatic encrypted transfer of recordings.** Once paired, any recordings
   saved before pairing (and any new ones you make) upload directly to your
   computer over the end-to-end encrypted Noise link, resuming if the
   connection drops. Your phone deletes its audio file once the computer
   confirms receipt. Your computer turns the audio into a meeting, transcribes
   and summarizes it, and syncs the finished notes back to your phone. A crash
   or dead battery loses only the last moments; a cut-short recording is
   recovered automatically at the next launch.

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
each app. The iPhone and iPad app is on the [App Store](https://apps.apple.com/app/id6836773709)
(iOS and iPadOS 18 or later). The Android app is on [Google Play](https://play.google.com/store/apps/details?id=me.dotenv.lokalbot.companion), and each
LokalBot release also attaches the signed APK, under a different key from Play's
([Android releases](../Docs/releasing/android.md)).

## Trying it without a desktop app

`lokalbot-sync` has a development host that serves the sample library, so a
phone can pair and sync before a desktop app is involved:

```sh
cd LinuxWindows
cargo run -p lokalbot-sync --example companion_host -- --name "Dev Computer"
```

It prints the pairing link and a QR code, asks `y`/`n` when a device pairs
(`--auto-approve` skips that), applies action changes, answers questions
with a canned reply, and keeps the recordings devices send in its `uploads/`
folder. Type `pair` for a new code, `devices`, `remove <id>`,
`publish`, or `quit`. `--port`, `--dir`, and `--loopback` are optional. Both
apps also have **Record a meeting** on the welcome screen (for immediate
offline recording) and **Try it without a computer**, which loads the same
sample library on the device.

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
