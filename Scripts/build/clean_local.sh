#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "=== LokalBot local build cleanup ==="

remove() {
  local target="$1"
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "  removing: $target"
    rm -rf "$target"
  fi
}

while IFS= read -r vol; do
  [ -z "$vol" ] && continue
  hdiutil detach "$vol" -quiet 2>/dev/null && echo "  ejected: $vol" || true
done < <(ls /Volumes/ 2>/dev/null | grep -Ei "^LokalBot(V3)?$" | sed 's|^|/Volumes/|' || true)

remove ".build"
remove "build"
remove "default.profraw"
remove "/tmp/LokalBot-dmg-venv"
remove "/tmp/LokalBotV3-dmg-venv"

shopt -s nullglob
for dmg in ./*.dmg /tmp/LokalBot*.dmg; do
  remove "$dmg"
done

for dd in "$HOME"/Library/Developer/Xcode/DerivedData/LokalBot-*; do
  remove "$dd"
done
shopt -u nullglob

echo "=== Done. Clean slate. ==="
