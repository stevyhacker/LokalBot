#!/bin/bash
# Films the recorded-call and Ask takes on your own Mac, where a real GPU turns half an
# hour of model time into seconds. Unlike film.sh it changes no system settings, closes no
# other app's windows, and stops only the UI Test Host and its helpers. An installed LokalBot
# keeps running on its own ports and data, though it can see the demo windows and typing.
#
#   UI_HOST_APP=<LokalBot UI Test Host.app> RIG_DISPLAY=<a 2x display's id> \
#     film-local.sh <out-dir> [live|notes|notes-tall|ask|ask-tall[@appearance]]...
#
# Keep <out-dir> and the host outside ~/Documents, which an ad-hoc signed host must ask to
# read. The shell needs Accessibility, Input Monitoring and Screen Recording. Touching the
# Mac aborts a take, which is then filmed again. Audio comes from WAV files, never the
# microphone. Dictation stays on hosted Macs: its shortcut would also reach an installed
# LokalBot, and a dark TextEdit needs the whole system in dark mode.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
HOST_APP=$(cd "${UI_HOST_APP:?set UI_HOST_APP to a built LokalBot UI Test Host.app}" && pwd)
HOST_BIN="$HOST_APP/Contents/MacOS/"
HOST_ID=me.dotenv.LokalBot.uitesthost
HELPERS='me\.dotenv\.LokalBot\.uitesthost/llama-cpp/.*llama-server'
export RIG_DISPLAY=${RIG_DISPLAY:?set RIG_DISPLAY to a 2x display id}
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
shift
if [[ $# -eq 0 ]]; then set -- live notes notes-tall ask ask-tall; fi
WORK=$OUT/work
RIG=$WORK/rig
mkdir -p "$WORK/models" "$OUT/logs" "$OUT/clips" "$OUT/takes" "$OUT/recorded"
caffeinate -dims -w $$ &

quit_host() {
  pkill -f "^$HOST_BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "^$HOST_BIN" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "^$HOST_BIN" 2>/dev/null || true
  pkill -f "$HELPERS" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$HELPERS" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "$HELPERS" 2>/dev/null || true
  sleep 0.5
}
cleanup() {
  quit_host
  for suite in "$WORK"/suite.*; do
    [[ -e "$suite" ]] && { defaults delete "${suite##*/suite.}" >/dev/null 2>&1 || true; rm -f "$suite"; }
  done
}
trap cleanup EXIT

swiftc -O -swift-version 5 "$ROOT/Scripts/media/readme-gif/rig.swift" -o "$RIG" || exit 1
FILM_TZ=$(python3 "$HERE/stage.py" timezone)
export TZ=$FILM_TZ
if [[ ! -d "$WORK/studio" ]]; then
  python3 "$HERE/stage.py" library studio "$WORK/studio" || exit 1
  # Clones of an installed LokalBot's models save the download; stage.py checks their digests.
  cp -cn "$HOME/Library/Application Support/me.dotenv.LokalBot/models/"{Qwen3.5-4B-Q4_K_M,embeddinggemma-2-Q8_0}.gguf "$WORK/models/" 2>/dev/null || true
  python3 "$HERE/stage.py" models "$WORK/models" "$WORK/studio" || exit 1
  python3 "$HERE/stage.py" audio "$WORK/call" call || exit 1
fi

background() { [[ $1 == dark ]] && echo "#0E1720" || echo "#E6F0EF"; }

launch_host() {  # launch_host <appearance> <library> <profile> [ENV=VALUE ...]: the host on a fresh copy of a library
  local appearance=$1 source=$2 profile=$3 run suite kv
  shift 3
  quit_host
  run=$(mktemp -d "$WORK/run.XXXXXX")
  cp -cR "$source/." "$run/" 2>/dev/null || cp -R "$source/." "$run/"
  suite="lokalbot.landing-film.$(uuidgen)"
  touch "$WORK/suite.$suite"
  python3 "$HERE/stage.py" settings "$suite" "$profile" || return 1
  defaults write "$HOST_ID" lokalbotv3.onboarding.shown -bool YES
  local -a envs=(--env LOKALBOT_UI_TEST=1 --env "TZ=$FILM_TZ" --env "LOKALBOT_STORAGE_ROOT=$run" --env "LOKALBOT_DEFAULTS_SUITE=$suite"
                 --env "LOKALBOT_CAPTURE_APPEARANCE=$appearance" --env LOKALBOT_DISMISS_ONBOARDING=1
                 --env LOKALBOT_SCREEN_MEMORY_DEMO=1 --env LOKALBOT_RESET_SPLIT_VIEWS=1)
  for kv in "$@"; do envs+=(--env "$kv"); done
  open -n -a "$HOST_APP" "${envs[@]}" --args -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" \
    -AppleLocale en_US -AppleShowScrollBars WhenScrolling -NSAutomaticInlinePredictionEnabled NO \
    -NSAutomaticSpellingCorrectionEnabled NO -NSAutomaticTextCompletionEnabled NO -AppleICUForce24HourTime NO \
    --lokalbot-ui-test --lokalbot-storage-root "$run" --lokalbot-defaults-suite "$suite"
  sleep 5
  LAST_RUN=$run
}

keep_logs() { [[ -f "${LAST_RUN:-}/debug.log" ]] && cp "$LAST_RUN/debug.log" "$OUT/logs/debug-$1.log" || true; }

rig_take() {  # rig_take <appearance> <take>: records and encodes; 0 on success
  local dest="$OUT/takes/$1/$2" status=0
  rm -rf "$dest"; mkdir -p "$dest"
  RIG_BACKGROUND=$(background "$1") "$RIG" take "$HERE/shots/$2.json" "$dest" 2>&1 | tee -a "$OUT/logs/rig-$2.log"
  status=${PIPESTATUS[0]}
  if [[ $status -eq 0 && -s "$dest/take.json" ]]; then
    python3 "$ROOT/Scripts/media/autocomplete-demo/encode.py" "$dest" "$OUT/clips/$1-$2.mp4" || status=1
    rm -rf "$dest/frames"
  fi
  return $status
}

ask_take() {  # rig_take, stopped as soon as the app reports a failed answer
  local status=0 watcher
  ( until grep -q "chat response failed" "$LAST_RUN/debug.log" 2>/dev/null; do sleep 2; done
    pkill -f "^$RIG take" ) &
  watcher=$!
  rig_take "$1" "$2" || status=$?
  kill "$watcher" 2>/dev/null || true
  return $status
}

failed=()
for spec in "$@"; do
  name=${spec%@*}
  appearances="light dark"
  [[ $spec == *@* ]] && appearances=${spec#*@}
  for appearance in $appearances; do
    status=1
    for attempt in 1 2 3; do
      case $name in
        notes|notes-tall)
          library="$WORK/studio"
          [[ -d "$WORK/recorded" ]] && library="$WORK/recorded"
          launch_host "$appearance" "$library" fixture LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary || continue
          status=0; rig_take "$appearance" "$name" || status=$?
          ;;
        live)
          launch_host "$appearance" "$WORK/studio" meeting LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_UI_TEST_BACKGROUND=1 \
            "LOKALBOT_UI_TEST_AUDIO=$WORK/call" "LOKALBOT_UI_TEST_TRACE=$HERE/call-trace.json" || continue
          status=0; rig_take "$appearance" live || status=$?
          # The first recorded call's real notes are what the notes takes show.
          if [[ $status -eq 0 && ! -d "$WORK/recorded" ]]; then
            if folder=$(python3 "$HERE/stage.py" wait-notes "$LAST_RUN" "$WORK/studio" "${NOTES_TIMEOUT:-1200}"); then
              python3 "$HERE/stage.py" polish "$folder"
              cp -R "$folder" "$OUT/recorded/"
              sleep 3
              cp -cR "$LAST_RUN" "$WORK/recorded"
            else
              failed+=("live-notes")
            fi
          fi
          ;;
        ask|ask-tall)
          launch_host "$appearance" "$WORK/studio" ask LOKALBOT_INITIAL_SECTION=ask LOKALBOT_UI_TEST_BACKGROUND=1 || continue
          status=0; ask_take "$appearance" "$name" || status=$?
          ;;
        *) echo "unknown take $name"; break ;;
      esac
      keep_logs "$name-$appearance"
      quit_host
      [[ $status -eq 0 ]] && break
      echo "$name/$appearance attempt $attempt failed ($status)"
    done
    [[ $status -eq 0 ]] || failed+=("$name/$appearance")
  done
done
ls -l "$OUT/clips"
echo "failed: ${failed[*]:-none}" | tee "$OUT/logs/failed.txt"
