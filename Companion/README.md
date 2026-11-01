# LokalBot companion apps

iPhone, iPad and Android apps that show what LokalBot on your Mac remembers:
meetings, action items, the Timeline and Day Digests (including earlier days),
People and Projects. They also send questions for your Mac to answer.

The Mac stays the source of truth. A phone or tablet holds an end-to-end
encrypted, allowlisted copy that it gets straight from the Mac over your
local network or your Tailscale network. There is no LokalBot server and no
cloud in between. The plan and its decisions are in
[Docs/companion-apps-plan-2026-10-30.md](../Docs/companion-apps-plan-2026-10-30.md).

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

## Building

Everything needs Rust (`rustup`; the toolchain is pinned in
`LinuxWindows/rust-toolchain.toml`).

```sh
# Shared Rust core: tests
cd LinuxWindows && cargo test -p lokalbot-sync

# Swift package for the Mac app and the iOS app (writes Vendor/lokalbot-sync/)
Scripts/build-sync-xcframework.sh

# Android native libraries and Kotlin bindings (needs the Android NDK)
Scripts/build-sync-android.sh

# Design tokens after editing tokens.json
node Companion/design/generate.mjs
```

The iOS and Android READMEs in their folders cover building and installing
each app.

## Trying it without the Mac app

`lokalbot-sync` has a development host that serves the sample library, so a
phone can pair and sync before the Mac side is involved:

```sh
cd LinuxWindows
cargo run -p lokalbot-sync --example companion_host -- \
  --fixture ../Companion/protocol/fixtures/sample-library.json
```

It prints the pairing link and a QR code. Both apps also have **Try it without
a Mac**, which loads the same sample library on the device.
