#!/usr/bin/env bash
# Installs LokalBot for the current user from an extracted release archive:
# binaries into ~/.local/bin, the desktop entry and icons into ~/.local/share.
# Run with --uninstall to remove them (your library is never touched).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_ID=com.lokalbot.LokalBot
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$BIN/lokalbot" "$BIN/lokalbot-cli" "$DATA/applications/$APP_ID.desktop"
  for size in 16 24 32 48 64 128 256 512; do
    rm -f "$DATA/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  done
  echo "LokalBot removed. Your library in $DATA/LokalBot was kept."
  exit 0
fi
install -Dm755 "$HERE/lokalbot" "$BIN/lokalbot"
install -Dm755 "$HERE/lokalbot-cli" "$BIN/lokalbot-cli"
install -Dm644 "$HERE/$APP_ID.desktop" "$DATA/applications/$APP_ID.desktop"
sed -i "s|^Exec=lokalbot|Exec=$BIN/lokalbot|" "$DATA/applications/$APP_ID.desktop"
for size in 16 24 32 48 64 128 256 512; do
  install -Dm644 "$HERE/icons/lokalbot-$size.png" "$DATA/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
echo "LokalBot installed. Start it from your applications menu or run: $BIN/lokalbot"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH." ;; esac
