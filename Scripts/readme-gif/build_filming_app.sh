#!/bin/bash
# Builds the copy of LokalBot that films autocomplete and dictation.
#
#   Scripts/readme-gif/build_filming_app.sh <work-dir> [revision]   (default revision: v0.11.2)
#
# The shipping autocomplete panel sets `sharingType = .none`, so screen
# recording never sees a suggestion. This copy changes that one line to
# `.readOnly` and is otherwise the release source. It is built from
# `git archive`, so the checkout and /Applications/LokalBot.app are untouched,
# then re-signed to the installed app's designated requirement so the
# installed app's Accessibility and Input Monitoring grants apply to it.
# Never ship or commit the result.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
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
# Nested code keeps the signatures the archive gave it; only the outer bundle
# gets the installed app's designated requirement. --deep would re-sign
# Sparkle and lokalbot-cli with the app's entitlements and break them.
codesign --force --preserve-metadata=identifier,entitlements,flags,runtime \
  --requirements="=designated => $REQ" --options runtime --timestamp=none \
  --sign "$IDENTITY" "$APP" >> "$WORK/filming-build.log" 2>&1
codesign --verify --deep --strict "$APP"
[ "$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')" = "$REQ" ]
ditto "$APP" "$WORK/LokalBot.app"
echo "$WORK/LokalBot.app ($(git -C "$REPO" rev-parse --short "$REV"), ghost panel visible to capture)"
