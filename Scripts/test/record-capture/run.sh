#!/usr/bin/env bash
# Record a scripted capture session on this Mac and add its scrubbed trace to
# the test fixtures. Needs the installed Debug LokalBot with Accessibility and
# Screen Recording granted. Launches a browser (GUI) — ask before running.
#   Scripts/test/record-capture/run.sh chrome 60
set -euo pipefail
BROWSER="${1:?chrome or safari}"
SECONDS_TO_RECORD="${2:-60}"
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
APP_BIN="${LOKALBOT_APP:-/Applications/LokalBot.app}/Contents/MacOS/LokalBot"
# --record-capture exists only in Debug builds. A Release app would ignore it
# and open normally, so refuse any binary that lacks the flag.
if ! grep -aqr -- '--record-capture' "$(dirname "$APP_BIN")"; then
  echo "$APP_BIN is not a Debug build; set LOKALBOT_APP to a Debug LokalBot.app" >&2
  exit 2
fi
LIBRARY=$(mktemp -d /tmp/lokalbot-record.XXXXXX)
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/Scripts/test/record-capture/page" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true; rm -rf "$LIBRARY"' EXIT
case "$BROWSER" in
  chrome) open -a "Google Chrome" "http://127.0.0.1:$PORT/" ;;
  safari) open -a Safari "http://127.0.0.1:$PORT/" ;;
  *) echo "unknown browser $BROWSER" >&2; exit 2 ;;
esac
sleep 3
OUTPUT=$(LOKALBOT_STORAGE_ROOT="$LIBRARY" "$APP_BIN" --record-capture "$SECONDS_TO_RECORD" --scenario "scripted-$BROWSER-local-page" | tail -1)
TRACE="${OUTPUT#LokalBot --record-capture: }"
DEST="$ROOT/LokalBotTests/Fixtures/capture-traces/scripted-$BROWSER-local-page.json"
cp "$TRACE" "$DEST"
python3 "$ROOT/Scripts/ci/check-capture-recordings.py" "$(dirname "$DEST")"
echo "$DEST"
