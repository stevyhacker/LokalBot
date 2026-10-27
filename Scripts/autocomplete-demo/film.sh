#!/bin/bash
# Films LokalBot's autocomplete in TextEdit on a hosted Mac in CI, with the
# default on-device model and real keystrokes.
#
#   LOKALBOT_APP=<Debug LokalBot.app> Scripts/autocomplete-demo/film.sh <out-dir> [take...]
#
# Takes are Scripts/autocomplete-demo/shots/*.json (default: all but warmup),
# filmed once per appearance (APPEARANCES, default "dark light"). Each take is
# typed by Scripts/readme-gif/rig.swift with real key events and recorded at
# 30 fps with ScreenCaptureKit: TextEdit's window plus LokalBot's suggestion
# panel, which the Debug build shows to capture with --lokalbot-film-ghost.
# The rig waits for each suggestion and accepts it word by word with Tab; a
# take whose suggestion never comes is filmed again (ATTEMPTS, default 3).
#
# CI only: it grants this runner's TCC permissions to LokalBot and the rig
# with sudo, and changes TextEdit's and the global text defaults (plain text
# in a large font; no spelling marks or macOS inline predictions).
#
# Writes <out-dir>/clips/<appearance>-<take>.mp4 with a .json of the take's
# events, the raw takes' metadata, and the app's log.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "film.sh changes system settings; run it in GitHub Actions" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
APP=$(cd "${LOKALBOT_APP:?set LOKALBOT_APP to a Debug LokalBot.app}" && pwd)
BIN="$APP/Contents/MacOS/LokalBot"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
shift
if [[ $# -eq 0 ]]; then set -- memory email midword chat german french spanish; fi
APPEARANCES=${APPEARANCES:-dark light}
ATTEMPTS=${ATTEMPTS:-3}
WORK=$(cd "$(mktemp -d "${RUNNER_TEMP:-/tmp}/autocomplete-demo.XXXXXX")" && pwd -P)
LIB="$WORK/library"
DOCS="$WORK/docs"
RIG="$WORK/rig"
SUITE="lokalbot.autocomplete-demo.$$"
MODEL_DIR=${MODEL_DIR:-$WORK/model}
LAUNCH=${LAUNCH:-open}
mkdir -p "$OUT/logs" "$OUT/takes" "$OUT/clips"

stop_app() {
  pkill -f "$BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$BIN" >/dev/null || return 0; sleep 0.25; done
  pkill -9 -f "$BIN" 2>/dev/null || true
}
cleanup() {
  pkill -x TextEdit 2>/dev/null || true
  stop_app
  cp "$LIB/debug.log" "$OUT/logs/debug.log" 2>/dev/null || true
  grep -h 'film: ' "$LIB/debug.log" > "$OUT/logs/autocomplete-states.log" 2>/dev/null || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== model =="
MODEL=$(python3 "$HERE/stage.py" model "$MODEL_DIR")
ls -l "$MODEL"

echo "== stage =="
python3 "$HERE/stage.py" library "$LIB" "$MODEL"
python3 "$HERE/stage.py" settings "$SUITE"
swiftc -O -swift-version 5 "$ROOT/Scripts/readme-gif/rig.swift" -o "$RIG"

echo "== permissions =="
# Hosted images run with SIP off, so the TCC databases take rows directly.
grant() {  # grant <client> <client_type: 0 bundle id, 1 path>
  local service db
  for service in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent kTCCServiceScreenCapture; do
    for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
      sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags)
        VALUES ('$service', '$1', $2, 2, 4, 1, 0);" 2>&1 | sed "s|^|  $service $(basename "$(dirname "$(dirname "$db")")"): |" || true
    done
  done
}
grant "$BUNDLE_ID" 0
grant "$BIN" 1
grant "$RIG" 1
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "SELECT service, client, auth_value FROM access WHERE client IN ('$BUNDLE_ID', '$BIN', '$RIG');" || true

echo "== text defaults =="
defaults write -g NSAutomaticInlinePredictionEnabled -bool false
defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
defaults write -g NSAutomaticTextCompletionEnabled -bool false
defaults write -g WebAutomaticSpellingCorrectionEnabled -bool false
defaults write com.apple.TextEdit RichText -bool false
defaults write com.apple.TextEdit NSFixedPitchFont -string HelveticaNeue
defaults write com.apple.TextEdit NSFixedPitchFontSize -int 30
defaults write com.apple.TextEdit CheckSpellingWhileTyping -bool false
defaults write com.apple.TextEdit CheckGrammarWithSpelling -bool false
defaults write com.apple.TextEdit SmartQuotes -bool false
defaults write com.apple.TextEdit ApplePersistenceIgnoreState -bool true
defaults write com.apple.TextEdit NSQuitAlwaysKeepsWindows -bool false

background() { [[ $1 == dark ]] && echo "#1E1E1E" || echo "#FFFFFF"; }

launch_app() {  # launch_app <appearance>
  stop_app
  if [[ $1 == dark ]]; then defaults write -g AppleInterfaceStyle Dark; else defaults delete -g AppleInterfaceStyle 2>/dev/null || true; fi
  local args=(--lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" --lokalbot-film-ghost
              -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" -AppleLocale en_US)
  if [[ $LAUNCH == open ]]; then
    open -n -g "$APP" --args "${args[@]}"
  else
    # A child of this shell: macOS holds the runner responsible for its permissions.
    "$BIN" "${args[@]}" >> "$OUT/logs/app-stdout.log" 2>&1 &
  fi
  for _ in $(seq 120); do pgrep -f "$BIN" >/dev/null && break; sleep 0.5; done
  pgrep -f "$BIN" >/dev/null || { echo "LokalBot did not start"; return 1; }
  sleep 6
}

# film <appearance> <take> <dest>: one attempt; the rig's exit code
film() {
  local shot="$HERE/shots/$2.json" doc status=0
  pkill -x TextEdit 2>/dev/null || true
  sleep 0.5
  rm -rf "$3"
  mkdir -p "$3"
  doc=$(python3 "$HERE/stage.py" shot "$shot" "$DOCS")
  open -a TextEdit "$doc"
  RIG_BACKGROUND=$(background "$1") "$RIG" take "$shot" "$3" || status=$?
  pkill -x TextEdit 2>/dev/null || true
  return $status
}

warm_up() {  # warm_up <appearance>: the model loads; true once a suggestion shows
  local status=0
  film "$1" warmup "$WORK/warmup" > "$OUT/logs/warmup-$1.log" 2>&1 || status=$?
  cat "$OUT/logs/warmup-$1.log"
  grep -h 'film: ' "$LIB/debug.log" 2>/dev/null | tail -12 || true
  return $status
}

failed=0
for appearance in $APPEARANCES; do
  echo "== $appearance =="
  launch_app "$appearance"
  if ! warm_up "$appearance"; then
    if [[ $LAUNCH == open ]]; then
      echo "no suggestion when launched with open; launching LokalBot from this shell instead"
      LAUNCH=direct
      launch_app "$appearance"
      warm_up "$appearance" || { echo "no suggestion after warming up"; tail -60 "$LIB/debug.log" || true; exit 1; }
    else
      echo "no suggestion after warming up"; tail -60 "$LIB/debug.log" || true; exit 1
    fi
  fi
  for take in "$@"; do
    dest="$OUT/takes/$appearance/$take"
    status=1
    for attempt in $(seq "$ATTEMPTS"); do
      status=0
      film "$appearance" "$take" "$dest" || status=$?
      [[ $status -eq 0 ]] && break
      echo "$appearance/$take attempt $attempt: rig exited $status"
    done
    if [[ $status -eq 0 ]]; then
      python3 "$HERE/encode.py" "$dest" "$OUT/clips/$appearance-$take.mp4"
      rm -rf "$dest/frames"
    else
      failed=$((failed + 1))
    fi
  done
done
echo "launched with: $LAUNCH" | tee "$OUT/logs/launch.txt"
stop_app
echo "== what the model weighed =="
SERVER="$APP/Contents/Resources/llama-cpp/llama-server"
if [[ -x "$SERVER" ]]; then
  python3 "$HERE/probe.py" "$LIB/debug.log" "$SERVER" "$MODEL" "$OUT/logs/probabilities.json" || echo "probe failed"
else
  echo "no bundled llama-server at $SERVER"
fi
ls -l "$OUT/clips"
[[ $failed -eq 0 ]] || echo "$failed takes had no suggestion"
[[ -n "$(ls "$OUT/clips"/*.mp4 2>/dev/null)" ]]
