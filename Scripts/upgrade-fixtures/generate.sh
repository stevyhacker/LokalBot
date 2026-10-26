#!/usr/bin/env bash
# Build one upgrade fixture on a CLEAN hosted Mac: seed with that release's
# own seed script, write its settings, open the library with that release's
# signed build (headless), and export library + defaults + test key.
# Writes the real me.dotenv.LokalBot defaults domain and Keychain items, so
# it refuses to run outside CI.
set -euo pipefail
[[ "${CI:-}" == "true" ]] || { echo "generate.sh writes the app's real defaults and Keychain; run it only in CI" >&2; exit 2; }
VERSION="${1:?version}"
OUT="${2:?output dir}"
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
LIB="$WORK/library"
DOMAIN=me.dotenv.LokalBot

git -C "$ROOT_DIR" show "v$VERSION:Scripts/seed_demo_library.py" > "$WORK/seed.py"
python3 "$WORK/seed.py" "$LIB"
# Releases with Personal Context seed it as plaintext; a real library holds it
# sealed with the chat key, so seal it with the fixture's key.
if [[ -f "$LIB/memory/personal-model.json" ]]; then
  swift "$ROOT_DIR/Scripts/upgrade-fixtures/seal.swift" \
    "$(python3 "$ROOT_DIR/Scripts/upgrade-fixtures/settings.py" key chat-key)" \
    "$LIB/memory/personal-model.json" "$LIB/memory/personal-model.json.enc"
  rm "$LIB/memory/personal-model.json"
fi

defaults delete "$DOMAIN" >/dev/null 2>&1 || true
SETTINGS=$(python3 "$ROOT_DIR/Scripts/upgrade-fixtures/settings.py" "$VERSION")
defaults write "$DOMAIN" lokalbotv3.settings -data "$(printf '%s' "$SETTINGS" | xxd -p | tr -d '\n')"
for account in screenshot-key chat-key; do
  security delete-generic-password -s "$DOMAIN" -a "$account" >/dev/null 2>&1 || true
  security add-generic-password -A -s "$DOMAIN" -a "$account" \
    -X "$(python3 "$ROOT_DIR/Scripts/upgrade-fixtures/settings.py" key "$account")"
done

# Releases before 0.11.2 only have LokalBot.dmg; later ones add the version.
gh release download "v$VERSION" --repo stevyhacker/LokalBot \
  --pattern "LokalBot-$VERSION-macos-arm64.dmg" --output "$WORK/LokalBot.dmg" 2>/dev/null \
  || gh release download "v$VERSION" --repo stevyhacker/LokalBot --pattern LokalBot.dmg --dir "$WORK"
MOUNT=$(hdiutil attach -nobrowse -readonly "$WORK/LokalBot.dmg" | tail -1 | awk -F'\t' '{print $NF}')
cp -R "$MOUNT/LokalBot.app" "$WORK/LokalBot.app"
hdiutil detach "$MOUNT" -quiet

LOKALBOT_STORAGE_ROOT="$LIB" "$WORK/LokalBot.app/Contents/MacOS/LokalBot" --search "caching" \
  > "$WORK/search.log" 2>&1 || { cat "$WORK/search.log"; exit 1; }

mkdir -p "$OUT"
rsync -a --exclude models --exclude debug.log --exclude 'debug.log.*' "$LIB/" "$OUT/library/"
# Fold the write-ahead log into the database so the fixture commits as is.
for db in "$OUT"/library/*.sqlite; do
  sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE)' >/dev/null
  rm -f "$db-wal" "$db-shm"
done
defaults export "$DOMAIN" "$OUT/defaults.plist"
python3 - "$VERSION" "$OUT/manifest.json" <<'PY'
import json, sys, datetime
json.dump({"version": sys.argv[1], "keyDerivation": "sha256('lokalbot-upgrade-fixture-<account>')",
           "accounts": ["screenshot-key", "chat-key"],
           "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "note": "Synthetic library and test-only keys. Safe to commit."}, open(sys.argv[2], "w"), indent=2)
PY
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
for account in screenshot-key chat-key; do
  security delete-generic-password -s "$DOMAIN" -a "$account" >/dev/null 2>&1 || true
done
echo "$OUT"
