#!/bin/bash
# Films the UGC demo's app footage on a hosted Mac in GitHub Actions: Ask and
# a meeting in the LokalBot UI Test Host on the README's fictional library,
# and autocomplete in TextEdit with the default on-device model. Every take is
# recorded at 2x on a virtual Retina display, without the system pointer, and
# with the pointer's path logged, so the edit draws a smooth pointer and moves
# its camera with it.
#
#   UI_HOST_APP=<LokalBot UI Test Host.app> LOKALBOT_APP=<Debug LokalBot.app> \
#     film.sh <out-dir> [take...]
#
# Takes: flow ask meeting (shots/*.json, the UI Test Host) and follow-up
# (autocomplete, filmed by Scripts/autocomplete-demo/film.sh); default all.
# Writes <out>/clips/<take>.mp4 (30 fps, 4:4:4) with <take>.json (rect, scale,
# events, pointer path), <out>/probes/ (each take's accessibility tree and a
# frame at its start and at every `mark`), <out>/cursors/ (the system pointer
# images) and <out>/logs/. A take that fails is reported and skipped.
#
# CI only: it grants the rig's TCC permissions with sudo, like the
# autocomplete film script.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "film.sh changes system settings; run it in GitHub Actions" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
HOST_APP=$(cd "${UI_HOST_APP:?set UI_HOST_APP to a built LokalBot UI Test Host.app}" && pwd)
HOST_BIN="$HOST_APP/Contents/MacOS/"
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
shift
if [[ $# -eq 0 ]]; then set -- flow ask meeting follow-up; fi
WORK=$(cd "$(mktemp -d "${RUNNER_TEMP:-/tmp}/ugc-film.XXXXXX")" && pwd -P)
RIG="$WORK/rig"
DISPLAY_SIZE=${DISPLAY_SIZE:-1200x1600}
mkdir -p "$OUT/logs" "$OUT/clips" "$OUT/takes" "$OUT/probes"

quit_host() {
  pkill -f "$HOST_BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$HOST_BIN" >/dev/null || return 0; sleep 0.25; done
  pkill -9 -f "$HOST_BIN" 2>/dev/null || true
}
cleanup() {
  quit_host
  for suite in "$WORK"/suite.*; do
    [[ -e "$suite" ]] && defaults delete "${suite##*/suite.}" >/dev/null 2>&1 || true
  done
  if [[ -n "${DISPLAY_PID:-}" ]]; then kill "$DISPLAY_PID" 2>/dev/null || true; fi
}
trap cleanup EXIT

echo "== tools =="
swiftc -O -swift-version 5 "$ROOT/Scripts/readme-gif/rig.swift" -o "$RIG"
clang -fobjc-arc -O2 -framework Foundation -framework CoreGraphics "$HERE/vdisplay.m" -o "$WORK/vdisplay"

echo "== permissions =="
# Hosted images run with SIP off, so the TCC databases take rows directly.
for service in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent kTCCServiceScreenCapture; do
  for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
    sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags)
      VALUES ('$service', '$RIG', 1, 2, 4, 1, 0);" || true
  done
done

echo "== display =="
swift "$ROOT/Scripts/autocomplete-demo/display.swift" > "$OUT/logs/main-display.txt" 2>&1 || true
tail -1 "$OUT/logs/main-display.txt"
"$WORK/vdisplay" "$DISPLAY_SIZE" "$WORK/display.id" > "$OUT/logs/vdisplay.txt" 2>&1 &
DISPLAY_PID=$!
for _ in $(seq 60); do
  [[ -s "$WORK/display.id" ]] && break
  kill -0 "$DISPLAY_PID" 2>/dev/null || break
  sleep 0.5
done
cat "$OUT/logs/vdisplay.txt"
if [[ -s "$WORK/display.id" ]]; then
  RIG_DISPLAY=$(tr -d '[:space:]' < "$WORK/display.id")
  export RIG_DISPLAY
  echo "filming on the 2x display $RIG_DISPLAY"
else
  DISPLAY_PID=
  echo "no 2x display; filming at 1x on the main display"
fi
swift "$HERE/cursors.swift" "$OUT/cursors" || echo "no pointer images"

echo "== library =="
python3 "$ROOT/Scripts/readme-gif/seed_library.py" "$WORK/library"

take_env() {
  case $1 in
    flow|ask) echo "LOKALBOT_INITIAL_SECTION=ask LOKALBOT_RESET_SPLIT_VIEWS=1" ;;
    meeting) echo "LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=1 LOKALBOT_DETAIL_TAB=summary LOKALBOT_RESET_SPLIT_VIEWS=1" ;;
    *) echo "unknown take $1" >&2; return 2 ;;
  esac
}

# launch_host <take> <run>: the host on a fresh copy of the library, with its
# own UserDefaults suite.
launch_host() {
  local lib="$WORK/run-$2" suite
  suite="lokalbot.ugc-film.$(uuidgen)"
  quit_host
  rm -rf "$lib"
  cp -R "$WORK/library" "$lib"
  touch "$WORK/suite.$suite"
  local -a envs=(--env LOKALBOT_UI_TEST=1 --env "LOKALBOT_STORAGE_ROOT=$lib" --env "LOKALBOT_DEFAULTS_SUITE=$suite"
                 --env LOKALBOT_CAPTURE_APPEARANCE=light --env LOKALBOT_DISMISS_ONBOARDING=1
                 --env LOKALBOT_SCREEN_MEMORY_DEMO=1)
  local kv
  for kv in $(take_env "$1"); do envs+=(--env "$kv"); done
  open -n -a "$HOST_APP" "${envs[@]}" --args -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" \
    -AppleLocale en_US --lokalbot-ui-test --lokalbot-storage-root "$lib" --lokalbot-defaults-suite "$suite"
  sleep 5
}

failed=0
for take in "$@"; do
  [[ $take == follow-up ]] && continue
  shot="$HERE/shots/$take.json"
  echo "== $take =="
  # The work folder's path has no spaces, so the list splits on newlines.
  for probe in $(python3 "$HERE/probes.py" "$shot" "$WORK/probes"); do
    name=$(basename "$probe" .json)
    launch_host "$take" "$name"
    RIG_BACKGROUND="#EAEEF2" "$RIG" probe "$probe" "$OUT/probes/$name" 2>&1 | tee -a "$OUT/logs/probes.log" || true
    quit_host
  done
  status=1
  for attempt in 1 2 3; do
    launch_host "$take" "$take-$attempt"
    status=0
    RIG_BACKGROUND="#EAEEF2" "$RIG" take "$shot" "$OUT/takes/$take" 2>&1 | tee "$OUT/logs/rig-$take.log" || status=$?
    quit_host
    [[ $status -eq 0 && -s "$OUT/takes/$take/take.json" ]] && break
    status=1
    echo "$take attempt $attempt failed"
  done
  if [[ $status -eq 0 ]]; then
    python3 "$ROOT/Scripts/autocomplete-demo/encode.py" "$OUT/takes/$take" "$OUT/clips/$take.mp4"
    rm -rf "$OUT/takes/$take/frames"
  else
    failed=$((failed + 1))
  fi
done

if [[ " $* " == *" follow-up "* ]]; then
  echo "== follow-up =="
  status=0
  SHOTS="$HERE/shots" FONT_SIZE=${FONT_SIZE:-26} \
    bash "$ROOT/Scripts/autocomplete-demo/film.sh" "$OUT/autocomplete" follow-up || status=$?
  if [[ $status -eq 0 && -s "$OUT/autocomplete/clips/light-follow-up.mp4" ]]; then
    cp "$OUT/autocomplete/clips/light-follow-up.mp4" "$OUT/clips/follow-up.mp4"
    cp "$OUT/autocomplete/clips/light-follow-up.json" "$OUT/clips/follow-up.json"
  else
    echo "follow-up failed ($status)"
    failed=$((failed + 1))
  fi
fi
ls -l "$OUT/clips"
echo "$failed takes failed"
[[ -n "$(ls "$OUT/clips"/*.mp4 2>/dev/null)" ]]
