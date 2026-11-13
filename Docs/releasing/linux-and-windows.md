# Linux and Windows

Part of the [release runbook](../../RELEASING.md).

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
| `LokalBot-<version>-linux-x86_64.tar.gz` | Linux archive with `install.sh` |
| `LokalBot-<version>-windows-x86_64.zip` | Windows archive |
| `LokalBot-<version>-windows-x86_64-setup.exe` | per-user Windows installer of the same files (`scripts/package-windows-installer.ps1`, Inno Setup 6): `%LOCALAPPDATA%\Programs\LokalBot`, a Start menu shortcut with the notification app id, and an Installed apps entry, without administrator rights. The release installs and uninstalls it on the Windows runner. Updates replace the files in place from the zip and then write the new version into that Installed apps entry, which winget reads (`lokalbot_update::installed_apps`) |
| `LokalBot-<version>-linux-amd64.deb`, `LokalBot-<version>-linux-x86_64.rpm`, `LokalBot-<version>-linux-x86_64.pkg.tar.zst` | Debian/Ubuntu, Fedora/openSUSE and Arch packages of the same binaries (`scripts/package-linux-distros.sh`, nfpm). The release checks each one installs in a clean Ubuntu 24.04, Fedora 41 and Arch container. They install into `/usr/bin`, so LokalBot announces updates for them instead of replacing its files; it recognizes them by the package name `lokalbot`. A `.deb` or `.rpm` that added the LokalBot repository ([Linux package repositories](linux-package-repos.md)) is told to run `sudo apt upgrade` or `sudo dnf upgrade`; the others get the command that installs the new package |
| `linux-x86_64.json`, `windows-x86_64.json` | update feeds |

Releases attach no separate checksum files. GitHub shows each file's SHA-256 on
the release page and returns it as `digest` in the API, and the release jobs and
the Homebrew tap read it there.

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

## Third-party licenses

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

The generated list covers the Linux and Windows targets. The Mac app and the
phone apps compile `lokalbot-sync` for Apple and Android targets, where a
dependency can bring in a crate the list lacks. The same workflow runs
`Scripts/ci/check-sync-crate-notices.py`, which fails until such a crate is
named, with its version, in the companion section of `THIRD_PARTY_NOTICES.md`.

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

## Dry run

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

## Checks after publishing

```sh
cd LinuxWindows
cargo run --release -p lokalbot-update --no-default-features --bin lokalbot-update-feed -- \
  verify --feed linux-x86_64.json --archive LokalBot-1.0.0-linux-x86_64.tar.gz
```

`verify` uses the embedded `SUPublicEDKey` unless `--public-key` is given.

## Rollback

Like Sparkle, installed copies follow the feeds of the Latest release. To stop
an update, re-upload the previous release's `linux-x86_64.json` and
`windows-x86_64.json` to the Latest release (or mark an older release Latest).

## AUR package

After the publish job, the `aur` job (`.github/workflows/aur.yml`) points the
`lokalbot-bin` AUR package (`LinuxWindows/packaging/aur`) at the stable tag's
Linux archive and the SHA-256 GitHub reports for it, builds and installs it in
a clean Arch container with namcap, and pushes `PKGBUILD` and `.SRCINFO` to
aur.archlinux.org with the `AUR_SSH_PRIVATE_KEY` secret. It pushes only while
the `AUR_PUBLISH` repository variable is `true` (set it once an AUR account holds
the key); without the variable or the secret it stops after the checks, and
pre-release tags skip it. To publish again from
master: `gh workflow run aur.yml -f tag=vX.Y.Z`. Setup, manual updates and the
expected namcap warnings are in
[the AUR package README](../../LinuxWindows/packaging/aur/README.md).

## winget

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
[LinuxWindows/packaging/winget/README.md](../../LinuxWindows/packaging/winget/README.md).
