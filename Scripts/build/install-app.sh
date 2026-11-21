#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "Scripts/build/install-app.sh now uses the permission-preserving installer." >&2
exec Scripts/build/reinstall-preserve-permissions.sh "$@"
