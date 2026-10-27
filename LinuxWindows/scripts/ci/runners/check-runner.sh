#!/usr/bin/env bash
# First step of a job on a self-hosted Linux runner (setup-linux-runner.sh):
# - fails if the runner can reach the Tailscale network, which its systemd
#   unit is meant to block;
# - points XDG directories at this job's temp folder, so app state doesn't
#   carry over between jobs the way it can't on GitHub's fresh machines;
# - trims the warm target directory when it, or the disk, gets too full.
set -euo pipefail

if timeout 3 bash -c 'exec 3<>/dev/tcp/100.100.100.100/53' 2>/dev/null; then
  echo "::error::This runner can reach the Tailscale network. Check the IPAddressDeny drop-in from setup-linux-runner.sh."
  exit 1
fi

for dir in config data cache state; do
  mkdir -p "$RUNNER_TEMP/xdg/$dir"
done
# The app's single-instance socket lives in XDG_RUNTIME_DIR, which must be
# private to its owner.
mkdir -p -m 700 "$RUNNER_TEMP/xdg/runtime"
{
  echo "XDG_CONFIG_HOME=$RUNNER_TEMP/xdg/config"
  echo "XDG_DATA_HOME=$RUNNER_TEMP/xdg/data"
  echo "XDG_CACHE_HOME=$RUNNER_TEMP/xdg/cache"
  echo "XDG_STATE_HOME=$RUNNER_TEMP/xdg/state"
  echo "XDG_RUNTIME_DIR=$RUNNER_TEMP/xdg/runtime"
} >>"$GITHUB_ENV"

target=${CARGO_TARGET_DIR:?the runner sets CARGO_TARGET_DIR in its .env}
mkdir -p "$target"
size_gb=$(($(du -sm "$target" | cut -f1) / 1024))
free_gb=$(($(df -Pm "$target" | awk 'NR == 2 { print $4 }') / 1024))
echo "Warm target: $size_gb GB in $target; $free_gb GB free."
if [ "$size_gb" -gt "${TARGET_LIMIT_GB:-60}" ] || [ "$free_gb" -lt "${MIN_FREE_GB:-40}" ]; then
  echo "Clearing the warm target to free space."
  rm -rf "${target:?}"/*
fi
