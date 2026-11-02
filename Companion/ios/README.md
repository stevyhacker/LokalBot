# LokalBot for iPhone and iPad

The companion app reads the library the Mac shares (meetings, actions, the
Timeline and Day Digests, people and projects) and asks the Mac questions.
It syncs only with the paired Mac, over the local network or Tailscale,
end-to-end encrypted. See
[the plan](../../Docs/companion-apps-plan-2026-10-30.md) and
[the protocol](../protocol/).

- `LokalBotCompanionKit/`: Swift package with the record models, design
  tokens and components, the store protocol, view models and their tests.
- `App/`: the app: scenes, screens, pairing, background refresh and
  `RustStore`, which wraps the sync core.
- `project.yml`: XcodeGen spec. `LokalBotCompanion.xcodeproj` is generated
  and not committed.

## Prerequisites

- Xcode 26.4 or later (CI pins 26.4.1) and XcodeGen: `brew install xcodegen`.
- Rust through [rustup](https://rustup.rs). The build script installs the
  toolchain pinned in `LinuxWindows/rust-toolchain.toml` and the Apple
  targets.
- Build the sync core, then generate the project. XcodeGen refuses to run
  until `Vendor/lokalbot-sync` exists:

  ```sh
  Scripts/build-sync-xcframework.sh        # writes Vendor/lokalbot-sync; --force rebuilds
  (cd Companion/ios && xcodegen generate)
  ```

  Run the script again after changing `LinuxWindows/crates/lokalbot-sync`.
  It does nothing while its inputs are unchanged. The package is arm64
  only, so the Simulator needs an Apple silicon Mac.

## Build and test

```sh
swift test --package-path Companion/ios/LokalBotCompanionKit
xcodebuild -project Companion/ios/LokalBotCompanion.xcodeproj -scheme LokalBotCompanion \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project Companion/ios/LokalBotCompanion.xcodeproj -scheme LokalBotCompanion \
  -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

CI runs the same steps in `.github/workflows/companion-ios.yml`.

## Run in the Simulator

From Xcode, choose the LokalBotCompanion scheme and an iOS 18 or later
simulator, then Run.

From the command line, sign ad hoc. The app keeps its device key in the
Keychain, which an unsigned build (`CODE_SIGNING_ALLOWED=NO`) can't use.
Such a build opens with "LokalBot couldn't open its copy on this device".

```sh
xcodebuild -project Companion/ios/LokalBotCompanion.xcodeproj -scheme LokalBotCompanion \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/lokalbot-companion \
  build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
xcrun simctl install booted /tmp/lokalbot-companion/Build/Products/Debug-iphonesimulator/LokalBot.app
xcrun simctl launch booted me.dotenv.LokalBot.companion
```

## Install on your iPhone or iPad

1. Open `Companion/ios/LokalBotCompanion.xcodeproj` in Xcode. In Xcode
   Settings → Accounts, sign in with an Apple ID on team `3N8B4562P4`.
   Signing is automatic; the bundle ID is `me.dotenv.LokalBot.companion`.
2. Connect the device. On first use, turn on Settings → Privacy & Security →
   Developer Mode on it.
3. Choose the device as the run destination and click Run.

## Pair

**With the Mac app.** On the Mac, open LokalBot Settings → Phones &
tablets, turn sharing on, and choose Add a Device. On the phone, tap Pair
with Your Mac, then scan the code or paste its link. Name the device (the
Mac shows this name), tap Pair, and allow it on the Mac. Both devices must be
on the same Wi-Fi or on Tailscale.

**With the stand-in host**, when the Mac app isn't needed. It serves the
built-in sample library, applies action changes and answers questions with a
canned reply. Run it from `LinuxWindows/`:

```sh
cargo run -p lokalbot-sync --example companion_host -- --name "Dev Mac"
```

Optional flags are `--auto-approve`, `--port 17890`, `--dir PATH` and
`--loopback`. With `--loopback` it accepts only this Mac and puts 127.0.0.1
in the code, which suits the Simulator. It prints the pairing link and a QR
code. While it runs, type `pair`, `devices`, `remove <id>`, `publish` or
`quit`, and answer a pairing request with `y` or `n`. A device scans the QR
code in the terminal; in the Simulator, paste the link, or launch with
`-demoPairLink "<link>"` (below).

## Debug launch arguments

Debug builds read these (`App/Platform/DemoLaunch.swift`). Pass them after
the bundle ID, for example
`xcrun simctl launch booted me.dotenv.LokalBot.companion -demoPaired YES -demoSection timeline`,
or add them under the scheme's Arguments.

| Argument | Effect |
| --- | --- |
| `-demoPaired YES` | The sample library in memory, shown as a Mac that synced 2 minutes ago over Wi-Fi, with "today" pinned to the sample's date |
| `-demoTailscale YES` | With `-demoPaired`: reached over Tailscale |
| `-demoUnreachable YES` | With `-demoPaired`: the Mac doesn't answer (sync and Ask fail) |
| `-demoSection <name>` | Opens `today`, `actions`, `meetings`, `timeline`, `people`, `projects`, `ask` or `settings` |
| `-demoMeeting <id>` | Opens a meeting; `-demoAt <seconds>` jumps to that moment, `-demoTab summary\|transcript\|notes` picks the tab |
| `-demoAction <meetingID>/<actionID>` | Opens an action |
| `-demoPerson <id>`, `-demoProject <id>` | Opens a person or a project |
| `-demoDay YYYY-MM-DD` | Opens that day in the Timeline |
| `-demoAsk "<question>"` | Asks a question at launch |
| `-demoWidth <points>` | Narrows the window, to stand in for Split View, Slide Over or a foldable |
| `-demoSizeClass regular\|compact` | With `-demoWidth`: overrides the horizontal size class |
| `-demoSample YES` | Loads the sample library through the sync core, as Try It Without a Mac does |
| `-demoPairLink "<link>"` | Pairs at launch; `-demoDeviceName "<name>"` names the device first |
| `-demoPairingLink "<link>"` | Opens the pairing sheet at its confirm step |
| `-demoToggleAction <meetingID>/<actionID>` | Marks an action done through the store |

## Releasing

- Set the version in `project.yml` (`MARKETING_VERSION`,
  `CURRENT_PROJECT_VERSION`).
- TestFlight: Product → Archive (Release, team `3N8B4562P4`), then
  Distribute App → App Store Connect, and add testers in App Store Connect.
- App Review can't pair with a Mac. Point the review notes to **Try It
  Without a Mac** on the welcome screen, which opens the built-in sample
  library. Explain there that the app syncs with LokalBot on the person's
  Mac over the local network or Tailscale.
- Export compliance is **still open**. Sync traffic is encrypted (Noise:
  X25519, ChaChaPoly, BLAKE2s), and `ITSAppUsesNonExemptEncryption` is not
  set yet. Until it is decided, App Store Connect asks on every upload.
- The privacy label can say Data Not Collected: nothing leaves the person's
  devices, and the local copy is excluded from device backups.
