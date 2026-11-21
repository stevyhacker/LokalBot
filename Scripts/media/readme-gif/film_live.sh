#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
: "${FILMING_APP:?set FILMING_APP to the copy built by build_filming_app.sh}"
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
shift
if [ $# -eq 0 ]; then set -- autocomplete dictation; fi
APPEARANCES=${APPEARANCES:-light dark}
INSTALLED=/Applications/LokalBot.app

WORK=$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-readme-gif-live.XXXXXX")
SUITE="lokalbot.readme-gif.$(uuidgen)"
LIB="$WORK/library"
reopen_installed=0
if pgrep -f "$INSTALLED/Contents/MacOS/LokalBot" >/dev/null; then reopen_installed=1; fi

quit_app() {
  local bin="$1/Contents/MacOS/LokalBot"
  pgrep -f "$bin" >/dev/null || return 0
  osascript -e "tell application \"$1\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 40); do pgrep -f "$bin" >/dev/null || return 0; sleep 0.5; done
  pkill -f "$bin" || true
}
cleanup() {
  osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
  osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
  quit_app "$FILMING_APP"
  cp "$LIB/debug.log" "$OUT/filming-app.log" 2>/dev/null || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$SUITE.plist"
  rm -rf "$WORK"
  if [ $reopen_installed = 1 ]; then open -g "$INSTALLED"; fi
}
trap cleanup EXIT

swiftc -O -swift-version 5 "$HERE/rig.swift" -o "$WORK/rig"
python3 "$HERE/prepare_filming.py" "$LIB" "$SUITE" >/dev/null
osascript -e 'tell application "TextEdit" to quit' >/dev/null 2>&1 || true
quit_app "$INSTALLED"
open -n -g "$FILMING_APP" --args -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" -AppleLocale en_US \
  --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE"
for _ in $(seq 60); do pgrep -f "$FILMING_APP/Contents/MacOS/LokalBot" >/dev/null && break; sleep 0.5; done
sleep 8

background() { [ "$1" = dark ] && echo "#161B22" || echo "#EAEEF2"; }
document() {
  case $1 in
    autocomplete) printf 'launch-email' ;;
    dictation) printf 'team-update' ;;
  esac
}
opening() {
  case $1 in
    autocomplete) printf 'Hi all,\n\n' ;;
    dictation) printf '' ;;
  esac
}

for appearance in $APPEARANCES; do
  for take in "$@"; do
    file="$WORK/$(document "$take").txt"
    status=1
    for attempt in 1 2 3 4 5; do
      opening "$take" > "$file"
      "$WORK/rig" idle 4
      open -a TextEdit "$file"
      osascript "$HERE/open_textedit.applescript" "$file" >/dev/null
      sleep 1.5
      status=0
      RIG_BACKGROUND=$(background "$appearance") "$WORK/rig" take "$HERE/shots/$take.json" "$OUT/$appearance/$take" || status=$?
      osascript -e 'tell application "TextEdit" to close every document saving no' >/dev/null 2>&1 || true
      [ $status -eq 0 ] && break
      [ $status -eq 3 ] || exit $status
      echo "film_live: $appearance/$take interrupted by input; retrying" >&2
    done
    [ $status -eq 0 ] || exit $status
  done
done
