#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/LokalBot/Agent/AgentRuntime.swift"
VERSION=$(sed -nE 's/.*static let bunVersion = "([0-9.]+)".*/\1/p' "$SOURCE")
ZIP_SHA=$(awk '/name: "Bun /{found=1} found && /sha256:/{sub(/.*sha256: "/, ""); sub(/".*/, ""); print; exit}' "$SOURCE")
BIN_SHA=$(sed -nE 's/.*bunBinarySHA256: "([0-9a-f]{64})".*/\1/p' "$SOURCE")
if [[ "${1:-}" == "--print-pins" ]]; then
  echo "$VERSION $ZIP_SHA $BIN_SHA"
  exit 0
fi
[[ -n "$VERSION" && ${#ZIP_SHA} -eq 64 && ${#BIN_SHA} -eq 64 ]] || { echo "Bun pins not found in $SOURCE" >&2; exit 1; }
DEST="${1:-$ROOT/.build/bun}"
mkdir -p "$DEST"
curl -fsSL --retry 3 -o "$DEST/bun.zip" \
  "https://github.com/oven-sh/bun/releases/download/bun-v$VERSION/bun-darwin-aarch64.zip"
echo "$ZIP_SHA  $DEST/bun.zip" | shasum -a 256 -c - >/dev/null
rm -rf "$DEST/unzipped"
unzip -q "$DEST/bun.zip" -d "$DEST/unzipped"
install -m 0755 "$DEST/unzipped/bun-darwin-aarch64/bun" "$DEST/bun"
echo "$BIN_SHA  $DEST/bun" | shasum -a 256 -c - >/dev/null
echo "$DEST/bun"
