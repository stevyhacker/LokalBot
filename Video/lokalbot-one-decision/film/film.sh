#!/bin/bash
# Films the One Decision takes on your own Mac: the real app in the UI Test Host, the
# on-device models, a fictional library. It changes no system settings and closes no
# other app's windows; it stops only the host it started, the host's model helpers and
# the TextEdit it opened. An installed LokalBot keeps running on its own ports and data,
# though it can see the demo windows and the typing: turn its Autocomplete off first,
# or the autocomplete take is skipped (two apps would answer the same Tab).
#
#   UI_HOST_APP=<LokalBot UI Test Host.app> RIG_DISPLAY=<a 2x display's id> \
#     film.sh <out-dir> prepare|live|notes|search|timeline|autocomplete|dictation|probe <shot> ...
#     film.sh <out-dir> restore <recorded meeting folder>   a later session: the library as it was
#
# Takes are filmed one at a time so each can be checked before the next: `live` records
# the call and waits for its notes, and every later take runs on that recorded library.
# To film more takes another day, `restore` seeds the library again with STAGE_NOW set to the
# first session's time and FILM_TZ to its zone, and puts the recorded call back in it.
# `dictation` hears <out-dir>/work/spoken/mic.wav (stage.py spoken) and holds Option-Shift.
# Keep <out-dir> and the host outside ~/Documents. The shell needs Accessibility, Input
# Monitoring and Screen Recording. Touching the Mac aborts a take, which is filmed again.
# Audio comes from WAV files, never the microphone.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
HOST_APP=$(cd "${UI_HOST_APP:?set UI_HOST_APP to a built LokalBot UI Test Host.app}" && pwd)
HOST_BIN="$HOST_APP/Contents/MacOS/"
HOST_EXE="$HOST_APP/Contents/MacOS/LokalBot UI Test Host"
HOST_ID=me.dotenv.LokalBot.uitesthost
HELPERS='me\.dotenv\.LokalBot\.uitesthost/llama-cpp/.*llama-server'
export RIG_DISPLAY=${RIG_DISPLAY:?set RIG_DISPLAY to a 2x display id}
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
shift
WORK=$OUT/work
RIG=$WORK/rig
APPEARANCE=${APPEARANCE:-light}
BACKGROUND=${BACKGROUND:-#FFFFFF}
mkdir -p "$WORK" "$OUT/logs" "$OUT/clips" "$OUT/takes" "$OUT/trees" "$OUT/probe"
caffeinate -dims -w $$ &
TEXTEDIT_PID=

quit_host() {
  pkill -f "^$HOST_BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "^$HOST_BIN" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "^$HOST_BIN" 2>/dev/null || true
  pkill -f "$HELPERS" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$HELPERS" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "$HELPERS" 2>/dev/null || true
  sleep 0.5
}
quit_textedit() {  # only the TextEdit this script opened
  [[ -n "$TEXTEDIT_PID" ]] && kill "$TEXTEDIT_PID" 2>/dev/null
  TEXTEDIT_PID=
  sleep 0.5
}
cleanup() {
  quit_textedit
  quit_host
  for suite in "$WORK"/suite.*; do
    [[ -e "$suite" ]] && { defaults delete "${suite##*/suite.}" >/dev/null 2>&1 || true; rm -f "$suite"; }
  done
}
trap cleanup EXIT

FILM_TZ=${FILM_TZ:-$(cat "$WORK/timezone" 2>/dev/null || python3 "$HERE/stage.py" timezone)}
export TZ=$FILM_TZ

prepare() {
  echo "$FILM_TZ" > "$WORK/timezone"
  [[ -x "$RIG" ]] || swiftc -O -swift-version 5 "$ROOT/Scripts/readme-gif/rig.swift" -o "$RIG" || exit 1
  if [[ ! -d "$WORK/world" ]]; then
    python3 "$HERE/stage.py" library "$WORK/world" || exit 1
    python3 "$HERE/stage.py" models "$WORK/world" || exit 1
    python3 "$HERE/stage.py" audio "$WORK/call" || exit 1
  fi
  echo "prepared: $WORK (zone $FILM_TZ)"
}

library() { [[ -d "$WORK/recorded" ]] && echo "$WORK/recorded" || echo "$WORK/world"; }

host_args() {  # the launch arguments every host run shares
  printf '%s\n' -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" -AppleLocale en_US \
    -AppleShowScrollBars WhenScrolling -NSAutomaticInlinePredictionEnabled NO \
    -NSAutomaticSpellingCorrectionEnabled NO -NSAutomaticTextCompletionEnabled NO -AppleICUForce24HourTime NO \
    --lokalbot-ui-test --lokalbot-storage-root "$1" --lokalbot-defaults-suite "$2"
}

# launch_host <library> <profile> [ENV=VALUE ...]: the host on a fresh copy of a library.
# DIRECT=1 starts it as a child of this shell, so macOS holds the shell responsible for
# its permissions (autocomplete reads another app's text field).
launch_host() {
  local source=$1 profile=$2 run suite kv
  shift 2
  quit_host
  run=$(mktemp -d "$WORK/run.XXXXXX")
  cp -cR "$source/." "$run/" 2>/dev/null || cp -R "$source/." "$run/"
  suite="lokalbot.landing-film.$(uuidgen)"
  touch "$WORK/suite.$suite"
  python3 "$HERE/stage.py" settings "$suite" "$profile" || return 1
  defaults write "$HOST_ID" lokalbotv3.onboarding.shown -bool YES
  local -a pairs=(LOKALBOT_UI_TEST=1 "TZ=$FILM_TZ" "LOKALBOT_STORAGE_ROOT=$run" "LOKALBOT_DEFAULTS_SUITE=$suite"
                  "LOKALBOT_CAPTURE_APPEARANCE=$APPEARANCE" LOKALBOT_DISMISS_ONBOARDING=1
                  LOKALBOT_SCREEN_MEMORY_DEMO=1 LOKALBOT_RESET_SPLIT_VIEWS=1 "$@")
  local -a args=()
  while IFS= read -r kv; do args+=("$kv"); done < <(host_args "$run" "$suite")
  if [[ "${DIRECT:-0}" == 1 ]]; then
    env "${pairs[@]}" "$HOST_EXE" "${args[@]}" >> "$OUT/logs/host-stdout.log" 2>&1 &
  else
    local -a envs=()
    for kv in "${pairs[@]}"; do envs+=(--env "$kv"); done
    open -n -a "$HOST_APP" "${envs[@]}" --args "${args[@]}"
  fi
  sleep 5
  LAST_RUN=$run
  echo "$run" > "$WORK/last-run"
}

keep_logs() { [[ -f "${LAST_RUN:-}/debug.log" ]] && cp "$LAST_RUN/debug.log" "$OUT/logs/debug-$1.log" || true; }

rig_take() {  # rig_take <take>: records and encodes; 0 on success
  local dest="$OUT/takes/$1" status=0
  rm -rf "$dest" "$OUT/trees/$1"; mkdir -p "$dest"
  RIG_TREE_DIR="$OUT/trees/$1" RIG_BACKGROUND=$BACKGROUND "$RIG" take "$HERE/shots/$1.json" "$dest" 2>&1 | tee -a "$OUT/logs/rig-$1.log"
  status=${PIPESTATUS[0]}
  if [[ $status -eq 0 && -s "$dest/take.json" ]]; then
    python3 "$ROOT/Scripts/autocomplete-demo/encode.py" "$dest" "$OUT/clips/$1.mp4" || status=1
    rm -rf "$dest/frames"
  fi
  return $status
}

open_textedit() {  # open_textedit <document>: a TextEdit of our own, at a size a film can read
  pgrep -x TextEdit >/dev/null && { echo "TextEdit is already open; close it first"; return 1; }
  open -a TextEdit "$1" --args -RichText NO -NSFixedPitchFont HelveticaNeue -NSFixedPitchFontSize "${FONT_SIZE:-36}" \
    -CheckSpellingWhileTyping NO -CheckGrammarWithSpelling NO -SmartQuotes NO -SmartDashes NO -TextReplacement NO \
    -NSAutomaticInlinePredictionEnabled NO -NSAutomaticSpellingCorrectionEnabled NO -NSAutomaticTextCompletionEnabled NO \
    -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
  for _ in $(seq 20); do TEXTEDIT_PID=$(pgrep -x TextEdit) && break; sleep 0.25; done
  sleep 2
}

installed_autocomplete_on() {  # true while the installed LokalBot would also answer Tab
  pgrep -f "^/Applications/LokalBot.app/" >/dev/null || return 1
  defaults export me.dotenv.LokalBot - 2>/dev/null | plutil -extract 'lokalbotv3\.settings' raw -o - - 2>/dev/null \
    | base64 -d 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("cotypingEnabled") else 1)'
}

status=0
command=${1:?a command}
shift
case $command in
  prepare) prepare ;;
  restore)
    prepare
    rm -rf "$WORK/recorded"
    cp -cR "$WORK/world" "$WORK/recorded"
    python3 "$HERE/stage.py" adopt "$WORK/recorded" "${1:?the recorded meeting folder}" || exit 1
    ;;
  live)
    prepare
    rm -rf "$WORK/recorded"
    launch_host "$WORK/world" meeting LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_UI_TEST_BACKGROUND=1 \
      "LOKALBOT_UI_TEST_AUDIO=$WORK/call" "LOKALBOT_UI_TEST_TRACE=$ROOT/Video/lokalbot-landing-demos/film/call-trace.json" || exit 1
    rig_take live || status=$?
    if [[ $status -eq 0 ]]; then
      # The recorded call's real notes are what every later take shows.
      if folder=$(python3 "$HERE/stage.py" wait-notes "$LAST_RUN" "$WORK/world" "${NOTES_TIMEOUT:-300}"); then
        python3 "$HERE/stage.py" polish "$folder"
        rm -rf "$OUT/recorded"; mkdir -p "$OUT/recorded"; cp -R "$folder" "$OUT/recorded/"
        sleep 3
        keep_logs live
        quit_host
        cp -cR "$LAST_RUN" "$WORK/recorded"
      else
        status=7
      fi
    fi
    keep_logs live
    ;;
  notes)
    launch_host "$(library)" fixture LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary || exit 1
    rig_take "${1:-notes}" || status=$?
    keep_logs notes
    ;;
  search)
    launch_host "$(library)" fixture LOKALBOT_UI_TEST_WINDOW=quick-recall || exit 1
    rig_take search || status=$?
    keep_logs search
    ;;
  timeline)
    launch_host "$(library)" fixture LOKALBOT_INITIAL_SECTION=timeline || exit 1
    rig_take timeline || status=$?
    keep_logs timeline
    ;;
  dictation)
    [[ -s "$WORK/spoken/mic.wav" ]] || { echo "no $WORK/spoken/mic.wav: run stage.py spoken first"; exit 1; }
    DIRECT=1 launch_host "$(library)" dictation LOKALBOT_UI_TEST_BACKGROUND=1 "LOKALBOT_UI_TEST_AUDIO=$WORK/spoken" || exit 1
    sleep 8
    # The first dictation of a launch loads the speech and writing models; film the second.
    for shot in ${*:-dictation-warmup dictation}; do
      doc=$(python3 "$HERE/stage.py" document "$WORK/docs" Notes.txt "") || exit 1
      open_textedit "$doc" || exit 1
      rig_take "$shot" || status=$?
      quit_textedit
      [[ $status -eq 0 ]] || break
    done
    keep_logs dictation
    ;;
  autocomplete)
    if installed_autocomplete_on; then echo "the installed LokalBot's Autocomplete is on; skipped"; exit 8; fi
    DIRECT=1 launch_host "$(library)" autocomplete LOKALBOT_UI_TEST_BACKGROUND=1 LOKALBOT_TEST_FILM_GHOST=1 \
      "LOKALBOT_UI_TEST_AUDIO=$WORK/call" || exit 1
    sleep 6
    for shot in ${*:-warmup autocomplete}; do
      doc=$(python3 "$HERE/stage.py" document "$WORK/docs") || exit 1
      open_textedit "$doc" || exit 1
      rig_take "$shot" || status=$?
      quit_textedit
      [[ $status -eq 0 ]] || break
    done
    keep_logs autocomplete
    ;;
  probe)  # probe <shot> <launch command words...>: the accessibility tree and one frame, nothing recorded
    shot=$1; shift
    case ${1:-notes} in
      notes) launch_host "$(library)" fixture LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary ;;
      search) launch_host "$(library)" fixture LOKALBOT_UI_TEST_WINDOW=quick-recall ;;
      meetings) launch_host "$(library)" fixture LOKALBOT_INITIAL_SECTION=meetings ;;
      timeline) launch_host "$(library)" fixture LOKALBOT_INITIAL_SECTION=timeline ;;
    esac
    RIG_BACKGROUND=$BACKGROUND "$RIG" probe "$HERE/shots/$shot.json" "$OUT/probe/$shot" || status=$?
    ;;
  *) echo "unknown command $command"; exit 2 ;;
esac
echo "$command: $status" | tee -a "$OUT/logs/results.txt"
exit $status
