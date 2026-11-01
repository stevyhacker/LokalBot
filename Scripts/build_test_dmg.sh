#!/usr/bin/env bash
# Build a quick UNSIGNED test DMG from a local Debug build of LokalBot, to
# rehearse the drag-to-Applications install flow. Release DMGs are notarized +
# Sparkle-signed via CI / RELEASING.md — this one is for eyeballing layout only.
# Usage: bash Scripts/build_test_dmg.sh [output.dmg]
set -euo pipefail
cd "$(dirname "$0")/.."

OUTPUT_PATH="${1:-/tmp/LokalBot-test.dmg}"
VENV_DIR="/tmp/LokalBot-dmg-venv"
VENV_PY="$VENV_DIR/bin/python3"
DERIVED_DATA="/tmp/LokalBot-test-DerivedData"

# dmgbuild lives in an isolated venv: Homebrew Python is PEP 668-managed, so
# `pip install` against it fails with "externally-managed-environment". A
# throwaway venv sidesteps that and keeps the system interpreter clean.
if [ ! -x "$VENV_PY" ]; then
  echo "Creating dmgbuild venv at $VENV_DIR…"
  python3 -m venv "$VENV_DIR"
fi
if ! "$VENV_PY" -c "import dmgbuild" 2>/dev/null; then
  echo "Installing dmgbuild into venv…"
  "$VENV_PY" -m pip install --quiet --upgrade pip
  "$VENV_PY" -m pip install --quiet dmgbuild
fi

# Build the Debug app. Package only the bundle from this invocation, and let a
# compile failure stop the script instead of falling through to a stale app.
echo "Building LokalBot (Debug)…"
Scripts/build-sync-xcframework.sh
xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -quiet build

APP_PATH="$DERIVED_DATA/Build/Products/Debug/LokalBot.app"
[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || { echo "LokalBot.app not found after build"; exit 1; }

# Debug builds aren't notarized, so Gatekeeper flags a DMG-mounted copy as
# "damaged". Strip quarantine + ad-hoc sign so the test DMG launches without
# manual xattr surgery.
echo "Stripping quarantine and ad-hoc signing…"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

# Eject stale LokalBot volumes first; a remount as "LokalBot 1" would leave a
# blank Finder window and lock files mid-build.
while IFS= read -r vol; do
  [ -z "$vol" ] && continue
  hdiutil detach "$vol" -quiet 2>/dev/null && echo "Ejected $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -Ei "^LokalBot(V3)?$" | sed 's|^|/Volumes/|' || true)

echo "Building test DMG…"
"$VENV_PY" Scripts/build_release_dmg.py --app "$APP_PATH" --output "$OUTPUT_PATH"

# Strip quarantine from the produced image too, so opening it doesn't prompt.
xattr -cr "$OUTPUT_PATH"

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
