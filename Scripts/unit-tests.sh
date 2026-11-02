#!/bin/bash
# LokalBot unit-test runner. Unlike XCUITest, this does not synthesize input or
# take control of the foreground app. Keeping the invocation behind one stable
# project-local command also lets automation grant a narrow reusable approval.
#
# Usage:
#   Scripts/unit-tests.sh
#   Scripts/unit-tests.sh AppSettingsTests
#   Scripts/unit-tests.sh AppSettingsTests/testDefaults
#   Scripts/unit-tests.sh --derived-data-path   # where the build products go
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PROJECT="$ROOT/LokalBot.xcodeproj"
# Build outside the checkout, one folder per checkout. A test host inside
# ~/Documents makes macOS ask for access to Documents after every build.
CHECKOUT_ID="$(printf '%s' "$ROOT" | shasum | cut -c1-10)"
DERIVED="${LOKALBOT_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/LokalBot-unit-tests-$CHECKOUT_ID}"

if [ "${1:-}" = "--derived-data-path" ]; then
  echo "$DERIVED"
  exit 0
fi

ARGS=(
  -quiet
  -project "$PROJECT"
  -scheme LokalBot
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
  -skip-testing:LokalBotUITests
)

if [ "${1:-}" != "" ]; then
  FILTER="${1#LokalBotTests/}"
  ARGS+=(-only-testing:"LokalBotTests/$FILTER")
fi

"$ROOT/Scripts/build-sync-xcframework.sh"
xcodebuild "${ARGS[@]}" test
