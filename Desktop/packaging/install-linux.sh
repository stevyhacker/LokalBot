#!/usr/bin/env bash
# Optional user-only installation from an extracted artifact.
set -euo pipefail
package_dir="$(cd "$(dirname "$0")/.." && pwd)"
install_dir="${XDG_DATA_HOME:-$HOME/.local/share}/lokalbot-desktop"
bin_dir="$HOME/.local/bin"
mkdir -p "$install_dir" "$bin_dir" "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
for binary in lokalbot-desktop lokalbot-desktop-cli whisper-cli; do
  if [[ -f "$package_dir/$binary" ]]; then install -m 755 "$package_dir/$binary" "$install_dir/$binary"; ln -sf "$install_dir/$binary" "$bin_dir/$binary"; fi
done
cat > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/lokalbot-desktop.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LokalBot
Comment=Private work memory
Exec="$install_dir/lokalbot-desktop"
Terminal=false
Categories=Office;Utility;
EOF
printf 'Installed to %s. Add %s to PATH for the CLI.\n' "$install_dir" "$bin_dir"
