#!/usr/bin/env bash
# Runs the ignored live tests on a private Xvfb display and D-Bus session:
# the X11 sampler, idle time, shortcuts (press and release), paste and typing
# into GTK and terminal windows, and notification and tray round trips.
# Needs Xvfb, xfwm4, xdotool, xmessage (x11-apps), zenity, xsel,
# xfce4-terminal and dbus-run-session.
# Usage: crates/lokalbot-platform/scripts/live-x11.sh [display number]
set -euo pipefail
if [ -z "${LOKALBOT_LIVE_BUS:-}" ]; then
  exec env LOKALBOT_LIVE_BUS=1 dbus-run-session -- "$0" "$@"
fi
cd "$(dirname "$0")/../../.."
export DISPLAY=":${1:-97}"
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
pids=($!)
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
for _ in $(seq 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xfwm4 --compositor=off >/dev/null 2>&1 &
pids+=($!)
sleep 1

title="Quarterly plan — token=abcdef123456"
xmessage -title "$title" "LokalBot live test" >/dev/null 2>&1 &
pids+=($!)
window=""
for _ in $(seq 100); do
  window="$(xdotool search --name "Quarterly plan" 2>/dev/null | head -n1 || true)"
  [ -n "$window" ] && break
  sleep 0.1
done
[ -n "$window" ] || { echo "the test window did not appear" >&2; exit 1; }
xdotool windowactivate --sync "$window"

LOKALBOT_EXPECT_TITLE="$title" cargo test -p lokalbot-platform \
  --test live_desktop --test live_dbus -- --ignored --test-threads=1 --nocapture
