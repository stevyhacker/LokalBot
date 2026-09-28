#!/bin/bash
# Record one take with a filming host built from a throwaway copy of the source + filming-host.patch.
#   APP_BUNDLE=".../LokalBot UI Test Host.app" LIBRARY=<seeded demo library> OUT=<takes dir> \
#     filming/film.sh filming/scripts/t-recall.json LOKALBOT_UI_TEST_WINDOW=quick-recall LOKALBOT_CAPTURE_SIZE=660x480
# Launching through LaunchServices keeps the host a normal app; each take gets a fresh copy of the library.
set -euo pipefail
: "${APP_BUNDLE:?}" "${LIBRARY:?}" "${OUT:?}"
SCRIPT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; shift
LIB=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-film-lib.XXXXXX"); cp -R "$LIBRARY/." "$LIB/"
SUITE="lokalbot.film.$(uuidgen)"
ENVS=(LOKALBOT_UI_TEST=1 "LOKALBOT_STORAGE_ROOT=$LIB" "LOKALBOT_DEFAULTS_SUITE=$SUITE" LOKALBOT_CAPTURE_SIZE=1400x880
      LOKALBOT_CAPTURE_APPEARANCE=dark LOKALBOT_SCREEN_MEMORY_DEMO=1 LOKALBOT_DISMISS_ONBOARDING=1 LOKALBOT_FILM_SCALE=1.5
      "LOKALBOT_FILM_DIR=$OUT" "LOKALBOT_FILM_SCRIPT=$SCRIPT" "$@")
ARGS=(); SEEN=" "
for ((i=${#ENVS[@]}-1; i>=0; i--)); do
  key="${ENVS[$i]%%=*}"; case "$SEEN" in *" $key "*) continue;; esac; SEEN="$SEEN$key "; ARGS+=(--env "${ENVS[$i]}")
done
timeout 180 open -n -W "${ARGS[@]}" -a "$APP_BUNDLE" --args -ApplePersistenceIgnoreState YES -AppleLocale en_US \
  -AppleLanguages "(en)" --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" || true
rm -rf "$LIB"
