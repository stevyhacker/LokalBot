# 0121. Scripts

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `Scripts/build/`, `Scripts/ci/`, `Scripts/cotyping/`, `Scripts/dev/`, `Scripts/media/`, `Scripts/media/agent-handoff-demo/`, `Scripts/media/autocomplete-demo/`, `Scripts/media/readme-gif/`, `Scripts/release/`, `Scripts/test/`, `Scripts/test/day-in-the-life/`, `Scripts/test/record-capture/`, `Scripts/test/scale/`, `Scripts/test/upgrade-fixtures/`, `Scripts/tests/`.

## Decisions

### `Scripts/build/build-sync-android.sh`

#### Android sync build: NDK lookup, outputs, cargo-ndk install, input-hash skip
Builds the companion sync core (LinuxWindows/crates/lokalbot-sync) for
Android and generates its Kotlin bindings, for the app's :sync module:

  Companion/android/sync/build/rust/jniLibs/\<abi>/liblokalbot_sync.so   arm64-v8a, x86_64
  Companion/android/sync/build/rust/kotlin/me/dotenv/lokalbot/sync/lokalbot_sync.kt

Uses the NDK in ANDROID_NDK_HOME, or the newest one under $ANDROID_HOME/ndk,
$ANDROID_SDK_ROOT/ndk, ~/Library/Android/sdk/ndk or ~/android-sdk/ndk.
Installs cargo-ndk and the Rust Android targets when they are missing.
Nothing is rebuilt while Cargo.lock, the crate's sources, uniffi.toml and
this script are unchanged.

  Scripts/build/build-sync-android.sh          build when the inputs changed
  Scripts/build/build-sync-android.sh --force  build anyway

#### MIN_SDK must match the Android app's minSdk
`MIN_SDK`: The app's minSdk.

#### Input hash covers sources but not tests, which do not change what ships
`build-sync-android.sh input hash`: The library's sources; its tests don't change what ships.

#### Release libraries strip UniFFI metadata symbols; read them from the static archive
`build-sync-android.sh uniffi-bindgen`: Release libraries are stripped of the symbols UniFFI reads its metadata
from; the static archive of the same build keeps them.

### `Scripts/build/build-sync-xcframework.sh`

#### Apple sync build: arm64 only, input-hash skip, reruns itself in clean environment
Builds the companion sync core (LinuxWindows/crates/lokalbot-sync) for the
Mac, iPhone/iPad and the Apple-silicon iOS Simulator, and writes a local
Swift package the Mac and iOS apps depend on:

  Vendor/lokalbot-sync/Package.swift                library product LokalBotSync
  Vendor/lokalbot-sync/LokalBotSyncFFI.xcframework  static libraries, C header, module map
  Vendor/lokalbot-sync/Sources/LokalBotSync/        generated UniFFI Swift bindings

Arm64 only, like the Mac app (Scripts/build/fetch-llama.sh, fetch-sherpa.sh).
Nothing is rebuilt while Cargo.lock, the crate's sources, uniffi.toml and
this script are unchanged. Safe to run from an Xcode build phase: it runs
itself again in a clean environment, so Xcode's SDKROOT, ARCHS and
deployment-target variables cannot leak into the Rust cross builds.

  Scripts/build/build-sync-xcframework.sh          build when the inputs changed
  Scripts/build/build-sync-xcframework.sh --force  build anyway

#### Keep caller's cargo and rustup dirs; CI images may not use ~/.cargo/bin
`build-sync-xcframework.sh clean environment`: Keep wherever the caller's cargo and rustup live: CI images and custom
installations don't always use ~/.cargo/bin.

#### Preserve DEVELOPER_DIR and custom Rust installation variables through env -i
`build-sync-xcframework.sh clean environment`: The Xcode that invoked us, and a custom Rust installation, still apply.

#### Deployment targets must match Package.swift platforms
`build-sync-xcframework.sh deployment targets`: Package.swift's platforms.

#### Input hash covers sources but not tests, which do not change what ships
`build-sync-xcframework.sh input hash`: The library's sources; its tests don't change what ships.

#### Header and modulemap in module-named folder avoid module.modulemap collisions
`build-sync-xcframework.sh headers`: The header and module map sit in a folder named after the module, so they
never collide with another XCFramework's module.modulemap in Xcode's
shared include directory; clang finds \<dir>/\<Module>/module.modulemap.

#### Prelink each slice exporting only UniFFI symbols to avoid Rust std symbol clashes
`build-sync-xcframework.sh prelink`: A Rust static library carries its own copy of the Rust standard library, so
two of them in one app (FluidAudio's text processing is another) clash on
symbols like _rust_eh_personality. Prelink each slice into one object in
which only the UniFFI functions stay global, and check that those are
exactly the functions the header declares.

#### Rust std bitcode breaks older linkers; list machine-code symbols only
`build-sync-xcframework.sh prelink`: Rust's standard library embeds LLVM bitcode, which older Xcode linkers
keep through `ld -r` and whose tools can't parse a newer Rust's LLVM:
list the machine-code symbols only.

### `Scripts/build/build_test_dmg.sh`

#### Test DMG is unsigned, for eyeballing install layout; releases are notarized
Build a quick UNSIGNED test DMG from a local Debug build of LokalBot, to
rehearse the drag-to-Applications install flow. Release DMGs are notarized +
Sparkle-signed via CI / RELEASING.md — this one is for eyeballing layout only.
Usage: bash Scripts/build/build_test_dmg.sh [output.dmg]

#### Use throwaway venv because Homebrew Python is PEP 668 externally managed
`build_test_dmg.sh dmgbuild venv`: dmgbuild lives in an isolated venv: Homebrew Python is PEP 668-managed, so
`pip install` against it fails with "externally-managed-environment". A
throwaway venv sidesteps that and keeps the system interpreter clean.

#### Package only this build's bundle; compile failure must not fall back to stale app
`build_test_dmg.sh build`: Build the Debug app. Package only the bundle from this invocation, and let a
compile failure stop the script instead of falling through to a stale app.

#### XcodeGen needs vendor paths before the first build fetches runtimes
`build_test_dmg.sh build`: XcodeGen needs these paths before the first build fetches the runtimes.

#### Debug builds not notarized; strip quarantine and ad-hoc sign to avoid damaged warning
`build_test_dmg.sh signing`: Debug builds aren't notarized, so Gatekeeper flags a DMG-mounted copy as
"damaged". Strip quarantine + ad-hoc sign so the test DMG launches without
manual xattr surgery.

#### Eject stale LokalBot volumes; remount as LokalBot 1 blanks Finder and locks files
`build_test_dmg.sh volumes`: Eject stale LokalBot volumes first; a remount as "LokalBot 1" would leave a
blank Finder window and lock files mid-build.

### `Scripts/build/clean_local.sh`

#### Cleanup scoped to LokalBot artifacts; never touches installed apps, other DerivedData, TCC
Remove this project's local build/derived/DMG artifacts so the next build
starts from a clean slate. Scoped to LokalBot artifacts only — it
never touches installed apps, other projects' DerivedData, or TCC grants.
Usage: bash Scripts/build/clean_local.sh

#### Eject mounted volumes first so nothing holds files open during deletion
`clean_local.sh volumes`: Eject mounted LokalBot volumes first so nothing holds a file open while we
delete the images that back them.

#### DerivedData folder is \<Project>-\<hash>, so LokalBot-* glob is project-scoped
`clean_local.sh DerivedData`: Xcode DerivedData for THIS project only. The folder is named
"\<ProjectName>-\<hash>", so the LokalBot-* glob is project-scoped and safe.

### `Scripts/build/fetch-llama.sh`

#### Build llama.cpp from pinned source: upstream binaries require macOS 26, avoid native CPU flags
Builds a pinned llama.cpp server/runtime for the app's real deployment
target. Upstream release binaries currently declare macOS 26, so copying
them would make a nominally macOS 15 app fail at launch. Building from the
checksum-pinned source archive keeps the public minimum honest and avoids
host-specific CPU instructions (`GGML_NATIVE=OFF`).

#### Source archive lacks .git; pass build number so --version identifies pinned build
`fetch-llama.sh BUILD_NUMBER`: The source archive has no .git, so upstream's build-info would report build
0. Pass the number of the build tag on the same commit (b12359) explicitly so
`llama-server --version` identifies the pinned build.

#### Verify every runtime object's minimum macOS; fail closed if CMake ignores target
`fetch-llama.sh validate_runtime`: Verify every runtime object advertises the same supported minimum before it
enters the app bundle. This fails closed if a future CMake change ignores the
deployment target.

#### Public headers come from verified source archive so API and runtime cannot drift
`fetch-llama.sh headers`: Public C headers for the in-process libllama module. They come from the same
verified source archive as the binary, so API and runtime cannot drift.

#### Publish only validated builds; failure leaves prior vendor directory and marker
`fetch-llama.sh publish`: Publish only a fully validated build; a failed attempt leaves the prior
vendor directory and its marker untouched.

### `Scripts/build/fetch-sherpa.sh`

#### sherpa-onnx CLIs bundled and run as subprocesses, not linked, for SenseVoice, GigaAM, Kokoro
Fetches the pinned sherpa-onnx offline CLIs (+ onnxruntime dylibs)
into Vendor/sherpa-onnx/, which the Xcode build copies into the app bundle.
This is the ONNX-runtime path for SenseVoice (CJK) and GigaAM (Russian) —
models WhisperKit/FluidAudio don't cover well — and Kokoro TTS. Run as an
Xcode pre-build phase, mirroring fetch-llama.sh; idempotent and safe to run
manually.

Integration model (same as the bundled llama-server): we bundle the
`sherpa-onnx-offline`/`sherpa-onnx-offline-tts` binaries + dylibs, copy them
out of the bundle on first run, and invoke them as subprocesses — no C++/ONNX
linking into the Swift app, no notarization-of-linked-lib dance.

#### Bundled onnxruntime reports macOS 11.0, satisfying 15.0 target
`fetch-sherpa.sh ONNXRUNTIME_VERSION`: bundled runtime reports macOS 11.0, satisfying our 15.0 target

#### Release assets can be replaced in place; verify SHA-256, recompute when bumping version
`fetch-sherpa.sh ARCHIVE_SHA256`: SHA-256 of the release artifact — a GitHub release asset can be replaced in
place, so verify before bundling. Recompute when bumping VERSION:
  shasum -a 256 \<file>

#### ONNX Runtime license committed after 2026-11-18 404 broke clean builds
`fetch-sherpa.sh ONNXRUNTIME_LICENSE`: ONNX Runtime's MIT license, committed rather than downloaded: on 2026-11-18
github.com/microsoft/onnxruntime started answering 404, which broke every
clean build. Same bytes as its $ONNXRUNTIME_VERSION LICENSE.

#### Verify arch, deployment target and rpath so bundle cannot need a later macOS
`fetch-sherpa.sh validate`: A bundle that advertises macOS 15.0 cannot quietly include a runtime that
only loads on a later point release. Verify the architecture, deployment
target, and bundle-relative rpath for every native object before packaging.

#### Fail closed if release drops options SenseVoice, GigaAM, Kokoro depend on
`fetch-sherpa.sh validate`: Fail closed if an older compatible release ever drops an option LokalBot
depends on for SenseVoice, GigaAM, or Kokoro.

#### Bundle only offline recogniser, TTS and dylibs; app sets DYLD_LIBRARY_PATH
`fetch-sherpa.sh staging`: Only the offline file-based recogniser, offline TTS, and dylibs. Microphone,
websocket, and other tools aren't needed. Flat layout; the app spawns the
binary with DYLD_LIBRARY_PATH pointed at this directory.

### `Scripts/build/install-app.sh`

#### Install must preserve designated requirement so privacy grants stay attached
`install-app.sh`: Compatibility entry point. Installation must preserve the existing bundle's
designated requirement so macOS privacy grants stay attached to LokalBot.

### `Scripts/build/reinstall-preserve-permissions.sh`

#### Update installed bundle in place and re-sign with installed requirement to keep TCC grants
Rebuild and reinstall LokalBot without changing the permission-bearing app
identity. This intentionally updates the existing /Applications bundle in
place instead of deleting it first, so macOS TCC grants keep pointing at the
same signed app identity.

Xcode's Developer ID export writes its own form of the designated
requirement. When that text differs from the installed app's but the build
still satisfies the installed requirement, the outer bundle is re-signed with
the installed requirement so the identity TCC checks stays the same.

Usage:
  Scripts/build/reinstall-preserve-permissions.sh
  Scripts/build/reinstall-preserve-permissions.sh --no-relaunch
  CONFIGURATION=Release Scripts/build/reinstall-preserve-permissions.sh

#### Re-sign only outer bundle; nested code keeps export signatures
`resign_with_requirement`: Re-signs only the outer bundle; nested code keeps the export's signatures.

#### Match only installed copy; replays and benchmarks run others under same name
`installed_app_pids`: Only the installed copy: Release replays and benchmarks run other copies
under the same process name and must keep running.

#### XcodeGen needs vendor paths before the first build fetches runtimes
`reinstall-preserve-permissions.sh build`: XcodeGen needs these paths before the first build fetches the runtimes.

### `Scripts/build/sign-bundled-native-code.sh`

#### Keep library validation on; sign vendored dylibs with team before bundle is sealed
Hardened-runtime apps can only load bundled dylibs that are signed by the
same team, unless library validation is disabled. Keep validation on and sign
our vendored native runtimes after Copy Bundle Resources but before the app
bundle itself is sealed by Xcode.

### `Scripts/ci/build-relevance.py`

#### Empty or unreadable diff triggers a build
`relevant`: An empty or unreadable diff builds.

### `Scripts/ci/check-sync-crate-notices.py`

#### Targets must match those built by the two sync build scripts
`TARGETS`: The targets Scripts/build/build-sync-xcframework.sh and Scripts/build/build-sync-android.sh build.

### `Scripts/ci/ci-timings.py`

#### Gate job cannot depend on its own completion; check focused gate before UI prefix
`summarize`: The gate's own completion cannot be a dependency. Check the
focused gate before the general UI consumer-name prefix.

### `Scripts/ci/compiler-cache.py`

#### Cache identity pins project.yml and generator; raw PBX bytes vary by object IDs
`prepare`: project.yml is the generated project/scheme authority in both workflows.
Raw PBX bytes are unstable: XcodeGen can assign different object IDs to
equivalent copy phases. Pin the specification and generator instead.
Build scripts/workflows cover every argument; dependency pins stay exact.

#### Always build checked-out revision; cache never supplies stamps or build products
`clean_products`: Always build the checked-out revision. A cache can never supply a stamp,
xctestrun, executable, or incremental build database from another run.

#### Oversized or unusable compiler cache is optional, never fails the build
`seal`: An oversized/unusable accelerator is optional, never a build failure.

### `Scripts/ci/fetch-bun.sh`

#### Fetch checksum-pinned Bun that AgentRuntimeManifest trusts, for CI model-stub tests
Download the checksum-pinned Bun that AgentRuntimeManifest already trusts, for
CI tests that run the model stub. Prints the verified binary path last.
  Scripts/ci/fetch-bun.sh [dest-dir]
  Scripts/ci/fetch-bun.sh --print-pins

### `Scripts/ci/model-drift.py`

#### Match calls by purpose and ordinal so nth call answers same request in both runs
`compare`: The same purpose's nth call answers the same request in both runs.

### `Scripts/ci/prepare-display.swift`

#### Run only on ephemeral hosted desktop; prefer CoreGraphics modes, fall back to Anka tool
`prepareDisplay`: Run only on the ephemeral hosted desktop, before building or starting XCTest.
Prefer supported CoreGraphics modes; older Anka images need their guest tool.

#### Display mode change is session-scoped and reverts when process exits
`prepareDisplay`: App-only changes revert when this short-lived Swift process exits.

#### Anka change_res fallback follows runner-images issue 9345
`prepareDisplay`: https://github.com/actions/runner-images/issues/9345#issuecomment-1981190579

### `Scripts/ci/release-candidate.py`

#### UI Tests runs only via release-candidate dispatch bound to exact SHA; full run reports XCUITest
`GATE_EVENTS`: UI Tests no longer runs on every master push. prepare-release.sh dispatches
it for the candidate, and that run binds itself to the exact SHA it was
asked to test before any job runs. Only a full run reports `XCUITest
(macOS)`; filtered and legacy-comparison dispatches use another name.

#### Merged PR's UI run counts only if it tested this exact tree
`PULL_REQUEST_UI_JOBS`: Without an exact-commit UI run, the merged pull request's run counts when it
tested this exact tree (merged_pull_request_ui). `UI build (macOS)` runs only
when the suite does, so a draft or UI-irrelevant pass doesn't count.

#### GitHub comparison lists at most 300 files, so longer lists may be truncated
`COMPARE_FILE_LIMIT`: GitHub's comparison lists at most this many files, so a list this long may be cut short.

#### Renames count both ends; moving a file out of the app changes the app
`paths_changed_since`: A rename names both ends: moving a file out of the app changes the app.

#### Newest qualifying run on exact SHA is authoritative over older successes
`successful_gate`: The newest qualifying run on this exact SHA is authoritative. An older
successful attempt cannot hide a running or failed rerun.

#### Exact-commit UI run decides alone; otherwise merged PR run is used
`gates`: An exact-commit UI run, when there is one, decides on its own.

### `Scripts/ci/test-products.py`

#### Ignore attempt: failed-jobs-only reruns reuse earlier-attempt build products
`identity`: Not the attempt: a failed-jobs-only rerun keeps the build job that passed,
so its consumers use products from an earlier attempt of the same run,
built from the same commit, toolchain and dependency lock.

#### UI products built on release toolchain run on oldest macOS; ignore xcode and sdk
`CROSS_TOOLCHAIN_KEYS`: UI products are built with the release toolchain on macOS 26 and run on the
oldest supported macOS, whose image has an older Xcode. Everything else about
the candidate must still match; unit-test products stay on one toolchain.

### `Scripts/ci/ui-relevance.py`

#### Dependency bumps change compiled code without touching LokalBot directory
`UI_PATTERNS`: Dependency bumps change compiled code without touching LokalBot/.

### `Scripts/ci/ui-shards.py`

#### Background-work UI flows run only in their own shard
`ui-shards.py BACKGROUND`: Flows with the host's background work running (replayed trace, file audio,
model stub) run only in their own shard.

#### UI suite runs on two runners; Reduce Motion runs last, timings 2026-11-18
`ui-shards.py GROUPS`: The complete suite runs on two macOS runners after the build, about 30 and 35
minutes each (2026-11-18 timings). Every runner is another job GitHub can fail
to place when hosted macOS capacity is short, and a failed-jobs-only rerun
repeats one group, not the suite. Each phase still writes its own report, so
verify() checks it as before. Reduce Motion runs last so its preference can't
reach another phase even if restoring it fails.

#### Reject unrecognized XCTest syntax rather than omit it from inventory
`ui-shards.py inventory`: XCTest methods are parameterless Swift methods in final XCTestCase classes.
Reject new test syntax rather than silently omitting it from the inventory.

#### A failed phase does not stop the rest of its group
`ui-shards.py execute`: A failed phase doesn't stop the rest of its group.

#### Each visual size keeps its own result, log and report
`ui-shards.py execute`: Each size keeps its own result, log and report, so verify() and the
evidence look exactly as they did with one runner per size. A failed
size doesn't stop the others.

#### Test environment and accessibility prefs restored after each phase on shared runners
`ui-shards.py execute`: Phases that share a runner must not inherit each other's test environment
or accessibility preferences, so both are put back after each phase.

#### Focused runs must execute requested tests; zero-test runs fail
`ui-shards.py run_phase`: Even focused invocations must execute the requested tests. A typo must
never become a green zero-test run; focused checks remain separate from
the complete-suite gate and its 78-capture requirement.

#### Failed-jobs-only reruns keep passing reports; other runs or later attempts are stale
`ui-shards.py verify`: A failed-jobs-only rerun keeps the reports of the runner that passed in
an earlier attempt of this run. Reports from another run or commit,
or a later attempt than this one, are stale.

### `Scripts/cotyping/compare-cotyping.sh`

#### Prompts come from the shared TSV manifest, overridable by env var
`compare-cotyping.sh (prompts)`: Prompts come from the shared manifest so Cotypist and LokalBot are driven by
the exact same inputs the in-app benchmark mirrors. Tab-separated:
slug\<TAB>kind\<TAB>prompt. Override with COTYPING_COMPARE_PROMPTS.

### `Scripts/cotyping/cotyping-probe.swift`

#### screencapture uses global top-left coordinates, including negative-origin displays
`cotyping-probe.swift captureRect`: screencapture uses global top-left coordinates, including displays
whose origin is negative or above the primary display.

### `Scripts/dev/build-and-run.sh`

#### Script is the Codex local environment Run action
`build-and-run.sh (file)`: The Run action of a Codex local environment (.codex/environments/, which is
not tracked) calls this: build LokalBot Dev and start it, or attach lldb,
stream logs, or check that it launched.

#### XcodeGen needs vendor paths before first build fetches runtimes
`build-and-run.sh`: XcodeGen needs these paths before the first build fetches the runtimes.

#### Sync xcframework step builds the Rust phone/tablet sync library
`build-and-run.sh`: The phone and tablet sync library (Rust), as a local Swift package.

### `Scripts/dev/sample_meeting.py`

#### Gemini voices each turn alone without seed; style sets delivery unspoken
`sample_meeting.py speech`: Gemini voices each turn alone, with no seed; `style` sets the delivery
without being spoken.

#### Gemini returns WAV, 24 kHz mono
`sample_meeting.py speech`: WAV, 24 kHz mono

#### Retry rate limits and overload; any other HTTP error stops the build
`sample_meeting.py synthesize`: rate limits and overload pass; anything else stops the build

#### AAC-LC chosen because symphonia and AVFoundation both decode it
`sample_meeting.py build`: AAC-LC: symphonia (Linux, Windows) and AVFoundation (Mac) both decode it.

#### German check normalizes digits, compound forms and ordinal endings
`sample_meeting.py German normalization`: German: digits become words, "einhundert" and "hundert" agree, and an
ordinal's case ending ("18." / "achtzehnte" / "achtzehnten") doesn't count.

#### Serbian check reads Cyrillic as Latin, normalizes digits, dva/dve and ordinals
`sample_meeting.py Serbian normalization`: Serbian: Cyrillic output reads as Latin, digits become words, "dve" and
"dva" agree, and an ordinal's case ending doesn't count.

#### Chinese digits read as numerals; 两 counts as 二
`sample_meeting.py Chinese normalization`: Chinese: digits read as Chinese numerals, and 两 counts as 二.

#### English 'hundred and' dropped so spoken and digit forms agree
`sample_meeting.py normalize`: "a hundred and eighty" and "180" should agree

### `Scripts/media/agent-handoff-demo/edit.py`

#### Scene seconds on screen; None keeps real length
`edit.py SCENES`: Seconds on screen per scene; None keeps the scene's real length.

#### Frames use most common size, capped at MAX_WIDTH, even sides for H.264
`edit.py main`: Every frame at the size most of them have, no wider than MAX_WIDTH,
with even sides for H.264.

### `Scripts/media/agent-handoff-demo/film.sh`

#### Handoff film usage, transcription on Mac, OpenRouter model, throwaway library and key
`agent-handoff-demo/film.sh (file)`: Films the after-meeting agent handoff on a Mac with a Debug LokalBot.app:
a call ends, LokalBot transcribes and summarizes it, and each action the
person took on starts as its own Agent Mode task.

  LOKALBOT_APP=\<Debug LokalBot.app> OPENROUTER_API_KEY=\<key> \
Scripts/media/agent-handoff-demo/film.sh \<out-dir>

Transcription runs on this Mac (Parakeet); the summary and the agents use
an OpenRouter model (DEMO_MODELS, first that answers with private routing).
The library, settings suite and keychain are throwaway; the key is only
written to that keychain. The window is recorded with screencapture, so the
shell running this needs Screen Recording (hosted runners have it). Writes
the cut (agent-handoff.mp4/.gif, stills) and evidence (logs, the meeting's
notes, what the agents wrote) to \<out-dir>.

#### macOS has no timeout(1)
`film.sh run_for`: Runs "$@" for at most $1 seconds; macOS has no timeout(1).

#### User-initiated --process downloads Parakeet on cache miss
`film.sh warm-up`: A user-initiated --process downloads Parakeet when the cache missed;
the filmed call is then processed automatically, as after a recording.

#### Whole-screen capture once a minute when runner may record
`film.sh`: The whole screen once a minute, when this runner may record it.

#### Output must never carry the API key; scan and remove
`film.sh`: Nothing written here may carry the key.

### `Scripts/media/agent-handoff-demo/stage.py`

#### Priya owns the website; four follow-ups go to agents
`stage.py FOLLOW_UP`: Priya owns the website; the four things the person takes on go to agents.

#### Capture, learning and reach-out features off; transcription local, summaries via OpenRouter
`stage.py SETTINGS`: Everything that could capture, learn, or reach past the library stays off;
the meeting is transcribed on this Mac and summarized, like the agents' work,
by the OpenRouter model. Unlisted settings keep their defaults.

#### Full-access approval mode so agents run unattended
`stage.py write_settings`: Full access: no tool asks first, so the agents run unattended.
In the narrower modes each lokalbot-cli lookup waits for a click.

### `Scripts/media/assemble_gif.py`

#### Labels match landing video description; coordinates normalized to resolution
`assemble_gif.py DIRECTED_SCENES`: Labels are exact phrases already used by the landing page's video description.
Focus and cursor coordinates are normalized to keep direction stable if the
capture resolution changes while preserving the same app layout.

### `Scripts/media/autocomplete-demo/display.swift`

#### Give hosted desktop a Retina mode, else widest 1x, 1760 pt windows
`display.swift (file)`: Gives the hosted desktop a Retina (2x) mode when the runner offers one, so
the filmed text stays sharp when the cut scales it up. Lists every mode it
sees; falls back to the widest 1x mode. Either has room for the takes'
windows, which are 1760 points wide.

  swift Scripts/media/autocomplete-demo/display.swift

### `Scripts/media/autocomplete-demo/encode.py`

#### Whole-microsecond stamps avoid duration rounding drift
`encode.py main`: Whole microseconds, each from the last: rounded durations add up, and over a
long take of steady frames the video drifted seconds from its events.

#### Concat demuxer needs last file twice for its duration
`encode.py main`: The concat demuxer needs the last file twice for its duration to count.

### `Scripts/media/autocomplete-demo/film.sh`

#### Autocomplete filming in TextEdit on hosted Mac; CI only, TCC grants, plain-text documents
`autocomplete-demo/film.sh (file)`: Films LokalBot's autocomplete in TextEdit on a hosted Mac in CI, with the
default on-device model and real keystrokes.

  LOKALBOT_APP=\<Debug LokalBot.app> Scripts/media/autocomplete-demo/film.sh \<out-dir> [take...]

Takes are Scripts/media/autocomplete-demo/shots/*.json (default: all but warmup;
SHOTS names another folder, which needs its own warmup.json), filmed once
per appearance (APPEARANCES, default "light"). Each take is
typed by Scripts/media/readme-gif/rig.swift with real key events and recorded at
30 fps with ScreenCaptureKit: TextEdit's window plus LokalBot's suggestion
panel, which the Debug build shows to capture with --lokalbot-film-ghost.
The rig waits for each suggestion and accepts it word by word with Tab; a
take whose suggestion never comes, or whose typing comes out wrong, is
filmed again (ATTEMPTS, default 3).
LokalBot runs as a child of this script, so the runner is responsible for
its permissions; LAUNCH=open starts it with `open` instead.

CI only: it grants this runner's TCC permissions to LokalBot and the rig
with sudo and turns macOS inline predictions and corrections off. TextEdit
opens each document in plain text at FONT_SIZE (default 44) points: it is
sandboxed and reads its preferences from its container, so its settings go
in as launch arguments rather than through `defaults`.

Writes \<out-dir>/clips/\<appearance>-\<take>.mp4 with a .json of the take's
events, the raw takes' metadata, and the app's log.

#### Hosted images run with SIP off so TCC databases take rows directly
`film.sh grant`: Hosted images run with SIP off, so the TCC databases take rows directly.

#### Run app as child so macOS holds the runner responsible for permissions
`film.sh launch_app`: A child of this shell: macOS holds the runner responsible for its permissions.

#### Warm-up loads the model; succeeds once a suggestion shows
`film.sh warm_up`: warm_up \<appearance>: the model loads; true once a suggestion shows

### `Scripts/media/autocomplete-demo/probe.py`

#### Probabilities are the model's own pre-sampling softmax
`probe.py main`: Probabilities before sampling: the model's own softmax over its vocabulary.

### `Scripts/media/autocomplete-demo/stage.py`

#### Dictation and visible-context off: key loss and 9 s accessibility walk on hosted runners
`stage.py SETTINGS`: Dictation's shortcut tap sits in the keystroke path on the app's main
thread; on a busy hosted runner the rig's keys came out lost and out of
order. Reading the visible window walks TextEdit's accessibility tree,
which took 9 s there. Neither is part of this demo.

### `Scripts/media/capture-screenshots.sh`

#### Screenshots rendered in-process by UI test host; no TCC grant needed
`capture-screenshots.sh (file)`: Regenerate the README screenshots and GIFs from the real app UI.

Builds the UI-test host, seeds a synthetic meeting library, then lands the
host on each section via the LOKALBOT_* capture env vars (handled in the app
only under the LOKALBOT_UI_TEST_HOST build flag). The host renders its own
window to a configurable-density PNG in-process (2x by default via
LOKALBOT_CAPTURE_SCALE) and quits -- so a
running production LokalBot is never touched and no TCC grant is needed.

Produces in Assets/screenshots/:
  *.png      one still per section
plus Quick Recall and Dictation feature surfaces
  hero.gif   a tour across sections
  recap.gif  browsing meeting recaps + transcript
  search.gif searching across meetings

Requires: Xcode, a configured signing team, ffmpeg (for the GIFs).

#### Detach stdin so backgrounded GUI children do not consume it
`capture-screenshots.sh`: Detach stdin: backgrounded GUI children must not inherit (and consume) the
shell's stdin, which can otherwise garble the rest of this script.

#### GIF-only frames kept out of Assets
`capture-screenshots.sh FRAMES`: GIF-only frames (kept out of Assets/)

#### Stills published only after the full set validates
`capture-screenshots.sh STILLS`: publish only after the full set validates

#### 1400 pt frame is smallest stable width; compact list column
`capture-screenshots.sh CAPTURE_CONTENT_MAX`: Keep the master/list column compact so the inspector gets a stable, generous
share of three-column marketing captures. The 1400pt frame is the smallest
verified stable width for the current outcome workspace and keeps README text
more legible than the former 1480pt frame.

#### Captures pinned to light so dark-mode Macs match README set
`capture-screenshots.sh CAPTURE_APPEARANCE`: The committed README set is light; captures must not follow the host machine's
appearance or a dark-mode Mac exports a mismatched set. Pinned in the host via
NSApp.appearance; LOKALBOT_CAPTURE_APPEARANCE=dark exports the dark variant.

#### README meeting section shows the podcast trailer review (studio index 3)
`capture-screenshots.sh`: The README meeting section shows the podcast trailer review (studio index 3).

#### Studio list order maps indexes to meetings; must match seed
`capture-screenshots.sh`: Studio list order: 0 Holiday shoot, 1 Mac refresh, 2 Studio check-in, 3 Podcast
trailer, 4 Brand refresh sync, 5 Client call - Northwind.

#### GIF widths are 2x README display size; assemble never upscales
`capture-screenshots.sh`: Widths are 2x the README display size (880/860); assemble_gif never upscales,
so 1x captures pass through at native size.

### `Scripts/media/readme-gif/build.sh`

#### Builds README GIFs from takes; published hero is cut elsewhere
`readme-gif/build.sh (file)`: Builds the README hero GIFs from takes recorded by film.sh.

  Scripts/media/readme-gif/build.sh \<takes-dir> [out-dir]   (default out-dir: \<takes-dir>/out)

Writes lokalbot-demo-\<appearance>.gif for each of APPEARANCES (default "light dark"). Needs ffmpeg and gifsicle.
The published hero in Assets/hero is cut by Video/lokalbot-landing-demos, so this
writes there only when Assets/hero is named as the out-dir.

#### One weighted palette, ordered dithering and rectangle diffs keep unchanged pixels identical
`readme-gif/build.sh`: One palette for the whole loop, weighted toward what changes; ordered
dithering and rectangle diffs keep unchanged pixels identical between frames.

### `Scripts/media/readme-gif/build_filming_app.sh`

#### Filming copy flips panel sharingType to readOnly, built from git archive, re-signed, never shipped
`build_filming_app.sh (file)`: Builds the copy of LokalBot that films autocomplete and dictation.

  Scripts/media/readme-gif/build_filming_app.sh \<work-dir> [revision]   (default revision: v0.11.2)

The shipping autocomplete panel sets `sharingType = .none`, so screen
recording never sees a suggestion. This copy changes that one line to
`.readOnly` and is otherwise the release source. It is built from
`git archive`, so the checkout and /Applications/LokalBot.app are untouched,
then re-signed to the installed app's designated requirement so the
installed app's Accessibility and Input Monitoring grants apply to it.
Never ship or commit the result.

#### Re-sign only outer bundle; --deep would break Sparkle and lokalbot-cli
`build_filming_app.sh`: Nested code keeps the signatures the archive gave it; only the outer bundle
gets the installed app's designated requirement. --deep would re-sign
Sparkle and lokalbot-cli with the app's entitlements and break them.

### `Scripts/media/readme-gif/claude_scene.sh`

#### Agent scene uses Claude subscription login token from keychain, env only; API key refused
`claude_scene.sh (file)`: Runs inside the Terminal window filmed for the agent scene.
  claude_scene.sh \<claude-dir>   (prepared by prepare_claude.py)
Starts an interactive Claude Code session in the workspace, with only the
LokalBot MCP server, an isolated config, and a clean prompt. It signs in
with the Claude subscription login Claude Code already keeps in the login
keychain; the token is passed in the environment only, never written or
shown. (An API key cannot be used here: the API refuses interactive
Claude Code sessions on an account without prepaid credit.)

#### Standard-speed requests only, no background calls
`claude_scene.sh`: Standard-speed requests only, and no session-title or other background calls.

### `Scripts/media/readme-gif/compose.swift`

#### Takes become flat-canvas GIF frames with click rings; reads rig output layout
`compose.swift (file)`: Lays recorded takes out as GIF frames: one flat canvas in the takes' own
fill colour, a caption per shot, the take's pixels (only cropped or scaled),
and a ring where each recorded click landed. Writes numbered PNGs for ffmpeg.

  compose \<edit.json> \<light|dark> \<takes-dir> \<out-frames-dir>

Takes are read from \<takes-dir>/\<appearance>/\<take>/ as written by rig.
Build: swiftc -O -swift-version 5 compose.swift -o compose

#### from is seconds into the take
`compose.swift Shot.from`: seconds into the take

#### hold is extra seconds the frame at to stays
`compose.swift Shot.hold`: extra seconds the frame at `to` stays up

#### crop is capture points x, y, w, h
`compose.swift Shot.crop`: capture points x, y, w, h

#### radius restores corner radius in points after a crop
`compose.swift Shot.radius`: corner radius in points to restore after a crop

#### scale is canvas pixels per capture pixel
`compose.swift Edit.scale`: canvas pixels per capture pixel

#### captionTop is canvas pixels from top to first caption line
`compose.swift Edit.captionTop`: canvas pixels from the top to the caption's first line

#### stageTop is top of area where takes are centred
`compose.swift Edit.stageTop`: top of the area takes are centred in

#### start is seconds into the cut where the loop begins
`compose.swift Edit.start`: seconds into the cut where the loop begins

#### fill sampled outside the window corner
`compose.swift Take.fill`: the capture's own fill, sampled outside the window corner

#### Top-left pixel lies outside the rounded window corner
`compose.swift Take.corner`: The top-left pixel, which lies outside the window's rounded corner.

#### Frame on screen is last one delivered at or before t
`compose.swift Take.frame`: The frame on screen at time t: the last one delivered at or before it.

#### Each shot plays from..to at recorded speed then holds last frame
`compose.swift shots`: Each shot plays from..to at recorded speed, then holds its last frame.

#### CG origin is bottom-left; layout is top-left
`compose.swift placement`: CG's origin is bottom-left; the layout above is top-left.

#### Click rings expand and fade over 0.5 s
`compose.swift click rings`: Click rings: expand and fade over 0.5 s from the press.

### `Scripts/media/readme-gif/film.sh`

#### Takes use fresh library copy, own defaults suite; abort if input touched
`readme-gif/film.sh (file)`: Records the README GIF takes from the LokalBot UI Test Host.

  APP_BUNDLE=".../LokalBot UI Test Host.app" Scripts/media/readme-gif/film.sh \<takes-dir> [take...]

Takes: recall meeting ask (default: all). APPEARANCES="light dark" (default).
Each take launches the host on a fresh copy of one seeded fictional library,
with its own UserDefaults suite, places the window on the built-in Retina
display, records it with rig, and quits the host. Needs Screen Recording and
Accessibility for the terminal. A take waits until nobody has touched the
keyboard, mouse or trackpad for a few seconds, and restarts if they do.

### `Scripts/media/readme-gif/film_live.sh`

#### Quit installed app to avoid port and shortcut clash; plain-text docs; dictation needs mic and quiet room
`film_live.sh (file)`: Records the autocomplete and dictation takes with the filming copy.

  FILMING_APP=\<work>/LokalBot.app Scripts/media/readme-gif/film_live.sh \<takes-dir> [take...]

Takes: autocomplete dictation (default: both). APPEARANCES="light dark" (default).
The installed LokalBot is quit first (both copies would share model ports and
keyboard shortcuts) and reopened at the end, also on failure. The filming copy
runs on a fresh fictional library with its own settings suite; TextEdit
documents are plain text, created in a temporary folder and closed without
saving. Plain text keeps TextEdit's format bar, whose labels autocomplete
would read as context, out of the window. Documents keep TextEdit's
plain-text font; the GIF scales the window up. TextEdit's preferences are not changed.
Dictation plays its line through the speakers with a macOS voice, so the
MacBook's own microphone must be the input and the room fairly quiet.

#### Quit waits up to 20 s then kills
`film_live.sh quit_app`: quit_app \<bundle path>; waits up to 20 s

### `Scripts/media/readme-gif/prepare_filming.py`

#### Capture and reach-out off, scene features on and local
`prepare_filming.py SETTINGS`: Everything that could capture, learn from, or reach past this library is off;
what the scenes need is on and local. Unlisted settings keep their defaults.

### `Scripts/media/readme-gif/rig.swift`

#### Rig commands, input-touch abort, pointer track, RIG_ env vars, exit codes 3/5/6
`rig.swift (file)`: Films one LokalBot UI Test Host window for the README GIF.

The window is captured with ScreenCaptureKit on its own, over a flat fill,
including the real pointer. It is driven with real HID input events (pointer
moves, clicks, keystrokes), so what the GIF shows is the app responding to
input. A take aborts if the keyboard, mouse or trackpad is touched, so a
person working on the Mac is never fought over the pointer.

  rig take  \<shot.json> \<out-dir>   record frames + take.json into out-dir
  rig still \<shot.json> \<out.png>   place the window and save one frame
  rig ax    \<shot.json>             place the window and print its accessibility tree
  rig probe \<shot.json> \<out-prefix> place the window, run the setup, save \<prefix>.txt
(the accessibility tree) and \<prefix>.png (one frame)
  rig idle  \<seconds>               wait until nobody has touched an input device that long
  rig key   \<name> [mod...]         press one key, e.g. a system-wide shortcut: rig key space control shift
  rig windows list|kill             other apps' windows on the filming display; kill ends their owners
  rig appearance light|dark         set the system appearance, which the apps launched next read

take.json also tracks the pointer at 60 Hz (`pointer`: [t, x, y] in capture
seconds and window-relative points), so an edit can draw or follow it when
the shot leaves it out of the recording (`"cursor": false`). RIG_DISPLAY
names the display to film on by its CGDirectDisplayID. RIG_TREE_DIR saves the
window's accessibility tree at each `mark`, as \<dir>/\<mark>.txt.

Exit codes: 3 a person touched the Mac during the take, 5 a `ghost` wait
timed out, 6 the focused field does not end with an `expect` text (keys
were lost on the way) or holds a `reject` text. Film the take again for any
of them.

Build: swiftc -O -swift-version 5 rig.swift -o rig

#### at is window-relative points
`rig.swift Target.at`: window-relative points

#### label matches exact AXDescription or AXTitle
`rig.swift Target.label`: exact AXDescription or AXTitle

#### contains matches substring of AXTitle, AXDescription or AXValue
`rig.swift Target.contains`: substring of AXTitle, AXDescription or AXValue

#### index is nth match, default 0
`rig.swift Target.index`: nth match, default 0

#### offset is points added to resolved position
`rig.swift Target.offset`: points added to the resolved position

#### anchor is fraction of element frame, default centre
`rig.swift Target.anchor`: fraction of the element frame, default centre [0.5, 0.5]

#### park warps pointer without motion, window-relative
`rig.swift Action.park`: window-relative; warps the pointer without motion

#### press does AXPress without moving the pointer
`rig.swift Action.press`: AXPress without moving the pointer

#### focus gives keyboard focus without moving the pointer
`rig.swift Action.focus`: give an element keyboard focus without moving the pointer

#### hold keeps modifier keys down while during runs
`rig.swift Action.hold`: modifier keys held down while `during` runs, e.g. ["control", "option"]

#### run starts a background command and is not waited for
`rig.swift Action.run`: a command started in the background, e.g. a voice line; not waited for

#### ghost waits at most this long for an also-app floating window
`rig.swift Action.ghost`: wait this long at most for an `also` app's floating window, e.g. a suggestion

#### accept presses key (default tab) up to N times while window shows
`rig.swift Action.accept`: press `key` (default tab) up to this many times while that window shows

#### expect: focused field must end with text else exit 6
`rig.swift Action.expect`: the focused field's text must end with this, else exit 6

#### reject: focused field must not contain text else exit 6
`rig.swift Action.reject`: the focused field's text must not contain this, else exit 6

#### optional skips action with a note when element missing
`rig.swift Action.optional`: skip this action, with a note, when its element is not found

#### until waits for element up to timeout seconds, default 60
`rig.swift Action.until`: wait for this element to appear, up to `timeout` seconds (default 60)

#### gone with until waits for element to disappear
`rig.swift Action.gone`: with `until`: wait for it to go away instead

#### size is outer window size in points
`rig.swift Shot.size`: outer window size, points

#### background is #RRGGBB fill; RIG_BACKGROUND overrides
`rig.swift Shot.background`: \#RRGGBB fill behind the window; RIG_BACKGROUND overrides

#### margin is points captured around the window
`rig.swift Shot.margin`: points captured around the window

#### bottom is window distance above visible screen bottom; default centred
`rig.swift Shot.bottom`: window bottom this far above the visible screen bottom; default centred

#### below is points captured below the window, e.g. dictation overlay
`rig.swift Shot.below`: points captured below the window, e.g. LokalBot's dictation overlay

#### settle is seconds between placing and recording
`rig.swift Shot.settle`: seconds between placing and recording

#### pre is seconds recorded before first action
`rig.swift Shot.pre`: seconds recorded before the first action

#### post is seconds recorded after last action
`rig.swift Shot.post`: seconds recorded after the last action

#### idle is seconds of no human input required to start
`rig.swift Shot.idle`: seconds of no human input required to start

#### park is window-relative pointer position when recording starts
`rig.swift Shot.park`: window-relative pointer position while recording starts

#### also lists bundle ids whose windows are captured too
`rig.swift Shot.also`: bundle ids whose windows are captured too, e.g. an overlay

#### title picks window by substring; default the widest
`rig.swift Shot.title`: capture the window whose title contains this; default: the widest

#### cursor false leaves pointer out of recording; default true
`rig.swift Shot.cursor`: false leaves the pointer out of the recording; default true

#### ownInput: app posts its own input, not read as a person's
`rig.swift Shot.ownInput`: the app posts input itself, such as a paste; don't read it as a person's

#### Prefer built-in Retina panel (2x), else main display
`rig.swift Display.filming`: The built-in Retina panel when present (2x pixels), else the main display.

#### bounds are global coordinates with top-left origin
`rig.swift Display.bounds`: global, top-left origin

#### visible is global top-left, minus menu bar and Dock
`rig.swift Display.visible`: global, top-left origin, minus menu bar and Dock

#### Posted keys and clicks reset HID idle; pointer warps do not
`rig.swift hidIdle`: Seconds since the HID system last saw input. Keystrokes and clicks this
tool posts reset it too; pointer moves are warps and do not.

#### Input guard is off when filmed app posts input itself
`rig.swift guardsInput`: False while filming an app that posts input itself.

#### True only for input this tool did not post
`rig.swift touchedSince`: True when input arrived after `start` that this tool did not post.

#### Warp the visible pointer and also post a move to the app
`rig.swift pointTo`: Moves the visible pointer and tells the app under it.

#### Push-to-talk shortcuts need keys held, not tapped
`rig.swift holdDown`: Presses and holds keys in order, e.g. ["option", "space"], and returns the
release. Push-to-talk shortcuts need the key held, not tapped.

#### Deterministic jitter so retakes type with same rhythm
`rig.swift jitter`: Deterministic jitter so retakes type with the same rhythm.

#### Floating windows of the shot's also apps are overlays
`rig.swift overlayBundles`: Bundle ids of the shot's `also` apps; their floating windows are overlays.

#### Window list times suggestion even when capture hides its pixels
`rig.swift waitForOverlay`: Waits up to `seconds` for an overlay app to put a window above the menu
bar's level on screen, such as LokalBot's autocomplete suggestion panel.
The window list names windows that capture cannot see, so this times the
suggestion even when its pixels are hidden from recording.

#### Copy pooled IOSurface so stream can reuse it immediately
`rig.swift Capture.copyImage`: Copies the pooled IOSurface so the stream can reuse it immediately.

#### Pointer sampled at 60 Hz because capture frames only on change
`rig.swift PointerTrack`: The pointer's position through a take, sampled at 60 Hz on the capture's
clock, relative to the captured rect. Capture delivers a frame only when
the picture changes, so frames alone cannot place a hidden pointer.

#### Exclude other windows; naming subject app shows purple sharing capsule
`rig.swift filter`: The display with every window left out except the subject's and those of
the `also` apps. Windows are listed when capture starts, so an overlay app
must already be running then; panels it opens later belong to no excluded
window and are captured. Naming the subject's app as the shared content
instead makes macOS badge its windows with the purple "window is being
shared" capsule in place of the window controls.

#### SCStreamConfiguration does not retain backgroundColor; keep it alive
`rig.swift configuration`: SCStreamConfiguration holds backgroundColor without retaining it.

#### Place window again after setup because minimum size can change
`rig.swift prepare`: Places the window, runs the shot's setup, places it again (setup can change
its minimum size), and leaves it frontmost and settled.

#### Capture omits other apps' windows but dialogs still catch clicks
`rig.swift strayWindows`: A take's capture leaves other apps' windows out, so a dialog never shows in
the footage but still catches the rig's clicks. Lists what is on the filming
display; with `kill`, ends the owners of windows that aren't part of a take
or of the desktop.

#### Apps read WindowServer theme that AppleInterfaceStyle may not reach
`rig.swift setSystemAppearance`: Apps read the WindowServer's theme, which the `AppleInterfaceStyle` default
doesn't always reach by itself.

### `Scripts/media/render-hero-video-short.sh`

#### Promote canonical 30 s promo only after Studio preview review
`render-hero-video-short.sh (file)`: Render and atomically promote the canonical 16:9, 30-second product promo.
Run only after the HyperFrames Studio preview has been reviewed.

#### Two-pass linear loudnorm since single pass misses targets
`render-hero-video-short.sh loudnorm`: Measure first, then apply a linear second pass. A single loudnorm pass can
miss both integrated loudness and true-peak targets on a short, dynamic mix.

#### Poster frame at 10.8 s shows complete cited answer
`render-hero-video-short.sh poster`: The complete cited-answer frame reads clearly before playback and at social-card size.

#### Previous public aliases kept aligned with canonical website cut
`render-hero-video-short.sh aliases`: Keep the previous public aliases aligned with the canonical website cut.

### `Scripts/media/render_readme_hero.py`

#### Positions in CSS px on 1600x900; Quick Recall crop and bracket alignment
`render_readme_hero.py PAGE`: Positions are in CSS px on a 1600x900 page. Quick Recall's 4x capture is
cropped 104 px at the top (24.4 CSS px), and the brackets follow its two
result groups when each holds two rows.

#### Headless Chrome keeps running after writing the screenshot
`render_readme_hero.py main`: Headless Chrome keeps running after it writes the screenshot.

### `Scripts/release/build-mcpb.sh`

#### MCPB bundle holds no binary; shim execs installed signed helper
`build-mcpb.sh (file)`: Build dist/LokalBot.mcpb — a one-click MCP bundle for GUI clients.
The bundle contains no binary: its shim execs the signed helper installed
inside LokalBot.app, avoiding a second copy that can drift or need signing.

#### Manifest spec 0.3; ${__dirname} must stay literal
`build-mcpb.sh manifest`: The current official MCPB manifest specification is 0.3. ${__dirname} is
substituted by the host at runtime and must remain literal in the JSON.

#### mcpb 2.1.2 pinned, older than seven days when added
`build-mcpb.sh MCPB_PACKAGE`: 2.1.2 was published more than seven days before this script was added.

### `Scripts/release/build-openai-plugin.sh`

#### OpenAI plugin ZIP layout and upload location
`build-openai-plugin.sh (file)`: Builds the ZIP for the OpenAI plugin directory (ChatGPT and Codex) from
Distribution/openai-plugin: plugin.json, skills/ and assets/ at the ZIP root.
Upload it at https://platform.openai.com/plugins. See
Distribution/openai-plugin/README.md.

### `Scripts/release/build_release_dmg.py`

#### Compact DMG geometry opens without scrollbars on laptop display
`build_release_dmg.py constants`: Product constants. LokalBot ships as a single window; keep the geometry
compact so the mounted volume opens without scrollbars on a laptop display.

### `Scripts/release/generate_appcast.py`

#### OWNER/REPO placeholder refused; pass --repo; canonical slug
`generate_appcast.py DEFAULT_REPO`: OWNER/REPO is a placeholder, refused in main(): pass --repo (CI passes
--repo "$GITHUB_REPOSITORY"; the canonical slug is stevyhacker/lokalbot).

#### Pattern matches sign_update stdout for non-feed archives
`generate_appcast.py SIGNATURE_PATTERN`: Matches sign_update's stdout when signing a non-feed archive:
  sparkle:edSignature="\<base64>" length="\<bytes>"

#### Deployment target floor; Sparkle will not offer update below it
`generate_appcast.py DEFAULT_MINIMUM_SYSTEM_VERSION`: Deployment target floor; Sparkle refuses to offer the update below this.

#### SwiftPM puts Sparkle artifacts in DerivedData or local .build
`generate_appcast.py candidate_sign_update_paths`: SwiftPM resolves Sparkle's binary artifacts into DerivedData (xcodebuild)
or the local .build tree (swift build).

#### Unfilled token would ship in the feed every install reads
`generate_appcast.py render_appcast`: A token nobody filled would ship in the feed every installed copy reads.

#### Placeholder repo feed would stop updates for everyone
`generate_appcast.py main`: Its enclosure and release URLs would point at github.com/OWNER/REPO,
and a feed like that stops updates for everyone who reads it.

#### Enclosure points at version-specific asset, not /latest/
`generate_appcast.py main`: Enclosure points at the version-specific asset (not /latest/) so Sparkle
downloads exactly the build it advertised.

### `Scripts/release/prepare-release.sh`

#### Overlap trusted master archive preparation with push CI gates; no tag or release
`prepare-release.sh (file)`: Explicitly overlap trusted master archive preparation with its push CI gates.
This dispatch creates no tag and publishes no release.

#### Candidate is master tip or behind by website and docs commits only
`prepare-release.sh`: The candidate is the master tip, or behind it by website and docs commits only.

#### Dispatch runs on master tip so cannot prepare older commit
`prepare-release.sh`: A dispatch always runs on master's tip, so it can't prepare or test this older commit.

#### UI Tests no longer on every master push; PR run covers exact tree
`prepare-release.sh`: UI Tests no longer runs on every master push. The merged pull request's full
run covers a candidate with its exact tree; otherwise validate this commit.

### `Scripts/release/release-preflight.py`

#### Releases after 0.11.5 link an explainer per major feature
`release-preflight.py EXPLAINERS_AFTER`: Releases after this one link an explainer for their major features
(RELEASING.md, "Explainers for major features").

#### Website deploys from master so explainer must be committed before tag
`release-preflight.py validate_explainers`: The website deploys Website/public/ from master, so an explainer must be committed before the tag.

#### Workspace members are lockfile packages without registry or git source
`release-preflight.py validate_port_version`: Workspace members are the lockfile packages without a registry or git source.

#### Network or auth failures on tag lookup fail closed
`release-preflight.py validate`: Network/auth failures also fail closed; they are not tag absence.

### `Scripts/release/sign-android-bundle.sh`

#### AAB signing script shared by release and CI; kept out of Gradle; certificate pin
`sign-android-bundle.sh (file)`: Signs an Android App Bundle (.aab) with jarsigner and verifies the signer's
certificate. Release runs sign with the Play upload key (google-play.yml) and
CI signs with a throwaway key (companion-android.yml, google-play.yml PR check)
through this same script.

Signing stays out of the Gradle build, so no build script runs beside the key.

  PLAY_UPLOAD_KEYSTORE_PASSWORD=... Scripts/release/sign-android-bundle.sh \
UNSIGNED.aab OUT.aab KEYSTORE [CERTIFICATE_SHA256]

Optional environment variables:
  PLAY_UPLOAD_KEY_ALIAS     key alias inside the keystore (auto-detected when
the keystore holds exactly one PrivateKeyEntry)
  PLAY_UPLOAD_KEY_PASSWORD  key password if distinct from the store password

With CERTIFICATE_SHA256 it refuses a keystore whose certificate has another
digest and leaves no OUT.aab.

### `Scripts/release/sign-android-release.sh`

#### Wrong signing key would strand installs; certificate digest pinned; signing outside Gradle
`sign-android-release.sh (file)`: Signs the Android release APK: aligns it, signs it with apksigner and checks
the result. The release signs with the real key (release.yml, android-publish)
and CI signs with a throwaway one (companion-android.yml), through this script.

Signing stays out of the Gradle build, so no build script runs beside the key.

  ANDROID_KEYSTORE_PASSWORD=... Scripts/release/sign-android-release.sh \
UNSIGNED.apk OUT.apk KEYSTORE.p12 [CERTIFICATE_SHA256]

With CERTIFICATE_SHA256 it refuses a key whose certificate has another digest
and leaves no OUT.apk: Android installs an update only from the key that signed
the installed copy, so a wrong key would strand everyone on the older version.

#### zipalign -P 16 keeps native libraries on 16 KB pages
`sign-android-release.sh`: -P 16 keeps native libraries on 16 KB pages, which newer devices need.

#### apksigner output format differs between build-tools 36 and 37
`sign-android-release.sh`: Build-tools 36 prints "Signer #1 certificate ..." and 37 "V3.0 Signer: certificate ...".

### `Scripts/test/day-in-the-life.sh`

#### Day run uses real headless pipelines, stubbed models, hermetic library
`day-in-the-life.sh (file)`: One synthetic workday through the REAL headless pipelines: transcription
(golden transcripts, or real Parakeet with --real-asr), notes, digest,
search, boundary review, and the health evaluator. Models are the scenario
stub replaying committed GLM 5.3 Flash answers. Hermetic library and
defaults suite; never touches the user's data.

#### Allowed Parakeet WER 0.10; measured 1 edit in 70 words
`day-in-the-life.sh MAX_WER`: Real Parakeet word error rate allowed across the day's meetings against the
golden transcripts, ignoring case, punctuation, hyphens, and split or joined
compounds. 2026-10-01 measured 1 edit in 70 words ("pare" for "pair").

#### CI uploads LOKALBOT_DAY_ROOT folder on failure
`day-in-the-life.sh LIB`: CI points LOKALBOT_DAY_ROOT at a folder it uploads when the run fails.

#### bash 3.2: read stub port from file, not process substitution
`day-in-the-life.sh`: macOS ships bash 3.2: start the stub in the background and read its port
(first stdout line) from a file rather than via process substitution.

#### Semantic search and diarization off to avoid model downloads
`day-in-the-life.sh SETTINGS`: Semantic search and multi-speaker diarization would start or download local
models; the run exercises keyword search and per-track transcripts instead.

#### Only design review has recorded notes answers; sprint tests two-source transcription
`day-in-the-life.sh`: Only the design review has recorded notes answers; the merged sprint
planning exercises transcription of a two-source meeting.

#### Notes ownership asserted only on golden runs; real ASR uses WER
`day-in-the-life.sh`: The recorded notes answer quotes the golden wording, so ownership is only
asserted on golden runs. Here the drift signal is the word error rate.

#### Boundary 0-36 s keeps all cited lines; trimming invalidates evidence IDs
`day-in-the-life.sh`: 0–36 s keeps every line the recorded notes answer cites (the last ends at
35 s); trimming one makes that answer's evidence IDs invalid, which the app
rightly rejects. The review still rewrites the transcript and reindexes.

#### Capture output first so grep -q SIGPIPE cannot fail check
`day-in-the-life.sh`: Output is captured first: with pipefail, grep -q exiting early could
SIGPIPE the app and fail a check that matched.

#### Boundary review revokes digest, so digest written after it
`day-in-the-life.sh`: A boundary review revokes the day's derived evidence (its digest), so the
digest is written after it, as the last derived artifact of the day.

### `Scripts/test/day-in-the-life/assertions.py`

#### Hyphens, punctuation and case are not recognition errors
`assertions.py words`: Hyphens, punctuation, and case are not recognition errors.

#### Synthetic meetings only: print words to read drift from log
`assertions.py day_word_error_rate`: Synthetic meetings only: show the words so drift can be read
from the log without the artifact.

### `Scripts/test/e2e.sh`

#### E2E drives real app headlessly; hermetic temp root; TCC flows skip
`e2e.sh (file)`: LokalBot end-to-end test suite. Drives the REAL app binary headlessly:
real audio (synthesized with `say`), real CoreML transcription, the real
bundled llama.cpp server, real SQLite. Run on a Mac with the app built:
  Scripts/build/install-app.sh && Scripts/test/e2e.sh
Flows needing TCC permissions (screenshots) SKIP instead of failing when
the permission is missing, so the suite is useful pre- and post-grant.

Hermetic: the whole suite runs against a throwaway library under a temp
LOKALBOT_STORAGE_ROOT, so it never touches the user's real meetings,
indexes, or journal. The real install's models/ directory is symlinked
into the temp root so multi-GB GGUFs are shared, not re-downloaded.

#### Share real install's model downloads via symlink; rm -rf is safe
`e2e.sh models symlink`: Catalog GGUFs download under \<storage root>/models (ModelCatalog.localURL),
so a bare hermetic root would re-fetch them from scratch. Share the real
install's downloads instead. Cleanup stays safe: `rm -rf` deletes the
symlink itself, never the target directory's contents.

#### Seed OCR proper noun absent from titles to prove OCR path in digest
`e2e.sh T8`: Seed today's OCR with a proper noun that appears in NO window title or
meeting, so if it lands in the digest it can only have come from the
screenshot -> OCR path wired into generateDayDigest. A generic activity
block gives the day material; its title carries no token.

#### Fixture day dream is a substantive brief, never empty stub
`e2e.sh T8b`: The T2 fixture day has a real meeting → a substantive brief (model-written,
or the evidence-only fallback if no model is reachable — never an empty stub).

#### Empty yesterday skips model and writes empty-day stub so catch-up advances
`e2e.sh T8b`: Yesterday is empty in this hermetic library → the model must be skipped and
a durable empty-day stub written so catch-up moves past the day.

#### Chat test reuses T2 Redis fixture; agent must ground answer in meeting
`e2e.sh T9`: Reuses the T2 fixture (Redis / eviction policy) in the test library.
The agent must search/read the meeting and ground its answer in it.

### `Scripts/test/record-capture/run.sh`

#### Records scripted capture; needs Debug app and permissions; launches browser, ask first
`record-capture/run.sh (file)`: Record a scripted capture session on this Mac and add its scrubbed trace to
the test fixtures. Needs the installed Debug LokalBot with Accessibility and
Screen Recording granted. Launches a browser (GUI) — ask before running.
  Scripts/test/record-capture/run.sh chrome 60

#### --record-capture exists only in Debug builds; Release would open normally
`record-capture/run.sh`: --record-capture exists only in Debug builds. A Release app would ignore it
and open normally, so refuse any binary that lacks the flag.

### `Scripts/test/scale/digest-while-writing.sh`

#### 0.9.1 regression: activity written during digest must not fail it
`digest-while-writing.sh (file)`: 0.9.1 regression: new activity written while a digest generates must not
fail the digest. Runs --digest while another process inserts activity.

### `Scripts/test/scale/two-instances.sh`

#### \#115 regression: second copy exits instead of writing; nightly CI only
`two-instances.sh (file)`: \#115 regression: a second copy on the same library exits instead of
writing to it. Launches the app normally (GUI) — nightly CI only.

#### bash 3.2 does not stop set -e on false [[ ]]; use [ ]
`two-instances.sh`: A plain `[ ]`: macOS's own bash (3.2) does not stop a `set -e` script on a false `[[ ]]`.

### `Scripts/test/seed_demo_library.py`

#### Stable ids let chat citations and capture scripts reference meetings
`seed_demo_library.py meeting ids`: Stable ids so chat citations and capture scripts can reference meetings.

#### Studio featured meetings have playable audio; used by website and README
`seed_demo_library.py STUDIO_SHOOT`: The studio profile's featured meetings, the ones with playable audio: the
holiday shoot (website and README hero) and the podcast trailer review
(README meeting section).

#### Block tuples are app, title, start minute, end minute on seeded day
`seed_demo_library.py FULL_DAY_BLOCKS`: (app, title, start minute, end minute) on the seeded day

#### Lines mirror standupTranscript; start times match golden transcripts
`seed_demo_library.py DESIGN_REVIEW_LINES`: (start seconds, speaker, text). The lines are SyntheticModelPrompts'
standupTranscript() lines; the start times match the golden transcripts in
LokalBotTests/Fixtures/day-in-the-life/golden-transcripts.

#### Sprint planning merges two 2-minute sources, one line each
`seed_demo_library.py SPRINT_LINES`: Sprint planning merges two 2-minute sources; one line falls in each.

#### Meeting times are local wall-clock like activity blocks
`seed_demo_library.py seed_full_day`: Local wall-clock time, like the activity blocks.

#### Today's blocks sit minutes before now so captures never show the future
`seed_demo_library.py seed_studio_activity`: Today's blocks and moments are minutes before now, so a capture never
shows the future and the screen moments line up with today's meetings.

#### Yesterday's screen moments avoid podcast call so no on-screen section
`seed_demo_library.py seed_studio_activity`: (app, window title, time, screen text, thumbnail, accent, bookmark note).
Yesterday's demo presentation moments stay outside the podcast call, so
its meeting window has no "On Screen During the Meeting" section.

#### Named speaker suppresses 'speaker needs a name' prompt in summaries
`seed_demo_library.py seed_studio`: A named speaker keeps the "speaker needs a name" prompt out of the
featured meetings' summaries.

### `Scripts/test/ui-tests.sh`

#### UI tests remote by default; foreground needs TCC grants; host skips side effects
`ui-tests.sh (file)`: LokalBot UI test runner: remote by default, foreground only by opt-in.

Drives the dedicated LokalBot UI Test Host via XCUITest against a
synthetic meetings library — no microphone/screen-recording permissions,
no real audio, no network. The host is compiled with LOKALBOT_UI_TEST=1
and skips every side-effectful subsystem (Core Audio polling,
accessibility-trusted detector, Sparkle, screenshots).

Local XCUITest sends real mouse and keyboard events. It therefore owns the
foreground while it runs; it cannot be made invisible in the same login
session without weakening these into non-UI tests. Prefer --remote, which
dispatches the existing GitHub Actions job and returns immediately.

Prereq for explicit --foreground runs (macOS TCC): the controlling terminal
and generated test runner MUST hold:
  • Privacy & Security → Automation → Xcode  (allowed)
  • Privacy & Security → Accessibility       (allowed)
without these, the XCUITest runner fails with
"Timed out while enabling automation mode." — that error is the missing
TCC grant, NOT a bug in the suite. The UI-test target is development-signed
with a stable bundle identity so the grant survives ordinary rebuilds.

Usage:
  Scripts/test/ui-tests.sh                # dispatch all tests without stealing focus
  Scripts/test/ui-tests.sh --remote       # explicit form of the default above
  Scripts/test/ui-tests.sh --remote MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
  Scripts/test/ui-tests.sh --build-only   # compile without launching the app
  Scripts/test/ui-tests.sh --test-only --only MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
\# hosted CI: reuse this job's build
  Scripts/test/ui-tests.sh --foreground --skip RedesignUITests/testWorkspaceVisualMatrix
  Scripts/test/ui-tests.sh --foreground   # run all tests in this login session
  Scripts/test/ui-tests.sh --foreground MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks

#### Reuse mode must never take control of a developer's desktop
`ui-tests.sh`: A reuse request must never implicitly take control of a developer's desktop.

#### Developer runs remote by default; CI runs on hosted session
`ui-tests.sh`: A developer invocation is remote by default. CI keeps running the suite on
its hosted macOS session, where foreground ownership cannot disturb anyone.

#### Remote runner cannot see working tree; refuse stale green result
`ui-tests.sh`: A remote runner cannot see working-tree changes. Refuse to report a green
result for stale UI code while still allowing unrelated local work.

#### Fetch upstream before compare; candidate_sha guards later advance
`ui-tests.sh`: Refresh the actual remote ref before comparing it. If the branch advances
again between this fetch and dispatch, candidate_sha makes the hosted job
fail rather than reporting another commit as validation for this checkout.

#### CI runners have no signing cert; CODE_SIGNING_ALLOWED opt-out
`ui-tests.sh`: CI runners hold no signing certificate; let workflows opt out of signing
(CODE_SIGNING_ALLOWED=NO Scripts/test/ui-tests.sh) without changing local runs.

#### Failed build must invalidate previous build's reuse stamp
`ui-tests.sh`: A failed build must invalidate the preceding build's reuse stamp.

#### Run xctestrun directly so downstream runners need no project or packages
`ui-tests.sh`: Consume the portable run configuration directly; downstream runners need no
generated project, native vendor build or Swift package resolution.

### `Scripts/test/unit-tests.sh`

#### Unit runner does not take foreground; stable command enables narrow approval
`unit-tests.sh (file)`: LokalBot unit-test runner. Unlike XCUITest, this does not synthesize input or
take control of the foreground app. Keeping the invocation behind one stable
project-local command also lets automation grant a narrow reusable approval.

Usage:
  Scripts/test/unit-tests.sh
  Scripts/test/unit-tests.sh AppSettingsTests
  Scripts/test/unit-tests.sh AppSettingsTests/testExplicitDiarizationChoicesSurviveReloadWithoutReenablingDiarization
  Scripts/test/unit-tests.sh --derived-data-path   # where the build products go

#### Build outside checkout: test host in Documents triggers access prompt
`unit-tests.sh DERIVED`: Build outside the checkout, one folder per checkout. A test host inside
~/Documents makes macOS ask for access to Documents after every build.

#### Skipped tests are named; non-opted-in skips fail as in CI
`unit-tests.sh`: A skipped test reports nothing, so name every skip and fail on one that is
not a listed opt-in test (Scripts/ci/unit-skips.json), as hosted CI does.

### `Scripts/test/upgrade-fixtures/add.sh`

#### Fixture built by release run, kept 90 days; only master or tag runs count
`upgrade-fixtures/add.sh (file)`: Add a published release's upgrade fixture to LokalBotTests/Fixtures/upgrade.
The release run builds it once the DMG is published and keeps it for 90
days; a dispatched Upgrade fixtures run on master works too:
  gh workflow run upgrade-fixtures.yml --ref master -f versions=VERSION
Only runs of master or the release's own tag in this repository count.

#### Older fixtures predate generate.sh WAL folding
`upgrade-fixtures/add.sh`: Fixtures built before generate.sh folded the write-ahead log.

### `Scripts/test/upgrade-fixtures/generate.sh`

#### Fixture built on clean hosted Mac with release's seed and build; CI only
`upgrade-fixtures/generate.sh (file)`: Build one upgrade fixture on a CLEAN hosted Mac: seed with that release's
own seed script, write its settings, open the library with that release's
signed build (headless), and export library + defaults + test key.
Writes the real me.dotenv.LokalBot defaults domain and Keychain items, so
it refuses to run outside CI.

#### Use release's own seed script; pre-reorg tags kept it elsewhere
`upgrade-fixtures/generate.sh`: The seed script as that release shipped it. Releases tagged before the November
2026 reorganization kept it at Scripts/seed_demo_library.py.

#### Seal plaintext personal model with chat key like a real library
`upgrade-fixtures/generate.sh`: Releases with Personal Context seed it as plaintext; a real library holds it
sealed with the chat key, so seal it with the fixture's key.

#### Releases before 0.11.2 only have LokalBot.dmg
`upgrade-fixtures/generate.sh`: Releases before 0.11.2 only have LokalBot.dmg; later ones add the version.

#### Fold WAL into database so fixture commits as is
`upgrade-fixtures/generate.sh`: Fold the write-ahead log into the database so the fixture commits as is.

### `Scripts/test/upgrade-fixtures/seal.swift`

#### Seal mirrors PersonalModelStore AES-GCM format for fixtures
`seal.swift (file)`: Seals a file with AES-GCM under a hex key, the way PersonalModelStore
writes memory/personal-model.json.enc, so upgrade fixtures carry the
encrypted form a real library has.
Usage: swift seal.swift \<key-hex> \<input> \<output>

### `Scripts/test/upgrade-fixtures/settings.py`

#### Remote automation approval existed only in 0.9.0 and 0.9.1
`upgrade-fixtures/settings.py profile`: Only 0.9.0 and 0.9.1 had a separate approval for scheduled remote runs;
0.9.2 removed it (#113).

### `Scripts/tests/AudioRecoveryCrashProbe.swift`

#### Synthetic kill probe never opens capture devices or library
`AudioRecoveryCrashProbe`: Synthetic process-kill probe; never opens capture devices or the library.

#### Keep unclosed writers alive until parent SIGKILL
`AudioRecoveryCrashProbe`: Retain unclosed writers until the parent sends SIGKILL.

### `Scripts/tests/audio-recovery-crash.sh`

#### bash 3.2 does not stop set -e on false [[ ]]; use [ ]
`audio-recovery-crash.sh`: A plain `[ ]`: macOS's own bash (3.2) does not stop a `set -e` script on a false `[[ ]]`.

### `Scripts/tests/compare-cotyping-safety.sh`

#### Use plain [ ] or grep; bash 3.2 ignores false [[ ]] under set -e
`compare-cotyping-safety.sh`: Every check below is a plain `[ ]` or `grep`: macOS's own bash (3.2) does not
stop a `set -e` script when a bare `[[ ]]` is false.

#### Every operation must carry created document id; no front-window fallback
`compare-cotyping-safety.sh`: Drive one mocked prompt through the success path. Every capture/read/accept/
close operation must carry the document id returned by the creation call;
the script must never fall back to the largest or generic front window.

### `Scripts/tests/pi-runtime.test.ts`

#### Run against checksum-pinned frozen-lockfile runtime
`pi-runtime.test.ts (file)`: Run against a checksum-pinned, frozen-lockfile runtime:
LOKALBOT_PINNED_RUNTIME_ROOT=/path/to/runtime bash Scripts/tests/run-pi-runtime-tests.sh

#### Hook returning undefined lets Pi execute; blocking result must be returned
`pi-runtime.test.ts withExtensionFixture`: Exercise the actual extension hook without a model, library, or tool runner.
Returning undefined is what allows Pi to execute, so a blocking result must
be returned even if the fake UI would approve every request.

#### cwd is session folder pi resolves tool paths against
`pi-runtime.test.ts call cwd`: `cwd` is the session folder pi resolves tool paths against (ctx.cwd).

#### Bash tool spawns commands with copy of process.env; token must not leak
`pi-runtime.test.ts`: pi's bash tool spawns each command with a copy of process.env.

#### pi re-evaluates the extension for a new session
`pi-runtime.test.ts`: pi evaluates the extension again for a new session.

#### pi rewrites paths before opening; boundary check must match as typed gap
`pi-runtime.test.ts`: pi's file tools rewrite a requested path before opening it (pi 1.5.2
utils/paths.js and core/tools/path-utils.js). Checked as typed, each of
these named a missing file inside the workspace and ran without asking.

#### Path pi cannot resolve is never a workspace name
`pi-runtime.test.ts`: A path pi cannot resolve is never treated as a workspace name.

#### pi retries missing names with narrow no-break space, NFD, curly apostrophes
`pi-runtime.test.ts`: pi retries a missing name with a narrow no-break space before AM/PM,
in NFD, and with curly apostrophes.

#### pi resolves against ctx.cwd; resumed session keeps saved folder
`pi-runtime.test.ts`: pi resolves against ctx.cwd: a resumed session keeps the folder it was saved with.

#### On case-sensitive volumes pi cannot open the variant either
`pi-runtime.test.ts`: On a case-sensitive volume pi cannot open the variant either.

#### Mirrors OpenAI Responses event stream order
`pi-runtime.test.ts responsesStream`: A Responses event stream as OpenAI sends it: each output item added, its
text, the item done, then the completed response.

#### Mirrors ChatGPT relay output: encrypted reasoning, tool call, then answer
`pi-runtime.test.ts responsesTurn`: What LokalBot's ChatGPT plan relay passes back: encrypted reasoning and a
tool call, then the answer once the tool's output comes in.

#### Disable compiled caches as in PiLaunchPlanner
`pi-runtime.test.ts piTurn`: As in PiLaunchPlanner: no compiled copies outside the runtime.

#### MCP client is built-in extension left off by --no-extensions; load explicitly
`pi-runtime.test.ts STUB_MCP_SERVER`: Pi's MCP client is a built-in extension that Agent Mode's --no-extensions
leaves off. Loading it explicitly proves its tools still pass the gate.

#### Without cache settings Bun, pi and jiti write caches to home and tmp
`pi-runtime.test.ts`: Otherwise Bun's transpiler cache is written to ~/Library/Caches/bun, and
pi's compile cache and jiti's extension cache to the temporary folder.

#### Older host without kind says nothing about the folder
`pi-runtime.test.ts`: Launched without a kind (an older host): say nothing about the folder.

#### Small local models reject later system messages; Pi folds into first
`pi-runtime.test.ts`: Small local models' chat templates reject a system message after the
first; Pi folds the changed prompt into the leading one instead.

#### Responses API sends instructions as developer message and no output cap
`pi-runtime.test.ts`: Instructions go out as a developer message, and no output cap.

#### store false means pi replays encrypted reasoning with call and output
`pi-runtime.test.ts`: store: false keeps nothing on OpenAI's side, so pi replays the
encrypted reasoning with the call and its output.

### `Scripts/tests/run-pi-runtime-tests.sh`

#### Resolve provider import from pinned runtime without installing into checkout
`run-pi-runtime-tests.sh (file)`: Resolve the extension's provider import from the pinned runtime without
installing dependencies into the checkout or modifying the installed runtime.

#### No transpiler or compile caches in home cache and temp folder
`run-pi-runtime-tests.sh`: No transpiler or compile caches: Bun, pi and jiti would keep them in
~/Library/Caches/bun and the temporary folder.

### `Scripts/tests/test_check_capture_recordings.py`

#### Set order varies; stripping zoom.us first must not leave app. behind
`test_check_capture_recordings.py`: Set order changes between processes; stripping zoom.us before
app.zoom.us must not leave "app." behind as unscrubbed text.

### `Scripts/tests/test_ci_pipeline.py`

#### Draft or UI-irrelevant PRs pass aggregate check with suite skipped
`test_the_suite_must_have_run_and_passed_in_the_newest_run`: A draft or UI-irrelevant pull request passes the aggregate check
with the suite skipped.

#### Website push must start no run or use its own concurrency group
`test_a_website_push_starts_nothing_that_cancels_a_candidates_gates`: A new run cancels the same group's running one, so a website push must
either start no run or land in a group of its own.

#### Failed-jobs-only rerun keeps the passing runner's reports
`test_reports_from_an_earlier_attempt_of_the_same_run_pass`: A failed-jobs-only rerun keeps the passing runner's reports.

#### Model stub's Bun is fetched only on the background-phase runner
`test_background_flows_run_only_in_their_own_shard`: The model stub's Bun is fetched only on the runner that has the background phase.

#### Workday check reports from the tests job, so it skips with it
`test_nightly_build_only_compiles_and_a_failed_build_opens_an_issue`: The workday check reports from the tests job, so it is skipped with it.

#### Comparison exit code fails the job; nothing may mask it
`test_a_drift_run_that_could_not_record_opens_an_issue`: The comparison's exit code is what fails the job; nothing may mask it.

#### With a key every run records; an empty recording fails comparison
`test_a_drift_run_without_the_key_is_a_notice_on_pull_requests_and_a_failure_elsewhere`: With a key, every kind of run records, and an empty recording then fails the comparison.

#### Fork pull requests have no secrets: notice, not failure
`test_a_drift_run_without_the_key_is_a_notice_on_pull_requests_and_a_failure_elsewhere`: A pull request from a fork has no secrets: its author gets a notice, not a failure.

#### Nightly or manual run without the key fails; check is off
`test_a_drift_run_without_the_key_is_a_notice_on_pull_requests_and_a_failure_elsewhere`: A nightly or manual run without the key has the check switched off: that fails.

#### Recording, comparing and upload wait on the key check first
`test_a_drift_run_without_the_key_is_a_notice_on_pull_requests_and_a_failure_elsewhere`: Recording, comparing and the upload wait on that answer; the key check comes first.

#### Secrets are unreadable in if: conditions; presence travels through env
`test_a_drift_run_without_the_key_is_a_notice_on_pull_requests_and_a_failure_elsewhere`: A secret in an `if:` is not readable there; presence travels through env.

#### A step-level condition once made the bundle go missing from releases
`test_the_bundle_is_attached_whatever_the_registry_switch_says`: A step-level condition here is how the bundle went missing from releases.

#### No repository variable is set, so unset must mean yes
`test_listing_is_on_until_the_variable_says_false`: No repository variable is set, so an unset one has to mean yes.

#### Failed workday must not fail or hang the unit-test check
`test_workday_is_awaited_and_keeps_its_own_required_check`: A failed workday must not fail the unit-test check, and must not hang it.

#### Failed-jobs-only rerun consumes products from an earlier attempt
`test_identity_ignores_only_runner_location_job_and_attempt`: A failed-jobs-only rerun consumes products from an earlier attempt of the same run.

### `Scripts/tests/test_ci_preflight.py`

#### Disable Git background helpers that race temp-directory cleanup on hosted Macs
`setUp`: Short failure-path tests can finish while Git's background helpers
still touch .git, racing TemporaryDirectory cleanup on hosted Macs.

#### GitHub Actions enables -e and pipefail for an explicit bash shell
`test_ci_logging_pipeline_stops_before_smoke_when_compilation_fails`: GHA enables -e -o pipefail for an explicit Bash shell.

### `Scripts/tests/test_claude_plugin.py`

#### Install copies the plugin source folder, so never the repository root
`test_marketplace_points_at_the_plugin_folder`: An install copies the plugin's source folder, so it must be this
small folder and never the repository root.

#### Directory refuses local MCP plugins unless the organization is Verified
`test_no_local_mcp_server`: The directory refuses plugins that start an MCP server on the user's
computer unless the organization is Verified, which LokalBot isn't.

#### Installs stay cached until version changes; entry must not carry a second one
`test_one_semver_version_in_the_manifest`: Installs stay on their cached copy until this string changes, and
the marketplace entry must not carry a second one that could drift.

#### Icon is found by path; naming it triggers a policy hold
`test_listing_icon_is_a_square_png_in_range`: Found by its path; naming it in the manifest or README puts the
submission on a policy hold ("image the plugin's code could run").

#### Plugin repository holds only this folder, so parent-relative links break
`test_nothing_links_outside_the_plugin`: Installs and the plugin's own repository (stevyhacker/lokalbot-claude-plugin)
hold only this folder, so a relative link above it breaks there.

#### The deploy key must never reach a self-hosted runner
`test_sync_workflow_copies_this_folder`: The deploy key must never reach a self-hosted runner.

#### Skills must name stated and learned authorities so learned items aren't quoted as user words
`test_skills_name_every_authority_personal_context_returns`: An agent told every item is the user's own statement quotes a learned,
possibly outdated one as the user's words.

### `Scripts/tests/test_cotyping_compare_safety.py`

#### Shell test stubs pgrep, open, pkill, osascript, screencapture and sleep via PATH
`test_scripts_refuse_running_apps_and_touch_only_their_own_document`: The shell test puts stand-ins for pgrep, open, pkill, osascript, screencapture
and sleep first on PATH, so nothing is launched, quit or captured.

### `Scripts/tests/test_cotyping_probe_contract.py`

#### Swift compile test runs on macOS only; timeout allows a loaded runner
Compiles a Swift script with xcrun. Build's unit-test job runs it on macOS;
the CI helpers job on Linux skips it. That job runs the unit tests, the
workday and the crash probe at the same time, and the compile alone passed
60 s there on 2026-11-18, so the limit allows for a loaded runner.

### `Scripts/tests/test_day_in_the_life.py`

#### Real ASR wording can trigger a notes repair the stub lacked a rule for
`test_only_real_asr_answers_notes_repairs`: Nightly 2026-10-01: real Parakeet wording missed a recorded quote,
the app asked for a repair, and the stub had no rule (HTTP 500).

#### outcomes.json shape as MeetingOutcomes encodes it, with owner Me and isForUser
`test_owned_action`: outcomes.json as MeetingOutcomes encodes it: actionItems with the
resolved owner ("Me") and isForUser.

#### Pool word errors across meetings; one short meeting hit 21.4% error
`test_day_rate_pools_meetings_so_one_short_meeting_cannot_decide_the_run`: Nightly 2026-10-01: Parakeet heard the 14-word sprint planning as
"...i'll pare on the tombstone clean up tomorrow" (21.4% per meeting
before compounds were ignored) and the design review exactly.

### `Scripts/tests/test_google_play_release.py`

#### Skipped optional windows-sign must not skip linux-repos, aur or winget
`test_release_workflow_wires_google_play_and_keeps_downstream_linux_windows_jobs_running`: Regression guard: skipped optional windows-sign must not skip linux-repos, aur, or winget.

### `Scripts/tests/test_localization.py`

#### Recorded view literals predate the check; translating one removes its line
`UNTRANSLATED_VIEW_LITERALS`: Literals in these views that predate the view-literal check and still have
no catalog entry. Translating one means deleting its line here.

#### SwiftUI looks up these first arguments; StatTile passes label as LocalizedStringKey
`CATALOG_CALLS`: SwiftUI looks these first arguments up in the catalog; StatTile passes its
label on as a LocalizedStringKey.

#### Proper names and symbols read the same in every language
`INTENTIONAL_VIEW_LITERALS`: Proper names and symbols that read the same in every language.

#### String properties shown via LocalizedStringKey need catalog defaults too
`scan_view_literals`: A String property shown through LocalizedStringKey(property) needs
its default in the catalog too, like `var title = "Needs Attention"`.

#### Keyed by file name so moving views between folders keeps entries
`view_literal_problems`: Keyed by file name, so moving a view between feature folders keeps its entries.

#### English must exist even when the Mac uses another language
`test_languages_have_matching_nonempty_entries`: English must be available even when the Mac uses another language.

#### Key checks miss new copy without a key, shipping English everywhere
`test_view_literals_have_catalog_entries`: Catalog checks above only compare keys that already exist; new view
copy without a key ships in English to every other language.

#### An interpolation matches whichever format specifier the key uses
`test_view_literal_scan_finds_untranslated_copy`: An interpolation matches whichever format specifier the key uses.

#### Direction comes from view environment; machine translation inserts LRM, RLM, ALM
`test_line_breaks_and_direction_controls`: Direction belongs to the view environment, never hidden overrides or
marks in copy. Machine translation most often inserts LRM, RLM and ALM.

### `Scripts/tests/test_model_drift.py`

#### A single slow GLM call is normal; recordings span 1-46 s
`test_one_slow_call_is_not_latency_drift`: Nightly 2026-10-01: a single GLM notes call took 4287 ms against
1843 ms recorded, while the same model's recordings span 1-46 s.

#### GLM once returned empty notes for an unchanged prompt; must be reported
`test_an_emptied_list_is_reported`: Nightly 2026-10-01: GLM answered the unchanged notes prompt with
actions but `"notes": []`; the recording had five notes.

#### HTTP 401 on every request once produced a false No drift report
`test_a_run_that_recorded_nothing_is_not_reported_as_no_drift`: Nightly 2026-11-10: OpenRouter answered every request with HTTP 401,
each case was saved with no calls, and the report said "No drift detected."

#### Recording test skips without a key and writes no folder
`test_a_run_that_wrote_no_recordings_fails_too`: The recording test skips without a key and writes no folder at all.

### `Scripts/tests/test_openai_plugin.py`

#### Agent Plugins 1.0.0 schema allows only these top-level keys
`ALLOWED_KEYS`: Top-level keys the Agent Plugins 1.0.0 schema allows (additionalProperties: false).

#### Local MCP needs OpenAI allowlist; hooks or apps can't ship in ZIP
`test_skills_only_and_desktop_only`: Local MCP needs OpenAI's partner allowlist, and hooks or app references
can't be submitted as a ZIP, so the package is skills only.

#### Shell variables read as credentials to directory scanners
`test_skills_carry_nothing_claude_specific_or_scanner_bait`: Shell variables read as credentials to directory scanners.

#### OpenAI submission keeps supporting files and references inside the plugin
`test_skills_need_no_instructions_from_outside_the_package`: OpenAI's submission rules: keep supporting files and their references
inside the plugin. Download pages are fine; repository docs are not.

#### Approved remote model servers do receive library content
`test_listing_does_not_promise_nothing_leaves_the_computer`: Remote model servers the user approves do receive library content.

### `Scripts/tests/test_release_signing_boundary.py`

#### codesign needs keychain on search list or DMG signing fails
`test_signing_keychains_are_searchable_while_codesign_runs`: codesign finds the identity's private key through the user keychain
search list, even with --keychain. Without it the DMG signature fails
with "The specified item could not be found in the keychain."

### `Scripts/tests/test_sample_meeting.py`

#### Maps spoken language to interface language holding its Ask question
`LANGUAGES`: Spoken language → the interface language whose strings carry its Ask question.

### `Scripts/tests/test_seed_demo_library.py`

#### Ownership decision precedes generation; stub heavy writers to test the CLI boundary
`DemoLibraryDestinationTests.run_main`: The ownership decision happens before fixture generation. Stub the
expensive audio/data writers so these tests exercise that real CLI
boundary without depending on codecs or creating benchmark data.

#### Encoding needs afconvert, so macOS only; Linux helpers job skips
`SeedProfileTests`: Encodes audio with /usr/bin/afconvert. Build's unit-test job runs it on macOS;
the CI helpers job on Linux skips it.

#### Merged source over 30 s without speech triggers repair; seed must be healthy
`test_full_day_merged_meeting_is_covered_by_its_golden_transcript`: A merged source of 30 s or more with no transcript segment is a
merged gap, which the pipeline repairs by re-transcribing; the seeded
day must be healthy, so every source span holds golden speech.

#### Website examples need isolated searches and nothing seeded in capture's future
`test_studio_profile_keeps_each_example_on_its_own_surface`: The website shows the holiday shoot meeting, a "MacBook" search and a
"captions" search. Each search must return only its own rows, and
nothing seeded for today may lie in the future of the capture.

#### Photos moment lies inside featured call to show On Screen section
`test_studio_profile_keeps_each_example_on_its_own_surface`: The Photos moment falls inside the featured call, so the meeting
window shows it under "On Screen During the Meeting".

#### Podcast call has nothing on screen, matching README without that section
`test_studio_profile_keeps_each_example_on_its_own_surface`: Nothing was on screen during the podcast call, which the README shows
without an "On Screen During the Meeting" section.

### `Scripts/tests/test_sync_crate_notices.py`

#### A notice for another crate version does not cover this one
`test_a_crate_neither_file_names_is_reported_with_its_version`: A notice for another version of the crate does not cover this one.

### `Scripts/tests/test_traffic_report.py`

#### vh units and html/body height 100% break embedded auto-height frames
`test_render_html_respects_embed_layout_and_theme_tokens`: Never use vh units anywhere or height:100% on html/body (breaks embedded auto-height frames).

### `Scripts/tests/test_ui_durations.py`

#### Planning on the 30 s guess left shards two minutes apart
`test_most_functional_tests_have_a_timing`: A new test may wait for its first hosted run; a suite planned mostly
on the 30 s guess left the two shards two minutes apart.

### `Scripts/tests/test_unit_skips.py`

#### Shape that xcresulttool test-results tests prints
`tree`: The shape `xcresulttool get test-results tests` prints: plan, bundle, suite, cases.

### `Scripts/tests/test_upgrade_fixture_settings.py`

#### Remote automation approval existed only in 0.9.0 and 0.9.1; removed in 0.9.2
`test_only_0_9_0_and_0_9_1_carry_the_old_automation_approval`: The separate approval for scheduled remote runs existed only in
0.9.0 and 0.9.1; 0.9.2 removed it (#113).

#### Versions sort numerically: 0.10.10 after 0.10.9
`test_committed_versions_are_the_fixture_folders_in_release_order`: 0.10.10 sorts after 0.10.9, not after 0.10.1.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
