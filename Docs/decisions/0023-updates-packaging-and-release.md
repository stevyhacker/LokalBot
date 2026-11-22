# 0023. Updates, packaging and release

- Status: Accepted
- Date: 2026-11-20

## Context

This feature covers how LokalBot is built, signed, packaged, released and updated. The Mac app updates through Sparkle from an appcast; the Windows and Linux app has its own updater (`lokalbot-update`) that checks Sparkle-compatible signatures and replaces its own files, and it ships as a Windows build and as .deb, .rpm and Arch packages with apt and dnf repositories. It also covers the phone apps' release builds, the CI gates a release candidate passes, the plugin packages and the website's media serving. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Finding and verifying updates

### Updates are found automatically but installed only when the person chooses

While "Check for updates automatically" is on, the Windows and Linux app reads the latest release's feed shortly after launch and once a day, and "Check for Updates…" in Settings checks at any time. As with Sparkle's defaults, which the Mac app's `AppUpdateManager` gets from Sparkle's standard driver, nothing is downloaded or installed until the person chooses Install and Relaunch in Settings → General or the tray menu. A newly found version is announced once with a notification.

Where: `LinuxWindows/crates/lokalbot-app/src/updates.rs`.

### An update is verified before it is unpacked, against the version its signed archive names

Installing downloads the archive and checks its size, SHA-256 and Ed25519 signature before unpacking it. The signed archive names its version, so a feed cannot relabel an older signed archive as this release.

Where: `LinuxWindows/crates/lokalbot-app/src/updates.rs`, `LinuxWindows/crates/lokalbot-update/src/client.rs` (`Updater.prepare`).

### Windows and Linux updates are signed with the Mac app's Sparkle Ed25519 key

The archive carries a Sparkle-compatible Ed25519 signature over its bytes, made with the same `SPARKLE_PRIVATE_KEY` that `sign_update` uses for the DMG, so the macOS app's `SUPublicEDKey` verifies it too. The updater's `PUBLIC_KEY` must equal `SUPublicEDKey` in `LokalBot/Info.plist`, and `Scripts/release/release-preflight.py` fails when the two differ. Sparkle's private key is base64 text in one of two forms (`common_cli/Secret.swift`): a 32-byte seed or, for keys made by older Sparkle releases, the 64-byte orlp expanded secret key followed by the 32-byte public key. Both are accepted and sign identically.

Where: `LinuxWindows/crates/lokalbot-update/src/signature.rs`, `LinuxWindows/crates/lokalbot-update/src/lib.rs` (`PUBLIC_KEY`).

### A copy that cannot replace itself, or that a package manager installed, is sent elsewhere

When a copy cannot replace its own files (`/opt`, Program Files, a source build), the update is offered as a download from GitHub. A copy a package manager installed is told to update through it: the AUR's `lokalbot-bin` with `yay -Syu`, the release's .deb and .rpm with `apt upgrade` and `dnf upgrade` once LokalBot's repository was added, and otherwise (the Arch package, or a .deb or .rpm from before the repository) by installing the new package.

Where: `LinuxWindows/crates/lokalbot-app/src/updates.rs`.

### Relaunching for an update saves the recording first, and the old copy stays if it can't

After swapping the files, and before the new copy starts, the app saves any recording and then stops the llama.cpp servers; Agent Mode stops its processes as LokalBot quits. When the recording could not be saved, `prepare_to_quit` returns false, the engine has already said why, and this copy stays instead of relaunching.

Where: `LinuxWindows/crates/lokalbot-app/src/updates.rs` (`prepare_to_quit`).

### The dev build never updates itself

`isUpdaterEnabledForThisBuild` is compiled to `false` in the dev configuration (`LOKALBOT_DEV`), which ships a distinct bundle id that the prod appcast must never replace.

Where: `LokalBot/Services/App/AppUpdateManager.swift` (`AppUpdateManager.isUpdaterEnabledForThisBuild`).

### The appcast points at the exact versioned asset of a real repository

The enclosure points at the version-specific asset, not `/latest/`, so Sparkle downloads exactly the build it advertised. The script refuses the placeholder repository slug: its enclosure and release URLs would point at github.com/OWNER/REPO, and a feed like that stops updates for everyone who reads it.

Where: `Scripts/release/generate_appcast.py` (`main`).

## Installing an update on Windows and Linux

### New files are staged beside their targets and renamed in, and Windows moves running executables aside

Every new file is first copied next to the file it replaces, so the final step is a rename within one folder. Linux renames over the old file, and running processes keep the old inode. Windows cannot replace a running executable but can rename it, so `lokalbot.exe` and `lokalbot-cli.exe` (which a coding agent may hold open as its MCP server) become `.old` files that the next start deletes. A failure part-way restores every file already replaced.

Where: `LinuxWindows/crates/lokalbot-update/src/install.rs`.

### Renames on Windows wait while something briefly holds the file

Antivirus holds a new file for a moment, and so does anything reading a running executable's version details, as LokalBot does to name the focused app, so a rename waits for the file instead of failing.

Where: `LinuxWindows/crates/lokalbot-update/src/install.rs` (`rename_when_free`).

### Leftover cleanup skips folders an install is replacing files in

`remove_leftovers` runs 0, 10 and 60 seconds after the app starts and skips the folders in `REPLACING`. It used to delete the `.new` file of an install under way (an update started at launch on a slow machine), and the rename then failed with "No such file or directory".

Where: `LinuxWindows/crates/lokalbot-update/src/install.rs` (`REPLACING`).

## Mac build, signing and install

### Library validation stays on, and vendored dylibs are signed by the team before the bundle is sealed

A hardened-runtime app can load only bundled dylibs signed by the same team unless library validation is disabled. Validation stays on, and the vendored native runtimes are signed after Copy Bundle Resources but before Xcode seals the app bundle.

Where: `Scripts/build/sign-bundled-native-code.sh`.

### Local reinstalls keep the TCC identity: update the bundle in place and re-sign only the outer bundle

The reinstall updates the existing /Applications bundle in place instead of deleting it first, so macOS TCC grants keep pointing at the same signed app identity. Xcode's Developer ID export writes its own form of the designated requirement; when that text differs from the installed app's but the build still satisfies the installed requirement, the outer bundle is re-signed with the installed requirement. Nested code keeps the signatures the archive gave it: `--deep` would re-sign Sparkle and `lokalbot-cli` with the app's entitlements and break them.

Where: `Scripts/build/reinstall-preserve-permissions.sh`, `Scripts/media/readme-gif/build_filming_app.sh`.

### Signing keychains stay on the user search list while codesign runs

codesign finds the identity's private key through the user keychain search list, even with `--keychain`. Without it the DMG signature fails with "The specified item could not be found in the keychain."

Where: `Scripts/tests/test_release_signing_boundary.py` (`test_signing_keychains_are_searchable_while_codesign_runs`).

### Native runtimes install content-addressed, and every file is validated on reuse

A content-addressed installation keeps a running helper's dylibs stable across app updates. Every file is validated on reuse, because size and a success marker alone cannot detect same-size updates, corruption or a missing dependency.

Where: `LokalBot/Engines/SherpaOnnxRuntime.swift` (`NativeRuntimeInstaller`).

### Old runtime versions are removed unless claimed or executing, as a best effort

Each signed build re-signs the bundled binaries with a fresh timestamp, so every update used to leave its previous version (about 50 MB) behind for good (#406). A version stays while any LokalBot holds its claim or any process executes from it; everything else in `root` goes, including the flat layout older releases installed and interrupted installs. A failure here never fails the install.

Where: `LokalBot/Engines/SherpaOnnxRuntime.swift` (`NativeRuntimeInstaller.removeUnusedVersions`).

### llama.cpp is built from pinned source for the app's real deployment target

Upstream release binaries currently declare macOS 26, so copying them would make a nominally macOS 15 app fail at launch. Building from the checksum-pinned source archive keeps the public minimum honest and avoids host-specific CPU instructions (`GGML_NATIVE=OFF`).

Where: `Scripts/build/fetch-llama.sh`.

### The ONNX Runtime license is committed, not downloaded

On 2026-11-18 github.com/microsoft/onnxruntime started answering 404, which broke every clean build. The committed MIT license has the same bytes as the `$ONNXRUNTIME_VERSION` LICENSE.

Where: `Scripts/build/fetch-sherpa.sh` (`ONNXRUNTIME_LICENSE`).

### Rust static libraries are prelinked so only their UniFFI functions stay global

A Rust static library carries its own copy of the Rust standard library, so two of them in one app (FluidAudio's text processing is another) clash on symbols like `_rust_eh_personality`. Each slice is prelinked into one object in which only the UniFFI functions stay global, and a check confirms those are exactly the functions the header declares. Only machine-code symbols are listed: Rust's standard library embeds LLVM bitcode, which older Xcode linkers keep through `ld -r` and whose tools can't parse a newer Rust's LLVM.

Where: `Scripts/build/build-sync-xcframework.sh`.

### An XCFramework's header and module map sit in a folder named after the module

This way they never collide with another XCFramework's `module.modulemap` in Xcode's shared include directory; clang finds `<dir>/<Module>/module.modulemap`.

Where: `Scripts/build/build-sync-xcframework.sh`.

## Windows and Linux packages and repositories

### The Windows executable embeds the icon and version details but no manifest of its own

GPUI already embeds the application manifest (per-monitor DPI awareness, common controls v6).

Where: `LinuxWindows/crates/lokalbot-app/build.rs`.

### Windows builds ship the build machine's Visual C++ runtime beside llama-server

llama.cpp's Windows builds import the Visual C++ runtime, which Windows lacks until something installs the Visual C++ Redistributable. The package ships the build machine's copy unmodified (Distributable Code under the Visual Studio license terms), and LokalBot copies it beside each `llama-server.exe` (`lokalbot-ai`'s `runtime.rs`).

Where: `LinuxWindows/scripts/package.sh`.

### Linux packages declare what the binaries and the downloaded llama.cpp runtime need

The binaries need glibc 2.39 (built on Ubuntu 24.04), link ALSA, xcb and xkbcommon, and load Vulkan and the Wayland client at run time; the downloaded `llama-server` links the GCC OpenMP runtime, `libgomp.so.1`, which minimal installs lack. On Arch, where `gcc-libs` is a meta package of every GCC runtime, namcap asks for `libgcc` and `libstdc++`, and for `hicolor-icon-theme`, which owns the icon folders. System audio uses PulseAudio or PipeWire's PulseAudio server, the suggested tools enable typing and screenshots on some desktops, and Tesseract reads screen text in scripts other than Latin (without it, ocrs reads Latin).

Where: `LinuxWindows/scripts/package-linux-distros.sh`.

### The apt repository lists its one index by hash and stores it under that hash

The index is listed in Release by SHA-256 and also stored under its hash (Acquire-By-Hash), so a cached or half-uploaded index never mismatches.

Where: `LinuxWindows/scripts/linux-repos.sh`.

### rpm signing reaches gpg through a gpg2 shim

Ubuntu's rpm looks for gpg as gpg2, which Ubuntu no longer ships.

Where: `LinuxWindows/scripts/linux-repos.sh`.

### The repository check serves HTTP/1.1 and ends TLS connections with close_notify

Debian 13's apt rejects a TLS stream that just stops ("unexpected eof").

Where: `LinuxWindows/scripts/ci/check-linux-repos.sh`.

### Generated Rust localizations escape invisible characters

Zero-width space, soft hyphen and word joiner are invisible, usually left by a translation tool, and clippy denies them in the generated Rust.

Where: `LinuxWindows/scripts/sync-localizations.py` (`INVISIBLE`).

## Phone apps

### One tag ships every platform, and the phone apps' build number is the Mac build number

`Scripts/release/bump-version.py` sets the Android and the iPhone and iPad versions. Android's versionCode and the iOS `CURRENT_PROJECT_VERSION` are the Mac build number, which only ever goes up: Android refuses a lower one, and App Store Connect refuses one it has seen.

Where: `Companion/android/app/build.gradle.kts` (`defaultConfig.versionCode`), `Companion/ios/project.yml` (`CURRENT_PROJECT_VERSION`), `Scripts/release/release-preflight.py` (`validate_ios_version`).

### Android release signing stays outside Gradle and refuses a key with the wrong certificate

The script aligns the APK, signs it with apksigner and checks the result; the release signs with the real key (`release.yml`, android-publish) and CI with a throwaway one (`companion-android.yml`). Signing stays out of the Gradle build so no build script runs beside the key. Given `CERTIFICATE_SHA256`, it refuses a key whose certificate has another digest and leaves no output APK: Android installs an update only from the key that signed the installed copy, so a wrong key would strand everyone on the older version.

Where: `Scripts/release/sign-android-release.sh`.

### APKs are aligned with -P 16

It keeps native libraries on 16 KB pages, which newer devices need.

Where: `Scripts/release/sign-android-release.sh`.

### The iPhone and iPad app is archived unsigned, then signed at export with an App Store Connect key

The `archive` job builds with `CODE_SIGNING_ALLOWED=NO` and sees no secret; the `publish` job runs no build script and signs through `xcodebuild -exportArchive` with the API key, so nothing from the build runs beside the key. Automatic signing there uses Apple's cloud-managed distribution certificate, which keeps certificates and provisioning profiles, and their yearly renewal, out of the repository's secrets. Cloud signing needs a team key with the Admin role. An unsigned archive carries no entitlements, so this holds only while the app declares none; a test fails when `Companion/ios/project.yml` gains an entitlements file, and the archive must then be signed ad hoc or with a development identity instead.

Where: `.github/workflows/app-store.yml`, `Companion/ios/ExportOptions.plist`, `Scripts/tests/test_app_store_release.py` (`test_an_unsigned_archive_carries_no_entitlements`).

### App Store What's New keeps only the release-note bullets tagged for iPhone or iPad

The release notes cover every platform, and App Review rejects metadata that names another mobile platform. Untagged bullets, and tagged ones that still name Android or Google Play, are left out; with none left the text is "Bug fixes and improvements."

Where: `Scripts/release/publish_app_store.py` (`format_whats_new`).

### A store workflow knows Release called it from an input, not the event name

A called workflow's `github` context belongs to its caller, so `github.event_name` is `push` there and never `workflow_call`. Comparing against `workflow_call` would have skipped the Google Play upload job on every real release. Both store workflows declare a `from_release` input, on `workflow_call` only, that defaults to true.

Where: `.github/workflows/google-play.yml`, `.github/workflows/app-store.yml`.

### The iOS app icon is flattened to opaque

App Store icons must be opaque, so a lossless-quality JPEG pass drops the alpha channel.

Where: `Companion/ios/Scripts/render-app-icon.mjs`.

## CI and release gates

### The release gate is a full UI test run bound to the candidate's exact SHA, which must be master's tip

UI Tests no longer runs on every master push: `prepare-release.sh` dispatches it for the candidate, and that run binds itself to the exact SHA it was asked to test before any job runs. Only a full run reports `XCUITest (macOS)`; filtered and legacy-comparison dispatches use another name. A dispatch always runs on master's tip, so it can't prepare or test an older commit.

Where: `Scripts/ci/release-candidate.py` (`GATE_EVENTS`), `Scripts/release/prepare-release.sh`.

### The newest qualifying gate run on the SHA decides

An older successful attempt cannot hide a running or failed rerun.

Where: `Scripts/ci/release-candidate.py` (`successful_gate`).

### Test products are identified by run, not attempt

A failed-jobs-only rerun keeps the build job that passed, so its consumers use products from an earlier attempt of the same run, built from the same commit, toolchain and dependency lock.

Where: `Scripts/ci/test-products.py` (`identity`).

### UI test products are built on the release toolchain and run on the oldest supported macOS

UI products are built with the release toolchain on macOS 26 and run on the oldest supported macOS, whose image has an older Xcode. Everything else about the candidate must still match, and unit-test products stay on one toolchain.

Where: `Scripts/ci/test-products.py` (`CROSS_TOOLCHAIN_KEYS`).

### The UI suite runs as two shards, with Reduce Motion last

The complete suite runs on two macOS runners after the build, about 30 and 35 minutes each (2026-11-18 timings): every runner is another job GitHub can fail to place when hosted macOS capacity is short, and a failed-jobs-only rerun repeats one group, not the suite. Each phase still writes its own report for `verify()` to check. Reduce Motion runs last so its preference can't reach another phase even if restoring it fails.

Where: `Scripts/ci/ui-shards.py` (`GROUPS`).

### The compiler cache keys on the project spec and generator, and never supplies build products

`project.yml` is the generated project and scheme authority in both workflows, and raw PBX bytes are unstable because XcodeGen can assign different object IDs to equivalent copy phases, so the key pins the specification and the generator; build scripts and workflows cover every argument, and dependency pins stay exact. CI always builds the checked-out revision: the cache can never supply a stamp, xctestrun, executable or incremental build database from another run.

Where: `Scripts/ci/compiler-cache.py` (`prepare`, `clean_products`).

### A website push never cancels a release candidate's gate runs

A new run cancels the same group's running one, so a website push must either start no run or land in a group of its own.

Where: `Scripts/tests/test_ci_pipeline.py` (`test_a_website_push_starts_nothing_that_cancels_a_candidates_gates`).

### Workflows learn whether a secret is set through env, not from an `if:`

A secret is not readable in an `if:`, so its presence travels through env; a drift run without the key is then a notice on pull requests and a failure elsewhere.

Where: `Scripts/tests/test_ci_pipeline.py` (`test_a_drift_run_without_the_key_is_a_notice_on_pull_requests_and_a_failure_elsewhere`).

### The bundle is attached to the release whatever the registry switch says

A step-level condition there is how the bundle went missing from releases.

Where: `Scripts/tests/test_ci_pipeline.py` (`test_the_bundle_is_attached_whatever_the_registry_switch_says`).

### Self-hosted Linux runners cannot reach Tailscale or private networks

CI jobs run code from pull requests, so the runner blocks the Tailscale network (the IPv4 CGNAT range and Tailscale's IPv6 prefix) and private networks (a home LAN, a hypervisor's NAT, Docker bridges, link-local). The block also stops DNS when `/etc/resolv.conf` names a private resolver (WSL's 10.255.255.254, a home router), and the runner would then never connect; a local stub such as systemd-resolved (127.0.0.53) works.

Where: `LinuxWindows/scripts/ci/runners/setup-linux-runner.sh` (`DENY`).

## Plugin directories

### The Claude plugin starts no local MCP server

The directory refuses plugins that start an MCP server on the user's computer unless the organization is Verified, which LokalBot isn't.

Where: `Scripts/tests/test_claude_plugin.py` (`test_no_local_mcp_server`).

### The Claude plugin's listing icon is found by its path and never named

Naming it in the manifest or README puts the submission on a policy hold ("image the plugin's code could run").

Where: `Scripts/tests/test_claude_plugin.py` (`test_listing_icon_is_a_square_png_in_range`).

### The plugin sync deploy key never reaches a self-hosted runner

The workflow that copies the plugin folder holds a deploy key, and that key must never reach a self-hosted runner.

Where: `Scripts/tests/test_claude_plugin.py` (`test_sync_workflow_copies_this_folder`).

### The OpenAI plugin is skills only and desktop only

Local MCP needs OpenAI's partner allowlist, and hooks or app references can't be submitted as a ZIP.

Where: `Scripts/tests/test_openai_plugin.py` (`test_skills_only_and_desktop_only`).

## Website and media

### Media byte ranges are served by a worker

Workers static assets answer byte-range requests with the whole file; Safari won't play audio or video without ranges, and other browsers can't seek. Media requests run through this worker first (`run_worker_first` in `wrangler.jsonc`), and everything else is served by the assets directly.

Where: `Website/worker/media-ranges.js`.

### The traffic report uses no vh units and no height:100% on html or body

Either breaks embedded auto-height frames.

Where: `Scripts/tests/test_traffic_report.py` (`test_render_html_respects_embed_layout_and_theme_tokens`).

### Demo video frame durations are whole microseconds, each measured from the last

Rounded durations add up, and over a long take of steady frames the video drifted seconds from its events.

Where: `Scripts/media/autocomplete-demo/encode.py` (`main`).

## Consequences

- The updater's `PUBLIC_KEY`, the Mac's `SUPublicEDKey` and the release's `SPARKLE_PRIVATE_KEY` are one key pair, and the Android release key must stay the one that signed installed copies; changing either strands everyone on the version they have.
- Updates replace files under running processes: keep the stage-and-rename install, the `.old` executables, the Windows rename retries and the `REPLACING` guard together, and on the Mac never delete the installed bundle or re-sign with `--deep`.
- A release is gated by a full UI run bound to master's exact tip; changes to CI concurrency groups, conditions, caches or shards must not let another run cancel, hide or stand in for that gate.
