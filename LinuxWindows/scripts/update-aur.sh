#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DIR="packaging/aur/lokalbot-bin"
VERSION="${1:?usage: scripts/update-aur.sh <version> [pkgrel]}"
VERSION="${VERSION#v}"
PKGREL="${2:-}"
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
  SHA256=$(gh api "repos/$REPOSITORY/releases/tags/v$VERSION" \
    --jq ".assets[] | select(.name == \"$ASSET\") | .digest | ltrimstr(\"sha256:\")")
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
