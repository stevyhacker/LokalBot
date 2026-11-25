#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-pi-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/LokalBot/Resources/pi" "$TEST_ROOT/Scripts/tests"
cp -R "$REPO_ROOT/LokalBot/Resources/pi/lokalbot-extension" "$REPO_ROOT/LokalBot/Resources/pi/lokalbot-cli-skill" \
  "$REPO_ROOT/LokalBot/Resources/pi/system-prompt.md" "$TEST_ROOT/LokalBot/Resources/pi/"
cp "$REPO_ROOT/Scripts/tests/pi-runtime.test.ts" "$TEST_ROOT/Scripts/tests/"

if [[ -n "${LOKALBOT_PINNED_RUNTIME_ROOT:-}" ]]; then
  RUNTIME_ROOT="$(cd "$LOKALBOT_PINNED_RUNTIME_ROOT" && pwd)"
  ln -s "$RUNTIME_ROOT/pi/node_modules" "$TEST_ROOT/node_modules"
  BUN_BIN="$RUNTIME_ROOT/bun/bun"
  BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 NODE_DISABLE_COMPILE_CACHE=1 JITI_FS_CACHE=false \
    LOKALBOT_PINNED_RUNTIME_ROOT="$RUNTIME_ROOT" \
    "$BUN_BIN" test "$TEST_ROOT/Scripts/tests/pi-runtime.test.ts"
else
  BUN_BIN="${LOKALBOT_TEST_BUN:-$(command -v bun || true)}"
  [[ -n "$BUN_BIN" && -x "$BUN_BIN" ]] || { echo "Set LOKALBOT_TEST_BUN or install bun" >&2; exit 1; }
  SHIM_DIR="$TEST_ROOT/node_modules/@earendil-works/pi-ai"
  mkdir -p "$SHIM_DIR"
  cat > "$SHIM_DIR/package.json" <<'EOF'
{"name":"@earendil-works/pi-ai","type":"module","exports":{"./compat":"./compat.js"}}
EOF
  cat > "$SHIM_DIR/compat.js" <<'EOF'
export function openAICompletionsApi() {
  return { streamSimple() { throw new Error("pinned pi runtime required"); } };
}
export function openAIResponsesApi() {
  return { streamSimple() { throw new Error("pinned pi runtime required"); } };
}
EOF
  BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 NODE_DISABLE_COMPILE_CACHE=1 JITI_FS_CACHE=false \
    "$BUN_BIN" test "$TEST_ROOT/Scripts/tests/pi-runtime.test.ts"
fi
