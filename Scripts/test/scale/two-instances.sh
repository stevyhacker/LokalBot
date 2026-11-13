#!/usr/bin/env bash
# #115 regression: a second copy on the same library exits instead of
# writing to it. Launches the app normally (GUI) — nightly CI only.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${LOKALBOT_APP:?}/Contents/MacOS/LokalBot"
LIB=$(mktemp -d /tmp/lokalbot-two.XXXXXX)
SUITE="me.dotenv.LokalBot.two.$$"
python3 "$ROOT_DIR/Scripts/test/seed_demo_library.py" "$LIB" >/dev/null
export LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE"
"$BIN" -ApplePersistenceIgnoreState YES > "$LIB/first.log" 2>&1 &
FIRST=$!
trap 'kill $FIRST 2>/dev/null || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
python3 - "$LIB/.instance.lock" <<'PY'
import fcntl, sys, time
for _ in range(100):
    try:
        with open(sys.argv[1], "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(handle, fcntl.LOCK_UN)
    except (BlockingIOError, FileNotFoundError):
        if __import__("os").path.exists(sys.argv[1]):
            sys.exit(0)
    time.sleep(0.2)
sys.exit("the first copy never took the library lock")
PY
( "$BIN" -ApplePersistenceIgnoreState YES > "$LIB/second.log" 2>&1 & echo $! > "$LIB/second.pid" )
for _ in $(seq 1 75); do kill -0 "$(cat "$LIB/second.pid")" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$(cat "$LIB/second.pid")" 2>/dev/null; then echo "second copy kept running on a locked library"; exit 1; fi
kill $FIRST
wait $FIRST 2>/dev/null || true
# A plain `[ ]`: macOS's own bash (3.2) does not stop a `set -e` script on a false `[[ ]]`.
[ "$(sqlite3 "$LIB/lokalbotv3.sqlite" 'PRAGMA integrity_check')" = "ok" ] || { echo "the library failed its integrity check"; exit 1; }
echo "second copy exited; library intact"
