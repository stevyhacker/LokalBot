#!/usr/bin/env bash
# Dedicated remote X11 preview; touches only this project's processes and files.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
session_dir="$project_dir/.preview-session"
mkdir -p "$session_dir" "$project_dir/screenshots"
chmod 700 "$session_dir"

case "${1:-start}" in
  start)
    if [[ -f "$session_dir/app.pid" ]] && kill -0 "$(cat "$session_dir/app.pid")" 2>/dev/null; then
      printf 'Preview already running on %s\n' "$(cat "$session_dir/display")"
      exit 0
    fi
    if [[ ! -f "$session_dir/xvfb.pid" ]] || ! kill -0 "$(cat "$session_dir/xvfb.pid")" 2>/dev/null; then
      : > "$session_dir/display-number"
      nohup Xvfb -displayfd 3 -screen 0 1440x960x24 -nolisten tcp -ac -noreset \
        3> "$session_dir/display-number" > "$session_dir/xvfb.log" 2>&1 < /dev/null &
      printf '%s\n' "$!" > "$session_dir/xvfb.pid"
      for _ in {1..50}; do
        [[ -s "$session_dir/display-number" ]] && break
        sleep 0.1
      done
      [[ -s "$session_dir/display-number" ]] || { cat "$session_dir/xvfb.log"; exit 1; }
      printf ':%s\n' "$(cat "$session_dir/display-number")" > "$session_dir/display"
    fi
    app_binary="${LOKALBOT_DESKTOP_BINARY:-$project_dir/target/debug/lokalbot-desktop}"
    [[ -x "$app_binary" ]] || { printf 'Native application is missing: %s\n' "$app_binary"; exit 1; }
    vulkan_icd="${VK_ICD_FILENAMES:-}"
    if [[ -z "$vulkan_icd" ]]; then
      for candidate in /usr/share/vulkan/icd.d/lvp_icd*.json; do
        if [[ -f "$candidate" ]]; then vulkan_icd="$candidate"; break; fi
      done
    fi
    [[ -n "$vulkan_icd" ]] || { printf 'Install Mesa Vulkan drivers for the software-rendered preview.\n'; exit 1; }
    shift || true
    nohup env -u WAYLAND_DISPLAY DISPLAY="$(cat "$session_dir/display")" \
      XDG_RUNTIME_DIR="$session_dir" GPUI_X11_SCALE_FACTOR=1 \
      VK_ICD_FILENAMES="$vulkan_icd" \
      LOKALBOT_STORAGE_ROOT="${LOKALBOT_STORAGE_ROOT:-$session_dir/library}" "$app_binary" "$@" \
      > "$session_dir/app.log" 2>&1 < /dev/null &
    printf '%s\n' "$!" > "$session_dir/app.pid"
    readlink -f "$app_binary" > "$session_dir/app.executable"
    printf 'Started native GPUI preview on %s (PID %s)\n' "$(cat "$session_dir/display")" "$(cat "$session_dir/app.pid")"
    ;;
  capture)
    name="${2:-preview}"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf 'Invalid capture name\n'; exit 1; }
    ffmpeg -nostdin -hide_banner -loglevel error -f x11grab -draw_mouse 0 -video_size 1440x960 \
      -i "$(cat "$session_dir/display")" -frames:v 1 -threads 1 -update 1 -y "$project_dir/screenshots/$name.png"
    printf '%s\n' "$project_dir/screenshots/$name.png"
    ;;
  stop)
    for process in app xvfb; do
      if [[ -f "$session_dir/$process.pid" ]]; then
        process_pid="$(cat "$session_dir/$process.pid")"
        if kill -0 "$process_pid" 2>/dev/null; then
          process_exe="$(readlink "/proc/$process_pid/exe" || true)"
          process_exe="${process_exe% (deleted)}"
          expected_exe="$(readlink -f "$project_dir/target/debug/lokalbot-desktop")"
          if [[ "$process" == app && -f "$session_dir/app.executable" ]]; then expected_exe="$(cat "$session_dir/app.executable")"; fi
          if [[ "$process_exe" == "$expected_exe" || "$process_exe" == /usr/bin/Xvfb ]]; then
            kill "$process_pid"
          fi
        fi
        rm "$session_dir/$process.pid"
      fi
    done
    ;;
  *) printf 'Usage: %s start [--page today|meetings|timeline|ask|type|agent|settings] | capture NAME | stop\n' "$0"; exit 1 ;;
esac
