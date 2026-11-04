#!/bin/bash
# Films the landing page's demo clips on a hosted Mac in GitHub Actions: the real
# app on fictional libraries, at 2x on a virtual Retina display, without the
# system pointer and with the pointer's path logged, so the edit (compose.py)
# draws a smooth pointer and moves its camera with it.
#
#   UI_HOST_APP=<LokalBot UI Test Host.app> LOKALBOT_APP=<Debug LokalBot.app> \
#     film.sh <out-dir> [take...]
#
# Takes (shots/*.json):
#   search today timeline people notes stills   the host on seeded data
#   live ask dictation files                    the host's background mode: real pipelines
#                                               and local models, with WAV files for the
#                                               microphone and the call's system audio
#   autocomplete                                the Debug app in TextEdit (Scripts/autocomplete-demo/film.sh)
#
# Writes <out>/clips/<appearance>-<take>.mp4 (30 fps, 4:4:4) with <take>.json (rect,
# scale, events, pointer path), <out>/probes/ (the accessibility tree and a frame at
# each `mark`), <out>/stills/ and <out>/logs/. A take that fails is reported and skipped.
#
# CI only: it grants the rig's TCC permissions with sudo.
set -uo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "film.sh changes system settings; run it in GitHub Actions" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
HOST_APP=$(cd "${UI_HOST_APP:?set UI_HOST_APP to a built LokalBot UI Test Host.app}" && pwd)
HOST_BIN="$HOST_APP/Contents/MacOS/"
HOST_ID=me.dotenv.LokalBot.uitesthost
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
shift
if [[ $# -eq 0 ]]; then set -- search today timeline people notes stills live ask dictation files autocomplete; fi
APPEARANCES=${APPEARANCES:-light dark}
PROBE=${PROBE:-0}
WORK=$(cd "$(mktemp -d "${RUNNER_TEMP:-/tmp}/landing-film.XXXXXX")" && pwd -P)
RIG="$WORK/rig"
DISPLAY_SIZE=${DISPLAY_SIZE:-1400x1000}
mkdir -p "$OUT/logs" "$OUT/clips" "$OUT/takes" "$OUT/probes" "$OUT/stills" "$OUT/recorded"
export FILM_FILES="$WORK/files"

quit_host() {
  pkill -f "$HOST_BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$HOST_BIN" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "$HOST_BIN" 2>/dev/null || true
  pkill -f llama-server 2>/dev/null || true
  sleep 0.5
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
swiftc -O -swift-version 5 "$ROOT/Scripts/readme-gif/rig.swift" -o "$RIG" || exit 1
clang -fobjc-arc -O2 -framework Foundation -framework CoreGraphics "$HERE/vdisplay.m" -o "$WORK/vdisplay" || exit 1

echo "== permissions =="
# Hosted images run with SIP off, so the TCC databases take rows directly.
grant() {  # grant <client> <client_type: 0 bundle id, 1 path>
  local service db
  for service in kTCCServiceAccessibility kTCCServiceListenEvent kTCCServicePostEvent kTCCServiceScreenCapture kTCCServiceMicrophone kTCCServiceAudioCapture; do
    for db in "/Library/Application Support/com.apple.TCC/TCC.db" "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
      sudo sqlite3 "$db" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, flags)
        VALUES ('$service', '$1', $2, 2, 4, 1, 0);" 2>/dev/null || true
    done
  done
}
grant "$RIG" 1
grant "$HOST_ID" 0
grant "$HOST_BIN/LokalBot UI Test Host" 1

echo "== text defaults =="
defaults write -g NSAutomaticInlinePredictionEnabled -bool false
defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
defaults write -g NSAutomaticTextCompletionEnabled -bool false
defaults write com.apple.dock autohide -bool true; killall Dock 2>/dev/null || true

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

FILM_TZ=$(python3 "$HERE/stage.py" timezone)
export TZ=$FILM_TZ
echo "== libraries (TZ=$FILM_TZ, $(date)) =="
python3 "$HERE/stage.py" library studio "$WORK/studio" || exit 1
python3 "$HERE/stage.py" library pricing "$WORK/pricing" || exit 1
python3 "$HERE/stage.py" audio "$WORK/call" call || exit 1
python3 "$HERE/stage.py" audio "$WORK/spoken" dictation || exit 1
python3 "$HERE/stage.py" files "$WORK/files" || exit 1
say -v '?' | grep -E '^(Samantha|Daniel)' > "$OUT/logs/voices.txt" || true
cp "$WORK"/call/*.wav "$OUT/logs/" 2>/dev/null || true

needs_models=0
for take in "$@"; do case $take in live|ask|dictation|files) needs_models=1;; esac; done
if [[ $needs_models -eq 1 ]]; then
  echo "== models =="
  python3 "$HERE/stage.py" models "$WORK/models" "$WORK/studio" "$WORK/pricing" || exit 1
  ls -la "$WORK/models"
fi

background() { [[ $1 == dark ]] && echo "#0E1720" || echo "#E6F0EF"; }

# launch_host <appearance> <library> <profile> [ENV=VALUE ...]: the host on a fresh copy of a library.
launch_host() {
  local appearance=$1 source=$2 profile=$3 run suite
  shift 3
  quit_host
  run=$(mktemp -d "$WORK/run.XXXXXX")
  cp -cR "$source/." "$run/" 2>/dev/null || cp -R "$source/." "$run/"
  suite="lokalbot.landing-film.$(uuidgen)"
  touch "$WORK/suite.$suite"
  python3 "$HERE/stage.py" settings "$suite" "$profile" || return 1
  defaults write "$HOST_ID" lokalbotv3.onboarding.shown -bool YES
  if [[ $appearance == dark ]]; then defaults write -g AppleInterfaceStyle Dark; else defaults delete -g AppleInterfaceStyle 2>/dev/null || true; fi
  local -a envs=(--env LOKALBOT_UI_TEST=1 --env "TZ=$FILM_TZ" --env "LOKALBOT_STORAGE_ROOT=$run" --env "LOKALBOT_DEFAULTS_SUITE=$suite"
                 --env "LOKALBOT_CAPTURE_APPEARANCE=$appearance" --env LOKALBOT_DISMISS_ONBOARDING=1
                 --env LOKALBOT_SCREEN_MEMORY_DEMO=1 --env LOKALBOT_RESET_SPLIT_VIEWS=1)
  local kv
  for kv in "$@"; do envs+=(--env "$kv"); done
  open -n -a "$HOST_APP" "${envs[@]}" --args -ApplePersistenceIgnoreState YES -AppleLanguages "(en)" \
    -AppleLocale en_US --lokalbot-ui-test --lokalbot-storage-root "$run" --lokalbot-defaults-suite "$suite"
  sleep 6
  LAST_RUN=$run
}

keep_logs() {  # keep_logs <name>
  [[ -n "${LAST_RUN:-}" && -f "$LAST_RUN/debug.log" ]] && cp "$LAST_RUN/debug.log" "$OUT/logs/debug-$1.log" || true
}

# rig_take <appearance> <take> <shot>: records and encodes; 0 on success
rig_take() {
  local appearance=$1 take=$2 shot=$3 dest="$OUT/takes/$1/$2" status=0
  rm -rf "$dest"; mkdir -p "$dest"
  RIG_BACKGROUND=$(background "$appearance") "$RIG" take "$shot" "$dest" 2>&1 | tee -a "$OUT/logs/rig-$take.log"
  status=${PIPESTATUS[0]}
  if [[ $status -eq 0 && -s "$dest/take.json" ]]; then
    python3 "$ROOT/Scripts/autocomplete-demo/encode.py" "$dest" "$OUT/clips/$appearance-$take.mp4" || status=1
    rm -rf "$dest/frames"
  fi
  return $status
}

# probes <appearance> <take> <library> <profile> [ENV...]: the tree and a frame at each mark
probes() {
  local appearance=$1 take=$2 library=$3 profile=$4 probe name
  shift 4
  [[ $PROBE == 1 ]] || return 0
  for probe in $(python3 "$HERE/probes.py" "$HERE/shots/$take.json" "$WORK/probes"); do
    name=$(basename "$probe" .json)
    launch_host "$appearance" "$library" "$profile" "$@" || continue
    RIG_BACKGROUND=$(background "$appearance") "$RIG" probe "$probe" "$OUT/probes/$name" 2>&1 | tee -a "$OUT/logs/probes.log" || true
    quit_host
  done
}

failed=()
film_seeded() {  # film_seeded <take> <library> ENV...: filmed on seeded data in each appearance
  local take=$1 library=$2 appearance attempt status
  shift 2
  echo "== $take =="
  first=1
  for appearance in $APPEARANCES; do
    [[ $first == 1 ]] && probes "$appearance" "$take" "$library" fixture "$@"
    first=0
    status=1
    for attempt in 1 2; do
      launch_host "$appearance" "$library" fixture "$@" || continue
      status=0; rig_take "$appearance" "$take" "$HERE/shots/$take.json" || status=$?
      keep_logs "$take-$appearance"
      quit_host
      [[ $status -eq 0 ]] && break
      echo "$take/$appearance attempt $attempt failed ($status)"
    done
    [[ $status -eq 0 ]] || failed+=("$take/$appearance")
  done
}

for take in "$@"; do
  case $take in
    search) film_seeded search "$WORK/studio" LOKALBOT_UI_TEST_WINDOW=quick-recall ;;
    today) film_seeded today "$WORK/studio" LOKALBOT_INITIAL_SECTION=today ;;
    timeline) film_seeded timeline "$WORK/studio" LOKALBOT_INITIAL_SECTION=timeline ;;
    people) film_seeded people "$WORK/studio" LOKALBOT_INITIAL_SECTION=people ;;
    notes)
      # The recorded call's real notes when the live take made them, else the seeded holiday shoot.
      library="$WORK/studio"
      [[ -d "$WORK/recorded" ]] && library="$WORK/recorded"
      film_seeded notes "$library" LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary
      ;;
    stills)
      echo "== stills =="
      for appearance in $APPEARANCES; do
        launch_host "$appearance" "$WORK/studio" fixture LOKALBOT_UI_TEST_WINDOW=quick-recall "LOKALBOT_QUICK_RECALL_QUERY=demo presentation" || continue
        RIG_BACKGROUND=$(background "$appearance") "$RIG" still "$HERE/shots/still-recall.json" "$OUT/stills/quick-recall-$appearance.png" || failed+=("still-recall/$appearance")
        launch_host "$appearance" "$WORK/studio" fixture LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary || continue
        RIG_BACKGROUND=$(background "$appearance") "$RIG" still "$HERE/shots/still-meeting.json" "$OUT/stills/meetings-summary-$appearance.png" || failed+=("still-meeting/$appearance")
        quit_host
      done
      ;;
    live)
      echo "== live =="
      first=1
      for appearance in $APPEARANCES; do
        launch_host "$appearance" "$WORK/studio" meeting LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_UI_TEST_BACKGROUND=1 "LOKALBOT_UI_TEST_AUDIO=$WORK/call" || continue
        status=0; rig_take "$appearance" live "$HERE/shots/live.json" || status=$?
        [[ $status -eq 0 ]] || failed+=("live/$appearance")
        if [[ $first == 1 ]]; then
          echo "waiting for the recorded call's notes"
          if folder=$(python3 "$HERE/stage.py" wait-notes "$LAST_RUN" "${NOTES_TIMEOUT:-1500}"); then
            python3 "$HERE/stage.py" polish "$folder"
            cp -R "$folder" "$OUT/recorded/"
            sleep 3
            rm -rf "$WORK/recorded"; cp -R "$LAST_RUN" "$WORK/recorded"
          else
            failed+=("live-notes")
          fi
        fi
        first=0
        keep_logs "live-$appearance"
        quit_host
      done
      ;;
    ask)
      echo "== ask =="
      for appearance in $APPEARANCES; do
        launch_host "$appearance" "$WORK/studio" ask LOKALBOT_INITIAL_SECTION=ask LOKALBOT_UI_TEST_BACKGROUND=1 || continue
        status=0; rig_take "$appearance" ask "$HERE/shots/ask.json" || status=$?
        [[ $status -eq 0 ]] || failed+=("ask/$appearance")
        keep_logs "ask-$appearance"
        quit_host
      done
      ;;
    dictation)
      echo "== dictation =="
      for appearance in $APPEARANCES; do
        launch_host "$appearance" "$WORK/pricing" dictation LOKALBOT_UI_TEST_BACKGROUND=1 "LOKALBOT_UI_TEST_AUDIO=$WORK/spoken" || continue
        sleep 10
        doc="$WORK/Team update.txt"; : > "$doc"
        textedit=(-RichText NO -NSFixedPitchFont HelveticaNeue -NSFixedPitchFontSize 30 -CheckSpellingWhileTyping NO -CheckGrammarWithSpelling NO
                  -SmartQuotes NO -SmartDashes NO -TextReplacement NO -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO)
        [[ $appearance == dark ]] && textedit+=(-AppleInterfaceStyle Dark)
        pkill -x TextEdit 2>/dev/null || true; sleep 0.5
        open -a TextEdit "$doc" --args "${textedit[@]}"
        sleep 2
        status=0; rig_take "$appearance" dictation "$HERE/shots/dictation.json" || status=$?
        [[ $status -eq 0 ]] || failed+=("dictation/$appearance")
        pkill -x TextEdit 2>/dev/null || true
        keep_logs "dictation-$appearance"
        quit_host
      done
      ;;
    files)
      echo "== files =="
      for appearance in $APPEARANCES; do
        library="$WORK/studio"
        [[ -d "$WORK/indexed" ]] && library="$WORK/indexed"
        launch_host "$appearance" "$library" files LOKALBOT_UI_TEST_BACKGROUND=1 LOKALBOT_UI_TEST_WINDOW=quick-recall || continue
        if [[ ! -d "$WORK/indexed" ]]; then
          echo "waiting for Files to read the folder"
          for _ in $(seq 180); do
            db=$(find "$LAST_RUN/files-index.noindex" -name '*.sqlite*' -size +100k 2>/dev/null | head -1)
            [[ -n "$db" ]] && grep -q "file pass finished\|pass finished\|index up to date" "$LAST_RUN/debug.log" 2>/dev/null && break
            sleep 5
          done
          ls -la "$LAST_RUN/files-index.noindex" 2>/dev/null || true
          grep -iE "file|digup" "$LAST_RUN/debug.log" 2>/dev/null | tail -20 || true
          cp -cR "$LAST_RUN" "$WORK/indexed" 2>/dev/null || cp -R "$LAST_RUN" "$WORK/indexed"
        fi
        status=0; rig_take "$appearance" files "$HERE/shots/files.json" || status=$?
        [[ $status -eq 0 ]] || failed+=("files/$appearance")
        keep_logs "files-$appearance"
        quit_host
      done
      ;;
    autocomplete)
      echo "== autocomplete =="
      status=0
      APPEARANCES="$APPEARANCES" SHOTS="$HERE/shots-autocomplete" FONT_SIZE=34 \
        BACKGROUND_LIGHT="$(background light)" BACKGROUND_DARK="$(background dark)" \
        LOKALBOT_APP="${LOKALBOT_APP:?set LOKALBOT_APP to a Debug LokalBot.app}" \
        bash "$ROOT/Scripts/autocomplete-demo/film.sh" "$OUT/autocomplete" memory || status=$?
      for appearance in $APPEARANCES; do
        cp "$OUT/autocomplete/clips/$appearance-memory.mp4" "$OUT/clips/$appearance-autocomplete.mp4" 2>/dev/null || status=1
        cp "$OUT/autocomplete/clips/$appearance-memory.json" "$OUT/clips/$appearance-autocomplete.json" 2>/dev/null || status=1
      done
      [[ $status -eq 0 ]] || failed+=("autocomplete")
      ;;
    *) echo "unknown take $take"; failed+=("$take") ;;
  esac
done

ls -l "$OUT/clips" "$OUT/stills"
echo "failed: ${failed[*]:-none}" | tee "$OUT/logs/failed.txt"
[[ -n "$(ls "$OUT/clips"/*.mp4 2>/dev/null)" ]]
