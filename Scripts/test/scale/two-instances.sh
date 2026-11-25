#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${LOKALBOT_APP:?}/Contents/MacOS/LokalBot"
LIB=$(mktemp -d /tmp/lokalbot-two.XXXXXX)
SUITE="me.dotenv.LokalBot.two.$$"
PASSED=0
cleanup() {
  kill "${FIRST:-}" 2>/dev/null || true
  kill "${SECOND:-}" 2>/dev/null || true
  defaults delete "$SUITE" >/dev/null 2>&1 || true
  if [ "$PASSED" -eq 1 ]; then
    rm -rf "$LIB"
  else
    echo "two-instances library kept for inspection: $LIB" >&2
  fi
}
trap cleanup EXIT
python3 "$ROOT_DIR/Scripts/test/seed_demo_library.py" "$LIB" >/dev/null
export LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE"
"$BIN" -ApplePersistenceIgnoreState YES > "$LIB/first.log" 2>&1 &
FIRST=$!
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
"$BIN" -ApplePersistenceIgnoreState YES > "$LIB/second.log" 2>&1 &
SECOND=$!
for _ in $(seq 1 75); do kill -0 "$SECOND" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$SECOND" 2>/dev/null; then
  echo "second copy kept running on a locked library" >&2
  exit 1
fi
SECOND_STATUS=0
wait "$SECOND" || SECOND_STATUS=$?
if [ "$SECOND_STATUS" -ne 0 ]; then
  echo "second copy exited with non-zero status $SECOND_STATUS instead of refusing cleanly:" >&2
  cat "$LIB/second.log" >&2 || true
  exit 1
fi
if ! grep -q "another LokalBot is using" "$LIB/second.log"; then
  echo "second copy exited 0 without logging the library instance lock refusal:" >&2
  cat "$LIB/second.log" >&2 || true
  exit 1
fi
kill "$FIRST"
wait "$FIRST" 2>/dev/null || true
[ "$(sqlite3 "$LIB/lokalbotv3.sqlite" 'PRAGMA integrity_check')" = "ok" ] || { echo "the library failed its integrity check"; exit 1; }
PASSED=1
echo "second copy exited cleanly on lock; library intact"
