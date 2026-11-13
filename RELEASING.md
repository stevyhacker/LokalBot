# Releasing LokalBot (Sparkle)

Practical runbook for cutting a notarized LokalBot release and publishing a
Sparkle update. The same tag also ships the Linux and Windows app with its own
signed update feeds ([Linux and Windows](Docs/releasing/linux-and-windows.md)) and the Android
app as a signed APK ([Android](Docs/releasing/android.md)); Google Play gets the same version by
hand. The release tooling lives in
`Scripts/release/` and `Scripts/build/`:

| File | Role |
| --- | --- |
| `Scripts/release/build_release_dmg.py` | styled installer DMG via `dmgbuild` |
| `Scripts/build/build_test_dmg.sh` | quick unsigned DMG for local layout checks |
| `Scripts/release/generate_appcast.py` | sign the DMG + render `appcast.xml` |
| `Scripts/release/appcast.template.xml` | Sparkle 2 feed skeleton |
| `Scripts/build/clean_local.sh` | wipe local build/derived/DMG artifacts |
| `Scripts/release/bump-version.py` | set the version in every file one tag ships it from |
| `Scripts/release/sign-android-release.sh` | align and sign the Android APK, then check its certificate |
| `LinuxWindows/scripts/release-feeds.sh` | sign the Linux/Windows archives and write their update feeds |
| `LinuxWindows/scripts/linux-repos.sh` | add the `.deb` and `.rpm` to the signed apt and dnf repositories ([Linux package repositories](Docs/releasing/linux-package-repos.md)) |
| `LinuxWindows/scripts/third-party-licenses.sh` | regenerate the Linux/Windows crate license list ([Third-party licenses](Docs/releasing/linux-and-windows.md#third-party-licenses)) |

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

## Setup and other channels

These have their own pages under [`Docs/releasing/`](Docs/releasing/):

- [One-time setup](Docs/releasing/one-time-setup.md): the GitHub repository, the Sparkle key pair, the Developer ID certificate and notarization credentials.
- [Linux and Windows](Docs/releasing/linux-and-windows.md): the port's signed archives and update feeds, third-party licenses, AUR and winget.
- [Linux package repositories](Docs/releasing/linux-package-repos.md): the signed apt and dnf repositories at pkg.lokalbot.com and their key.
- [Android](Docs/releasing/android.md): the signed APK and Google Play.
- [Homebrew](Docs/releasing/homebrew.md): syncing the cask after a stable release.
- [MCP Registry](Docs/releasing/mcp-registry.md): publishing the server entry.

---

## Release flow (every release)

Run from the repo root. Replace `1.0.0` / `100` with the version you are shipping.

### 0. Add the previous release's upgrade fixture

Each stable release run builds its own version's fixture on a clean hosted Mac
once the DMG is published (the **Upgrade fixture** job, which calls
`upgrade-fixtures.yml`) and keeps it for 90 days. Add the previous stable
version's fixture to the candidate:

```sh
Scripts/test/upgrade-fixtures/add.sh 0.8.0
```

It downloads that artifact from a run of the release's tag or of `master`,
extracts it into `LokalBotTests/Fixtures/upgrade/<version>/` with the
database's write-ahead log folded in, and checks that its manifest names the
version and the synthetic library. Commit the folder on its own, before the
release-metadata commit (the staged preflight in step 1 accepts only the
metadata files); the Build job's `UpgradeMigrationTests` opens every fixture
folder. When the artifact is missing or expired, build it with
`gh workflow run upgrade-fixtures.yml --ref master -f versions=<version>` and
run `add.sh` again once that finishes. The committed folders are the only list
of fixture versions. `release-preflight.py --candidate` refuses a release
whose changelog base has no fixture.

### 1. Bump the version

One tag ships macOS, Linux, Windows and Android, so the marketing version lives
in `LokalBot/Info.plist` (the source of truth), `project.yml`, the Linux and
Windows workspace (`LinuxWindows/Cargo.toml` and its crates in
`LinuxWindows/Cargo.lock`) and the Android app
(`Companion/android/app/build.gradle.kts`). Set all of them at once:

```sh
python3 Scripts/release/bump-version.py 1.0.0 100
```

- `CFBundleShortVersionString`, the workspace version and `versionName` → marketing version, e.g. `1.0.0`
- `CFBundleVersion` and `versionCode` → build number, e.g. `100` (monotonic; Sparkle and Android compare this)

`release-preflight.py` (also in every XcodeGen CI run) fails when any of these
disagree, or when the Linux/Windows update key differs from `SUPublicEDKey`.
Then regenerate the project:

```sh
xcodegen generate
```

Prepare `Scripts/release/release-notes/v<version>.md` at the same time, including a
human-readable summary and the full comparison from the previous stable tag.
Before committing a stable release candidate, fetch current tags and validate
the metadata files together (replace the version below):

```sh
git fetch origin --tags
git add project.yml LokalBot/Info.plist LinuxWindows/Cargo.toml LinuxWindows/Cargo.lock \
  Companion/android/app/build.gradle.kts Scripts/release/release-notes/v0.8.1.md
python3 Scripts/release/release-preflight.py --version 0.8.1 --candidate --staged
git diff --cached
```

This read-only preflight checks every version source, the notes and changelog
base, increasing build numbers, local/remote tag availability, and that the
staged snapshot contains exactly the six validated metadata files. Complete
feature/fix commits separately before preparing this candidate. It never
commits, tags, or publishes. Without `--candidate --staged`, the script checks
metadata consistency and stable-release notes, including for already-released
versions. General PR/push CI uses `--metadata-only` to validate version/build
consistency without requiring stable-release notes. That mode cannot be combined
with `--candidate` or `--staged`; candidate preparation and stable publication
still require the notes and changelog. Prerelease publication retains its
tag-specific notes path and generated-notes fallback.

#### Explainers for major features

Every major feature in a stable release ships with an explainer: one
infographic image (PNG) or one short PDF that shows a new user what the
feature does and how to start using it. A major feature is a new capability
people have to learn, such as a new page, workflow, integration, or group of
settings. Fixes, new model choices, and small additions to something people
already use don't need one.

- **Content.** What the feature does and who it's for; how to turn it on, with
  the real menu or settings path; what it reads, keeps, and sends, and what
  stays on the computer; its limits and anything unverified, such as an alpha
  platform or a pending review; and at least one real screenshot, film still,
  or diagram. Use synthetic data, such as the demo library, never a real
  library, mailbox, or calendar.
- **Format.** A PNG at least 1200 pixels wide, or a PDF of a few pages, under
  10 MB either way. Name it after the feature, not the release:
  `Website/public/explainers/<feature-slug>.png` or `.pdf`, in lowercase words joined by
  dashes, for example `Website/public/explainers/gmail-meeting-briefs.pdf`. When a later
  release changes the feature, update the same file.
- **Making one.** Write the explainer as an HTML page and render it with
  headless Google Chrome. Commit the page as
  `Docs/explainers/<feature-slug>.html`, so a later release can update the
  explainer from it:

  ```sh
  python3 Website/generator/render_explainer.py Docs/explainers/gmail-meeting-briefs.html Website/public/explainers/gmail-meeting-briefs.pdf
  python3 Website/generator/render_explainer.py Docs/explainers/gmail-meeting-briefs.html Website/public/explainers/gmail-meeting-briefs.png --size 1200x2400
  ```

  A PNG captures a fixed canvas at 2x, so design the page at that size. For a
  PDF, give the page `print-color-adjust: exact` so its backgrounds print, and
  size each page with `@page` so nothing breaks across sheets
  (`Docs/explainers/gmail-meeting-briefs.html` is one way to do that).
- **Land it before the candidate.** Commit explainers to `master` with their
  feature or in a separate pull request, because the candidate commit holds
  only the release metadata. The website deploys `Website/public/` from `master`, so the
  link works before the tag is pushed.
- **Link it** at the end of the feature's bullet under **What’s new**:
  `[How it works](https://www.lokalbot.com/explainers/gmail-meeting-briefs.pdf)`.
  The GitHub Release body and Sparkle's release-notes link show the same notes.
  After publishing, open each explainer link from the release page.

`release-preflight.py` enforces this for releases after 0.11.5. Notes with a
**What’s new** section must link at least one explainer, and every linked
explainer must be a committed PNG or PDF in `Website/public/explainers/`, under 10 MB.
When everything new in a release is small, say so in an HTML comment in the
notes, which GitHub doesn't show on the release page:
`<!-- no explainer: only small additions to existing pages -->`. The preflight
can't tell which bullets are major, so check each one while writing the notes.

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
target. The UI workflow builds its separate host once, then runs the critical
group, Reduce Motion, and the independent functional, background and visual
shards in parallel, covering all 78 captures. A shared inventory and aggregate result verification prevent missing
or duplicate tests. Filtered manual UI
dispatches remain focused checks and do not constitute the full release gate.
Test products are shared only within the same workflow attempt and exact SHA,
with clean build inputs, matching toolchain and digest verification; missing or
stale products fail instead of rebuilding silently. Use **Re-run all jobs** when
retrying a shared-products workflow: a failed-jobs-only retry cannot consume
artifacts from the preceding attempt. UI Tests runs on pull requests that are
ready for review, weekly on `master`, and for a release candidate that its
merged pull request's run doesn't cover, when `Scripts/release/prepare-release.sh`
dispatches it with the candidate's SHA; it no longer runs on every `master`
push. Lint runs on every push, and Build and XcodeGen on every push except one
of only docs, the website and the scripts that generate it, assets, video or
distribution notes (`DOCS_ONLY` in `Scripts/ci/build-relevance.py`, mirrored by
their `paths-ignore`). Build also skips its macOS jobs on pull requests that
change only those paths.

### Optional: prepare the signed archive while CI validates

After pushing the complete candidate commit to `master`, run:

```bash
Scripts/release/prepare-release.sh 0.8.1
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

A dispatch always runs on `master`'s tip. If website or docs commits have
already landed after the candidate, the script can't prepare the archive or
dispatch UI Tests for it: it succeeds when the merged pull request's run covers
the candidate, and the tag run then builds the archive itself. Without that
coverage, it refuses, and the release needs a new candidate. The script also
refuses a commit that changes only `DOCS_ONLY` paths, because Build and XcodeGen
never run on one.

Build and unit execution are separate jobs in `build.yml`, sharing one compile.
The UI aggregate checks smoke, Reduce Motion, both functional shards, the
background shard, all three visual sizes and every capture. Filtered or legacy-comparison runs cannot replace
the complete UI gate. All UI execution remains on hosted runners.

On a tag push, Release requires the candidate to be the current `master` tip, or
an ancestor of it when every file `master` has changed since matches `DOCS_ONLY`.
Website and docs merges therefore don't restart a release: **tag the candidate's
exact SHA, not the tip**. The artifacts build from the candidate's own checkout,
so the later files aren't in the release. A change to anything else, a rename
from outside those paths, or a file list GitHub cuts short (300 files) refuses
the tag, and the release then needs a new candidate.

Release also verifies successful **push** runs for Build (both jobs), Lint and
XcodeGen, and a successful UI Tests run on that exact SHA, either a push run or the
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

Its visual artifacts retain all 78 cases under a separate comparison check; it
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
/tmp/LokalBot-dmg-venv/bin/python3 Scripts/release/build_release_dmg.py \
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
python3 Scripts/release/generate_appcast.py \
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

Upload the DMG under its versioned name and the appcast as release assets so the
feed at `releases/latest/download/appcast.xml` resolves:

```sh
cp build/LokalBot.dmg build/LokalBot-1.0.0-macos-arm64.dmg
git tag v1.0.0 && git push origin v1.0.0
gh release create v1.0.0 \
  build/LokalBot-1.0.0-macos-arm64.dmg \
  build/appcast.xml \
  --title "LokalBot 1.0.0" \
  --notes-file Scripts/release/release-notes/v1.0.0.md
```

CI reads `Scripts/release/release-notes/<tag>.md` when that file exists (for example
`Scripts/release/release-notes/v0.6.1.md`) and posts it as the GitHub Release body.
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

## CI release

A tag-triggered GitHub Actions workflow (`.github/workflows/release.yml`)
automates the flow above. It resolves packages, validates native vendors, and
builds an ad-hoc archive before any Developer ID identity is available. A
temporary keychain exists only while Xcode exports and seals the finished app,
then is deleted. The DMG uses a separate short-lived keychain that is deleted
immediately after `codesign`, before notarization. The workflow then notarizes
and staples, downloads the Sparkle tarball for `sign_update`, runs
`generate_appcast.py`, and uploads `LokalBot-<version>-macos-arm64.dmg` and
`appcast.xml` to the Release.
Jobs beside it build, sign and attach the Linux and Windows archives and feeds
([Linux and Windows](Docs/releasing/linux-and-windows.md)) and the Android APK
([Android](Docs/releasing/android.md)); the manual steps above cover macOS only.
Required repo secrets:

- `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `KEYCHAIN_PWD`
- `NOTARY_APPLE_ID`, `NOTARY_APPLE_TEAM_ID`, `NOTARY_APPLE_PWD`
- `SPARKLE_PRIVATE_KEY` (the base64 Ed25519 private key; written to a temp file
  and passed to `generate_appcast.py --ed-key-file`, and to
  `LinuxWindows/scripts/release-feeds.sh` for the Linux and Windows feeds)

Optional: `AUR_SSH_PRIVATE_KEY`, the AUR account's SSH key that lets the
release push the `lokalbot-bin` AUR package once the `AUR_PUBLISH` repository
variable is `true` ([AUR package](Docs/releasing/linux-and-windows.md#aur-package)).

Optional, with no secret: the `MCP_REGISTRY_PUBLISH` repository variable set to
`false` keeps stable releases out of the official MCP Registry; without it each
one is listed ([MCP Registry](Docs/releasing/mcp-registry.md)).

`ANDROID_KEYSTORE_BASE64` and `ANDROID_KEYSTORE_PASSWORD` sign the Android APK.
A release has no APK until its key is set up, and a missing secret fails the
job after that ([Android](Docs/releasing/android.md)).

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

CI passes `--repo "$GITHUB_REPOSITORY"`. `generate_appcast.py` refuses to run
without `--repo`, so a feed never points at the `OWNER/REPO` placeholder.

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
- Never lose or casually replace the Android signing key → installed copies refuse
  updates signed by another key.
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
bash Scripts/build/clean_local.sh   # removes .build, build/, *.dmg, the dmgbuild venv, and LokalBot-* DerivedData
```
