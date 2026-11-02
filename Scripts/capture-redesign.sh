#!/bin/bash
# Capture the seven current product surfaces from the real SwiftUI UI-test
# host at the reference aspect ratio. The synthetic library contains grounded
# meetings, outcomes, day activity, and an answered Ask thread.
set -euo pipefail
cd "$(dirname "$0")/.."
exec </dev/null

SCHEME="LokalBot UI Test Host"
OUT="${LOKALBOT_REDESIGN_CAPTURE_OUT:-$PWD/Artifacts/redesign-qa}"
LIB="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-redesign-library.XXXXXX")"
SUITE="lokalbot.redesign.$(uuidgen)"
# AppLifecycle sizes the window content; the rendered frame includes the
# 52-point macOS titlebar. 941 points therefore yields the approved 1584x993
# comparison raster used by the redesign sources.
CAPTURE_SIZE="${LOKALBOT_CAPTURE_SIZE:-1584x941}"
CAPTURE_SCALE="${LOKALBOT_CAPTURE_SCALE:-1}"
CAPTURE_DELAY="${LOKALBOT_CAPTURE_DELAY:-8}"
CAPTURE_APPEARANCE="${LOKALBOT_CAPTURE_APPEARANCE:-dark}"

cleanup() {
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  rm -rf "$LIB"
}
trap cleanup EXIT

mkdir -p "$OUT"
Scripts/build-sync-xcframework.sh
xcodegen generate >/dev/null
xcodebuild -project LokalBot.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'platform=macOS' build >/dev/null
PRODUCTS=$(xcodebuild -project LokalBot.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS/LokalBot UI Test Host.app/Contents/MacOS/LokalBot UI Test Host"
python3 Scripts/seed_demo_library.py "$LIB"

capture() {
  name="$1"
  shift
  destination="$OUT/$name.png"
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  rm -f "$destination"
  env LOKALBOT_UI_TEST=1 \
      LOKALBOT_STORAGE_ROOT="$LIB" \
      LOKALBOT_DEFAULTS_SUITE="$SUITE" \
      LOKALBOT_CAPTURE_FILE="$destination" \
      LOKALBOT_CAPTURE_SIZE="$CAPTURE_SIZE" \
      LOKALBOT_CAPTURE_CONTENT_MAX=420 \
      LOKALBOT_CAPTURE_SCALE="$CAPTURE_SCALE" \
      LOKALBOT_CAPTURE_DELAY="$CAPTURE_DELAY" \
      LOKALBOT_CAPTURE_APPEARANCE="$CAPTURE_APPEARANCE" \
      LOKALBOT_DISMISS_ONBOARDING=1 \
      LOKALBOT_SCREEN_MEMORY_DEMO=1 \
      LOKALBOT_CALENDAR_DEMO=1 \
      "$@" \
    "$APP" -ApplePersistenceIgnoreState YES -AppleLocale en_US -AppleLanguages "(en)" \
    --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" \
    >/dev/null 2>&1 &
  for _ in $(seq 1 50); do
    [ -s "$destination" ] && break
    sleep 0.5
  done
  if [ ! -s "$destination" ]; then
    echo "capture failed: $name" >&2
    exit 1
  fi
  echo "$destination"
}

capture redesign-01-timeline LOKALBOT_INITIAL_SECTION=timeline
capture redesign-02-today LOKALBOT_INITIAL_SECTION=today
capture redesign-03-meetings LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0
capture redesign-04-ask LOKALBOT_INITIAL_SECTION=ask
capture redesign-05-agent LOKALBOT_INITIAL_SECTION=agent \
  LOKALBOT_AGENT_UI_TEST_READY=1 LOKALBOT_AGENT_DEMO=1
capture redesign-06-autocomplete LOKALBOT_INITIAL_SECTION=autocomplete \
  LOKALBOT_COTYPING_DEMO=1
capture redesign-07-models LOKALBOT_INITIAL_SECTION=models \
  LOKALBOT_MODELS_DEMO_READY=1

echo "Redesign captures: $OUT"
