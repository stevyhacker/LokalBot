#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
DIST="$(cd "$1" && pwd)"
TAG="$2"
KEY_FILE="$3"
EXPECTED="${4:-}"
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
TAG_VERSION="${TAG#v}"
if [ "${TAG_VERSION%%-*}" != "$VERSION" ]; then
  echo "Tag $TAG does not name the workspace version $VERSION" >&2
  exit 1
fi
TOOL="${FEED_TOOL:-}"
if [ -z "$TOOL" ]; then
  cargo build --release --locked -p lokalbot-update --no-default-features --bin lokalbot-update-feed
  TOOL="${CARGO_TARGET_DIR:-target}/release/lokalbot-update-feed"
fi
PUBLIC=$("$TOOL" public-key --key-file "$KEY_FILE")
if [ -n "$EXPECTED" ] && [ "$PUBLIC" != "$EXPECTED" ]; then
  echo "The signing key does not belong to SUPublicEDKey $EXPECTED; nothing was signed." >&2
  exit 1
fi
for PLATFORM in linux-x86_64 windows-x86_64; do
  case "$PLATFORM" in
    windows-*) EXTENSION=zip ;;
    *) EXTENSION=tar.gz ;;
  esac
  ARCHIVE="$DIST/LokalBot-$VERSION-$PLATFORM.$EXTENSION"
  ARGS=(sign --archive "$ARCHIVE" --platform "$PLATFORM" --version "$VERSION" --tag "$TAG"
    --key-file "$KEY_FILE" --expect-public-key "$PUBLIC"
    --minimum-version "${MINIMUM_VERSION:-0.0.0}"
    --repo "${GITHUB_REPOSITORY:-stevyhacker/lokalbot}" --output "$DIST/$PLATFORM.json")
  if [ -n "${DOWNLOAD_BASE:-}" ]; then
    ARGS+=(--download-base "$DOWNLOAD_BASE")
  fi
  "$TOOL" "${ARGS[@]}"
  "$TOOL" verify --feed "$DIST/$PLATFORM.json" --archive "$ARCHIVE" --public-key "$PUBLIC"
done
