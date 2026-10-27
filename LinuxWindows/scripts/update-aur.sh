#!/usr/bin/env bash
# Points the lokalbot-bin AUR package (packaging/aur/lokalbot-bin) at a
# release: sets pkgver, takes the Linux archive's SHA-256 from the release's
# .sha256 asset, and regenerates .SRCINFO. A new version resets pkgrel to 1;
# the same version keeps it unless PKGREL is given (a packaging-only fix).
#
#   scripts/update-aur.sh 0.11.1       # or v0.11.1
#   scripts/update-aur.sh 0.11.1 2     # PKGREL 2 for the same release
#
# .SRCINFO comes from makepkg --printsrcinfo. Where there is no makepkg
# (macOS, Ubuntu), it runs in an archlinux container with docker or podman.
#
# REPOSITORY: the GitHub repository with the release (default
# stevyhacker/LokalBot). SHA256: use this checksum instead of downloading the
# .sha256 asset.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="packaging/aur/lokalbot-bin"
VERSION="${1:?usage: scripts/update-aur.sh <version> [pkgrel]}"
VERSION="${VERSION#v}"
PKGREL="${2:-}"
# pkgver cannot hold a hyphen, and pre-releases stay off the AUR.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "$VERSION is not a release version (x.y.z)." >&2
  exit 1
fi
if [ -n "$PKGREL" ] && ! [[ "$PKGREL" =~ ^[1-9][0-9]*$ ]]; then
  echo "pkgrel must be a positive whole number, not $PKGREL." >&2
  exit 1
fi
REPOSITORY="${REPOSITORY:-stevyhacker/LokalBot}"
ASSET="LokalBot-$VERSION-linux-x86_64.tar.gz"

SHA256="${SHA256:-}"
if [ -z "$SHA256" ]; then
  url="https://github.com/$REPOSITORY/releases/download/v$VERSION/$ASSET.sha256"
  SHA256=$(curl -fsSL --retry 3 "$url" | awk -v asset="$ASSET" '$2 == asset || $2 == "*" asset { print $1 }')
fi
if ! [[ "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "No SHA-256 for $ASSET in release v$VERSION of $REPOSITORY." >&2
  exit 1
fi

trap 'rm -f "$DIR/PKGBUILD.new" "$DIR/.SRCINFO.new"' EXIT

current=$(sed -n 's/^pkgver=//p' "$DIR/PKGBUILD")
pkgrel=$(sed -n 's/^pkgrel=//p' "$DIR/PKGBUILD")
[ "$current" = "$VERSION" ] || pkgrel=1
pkgrel="${PKGREL:-$pkgrel}"
sed -e "s/^pkgver=.*/pkgver=$VERSION/" \
  -e "s/^pkgrel=.*/pkgrel=$pkgrel/" \
  -e "s/^sha256sums_x86_64=.*/sha256sums_x86_64=('$SHA256')/" \
  "$DIR/PKGBUILD" > "$DIR/PKGBUILD.new"
mv "$DIR/PKGBUILD.new" "$DIR/PKGBUILD"

# makepkg refuses to run as root. In the container its user cannot write the
# mounted folder, so its build and output folders move to /tmp.
if command -v makepkg > /dev/null && [ "$(id -u)" != 0 ]; then
  (cd "$DIR" && makepkg --printsrcinfo) > "$DIR/.SRCINFO.new"
else
  engine=$(command -v docker || command -v podman || true)
  if [ -z "$engine" ]; then
    echo "Regenerating .SRCINFO needs makepkg, docker or podman." >&2
    exit 1
  fi
  "$engine" run --rm --user 65534:65534 -e BUILDDIR=/tmp -e PKGDEST=/tmp -e SRCDEST=/tmp \
    -v "$(pwd)/$DIR:/pkg:ro" -w /pkg archlinux:latest \
    makepkg --printsrcinfo > "$DIR/.SRCINFO.new"
fi
mv "$DIR/.SRCINFO.new" "$DIR/.SRCINFO"
echo "lokalbot-bin $VERSION-$pkgrel, sha256 $SHA256"
