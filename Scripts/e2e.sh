#!/bin/bash
# LokalBot end-to-end test suite. Drives the REAL app binary headlessly:
# real audio (synthesized with `say`), real CoreML transcription, the real
# bundled llama.cpp server, real SQLite. Run on a Mac with the app built:
#   Scripts/install-app.sh && Scripts/e2e.sh
# Flows needing TCC permissions (screenshots) SKIP instead of failing when
# the permission is missing, so the suite is useful pre- and post-grant.
#
# Hermetic: the whole suite runs against a throwaway library under a temp
# LOKALBOT_STORAGE_ROOT, so it never touches the user's real meetings,
# indexes, or journal. The real install's models/ directory is symlinked
# into the temp root so multi-GB GGUFs are shared, not re-downloaded.
set -uo pipefail

BIN="${LOKALBOT_APP:-/Applications/LokalBot.app}/Contents/MacOS/LokalBot"
[ -x "$BIN" ] || { echo "no binary at $BIN — run Scripts/install-app.sh first"; exit 2; }

ROOT=$(mktemp -d /tmp/lokalbot-e2e.XXXXXX)
export LOKALBOT_STORAGE_ROOT="$ROOT"

# Catalog GGUFs download under <storage root>/models (ModelCatalog.localURL),
# so a bare hermetic root would re-fetch them from scratch. Share the real
# install's downloads instead. Cleanup stays safe: `rm -rf` deletes the
# symlink itself, never the target directory's contents.
REAL_MODELS="$HOME/Library/Application Support/me.dotenv.LokalBot/models"
mkdir -p "$REAL_MODELS"
ln -s "$REAL_MODELS" "$ROOT/models"

P=0; F=0; S=0
pass() { echo "  ✅ $1"; P=$((P+1)); }
fail() { echo "  ❌ $1"; F=$((F+1)); }
skip() { echo "  ⏭️  $1"; S=$((S+1)); }

# Keep the library around on failure for debugging; clean up on success.
finish() {
  if [ "$F" -eq 0 ]; then
    rm -rf "$ROOT"
  else
    echo "test library kept for inspection: $ROOT"
  fi
}
trap finish EXIT

echo "== T1: manual recording (mic → m4a + meta.json) =="
OUT=$("$BIN" --record 4 2>/dev/null | tail -1); RC=$?
DIR="${OUT#*→ }"
if [ "$RC" -eq 3 ]; then
  skip "microphone permission not granted yet"
elif [[ "$OUT" == *"--record: done"* && -s "$DIR/mic.m4a" && -s "$DIR/meta.json" ]]; then
  SIZE=$(stat -f%z "$DIR/mic.m4a")
  [ "$SIZE" -gt 5000 ] && pass "recorded mic.m4a (${SIZE}B) + meta.json" \
                       || fail "mic.m4a suspiciously small (${SIZE}B)"
else
  fail "record flow: $OUT"
fi

echo "== T2: transcribe + summarize (dual-track, Me/Them, Markdown) =="
FIX="$ROOT/meetings/2026/06/e2e-fixture"
mkdir -p "$FIX"
say -v Samantha -o /tmp/e2e_mic.aiff "Let us decide on the caching layer. I propose Redis because of pub sub support. I will draft the eviction policy document by Thursday." 2>/dev/null
say -v Daniel -o /tmp/e2e_sys.aiff "Agreed on Redis. One open question, do we need cluster mode from day one? Please benchmark failover latency first." 2>/dev/null
afconvert -f m4af -d aac /tmp/e2e_mic.aiff "$FIX/mic.m4a"
afconvert -f m4af -d aac /tmp/e2e_sys.aiff "$FIX/system.m4a"
cat > "$FIX/meta.json" <<'EOF'
{"id":"7E57C0DE-0000-4000-8000-00000000E2E1","title":"E2E fixture","appName":"E2E",
 "startedAt":"2026-06-10T09:00:00Z","endedAt":"2026-06-10T09:02:00Z",
 "relativePath":"meetings/2026/06/e2e-fixture","hasSystemTrack":true}
EOF
"$BIN" --process "$FIX" >/dev/null 2>&1
grep -q '"speaker" : "me"' "$FIX/transcript.json" 2>/dev/null \
  && grep -q '"speaker" : "them"' "$FIX/transcript.json" \
  && pass "transcript.json has both speakers" || fail "speaker attribution"
grep -qi "redis" "$FIX/transcript.md" 2>/dev/null \
  && pass "transcription accurate ('Redis' survived)" || fail "transcript content"
grep -q "^## TL;DR" "$FIX/summary.md" 2>/dev/null \
  && grep -q "^## Action items" "$FIX/summary.md" \
  && pass "summary.md has TL;DR + Action items sections" || fail "summary sections"

echo "== T2b: crash recovery (broken m4a → preserved PCM tee) =="
RECOVERY="$ROOT/meetings/2026/06/e2e-recovery"
mkdir -p "$RECOVERY"
say -v Samantha -o /tmp/e2e_recovery.aiff \
  "The crash recovery phrase is amber lighthouse. This audio must survive processing." 2>/dev/null
afconvert -f caff -d LEF32@16000 /tmp/e2e_recovery.aiff "$RECOVERY/mic.live.caf"
printf 'unfinished m4a container' > "$RECOVERY/mic.m4a"
cat > "$RECOVERY/meta.json" <<'EOF'
{"id":"7E57C0DE-0000-4000-8000-00000000E2E2","title":"E2E recovery","appName":"E2E",
 "startedAt":"2026-06-10T10:00:00Z","endedAt":"2026-06-10T10:01:00Z",
 "relativePath":"meetings/2026/06/e2e-recovery","hasSystemTrack":false}
EOF
"$BIN" --process "$RECOVERY" --no-summary >/dev/null 2>&1
if grep -qi "amber lighthouse" "$RECOVERY/transcript.md" 2>/dev/null \
   && [ -s "$RECOVERY/mic.live.caf" ]; then
  pass "recovered transcript from CAF and preserved the sole playable audio"
else
  fail "crash recovery did not transcribe and preserve mic.live.caf"
fi

echo "== T3: keyword search (FTS5) =="
"$BIN" --search "eviction policy" 2>/dev/null | grep -q "\[segment\]" \
  && pass "exact keyword hits a transcript segment" || fail "keyword search"

echo "== T4: prefix search (search-as-you-type) =="
"$BIN" --search "failov" 2>/dev/null | grep -q "«failover»" \
  && pass "prefix 'failov' matches 'failover'" || fail "prefix search"

echo "== T5: semantic search (embeddings, zero keyword overlap) =="
"$BIN" --search "which datastore did the team pick for caching" 2>/dev/null | grep -q "\[≈" \
  && pass "meaning-only query finds the Redis discussion" || fail "semantic search"

echo "== T6: screenshot + OCR + encryption =="
SHOT_OUTPUT=$("$BIN" --shot-test 2>&1)
case $? in
  0) LAST=$(sqlite3 "$ROOT/lokalbotv3.sqlite" "SELECT path FROM screenshots WHERE path!='' ORDER BY ts DESC LIMIT 1")
     if [[ "$SHOT_OUTPUT" == *"encrypted image round-trip"* \
          && "$LAST" == "$ROOT"/* && -f "$LAST" && -r "$LAST" && -s "$LAST" ]]; then
       pass "capture ok, readable AES-GCM envelope decrypts to an image"
     else fail "capture encryption round-trip failed: $SHOT_OUTPUT"; fi ;;
  3) skip "screen recording permission not granted yet" ;;
  *) fail "shot-test errored — see $ROOT/debug.log" ;;
esac

echo "== T7: day digest (activity + meetings → journal/*.md) =="
OUT=$("$BIN" --digest 2>/dev/null | tail -1)
JOURNAL="${OUT#*: }"; JOURNAL="${JOURNAL%% (*}"
if [[ "$OUT" == *"--digest: /"* && -s "$JOURNAL" ]] && grep -q "^## " "$JOURNAL"; then
  pass "digest written: $(basename "$JOURNAL")"
else fail "digest: $OUT"; fi

echo "== T8: digest folds in screenshot OCR, not just window titles =="
# Seed today's OCR with a proper noun that appears in NO window title or
# meeting, so if it lands in the digest it can only have come from the
# screenshot -> OCR path wired into generateDayDigest. A generic activity
# block gives the day material; its title carries no token.
NOW=$(date +%s)
sqlite3 -cmd ".timeout 5000" "$ROOT/lokalbotv3.sqlite" \
  "INSERT INTO ocr_fts (text, ts, app) VALUES ('Working through the Project Zephyrus migration runbook: rollback steps, feature flags, and the on-call rota for the cutover.', $NOW, 'Safari');" 2>/dev/null
sqlite3 -cmd ".timeout 5000" "$ROOT/lokalbotv3.sqlite" \
  "INSERT INTO activity_blocks (app, title, start, end) VALUES ('Safari', 'Internal wiki', $((NOW-600)), $NOW);" 2>/dev/null
OUT=$("$BIN" --digest 2>/dev/null | tail -1)
JOURNAL="${OUT#*: }"; JOURNAL="${JOURNAL%% (*}"
if [[ "$OUT" == *"--digest: /"* && -s "$JOURNAL" ]]; then
  grep -qi "zephyrus" "$JOURNAL" \
    && pass "OCR'd screen text reached the digest ('Zephyrus' came only from screen text)" \
    || fail "digest written but OCR token absent — screenshots not feeding the summary"
else
  fail "digest: $OUT"
fi

echo "== T8b: dreaming (day retrospective → dreams/*.json + work memory) =="
# The T2 fixture day has a real meeting → a substantive brief (model-written,
# or the evidence-only fallback if no model is reachable — never an empty stub).
OUT=$("$BIN" --dream 2026-06-10 2>/dev/null | tail -1)
DREAM="$ROOT/dreams/2026-06-10.json"
if [[ "$OUT" == *"--dream:"* && -s "$DREAM" && -s "$ROOT/memory/memory.json" ]] \
   && ! grep -q '"emptyDay"' "$DREAM"; then
  pass "fixture day dreamed: ${OUT#*--dream: }"
else fail "fixture-day dream: $OUT"; fi
# Yesterday is empty in this hermetic library → the model must be skipped and
# a durable empty-day stub written so catch-up moves past the day.
YDAY=$(date -v-1d +%F)
OUT=$("$BIN" --dream 2>/dev/null | tail -1)
if [[ "$OUT" == *"--dream: fallback (emptyDay)"* && -s "$ROOT/dreams/$YDAY.json" ]]; then
  pass "empty yesterday stubbed without waking a model"
else fail "empty-day dream: $OUT"; fi

echo "== T9: chat assistant (tool-calling Q&A over meetings) =="
# Reuses the T2 fixture (Redis / eviction policy) in the test library.
# The agent must search/read the meeting and ground its answer in it.
CHAT=$("$BIN" --chat "What did we decide about caching? Name the datastore." 2>/dev/null)
if echo "$CHAT" | grep -qi "redis"; then
  pass "chat agent grounded its answer in the meeting (mentions 'Redis')"
else
  fail "chat agent answer missing expected content: $(echo "$CHAT" | tail -1)"
fi

echo "== T10: agent mode (pi RPC, auto-approved) =="
AG=$("$BIN" --agent "Reply with the single word pong." 2>/dev/null); RC=$?
if [ "$RC" -eq 3 ]; then
  skip "agent runtime not installed"
elif [[ "$AG" == *"--agent: done"* ]]; then
  pass "agent replied"
else
  fail "agent: $(echo "$AG" | tail -1)"
fi

echo "== T11: MCP server (stdio handshake + gated tools) =="
CLI="${LOKALBOT_APP:-/Applications/LokalBot.app}/Contents/Helpers/lokalbot-cli"
if [ ! -x "$CLI" ]; then
  skip "embedded lokalbot-cli not present"
else
  mkdir -p "$ROOT/control"
  touch "$ROOT/control/agent-access-enabled"
  OUT=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}' \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_meetings","arguments":{"query":"redis"}}}' \
    | "$CLI" mcp 2>/dev/null)
  echo "$OUT" | head -1 | grep -q '"serverInfo"' \
    && echo "$OUT" | tail -1 | grep -qi "redis" \
    && pass "MCP handshake + search_meetings found the Redis discussion" \
    || fail "MCP session output unexpected: $(echo "$OUT" | tail -1 | cut -c1-120)"

  rm -f "$ROOT/control/agent-access-enabled"
  OUT=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}' \
    | "$CLI" mcp 2>/dev/null)
  echo "$OUT" | grep -q "access_disabled" \
    && pass "tools refused while the Privacy toggle marker is absent" \
    || fail "expected access_disabled, got: $(echo "$OUT" | cut -c1-120)"

  if [ "$(curl -s -o /dev/null -w '%{http_code}' -m 2 http://127.0.0.1:17872/health 2>/dev/null)" = "200" ]; then
    touch "$ROOT/control/agent-access-enabled"
    OUT=$(printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ask_library","arguments":{"question":"Which datastore did we choose for caching?"}}}' \
      | "$CLI" mcp 2>/dev/null)
    echo "$OUT" | grep -qi "redis" \
      && pass "ask_library answered from the meeting (mentions 'Redis')" \
      || fail "ask_library answer missing expected content: $(echo "$OUT" | cut -c1-160)"
    rm -f "$ROOT/control/agent-access-enabled"
  else
    skip "llama-server not serving on 17872 — ask_library round-trip skipped"
  fi
fi

echo
echo "passed: $P · failed: $F · skipped: $S"
[ "$F" -eq 0 ]
