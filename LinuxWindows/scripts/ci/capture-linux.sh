#!/usr/bin/env bash
set -euo pipefail
trap 'echo "capture-linux.sh: line $LINENO failed: $BASH_COMMAND" >&2' ERR

if [ -z "${LB_CAPTURE_SESSION:-}" ] && command -v dbus-run-session >/dev/null; then
  export LB_CAPTURE_SESSION=1
  CONFIG="$(mktemp -d)"
  mkdir -p "$CONFIG/xfce4/xfconf/xfce-perchannel-xml"
  cat > "$CONFIG/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="length" type="double" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="36"/>
      <property name="icon-size" type="uint" value="18"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="applicationsmenu"/>
    <property name="plugin-2" type="string" value="tasklist"/>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="clock"/>
  </property>
</channel>
XML
  export XDG_CONFIG_HOME="$CONFIG"
  exec dbus-run-session -- "$0" "$@"
fi

BIN="$1"; ROOT="$2"; OUT="$3"; shift 3
PAGES=("${@:-today}")
DISPLAY_NUM="${CAPTURE_DISPLAY:-:91}"
SIZE="${CAPTURE_SIZE:-1600x1000}"
SUFFIX="${CAPTURE_SUFFIX:-}"
mkdir -p "$OUT"
Xvfb "$DISPLAY_NUM" -screen 0 "${SIZE}x24" -nolisten tcp >/tmp/lokalbot-xvfb.log 2>&1 &
XVFB=$!
PIDS=()
trap 'kill "${PIDS[@]}" 2>/dev/null || true; kill $XVFB 2>/dev/null || true' EXIT
sleep 1
DISPLAY="$DISPLAY_NUM" xfwm4 --compositor=on >/tmp/lokalbot-xfwm4.log 2>&1 &
PIDS+=($!)
wait_for() {
  local what="$1"; shift
  for _ in $(seq 60); do
    "$@" && return 0
    sleep 0.5
  done
  echo "capture-linux.sh: no $what after 30 s, capturing anyway" >&2
}
wm_ready() {
  local supported
  supported=$(DISPLAY="$DISPLAY_NUM" xprop -root _NET_SUPPORTED 2>/dev/null) || return 1
  [[ $supported == *_GTK_FRAME_EXTENTS* ]]
}
tray_ready() {
  local reply
  reply=$(dbus-send --session --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus.NameHasOwner string:org.kde.StatusNotifierWatcher 2>/dev/null) || return 1
  [[ $reply == *"boolean true"* ]]
}
wait_for "window manager" wm_ready
DISPLAY="$DISPLAY_NUM" hsetroot -add "#1d4e57" -add "#2b3446" -gradient 160 >/dev/null 2>&1 \
  || DISPLAY="$DISPLAY_NUM" xsetroot -solid '#2b3446' 2>/dev/null || true
if [ -n "${LB_CAPTURE_SESSION:-}" ] && command -v xfce4-panel >/dev/null; then
  DISPLAY="$DISPLAY_NUM" xfce4-panel >/tmp/lokalbot-panel.log 2>&1 &
  PIDS+=($!)
  wait_for "system tray" tray_ready
fi
sleep 2
for page in "${PAGES[@]}"; do
  DISPLAY="$DISPLAY_NUM" xdotool mousemove 2 2 2>/dev/null || true
  case "$page" in
    settings*) TITLE='^Settings$'; ARGS=(--page "$page") ;;
    quick-recall) TITLE='^Quick Recall$'; ARGS=(--window quick-recall) ;;
    *) TITLE='^LokalBot$'; ARGS=(--page "$page") ;;
  esac
  DISPLAY="$DISPLAY_NUM" LOKALBOT_STORAGE_ROOT="$ROOT" "$BIN" "${ARGS[@]}" >/tmp/lokalbot-$page.log 2>&1 &
  APP=$!
  sleep "${CAPTURE_WAIT:-8}"
  if ! kill -0 "$APP" 2>/dev/null; then
    echo "LokalBot exited early on page $page:"; cat "/tmp/lokalbot-$page.log"; exit 1
  fi
  WID=$(DISPLAY="$DISPLAY_NUM" xdotool search --sync --onlyvisible --name "$TITLE" | head -1 || true)
  if [ -n "$WID" ]; then
    eval "$(DISPLAY="$DISPLAY_NUM" xdotool getwindowgeometry --shell "$WID")"
    DISPLAY="$DISPLAY_NUM" xdotool windowmove "$WID" $(( (${SIZE%x*} - WIDTH) / 2 )) \
      $(( (${SIZE#*x} - 36 - HEIGHT) / 2 )) 2>/dev/null || true
  fi
  DISPLAY="$DISPLAY_NUM" xdotool mousemove 2 2 2>/dev/null || true
  sleep 1
  DISPLAY="$DISPLAY_NUM" ffmpeg -loglevel error -y -f x11grab -draw_mouse 0 -video_size "$SIZE" \
    -i "$DISPLAY_NUM" -frames:v 1 "$OUT/linux-desktop-$page$SUFFIX.png"
  if [ -n "$WID" ]; then
    eval "$(DISPLAY="$DISPLAY_NUM" xdotool getwindowgeometry --shell "$WID")"
    extents=$(DISPLAY="$DISPLAY_NUM" xprop -id "$WID" _GTK_FRAME_EXTENTS 2>/dev/null \
      | sed -n 's/.*= *//p' | tr -d ',') || true
    read -r L R T B <<<"${extents:-0 0 0 0}"
    ffmpeg -loglevel error -y -i "$OUT/linux-desktop-$page$SUFFIX.png" \
      -vf "crop=$((WIDTH - L - R)):$((HEIGHT - T - B)):$((X + L)):$((Y + T))" "$OUT/linux-$page$SUFFIX.png"
  fi
  kill "$APP" 2>/dev/null || true
  wait "$APP" 2>/dev/null || true
  echo "captured $page"
done
