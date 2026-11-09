#!/usr/bin/env bash
# Runs the ignored KDE Plasma live test inside a headless KWin, with the
# autocomplete input method helper as KWin's input method, a private runtime
# folder and a D-Bus session. Keys go in through KWin's EIS endpoint. Needs
# kwin_wayland (Plasma 6), Python with GTK 3 and PyGObject, libei and
# dbus-run-session. In a container, kwin_wayland needs its file capabilities
# removed (`setcap -r "$(command -v kwin_wayland)"`).
# Usage: crates/lokalbot-platform/scripts/live-kwin.sh
set -euo pipefail
if [ -z "${LOKALBOT_LIVE_BUS:-}" ]; then
  exec env LOKALBOT_LIVE_BUS=1 dbus-run-session -- "$0" "$@"
fi
cd "$(dirname "$0")/../../.."
cargo build -q -p lokalbot-platform --example kwin_input_method
helper="$(realpath "${CARGO_TARGET_DIR:-target}/debug/examples/kwin_input_method")"
runtime="$(mktemp -d)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK HYPRLAND_INSTANCE_SIGNATURE
export KWIN_COMPOSE=Q XDG_CURRENT_DESKTOP=KDE XDG_SESSION_TYPE=wayland
kwin_wayland --virtual --socket wayland-kwin --width 1280 --height 800 \
  --no-lockscreen --no-global-shortcuts --inputmethod "$helper" >"$runtime/kwin.log" 2>&1 &
pids=($!)
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$runtime"' EXIT
for _ in $(seq 100); do
  [ -S "$runtime/wayland-kwin" ] && [ -S "$runtime/lokalbot/kwin-input-method.sock" ] && break
  sleep 0.1
done
[ -S "$runtime/lokalbot/kwin-input-method.sock" ] || { cat "$runtime/kwin.log" >&2; exit 1; }
export WAYLAND_DISPLAY=wayland-kwin GDK_BACKEND=wayland

cargo test -p lokalbot-platform --test live_input_method -- --ignored --test-threads=1 --nocapture kwin
