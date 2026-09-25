#!/usr/bin/env bash
# Compatibility entry point. Installation must preserve the existing bundle's
# designated requirement so macOS privacy grants stay attached to LokalBot.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Scripts/install-app.sh now uses the permission-preserving installer." >&2
exec Scripts/reinstall-preserve-permissions.sh "$@"
