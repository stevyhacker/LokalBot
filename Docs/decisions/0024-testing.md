# 0024. Testing

- Status: Accepted
- Date: 2026-11-20

## Context

Testing covers the Mac app's unit tests and its UI tests against the `LokalBot UI Test Host`, the scripted window captures and demo recordings made from the app, the Windows and Linux app's live tests and CI captures, the phone apps' tests, and the scripts and nightly checks around them. Much of it exists to keep tests away from the user's real app data and to make captures come out the same on hosted runners. These decisions were moved here from code comments when the code stopped carrying comments ([ADR 0001](0001-code-carries-no-comments.md)).

## Unit tests and the installed app

### The unit-test host shares the release app's folders and preferences, so launch leaves them alone

The unit-test host shares the release app's folders, so app launch never touches them there. Unit tests also share the real preferences: finishing setup clears the saved resume state, since nothing is left to resume, and in a unit test that is the real app's preference.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.applicationDidFinishLaunching`), `LokalBot/AppState.swift` (`AppState.markSetupFinished`).

### The unit-test host gets its own llama-server folder

The llama-server folder holds the installed llama-server binary, its PID markers, owner locks and bearer tokens, and is the identity's Application Support home. The unit-test host carries the release bundle id, so it gets its own folder and never writes the installed app's markers or reads its tokens. The storage-root override does not redirect this folder either.

Where: `LokalBot/Models/App/AppDirectories.swift` (`AppDirectories.localServerSupport`).

### Unit tests stay off the network, and a model download fails the test that reached it

Unit tests share the app's code but must stay offline. A model download a test reaches is refused (`UITestRuntime.refuseDownloadInUnitTests`) and fails that test through `LokalBotTestObservation`, the test bundle's principal class (`NSPrincipalClass` in `project.yml`), which XCTest creates before the first test runs. Background work can outlive the test that started it, so a refusal can also surface in the next test to finish. Unit tests' settings turn semantic search on, so searching screens through `AppState` used to download the 310 MB embedding model.

Where: `LokalBotTests/TestSupport/LokalBotTestObservation.swift` (`LokalBotTestObservation`), `LokalBotTests/Models/App/AppIdentifiersTests.swift` (`AppIdentifiersTests.testHostedUnitTestAppStateNeverDownloadsTheEmbeddingModel`).

### Tests never call `llama_backend_free`

The llama smoke test runs in the shared test process, and freeing the global backend would break any test class that loads a model (`LlamaCotypingRuntime`'s once-let init). The smoke test only checks that `LlamaCore` imports, the dylib links and the default-params structs resolve, which needs no teardown.

Where: `LokalBotTests/Engines/LlamaCoreSmokeTests.swift` (`testBackendInitAndDefaultParamsLink`).

### Unit tests build outside the checkout, one folder per checkout

A test host inside `~/Documents` makes macOS ask for access to Documents after every build.

Where: `Scripts/test/unit-tests.sh` (`DERIVED`).

## Mac UI tests

### UI tests drive a dedicated host that skips side-effectful startup

End-to-end UI tests drive the dedicated `LokalBot UI Test Host` against a synthetic meetings library planted on disk before launch. The app sees `LOKALBOT_UI_TEST=1` and skips every side-effectful startup path (Core Audio polling, the accessibility-trusted detector, Sparkle, screenshots), so the suite needs no TCC permissions and never touches the user's real library.

Where: `LokalBotUITests/MainWindowUITests.swift` (`MainWindowUITests`).

### CI configures the desktop before XCTest starts

The display setup happens in CI, not in the tests: XCTest does not inherit ordinary shell environment variables such as `GITHUB_ACTIONS`.

Where: `LokalBotUITests/HostedDisplay.swift` (`HostedDisplay.prepareForModelLayouts`).

### The UI-test window publishes its SwiftUI request after AppKit's key-equivalent dispatch unwinds

AppKit invokes key-equivalent handling inside its event dispatch. Publishing the SwiftUI request from inside it lets the host consume Command-F without invalidating the meeting detail's state on macOS 15.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.openUITestWindow`).

## Scripted window captures

### A capture size is the outer window size and is applied before the content exists

The first layout then happens at the final size. macOS 15 grows split panes proportionally when a window is widened afterwards.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.openUITestWindow`).

### A requested capture size wins over the content's minimum size

This full-size-content window counts the 52 pt titlebar and toolbar twice when the SwiftUI minimum becomes a window minimum, so Settings' 600 pt minimum grew 1000x700 captures to 704 pt. The content minimum is kept out of the window.

Where: `LokalBot/AppLifecycle.swift` (`AppDelegate.openUITestWindow`).

### Scripted exports draw the sidebar with resolved colors

`cacheDisplay` does not flatten the sidebar's vibrancy text: AppKit gives the offscreen bitmap the mask color (black) instead of the composited label color, and the selection highlight becomes a solid black bar. Resolved colors are used only for scripted exports; the normal app and UI-test windows keep the native sidebar rendering.

Where: `LokalBot/Views/Window/MainWindowView.swift` (`MainWindowView.sidebarDestination`).

## Demo and README recordings

### The README rig captures the display minus excluded windows, not the subject app

The capture is the display with every window left out except the subject's and those of the `also` apps. Windows are listed when capture starts, so an overlay app must already be running then; panels it opens later belong to no excluded window and are captured. Naming the subject's app as the shared content instead makes macOS badge its windows with the purple "window is being shared" capsule in place of the window controls.

Where: `Scripts/media/readme-gif/rig.swift` (`filter`).

### The autocomplete demo turns off dictation and visible-window text reading

Dictation's shortcut tap sits in the keystroke path on the app's main thread, and on a busy hosted runner the rig's keys came out lost and out of order. Reading the visible window walks TextEdit's accessibility tree, which took 9 s there. Neither is part of the demo.

Where: `Scripts/media/autocomplete-demo/stage.py` (`SETTINGS`).

## Windows and Linux tests and captures

### The Linux capture script waits until the window manager advertises `_GTK_FRAME_EXTENTS`

GPUI draws its own frame and shadow only if, as it starts, the window manager lists `_GTK_FRAME_EXTENTS` as supported on the root window. Otherwise xfwm4 frames the window.

Where: `LinuxWindows/scripts/ci/capture-linux.sh` (`wm_ready`).

### Linux captures keep the pointer off the window from the start

Moving the pointer away later leaves GPUI with a stale hover under the old pointer position.

Where: `LinuxWindows/scripts/ci/capture-linux.sh` (file).

### The KWin live test types through KWin's EIS endpoint

KWin offers no virtual keyboard protocol. Keys go in through its EIS endpoint, as a remote desktop session's do, so they take the same path through KWin as a real keyboard's.

Where: `LinuxWindows/crates/lokalbot-platform/tests/live_input_method.rs` (`EisKeyboard`).

### Live KWin 6 and Sway 1.11 tests run in a separate Ubuntu 26.04 container

The Linux build and release jobs stay on Ubuntu 24.04 so shipped binaries keep their glibc 2.39 baseline ([ADR 0023](0023-updates-packaging-and-release.md)), but Ubuntu 24.04 has neither KWin 6 nor Sway 1.10+. CI therefore runs `live-kwin.sh` and `live-sway.sh` in a separate `ubuntu:26.04` Docker container on GitHub's `ubuntu-24.04` runner (self-hosted Linux runners have no Docker) with an isolated Cargo cache so Ubuntu 26.04 target artifacts never mix with Ubuntu 24.04 builds. Inside the container, `kwin-wayland`'s postinst sets `cap_sys_nice` on `/usr/bin/kwin_wayland`, which fails with `EPERM` when Docker drops that capability, so `setcap -r` clears it; `kwin-common` provides the EIS plugin; and `LANG=C.UTF-8` lets `wtype` type non-ASCII characters.

Where: `.github/workflows/linux-windows.yml` (`linux-wayland`), `LinuxWindows/scripts/ci/wayland-live-tests.sh` (file), `LinuxWindows/crates/lokalbot-platform/scripts/live-sway.sh` (file).

### The autocomplete probe never touches a Notepad the user has open

Where: `LinuxWindows/crates/lokalbot-app/examples/autocomplete_probe.rs` (`win::open`).

## Phone tests

### Android unit tests open the JDK's file descriptor internals to Robolectric

Robolectric for Android 16 reaches into the JDK's file descriptor internals, so the test JVM gets the `jvmArgs` that open them.

Where: `Companion/android/app/build.gradle.kts` (`testOptions`).

### The end-to-end tests pick emulator console ports from the even ports up to 5682

The emulator takes even console ports up to 5682 and uses the next one for adb.

Where: `Companion/e2e/own_emulator.py` (`CONSOLE_PORTS`).

### The iOS package carries a copy of the sample-library fixture, not a symlink

Some SwiftPM versions bundle a symlink as a dangling link, so the package has its own copy of `Companion/protocol/fixtures/sample-library.json`. A test fails when the two differ.

Where: `Companion/ios/LokalBotCompanionKit/Package.swift` (`sample-library.json` resource).

## Recorded data, scripts and nightly reports

### Capture traces are scrubbed with structure-preserving placeholders before they are written

Every personal string in a capture trace is replaced: letters become consonants (so any vowel in a scrubbed field reveals unscrubbed text), digits stay digits and punctuation stays, so detection patterns such as Meet codes survive while content does not. `allowlist` must stay equal to `Scripts/test/record-capture/scrub-allowlist.json`.

Where: `LokalBot/Services/Capture/CaptureTraceScrubber.swift` (`CaptureTraceScrubber`).

### The day-in-the-life rate pools word error rate across meetings

One short meeting must not decide the run. In the 2026-10-01 nightly, Parakeet heard the 14-word sprint planning as "...i'll pare on the tombstone clean up tomorrow" (21.4% for that meeting, before compounds were ignored) and the design review exactly.

Where: `Scripts/tests/test_day_in_the_life.py` (`test_day_rate_pools_meetings_so_one_short_meeting_cannot_decide_the_run`).

### A model drift run that recorded nothing is a failure, not "no drift"

In the 2026-11-10 nightly, OpenRouter answered every request with HTTP 401, each case was saved with no calls, and the report said "No drift detected."

Where: `Scripts/tests/test_model_drift.py` (`test_a_run_that_recorded_nothing_is_not_reported_as_no_drift`).

### Shell checks that run under macOS's bash use plain `[ ]` or `grep`

macOS's own bash (3.2) does not stop a `set -e` script when a bare `[[ ]]` is false.

Where: `Scripts/tests/compare-cotyping-safety.sh` (file).

## Consequences

- The unit-test host carries the release bundle id. New code that writes files, preferences, markers or tokens, or that downloads anything, has to account for it, and unit tests stay offline.
- Captures depend on setup order and OS quirks (macOS 15 split panes, the titlebar counted twice, xfwm4 frames, GPUI hover, macOS's sharing badge). Changing when the size is set, when the pointer moves or what is shared needs a fresh capture to check.
- Nightly checks must fail on runs that recorded nothing and judge pooled results, so an outage or one short sample cannot pass or fail a run on its own.
