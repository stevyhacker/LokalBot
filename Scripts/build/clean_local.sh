#!/usr/bin/env bash
# Remove this project's local build/derived/DMG artifacts so the next build
# starts from a clean slate. Scoped to LokalBot artifacts only — it
# never touches installed apps, other projects' DerivedData, or TCC grants.
# Usage: bash Scripts/build/clean_local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "=== LokalBot local build cleanup ==="

# Remove a path (file, dir, or symlink) if it exists, announcing what went.
remove() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "  removing: $target"
    rm -rf "$target"
  fi
}

# Eject mounted LokalBot volumes first so nothing holds a file open while we
# delete the images that back them.
while IFS= read -r vol; do
  [ -z "$vol" ] && continue
  hdiutil detach "$vol" -quiet 2>/dev/null && echo "  ejected: $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -Ei "^LokalBot(V3)?$" | sed 's|^|/Volumes/|' || true)

# Repo-local build outputs.
remove ".build"                 # custom derivedDataPath used by local/e2e builds
remove "build"                  # archive + export + DMG + appcast staging
remove "default.profraw"        # stray code-coverage profile data
remove "/tmp/LokalBot-dmg-venv" # throwaway dmgbuild venv from build_test_dmg.sh
remove "/tmp/LokalBotV3-dmg-venv" # legacy throwaway dmgbuild venv

# DMG images at the repo root and the test-DMG temp location.
shopt -s nullglob
for dmg in ./*.dmg /tmp/LokalBot*.dmg; do
  remove "$dmg"
done

# Xcode DerivedData for THIS project only. The folder is named
# "<ProjectName>-<hash>", so the LokalBot-* glob is project-scoped and safe.
for dd in "$HOME"/Library/Developer/Xcode/DerivedData/LokalBot-*; do
  remove "$dd"
done
shopt -u nullglob

echo "=== Done. Clean slate. ==="
