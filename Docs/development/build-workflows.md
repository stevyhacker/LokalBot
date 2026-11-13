# Build workflows

Part of the [development guide](../../DEVELOPMENT.md).

Build with Xcode 26.4 or newer (Swift 6.3 and the Metal toolchain), as required by the pinned MLX package. The app deployment target remains macOS 15.

The Xcode project is generated from `project.yml`. Regenerate it after editing project configuration or adding/removing source files:

```bash
xcodegen generate
```

Use the **LokalBot Dev** scheme for local development. Build it with:

```bash
xcodebuild -project LokalBot.xcodeproj -scheme 'LokalBot Dev' -destination 'platform=macOS' build
```

The prod and Dev targets share sources, but have separate bundle identities (`me.dotenv.LokalBot` and `me.dotenv.LokalBot.dev`) and macOS permission grants. `LOKALBOT_DEV` disables Sparkle's launch path in every Dev configuration. The dedicated **LokalBot UI Test Host** also sets `LOKALBOT_UI_TEST_HOST` and removes the menu-bar extra for XCUITest. Unit tests use the **LokalBot** scheme; see [Testing](testing.md).

Dev and UI Test Host also have separate Application Support roots and Keychain namespaces. Dev starts with its own library and downloaded models; it never imports the release library automatically. An embedded CLI resolves the enclosing app identity, including when invoked through a symlink. `LOKALBOT_STORAGE_ROOT` remains an explicit fixture/storage override.

A release-identity build run from Xcode build products (any path under `DerivedData/` or `Build/Products/`) uses `~/Library/Application Support/me.dotenv.LokalBot.local-build` and its own settings suite, and never runs the library migration, so it cannot write the installed app's library. Set `LOKALBOT_STORAGE_ROOT` to point it at another library deliberately. Only one GUI process may use a library at a time: it holds `.instance.lock` in the library root, and a second copy waits up to 10 seconds for a quitting holder, then activates the running copy and exits. Headless flags, unit tests, and UI tests do not take the lock.

App Sandbox is intentionally disabled because Core Audio process taps do not work in the sandbox. Distribution uses Developer ID signing and notarization. When the user requests reinstallation of the installed app, use `Scripts/build/reinstall-preserve-permissions.sh` to validate signing identity and update it in place.

Sharing with phones and tablets links the Rust crate `lokalbot-sync` (`LinuxWindows/crates/lokalbot-sync`) as the local Swift package `Vendor/lokalbot-sync` (product `LokalBotSync`). Xcode resolves packages before any build phase runs, so build it before `xcodegen generate` and the first `xcodebuild`:

```bash
Scripts/build/build-sync-xcframework.sh
```

It needs `rustup` and `cargo` (https://rustup.rs); it installs the toolchain `LinuxWindows/rust-toolchain.toml` pins and the Apple targets it builds (arm64 macOS, iOS, and iOS Simulator), and does nothing while the crate, `Cargo.lock`, and the script are unchanged. The app target also runs it as a pre-build phase, so a crate change is picked up by the next build. Every workflow that builds the Mac app runs it first through `.github/actions/lokalbot-sync`.

The first build uses `Scripts/build/fetch-llama.sh` and `Scripts/build/fetch-sherpa.sh` to vendor native runtimes. Read their pins and the Swift package versions from the checked-in configuration rather than copying version numbers from prose. Preserve pins unless the requested work needs an update.

The `lokalbot-cli` target shares `LokalBot/CLISupport/` and selected model files by direct source inclusion. It is built before the app and embedded in `Contents/Helpers/`; it is not a shared framework. `project.yml` separately copies `.agents/skills/lokalbot-cli/SKILL.md` into `Contents/Resources/lokalbot-cli/`. Keep that skill self-contained unless its packaging is also updated. `Scripts/release/build-mcpb.sh` packages the helper for GUI MCP clients.

Unit tests are hosted inside the prod app binary and link `libllama` directly; `-bundle_loader` resolves host-defined symbols only. Generated `default.profraw` coverage files are gitignored and should not be committed. Signing keys and populated environment files must remain outside version control.
