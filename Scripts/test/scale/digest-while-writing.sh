#!/usr/bin/env bash
# 0.9.1 regression: new activity written while a digest generates must not
# fail the digest. Runs --digest while another process inserts activity.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
BIN="${LOKALBOT_APP:?}/Contents/MacOS/LokalBot"
LIB=$(mktemp -d /tmp/lokalbot-scale.XXXXXX)
DAY=$(date +%Y-%m-%d)
SUITE="me.dotenv.LokalBot.scale.$$"
python3 "$ROOT_DIR/Scripts/test/seed_demo_library.py" --profile full-day --day "$DAY" "$LIB" >/dev/null
"$LOKALBOT_TEST_BUN" run "$ROOT_DIR/LokalBotTests/Fixtures/stub-openai.ts" > "$LIB/stub.out" 2>&1 &
STUB=$!
trap 'kill $STUB 2>/dev/null || true; defaults delete "$SUITE" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 100); do PORT=$(head -1 "$LIB/stub.out" | tr -dc '0-9'); [[ -n "$PORT" ]] && break; sleep 0.1; done
python3 "$ROOT_DIR/Scripts/test/day-in-the-life/scenario.py" "$ROOT_DIR/LokalBotTests/Fixtures/model-recordings" z-ai/glm-5.3-flash \
  | curl -fsS -X POST --data @- "http://127.0.0.1:$PORT/__scenario" >/dev/null
SETTINGS=$(printf '{"summarizerBackend":"OpenAI-compatible server","openAIBaseURL":"http://127.0.0.1:%s/v1","openAIModel":"z-ai/glm-5.3-flash","trackingEnabled":false,"dayDigestAutoEnabled":false,"dreamingEnabled":false}' "$PORT")
defaults write "$SUITE" lokalbotv3.settings -data "$(printf '%s' "$SETTINGS" | xxd -p | tr -d '\n')"
python3 - "$LIB/lokalbotv3.sqlite" <<'PY' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], timeout=5)
for i in range(100):
    now = time.time()
    con.execute("INSERT INTO activity_blocks (app,title,start,end) VALUES ('Xcode', ?, ?, ?)", (f"live {i}", now - 5, now))
    con.commit()
    time.sleep(0.2)
PY
WRITER=$!
LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE" "$BIN" --digest "$DAY"
wait $WRITER
test -s "$LIB/journal/$DAY.md"
echo "digest finished while activity was being written"
