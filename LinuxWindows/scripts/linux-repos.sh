#!/usr/bin/env bash
# Adds Linux packages to LokalBot's apt and dnf repositories and signs them.
# .github/workflows/linux-repos.yml publishes the tree at https://pkg.lokalbot.com:
#   apt/           suite stable, component main, amd64: pool/main/l/lokalbot/
#                  and dists/stable/ with InRelease, Release and Release.gpg
#                  (apt-ftparchive, SHA-256 only, indexes also by hash)
#   rpm/           the RPMs, each signed with rpmsign, and repodata/
#                  (createrepo_c) with repomd.xml.asc
#   lokalbot.asc   the public key, and lokalbot.gpg, the same key unarmored
#
#   scripts/linux-repos.sh REPO KEY [PACKAGE.deb|PACKAGE.rpm ...]
#
# REPO holds the published packages (copied from the bucket, or empty for a
# new repository) and receives the new tree. KEY is the signing key's
# fingerprint; GNUPGHOME has its secret key. A package whose version is
# already published is left out: a published version's bytes never change.
# Each repository then keeps its newest KEEP (default 3) versions, and every
# index is rebuilt, signed and checked against the public key. With no
# packages, the indexes are only rebuilt and signed again.
#
# PUBLIC_KEY: the armored public keyring to publish (default: KEY's public
# key). It must contain KEY.
#
# Needs apt-ftparchive (apt-utils), dpkg-deb, createrepo_c, rpm, rpmsign and
# gpg, as on Ubuntu 24.04.
set -euo pipefail
if [ $# -lt 2 ]; then
  echo "usage: $0 REPO KEY [PACKAGE.deb|PACKAGE.rpm ...]" >&2
  exit 2
fi
mkdir -p "$1"
REPO=$(cd "$1" && pwd)
KEY=$2
shift 2
KEEP=${KEEP:-3}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

APT="$REPO/apt"
POOL="$APT/pool/main/l/lokalbot"
DIST="$APT/dists/stable"
RPMS="$REPO/rpm"
mkdir -p "$POOL" "$RPMS"

if [ -n "${PUBLIC_KEY:-}" ]; then
  cp "$PUBLIC_KEY" "$REPO/lokalbot.asc"
else
  gpg --batch --armor --export-options export-minimal --export "$KEY" > "$REPO/lokalbot.asc"
fi
gpg --dearmor < "$REPO/lokalbot.asc" > "$REPO/lokalbot.gpg"
if ! gpg --batch --show-keys --with-colons "$REPO/lokalbot.asc" |
  awk -F: '$1 == "fpr" {print $10}' | grep -qix "$KEY"; then
  echo "The published key does not contain $KEY." >&2
  exit 1
fi
RPMDB="$WORK/rpmdb"
mkdir -p "$RPMDB"
rpmkeys --dbpath "$RPMDB" --import "$REPO/lokalbot.asc"

for package in "$@"; do
  case "$package" in
    *.deb)
      name=$(dpkg-deb --field "$package" Package)
      version=$(dpkg-deb --field "$package" Version)
      arch=$(dpkg-deb --field "$package" Architecture)
      target="$POOL/lokalbot_${version}_amd64.deb"
      ;;
    *.rpm)
      read -r name version arch < <(rpm -qp --queryformat '%{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$package")
      target="$RPMS/lokalbot-$version.x86_64.rpm"
      ;;
    *)
      echo "$package is not a .deb or .rpm" >&2
      exit 1
      ;;
  esac
  if [ "$name" != lokalbot ] || { [ "$arch" != amd64 ] && [ "$arch" != x86_64 ]; }; then
    echo "$package is $name for $arch, not lokalbot for x86_64" >&2
    exit 1
  fi
  if [ -e "$target" ]; then
    echo "lokalbot $version is already published; keeping $(basename "$target")"
    continue
  fi
  cp "$package" "$WORK/new"
  if [[ "$package" == *.rpm ]]; then
    # Ubuntu's rpm looks for gpg as gpg2, which it no longer ships.
    rpmsign --addsign --define "__gpg $(command -v gpg)" --define "_gpg_name $KEY" \
      --define "_gpg_sign_cmd_extra_args --batch --digest-algo sha256" "$WORK/new" > /dev/null
  fi
  mv "$WORK/new" "$target"
  echo "added $(basename "$target")"
done

# The newest KEEP versions stay.
prune() {
  local dir=$1 prefix=$2 suffix=$3 version
  find "$dir" -maxdepth 1 -name "$prefix*$suffix" -printf '%f\n' |
    sed "s/^$prefix//; s/$suffix\$//" | sort -V | head -n -"$KEEP" |
    while read -r version; do
      rm "$dir/$prefix$version$suffix"
      echo "removed $prefix$version$suffix"
    done
}
prune "$POOL" lokalbot_ _amd64.deb
prune "$RPMS" lokalbot- .x86_64.rpm

# apt: one index, listed in Release by SHA-256 and also stored under its hash
# (Acquire-By-Hash), so a cached or half-uploaded index never mismatches.
SHA256_ONLY=(-o APT::FTPArchive::MD5=false -o APT::FTPArchive::SHA1=false -o APT::FTPArchive::SHA512=false)
BIN="$DIST/main/binary-amd64"
rm -rf "$DIST"
mkdir -p "$BIN"
(cd "$APT" && apt-ftparchive "${SHA256_ONLY[@]}" packages pool) > "$BIN/Packages"
gzip -9nc "$BIN/Packages" > "$BIN/Packages.gz"
apt-ftparchive "${SHA256_ONLY[@]}" \
  -o APT::FTPArchive::Release::Origin=LokalBot \
  -o APT::FTPArchive::Release::Label=LokalBot \
  -o APT::FTPArchive::Release::Suite=stable \
  -o APT::FTPArchive::Release::Codename=stable \
  -o APT::FTPArchive::Release::Architectures=amd64 \
  -o APT::FTPArchive::Release::Components=main \
  -o "APT::FTPArchive::Release::Description=LokalBot (alpha)" \
  -o APT::FTPArchive::Release::Acquire-By-Hash=yes \
  release "$DIST" > "$WORK/Release"
mv "$WORK/Release" "$DIST/Release"
awk '/^SHA256:/ {list = 1; next} /^[^ ]/ {list = 0} list {print $1, $3}' "$DIST/Release" |
  while read -r hash file; do
    mkdir -p "$DIST/$(dirname "$file")/by-hash/SHA256"
    cp "$DIST/$file" "$DIST/$(dirname "$file")/by-hash/SHA256/$hash"
  done
sign() { gpg --batch --yes --local-user "$KEY" --digest-algo SHA512 "$@"; }
sign --clearsign --output "$DIST/InRelease" "$DIST/Release"
sign --armor --detach-sign --output "$DIST/Release.gpg" "$DIST/Release"

# dnf: repodata names each file by its hash; repomd.xml is signed.
rm -rf "$RPMS/repodata"
createrepo_c --quiet --no-database --general-compress-type=gz "$RPMS"
sign --armor --detach-sign --output "$RPMS/repodata/repomd.xml.asc" "$RPMS/repodata/repomd.xml"

# Everything verifies with the public key alone.
gpgv --quiet --keyring "$REPO/lokalbot.gpg" "$DIST/InRelease"
gpgv --quiet --keyring "$REPO/lokalbot.gpg" "$DIST/Release.gpg" "$DIST/Release"
gpgv --quiet --keyring "$REPO/lokalbot.gpg" "$RPMS/repodata/repomd.xml.asc" "$RPMS/repodata/repomd.xml"
for rpm in "$RPMS"/*.rpm; do
  [ -e "$rpm" ] || continue
  if ! rpmkeys --dbpath "$RPMDB" --checksig "$rpm" | grep -q ' signatures OK$'; then
    echo "$(basename "$rpm") is not signed by $KEY" >&2
    exit 1
  fi
done
echo "apt: $(grep -c '^Package:' "$BIN/Packages") versions; rpm: $(find "$RPMS" -maxdepth 1 -name '*.rpm' | wc -l) versions"
