#!/usr/bin/env bash
# Builds Linux distribution packages from the folder scripts/package.sh staged
# in dist/, with nfpm (https://nfpm.goreleaser.com):
#   dist/LokalBot-<version>-linux-amd64.deb          Debian, Ubuntu
#   dist/LokalBot-<version>-linux-x86_64.rpm         Fedora, openSUSE, RHEL
#   dist/LokalBot-<version>-linux-x86_64.pkg.tar.zst Arch
# each with a .sha256 file. Run scripts/package.sh first.
#
# NFPM: the nfpm binary to use (default: nfpm on PATH).
# PACKAGE_VERSION, STAGE, LINUX_REPO_PUBLIC_KEY: another version, staged
# folder or repository key, for scripts/ci/check-linux-repos.sh.
#
# The packages install lokalbot and lokalbot-cli into /usr/bin, the desktop
# entry and icons into /usr/share. LokalBot does not replace a package's
# files. It finds the package that owns it, and for one named lokalbot (these
# packages, lokalbot-update's package::RELEASE_PACKAGE) shows the command that
# installs the new package; the file names below are in that command too.
# Once the repository key is in packaging/linux, the .deb and .rpm also add
# the apt and dnf repositories at pkg.lokalbot.com (scripts/linux-repos.sh)
# with that key, so later versions come with `apt upgrade` and `dnf upgrade`,
# which LokalBot then suggests (package::repository_file).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${PACKAGE_VERSION:-$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)}
ROOT="$(pwd)"
STAGE="${STAGE:-$ROOT/dist/LokalBot-$VERSION-linux-x86_64}"
REPO_KEY="${LINUX_REPO_PUBLIC_KEY:-$ROOT/packaging/linux/lokalbot-archive-keyring.asc}"
NFPM="${NFPM:-nfpm}"
APP_ID=com.lokalbot.LokalBot
if [ ! -x "$STAGE/lokalbot" ] || [ ! -x "$STAGE/lokalbot-cli" ]; then
  echo "$STAGE has no binaries; run scripts/package.sh first." >&2
  exit 1
fi

CONFIG="$ROOT/dist/nfpm.yaml"
KEYRING="$ROOT/dist/lokalbot-archive-keyring.gpg"
mkdir -p "$ROOT/dist"
if [ -f "$REPO_KEY" ]; then
  gpg --dearmor < "$REPO_KEY" > "$KEYRING"
fi
{
  cat <<EOF
name: lokalbot
arch: amd64
platform: linux
version: "$VERSION"
release: "1"
section: utils
priority: optional
maintainer: "stevyhacker <stevyhacker@users.noreply.github.com>"
vendor: LokalBot project
homepage: https://www.lokalbot.com
license: GPL-3.0-only AND AGPL-3.0-only
description: |-
  Private work memory with on-device AI (alpha).
  LokalBot records meetings without a bot, transcribes and summarizes them on
  this computer, and searches what was said and, if you turn it on, what you
  saw on screen. It also has dictation, autocomplete and a read-only CLI and
  MCP server for coding agents.
contents:
  - src: $STAGE/lokalbot
    dst: /usr/bin/lokalbot
    file_info: {mode: 0755}
  - src: $STAGE/lokalbot-cli
    dst: /usr/bin/lokalbot-cli
    file_info: {mode: 0755}
  - src: $ROOT/packaging/linux/$APP_ID.desktop
    dst: /usr/share/applications/$APP_ID.desktop
    file_info: {mode: 0644}
  - src: $STAGE/LICENSE
    dst: /usr/share/doc/lokalbot/copyright
    packager: deb
    file_info: {mode: 0644}
  - src: $STAGE/LICENSE
    dst: /usr/share/licenses/lokalbot/LICENSE
    packager: rpm
    file_info: {mode: 0644}
  - src: $STAGE/LICENSE
    dst: /usr/share/licenses/lokalbot/LICENSE
    packager: archlinux
    file_info: {mode: 0644}
  - src: $STAGE/THIRD_PARTY_NOTICES.md
    dst: /usr/share/doc/lokalbot/THIRD_PARTY_NOTICES.md
    file_info: {mode: 0644}
EOF
  # Every license text the notices name, at the paths they give.
  for license in "$STAGE"/LICENSES/*; do
    cat <<EOF
  - src: $license
    dst: /usr/share/doc/lokalbot/LICENSES/$(basename "$license")
    file_info: {mode: 0644}
EOF
  done
  for size in 16 24 32 48 64 128 256 512; do
    cat <<EOF
  - src: $ROOT/packaging/icons/lokalbot-$size.png
    dst: /usr/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png
    file_info: {mode: 0644}
EOF
  done
  # The repository files are config files: an edited copy survives upgrades.
  if [ -f "$REPO_KEY" ]; then
    cat <<EOF
  - src: $ROOT/packaging/linux/lokalbot.sources
    dst: /etc/apt/sources.list.d/lokalbot.sources
    type: config
    packager: deb
    file_info: {mode: 0644}
  - src: $KEYRING
    dst: /usr/share/keyrings/lokalbot-archive-keyring.gpg
    packager: deb
    file_info: {mode: 0644}
  - src: $ROOT/packaging/linux/lokalbot.repo
    dst: /etc/yum.repos.d/lokalbot.repo
    type: config|noreplace
    packager: rpm
    file_info: {mode: 0644}
  - src: $REPO_KEY
    dst: /etc/pki/rpm-gpg/RPM-GPG-KEY-lokalbot
    packager: rpm
    file_info: {mode: 0644}
EOF
  fi
  # The binaries need glibc 2.39 (built on Ubuntu 24.04). The app links ALSA,
  # xcb and xkbcommon and loads Vulkan and the Wayland client at run time.
  # The llama.cpp runtime it downloads (llama-server) links the GCC OpenMP
  # runtime, libgomp.so.1, which minimal installs lack.
  # Arch's gcc-libs is a meta package of every GCC runtime; namcap asks for
  # libgcc and libstdc++, and for hicolor-icon-theme, which owns the icon folders.
  # System audio uses PulseAudio or PipeWire's PulseAudio server; the
  # suggested tools enable typing and screenshots on some desktops.
  cat <<'EOF'
overrides:
  deb:
    depends:
      - libc6 (>= 2.39)
      - libstdc++6
      - libgcc-s1
      - libgomp1
      - libasound2t64 | libasound2
      - libxcb1
      - libxkbcommon0
      - libxkbcommon-x11-0
      - libvulkan1
      - libwayland-client0
    recommends:
      - pipewire-pulse | pulseaudio
      - mesa-vulkan-drivers
      - libegl1
      - libwayland-egl1
    suggests:
      - xdotool
      - wtype
      - ydotool
      - grim
      - xsel
      - zenity
  rpm:
    depends:
      - libc.so.6(GLIBC_2.39)(64bit)
      - libstdc++.so.6()(64bit)
      - libgomp.so.1()(64bit)
      - libasound.so.2()(64bit)
      - libxcb.so.1()(64bit)
      - libxkbcommon.so.0()(64bit)
      - libxkbcommon-x11.so.0()(64bit)
      - libvulkan.so.1()(64bit)
      - libwayland-client.so.0()(64bit)
    suggests:
      - xdotool
      - wtype
      - grim
      - zenity
  archlinux:
    depends:
      - glibc>=2.39
      - libgcc
      - libstdc++
      - libgomp
      - alsa-lib
      - libxcb
      - libxkbcommon
      - libxkbcommon-x11
      - vulkan-icd-loader
      - wayland
      - hicolor-icon-theme
rpm:
  group: Applications/Productivity
  summary: Private work memory with on-device AI
archlinux:
  packager: "stevyhacker <stevyhacker@users.noreply.github.com>"
EOF
} > "$CONFIG"

cd "$ROOT/dist"
for spec in "deb linux-amd64.deb" "rpm linux-x86_64.rpm" "archlinux linux-x86_64.pkg.tar.zst"; do
  set -- $spec
  OUT="LokalBot-$VERSION-$2"
  rm -f "$OUT" "$OUT.sha256"
  "$NFPM" package --config "$CONFIG" --packager "$1" --target "$OUT"
  sha256sum "$OUT" > "$OUT.sha256"
  echo "dist/$OUT"
done
rm -f "$CONFIG" "$KEYRING"
