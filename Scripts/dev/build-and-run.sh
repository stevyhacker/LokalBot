#!/usr/bin/env bash
# The Run action of a Codex local environment (.codex/environments/, which is
# not tracked) calls this: build LokalBot Dev and start it, or attach lldb,
# stream logs, or check that it launched.
set -euo pipefail

MODE="${1:-run}"
APP_NAME="LokalBot Dev"
BUNDLE_ID="me.dotenv.LokalBot.dev"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DERIVED_DATA="${LOKALBOT_DEV_DERIVED_DATA:-/private/tmp/lokalbot-codex-dev-derived}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cd "$ROOT_DIR"
/usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

# XcodeGen needs these paths before the first build fetches the runtimes.
mkdir -p Vendor/llama-cpp Vendor/sherpa-onnx
# The phone and tablet sync library (Rust), as a local Swift package.
Scripts/build/build-sync-xcframework.sh
xcodegen generate >/dev/null
xcodebuild \
  -project LokalBot.xcodeproj \
  -scheme "LokalBot Dev" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS' \
  -quiet \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    /usr/bin/lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in $(seq 1 20); do
      /usr/bin/pgrep -x "$APP_NAME" >/dev/null && exit 0
      /bin/sleep 0.25
    done
    printf 'error: %s did not launch\n' "$APP_NAME" >&2
    exit 1
    ;;
  *)
    printf 'usage: %s [run|--debug|--logs|--telemetry|--verify]\n' "$0" >&2
    exit 2
    ;;
esac
