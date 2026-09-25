#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: Scripts/compare-cotyping.sh cotabby|cotypist|lokalbot [new-output-dir]

Opens TextEdit, types the shared cotyping prompts, waits for the active
cotyping app to show a suggestion, saves one screenshot per prompt, and
records TextEdit document text before optional acceptance. Every operation is
bound to the exact TextEdit document created for that prompt; other documents
are never closed, raised, read, or sent a Tab key.

Requires Accessibility for the shell running this script and Screen Recording
for screencapture. Competing cotyping apps must already be closed. The wrapper
run-cotyping-side-by-side.command performs that lifecycle for a full comparison.

Set COTYPING_COMPARE_ACCEPT=1 to press Tab after the screenshot and record
the resulting TextEdit document text in *.accepted.txt.

Set COTYPING_COMPARE_INPUT_MODE=direct to avoid System Events keystrokes and
write TextEdit's document text directly into a fresh Untitled document. This
lower-fidelity mode can show whether suggestions appear on one-shot
accessibility value changes, but it cannot verify incremental typing or Tab
acceptance.
USAGE
}

target="${1:-}"
case "$target" in
  cotabby) target_app="Cotabby"; target_bundle="com.jacobfu.tabby" ;;
  cotypist) target_app="Cotypist"; target_bundle="app.cotypist.Cotypist" ;;
  lokalbot) target_app="LokalBot"; target_bundle="me.dotenv.LokalBot" ;;
  -h|--help|"") usage; exit 64 ;;
  *) usage; exit 64 ;;
esac

out_dir="${2:-/tmp/cotyping-comparison-${target}-$(date +%Y%m%d-%H%M%S)}"
if [[ -e "$out_dir" ]]; then
  printf 'Output directory already exists; refusing stale evidence: %s\n' "$out_dir" >&2
  exit 73
fi
mkdir -m 700 "$out_dir"
wait_seconds="${COTYPING_COMPARE_WAIT_SECONDS:-5}"
first_wait_seconds="${COTYPING_COMPARE_FIRST_WAIT_SECONDS:-12}"
key_delay_seconds="${COTYPING_COMPARE_KEY_DELAY_SECONDS:-0.025}"
accept_suggestions="${COTYPING_COMPARE_ACCEPT:-0}"
accept_wait_seconds="${COTYPING_COMPARE_ACCEPT_WAIT_SECONDS:-0.7}"
input_mode="${COTYPING_COMPARE_INPUT_MODE:-keys}"

check_other_cotyping_apps() {
  local other
  for other in Cotabby Cotypist LokalBot; do
    if [[ "$other" != "$target_app" ]] && pgrep -x "$other" >/dev/null; then
      printf 'Cannot isolate this comparison while %s is running. Close it yourself when safe, then retry. No apps were stopped.\n' "$other" >&2
      return 1
    fi
  done
}

wait_for_target() {
  local _
  for _ in $(seq 1 20); do
    pgrep -x "$target_app" >/dev/null && return 0
    sleep 0.25
  done
  printf 'Comparison target did not finish launching: %s\n' "$target_app" >&2
  return 1
}

check_other_cotyping_apps
if ! open -b "$target_bundle" >/dev/null 2>&1 && ! open -a "$target_app" >/dev/null 2>&1; then
  printf 'Could not launch comparison target: %s\n' "$target_app" >&2
  exit 1
fi
wait_for_target
target_pids="$(pgrep -x "$target_app")"
if [[ ! "$target_pids" =~ ^[0-9]+$ ]]; then
  printf 'Comparison target did not resolve to one owned process: %s\n' "$target_app" >&2
  exit 1
fi
printf '%s\n' "$target_pids" > "$out_dir/target.pid"
open -b com.apple.TextEdit >/dev/null 2>&1 \
  || open /System/Applications/TextEdit.app >/dev/null 2>&1 \
  || open -a TextEdit
sleep 1

read_document_text() {
  osascript - "$1" <<'OSA'
on run argv
  set benchmarkID to item 1 of argv
  tell application "TextEdit"
    repeat with candidate in documents
      if (id of candidate as text) is benchmarkID then return text of candidate
    end repeat
  end tell
  error "Benchmark document no longer exists"
end run
OSA
}

document_window_rect() {
  osascript - "$1" <<'OSA'
on run argv
  set benchmarkID to item 1 of argv
  tell application "TextEdit"
    set benchmarkDocument to missing value
    repeat with candidate in documents
      if (id of candidate as text) is benchmarkID then set benchmarkDocument to candidate
    end repeat
    if benchmarkDocument is missing value then error "Benchmark document no longer exists"
    set benchmarkWindow to first window whose document is benchmarkDocument
    set index of benchmarkWindow to 1
    activate
    if (id of front document as text) is not benchmarkID then error "Could not activate benchmark document"
    set windowBounds to bounds of benchmarkWindow
    set windowLeft to item 1 of windowBounds
    set windowTop to item 2 of windowBounds
    set windowRight to item 3 of windowBounds
    set windowBottom to item 4 of windowBounds
    return (windowLeft as integer as text) & "," & (windowTop as integer as text) & "," & ((windowRight - windowLeft) as integer as text) & "," & ((windowBottom - windowTop) as integer as text)
  end tell
end run
OSA
}

close_benchmark_document() {
  osascript - "$1" <<'OSA'
on run argv
  set benchmarkID to item 1 of argv
  tell application "TextEdit"
    repeat with candidate in documents
      if (id of candidate as text) is benchmarkID then
        close candidate saving no
        return
      end if
    end repeat
  end tell
  error "Benchmark document no longer exists"
end run
OSA
}

active_document_id=""
cleanup_owned_document() {
  if [[ -n "$active_document_id" ]]; then
    close_benchmark_document "$active_document_id" >/dev/null 2>&1 || true
    active_document_id=""
  fi
}
trap cleanup_owned_document EXIT

capture_prompt() {
  local slug="$1"
  local prompt="$2"
  local document_id="$3"
  local rect
  local verified_rect

  rect="$(document_window_rect "$document_id")"
  if ! [[ "$rect" =~ ^-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+$ ]]; then
    printf 'Invalid owned TextEdit capture rect for %s: %q\n' "$slug" "$rect" >&2
    return 1
  fi
  screencapture -x -R "$rect" "$out_dir/${slug}.png"
  verified_rect="$(document_window_rect "$document_id")"
  if [[ "$verified_rect" != "$rect" ]]; then
    rm -f "$out_dir/${slug}.png"
    printf 'Owned TextEdit document moved or lost focus while capturing %s.\n' "$slug" >&2
    return 1
  fi
  printf '%s\n' "$rect" > "$out_dir/${slug}.rect"
  printf '%s\n' "$prompt" > "$out_dir/${slug}.txt"
}

accept_current_suggestion() {
  osascript - "$1" "$accept_wait_seconds" <<'OSA'
on run argv
  set benchmarkID to item 1 of argv
  set acceptDelay to item 2 of argv as real
  tell application "TextEdit"
    set benchmarkDocument to missing value
    repeat with candidate in documents
      if (id of candidate as text) is benchmarkID then set benchmarkDocument to candidate
    end repeat
    if benchmarkDocument is missing value then error "Benchmark document no longer exists"
    set benchmarkWindow to first window whose document is benchmarkDocument
    set index of benchmarkWindow to 1
    activate
    if (id of front document as text) is not benchmarkID then error "Could not activate benchmark document"
  end tell
  delay 0.1
  tell application "System Events"
    tell process "TextEdit"
      if frontmost is false then error "TextEdit lost focus before benchmark acceptance"
      keystroke tab
    end tell
  end tell
  delay acceptDelay
  tell application "TextEdit"
    if (id of front document as text) is not benchmarkID then error "Benchmark document lost focus during acceptance"
  end tell
end run
OSA
}

create_direct_document() {
  osascript - "$1" <<'OSA'
on run argv
  set promptText to item 1 of argv
  tell application "TextEdit"
    activate
    set benchmarkDocument to make new document
    set text of benchmarkDocument to promptText
    set benchmarkWindow to first window whose document is benchmarkDocument
    set index of benchmarkWindow to 1
    set benchmarkID to id of benchmarkDocument as text
    if (id of front document as text) is not benchmarkID then error "Could not activate new benchmark document"
    return benchmarkID
  end tell
end run
OSA
}

create_typed_document() {
  osascript - "$1" "$key_delay_seconds" <<'OSA'
on run argv
  set promptText to item 1 of argv
  set keyDelay to item 2 of argv as real
  tell application "TextEdit"
    activate
    set benchmarkDocument to make new document
    set benchmarkID to id of benchmarkDocument as text
    set benchmarkWindow to first window whose document is benchmarkDocument
    set index of benchmarkWindow to 1
    if (id of front document as text) is not benchmarkID then error "Could not activate new benchmark document"
  end tell
  delay 0.3
  repeat with characterIndex from 1 to count characters of promptText
    tell application "TextEdit"
      if (id of front document as text) is not benchmarkID then error "Benchmark document lost focus while typing"
    end tell
    tell application "System Events"
      tell process "TextEdit"
        if frontmost is false then error "TextEdit lost focus while typing"
        keystroke (character characterIndex of promptText)
      end tell
    end tell
    if keyDelay > 0 then delay keyDelay
  end repeat
  tell application "TextEdit"
    if (id of front document as text) is not benchmarkID then error "Benchmark document lost focus after typing"
  end tell
  return benchmarkID
end run
OSA
}

validate_prompt_artifacts() {
  local slug="$1"
  local required
  for required in .png .rect .txt .document.txt; do
    if [[ ! -s "$out_dir/${slug}${required}" ]]; then
      printf 'Capture is incomplete for %s: missing or empty %s\n' "$slug" "$required" >&2
      return 1
    fi
  done
  if [[ "$accept_suggestions" == "1" && "$input_mode" == "keys" \
        && ! -f "$out_dir/${slug}.accepted.txt" ]]; then
    printf 'Capture is incomplete for %s: missing acceptance evidence.\n' "$slug" >&2
    return 1
  fi
}

run_prompt() {
  local slug="$1"
  local prompt="$2"
  local prompt_wait_seconds="${3:-3}"
  local document_id

  if [[ "$input_mode" == "direct" ]]; then
    document_id="$(create_direct_document "$prompt")"
  else
    document_id="$(create_typed_document "$prompt")"
  fi
  if [[ -z "$document_id" ]]; then
    printf 'TextEdit did not return an owned document id for %s.\n' "$slug" >&2
    return 1
  fi
  active_document_id="$document_id"

  sleep "$prompt_wait_seconds"
  capture_prompt "$slug" "$prompt" "$document_id"
  read_document_text "$document_id" > "$out_dir/${slug}.document.txt"
  if [[ "$accept_suggestions" == "1" && "$input_mode" == "direct" ]]; then
    printf 'Skipping Tab accept for %s: direct mode does not send keystrokes.\n' "$slug" >&2
  elif [[ "$accept_suggestions" == "1" ]]; then
    accept_current_suggestion "$document_id"
    read_document_text "$document_id" > "$out_dir/${slug}.accepted.txt"
  fi
  close_benchmark_document "$document_id"
  active_document_id=""
  validate_prompt_artifacts "$slug"
}

# Prompts come from the shared manifest so Cotypist and LokalBot are driven by
# the exact same inputs the in-app benchmark mirrors. Tab-separated:
# slug<TAB>kind<TAB>prompt. Override with COTYPING_COMPARE_PROMPTS.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="${COTYPING_COMPARE_PROMPTS:-$script_dir/../Benchmarks/Cotyping/prompts.tsv}"
if [[ ! -f "$manifest" ]]; then
  printf 'Prompt manifest not found: %s\n' "$manifest" >&2
  exit 66
fi
cp "$manifest" "$out_dir/prompts.tsv"

first_prompt=1
prompt_count=0
seen_slugs="$out_dir/.seen-slugs"
: > "$seen_slugs"
while IFS=$'\t' read -r slug kind prompt; do
  [[ -z "$slug" || "$slug" == \#* ]] && continue
  if [[ -z "$kind" || -z "$prompt" ]]; then
    printf 'Malformed manifest row for slug: %s\n' "$slug" >&2
    exit 65
  fi
  if ! [[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]]; then
    printf 'Unsafe prompt slug: %s\n' "$slug" >&2
    exit 65
  fi
  if grep -Fxq "$slug" "$seen_slugs"; then
    printf 'Duplicate prompt slug: %s\n' "$slug" >&2
    exit 65
  fi
  printf '%s\n' "$slug" >> "$seen_slugs"
  if [[ "$first_prompt" == 1 ]]; then
    run_prompt "$slug" "$prompt" "$first_wait_seconds"
    first_prompt=0
  else
    run_prompt "$slug" "$prompt" "$wait_seconds"
  fi
  prompt_count=$((prompt_count + 1))
done < "$manifest"
rm -f "$seen_slugs"

if (( prompt_count == 0 )); then
  printf 'Prompt manifest contained no runnable cases: %s\n' "$manifest" >&2
  exit 65
fi

cat > "$out_dir/README.md" <<EOF
# Cotyping Comparison

Target: ${target_app}
Captured: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Input mode: ${input_mode}
Prompts completed: ${prompt_count}

Review each PNG for:
- first visible suggestion latency,
- grammar and relevance,
- placeholder/bracket/question leakage,
- inline-vs-popup placement,
- spacing after accepting by word or phrase.

Each prompt also writes:
- \`*.document.txt\`: TextEdit text after waiting for the suggestion.
- \`*.accepted.txt\`: TextEdit text after one Tab accept, when
  \`COTYPING_COMPARE_ACCEPT=1\` and input mode is \`keys\`.

Read back the text files before drawing conclusions: a UI probe can fail by
partially accepting, inserting a literal Tab, or showing no visible suggestion.
When input mode is \`direct\`, treat a no-suggestion capture as weak evidence:
many cotyping apps intentionally listen to real keystroke/input-monitoring
events and ignore one-shot Accessibility value changes.
EOF

manifest_sha256="$(shasum -a 256 "$out_dir/prompts.tsv" | awk '{print $1}')"
cat > "$out_dir/.complete.tmp" <<EOF
target=${target}
prompt_count=${prompt_count}
manifest_sha256=${manifest_sha256}
input_mode=${input_mode}
accept=${accept_suggestions}
EOF
mv "$out_dir/.complete.tmp" "$out_dir/capture.complete"
echo "$out_dir"
