#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "--in-container" ]; then
  cd /root
  pacman -Syu --noconfirm --needed base-devel namcap > /dev/null
  useradd -m builder
  echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
  install -d -o builder /home/builder/pkg
  install -m644 -o builder /src/PKGBUILD /src/.SRCINFO /home/builder/pkg/
  cd /home/builder/pkg
  as_builder() { sudo -u builder -- "$@"; }

  namcap_check() {
    local report
    report=$(as_builder namcap "$1")
    printf '%s\n' "${report:-  (no findings)}"
    if grep -q ' E: ' <<< "$report"; then
      echo "namcap reported errors for $1" >&2
      exit 1
    fi
  }

  echo "== .SRCINFO"
  if ! as_builder makepkg --printsrcinfo | diff -u .SRCINFO -; then
    echo ".SRCINFO does not match the PKGBUILD; run scripts/update-aur.sh" >&2
    exit 1
  fi
  echo "  matches the PKGBUILD"

  echo "== namcap PKGBUILD"
  namcap_check PKGBUILD

  echo "== makepkg -si"
  as_builder makepkg -si --noconfirm

  package=$(ls lokalbot-bin-*.pkg.tar.zst)
  echo "== namcap $package"
  namcap_check "$package"

  echo "== installed files"
  pacman -Qlq lokalbot-bin | grep -v '/$'
  test -x /usr/bin/lokalbot
  test -x /usr/bin/lokalbot-cli
  test -f /usr/share/applications/com.lokalbot.LokalBot.desktop
  test -f /usr/share/icons/hicolor/512x512/apps/com.lokalbot.LokalBot.png

  echo "== libraries"
  for binary in /usr/bin/lokalbot /usr/bin/lokalbot-cli; do
    ldd "$binary"
    if ldd "$binary" | grep 'not found' > /dev/null; then
      echo "$binary has a missing library" >&2
      exit 1
    fi
  done
  for lib in libvulkan.so.1 libwayland-client.so.0; do
    ldconfig -p | grep -F "$lib" > /dev/null || { echo "missing $lib" >&2; exit 1; }
    echo "  $lib: installed"
  done

  echo "== version"
  pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
  library=$(mktemp -d)
  reply=$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-aur-package","version":"1"}}}' |
    lokalbot-cli --lokalbot-storage-root "$library" mcp 2> /dev/null)
  version=$(sed -n 's/.*"serverInfo":{[^}]*"version":"\([^"]*\)".*/\1/p' <<< "$reply")
  echo "  lokalbot-cli $version, pkgver $pkgver"
  [ "$version" = "$pkgver" ] || { echo "lokalbot-cli reports '$version', not $pkgver" >&2; exit 1; }
  lokalbot-cli --help > /dev/null
  echo "OK"
  exit 0
fi

cd "$(dirname "$0")/../.."
DIR="$(cd "${1:-packaging/aur/lokalbot-bin}" && pwd)"
SCRIPT="$(pwd)/scripts/ci/check-aur-package.sh"
"${ENGINE:-docker}" run --rm \
  -v "$DIR:/src:ro" \
  -v "$SCRIPT:/check-aur-package.sh:ro" \
  "${IMAGE:-archlinux:latest}" \
  bash /check-aur-package.sh --in-container
