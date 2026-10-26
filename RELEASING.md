# Releasing LokalBot (Sparkle)

Practical runbook for cutting a notarized LokalBot release and publishing a
Sparkle update. The same tag also ships the Linux and Windows app with its own
signed update feeds ([Linux and Windows](#linux-and-windows)). The release
tooling lives in `Scripts/`:

| File | Role |
| --- | --- |
| `Scripts/build_release_dmg.py` | styled installer DMG via `dmgbuild` |
| `Scripts/build_test_dmg.sh` | quick unsigned DMG for local layout checks |
| `Scripts/generate_appcast.py` | sign the DMG + render `appcast.xml` |
| `Scripts/appcast.template.xml` | Sparkle 2 feed skeleton |
| `Scripts/clean_local.sh` | wipe local build/derived/DMG artifacts |
| `Scripts/bump-version.py` | set the version in every file one tag ships it from |
| `LinuxWindows/scripts/release-feeds.sh` | sign the Linux/Windows archives and write their update feeds |
| `LinuxWindows/scripts/linux-repos.sh` | add the `.deb` and `.rpm` to the signed apt and dnf repositories ([Linux package repositories](#linux-package-repositories)) |
| `LinuxWindows/scripts/third-party-licenses.sh` | regenerate the Linux/Windows crate license list ([Third-party licenses](#third-party-licenses)) |

---

## Mental model (keep this)

Two independent signing systems — never mix them:

1. **Apple signing** (`codesign` + `notarytool` + `stapler`) → lets macOS *run* the app.
2. **Sparkle signing** (Ed25519 `sign_update`) → lets installed copies *trust the update*.

Apple checks the app/DMG bytes; Sparkle checks the DMG bytes against `SUPublicEDKey`.
Because Sparkle hashes the *final* bytes, it is always the **last** step — after
notarization and stapling, with no further edits to the DMG.

---

## Current config

- Product: **LokalBot** · bundle id `me.dotenv.LokalBot` · team `3N8B4562P4`
- Xcode project `LokalBot.xcodeproj` · schemes `LokalBot` (prod), `LokalBot Dev` (dev)
- Sparkle feed (`SUFeedURL`):
  `https://github.com/stevyhacker/lokalbot/releases/latest/download/appcast.xml`
- Feed file name: **`appcast.xml`** (uploaded as a GitHub Release asset, not Pages)
- Public key (`SUPublicEDKey`):
  `R1A2lIfQ82UnkmUd12kwgpiS3tOlb6D0pVK8sKSrZdA=`

The private Sparkle key is a secret. **Never commit it.**

---

## One-time setup

### 1. Point the project at a GitHub repo

The canonical remote is `https://github.com/stevyhacker/lokalbot.git`. If you
are starting from a fresh clone or fork, set the real `owner/repo` slug anywhere
the examples below still use `OWNER/REPO`.

Create a new remote only for a fresh repository:

```sh
git remote add origin git@github.com:OWNER/REPO.git
git push -u origin main
```

### 2. Generate the Sparkle key pair (ONCE, ever)

Sparkle ships the key tools as binaries inside its SwiftPM artifact. After an
Xcode build that resolves the Sparkle package, symlink them onto your PATH:

```sh
mkdir -p ~/bin
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name generate_keys    -type f | head -n 1)" ~/bin/sparkle-generate-keys
ln -sf "$(find ~/Library/Developer/Xcode/DerivedData -name sign_update       -type f | head -n 1)" ~/bin/sparkle-sign-update
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

> No Sparkle package resolved yet? Download a Sparkle release tarball from
> <https://github.com/sparkle-project/Sparkle/releases>; the tools are under
> its `bin/` directory (`bin/generate_keys`, `bin/sign_update`).

Generate the key and print the public half:

```sh
sparkle-generate-keys           # creates the private key in the login Keychain
sparkle-generate-keys -p        # prints the base64 SUPublicEDKey
```

Back the private key up somewhere safe (you can never regenerate a matching one):

```sh
sparkle-generate-keys -x ~/secure/LokalBot-sparkle-key.txt
```

### 3. Publish the public key in the app

Add the Sparkle Info.plist keys via `project.yml` (so xcodegen writes them into
`LokalBot.app/Contents/Info.plist`). Under `targets.LokalBot.info.properties`:

```yaml
        SUFeedURL: https://github.com/stevyhacker/lokalbot/releases/latest/download/appcast.xml
        SUPublicEDKey: R1A2lIfQ82UnkmUd12kwgpiS3tOlb6D0pVK8sKSrZdA=
        SUEnableAutomaticChecks: true        # default on for new installs
```

`SUPublicEDKey` must match the private key used by `sign_update` at release time.
A mismatch makes every installed copy reject the update silently.

> Adding the Sparkle **framework** to the app (the `SPUStandardUpdaterController`
> wiring) is separate from this runbook; this document covers building, signing,
> and publishing the release artifacts.

### 4. Create the Developer ID Application certificate

For direct distribution outside the Mac App Store, create a **Developer ID
Application** certificate for team `3N8B4562P4`. The simplest route is Xcode:

1. Open Xcode → Settings → Accounts.
2. Select the Apple ID and the `Stevan Bogosavljevic` team.
3. Open **Manage Certificates…**, click `+`, and choose
   **Developer ID Application**.

Verify that the certificate and its private key are available locally:

```sh
security find-identity -p codesigning -v
```

The output must include `Developer ID Application` with team `3N8B4562P4`.
`Apple Development`, `Apple Distribution`, and `Developer ID Installer` are
different certificate types and do not replace it for this DMG flow.

For GitHub Actions, export the Developer ID Application certificate **with its
private key** from Keychain Access as a password-protected `.p12`. Never commit
the `.p12` or its password.

An App Store Connect app record and a Mac App Store provisioning profile are
not required for this direct-distribution path.

### 5. Store notarization credentials

Create an app-specific password at <https://appleid.apple.com>, then cache it as
a notarytool keychain profile so the release commands stay credential-free:

```sh
xcrun notarytool store-credentials "LokalBot-notary" \
  --apple-id "you@example.com" \
  --team-id "3N8B4562P4" \
  --password "<app-specific-password>"
```

---

## Release flow (every release)

Run from the repo root. Replace `1.0.0` / `100` with the version you are shipping.

### 0. Add the previous release's upgrade fixture

Each stable release run builds its own version's fixture on a clean hosted Mac
once the DMG is published (the **Upgrade fixture** job, which calls
`upgrade-fixtures.yml`) and keeps it for 90 days. Add the previous stable
version's fixture to the candidate:

```sh
Scripts/upgrade-fixtures/add.sh 0.8.0
```

It downloads that artifact from a run of the release's tag or of `master`,
extracts it into `LokalBotTests/Fixtures/upgrade/<version>/` with the
database's write-ahead log folded in, and checks that its manifest names the
version and the synthetic library. Commit the folder with the candidate; the
Build job's `UpgradeMigrationTests` opens every fixture folder. When the
artifact is missing or expired, build it with
`gh workflow run upgrade-fixtures.yml --ref master -f versions=<version>` and
run `add.sh` again once that finishes. The committed folders are the only list
of fixture versions. `release-preflight.py --candidate` refuses a release
whose changelog base has no fixture.

### 1. Bump the version

One tag ships macOS, Linux and Windows, so the marketing version lives in
`LokalBot/Info.plist` (the source of truth), `project.yml`, and the Linux and
Windows workspace (`LinuxWindows/Cargo.toml` and its crates in
`LinuxWindows/Cargo.lock`). Set all of them at once:

```sh
python3 Scripts/bump-version.py 1.0.0 100
```

- `CFBundleShortVersionString` and the workspace version → marketing version, e.g. `1.0.0`
- `CFBundleVersion` → build number, e.g. `100` (monotonic; Sparkle compares this)

`release-preflight.py` (also in every XcodeGen CI run) fails when any of these
disagree, or when the Linux/Windows update key differs from `SUPublicEDKey`.
Then regenerate the project:

```sh
xcodegen generate
```

Prepare `Scripts/release-notes/v<version>.md` at the same time, including a
human-readable summary and the full comparison from the previous stable tag.
Before committing a stable release candidate, fetch current tags and validate
the metadata files together (replace the version below):

```sh
git fetch origin --tags
git add project.yml LokalBot/Info.plist LinuxWindows/Cargo.toml LinuxWindows/Cargo.lock \
  Scripts/release-notes/v0.8.1.md
python3 Scripts/release-preflight.py --version 0.8.1 --candidate --staged
git diff --cached
```

This read-only preflight checks every version source, the notes and changelog
base, increasing build numbers, local/remote tag availability, and that the
staged snapshot contains exactly the five validated metadata files. Complete
feature/fix commits separately before preparing this candidate. It never
commits, tags, or publishes. Without `--candidate --staged`, the script checks
metadata consistency and stable-release notes, including for already-released
versions. General PR/push CI uses `--metadata-only` to validate version/build
consistency without requiring stable-release notes. That mode cannot be combined
with `--candidate` or `--staged`; candidate preparation and stable publication
still require the notes and changelog. Prerelease publication retains its
tag-specific notes path and generated-notes fallback.

Build (including its Tests job), Nightly and Release use Xcode **26.4.1** (build
**17E202**) on `macos-26` runners; MLX 0.32.3 and later need its Swift 6.3 toolchain,
and the `macos-15` image has no Xcode newer than 26.3. 0.8.0 used Xcode 26.3 build
**17C529**. The required UI Tests gate builds its products on `macos-26` with 26.4.1
and runs them on `macos-15` with Xcode 26.3, the app's oldest supported macOS
(`Scripts/ci/test-products.py` accepts that toolchain difference for UI products
only); **UI Tests (macOS 26)** builds and runs the same suite with 26.4.1,
weekly and on demand (`gh workflow run ui-tests-macos26.yml --ref BRANCH`), and is
not a merge or release gate until its known macOS 26 failures are fixed. Update
explicit versions and runners together after hosted validation. The Build gate compiles the production app and its unit-test
target. The UI workflow builds its separate host once, runs the critical group,
then Reduce Motion, then independent functional and visual shards covering all
72 captures. A shared inventory and aggregate result verification prevent missing
or duplicate tests. Filtered manual UI
dispatches remain focused checks and do not constitute the full release gate.
Test products are shared only within the same workflow attempt and exact SHA,
with clean build inputs, matching toolchain and digest verification; missing or
stale products fail instead of rebuilding silently. Use **Re-run all jobs** when
retrying a shared-products workflow: a failed-jobs-only retry cannot consume
artifacts from the preceding attempt. UI Tests runs on pull requests that are
ready for review, weekly on `master`, and for a release candidate that its
merged pull request's run doesn't cover, when `Scripts/prepare-release.sh`
dispatches it with the candidate's SHA; it no longer runs on every `master`
push. Build, Lint and XcodeGen still do. Build skips its
macOS jobs on pull requests that change only docs, the website, assets, video
or distribution notes (`Scripts/ci/build-relevance.py`).

### Optional: prepare the signed archive while CI validates

After pushing the complete candidate commit to `master`, run:

```bash
Scripts/prepare-release.sh 0.8.1
```

This explicitly dispatches the Release workflow in preparation mode.
Preparation validates candidate metadata and signs/exports the app while the
normal push CI runs. It creates no tag, sends nothing to notarization and
publishes no release. When the candidate is the merge of a pull request whose
full UI run tested the candidate's exact tree (`release-candidate.py
ui-covered`), that run is the UI gate; otherwise the script also dispatches the
full UI Tests suite for the candidate's exact SHA. Wait for preparation, any
UI Tests run it dispatched and the Build, Lint and XcodeGen push runs on the
exact commit before creating the release tag. Merge the release pull request
only once it contains the current `master`, so that its run covers the merge.

Build and unit execution are separate jobs in `build.yml`, sharing one compile.
The UI aggregate checks smoke, Reduce Motion, both functional shards, all three
visual sizes and every capture. Filtered or legacy-comparison runs cannot replace
the complete UI gate. All UI execution remains on hosted runners.

On a tag push, Release requires the candidate to remain the current `master` tip
and verifies successful **push** runs for Build (both jobs), Lint and XcodeGen,
and a successful UI Tests run on that exact SHA, either a push run or the
exact-SHA dispatch from `prepare-release.sh`; only a full run reports
`XCUITest (macOS)`. When no UI Tests run exists on that SHA, the merged pull
request's newest run counts instead, if the candidate merges a pull request
from this repository into `master`, the pull request's head already contained
the previous `master` tip and has the candidate's exact tree, and that run
built and passed the full suite (`UI build (macOS)` and `XCUITest (macOS)`).
GitHub tested that head merged into an older `master`, which is the head's own
tree. An exact-SHA run, when there is one, always decides. If a UI Tests job
fails to get a runner, use **Re-run all jobs** on that dispatch. It retrieves prepared apps only from successful `release.yml` manual
runs on that exact trusted master SHA and verifies source/tree, version/build,
Xcode, architecture, lockfile, run identity and archive digest before reuse.
A missing/expired preparation uses the existing cold archive flow; a mismatched
artifact fails. A changed candidate requires new push validation and preparation.
Preparation artifacts expire after seven days. Final signing/notarization,
stapling, Sparkle signing and independent download verification remain mandatory.

For hosted comparison of the retained capture timer:

```bash
gh workflow run ui-tests.yml --ref BRANCH -f capture_mode=legacy
```

Its visual artifacts retain all 72 cases under a separate comparison check; it
cannot satisfy the default full UI release gate. Default captures require ready route content and
window geometry before the preserved one-second compositing delay.

### 2. Archive + export a Developer ID build

Hardened Runtime must be ON for notarization (the project default is OFF for
fast local builds), so pass it on the archive command:

```sh
xcodebuild archive \
  -project LokalBot.xcodeproj \
  -scheme LokalBot \
  -configuration Release \
  -archivePath build/LokalBot.xcarchive \
  -allowProvisioningUpdates \
  ENABLE_HARDENED_RUNTIME=YES \
  ARCHS=arm64
```

The release is Apple Silicon only. Keep `ARCHS=arm64`: the bundled native
runtimes and the speech package do not provide a supported `x86_64` release
slice.

Create `build/exportOptions.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>3N8B4562P4</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
```

Export the signed app to `build/export/LokalBot.app` (the default the DMG
builder looks for):

```sh
xcodebuild -exportArchive \
  -archivePath build/LokalBot.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/exportOptions.plist
```

### 3. Notarize + staple the app

Stapling the app (not just the DMG) lets first launch succeed offline:

```sh
ditto -c -k --keepParent build/export/LokalBot.app build/LokalBot-app.zip
xcrun notarytool submit build/LokalBot-app.zip --keychain-profile "LokalBot-notary" --wait
xcrun stapler staple build/export/LokalBot.app
```

### 4. Build the styled DMG

```sh
python3 -m venv /tmp/LokalBot-dmg-venv
/tmp/LokalBot-dmg-venv/bin/python3 -m pip install 'dmgbuild==1.6.7'
/tmp/LokalBot-dmg-venv/bin/python3 Scripts/build_release_dmg.py \
  --app build/export/LokalBot.app \
  --output build/LokalBot.dmg
```

Keep `dmgbuild` inside the venv. Homebrew Python is PEP 668-managed and rejects
system-level `pip install` calls on current macOS runners.

This stages `LokalBot.app` beside an `Applications` shortcut, locks the
drag-to-install icon layout, and reuses the bundle's `AppIcon.icns` as the
volume icon. Pass `--background path/to/dmg_background.png` (with an optional
sibling `@2x` for HiDPI) for custom art.

### 5. Notarize + staple the DMG

```sh
codesign --force --sign "Developer ID Application" --timestamp build/LokalBot.dmg
codesign --verify --strict --verbose=2 build/LokalBot.dmg
xcrun notarytool submit build/LokalBot.dmg --keychain-profile "LokalBot-notary" --wait
xcrun stapler staple build/LokalBot.dmg
xcrun stapler validate build/LokalBot.dmg
spctl --assess --type open --context context:primary-signature \
  --verbose=2 build/LokalBot.dmg
```

### 6. Sparkle-sign + generate the appcast (LAST)

No edits to the DMG after this point — the signature covers these exact bytes:

```sh
python3 Scripts/generate_appcast.py \
  --archive build/LokalBot.dmg \
  --archive-filename LokalBot-1.0.0-macos-arm64.dmg \
  --app build/export/LokalBot.app \
  --repo stevyhacker/lokalbot \
  --output build/appcast.xml
  # --ed-key-file ~/secure/LokalBot-sparkle-key.txt   # only if the key isn't in your Keychain
```

The script reads `CFBundleShortVersionString` / `CFBundleVersion` from the app,
locates `sign_update` (via `--sign-update-tool`, `$SPARKLE_BIN`, your PATH,
`xcrun`, or DerivedData), signs the DMG, and renders `appcast.xml` with the
enclosure URL `https://github.com/stevyhacker/lokalbot/releases/download/v1.0.0/LokalBot-1.0.0-macos-arm64.dmg`.
The DMG is published as `LokalBot-<version>-macos-arm64.dmg`, like the Linux and
Windows files, so `--archive-filename` must match the name you upload in step 7.

The download URL's tag defaults to `v<short-version>`. If you're publishing
under a pre-release tag (step 7), pass it explicitly — e.g.
`--release-tag v1.0.0-beta` — so the enclosure points at the release the DMG
actually uploads to.

### 7. Publish the GitHub Release

Upload the DMG under its versioned name, its checksum and the appcast as release
assets so the feed at `releases/latest/download/appcast.xml` resolves:

```sh
cp build/LokalBot.dmg build/LokalBot-1.0.0-macos-arm64.dmg
(cd build && shasum -a 256 -b LokalBot-1.0.0-macos-arm64.dmg > LokalBot-1.0.0-macos-arm64.dmg.sha256)
git tag v1.0.0 && git push origin v1.0.0
gh release create v1.0.0 \
  build/LokalBot-1.0.0-macos-arm64.dmg \
  build/LokalBot-1.0.0-macos-arm64.dmg.sha256 \
  build/appcast.xml \
  --title "LokalBot 1.0.0" \
  --notes-file Scripts/release-notes/v1.0.0.md
```

CI reads `Scripts/release-notes/<tag>.md` when that file exists (for example
`Scripts/release-notes/v0.6.1.md`) and posts it as the GitHub Release body.
Otherwise it falls back to `--generate-notes`. Write a short “What’s new”
summary there before tagging so Sparkle’s release-notes link and the GitHub
Release page show the same changelog.

Pre-release tags (a hyphen suffix, e.g. `v1.0.0-beta`) are marked **Pre-release**
on GitHub and won't become "Latest"; tag without a suffix for a stable release.

- Agent runtime: no separate pi GitHub asset is published. The app downloads
  checksum-pinned Bun, then installs pi from the public npm registry using
  `LokalBot/Resources/pi/runtime/package.json` + `bun.lock`. When bumping pi,
  pin the matching `pi-agent-core`, `pi-ai`, and `pi-tui` overrides,
  regenerate the lockfile with the Bun version in `AgentRuntimeManifest`, and
  verify a clean
  `bun install --production --frozen-lockfile --ignore-scripts` before release.

---

## Linux and Windows

The tag that releases macOS also builds and publishes the Linux and Windows
app. `release.yml` calls `linux-windows-release.yml`, which builds
`LokalBot-<version>-linux-x86_64.tar.gz` and `LokalBot-<version>-windows-x86_64.zip`
with `LinuxWindows/scripts/package.sh` from the tag, without secrets or a
compiled-output cache, while the macOS job runs. Its tag check fails when
`LinuxWindows/Cargo.toml` does not name the tag's version.

After the macOS job has published the release (so its release gates passed),
`linux-windows-publish` builds `lokalbot-update-feed`, then writes
`SPARKLE_PRIVATE_KEY` to a temporary file and runs
`LinuxWindows/scripts/release-feeds.sh`. It refuses a key that does not belong
to `SUPublicEDKey` in `Info.plist`, signs each archive's bytes with Ed25519
(the same signature Sparkle's `sign_update` makes; both Sparkle key formats
work), checks each feed against its archive, and attaches to the release:

| Asset | What it is |
| --- | --- |
| `LokalBot-<version>-linux-x86_64.tar.gz` (+ `.sha256`) | Linux archive with `install.sh` |
| `LokalBot-<version>-windows-x86_64.zip` (+ `.sha256`) | Windows archive |
| `LokalBot-<version>-windows-x86_64-setup.exe` (+ `.sha256`) | per-user Windows installer of the same files (`scripts/package-windows-installer.ps1`, Inno Setup 6): `%LOCALAPPDATA%\Programs\LokalBot`, a Start menu shortcut with the notification app id, and an Installed apps entry, without administrator rights. The release installs and uninstalls it on the Windows runner. Updates replace the files in place from the zip and then write the new version into that Installed apps entry, which winget reads (`lokalbot_update::installed_apps`) |
| `LokalBot-<version>-linux-amd64.deb`, `LokalBot-<version>-linux-x86_64.rpm`, `LokalBot-<version>-linux-x86_64.pkg.tar.zst` (+ `.sha256`) | Debian/Ubuntu, Fedora/openSUSE and Arch packages of the same binaries (`scripts/package-linux-distros.sh`, nfpm). The release checks each one installs in a clean Ubuntu 24.04, Fedora 41 and Arch container. They install into `/usr/bin`, so LokalBot announces updates for them instead of replacing its files; it recognizes them by the package name `lokalbot`. A `.deb` or `.rpm` that added the LokalBot repository ([Linux package repositories](#linux-package-repositories)) is told to run `sudo apt upgrade` or `sudo dnf upgrade`; the others get the command that installs the new package |
| `linux-x86_64.json`, `windows-x86_64.json` | update feeds |

A feed names the version, the minimum installed version that may install it
(default `0.0.0`, any; set `MINIMUM_VERSION` when a release must be installed
by hand), the archive's URL, size, SHA-256, the base64 signature and the
release notes URL. Installed copies read
`https://github.com/stevyhacker/lokalbot/releases/latest/download/<platform>.json`,
so, like `appcast.xml`, a feed takes effect when its release becomes Latest;
pre-release tags attach feeds that no copy reads. The app verifies size,
SHA-256 and the signature before unpacking, and refuses an archive whose
`LokalBot-<version>-<platform>` folder does not match the feed's version.

If the macOS release succeeded but a Linux/Windows job failed, fix the cause
and use **Re-run failed jobs**: the publish job uploads with `--clobber`.

### Third-party licenses

The archives, packages and installer ship `THIRD_PARTY_NOTICES.md` and the
whole `LICENSES/` folder; `scripts/package.sh` copies both, and the Linux
packages install them in `/usr/share/doc/lokalbot`. `LICENSES/rust-crates.md`
lists every crate compiled into `lokalbot` and `lokalbot-cli` with the license
it is used under and that license's text. cargo-about generates it from
`LinuxWindows/Cargo.lock`, using `LinuxWindows/about.toml` (accepted licenses,
targets, clarifications) and `LinuxWindows/about.hbs` (the template). After
any change to `Cargo.lock`, regenerate it and commit the result:

```sh
LinuxWindows/scripts/third-party-licenses.sh
```

The script downloads the pinned cargo-about (on Linux x86_64 or Apple
silicon) and checks its SHA-256. With `--check` it only compares. The
**Third-party licenses** workflow runs that on pull requests that change the
crates, and the Linux release job runs it before packaging, so a stale list
fails both.

- A crate whose license `about.toml` doesn't accept stops the script. Add the
  license to `accepted` only if it is compatible with GPL-3.0.
- A crate whose section shows the standard license text and its authors
  ships no license file cargo-about can read. If it ships one under another
  name, add a `clarify` entry with that file's SHA-256
  (`cargo-about clarify <file> path <crate source folder>` prints it). When a
  clarified file changes, the crate falls back to the standard text, and the
  difference shows in the diff.

The rest of the Linux and Windows section of `THIRD_PARTY_NOTICES.md` is kept
by hand:

- The native libraries come from the sherpa-onnx release that the
  `sherpa-onnx` crate links. When it changes version, update their table from
  sherpa-onnx's `cmake/` folder at the new tag. Replace
  `LICENSES/onnxruntime-ThirdPartyNotices.txt` with the file of the ONNX
  Runtime version it uses.
- The model table follows `LinuxWindows/crates/lokalbot-ai/src/catalog.rs`,
  `lokalbot-ai/src/ocr.rs` and `lokalbot-speech/src/models.rs`. Take each
  license from the model's own page.

### Dry run

```sh
gh workflow run linux-windows-release.yml --ref BRANCH
```

builds the same archives from the branch, signs their feeds with a throwaway
key through the same `release-feeds.sh`, checks that the release key refuses
them, and keeps archives and feeds as the `dry-run-release-assets` artifact.
It never reads `SPARKLE_PRIVATE_KEY` and publishes nothing. The **Linux &
Windows** CI workflow also installs each packaged archive and has it update
itself from a signed feed on `127.0.0.1` (`scripts/ci/update-e2e.sh`,
`update-e2e.ps1`). To try an update by hand, serve a feed on this computer
and start LokalBot with `LOKALBOT_UPDATE_FEED_URL` (loopback HTTP is allowed
only there) and `LOKALBOT_UPDATE_PUBLIC_KEY` (honored only with a loopback
feed); `LOKALBOT_UPDATE_CURRENT_VERSION` makes that one process act older.

### Checks after publishing

```sh
cd LinuxWindows
cargo run --release -p lokalbot-update --no-default-features --bin lokalbot-update-feed -- \
  verify --feed linux-x86_64.json --archive LokalBot-1.0.0-linux-x86_64.tar.gz
```

`verify` uses the embedded `SUPublicEDKey` unless `--public-key` is given.

### Rollback

Like Sparkle, installed copies follow the feeds of the Latest release. To stop
an update, re-upload the previous release's `linux-x86_64.json` and
`windows-x86_64.json` to the Latest release (or mark an older release Latest).

### AUR package

After the publish job, the `aur` job (`.github/workflows/aur.yml`) points the
`lokalbot-bin` AUR package (`LinuxWindows/packaging/aur`) at the stable tag's
Linux archive and its `.sha256`, builds and installs it in a clean Arch
container with namcap, and pushes `PKGBUILD` and `.SRCINFO` to
aur.archlinux.org with the `AUR_SSH_PRIVATE_KEY` secret. It pushes only while
the `AUR_PUBLISH` repository variable is `true` (set it once an AUR account holds
the key); without the variable or the secret it stops after the checks, and
pre-release tags skip it. To publish again from
master: `gh workflow run aur.yml -f tag=vX.Y.Z`. Setup, manual updates and the
expected namcap warnings are in
[the AUR package README](LinuxWindows/packaging/aur/README.md).

### winget

For a stable tag, the `winget` job (`.github/workflows/winget.yml`, on a
GitHub-hosted runner) runs after the installer is attached. With the
`WINGET_TOKEN` secret (a classic token with `public_repo`, owned by the account
whose fork of `microsoft/winget-pkgs` it pushes to), `wingetcreate update`
opens the pull request that adds `stevyhacker.LokalBot` `<version>` to
winget-pkgs, pointing at `LokalBot-<version>-windows-x86_64-setup.exe`.
Without the secret, before winget-pkgs has the package, or when it already has
the version, the job says so and succeeds. winget-pkgs' bots validate the pull
request and a moderator merges it, usually within a day or two. To resubmit
by hand: `gh workflow run winget.yml -f tag=v<version>`. The first version
and the token are set up once; see
[LinuxWindows/packaging/winget/README.md](LinuxWindows/packaging/winget/README.md).

## Homebrew synchronization after a stable release

The public `stevyhacker/homebrew-tap` owns an hourly `Sync LokalBot release`
workflow. It verifies downloaded release assets and their appcast relationship
before updating the live cask; it does not require a cross-repository secret.
For immediate synchronization after publication:

```sh
gh workflow run sync-lokalbot.yml --repo stevyhacker/homebrew-tap --ref main
```

Confirm the run succeeded and the live cask's version/SHA-256 match the published
DMG before announcing Homebrew availability. Do not treat `brew livecheck` or a
dispatched workflow as synchronization proof. See
[the Homebrew runbook](Distribution/homebrew/README.md#3-shipping-path-own-tap).

## CI release

A tag-triggered GitHub Actions workflow (`.github/workflows/release.yml`)
automates the flow above. It resolves packages, validates native vendors, and
builds an ad-hoc archive before any Developer ID identity is available. A
temporary keychain exists only while Xcode exports and seals the finished app,
then is deleted. The DMG uses a separate short-lived keychain that is deleted
immediately after `codesign`, before notarization. The workflow then notarizes
and staples, downloads the Sparkle tarball for `sign_update`, runs
`generate_appcast.py`, and uploads `LokalBot-<version>-macos-arm64.dmg`, its
`.sha256` and `appcast.xml` to the Release.
Jobs beside it build, sign and attach the Linux and Windows archives and feeds
([Linux and Windows](#linux-and-windows)); the manual steps above cover macOS
only.
Required repo secrets:

- `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PWD`
- `NOTARY_APPLE_ID`, `NOTARY_APPLE_TEAM_ID`, `NOTARY_APPLE_PWD`
- `SPARKLE_PRIVATE_KEY` (the base64 Ed25519 private key; written to a temp file
  and passed to `generate_appcast.py --ed-key-file`, and to
  `LinuxWindows/scripts/release-feeds.sh` for the Linux and Windows feeds)

Optional: `AUR_SSH_PRIVATE_KEY`, the AUR account's SSH key that lets the
release push the `lokalbot-bin` AUR package once the `AUR_PUBLISH` repository
variable is `true` ([AUR package](#aur-package)).

Set the certificate and credential secrets without pasting them into source or
shell history. `gh secret set NAME` prompts for the value securely:

```sh
base64 -i /path/to/Developer-ID-Application.p12 | \
  gh secret set MACOS_CERTIFICATE --repo stevyhacker/lokalbot
gh secret set MACOS_CERTIFICATE_PWD --repo stevyhacker/lokalbot
gh secret set KEYCHAIN_PWD --repo stevyhacker/lokalbot
gh secret set NOTARY_APPLE_ID --repo stevyhacker/lokalbot
gh secret set NOTARY_APPLE_TEAM_ID --repo stevyhacker/lokalbot --body 3N8B4562P4
gh secret set NOTARY_APPLE_PWD --repo stevyhacker/lokalbot
gh secret set SPARKLE_PRIVATE_KEY --repo stevyhacker/lokalbot
```

`NOTARY_APPLE_PWD` is an app-specific password for the Apple ID, not the
account's normal password.

CI passes `--repo "$GITHUB_REPOSITORY"`, so the `OWNER/REPO` placeholder is
resolved automatically there.

## Linux package repositories

The release's `.deb` and `.rpm` add LokalBot's own apt and dnf repositories,
the way Chrome's and VS Code's packages do, so installing the downloaded file
once means `sudo apt upgrade` or `sudo dnf upgrade` brings every later stable
version. The `.deb` installs `/etc/apt/sources.list.d/lokalbot.sources` and
`/usr/share/keyrings/lokalbot-archive-keyring.gpg`; the `.rpm` installs
`/etc/yum.repos.d/lokalbot.repo` (`gpgcheck=1`, `repo_gpgcheck=1`) and
`/etc/pki/rpm-gpg/RPM-GPG-KEY-lokalbot`. The repository files are config
files, so a user's edits (`Enabled: no`, `enabled=0`) survive upgrades.
`scripts/package-linux-distros.sh` adds these files only once
`LinuxWindows/packaging/linux/lokalbot-archive-keyring.asc` exists. The Arch
package has no repository.

| URL | What it is |
| --- | --- |
| `https://pkg.lokalbot.com/apt` | apt repository: suite `stable`, component `main`, `amd64`; signed `InRelease` and `Release.gpg`, indexes also by hash |
| `https://pkg.lokalbot.com/rpm` | dnf repository: signed RPMs, `repodata/repomd.xml.asc` |
| `https://pkg.lokalbot.com/lokalbot.gpg`, `lokalbot.asc` | the public key, unarmored and armored |

`release.yml`'s `linux-repos` job calls `.github/workflows/linux-repos.yml`
for stable tags after the packages are attached; pre-release tags never reach
the repositories. On a GitHub-hosted runner (never a self-hosted one: this key
decides what every subscribed computer installs as root) it downloads the
release's `.deb` and `.rpm` and checks their `.sha256`, copies the published
packages from the R2 bucket `lokalbot-packages`, and runs
`LinuxWindows/scripts/linux-repos.sh`. That adds the release unless its
version is already published (a published version's bytes never change),
keeps the newest 3 versions, signs new RPMs with `rpmsign`, rebuilds and signs
the indexes, and checks every signature against the public key. The job then
uploads packages and hash-named indexes first, then the signed indexes (sent
with `Cache-Control: no-cache`), deletes the pruned packages, and compares
what `pkg.lokalbot.com` serves with what it uploaded. The workflow owns the
bucket: anything else in it is deleted, except older hash-named indexes, kept
so a client holding the previous index still finds its files. Without the
secrets the job skips with a notice; once the key is committed, a missing
secret fails it, because that release's packages point at the repositories.

To add a release that is already out (or to retry), run
`gh workflow run linux-repos.yml -f tag=vX.Y.Z`. Pull requests that change the
repositories or the packages run `scripts/ci/check-linux-repos.sh`: it
packages the latest release's binaries as four versions with a throwaway key,
serves the repositories as `pkg.lokalbot.com` on a private Docker network, and
checks that clean Ubuntu 24.04, Debian 13 and Fedora containers install the
first from the downloaded file, upgrade with `apt upgrade` and `dnf upgrade`,
keep an edited repository file, and refuse a tampered `InRelease`, `Release`
or `repomd.xml`, a swapped `.deb` or `.rpm`, and an unsigned `.rpm`. Run it on
any Linux machine with Docker:
`NFPM=/path/to/nfpm LinuxWindows/scripts/ci/check-linux-repos.sh LokalBot-X.Y.Z-linux-x86_64`.

### One-time setup

1. Generate the key on a trusted computer: RSA 4096 (every apt and rpm
   version verifies it; Ed25519 needs a recent rpm), signing only, expiring in
   3 years. CI has no passphrase prompt, so the key has none; the backup is
   what protects it.

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --passphrase '' --quick-generate-key \
     'LokalBot package signing <stevyhacker@users.noreply.github.com>' rsa4096 sign 3y
   FPR=$(gpg --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
   gpg --armor --export-options export-minimal --export "$FPR" \
     > LinuxWindows/packaging/linux/lokalbot-archive-keyring.asc
   gpg --armor --export-secret-keys "$FPR" | gh secret set LINUX_REPO_GPG_PRIVATE_KEY --repo stevyhacker/lokalbot
   ```

   Keep `gpg --armor --export-secret-keys "$FPR"` and the revocation
   certificate `$GNUPGHOME/openpgp-revocs.d/$FPR.rev` in your password manager,
   not on disk, then `rm -rf "$GNUPGHOME"`. Don't commit the public key yet.
2. In Cloudflare: create the R2 bucket `lokalbot-packages`; under its
   Settings → Custom Domains, connect `pkg.lokalbot.com` (this adds the DNS
   record and serves the bucket publicly there; leave the `r2.dev` URL off);
   then create an R2 API token with **Object Read & Write** on that bucket
   only. Each object carries its own `Cache-Control`, so no cache rule is
   needed.
3. Add the token and account ID:

   ```sh
   gh secret set LINUX_REPO_R2_ACCOUNT_ID --repo stevyhacker/lokalbot
   gh secret set LINUX_REPO_R2_ACCESS_KEY_ID --repo stevyhacker/lokalbot
   gh secret set LINUX_REPO_R2_SECRET_ACCESS_KEY --repo stevyhacker/lokalbot
   ```

4. Publish the current release and check it is served:
   `gh workflow run linux-repos.yml -f tag=v0.11.0`, then
   `curl -fsS https://pkg.lokalbot.com/apt/dists/stable/InRelease`. Its
   packages don't add the repositories, so nobody uses them yet.
5. Commit `lokalbot-archive-keyring.asc`, with the README and website copy
   that tells users about the repositories (#339). The next release's `.deb`
   and `.rpm` add the repositories, and every release after it reaches them
   with `apt upgrade` and `dnf upgrade`.

### Key expiry and rotation

The job warns when the key expires within 180 days. After it expires, apt and
dnf refuse the repositories until the computer has the extended key, and the
only way to deliver it is a package update signed before the expiry. So extend
the key well ahead, with the backup imported into a temporary `GNUPGHOME`:

```sh
gpg --quick-set-expire "$FPR" 3y
gpg --armor --export-options export-minimal --export "$FPR" > LinuxWindows/packaging/linux/lokalbot-archive-keyring.asc
gpg --armor --export-secret-keys "$FPR" | gh secret set LINUX_REPO_GPG_PRIVATE_KEY --repo stevyhacker/lokalbot
```

Commit the key, store the new backup and ship a release; the published
`lokalbot.gpg` updates with it. apt reads the keyring file, so the installed
release is enough. dnf keeps the key it imported in the rpm database
(`gpg-pubkey`); `sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-lokalbot`
updates its expiry there (checked with rpm 6.0 on Fedora 44), which the
release notes should mention. A computer that missed
every update until the old expiry gets the key back with
`curl -fsSL https://pkg.lokalbot.com/lokalbot.gpg | sudo tee /usr/share/keyrings/lokalbot-archive-keyring.gpg > /dev/null`
(apt) or by installing the latest `.rpm` from the release page (dnf).

To move to a new key, generate it, commit both keys in one armored file
(`gpg --armor --export-options export-minimal --export OLD NEW`) and ship a
release, still signed with the old key. Once most installs have that release,
switch `LINUX_REPO_GPG_PRIVATE_KEY` to the new key; the next release's indexes
are signed with it. Drop the old key from the file a few releases later.

### If the key leaks

The key alone can't reach users: an attacker also needs to serve files as
`pkg.lokalbot.com`. Still, act at once:

1. Delete `LINUX_REPO_GPG_PRIVATE_KEY`, and revoke and replace the R2 token in
   Cloudflare.
2. Generate a new key. Import the old key's revocation certificate
   (`gpg --import OLD.rev`) and commit the new key and the revoked old key in
   one armored file.
3. Ship a release whose repositories are still signed with the old key (set
   it as the secret for this one run): installs trust only that key until
   they have the new keyring. Then set the new key as the secret and run
   `gh workflow run linux-repos.yml -f tag=<that release>`, which signs the
   same repositories again with it.
4. In the release notes, tell users who hadn't updated yet to install the
   latest package from the release page, and dnf users to remove the old key
   with `sudo rpm -e gpg-pubkey-<old key ID>` (dnf keeps keys it imported).

### Taking a version back

apt and dnf never downgrade, so the fix for a bad release is a newer one. To
stop more computers from upgrading in the meantime, delete the version's
`apt/pool/main/l/lokalbot/lokalbot_X.Y.Z-1_amd64.deb` and
`rpm/lokalbot-X.Y.Z-1.x86_64.rpm` from the bucket in the Cloudflare dashboard,
then run `gh workflow run linux-repos.yml -f tag=vPREVIOUS` with the previous
good tag: it rebuilds the indexes from what is left.

---

## Sanity checks

```sh
# Apple: app and DMG accepted by Gatekeeper
spctl -a -t exec -vv build/export/LokalBot.app
spctl -a -t open --context context:primary-signature -vv build/LokalBot.dmg

# Stapling present (offline launch)
xcrun stapler validate build/LokalBot.dmg

# Sparkle: signature verifies against the public key
sparkle-sign-update --verify "$(python3 - <<'PY'
import re,sys
print(re.search(r'edSignature="([^"]+)"', open('build/appcast.xml').read()).group(1))
PY
)" build/LokalBot.dmg

# Installer layout: mounts in icon view, app above the Applications drop target
hdiutil attach build/LokalBot.dmg
```

---

## Rules (important)

- Never lose the Sparkle private key → you can't ship a trusted update again.
- Never rotate the key casually → existing installs reject updates signed by a new key.
- Never commit the private key.
- Never sign Linux/Windows feeds with any key but `SPARKLE_PRIVATE_KEY`; copies
  verify against the embedded `SUPublicEDKey`.
- Always Sparkle-sign **after** the final DMG exists (no edits after signing).
- Always publish `appcast.xml` **after** the Release asset exists.
- Always pass the real `owner/repo` slug when generating the appcast.

---

## Rollback

Sparkle follows the appcast, not the GitHub Releases page. To roll back, restore
the previous release's `appcast.xml` as the `latest` asset (or re-upload the prior
DMG + its appcast). Leave the bad Release in place unless there's a security
reason to delete it; pulling the asset only breaks anyone mid-download.

---

## Clean slate

```sh
bash Scripts/clean_local.sh   # removes .build, build/, *.dmg, the dmgbuild venv, and LokalBot-* DerivedData
```
