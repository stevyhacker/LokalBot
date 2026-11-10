#!/usr/bin/env bash
# Installs LokalBot for the current user from an extracted release archive:
# binaries into ~/.local/bin, the desktop entries and icons into ~/.local/share.
# The second entry lists LokalBot under KDE Plasma's Virtual Keyboard settings,
# for autocomplete; it is not in the applications menu.
# Run with --uninstall to remove them (your library is never touched).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
APP_ID=com.lokalbot.LokalBot
IM_ENTRY=$APP_ID.InputMethod.desktop
if [ "${1:-}" = "--uninstall" ]; then
  # What this copy set up outside those folders goes too, as the Windows
  # uninstaller removes it: the coding-agent skill from Settings → Advanced →
  # Agent CLI, and a launch-at-login entry that starts this copy.
  [ -x "$BIN/lokalbot-cli" ] && "$BIN/lokalbot-cli" install-skill --uninstall >/dev/null 2>&1 || true
  AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/lokalbot.desktop"
  if [ -f "$AUTOSTART" ] && grep -qF "$BIN/lokalbot" "$AUTOSTART"; then
    rm -f "$AUTOSTART"
  fi
  rm -f "$BIN/lokalbot" "$BIN/lokalbot-cli" "$DATA/applications/$APP_ID.desktop" \
    "$DATA/applications/$IM_ENTRY"
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
if [ -f "$HERE/$IM_ENTRY" ]; then
  install -Dm644 "$HERE/$IM_ENTRY" "$DATA/applications/$IM_ENTRY"
  sed -i "s|^Exec=lokalbot|Exec=$BIN/lokalbot|" "$DATA/applications/$IM_ENTRY"
fi
for size in 16 24 32 48 64 128 256 512; do
  install -Dm644 "$HERE/icons/lokalbot-$size.png" "$DATA/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
done
command -v update-desktop-database >/dev/null && update-desktop-database "$DATA/applications" >/dev/null 2>&1 || true
echo "LokalBot installed. Start it from your applications menu or run: $BIN/lokalbot"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "Note: $BIN is not on your PATH." ;; esac
