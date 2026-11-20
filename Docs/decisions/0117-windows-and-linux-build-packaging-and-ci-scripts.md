# 0117. Windows and Linux: build, packaging and CI scripts

- Status: Accepted
- Date: 2026-11-20

## Context

These decisions were recorded as comments beside the code until code stopped
carrying comments ([ADR 0001](0001-code-carries-no-comments.md)). Each entry keeps the comment's
wording under the file and symbol it concerns; the heading states the decision.

Sources: `LinuxWindows/packaging/linux/`, `LinuxWindows/scripts/`, `LinuxWindows/scripts/ci/`, `LinuxWindows/scripts/ci/runners/`, `LinuxWindows/scripts/tests/`.

## Decisions

### `LinuxWindows/packaging/linux/install.sh`

#### install.sh installs binaries, entries, icons per user; KDE input-method entry hidden from menu
Installs LokalBot for the current user from an extracted release archive:
binaries into ~/.local/bin, the desktop entries and icons into ~/.local/share.
The second entry lists LokalBot under KDE Plasma's Virtual Keyboard settings,
for autocomplete; it is not in the applications menu.
Run with --uninstall to remove them (your library is never touched).

#### Uninstall also removes agent skill and launch-at-login entry this copy set up
`install.sh uninstall`: What this copy set up outside those folders goes too, as the Windows
uninstaller removes it: the coding-agent skill from Settings → AI agents →
Agent CLI, and a launch-at-login entry that starts this copy.

### `LinuxWindows/scripts/ci/capture-linux.sh`

#### Capture setup on Xvfb with xfwm4 compositing and optional panel; page names
Captures LokalBot on a virtual X11 desktop (Xvfb, xfwm4 with compositing and,
when installed, an xfce4-panel with a task list, system tray and clock), one
PNG per page. Usage: capture-linux.sh \<lokalbot> \<library> \<out-dir> [pages...]
Pages are `--page` names: today, actions, meetings, timeline, people,
projects, ask, agent, and settings or settings-\<page> for the Settings window;
quick-recall captures the Quick Recall window over the main window.

#### ERR trap names the failing line because set -e exits silently
Under set -e a failing command would end the script without saying which.

#### Tray needs a session bus shared by panel and LokalBot
The tray needs a session bus that the panel and LokalBot share.

#### Panel reads its layout via xfconf, which follows XDG_CONFIG_HOME
The panel reads its layout through xfconf, which follows XDG_CONFIG_HOME.

#### Poll every half second up to 30 s; busy machines start slowly
`wait_for`: Runs a check every half second, for up to 30 s: on a busy machine the
desktop can take seconds to come up.

#### GPUI draws own frame only if WM lists _GTK_FRAME_EXTENTS at start
`wm_ready`: GPUI draws its own frame and shadow only if, as it starts, the window
manager lists _GTK_FRAME_EXTENTS as supported on the root window. Otherwise
xfwm4 frames the window.

#### Pointer kept off window from start; moving window later leaves stale GPUI hover
`capture-linux.sh`: Keep the pointer off the window from the start: moving the window later
leaves GPUI with a stale hover under the old pointer position.

#### Settings opens alone titled Settings; Quick Recall opens over main window
`capture-linux.sh`: Settings pages open the Settings window alone (titled "Settings" in the
English interface the captures use); Quick Recall opens its own window
over the main one; every other page is the main window.

#### Crop by X geometry minus GPUI's invisible resize border
`capture-linux.sh`: Crop to the LokalBot window using its X geometry, minus the invisible
resize border GPUI reports in _GTK_FRAME_EXTENTS (left, right, top, bottom).

#### Missing frame extents means xfwm4 framed window, so X geometry is the app
`capture-linux.sh`: Missing when xfwm4 framed the window: then the X geometry is the app.

### `LinuxWindows/scripts/ci/check-aur-package.sh`

#### AUR package check: SRCINFO, namcap, libraries, version via MCP initialize
Builds and installs the lokalbot-bin AUR package the way an AUR helper does
(makepkg -si as a regular user) in a clean archlinux container, then checks:
  - .SRCINFO matches the PKGBUILD (makepkg --printsrcinfo);
  - namcap finds no errors in the PKGBUILD or the built package;
  - lokalbot and lokalbot-cli are in /usr/bin and resolve every library
they link, and the libraries they load at run time are installed;
  - lokalbot-cli reports the PKGBUILD's pkgver (MCP initialize).

  scripts/ci/check-aur-package.sh [PKGBUILD_DIR]

PKGBUILD_DIR defaults to packaging/aur/lokalbot-bin. ENGINE: docker
(default) or podman. IMAGE: the container image (default archlinux:latest).

#### grep -q stops early and pipefail counts ldd's SIGPIPE
`check-aur-package.sh`: grep -q would stop reading early, and pipefail would count ldd's SIGPIPE.

#### Libraries loaded with dlopen are not listed by ldd
`check-aur-package.sh`: Loaded with dlopen, so ldd does not list them.

#### Neither binary has --version; MCP server reports CARGO_PKG_VERSION
`check-aur-package.sh`: Neither binary has --version; the MCP server reports CARGO_PKG_VERSION.

### `LinuxWindows/scripts/ci/check-linux-repos.sh`

#### End-to-end apt and dnf repository check with throwaway key and tamper cases
Checks LokalBot's apt and dnf repositories end to end with a throwaway key.
scripts/package-linux-distros.sh packages STAGE's binaries as four
versions, scripts/linux-repos.sh publishes them into a repository served
over HTTPS as pkg.lokalbot.com on a private Docker network, and clean
Ubuntu 24.04, Debian 13 and Fedora containers install the first version
from the downloaded file, then upgrade with `apt upgrade` and `dnf upgrade`
as later versions are published. It checks that:
  - the .deb and .rpm add the repository as config files, and an edited
repository file survives an upgrade; the Arch package adds nothing;
  - apt refuses a tampered InRelease, a tampered Release (signed by
Release.gpg) and a swapped .deb; dnf refuses a tampered repomd.xml, a
swapped .rpm and an unsigned one;
  - each repository keeps its newest three versions.

  NFPM=/path/to/nfpm scripts/ci/check-linux-repos.sh STAGE

STAGE is a staged release folder, LokalBot-\<version>-linux-x86_64 (from
scripts/package.sh, or extracted from a release's .tar.gz). Needs Docker
and nfpm (a static binary, run inside a container). Writes into dist/ and
removes its containers, network and files when it ends.

#### Refusal may be failure or skipped index, since apt keeps last good one
`refused`: Expects a client command to fail or to skip LokalBot's index (apt keeps
the last good one and warns), and shows why.

#### Test server needs HTTP/1.1 and TLS close_notify; Debian 13 apt rejects abrupt EOF
`check-linux-repos.sh`: HTTP/1.1, and TLS connections end with close_notify: Debian 13's apt
rejects a TLS stream that just stops ("unexpected eof").

#### Client run helper fails on command failure, apt errors or skipped index
`check-linux-repos.sh`: In a client: runs a command, shows its lines that match a pattern, and
fails when the command fails or apt reports an error or a skipped index.

### `LinuxWindows/scripts/ci/runners/check-runner.sh`

#### Runner check: block tailnet, per-job XDG dirs, trim warm target and caches
First step of a job on a self-hosted Linux runner (setup-linux-runner.sh):
- fails if the runner can reach the Tailscale network, which its systemd
  unit is meant to block;
- points XDG directories at this job's temp folder, so app state doesn't
  carry over between jobs the way it can't on GitHub's fresh machines;
- trims the warm target directory when it, or the disk, gets too full, and
  with --gradle (the Android runner, the only one that uses them), Gradle's
  caches when the disk does. ~/.m2 stays, since Maven Central can refuse to
  send it all again.

#### Single-instance socket in XDG_RUNTIME_DIR requires owner-private directory
`check-runner.sh`: The app's single-instance socket lives in XDG_RUNTIME_DIR, which must be
private to its owner.

### `LinuxWindows/scripts/ci/runners/setup-linux-android-sdk.sh`

#### Android runner gets its own SDK; never holds a key; release builds stay on GitHub
Gives the Linux runner from setup-linux-runner.sh what the "Companion Android"
workflow needs: an Android SDK of its own, because a job can't read anyone
else's home. Run it as a user with sudo. Running it again installs only what's
missing, and it never holds a key: release builds stay on GitHub's runners.

#### Command-line tools 20.0 match what android-emulator-runner uses
`TOOLS_BUILD`: Command-line tools 20.0, the ones android-emulator-runner uses on GitHub's runners.

#### Same SDK versions as GitHub runners; compileSdk picks platform, AGP adds build tools
`PACKAGES`: The same versions the job gets on GitHub's runners. The app's compileSdk picks
the platform, and AGP downloads the build tools it wants on top of these.

### `LinuxWindows/scripts/ci/runners/setup-linux-runner.sh`

#### Self-hosted runner setup: linux and android runners, naming, isolation, shared slice
Sets up a self-hosted GitHub Actions runner on an Ubuntu 24.04 host. Run it
as a user with sudo, with a runner registration token on stdin:

  gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
ssh HOST 'bash setup-linux-runner.sh https://github.com/OWNER/REPO [linux|android]'

"linux" (the default) is the runner for the Linux job of "Linux & Windows";
"android" is a second one beside it, for "Companion Android", so the two can
run at the same time. Give that one an SDK with setup-linux-android-sdk.sh.

The runner is named after its label (lokalbot-linux, lokalbot-android). To
add a machine beside one that already has that runner, give it a name of its
own; the label stays the same, so the picker uses whichever one is idle:

  ... | ssh HOST 'RUNNER_NAME=lokalbot-linux-pc bash setup-linux-runner.sh https://github.com/OWNER/REPO'

Registering with a name that is already taken replaces that runner.

Both run as one unprivileged user (no sudo, no docker), each under a systemd
unit that cannot reach the Tailscale network or private networks (a home LAN,
Docker bridges) and uses a private /tmp. The two units share a slice that gets
a lower CPU weight and a memory cap. See README.md.

#### capture-linux.sh starts its own Xvfb on this display
`CAPTURE_DISPLAY`: capture-linux.sh starts its own Xvfb on this display.

#### CI runs PR code, so deny Tailscale and private networks
`DENY`: CI jobs run code from pull requests. Keep them off the Tailscale network
(IPv4 CGNAT range and Tailscale's IPv6 prefix) and private networks (a home
LAN, a hypervisor's NAT, Docker bridges, link-local).

#### Network block also stops DNS via private resolvers; need local stub resolver
`setup-linux-runner.sh`: The block also stops DNS when /etc/resolv.conf names a private resolver
(WSL's 10.255.255.254, a home router), and the runner would never connect.
A local stub such as systemd-resolved (127.0.0.53) works.

#### Registration token passes through a runner-owned file, not process list
`setup-linux-runner.sh`: The token goes through a file the runner user owns, so it never shows up in
a process list.

#### Warm per-runner target dir instead of cache; write .env after config.sh rewrites .path
`setup-linux-runner.sh`: Jobs keep a warm target directory of their runner's own instead of restoring
a cache. Written after config.sh, which rewrites .path.

#### Both runners together get one runner's CPU weight plus memory cap
`SLICE`: Both runners together get the CPU weight one runner had alone, and a memory cap.

### `LinuxWindows/scripts/ci/update-e2e.sh`

#### Update e2e: dry-run feed on loopback, throwaway key, same archive pretends 0.0.1
End-to-end update from a dry-run feed on this computer. Installs the packaged
archive the way a user does (install.sh into a scratch home), serves an
update over plain HTTP on 127.0.0.1 signed with a throwaway key, and has the
installed LokalBot check, download, verify, install and relaunch itself.

  update-e2e.sh \<installed-archive> \<update-archive> \<lokalbot-update-feed> \<work-dir>

The two archives may be the same file: the installed copy then pretends to
be 0.0.1 (LOKALBOT_UPDATE_CURRENT_VERSION), which the relaunched copy does
not inherit. Needs python3, openssl, and DISPLAY or Xvfb (on a free display
number). Never touches the real home folder or library, and stops only the
LokalBot it installed.

#### LokalBot reads feed at startup so wait for the server first
`update-e2e.sh`: LokalBot reads the feed as soon as it starts; wait until the server answers.

#### install-update is the command form of Install and Relaunch
`update-e2e.sh`: `install-update` is the command form of Install and Relaunch.

### `LinuxWindows/scripts/linux-repos.sh`

#### Repository layout, signing, never overwrite published versions, keep newest KEEP, verify with public key
Adds Linux packages to LokalBot's apt and dnf repositories and signs them.
.github/workflows/linux-repos.yml publishes the tree at https://pkg.lokalbot.com:
  apt/           suite stable, component main, amd64: pool/main/l/lokalbot/
and dists/stable/ with InRelease, Release and Release.gpg
(apt-ftparchive, SHA-256 only, indexes also by hash)
  rpm/           the RPMs, each signed with rpmsign, and repodata/
(createrepo_c) with repomd.xml.asc
  lokalbot.asc   the public key, and lokalbot.gpg, the same key unarmored

  scripts/linux-repos.sh REPO KEY [PACKAGE.deb|PACKAGE.rpm ...]

REPO holds the published packages (copied from the bucket, or empty for a
new repository) and receives the new tree. KEY is the signing key's
fingerprint; GNUPGHOME has its secret key. A package whose version is
already published is left out: a published version's bytes never change.
Each repository then keeps its newest KEEP (default 3) versions, and every
index is rebuilt, signed and checked against the public key. With no
packages, the indexes are only rebuilt and signed again.

PUBLIC_KEY: the armored public keyring to publish (default: KEY's public
key). It must contain KEY.

Needs apt-ftparchive (apt-utils), dpkg-deb, createrepo_c, rpm, rpmsign and
gpg, as on Ubuntu 24.04.

#### Ubuntu rpm looks for gpg2, which it no longer ships
`linux-repos.sh`: Ubuntu's rpm looks for gpg as gpg2, which it no longer ships.

#### apt indexes listed by SHA-256 and stored by hash so caches never mismatch
`linux-repos.sh`: apt: one index, listed in Release by SHA-256 and also stored under its hash
(Acquire-By-Hash), so a cached or half-uploaded index never mismatches.

### `LinuxWindows/scripts/package-linux-distros.sh`

#### Packages install to /usr/bin; LokalBot suggests commands instead of replacing package files
Builds Linux distribution packages from the folder scripts/package.sh staged
in dist/, with nfpm (https://nfpm.goreleaser.com):
  dist/LokalBot-\<version>-linux-amd64.deb          Debian, Ubuntu
  dist/LokalBot-\<version>-linux-x86_64.rpm         Fedora, openSUSE, RHEL
  dist/LokalBot-\<version>-linux-x86_64.pkg.tar.zst Arch
Run scripts/package.sh first.

NFPM: the nfpm binary to use (default: nfpm on PATH).
PACKAGE_VERSION, STAGE, LINUX_REPO_PUBLIC_KEY: another version, staged
folder or repository key, for scripts/ci/check-linux-repos.sh.

The packages install lokalbot and lokalbot-cli into /usr/bin, the desktop
entry and icons into /usr/share. LokalBot does not replace a package's
files. It finds the package that owns it, and for one named lokalbot (these
packages, lokalbot-update's package::RELEASE_PACKAGE) shows the command that
installs the new package; the file names below are in that command too.
Once the repository key is in packaging/linux, the .deb and .rpm also add
the apt and dnf repositories at pkg.lokalbot.com (scripts/linux-repos.sh)
with that key, so later versions come with `apt upgrade` and `dnf upgrade`,
which LokalBot then suggests (package::repository_file).

#### Repository files are config files so edits survive upgrades
`package-linux-distros.sh`: The repository files are config files: an edited copy survives upgrades.

#### Dependency rationale: glibc 2.39, libgomp, Arch meta packages, suggested tools
`package-linux-distros.sh`: The binaries need glibc 2.39 (built on Ubuntu 24.04). The app links ALSA,
xcb and xkbcommon and loads Vulkan and the Wayland client at run time.
The llama.cpp runtime it downloads (llama-server) links the GCC OpenMP
runtime, libgomp.so.1, which minimal installs lack.
Arch's gcc-libs is a meta package of every GCC runtime; namcap asks for
libgcc and libstdc++, and for hicolor-icon-theme, which owns the icon folders.
System audio uses PulseAudio or PipeWire's PulseAudio server; the
suggested tools enable typing and screenshots on some desktops. Tesseract
reads screen text in scripts other than Latin; without it, ocrs reads Latin.

### `LinuxWindows/scripts/package.sh`

#### Release packaging outputs per platform; VC_REDIST_DIR overrides runtime source
Builds release binaries and packs them for the current platform into dist/.
Linux: LokalBot-\<version>-linux-x86_64.tar.gz (with install.sh)
Windows (Git Bash or CI): LokalBot-\<version>-windows-x86_64.zip

VC_REDIST_DIR (Windows): a Microsoft.VC14x.CRT folder to take the Visual C++
runtime from, instead of the newest Visual Studio with the C++ build tools.

#### Self-hosted CI runners keep a warm target directory elsewhere
`TARGET`: Self-hosted CI runners keep a warm target directory elsewhere.

#### Ship third-party notices and all named license texts with binaries
`package.sh`: The third-party notices and every license text they name (including
LICENSES/rust-crates.md, the statically linked crates) ship with the
binaries.

#### Ship build machine's VC++ runtime because llama.cpp Windows builds import it
`package.sh`: llama.cpp's Windows builds import the Visual C++ runtime, which Windows
lacks until something installs the Visual C++ Redistributable. Ship the
build machine's copy, unmodified (Distributable Code under the Visual
Studio license terms); LokalBot copies it beside each llama-server.exe
(lokalbot-ai's runtime.rs).

### `LinuxWindows/scripts/release-feeds.sh`

#### Sign archives with Sparkle key, write feeds, refuse key not matching app, never print key
Signs the Linux and Windows release archives in DIST with Sparkle's Ed25519
key and writes the update feeds linux-x86_64.json and windows-x86_64.json
next to them, then checks each feed against the archive.

  scripts/release-feeds.sh DIST TAG KEY_FILE [EXPECTED_PUBLIC_KEY]

KEY_FILE holds Sparkle's base64 private key: the SPARKLE_PRIVATE_KEY secret
for a release, or a throwaway key for a dry run. With EXPECTED_PUBLIC_KEY
(the app's SUPublicEDKey) a key that does not belong to it is refused before
anything is signed. The key is never printed.

FEED_TOOL: an already built lokalbot-update-feed (the release builds it
before the key exists). DOWNLOAD_BASE: where the feeds point instead of the
tag's release assets (a dry run serves them locally). MINIMUM_VERSION: the
oldest installed version that may install the update itself (default: any).

### `LinuxWindows/scripts/sync-localizations.py`

#### Strip invisible characters from translation tools; clippy denies them in Rust
`INVISIBLE`: Zero-width space, soft hyphen and word joiner: invisible, usually left by a
translation tool, and denied by clippy in the generated Rust.

#### JSON escapes differ from Rust's; keep non-ASCII literal except invisibles
`rust_string`: JSON's Unicode escapes differ from Rust's. Keep non-ASCII text literal,
except invisible characters, which Rust gets as escapes.

#### Python code point order equals Rust UTF-8 byte order
`generate`: Python orders str by code point, which is Rust's UTF-8 byte order.

### `LinuxWindows/scripts/tests/test_localizations.py`

#### Scan every crate; core or engine errors show as-is and need entries
`source_keys`: Every crate: an error from core or the engine is shown as it is, and a key
with no entry would stay in English in every language.

#### mac() fills a macOS catalog entry's %@ fields after lookup
`source_keys`: `mac(…)` fills a macOS catalog entry's %@ fields after looking it up.

#### personal/mod.rs declares tests near top; its messages follow
`test_only_test_items_are_skipped`: personal/mod.rs declares its tests near the top; its messages follow.

#### Clippy denies literal zero-width space, soft hyphen, word joiner
`test_invisible_characters_never_reach_the_rust_catalog`: Clippy denies a literal zero-width space, soft hyphen or word joiner.

### `LinuxWindows/scripts/third-party-licenses.sh`

#### Generate Rust crate licenses via pinned cargo-about; run after Cargo.lock changes
Writes ../LICENSES/rust-crates.md: every Rust crate compiled into the Linux
and Windows app, the license it is used under, and that license's text as
the crate ships it. cargo-about reads Cargo.lock and the crates' sources;
about.toml and about.hbs hold its configuration and template.

  scripts/third-party-licenses.sh          rewrite the file
  scripts/third-party-licenses.sh --check  fail if the file is out of date

Run it after changing Cargo.lock. It downloads the pinned cargo-about
(checked by SHA-256) into the target directory on first use; CARGO_ABOUT
names another binary of the same version.

#### Use --offline so license text is identical on every machine
`third-party-licenses.sh`: --offline keeps the output the same on every machine: license text comes
only from the downloaded crates, never from their git repositories.

#### Some crates ship CRLF licenses; Git stores LF so strip CR
`third-party-licenses.sh`: Some crates ship their license with Windows line endings; Git stores LF.

### `LinuxWindows/scripts/update-aur.sh`

#### Point AUR package at a release; pkgrel handling; SRCINFO via makepkg or container
Points the lokalbot-bin AUR package (packaging/aur/lokalbot-bin) at a
release: sets pkgver, takes the SHA-256 GitHub reports for the Linux archive
(with gh), and regenerates .SRCINFO. A new version resets pkgrel to 1;
the same version keeps it unless PKGREL is given (a packaging-only fix).

  scripts/update-aur.sh 0.11.1       # or v0.11.1
  scripts/update-aur.sh 0.11.1 2     # PKGREL 2 for the same release

.SRCINFO comes from makepkg --printsrcinfo. Where there is no makepkg
(macOS, Ubuntu), it runs in an archlinux container with docker or podman.

REPOSITORY: the GitHub repository with the release (default
stevyhacker/LokalBot). SHA256: use this checksum instead of asking GitHub.

#### pkgver cannot hold a hyphen; pre-releases stay off the AUR
`update-aur.sh`: pkgver cannot hold a hyphen, and pre-releases stay off the AUR.

#### makepkg refuses root; container build and output folders move to /tmp
`update-aur.sh`: makepkg refuses to run as root. In the container its user cannot write the
mounted folder, so its build and output folders move to /tmp.

### `LinuxWindows/scripts/verify-gpui-provenance.sh`

#### Compare gpui-pre crates with Zed source at declared commit
Compares the published gpui-pre crates that GPUI Kit pins against Zed's own
source at the commit each crate declares (`package.metadata.gpui-pre.zed-rev`).
Prints every file that differs. Expected differences are listed in
docs/dependency-provenance.md.

#### Most crates are crates/\<name>; derive_refineable lives inside refineable
`verify-gpui-provenance.sh`: Most crates are crates/\<name>; derive_refineable is inside crates/refineable.

## Consequences

Changing one of these decisions means changing its entry here in the same pull
request, and a new decision for this area is added under its file.
