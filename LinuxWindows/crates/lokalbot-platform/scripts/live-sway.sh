#!/usr/bin/env bash
# Runs the ignored Wayland live tests inside a headless Sway session with a
# private runtime folder and D-Bus session. Needs sway, foot, wtype and
# dbus-run-session.
# Usage: crates/lokalbot-platform/scripts/live-sway.sh
set -euo pipefail
if [ -z "${LOKALBOT_LIVE_BUS:-}" ]; then
  exec env LOKALBOT_LIVE_BUS=1 dbus-run-session -- "$0" "$@"
fi
cd "$(dirname "$0")/../../.."
runtime="$(mktemp -d)"
chmod 700 "$runtime"
export XDG_RUNTIME_DIR="$runtime"
export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1
unset DISPLAY WAYLAND_DISPLAY SWAYSOCK
printf 'output HEADLESS-1 resolution 1280x800\n' >"$runtime/sway.conf"
sway -c "$runtime/sway.conf" >"$runtime/sway.log" 2>&1 &
pids=($!)
trap 'kill "${pids[@]}" 2>/dev/null || true; rm -rf "$runtime"' EXIT
for _ in $(seq 100); do
  compgen -G "$runtime/sway-ipc.*.sock" >/dev/null && break
  sleep 0.1
done
SWAYSOCK="$(compgen -G "$runtime/sway-ipc.*.sock" | head -n1)"
WAYLAND_DISPLAY="$(cd "$runtime" && compgen -G 'wayland-*' | grep -v lock | head -n1)"
[ -n "$SWAYSOCK" ] && [ -n "$WAYLAND_DISPLAY" ] || { cat "$runtime/sway.log" >&2; exit 1; }
export SWAYSOCK WAYLAND_DISPLAY XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=sway

cargo test -p lokalbot-platform --test live_wayland -- --ignored --test-threads=1 --nocapture
