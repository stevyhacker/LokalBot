#!/usr/bin/env bash
# Checks autocomplete's desktop side on a private Xvfb display and D-Bus
# session with the accessibility bus: the field watcher reads a GTK reply
# field (text, caret, window title, the messages above it), Tab is taken
# while active and types the accepted text through AT-SPI, and the password
# field is never read. Needs Xvfb, xfwm4, xdotool, python3-gi with GTK 3,
# at-spi2-core and dbus-run-session.
# Usage: crates/lokalbot-platform/scripts/live-autocomplete.sh [display number]
set -euo pipefail
if [ -z "${LOKALBOT_LIVE_BUS:-}" ]; then
  exec env LOKALBOT_LIVE_BUS=1 dbus-run-session -- "$0" "$@"
fi
cd "$(dirname "$0")/../../.."
export DISPLAY=":${1:-96}"
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11
out="$(mktemp -d)"

Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
pids=($!)
trap 'kill "${pids[@]}" 2>/dev/null || true' EXIT
for _ in $(seq 100); do xdotool getdisplaygeometry >/dev/null 2>&1 && break; sleep 0.1; done
xfwm4 --compositor=off >/dev/null 2>&1 &
pids+=($!)
sleep 1

python3 crates/lokalbot-platform/scripts/autocomplete-field.py "Reply to Sarah" >"$out/field.log" 2>&1 &
pids+=($!)
window=""
for _ in $(seq 100); do
  window="$(xdotool search --name "Reply to Sarah" 2>/dev/null | head -n1 || true)"
  [ -n "$window" ] && break
  sleep 0.1
done
[ -n "$window" ] || { echo "the test window did not appear" >&2; cat "$out/field.log"; exit 1; }
xdotool windowactivate --sync "$window"
sleep 1
xdotool type --delay 20 "Thanks for the update. I wanted to follow"

cargo build -q -p lokalbot-platform --example autocomplete_watch
watch="${CARGO_TARGET_DIR:-target}/debug/examples/autocomplete_watch"
"$watch" --seconds 6 --tab " up" >"$out/watch.log" 2>&1 &
pids+=($!)
sleep 3
xdotool key Tab
sleep 2
cat "$out/watch.log"
reply="$(grep '^REPLY ' "$out/field.log" | tail -n1)"
echo "$reply"
case "$reply" in
  *'I wanted to follow up"') echo "PASS: Tab typed the accepted text" ;;
  *) echo "FAIL: the reply field did not get the accepted text" >&2; exit 1 ;;
esac
grep -q 'before="Thanks for the update. I wanted to follow"' "$out/watch.log" \
  || { echo "FAIL: the watcher did not read the text before the caret" >&2; exit 1; }
if grep -q 'hunter' "$out/watch.log"; then echo "FAIL: read a password" >&2; exit 1; fi
echo "PASS: the watcher read the field"
