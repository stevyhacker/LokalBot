#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-audio-crash.XXXXXX")"
writer_pid=""
cleanup() {
  if [[ -n "$writer_pid" ]]; then kill -KILL "$writer_pid" 2>/dev/null || true; fi
  rm -rf "$probe_dir"
}
trap cleanup EXIT
xcrun swiftc -target "$(uname -m)-apple-macosx15.0" -module-cache-path "$probe_dir/cache" -o "$probe_dir/probe" \
  "$repo_root/LokalBot/Services/AudioFileInspector.swift" \
  "$repo_root/LokalBot/Services/AudioPreviewTee.swift" \
  "$repo_root/LokalBot/Services/AudioRecoveryJournal.swift" \
  "$repo_root/LokalBot/Services/MeetingAudioFiles.swift" \
  "$repo_root/Scripts/tests/AudioRecoveryCrashProbe.swift"
"$probe_dir/probe" write "$probe_dir" &
writer_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
  [[ -f "$probe_dir/ready" ]] && break
  kill -0 "$writer_pid"
  sleep 0.1
done
# A plain `[ ]`: macOS's own bash (3.2) does not stop a `set -e` script on a false `[[ ]]`.
[ -f "$probe_dir/ready" ] || { echo "the probe never started writing"; exit 1; }
kill -KILL "$writer_pid"
wait "$writer_pid" 2>/dev/null || true
writer_pid=""
"$probe_dir/probe" verify "$probe_dir"
