#!/usr/bin/env bash
# Run an isolated Cotypist/LokalBot comparison and restore the cotyping apps
# that were running when the benchmark began.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT_ROOT="${COTYPING_OUTPUT_ROOT:-/tmp}"
COTYPIST_DIR="$OUTPUT_ROOT/cotyping-cotypist-$STAMP"
LOKALBOT_DIR="$OUTPUT_ROOT/cotyping-lokalbot-$STAMP"
REPORT_PATH="${COTYPING_REPORT_PATH:-$REPO/Benchmarks/Cotyping/results/$STAMP-cotypist-vs-lokalbot.md}"
COMPARE_SCRIPT="${COTYPING_COMPARE_SCRIPT:-$REPO/Scripts/compare-cotyping.sh}"
REPORT_SCRIPT="${COTYPING_REPORT_SCRIPT:-$REPO/Benchmarks/Cotyping/side_by_side.py}"
REINSTALL_SCRIPT="${COTYPING_REINSTALL_SCRIPT:-$REPO/Scripts/reinstall-preserve-permissions.sh}"
ENGINE_JSON="${COTYPING_ENGINE_JSON:-/tmp/lokalbot-cotyping-bench.json}"

app_running() {
  pgrep -x "$1" >/dev/null
}

initial_cotabby=0
initial_cotypist=0
app_running Cotabby && initial_cotabby=1
app_running Cotypist && initial_cotypist=1

# The production app may be recording, and a shell script cannot safely infer
# that live state from outside the process. Require the user to finish and quit
# it themselves instead of sending an unconditional quit event.
if app_running LokalBot; then
  printf 'LokalBot is running. Finish any recording and quit it yourself before benchmarking; no apps were stopped.\n' >&2
  exit 1
fi

owned_lokalbot_pid=""

stop_app() {
  local process="$1"
  local bundle="$2"
  local _
  app_running "$process" || return 0
  if ! osascript -e "tell application id \"$bundle\" to quit" >/dev/null 2>&1; then
    printf 'Could not request a clean quit from %s.\n' "$process" >&2
    return 1
  fi
  for _ in $(seq 1 40); do
    app_running "$process" || return 0
    sleep 0.25
  done
  printf '%s is still running; refusing a mixed cotyping leg.\n' "$process" >&2
  return 1
}

stop_all_cotyping_apps() {
  local failed=0
  stop_app Cotabby com.jacobfu.tabby || failed=1
  stop_app Cotypist app.cotypist.Cotypist || failed=1
  stop_owned_lokalbot || failed=1
  return "$failed"
}

refresh_owned_lokalbot_pid() {
  local pid_file="$LOKALBOT_DIR/target.pid"
  local recorded_pid
  [[ -f "$pid_file" ]] || return 0
  recorded_pid="$(cat "$pid_file")"
  if [[ "$recorded_pid" =~ ^[0-9]+$ ]]; then
    owned_lokalbot_pid="$recorded_pid"
  fi
}

stop_owned_lokalbot() {
  local running_pids
  app_running LokalBot || {
    owned_lokalbot_pid=""
    return 0
  }
  refresh_owned_lokalbot_pid
  running_pids="$(pgrep -x LokalBot)"
  if [[ -z "$owned_lokalbot_pid" || "$running_pids" != "$owned_lokalbot_pid" ]]; then
    printf 'LokalBot is running, but it is not the benchmark-owned process; refusing to quit it.\n' >&2
    return 1
  fi
  stop_app LokalBot me.dotenv.LokalBot
  owned_lokalbot_pid=""
}

launch_app() {
  local process="$1"
  local bundle="$2"
  local _
  open -b "$bundle" >/dev/null 2>&1 || {
    printf 'Could not relaunch %s (%s).\n' "$process" "$bundle" >&2
    return 1
  }
  for _ in $(seq 1 40); do
    app_running "$process" && return 0
    sleep 0.25
  done
  printf '%s did not appear after relaunch.\n' "$process" >&2
  return 1
}

restore_initial_apps() {
  local failed=0
  stop_all_cotyping_apps || failed=1
  [[ "$initial_cotabby" == 1 ]] && launch_app Cotabby com.jacobfu.tabby || true
  [[ "$initial_cotypist" == 1 ]] && launch_app Cotypist app.cotypist.Cotypist || true
  if [[ "$initial_cotabby" == 1 ]] && ! app_running Cotabby; then failed=1; fi
  if [[ "$initial_cotypist" == 1 ]] && ! app_running Cotypist; then failed=1; fi
  return "$failed"
}

finish() {
  local status=$?
  local restore_status=0
  trap - EXIT INT TERM
  set +e
  restore_initial_apps
  restore_status=$?
  if (( status == 0 && restore_status != 0 )); then
    printf 'Comparison finished, but the original cotyping app state could not be restored.\n' >&2
    status=1
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_complete_leg() {
  local directory="$1"
  local target="$2"
  local marker="$directory/capture.complete"
  [[ -s "$marker" ]] || {
    printf '%s leg has no completion marker: %s\n' "$target" "$marker" >&2
    return 1
  }
  grep -Fxq "target=$target" "$marker" || {
    printf '%s leg completion marker names the wrong target.\n' "$target" >&2
    return 1
  }
  grep -Eq '^prompt_count=[1-9][0-9]*$' "$marker" || {
    printf '%s leg completion marker has no positive prompt count.\n' "$target" >&2
    return 1
  }
}

echo "== isolate cotyping apps =="
stop_all_cotyping_apps

echo "== install freshly built LokalBot without launching it =="
"$REINSTALL_SCRIPT" --no-relaunch

export COTYPING_COMPARE_ACCEPT=1
export COTYPING_COMPARE_FIRST_WAIT_SECONDS="${COTYPING_COMPARE_FIRST_WAIT_SECONDS:-30}"
export COTYPING_COMPARE_WAIT_SECONDS="${COTYPING_COMPARE_WAIT_SECONDS:-6}"
export COTYPING_COMPARE_ACCEPT_WAIT_SECONDS="${COTYPING_COMPARE_ACCEPT_WAIT_SECONDS:-0.9}"

echo "== leg A: Cotypist =="
stop_all_cotyping_apps
"$COMPARE_SCRIPT" cotypist "$COTYPIST_DIR"
require_complete_leg "$COTYPIST_DIR" cotypist
stop_all_cotyping_apps

echo "== leg B: LokalBot =="
"$COMPARE_SCRIPT" lokalbot "$LOKALBOT_DIR"
refresh_owned_lokalbot_pid
require_complete_leg "$LOKALBOT_DIR" lokalbot
stop_all_cotyping_apps

echo "== merge and verify report =="
python3 "$REPORT_SCRIPT" \
  --cotypist-dir "$COTYPIST_DIR" \
  --lokalbot-dir "$LOKALBOT_DIR" \
  --engine-json "$ENGINE_JSON" \
  --output "$REPORT_PATH"

python3 - "$REPORT_PATH" <<'PY'
import json
from pathlib import Path
import sys

report = Path(sys.argv[1])
payload_path = report.with_suffix(".json")
if not report.is_file() or not report.stat().st_size:
    raise SystemExit("Side-by-side Markdown report is missing or empty")
if not payload_path.is_file() or not payload_path.stat().st_size:
    raise SystemExit("Side-by-side JSON report is missing or empty")
payload = json.loads(payload_path.read_text(encoding="utf-8"))
rows = payload.get("rows") or []
if not rows:
    raise SystemExit("Side-by-side report contains no prompt rows")
for app in ("cotypist", "lokalbot"):
    captured = payload.get("totals", {}).get(app, {}).get("captured")
    if captured != len(rows):
        raise SystemExit(f"{app} report is incomplete: {captured}/{len(rows)} captures")
for row in rows:
    for app in ("cotypist", "lokalbot"):
        evidence = row.get("apps", {}).get(app)
        if not evidence or evidence.get("insertion") is None:
            raise SystemExit(f"{app} report has unusable acceptance evidence for {row.get('slug')}")
PY

printf 'COTYPIST_DIR=%s\n' "$COTYPIST_DIR"
printf 'LOKALBOT_DIR=%s\n' "$LOKALBOT_DIR"
printf 'REPORT_PATH=%s\n' "$REPORT_PATH"
printf 'report=%s\ncompleted_at=%s\n' "$REPORT_PATH" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  > /tmp/side-by-side-done
