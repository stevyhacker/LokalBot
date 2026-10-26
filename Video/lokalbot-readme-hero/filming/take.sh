#!/bin/bash
# Records one take with the filming host (the UI Test Host built with filming-host.patch).
#   WORK=<dir> filming/take.sh filming/scripts/t-meeting.json [ENV=VALUE ...]
# WORK holds the build (dd/), the seeded library (library/) and the takes (takes/).
# Each take gets a fresh copy of the library and its own defaults suite, both
# removed afterwards. Exits 3 if the host started a recording; the copy holding
# it is deleted either way.
set -euo pipefail
: "${WORK:?set WORK to the folder holding dd/, library/ and takes/}"
APP_BUNDLE="${APP_BUNDLE:-$WORK/dd/Build/Products/Debug/LokalBot UI Test Host.app}"
LIBRARY="${LIBRARY:-$WORK/library}"
OUT="${OUT:-$WORK/takes}"
SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
mkdir -p "$OUT"
LIB=$(mktemp -d "$WORK/lib.XXXXXX"); cp -R "$LIBRARY/." "$LIB/"
SUITE="lokalbot.film.$(uuidgen)"
# FILM_TZ must match the zone the library was seeded in (seed_filming_library.py).
ENVS=(LOKALBOT_UI_TEST=1 "TZ=${FILM_TZ:-Asia/Tokyo}" "LOKALBOT_STORAGE_ROOT=$LIB" "LOKALBOT_DEFAULTS_SUITE=$SUITE"
      LOKALBOT_CAPTURE_SIZE=940x620 LOKALBOT_CAPTURE_APPEARANCE=light LOKALBOT_SCREEN_MEMORY_DEMO=1
      LOKALBOT_DISMISS_ONBOARDING=1 LOKALBOT_FILM_SCALE=1.5 "LOKALBOT_FILM_DIR=$OUT" "LOKALBOT_FILM_SCRIPT=$SCRIPT" "$@")
ARGS=(); SEEN=" "
for ((i=${#ENVS[@]}-1; i>=0; i--)); do
  key="${ENVS[$i]%%=*}"; case "$SEEN" in *" $key "*) continue;; esac; SEEN="$SEEN$key "; ARGS+=(--env "${ENVS[$i]}")
done
timeout 120 open -n -W "${ARGS[@]}" -a "$APP_BUNDLE" --args -ApplePersistenceIgnoreState YES -AppleLocale en_US \
  -AppleLanguages "(en)" --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" || true
rec=$(find "$LIB" \( -iname '*manual-recording*' -o -name '*.live.caf' \) 2>/dev/null | head -5)
rm -rf "$LIB"
defaults delete "$SUITE" >/dev/null 2>&1 || true
rm -f "$HOME/Library/Preferences/$SUITE.plist"
if [ -n "$rec" ]; then echo "WARNING: the host wrote a recording (deleted): $rec" >&2; exit 3; fi
echo "take done: $(basename "$SCRIPT")"
