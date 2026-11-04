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
#   search today timeline people notes notes-tall stills   the host on seeded data
#   live ask ask-tall dictation projects        the host's background mode: real pipelines
#                                               and local models, with WAV files for the
#                                               microphone and the call's system audio
#   files                                       the Debug app, which reads the chosen folders; the host never does
#   autocomplete                                the Debug app in TextEdit (Scripts/autocomplete-demo/film.sh)
#
# Writes <out>/clips/<appearance>-<take>.mp4 (30 fps, 4:4:4) with <take>.json (rect,
# scale, events, pointer path), <out>/stills/ and <out>/logs/; with PROBE=1 also
# <out>/trees/<take>/ (the accessibility tree at each `mark`). A take that fails is
# reported and skipped.
#
# CI only: it grants the rig's TCC permissions with sudo.
set -uo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "film.sh changes system settings; run it in GitHub Actions" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
HOST_APP=$(cd "${UI_HOST_APP:?set UI_HOST_APP to a built LokalBot UI Test Host.app}" && pwd)
HOST_BIN="$HOST_APP/Contents/MacOS/"
HOST_ID=me.dotenv.LokalBot.uitesthost
DEBUG_APP=${LOKALBOT_APP:-}
DEBUG_BIN=${DEBUG_APP:+$DEBUG_APP/Contents/MacOS/LokalBot}
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
shift
if [[ $# -eq 0 ]]; then set -- search today timeline people notes stills live ask dictation projects files autocomplete; fi
APPEARANCES=${APPEARANCES:-light dark}
PROBE=${PROBE:-0}
WORK=$(cd "$(mktemp -d "${RUNNER_TEMP:-/tmp}/landing-film.XXXXXX")" && pwd -P)
RIG="$WORK/rig"
DISPLAY_SIZE=${DISPLAY_SIZE:-1400x1000}
mkdir -p "$OUT/logs" "$OUT/clips" "$OUT/takes" "$OUT/trees" "$OUT/stills" "$OUT/recorded"
export FILM_FILES="$HOME/Files"  # the path Files results show

quit_host() {
  pkill -f "$HOST_BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$HOST_BIN" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "$HOST_BIN" 2>/dev/null || true
  pkill -f llama-server 2>/dev/null || true
  sleep 0.5
}
quit_debug() {
  [[ -n "$DEBUG_BIN" ]] || return 0
  pkill -f "$DEBUG_BIN" 2>/dev/null || true
  for _ in $(seq 40); do pgrep -f "$DEBUG_BIN" >/dev/null || break; sleep 0.25; done
  pkill -9 -f "$DEBUG_BIN" 2>/dev/null || true
  pkill -f llama-server 2>/dev/null || true
  sleep 0.5
}
cleanup() {
  quit_host
  quit_debug
  for suite in "$WORK"/suite.*; do
    [[ -e "$suite" ]] && defaults delete "${suite##*/suite.}" >/dev/null 2>&1 || true
  done
  if [[ -n "${STRAYS_PID:-}" ]]; then kill "$STRAYS_PID" 2>/dev/null || true; fi
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
grant "${HOST_BIN}LokalBot UI Test Host" 1
if [[ -n "$DEBUG_BIN" ]]; then
  grant me.dotenv.LokalBot 0
  grant "$DEBUG_BIN" 1
fi

echo "== text defaults =="
defaults write -g NSAutomaticInlinePredictionEnabled -bool false
defaults write -g NSAutomaticSpellingCorrectionEnabled -bool false
defaults write -g NSAutomaticTextCompletionEnabled -bool false
defaults write -g AppleShowScrollBars -string WhenScrolling
defaults write com.apple.dock autohide -bool true; killall Dock 2>/dev/null || true
defaults write com.apple.CrashReporter DialogType -string none
defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool false

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

# A take's capture leaves other apps' windows out, so a system dialog never shows
# in the footage but catches clicks. One stayed up through most of a pass.
( while :; do "$RIG" windows kill >> "$OUT/logs/windows.txt" 2>&1; sleep 4; done ) &
STRAYS_PID=$!

FILM_TZ=$(python3 "$HERE/stage.py" timezone)
export TZ=$FILM_TZ
echo "== libraries (TZ=$FILM_TZ, $(date)) =="
python3 "$HERE/stage.py" library studio "$WORK/studio" || exit 1
python3 "$HERE/stage.py" library pricing "$WORK/pricing" || exit 1
python3 "$HERE/stage.py" library empty "$WORK/empty" || exit 1
python3 "$HERE/stage.py" audio "$WORK/call" call || exit 1
python3 "$HERE/stage.py" audio "$WORK/spoken" dictation || exit 1
rm -rf "$FILM_FILES"
python3 "$HERE/stage.py" files "$FILM_FILES" || exit 1
say -v '?' | grep -E '^(Samantha|Daniel)' > "$OUT/logs/voices.txt" || true
cp "$WORK"/call/*.wav "$OUT/logs/" 2>/dev/null || true

needs_models=0
for take in "$@"; do case ${take%@*} in live|ask|ask-tall|dictation|projects|files) needs_models=1;; esac; done
if [[ $needs_models -eq 1 ]]; then
  echo "== models =="
  python3 "$HERE/stage.py" models "$WORK/models" "$WORK/studio" "$WORK/pricing" "$WORK/empty" || exit 1
  ls -la "$WORK/models"
  # On a Mac that has just booted, the first load of the model can miss the app's two-minute
  # limit for its server to start, which fails the answer or the notes. Load it once here.
  server=$(find "$HOST_APP/Contents/Resources" -type f -name llama-server | head -1)
  if [[ -x "$server" ]]; then
    started=$SECONDS
    "$server" -m "$WORK/models/Qwen3.5-4B-Q4_K_M.gguf" --host 127.0.0.1 --port 17990 -c 4096 -ngl 99 --no-webui > "$OUT/logs/warm-model.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 900); do
      curl -fs -o /dev/null http://127.0.0.1:17990/health && break
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 1
    done
    echo "the model took $((SECONDS - started))s to load"
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
fi

background() { [[ $1 == dark ]] && echo "#0E1720" || echo "#E6F0EF"; }

set_appearance() {  # set_appearance <appearance>: for the apps launched next
  if [[ $1 == dark ]]; then defaults write -g AppleInterfaceStyle Dark; else defaults delete -g AppleInterfaceStyle 2>/dev/null || true; fi
  "$RIG" appearance "$1" || true
}

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
  set_appearance "$appearance"
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

# launch_debug <appearance> <library> <profile>: the Debug app on a fresh copy of a library,
# a child of this shell so macOS holds the runner responsible for its permissions.
launch_debug() {
  local appearance=$1 source=$2 profile=$3 run suite
  quit_host
  quit_debug
  run=$(mktemp -d "$WORK/run.XXXXXX")
  cp -cR "$source/." "$run/" 2>/dev/null || cp -R "$source/." "$run/"
  suite="lokalbot.landing-film.$(uuidgen)"
  touch "$WORK/suite.$suite"
  python3 "$HERE/stage.py" settings "$suite" "$profile" || return 1
  defaults write me.dotenv.LokalBot lokalbotv3.onboarding.shown -bool YES
  set_appearance "$appearance"
  "$DEBUG_BIN" --lokalbot-storage-root "$run" --lokalbot-defaults-suite "$suite" -ApplePersistenceIgnoreState YES \
    -AppleLanguages "(en)" -AppleLocale en_US >> "$OUT/logs/debug-app.log" 2>&1 &
  for _ in $(seq 120); do pgrep -f "$DEBUG_BIN" >/dev/null && break; sleep 0.5; done
  sleep 6
  LAST_RUN=$run
}

# rig_take <appearance> <take> <shot>: records and encodes; 0 on success
rig_take() {
  local appearance=$1 take=$2 shot=$3 dest="$OUT/takes/$1/$2" status=0 trees=
  rm -rf "$dest"; mkdir -p "$dest"
  [[ $PROBE == 1 ]] && trees="$OUT/trees/$take"
  { echo "== $appearance/$take"; "$RIG" windows list; } >> "$OUT/logs/windows.txt" 2>&1
  RIG_TREE_DIR=$trees RIG_BACKGROUND=$(background "$appearance") "$RIG" take "$shot" "$dest" 2>&1 | tee -a "$OUT/logs/rig-$take.log"
  status=${PIPESTATUS[0]}
  if [[ $status -eq 0 && -s "$dest/take.json" ]]; then
    python3 "$ROOT/Scripts/autocomplete-demo/encode.py" "$dest" "$OUT/clips/$appearance-$take.mp4" || status=1
    rm -rf "$dest/frames"
  fi
  return $status
}

# ask_take <appearance> <take>: rig_take, stopped as soon as the app reports a failed answer,
# since the take would otherwise wait out every timeout for an answer that isn't coming.
ask_take() {
  local status=0 watcher
  ( until grep -q "chat response failed" "$LAST_RUN/debug.log" 2>/dev/null; do sleep 5; done
    grep "chat response failed" "$LAST_RUN/debug.log" | cut -c1-200
    pkill -f "$RIG take" ) &
  watcher=$!
  rig_take "$1" "$2" "$HERE/shots/$2.json" || status=$?
  kill "$watcher" 2>/dev/null || true
  return $status
}

failed=()
film_seeded() {  # film_seeded <take> <library> ENV...: filmed on seeded data in each appearance
  local take=$1 library=$2 appearance attempt status
  shift 2
  echo "== $take =="
  for appearance in $APPEARANCES; do
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

film_projects() {  # film_projects <library>: two takes of one launch, the model writing between them
  local library=$1 appearance attempt status
  for appearance in $APPEARANCES; do
    status=1
    for attempt in 1 2; do
      launch_host "$appearance" "$library" ask LOKALBOT_INITIAL_SECTION=projects LOKALBOT_UI_TEST_BACKGROUND=1 || continue
      status=0; rig_take "$appearance" projects "$HERE/shots/projects.json" || status=$?
      if [[ $status -eq 0 ]]; then
        # Nothing records during the wait. The rig saving frames slows the model on a hosted
        # Mac enough that the note runs past the app's 10 minute limit on a request.
        python3 "$HERE/stage.py" wait-note "$LAST_RUN" Northwind "${NOTE_TIMEOUT:-2700}" | tee -a "$OUT/logs/project-notes.txt"
        status=${PIPESTATUS[0]}
      fi
      if [[ $status -eq 0 ]]; then
        rig_take "$appearance" projects-note "$HERE/shots/projects-note.json" || status=$?
      fi
      keep_logs "projects-$appearance"
      quit_host
      [[ $status -eq 0 ]] && break
      echo "projects/$appearance attempt $attempt failed ($status)"
    done
    [[ $status -eq 0 ]] || failed+=("projects/$appearance")
  done
}

film_dictation() {  # film_dictation <appearance> <take>: into TextEdit with the host's overlay; 0 on success
  local appearance=$1 take=$2 doc status=0
  launch_host "$appearance" "$WORK/pricing" dictation LOKALBOT_UI_TEST_BACKGROUND=1 "LOKALBOT_UI_TEST_AUDIO=$WORK/spoken" || return 1
  sleep 10
  doc="$WORK/Team update.txt"; : > "$doc"
  textedit=(-RichText NO -NSFixedPitchFont HelveticaNeue -NSFixedPitchFontSize 38 -CheckSpellingWhileTyping NO -CheckGrammarWithSpelling NO
            -SmartQuotes NO -SmartDashes NO -TextReplacement NO -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO)
  [[ $appearance == dark ]] && textedit+=(-AppleInterfaceStyle Dark)
  pkill -x TextEdit 2>/dev/null || true; sleep 0.5
  open -a TextEdit "$doc" --args "${textedit[@]}"
  sleep 2
  rig_take "$appearance" "$take" "$HERE/shots/$take.json" || status=$?
  pkill -x TextEdit 2>/dev/null || true
  keep_logs "$take-$appearance"
  quit_host
  return $status
}

# A take written "ask@dark" films in that appearance only.
ALL_APPEARANCES=$APPEARANCES
for take in "$@"; do
  APPEARANCES=$ALL_APPEARANCES
  [[ $take == *@* ]] && APPEARANCES=${take#*@}
  case ${take%@*} in
    search) film_seeded search "$WORK/studio" LOKALBOT_UI_TEST_WINDOW=quick-recall ;;
    today) film_seeded today "$WORK/studio" LOKALBOT_INITIAL_SECTION=today ;;
    timeline) film_seeded timeline "$WORK/studio" LOKALBOT_INITIAL_SECTION=timeline ;;
    people) film_seeded people "$WORK/studio" LOKALBOT_INITIAL_SECTION=people ;;
    notes|notes-tall)
      # The recorded call's real notes when the live take made them, else the seeded holiday shoot.
      library="$WORK/studio"
      [[ -d "$WORK/recorded" ]] && library="$WORK/recorded"
      film_seeded "${take%@*}" "$library" LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=0 LOKALBOT_DETAIL_TAB=summary
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
        launch_host "$appearance" "$WORK/studio" meeting LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_UI_TEST_BACKGROUND=1 \
          "LOKALBOT_UI_TEST_AUDIO=$WORK/call" "LOKALBOT_UI_TEST_TRACE=$HERE/call-trace.json" || continue
        status=0; rig_take "$appearance" live "$HERE/shots/live.json" || status=$?
        [[ $status -eq 0 ]] || failed+=("live/$appearance")
        if [[ $first == 1 ]]; then
          echo "waiting for the recorded call's notes"
          if folder=$(python3 "$HERE/stage.py" wait-notes "$LAST_RUN" "$WORK/studio" "${NOTES_TIMEOUT:-3000}"); then
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
    ask|ask-tall)
      name=${take%@*}
      echo "== $name =="
      for appearance in $APPEARANCES; do
        status=1
        for attempt in 1 2 3; do
          launch_host "$appearance" "$WORK/studio" ask LOKALBOT_INITIAL_SECTION=ask LOKALBOT_UI_TEST_BACKGROUND=1 || continue
          status=0; ask_take "$appearance" "$name" || status=$?
          keep_logs "$name-$appearance"
          quit_host
          [[ $status -eq 0 ]] && break
          echo "$name/$appearance attempt $attempt failed ($status)"
        done
        [[ $status -eq 0 ]] || failed+=("$name/$appearance")
      done
      ;;
    dictation)
      echo "== dictation =="
      # The first dictation downloads and checks the speech model, which isn't what to show.
      film_dictation "${APPEARANCES%% *}" dictation-warmup || true
      rm -f "$OUT"/clips/*-dictation-warmup.*
      for appearance in $APPEARANCES; do
        for shot in dictation dictation-tall; do
          status=1
          for attempt in 1 2 3; do
            film_dictation "$appearance" "$shot" && { status=0; break; }
            echo "$shot/$appearance attempt $attempt failed"
          done
          [[ $status -eq 0 ]] || failed+=("$shot/$appearance")
        done
      done
      ;;
    projects)
      echo "== projects =="
      # The take tracks a suggestion, and the model writes its note. The page opens on the first
      # tracked project and writes that project's note if it has none, so that one is written
      # first, and nothing else is using the model when the take asks for the second.
      library="$WORK/noted"
      rm -rf "$library"
      cp -cR "$WORK/studio" "$library" 2>/dev/null || cp -R "$WORK/studio" "$library"
      python3 "$HERE/stage.py" track "$library" || exit 1
      status=1
      for attempt in 1 2; do
        launch_host "${APPEARANCES%% *}" "$library" ask LOKALBOT_INITIAL_SECTION=projects LOKALBOT_UI_TEST_BACKGROUND=1 || continue
        python3 "$HERE/stage.py" wait-note "$LAST_RUN" "Holiday shoot" "${NOTE_TIMEOUT:-2700}" | tee -a "$OUT/logs/project-notes.txt"
        status=${PIPESTATUS[0]}
        sleep 2
        keep_logs "projects-note"
        quit_host
        [[ $status -eq 0 ]] && break
        echo "the first note, attempt $attempt failed"
      done
      if [[ $status -eq 0 ]]; then
        rm -rf "$library"
        cp -cR "$LAST_RUN" "$library" 2>/dev/null || cp -R "$LAST_RUN" "$library"
        film_projects "$library"
      else
        failed+=("projects-note")
      fi
      ;;
    files)
      echo "== files =="
      for appearance in $APPEARANCES; do
        # No meetings to outrank the files this take is about.
        library="$WORK/empty"
        [[ -d "$WORK/indexed" ]] && library="$WORK/indexed"
        launch_debug "$appearance" "$library" files || { failed+=("files/$appearance"); continue; }
        if [[ ! -d "$WORK/indexed" ]]; then
          echo "waiting for Files to read the folder"
          for _ in $(seq "${FILES_TIMEOUT:-1200}"); do
            grep -q "file search: read" "$LAST_RUN/debug.log" 2>/dev/null && break
            sleep 1
          done
          grep -E "file search|embedder" "$LAST_RUN/debug.log" 2>/dev/null | tail -12 || true
          sleep 5
          quit_debug
          cp -cR "$LAST_RUN" "$WORK/indexed" 2>/dev/null || cp -R "$LAST_RUN" "$WORK/indexed"
          launch_debug "$appearance" "$WORK/indexed" files || { failed+=("files/$appearance"); continue; }
        fi
        "$RIG" key space control shift
        sleep 3
        status=0; rig_take "$appearance" files "$HERE/shots/files.json" || status=$?
        [[ $status -eq 0 ]] || failed+=("files/$appearance")
        keep_logs "files-$appearance"
        quit_debug
      done
      ;;
    autocomplete)
      echo "== autocomplete =="
      status=0
      APPEARANCES="$APPEARANCES" SHOTS="$HERE/shots-autocomplete" FONT_SIZE=38 \
        BACKGROUND_LIGHT="$(background light)" BACKGROUND_DARK="$(background dark)" \
        LOKALBOT_APP="${LOKALBOT_APP:?set LOKALBOT_APP to a Debug LokalBot.app}" \
        bash "$ROOT/Scripts/autocomplete-demo/film.sh" "$OUT/autocomplete" memory memory-tall || status=$?
      for appearance in $APPEARANCES; do
        for shot in memory memory-tall; do
          name=autocomplete${shot#memory}
          cp "$OUT/autocomplete/clips/$appearance-$shot.mp4" "$OUT/clips/$appearance-$name.mp4" 2>/dev/null || status=1
          cp "$OUT/autocomplete/clips/$appearance-$shot.json" "$OUT/clips/$appearance-$name.json" 2>/dev/null || status=1
        done
      done
      [[ $status -eq 0 ]] || failed+=("autocomplete")
      ;;
    *) echo "unknown take $take"; failed+=("$take") ;;
  esac
done

ls -l "$OUT/clips" "$OUT/stills"
echo "failed: ${failed[*]:-none}" | tee "$OUT/logs/failed.txt"
[[ -n "$(ls "$OUT/clips"/*.mp4 2>/dev/null)" ]]
