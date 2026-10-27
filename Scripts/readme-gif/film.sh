#!/bin/bash
# Records the README GIF takes from the LokalBot UI Test Host.
#
#   APP_BUNDLE=".../LokalBot UI Test Host.app" Scripts/readme-gif/film.sh <takes-dir> [take...]
#
# Takes: recall meeting ask (default: all). APPEARANCES="light dark" (default).
# Each take launches the host on a fresh copy of one seeded fictional library,
# with its own UserDefaults suite, places the window on the built-in Retina
# display, records it with rig, and quits the host. Needs Screen Recording and
# Accessibility for the terminal. A take waits until nobody has touched the
# keyboard, mouse or trackpad for a few seconds, and restarts if they do.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
: "${APP_BUNDLE:?set APP_BUNDLE to a built LokalBot UI Test Host.app}"
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
shift
if [ $# -eq 0 ]; then set -- recall meeting ask; fi
APPEARANCES=${APPEARANCES:-light dark}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-readme-gif.XXXXXX")
HOST="$APP_BUNDLE/Contents/MacOS/"
cleanup() {
  pkill -f "$HOST" 2>/dev/null || true
  for suite in "$WORK"/suite.*; do
    [ -e "$suite" ] || continue
    name=${suite##*/suite.}
    defaults delete "$name" >/dev/null 2>&1 || true
    rm -f "$HOME/Library/Preferences/$name.plist"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

swiftc -O -swift-version 5 "$HERE/rig.swift" -o "$WORK/rig"
python3 "$HERE/seed_library.py" "$WORK/library" >/dev/null

background() { [ "$1" = dark ] && echo "#161B22" || echo "#EAEEF2"; }

take_env() {
  case $1 in
    recall) echo "LOKALBOT_UI_TEST_WINDOW=quick-recall" ;;
    meeting) echo "LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary LOKALBOT_RESET_SPLIT_VIEWS=1" ;;
    ask) echo "LOKALBOT_INITIAL_SECTION=ask LOKALBOT_RESET_SPLIT_VIEWS=1" ;;
    *) echo "unknown take $1" >&2; exit 2 ;;
  esac
}

record() {
  local take=$1 appearance=$2 attempt=$3
  local lib="$WORK/run-$take-$appearance-$attempt"
  local suite
  suite="lokalbot.readme-gif.$(uuidgen)"
  cp -R "$WORK/library" "$lib"
  touch "$WORK/suite.$suite"
  local -a envs=(--env LOKALBOT_UI_TEST=1 --env "LOKALBOT_STORAGE_ROOT=$lib" --env "LOKALBOT_DEFAULTS_SUITE=$suite"
                 --env "LOKALBOT_CAPTURE_APPEARANCE=$appearance" --env LOKALBOT_DISMISS_ONBOARDING=1
                 --env LOKALBOT_SCREEN_MEMORY_DEMO=1)
  for kv in $(take_env "$take"); do envs+=(--env "$kv"); done
  "$WORK/rig" idle 4
  open -n -a "$APP_BUNDLE" "${envs[@]}" --args -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" \
    -AppleLocale en_US --lokalbot-ui-test --lokalbot-storage-root "$lib" --lokalbot-defaults-suite "$suite"
  sleep 4
  local status=0
  RIG_BACKGROUND=$(background "$appearance") "$WORK/rig" take "$HERE/shots/$take.json" "$OUT/$appearance/$take" || status=$?
  pkill -f "$HOST" 2>/dev/null || true
  sleep 1
  rm -rf "$lib"
  return $status
}

for appearance in $APPEARANCES; do
  for take in "$@"; do
    for attempt in 1 2 3 4 5; do
      status=0
      record "$take" "$appearance" "$attempt" || status=$?
      [ $status -eq 0 ] && break
      [ $status -eq 3 ] || exit $status
      echo "film: $appearance/$take interrupted by input; retrying" >&2
    done
    [ $status -eq 0 ] || exit $status
  done
done
