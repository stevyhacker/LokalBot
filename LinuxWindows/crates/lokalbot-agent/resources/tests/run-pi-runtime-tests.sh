#!/bin/bash
set -euo pipefail

RESOURCES="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_ROOT="${LOKALBOT_PINNED_RUNTIME_ROOT:?Set LOKALBOT_PINNED_RUNTIME_ROOT to the pinned Agent runtime}"
RUNTIME_ROOT="$(cd "$RUNTIME_ROOT" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-pi-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/resources/tests"
cp -R "$RESOURCES/lokalbot-extension" "$RESOURCES/lokalbot-cli-skill" "$RESOURCES/system-prompt.md" \
  "$TEST_ROOT/resources/"
cp "$RESOURCES/tests/pi-runtime.test.ts" "$TEST_ROOT/resources/tests/"
ln -s "$RUNTIME_ROOT/pi/node_modules" "$TEST_ROOT/node_modules"

BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 JITI_FS_CACHE=false \
  LOKALBOT_PINNED_RUNTIME_ROOT="$RUNTIME_ROOT" \
  "$RUNTIME_ROOT/bun/bun" test "$TEST_ROOT/resources/tests/pi-runtime.test.ts"
