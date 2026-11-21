#!/bin/bash
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
WORK=$(mkdir -p "$1" && cd "$1" && pwd)
REV=${2:-v0.11.2}
SRC="$WORK/filming-src"
DD="$WORK/filming-DD"
INSTALLED=/Applications/LokalBot.app
PANEL=LokalBot/Cotyping/CotypingOverlayController.swift

rm -rf "$SRC" "$DD" "$WORK/LokalBot.app"
mkdir -p "$SRC/.build"
git -C "$REPO" archive "$REV" | tar -x -C "$SRC"
cp -c -R "$REPO/Vendor/." "$SRC/Vendor/"
cp -c -R "$REPO/.build/SourcePackages" "$SRC/.build/SourcePackages"
[ "$(grep -c 'panel.sharingType = .none' "$SRC/$PANEL")" = 1 ] || { echo "expected one sharingType line in $PANEL" >&2; exit 1; }
sed -i '' 's/panel.sharingType = .none/panel.sharingType = .readOnly/' "$SRC/$PANEL"

TEAM=$(codesign -dv "$INSTALLED" 2>&1 | sed -n 's/^TeamIdentifier=//p')
REQ=$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^designated => //p')
IDENTITY=$(codesign -dvv "$INSTALLED" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)
[ -n "$TEAM" ] && [ -n "$REQ" ] && [ -n "$IDENTITY" ] || { echo "cannot read the installed app's signature" >&2; exit 1; }

(cd "$SRC" && xcodegen generate >/dev/null)
xcodebuild archive -project "$SRC/LokalBot.xcodeproj" -scheme LokalBot -configuration Release \
  -archivePath "$DD/LokalBot.xcarchive" -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$SRC/.build/SourcePackages" -disableAutomaticPackageResolution \
  -destination 'generic/platform=macOS' ARCHS=arm64 ENABLE_HARDENED_RUNTIME=YES \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" \
  -quiet > "$WORK/filming-build.log" 2>&1 || { tail -30 "$WORK/filming-build.log" >&2; exit 1; }

APP="$DD/LokalBot.xcarchive/Products/Applications/LokalBot.app"
codesign --force --preserve-metadata=identifier,entitlements,flags,runtime \
  --requirements="=designated => $REQ" --options runtime --timestamp=none \
  --sign "$IDENTITY" "$APP" >> "$WORK/filming-build.log" 2>&1
codesign --verify --deep --strict "$APP"
[ "$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')" = "$REQ" ]
ditto "$APP" "$WORK/LokalBot.app"
echo "$WORK/LokalBot.app ($(git -C "$REPO" rev-parse --short "$REV"), ghost panel visible to capture)"
