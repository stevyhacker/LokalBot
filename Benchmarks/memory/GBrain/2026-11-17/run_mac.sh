#!/usr/bin/env bash
# Full run on a Mac with LokalBot installed: both systems share one
# EmbeddingGemma 2 llama-server started here on its own port (the app's own
# servers are left alone). Headless: no app, no windows. Public data only.
#
#   Benchmarks/memory/GBrain/2026-11-17/run_mac.sh        (from the repository root)
#
# Writes everything under Local/gbrain-bench/ (git-ignored); results land in
# Local/gbrain-bench/results/ and summary.md.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
WORK="$ROOT/Local/gbrain-bench"
EXT="$WORK/ext"; W="$WORK/work"
PORT="${PORT:-18473}"
APP="$HOME/Library/Application Support/me.dotenv.LokalBot"
GBRAIN_COMMIT=c5a80f17f37149ccc1c8a514c9971d38368b4f55
mkdir -p "$EXT" "$W"
log() { printf '\n== %s  %s\n' "$(date +%H:%M:%S)" "$*"; }

log "tools"
for t in python3 git cargo; do command -v "$t" >/dev/null || { echo "missing $t"; exit 1; }; done
if ! command -v bun >/dev/null; then
  # A private copy under Local/, nothing installed system-wide.
  if [ ! -x "$WORK/tools/bun/bun" ]; then
    mkdir -p "$WORK/tools"
    arch=$( [ "$(uname -m)" = arm64 ] && echo aarch64 || echo x64 )
    curl -fsSL -o "$WORK/tools/bun.zip" "https://github.com/oven-sh/bun/releases/download/bun-v1.4.4/bun-darwin-$arch.zip"
    (cd "$WORK/tools" && unzip -qo bun.zip && mv "bun-darwin-$arch" bun)
  fi
  export PATH="$WORK/tools/bun:$PATH"
fi
bun --version; cargo --version; sysctl -n machdep.cpu.brand_string; sysctl -n hw.memsize

log "model and llama-server"
MODEL="$APP/models/embeddinggemma-2-Q8_0.gguf"
SERVER="$(ls -t "$APP"/llama-cpp/*/llama-server | head -1)"
[ -f "$MODEL" ] && [ -x "$SERVER" ] || { echo "EmbeddingGemma or llama-server not found under $APP"; exit 1; }
want=$(awk '$1=="embeddinggemma-2-Q8_0.gguf"{print $2}' "$ROOT/Benchmarks/search/EmbeddingGemma2/2026-10-07/model-checksums.txt")
have=$(shasum -a 256 "$MODEL" | awk '{print $1}')
[ "$want" = "$have" ] || { echo "model checksum $have differs from $want"; exit 1; }
"$SERVER" --version 2>&1 | head -2 || true

log "sources"
[ -d "$EXT/QMSum" ] || git clone -q https://github.com/Yale-LILY/QMSum.git "$EXT/QMSum"
if [ ! -d "$EXT/gbrain" ]; then git clone -q https://github.com/garrytan/gbrain.git "$EXT/gbrain"; fi
(cd "$EXT/gbrain" && git fetch -q origin "$GBRAIN_COMMIT" 2>/dev/null || true; git checkout -q "$GBRAIN_COMMIT" && bun install --frozen-lockfile >/dev/null)
G="$EXT/gbrain"
(cd "$EXT/QMSum" && git rev-parse HEAD)
python3 -I "$HERE/prepare.py" --qmsum "$EXT/QMSum" --out "$W"
(cd "$HERE" && python3 -I make_corrections.py "$W/corpus.jsonl" "$W/corr")

log "build the LokalBot harness"
(cd "$HERE/lokalbot-harness" && CARGO_TARGET_DIR="$WORK/target" cargo build --release --locked 2>&1 | tail -1)
B="$WORK/target/release/lokalbot-memory-bench"

log "start llama-server on $PORT"
"$SERVER" -m "$MODEL" --host 127.0.0.1 --port "$PORT" --embeddings -b 2048 -ub 2048 -ngl 99 --no-webui \
  > "$W/llama-server.log" 2>&1 &
LLAMA=$!
trap 'kill $LLAMA 2>/dev/null || true' EXIT
for _ in $(seq 120); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 1; done
curl -fs "http://127.0.0.1:$PORT/health"
EMB="http://127.0.0.1:$PORT/v1"
sample_llama() { while kill -0 "$LLAMA" 2>/dev/null; do ps -o rss= -p "$LLAMA" >> "$W/llama-rss.txt"; sleep 5; done; }
sample_llama &

R="$W/mac-resources.json"; rm -f "$R"
M() { python3 "$HERE/measure.py" "$@"; }

log "LokalBot: ingest, embed, query"
rm -rf "$W/lblib"
M lokalbot-ingest "$R" -- "$B" ingest "$W/corpus.jsonl" "$W/lblib"
M lokalbot-embed "$R" -- "$B" embed "$W/lblib" "$EMB"
M lokalbot-query-keyword "$R" -- "$B" query "$W/lblib" "$W/queries.jsonl" "$W/lb-keyword.jsonl"
M lokalbot-query-hybrid "$R" -- "$B" query "$W/lblib" "$W/queries.jsonl" "$W/lb-hybrid.jsonl" "$EMB"
du -sk "$W/lblib" > "$W/lb-disk.txt"

log "LokalBot: corrections"
"$B" facts "$W/corr/facts.json" "$W/lb-facts.json"
rm -rf "$W/lbpairs"
"$B" ingest "$W/corr/pairs/corpus.jsonl" "$W/lbpairs"
"$B" embed "$W/lbpairs" "$EMB"
"$B" query "$W/lbpairs" "$W/corr/pairs/queries.jsonl" "$W/lb-pairs-before.jsonl" "$EMB"
for n in $(seq -w 0 19); do "$B" delete "$W/lbpairs" "pair$n-older"; done
"$B" query "$W/lbpairs" "$W/corr/pairs/queries.jsonl" "$W/lb-pairs-after.jsonl" "$EMB"

gb_init() { # <home> [embedding]
  export GBRAIN_HOME="$1"; rm -rf "$GBRAIN_HOME"; mkdir -p "$GBRAIN_HOME"
  if [ "${2:-}" = embedding ]; then
    (cd "$G" && LLAMA_SERVER_BASE_URL="$EMB" bun src/cli.ts init --pglite --embedding-model llama-server:embeddinggemma-2 \
      --embedding-dimensions 768 --non-interactive --json > "$GBRAIN_HOME/init.json" 2>&1)
  else
    (cd "$G" && bun src/cli.ts init --pglite --no-embedding --non-interactive --json > "$GBRAIN_HOME/init.json" 2>&1)
  fi
  (cd "$G" && bun src/cli.ts transcripts archive off >/dev/null 2>&1; bun src/cli.ts config set maintenance.auto false >/dev/null 2>&1)
}
export LLAMA_SERVER_BASE_URL="$EMB"

log "GBrain keyword-only"
gb_init "$W/gb-keyword-home"
(cd "$G" && M gbrain-import-keyword "$R" -- bun src/cli.ts import "$W/gbrain" --no-embed --json > "$W/gb-import-keyword.json")
M gbrain-query-keyword "$R" -- python3 "$HERE/gbrain_run.py" "$G" "$W/corpus.jsonl" "$W/queries.jsonl" "$W/gb-keyword.jsonl" --tools query 2> "$W/gb-keyword.log"
du -sk "$GBRAIN_HOME/.gbrain/brain.pglite" > "$W/gb-keyword-disk.txt"

log "GBrain with EmbeddingGemma"
gb_init "$W/gb-hybrid-home" embedding
(cd "$G" && M gbrain-import-embed "$R" -- bun src/cli.ts import "$W/gbrain" --json > "$W/gb-import-hybrid.json")
(cd "$G" && bun src/cli.ts embed --stale > "$W/gb-embed-stale.log" 2>&1 || true)
M gbrain-query-hybrid "$R" -- python3 "$HERE/gbrain_run.py" "$G" "$W/corpus.jsonl" "$W/queries.jsonl" "$W/gb-hybrid.jsonl" --tools query 2> "$W/gb-hybrid.log"
du -sk "$GBRAIN_HOME/.gbrain/brain.pglite" > "$W/gb-hybrid-disk.txt"
(cd "$G" && bun src/cli.ts doctor --json --fast > "$W/gb-doctor.json" 2>&1 || true)

log "GBrain corrections (with embeddings)"
python3 "$HERE/gbrain_corrections.py" "$G" "$W/corr/facts.json" "$W" "$W/gb-facts.json" \
  --init-args "--pglite --embedding-model llama-server:embeddinggemma-2 --embedding-dimensions 768"
gb_init "$W/gb-pairs-home" embedding
(cd "$G" && bun src/cli.ts import "$W/corr/pairs/gbrain" --json > /dev/null 2>&1)
python3 "$HERE/gbrain_run.py" "$G" "$W/corr/pairs/corpus.jsonl" "$W/corr/pairs/queries.jsonl" "$W/gb-pairs-before.jsonl" --tools query 2>/dev/null
(cd "$G" && for n in $(seq -w 0 19); do bun src/cli.ts delete "meetings/pair$n-older" --force --json >/dev/null 2>&1 || echo "delete pair$n failed"; done)
python3 "$HERE/gbrain_run.py" "$G" "$W/corr/pairs/corpus.jsonl" "$W/corr/pairs/queries.jsonl" "$W/gb-pairs-after.jsonl" --tools query 2>/dev/null

log "score"
sort -n "$W/llama-rss.txt" | tail -1 | awk '{printf "{\"llama_server_peak_rss_mb\": %.1f}\n", $1/1024}' > "$W/llama-peak.json"
python3 "$HERE/score.py" "$W" "$WORK/results" \
  lokalbot-keyword=lb-keyword.jsonl:lb gbrain-keyword=gb-keyword.jsonl:gb \
  lokalbot-hybrid=lb-hybrid.jsonl:lb gbrain-hybrid=gb-hybrid.jsonl:gb | tee "$WORK/summary.md"
cp "$R" "$W"/*-disk.txt "$W/llama-peak.json" "$W"/gb-*.log "$WORK/results/" 2>/dev/null || true
log "done"
