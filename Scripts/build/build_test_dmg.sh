#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

OUTPUT_PATH="${1:-/tmp/LokalBot-test.dmg}"
VENV_DIR="/tmp/LokalBot-dmg-venv"
VENV_PY="$VENV_DIR/bin/python3"
DERIVED_DATA="/tmp/LokalBot-test-DerivedData"

if [ ! -x "$VENV_PY" ]; then
  echo "Creating dmgbuild venv at $VENV_DIR…"
  python3 -m venv "$VENV_DIR"
fi
if ! "$VENV_PY" -c "import dmgbuild" 2>/dev/null; then
  echo "Installing dmgbuild into venv…"
  "$VENV_PY" -m pip install --quiet --upgrade pip
  "$VENV_PY" -m pip install --quiet dmgbuild
fi

echo "Building LokalBot (Debug)…"
mkdir -p Vendor/llama-cpp Vendor/sherpa-onnx
Scripts/build/build-sync-xcframework.sh
xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme LokalBot -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -quiet build

APP_PATH="$DERIVED_DATA/Build/Products/Debug/LokalBot.app"
[ -n "$APP_PATH" ] && [ -d "$APP_PATH" ] || { echo "LokalBot.app not found after build"; exit 1; }

echo "Stripping quarantine and ad-hoc signing…"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"

while IFS= read -r vol; do
  [ -z "$vol" ] && continue
  hdiutil detach "$vol" -quiet 2>/dev/null && echo "Ejected $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -Ei "^LokalBot(V3)?$" | sed 's|^|/Volumes/|' || true)

echo "Building test DMG…"
"$VENV_PY" Scripts/release/build_release_dmg.py --app "$APP_PATH" --output "$OUTPUT_PATH"

xattr -cr "$OUTPUT_PATH"

echo "Opening $OUTPUT_PATH"
open "$OUTPUT_PATH"
