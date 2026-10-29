#!/bin/bash
# A separate LokalBot library and settings for recording the Meta hackathon
# demo (Docs/meta-hackathon/recording-checklist.md). Your own library,
# settings, and screen memory are never read or written.
#
#   Scripts/meta-hackathon-demo.sh setup   seed the earlier meetings, link your models, preset the demo settings
#   Scripts/meta-hackathon-demo.sh answers make the folders live answers read, and turn live answers on
#   Scripts/meta-hackathon-demo.sh open    start LokalBot Dev on the demo library
#   Scripts/meta-hackathon-demo.sh restart quit the demo's LokalBot Dev and start it again (after granting a permission)
#   Scripts/meta-hackathon-demo.sh pages   open the two synthetic pages for screen memory in Safari
#   Scripts/meta-hackathon-demo.sh reset   delete the demo library and its settings
set -euo pipefail

ROOT="$HOME/Library/Application Support/me.dotenv.LokalBot.meta-demo"
SUITE="me.dotenv.LokalBot.meta-demo"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
REAL_MODELS="$HOME/Library/Application Support/me.dotenv.LokalBot/models"
MARKER="$ROOT/.lokalbot-demo-library"
NORTHWIND="$ROOT/Northwind"
CODE="$ROOT/LokalBot"

# Partial settings: anything left out keeps its default. Meta Muse is approved
# with fast live text, screen answers and the floating panel on; the panel is
# visible to screen recordings; screen memory keeps screenshots, every minute.
SETTINGS='{
  "approvedRemoteInferenceOrigins": ["https://api.meta.ai"],
  "museLiveTextEnabled": true,
  "museScreenAnswersEnabled": true,
  "liveRadarPanelEnabled": true,
  "liveRadarPanelHiddenFromCapture": false,
  "trackingEnabled": true,
  "screenContextCaptureMode": "Text + visual context",
  "screenshotsEnabled": true,
  "screenshotIntervalMinutes": 1
}'

# Live answers read two folders made for the demo: the Northwind sheet and
# brief, and a clone of this repository without the demo's notes, fixtures,
# tests, and scripted film replies, which would otherwise answer the call's
# questions for it. Then live answers are turned on in the demo settings,
# keeping everything else.
live_answers() {
  if running_demo; then
    echo "Quit the demo's LokalBot Dev first; it saves its settings when it quits." >&2
    exit 1
  fi
  rm -rf "$NORTHWIND" "$CODE"
  mkdir -p "$NORTHWIND"
  cp "$REPO/Docs/meta-hackathon/demo-files/"* "$NORTHWIND/"
  git clone --quiet --no-checkout --branch meta-hackathon "$REPO" "$CODE"
  git -C "$CODE" remote set-url origin "$(git -C "$REPO" remote get-url origin)"
  git -C "$CODE" sparse-checkout set --no-cone '/*' '!/HACKATHON.md' '!/Docs/meta-hackathon/' '!/Benchmarks/MuseRadar/' \
    '!/LokalBotTests/' '!/LokalBotUITests/' '!/LokalBot/Engines/MuseUITestTransport.swift'
  git -C "$CODE" checkout --quiet meta-hackathon
  python3 -I - "$SUITE" "$NORTHWIND" "$CODE" <<'PY'
import json, plistlib, subprocess, sys
suite, *folders = sys.argv[1:]
exported = subprocess.run(["defaults", "export", suite, "-"], capture_output=True, check=True).stdout
settings = json.loads(plistlib.loads(exported).get("lokalbotv3.settings", b"{}"))
settings.update(liveAnswersEnabled=True, liveAnswerFolders=folders)
data = json.dumps(settings).encode().hex()
subprocess.run(["defaults", "write", suite, "lokalbotv3.settings", "-data", data], check=True)
PY
  echo "Live answers read $NORTHWIND and $CODE (at $(git -C "$CODE" rev-parse --short HEAD))."
}

# True when the running LokalBot Dev is the one started on the demo library.
running_demo() {
  local pid
  pid="$(pgrep -x "LokalBot Dev" | head -1)" || return 1
  ps eww -p "$pid" | grep -q "LOKALBOT_DEFAULTS_SUITE=$SUITE"
}

dev_app() {
  local products
  products="$(xcodebuild -project "$REPO/LokalBot.xcodeproj" -scheme 'LokalBot Dev' -configuration Debug \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')"
  [ -d "$products/LokalBot Dev.app" ] || {
    echo "LokalBot Dev isn't built. Run: xcodebuild -project LokalBot.xcodeproj -scheme 'LokalBot Dev' -configuration Debug build" >&2
    exit 1
  }
  echo "$products/LokalBot Dev.app"
}

case "${1:-}" in
setup)
  if [ -e "$ROOT" ]; then
    echo "The demo library already exists at $ROOT. Run '$0 reset' first to start over." >&2
    exit 1
  fi
  python3 -I "$REPO/Scripts/seed_demo_library.py" --profile meta-hackathon "$ROOT"
  # One link per model file, so a new download lands in the demo library and
  # never in yours.
  mkdir -p "$ROOT/models"
  if [ -d "$REAL_MODELS" ]; then
    for model in "$REAL_MODELS"/*; do ln -s "$model" "$ROOT/models/$(basename "$model")"; done
    echo "Linked $(ls "$ROOT/models" | wc -l | tr -d ' ') model files from your library."
  fi
  defaults write "$SUITE" lokalbotv3.settings -data "$(printf '%s' "$SETTINGS" | xxd -p | tr -d '\n')"
  echo "Demo settings saved in the '$SUITE' defaults suite."
  live_answers
  ;;
answers)
  [ -f "$MARKER" ] || { echo "Run '$0 setup' first." >&2; exit 1; }
  live_answers
  ;;
open)
  [ -f "$MARKER" ] || { echo "Run '$0 setup' first." >&2; exit 1; }
  if running_demo; then
    echo "LokalBot Dev is already running on the demo library. To reopen it, run: $0 restart"
    exit 0
  fi
  if pgrep -x "LokalBot Dev" >/dev/null; then
    echo "Quit LokalBot Dev first; a running copy keeps its own library." >&2
    exit 1
  fi
  open "$(dev_app)" --env LOKALBOT_STORAGE_ROOT="$ROOT" --env LOKALBOT_DEFAULTS_SUITE="$SUITE"
  ;;
restart)
  if pgrep -x "LokalBot Dev" >/dev/null; then
    running_demo || { echo "The running LokalBot Dev isn't on the demo library; quit it yourself." >&2; exit 1; }
    osascript -e 'tell application id "me.dotenv.LokalBot.dev" to quit'
    for _ in $(seq 1 30); do pgrep -x "LokalBot Dev" >/dev/null || break; sleep 1; done
    if pgrep -x "LokalBot Dev" >/dev/null; then
      echo "LokalBot Dev didn't quit; quit it with Command-Q and run '$0 open'." >&2
      exit 1
    fi
  fi
  exec "$0" open
  ;;
pages)
  open -a Safari "$REPO/Docs/meta-hackathon/demo-pages/growth-dashboard.html" \
    "$REPO/Docs/meta-hackathon/demo-pages/launch-plan.html"
  ;;
reset)
  if [ -e "$ROOT" ] && [ ! -f "$MARKER" ]; then
    echo "Refusing to delete $ROOT: it isn't a demo library." >&2
    exit 1
  fi
  rm -rf "$ROOT"
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  echo "Deleted the demo library and its settings."
  ;;
*)
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
  ;;
esac
