#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PROJECT="$ROOT/LokalBot.xcodeproj"
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

RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-unit-results.XXXXXX")"
trap 'rm -rf "$RESULTS"' EXIT
STATUS=0
xcodebuild "${ARGS[@]}" -resultBundlePath "$RESULTS/unit.xcresult" test || STATUS=$?
if [ -d "$RESULTS/unit.xcresult" ]; then
  python3 "$ROOT/Scripts/ci/unit-skips.py" check "$RESULTS/unit.xcresult" || [ "$STATUS" -ne 0 ] || STATUS=1
fi
exit "$STATUS"
