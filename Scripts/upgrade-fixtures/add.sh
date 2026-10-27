#!/usr/bin/env bash
# Add a published release's upgrade fixture to LokalBotTests/Fixtures/upgrade.
# The release run builds it once the DMG is published and keeps it for 90
# days; a dispatched Upgrade fixtures run on master works too:
#   gh workflow run upgrade-fixtures.yml --ref master -f versions=VERSION
# Only runs of master or the release's own tag in this repository count.
set -euo pipefail
VERSION="${1:?Usage: Scripts/upgrade-fixtures/add.sh VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Not a stable release version: $VERSION" >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT_DIR/LokalBotTests/Fixtures/upgrade/$VERSION"
REPO=stevyhacker/LokalBot
[[ ! -e "$DEST" ]] || { echo "$DEST already exists" >&2; exit 1; }

RUN=$(gh api "repos/$REPO/actions/artifacts?name=upgrade-fixture-$VERSION&per_page=100" --jq "
  [.artifacts[] | select(.expired | not)
    | select(.workflow_run.head_repository_id == .workflow_run.repository_id)
    | select(.workflow_run.head_branch == \"master\" or .workflow_run.head_branch == \"v$VERSION\")]
  | sort_by(.created_at) | last | .workflow_run.id // empty")
if [[ -z "$RUN" ]]; then
  echo "No unexpired upgrade-fixture-$VERSION from master or v$VERSION. Build it, then run this again:" >&2
  echo "  gh workflow run upgrade-fixtures.yml --ref master -f versions=$VERSION" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh run download "$RUN" --repo "$REPO" --name "upgrade-fixture-$VERSION" --dir "$WORK"
TAR="$WORK/fixture-$VERSION.tar"
if tar -tf "$TAR" | grep -Eq '^/|(^|/)\.\.(/|$)'; then
  echo "The fixture tarball names a path outside its folder" >&2
  exit 1
fi
mkdir -p "$DEST"
tar -xf "$TAR" -C "$DEST"
# Fixtures built before generate.sh folded the write-ahead log.
for db in "$DEST"/library/*.sqlite; do
  sqlite3 "$db" 'PRAGMA wal_checkpoint(TRUNCATE)' >/dev/null
  rm -f "$db-wal" "$db-shm"
done
python3 - "$DEST/manifest.json" "$VERSION" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
if manifest.get("version") != sys.argv[2] or not manifest.get("note", "").startswith("Synthetic library"):
    sys.exit(f"{sys.argv[1]} is not the synthetic {sys.argv[2]} fixture")
PY
echo "Added $DEST from run $RUN. Commit it with the release candidate."
