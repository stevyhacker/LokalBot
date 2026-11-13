#!/bin/bash
# LokalBot unit-test runner. Unlike XCUITest, this does not synthesize input or
# take control of the foreground app. Keeping the invocation behind one stable
# project-local command also lets automation grant a narrow reusable approval.
#
# Usage:
#   Scripts/test/unit-tests.sh
#   Scripts/test/unit-tests.sh AppSettingsTests
#   Scripts/test/unit-tests.sh AppSettingsTests/testExplicitDiarizationChoicesSurviveReloadWithoutReenablingDiarization
#   Scripts/test/unit-tests.sh --derived-data-path   # where the build products go
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
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

"$ROOT/Scripts/build/build-sync-xcframework.sh"

# A skipped test reports nothing, so name every skip and fail on one that is
# not a listed opt-in test (Scripts/ci/unit-skips.json), as hosted CI does.
RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-unit-results.XXXXXX")"
trap 'rm -rf "$RESULTS"' EXIT
STATUS=0
xcodebuild "${ARGS[@]}" -resultBundlePath "$RESULTS/unit.xcresult" test || STATUS=$?
if [ -d "$RESULTS/unit.xcresult" ]; then
  python3 "$ROOT/Scripts/ci/unit-skips.py" check "$RESULTS/unit.xcresult" || [ "$STATUS" -ne 0 ] || STATUS=1
fi
exit "$STATUS"
