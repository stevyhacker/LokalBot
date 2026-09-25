#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/cotyping-safety.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
mkdir -p "$fixture_root/bin"

cat > "$fixture_root/bin/pgrep" <<'SH'
#!/usr/bin/env bash
if [[ "${2:-}" == "${COTYPING_TEST_RUNNING:-}" ]]; then
  printf '4242\n'
  exit 0
fi
exit 1
SH
cat > "$fixture_root/bin/open" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COTYPING_TEST_LOG"
exit 7
SH
cat > "$fixture_root/bin/pkill" <<'SH'
#!/usr/bin/env bash
printf 'unexpected process termination\n' >> "$COTYPING_TEST_LOG"
exit 99
SH
for command in osascript screencapture; do
  cp "$fixture_root/bin/pkill" "$fixture_root/bin/$command"
done
chmod +x "$fixture_root/bin/"*
export PATH="$fixture_root/bin:$PATH"
export COTYPING_TEST_LOG="$fixture_root/actions"
export COTYPING_TEST_RUNNING=LokalBot

if bash "$repo_root/Scripts/run-cotyping-side-by-side.command" \
    > "$fixture_root/wrapper-result" 2>&1; then
  printf 'Expected a running production LokalBot to block the wrapper.\n' >&2
  exit 1
fi
[[ ! -e "$COTYPING_TEST_LOG" ]]
rg -q 'Finish any recording and quit it yourself' "$fixture_root/wrapper-result"
rg -q 'no apps were stopped' "$fixture_root/wrapper-result"

if bash "$repo_root/Scripts/compare-cotyping.sh" cotabby "$fixture_root/output" > "$fixture_root/result" 2>&1; then
  printf 'Expected a running competitor to block the benchmark.\n' >&2
  exit 1
fi
[[ ! -e "$COTYPING_TEST_LOG" ]]
rg -q 'No apps were stopped' "$fixture_root/result"

export COTYPING_TEST_RUNNING=none
if bash "$repo_root/Scripts/compare-cotyping.sh" cotabby "$fixture_root/output2" > "$fixture_root/result2" 2>&1; then
  printf 'Expected target launch failure to stop the benchmark.\n' >&2
  exit 1
fi
rg -q 'Could not launch comparison target' "$fixture_root/result2"
[[ "$(wc -l < "$COTYPING_TEST_LOG" | tr -d ' ')" == 2 ]]
if rg -q 'TextEdit|termination' "$COTYPING_TEST_LOG"; then
  printf 'A launch failure touched TextEdit or terminated a process.\n' >&2
  exit 1
fi

# Drive one mocked prompt through the success path. Every capture/read/accept/
# close operation must carry the document id returned by the creation call;
# the script must never fall back to the largest or generic front window.
cat > "$fixture_root/bin/pgrep" <<'SH'
#!/usr/bin/env bash
if [[ "${2:-}" == "Cotabby" ]]; then
  printf '4242\n'
  exit 0
fi
exit 1
SH
cat > "$fixture_root/bin/open" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture_root/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$fixture_root/bin/screencapture" <<'SH'
#!/usr/bin/env bash
printf 'mock png' > "${@: -1}"
SH
cat > "$fixture_root/bin/osascript" <<'SH'
#!/usr/bin/env bash
script="$(cat)"
printf 'ARGS:%s\n%s\n---\n' "$*" "$script" >> "$COTYPING_TEST_LOG"
if [[ "$script" == *"set windowBounds to bounds of benchmarkWindow"* ]]; then
  printf '10,20,640,480\n'
elif [[ "$script" == *"set benchmarkDocument to make new document"* ]]; then
  printf 'owned-document-42\n'
elif [[ "$script" == *"return text of candidate"* ]]; then
  printf 'owned benchmark text\n'
fi
SH
chmod +x "$fixture_root/bin/"*
: > "$COTYPING_TEST_LOG"
cat > "$fixture_root/prompts.tsv" <<'EOF'
owned-1	continuation	Only this owned document may be captured
EOF
export COTYPING_COMPARE_PROMPTS="$fixture_root/prompts.tsv"
export COTYPING_COMPARE_ACCEPT=1
export COTYPING_COMPARE_FIRST_WAIT_SECONDS=0
export COTYPING_COMPARE_WAIT_SECONDS=0
export COTYPING_COMPARE_ACCEPT_WAIT_SECONDS=0
bash "$repo_root/Scripts/compare-cotyping.sh" cotabby "$fixture_root/output3" >/dev/null
[[ -s "$fixture_root/output3/capture.complete" ]]
[[ "$(cat "$fixture_root/output3/target.pid")" == 4242 ]]
[[ -s "$fixture_root/output3/owned-1.png" ]]
[[ -s "$fixture_root/output3/owned-1.document.txt" ]]
[[ -f "$fixture_root/output3/owned-1.accepted.txt" ]]
[[ "$(rg -c 'ARGS:- owned-document-42' "$COTYPING_TEST_LOG")" -ge 5 ]]
if rg -q 'largestArea|set documentWindow to window 1|bounds of front window' \
  "$repo_root/Scripts/compare-cotyping.sh"; then
  printf 'The capture script contains an unowned-window fallback.\n' >&2
  exit 1
fi
rg -q 'first window whose document is benchmarkDocument' \
  "$repo_root/Scripts/compare-cotyping.sh"
printf 'Cotyping process-safety regressions passed.\n'
