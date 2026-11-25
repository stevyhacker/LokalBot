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

TARGET="LokalBotTests"
if [ "${1:-}" != "" ]; then
  FILTER="$1"
  if [[ "$FILTER" == LokalBotBenchmarks/* ]]; then
    TARGET="LokalBotBenchmarks"
    FILTER="${FILTER#LokalBotBenchmarks/}"
  else
    FILTER="${FILTER#LokalBotTests/}"
    CLASS="${FILTER%%/*}"
    if find "$ROOT/LokalBotBenchmarks" -name "$CLASS.swift" -print -quit 2>/dev/null | grep -q .; then
      TARGET="LokalBotBenchmarks"
    fi
  fi
  ARGS+=(-only-testing:"$TARGET/$FILTER")
else
  ARGS+=(-skip-testing:LokalBotBenchmarks)
fi

"$ROOT/Scripts/build/build-sync-xcframework.sh"

RESULTS="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-unit-results.XXXXXX")"
trap 'rm -rf "$RESULTS"' EXIT
STATUS=0
xcodebuild "${ARGS[@]}" -resultBundlePath "$RESULTS/unit.xcresult" test || STATUS=$?
if [ "$TARGET" = "LokalBotTests" ] && [ -d "$RESULTS/unit.xcresult" ]; then
  python3 "$ROOT/Scripts/ci/unit-skips.py" check "$RESULTS/unit.xcresult" || [ "$STATUS" -ne 0 ] || STATUS=1
fi
exit "$STATUS"
