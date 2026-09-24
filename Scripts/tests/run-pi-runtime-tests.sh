#!/bin/bash
# Resolve the extension's provider import from the pinned runtime without
# installing dependencies into the checkout or modifying the installed runtime.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_ROOT="${LOKALBOT_PINNED_RUNTIME_ROOT:?Set LOKALBOT_PINNED_RUNTIME_ROOT to the pinned Agent runtime}"
RUNTIME_ROOT="$(cd "$RUNTIME_ROOT" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-pi-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/LokalBot/Resources/pi" "$TEST_ROOT/Scripts/tests"
cp -R "$REPO_ROOT/LokalBot/Resources/pi/lokalbot-extension" "$TEST_ROOT/LokalBot/Resources/pi/"
cp "$REPO_ROOT/Scripts/tests/pi-runtime.test.ts" "$TEST_ROOT/Scripts/tests/"
ln -s "$RUNTIME_ROOT/pi/node_modules" "$TEST_ROOT/node_modules"

LOKALBOT_PINNED_RUNTIME_ROOT="$RUNTIME_ROOT" \
  "$RUNTIME_ROOT/bun/bun" test "$TEST_ROOT/Scripts/tests/pi-runtime.test.ts"
