# 0116. Windows and Linux: update

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/crates/lokalbot-update/src/bin/`, `LinuxWindows/crates/lokalbot-update/src/client.rs`, `LinuxWindows/crates/lokalbot-update/src/feed.rs`, `LinuxWindows/crates/lokalbot-update/src/install.rs`, `LinuxWindows/crates/lokalbot-update/src/installed_apps.rs`, `LinuxWindows/crates/lokalbot-update/src/lib.rs`, `LinuxWindows/crates/lokalbot-update/src/package.rs`, `LinuxWindows/crates/lokalbot-update/src/signature.rs`, `LinuxWindows/crates/lokalbot-update/src/version.rs`.

## Decisions

### `LinuxWindows/crates/lokalbot-update/src/bin/lokalbot-update-feed.rs`

#### Release tool signs archives and writes feed; private key read from file, never printed
Release tool: signs a Linux or Windows archive with the Sparkle key and
writes its update feed, or checks a feed and archive against a public key.
The release workflow builds it with `--no-default-features`.

```text
lokalbot-update-feed sign --archive DIST/LokalBot-0.10.11-linux-x86_64.tar.gz \
    --platform linux-x86_64 --version 0.10.11 --tag v0.10.11 --key-file KEY \
    [--expect-public-key BASE64] [--minimum-version 0.10.10] [--repo owner/name] \
    [--download-base URL] [--notes-url URL] --output linux-x86_64.json
lokalbot-update-feed verify --feed linux-x86_64.json --archive FILE [--public-key BASE64]
lokalbot-update-feed public-key --key-file KEY
```

The private key is read from a file and never printed.

### `LinuxWindows/crates/lokalbot-update/src/client.rs`

#### Feed URL and key env vars are for dry runs only
`FEED_URL_ENV`: Dry runs only: a feed on this computer, and the key that signed it.

#### Dry-run override pretends to be older; relaunched copy reports real version
`CURRENT_VERSION_ENV`: Dry runs only: treat this process as an older version. The relaunched
copy reports its real version.

#### False when this copy is below the feed's minimum version
`Release.installable`: False when this copy is older than the feed's minimum version.

#### Plain HTTP is allowed only for a dry-run feed on this computer
`Updater.allow_loopback_http`: A dry-run feed on this computer may use plain HTTP.

#### No updater in debug builds without dry-run feed or on unsupported platforms
`Updater.for_this_build`: The updater for this build, downloading into `work_dir`. `None` in
debug builds (unless a dry-run feed is set) and on platforms without
published archives.

#### Key and version overrides apply only to feeds on this computer
`Updater.configure`: A different key or version is only for testing against a feed on
this computer, never one from the network.

#### Allow five redirects for GitHub's download host; none for local dry-run servers
`Updater.check`: GitHub redirects twice to its download host; a dry-run
server on this computer has no reason to redirect at all.

#### Verify size, SHA-256 and signature before unpacking
`Updater.prepare`: Downloads the release's archive, checks its size, SHA-256 and
signature, and only then unpacks it. Returns the unpacked
`LokalBot-<version>-<platform>` folder. Blocking.

#### Signed archive names its version so a feed cannot relabel older archives
`Updater.prepare`: The signed archive names its version: a feed cannot relabel an
older signed archive as this release.

#### Size and digest are updated to match so only the signature catches tampering
`rejects_a_tampered_archive_before_unpacking`: The file served is not the one that was signed; size and digest
are updated to match it, so only the signature can catch it.

### `LinuxWindows/crates/lokalbot-update/src/feed.rs`

#### Update feed format, minimumVersion meaning, signature covers archive naming its version
The per-platform update feed (`linux-x86_64.json`, `windows-x86_64.json`),
the counterpart of Sparkle's `appcast.xml`. Each release attaches one per
platform; installed copies read the one attached to the latest release.

```json
{
  "platform": "linux-x86_64",
  "version": "0.10.11",
  "minimumVersion": "0.10.10",
  "url": "https://github.com/stevyhacker/lokalbot/releases/download/v0.10.11/LokalBot-0.10.11-linux-x86_64.tar.gz",
  "size": 41234567,
  "sha256": "…64 hex digits…",
  "signature": "…base64 Ed25519 signature of the archive bytes…",
  "releaseNotesUrl": "https://github.com/stevyhacker/lokalbot/releases/tag/v0.10.11"
}
```

`minimumVersion` is the oldest installed version that may install this
update itself (Sparkle's `minimumAutoupdateVersion`); older copies are
sent to the release page instead. The signature covers the archive, and
the archive's top folder names its version, so a feed cannot pass an old
signed archive off as a newer one.

#### Feeds are small; larger than 64 KiB is not a feed
`MAX_FEED_BYTES`: Feeds are small; anything larger is not a feed.

#### Archives are tens of megabytes; 1 GiB cap
`MAX_ARCHIVE_BYTES`: Archives are tens of megabytes.

#### installable is false below feed minimum version; replace by hand
`Offer::Newer`: `installable` is false when this copy is older than the feed's
minimum version and must be replaced by hand.

#### Plain http accepted only for loopback dry-run feeds
`Feed::parse`: Parses and validates a feed for `platform`. Plain `http://` URLs are
accepted only when `allow_loopback_http` is set and they stay on this
computer (a dry-run feed).

#### Call only on a parsed feed; version is pre-validated
`Feed::version`: The validated version. Call only on a parsed feed.

#### Archive top folder is LokalBot-\<version>-\<platform>
`Feed::folder_name`: `LokalBot-0.10.11-linux-x86_64`: the archive's top folder.

#### Archive name is folder name plus tar.gz, or zip on Windows
`Feed::archive_name`: `LokalBot-0.10.11-linux-x86_64.tar.gz` (`.zip` on Windows).

#### HTTPS anywhere, plain HTTP only to this computer for dry runs
`allowed_url`: HTTPS anywhere, or plain HTTP to this computer for a dry run.

### `LinuxWindows/crates/lokalbot-update/src/install.rs`

#### Stage files beside targets, rename; Windows renames running exes to .old; roll back on failure
Putting a verified, unpacked update in place of the running copy.

Every new file is first copied next to the file it replaces, so the final
step is a rename within one folder. Linux renames over the old file; the
running processes keep the old inode. Windows cannot replace a running
executable but can rename it, so `lokalbot.exe` and `lokalbot-cli.exe`
(which a coding agent may hold open as its MCP server) become `.old`
files that the next start deletes. A failure part-way restores every file
already replaced.

#### Relaunched copy waits for old one to release the library
`AFTER_UPDATE_ARG`: The relaunched copy waits for the old one to release the library.

#### Matches install.sh's desktop entry and icon name
`APP_ID`: install.sh's desktop entry and icon name.

#### Must match lokalbot-ai runtime.rs, which copies the VC runtime beside llama-server
`VC_RUNTIME_DIR`: The Windows archive's Visual C++ runtime, which lokalbot-ai's runtime.rs
(`VC_RUNTIME_DIR`) copies beside llama-server.exe.

#### Both swap styles tested on every platform; build uses NATIVE
`SwapStyle`: How the files are swapped. Both are tested on every platform; the running
build uses [`SwapStyle::NATIVE`].

#### Unix swap keeps a hard link to old file, renames new over it
`SwapStyle::Unix`: Keep a hard link to the old file, then rename the new one over it.

#### Windows swap renames old file aside, then renames new into place
`SwapStyle::Windows`: Rename the old file aside, then rename the new one into its place.

#### Package, system folder, sandbox or source build owns files; show how to update instead
`Placement::Managed`: A package manager, a system folder (`/usr`, `/opt`, Program Files),
a sandbox or a source build owns the files: say how to update
instead ([`crate::package`] tells package installs apart).

#### Strip Windows verbatim path prefix so paths show and compare as typed
`dunce`: Windows' canonical paths start with `\\?\`; show and compare them as typed.

#### A cargo target folder is a developer's release build, treated as managed
`is_managed`: A cargo target folder: a developer's release build.

#### AppImage, Snap and Flatpak run from read-only images, so managed
`is_managed`: AppImage, Snap and Flatpak run from read-only images.

#### Windows CLI copy from install-skill runs as agents' MCP server; replace if present
`Targets::cli_copy`: `lokalbot-cli install-skill`'s copy on Windows,
`%LOCALAPPDATA%\Programs\LokalBot\bin\lokalbot-cli.exe`, which coding
agents run as their MCP server. Replaced when it exists.

#### XDG data folder entries and icons refreshed when the application entry starts this installation
`Targets::data_dir`: The XDG data folder holding install.sh's desktop entries and icons.
They are refreshed when the application entry starts this installation.

#### Windows error code meaning another handle blocks the rename
`ERROR_SHARING_VIOLATION`: Windows' answer when another handle doesn't allow the rename.

#### Old file kept until every replacement succeeded
`Replacement::backup`: The old file, kept until every replacement succeeded.

#### Files replaced, in order; nothing replaced unless every file could be staged
`install`: Replaces the installed files with the unpacked update in `staged` (the
archive's `LokalBot-<version>-<platform>` folder): both binaries, the
Windows CLI copy, files the archive folder also holds (licenses, notices,
when LokalBot runs from an extracted archive or the installer's folder),
license texts the update adds to that folder's `LICENSES`, the Visual C++
runtime, then install.sh's desktop entries and icons. Nothing is replaced
unless every file could be staged.

#### Running Windows executables keep old file; next start deletes it
`install`: Running executables keep their old file on Windows; the next start
deletes it (`remove_leftovers`).

#### Symlinked CLI from install-skill is not this installation's file; skip it
`plan`: install-skill may have linked the CLI from elsewhere; a link is
not this installation's file.

#### Existing LICENSES folder also gets license texts the update adds
`plan`: A LICENSES folder already in place also gets the license texts the
update adds, so the notices it ships stay complete.

#### Older installations get the VC++ runtime too; llama.cpp runtimes need it
`plan`: Installations from before the Windows archive carried the Visual
C++ runtime get it too; their llama.cpp runtimes need it.

#### VC++ runtime folder may be new to an installation, so create it
`stage`: The Visual C++ runtime can be new to an installation, folder and all.

#### Windows flushes only through a handle opened for writing
`stage`: Windows flushes only through a handle that may write.

#### Backup is a free .old name, numbered while older ones are in use
`backup_path`: A free `<name>.old` (or `<name>.<n>.old` while an older one is still in use).

#### On failed rename Unix target is still old; hard-link rename would no-op
`swap`: The target was not replaced. On Unix it is still the old file (and
renaming a hard link onto its twin would do nothing).

#### Retry rename on Windows while antivirus or version readers briefly hold the file
`rename_when_free`: Renames, waiting while something on Windows holds the file for a moment.
Antivirus does after a new file, and so does anything reading a running
executable's version details, as LokalBot does to name the focused app.

#### On Windows the new file is not running yet, so it can be removed
`restore`: The new file is not running yet, so it can be removed.

#### remove_leftovers skips folders mid-install; it once deleted a live .new file
`REPLACING`: Folders an [`install`] in this process is replacing files in right now.
[`remove_leftovers`], which the app runs 0, 10 and 60 seconds after it
starts, skips them: it used to delete the `.new` file of an install under
way (an update started at launch on a slow machine), and the rename then
failed with "No such file or directory".

#### Registering waits for any cleanup pass running in these folders
`Replacing::new`: Waits for a cleanup pass that is going on in these folders.

#### Leftovers live in installation folder and Windows CLI copy folder
`leftover_dirs`: Where an update leaves `.old` and `.new` binaries: the installation's
folder and the Windows CLI copy's.

#### Running leftovers stay until next time; folders mid-install are skipped
`remove_leftovers`: Deletes `.old` and `.new` binaries an earlier update left in `dir` (and
next to the Windows CLI copy). Ones still running stay until next time, and
so does a folder an install in this process is replacing files in.

#### Lock held for whole pass so no install starts halfway
`remove_leftovers`: Held for the whole pass, so no install starts in these folders halfway.

#### Rewrite desktop entries and icons only when entry starts this install; failures only log
`refresh_desktop_entry`: Rewrites install.sh's desktop entries (the application's, and the one that
lists LokalBot under KDE Plasma's Virtual Keyboard settings) and icons from
the update when the application entry starts this installation. Failures
only log: the binaries are already in place.

#### Exec rewrite must match install.sh's sed substitution
`refresh_desktop_entry`: install.sh: sed "s|^Exec=lokalbot|Exec=$BIN/lokalbot|"

#### Input-method entry added whenever archive has it, as install.sh does
`refresh_desktop_entry`: install.sh installs the input-method entry whenever the archive
has one, so an update from a release without it adds it too.

#### Relaunch detached with after-update arg; strip process-specific env vars
`relaunch`: Starts the updated LokalBot detached from this process, with `args`
after [`AFTER_UPDATE_ARG`] so it waits for this copy to exit and release
the library. `remove_env` names variables that describe only this process.

#### Test adds KDE input-method entry the installed release lacked
`tests::refreshes_install_sh_desktop_entry_and_icons`: The entry for KDE Plasma's Virtual Keyboard settings, which the
installed release did not have yet.

#### Root can write anywhere, so NotWritable check only applies to normal users
`tests`: Root can write anywhere; the check only means something for users.

#### Regression: real Windows e2e update failed when lokalbot.exe was briefly held
`tests::windows_waits_for_a_file_held_for_a_moment`: The update's end-to-end check failed this way on a real Windows desktop:
`lokalbot.exe` was held for a moment, and the whole update gave up.

#### Running CLI as MCP server is replaced by rename; delete waits for exit
`tests::windows_replaces_a_running_cli`: The real Windows case: the CLI is running (as an MCP server would be)
while the update replaces it. Renaming works; deleting the old file
waits until the process exits.

#### Windows releases the image shortly after process exit
`tests::windows_replaces_a_running_cli`: The image is released shortly after exit.

### `LinuxWindows/crates/lokalbot-update/src/installed_apps.rs`

#### Self-updates bypass installer, so Installed apps version is updated only for existing matching entry
The entry the per-user installer (`packaging/windows/lokalbot.iss`) adds to
Windows' Installed apps. An update LokalBot installs itself bypasses the
installer, so the entry would keep showing the installer's version.
[`record_version`] brings it up to date, but only in an entry that already
exists under HKEY_CURRENT_USER and names this installation's folder: a copy
run from an extracted archive never gains one.

#### Inno Setup uninstall key for the app ID, under HKEY_CURRENT_USER
`UNINSTALL_KEY`: Inno Setup's uninstall key for [`APP_ID`], under HKEY_CURRENT_USER.

#### Display string matches how Inno Setup writes AppVersion
`display_version`: The string Installed apps shows, as Inno Setup writes `AppVersion`.

#### DWORD version values Inno Setup writes beside DisplayVersion
`version_numbers`: The DWORDs Inno Setup writes next to `DisplayVersion`.

#### InstallLocation ends in backslash; Windows paths compare case-insensitively
`names_dir`: Whether `install_location` (`InstallLocation`, which ends in a backslash)
names `dir`. Windows compares paths without regard to case.

#### Update only existing installer entry; extracted archive or Linux writes nothing
`record_version`: Sets the installer's Installed apps entry to `version` when it describes
the installation in `dir`. Returns whether anything changed; with no such
entry (an extracted archive, Linux) nothing is written.

#### Closes the registry handle returned by RegOpenKeyExW exactly once
`Key::drop`: SAFETY: closes the handle `RegOpenKeyExW` returned, once.

#### Opens existing key only, None when missing; never creates one
`Key::open`: An existing key; `None` when there is none. Never creates one.

#### Subkey is NUL-terminated and handle receives the key
`Key::open`: SAFETY: `subkey` is NUL-terminated and `handle` receives the key.

#### First call sizes the buffer in bytes; second fills it
`Key::string`: SAFETY: the first call asks for the size in bytes; the second
fills a buffer of at least that size.

#### With no buffer, only checks that a DWORD value exists
`Key::has_dword`: SAFETY: with no buffer, only checks that a DWORD value exists.

#### Data pointer is valid for the length passed
`Key::set`: SAFETY: `data` is valid for the length passed.

#### Creates key if needed; writes NUL-terminated UTF-16 sized in bytes
`tests::Scratch::set_string`: SAFETY: creates the key if needed and writes a
NUL-terminated UTF-16 string of the size passed in bytes.

#### Deletes a test-created key; missing key is fine
`tests::Scratch::drop_tree`: SAFETY: deletes a key this test created; a missing key is fine.

#### Inno Setup writes literal brace as doubled brace in AppId
`tests::the_key_matches_the_installers_app_id`: Inno Setup writes a literal `{` as `{{`.

### `LinuxWindows/crates/lokalbot-update/src/lib.rs`

#### Update flow: feed, download, size, SHA-256, Ed25519 check with Sparkle key, unpack, swap
Signed automatic updates for LokalBot on Linux and Windows, the
counterpart of Sparkle in `AppUpdateManager.swift`.

Each GitHub release attaches the Linux and Windows archives and one feed
per platform ([`feed`]). A copy reads the latest release's feed, and when
the user chooses to install, downloads the archive, checks its size,
SHA-256 and the Ed25519 signature made with the macOS app's Sparkle key
([`signature`]), unpacks it, and swaps the files ([`install`]). On
Windows the installer's Installed apps entry then shows the new version
([`installed_apps`]).

#### Latest release assets resolve here, like Sparkle's SUFeedURL
`FEED_BASE_URL`: Where the latest release's assets resolve, like Sparkle's `SUFeedURL`.

#### Must equal SUPublicEDKey in Info.plist; release-preflight fails on mismatch
`PUBLIC_KEY`: `SUPublicEDKey` in `LokalBot/Info.plist`; `Scripts/release/release-preflight.py`
fails when the two differ.

### `LinuxWindows/crates/lokalbot-update/src/package.rs`

#### Find owning package via pacman, dpkg-query, rpm; unlisted copies get no answer
The package that installed this copy, so an update it cannot install
itself is offered the way that package updates.

The package databases answer directly: `pacman -Qqo`, `dpkg-query -S`
and `rpm -qf` on the executable. A copy no package lists (install.sh, an
extracted archive, a folder under `/opt`) gets no answer. Linux only.

#### Release packages install from downloaded file; repository added once key committed
`RELEASE_PACKAGE`: The name of the release's own `.deb`, `.rpm` and Arch packages
(`scripts/package-linux-distros.sh`). They are installed from a
downloaded file. Once the repository key is committed, the `.deb` and
`.rpm` also add LokalBot's apt or dnf repository ([`repository_file`]),
and from then on the package manager fetches the next version; the Arch
package never has one. Other names, such as the AUR's `lokalbot-bin`,
come from a repository.

#### Release package with no repository is updated from a downloaded file
`Package::from_release`: One of the release's own packages with no repository to update it:
installed from a downloaded file, so the next one is too.

#### Arch users run an AUR helper; yay also updates repository packages
`Package::update_command`: Arch users run an AUR helper; yay also updates repository packages.

#### Downloaded file names must match package-linux-distros.sh
`Package::install_command`: Installs `version`'s release package of this format, downloaded into
the current folder. The file names are package-linux-distros.sh's.

#### Repository file path installed by the release deb or rpm
`repository_file`: The repository file the release's `.deb` (deb822) or `.rpm` installs
for LokalBot's apt or dnf repository (`packaging/linux`).

#### Spawns package tools and reads files, so call off the UI thread
`owner`: The package that installed `executable`, or `None` when no package
database lists it. Starts the package tools and reads the repository
file, so call it off the UI thread.

#### Other distros' tools may exist; only the database listing the file answers
`owner_with`: A system can have another distribution's tools (dpkg on Arch, to build
.debs); only the database that lists the file answers.

#### dpkg-query output shapes, including diversion lines and multiple packages
`parse`: `lokalbot: /usr/bin/lokalbot`, `libc6:amd64: /usr/lib/…` or
`a, b: /path`, after any `diversion by …` lines.

### `LinuxWindows/crates/lokalbot-update/src/signature.rs`

#### Sparkle-compatible signatures; two private key forms sign identically
Sparkle-compatible Ed25519 signatures over the update archive's bytes.

The macOS app's `SUPublicEDKey` verifies these, and the release signs
them with the same `SPARKLE_PRIVATE_KEY` that `sign_update` uses for the
DMG. Sparkle's private key is base64 text in one of two forms
(`common_cli/Secret.swift`): a 32-byte seed, or, for keys made by older
Sparkle releases, the 64-byte orlp expanded secret key followed by the
32-byte public key. Both sign identically.

#### Error never echoes key text, which may be the secret
`SignatureError::InvalidPrivateKey`: Never echoes the key text, which may be the secret itself.

#### Embedded key is SUPublicEDKey from Info.plist
`PublicKey::embedded`: `SUPublicEDKey` from `LokalBot/Info.plist`.

#### Strict verification rejects small-order keys and non-canonical signatures
`PublicKey::verify`: Checks `signature` (base64) over `message`. Strict verification
rejects small-order keys and non-canonical signatures.

#### Release key held only by the release tool and tests
`SecretKey`: The release key. Only the release tool and tests hold one.

#### Stored public half must match secret half or all signatures fail
`SecretKey::from_sparkle`: The stored public half must belong to the secret half, or
every signature would fail to verify.

#### Throwaway test seeds, never the release key
`tests::SEED`: Throwaway seeds for tests only; never the release key.

#### Older Sparkle format: orlp expanded key followed by public key
`tests::legacy_key`: Sparkle's older format: orlp's expanded key (clamped SHA-512 of the
seed) followed by the public key.

### `LinuxWindows/crates/lokalbot-update/src/version.rs`

#### Versions are the macOS marketing version, repeated by workspace so one tag ships all platforms
Release versions: the macOS marketing version (`0.10.11`), which the Linux
and Windows workspace repeats so one tag ships all three platforms.

#### Exactly three decimal numbers; pre-release tags never reach a feed
`Version::from_str`: Exactly three decimal numbers, as `release-preflight.py` requires of
the marketing version. Pre-release tags never reach a feed.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
