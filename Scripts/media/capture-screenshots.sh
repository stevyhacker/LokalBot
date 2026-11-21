#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
exec </dev/null

MODE="all"
case "${1:-}" in
  "") ;;
  --stills-only) MODE="stills" ;;
  -h|--help)
    echo "usage: $0 [--stills-only]"
    exit 0
    ;;
  *)
    echo "usage: $0 [--stills-only]" >&2
    exit 2
    ;;
esac

SCHEME="LokalBot UI Test Host"
OUT="$PWD/Assets/screenshots"
FRAMES="$(mktemp -d)"
STILLS="$FRAMES/stills"
LIB="$(mktemp -d "${TMPDIR:-/tmp}/lokalbot-demo-lib.XXXXXX")"
SUITE="lokalbot.shots.$(uuidgen)"
CAPTURE_SIZE="${LOKALBOT_CAPTURE_SIZE:-1400x880}"
CAPTURE_CONTENT_MAX="${LOKALBOT_CAPTURE_CONTENT_MAX:-400}"
CAPTURE_SCALE="${LOKALBOT_CAPTURE_SCALE:-2}"
CAPTURE_DELAY="${LOKALBOT_CAPTURE_DELAY:-8}"
CAPTURE_APPEARANCE="${LOKALBOT_CAPTURE_APPEARANCE:-light}"
mkdir -p "$OUT" "$STILLS"

echo "==> Generating Xcode project"
mkdir -p Vendor/llama-cpp Vendor/sherpa-onnx
Scripts/build/build-sync-xcframework.sh
xcodegen generate >/dev/null

echo "==> Building '$SCHEME'"
xcodebuild -project LokalBot.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'platform=macOS' build >/dev/null
PRODUCTS=$(xcodebuild -project LokalBot.xcodeproj -scheme "$SCHEME" \
  -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
APP="$PRODUCTS/LokalBot UI Test Host.app/Contents/MacOS/LokalBot UI Test Host"

echo "==> Seeding studio demo library"
python3 Scripts/test/seed_demo_library.py --profile studio "$LIB"

capture() {
  local dest="$1"
  local name="$2"
  local staged="$FRAMES/.${name}-capture.png"
  local capture_pid
  shift 2
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  sleep 1
  rm -f "$staged"
  env LOKALBOT_UI_TEST=1 LOKALBOT_STORAGE_ROOT="$LIB" LOKALBOT_DEFAULTS_SUITE="$SUITE" \
      LOKALBOT_CAPTURE_FILE="$staged" LOKALBOT_CAPTURE_SIZE="$CAPTURE_SIZE" \
      LOKALBOT_CAPTURE_CONTENT_MAX="$CAPTURE_CONTENT_MAX" \
      LOKALBOT_CAPTURE_SCALE="$CAPTURE_SCALE" \
      LOKALBOT_CAPTURE_DELAY="$CAPTURE_DELAY" \
      LOKALBOT_CAPTURE_APPEARANCE="$CAPTURE_APPEARANCE" \
      LOKALBOT_SCREEN_MEMORY_DEMO=1 "$@" \
    "$APP" -ApplePersistenceIgnoreState YES -AppleLocale en_US -AppleLanguages "(en)" \
    --lokalbot-ui-test --lokalbot-storage-root "$LIB" --lokalbot-defaults-suite "$SUITE" \
    </dev/null >/dev/null 2>&1 &
  capture_pid=$!
  for _ in $(seq 1 40); do
    [ -s "$staged" ] && break
    kill -0 "$capture_pid" 2>/dev/null || break
    sleep 0.5
  done
  sleep 0.3
  kill "$capture_pid" >/dev/null 2>&1 || true
  wait "$capture_pid" 2>/dev/null || true
  if [ -s "$staged" ]; then
    mv "$staged" "$dest/$name.png"
    echo "    $name.png"
  else
    rm -f "$staged"
    echo "    !! capture failed for $name" >&2
    return 1
  fi
}

echo "==> Capturing section stills at ${CAPTURE_SIZE}pt (${CAPTURE_SCALE}x, content max ${CAPTURE_CONTENT_MAX}pt, delay ${CAPTURE_DELAY}s)"
capture "$STILLS" meetings-summary    LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=3 LOKALBOT_DETAIL_TAB=summary    LOKALBOT_DISMISS_ONBOARDING=1
capture "$STILLS" meetings-transcript LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=3 LOKALBOT_DETAIL_TAB=transcript LOKALBOT_DISMISS_ONBOARDING=1
if cmp -s "$STILLS/meetings-summary.png" "$STILLS/meetings-transcript.png"; then
  echo "    !! meeting summary and transcript captures are identical" >&2
  exit 1
fi
capture "$STILLS" timeline            LOKALBOT_INITIAL_SECTION=timeline LOKALBOT_DISMISS_ONBOARDING=1
capture "$STILLS" today               LOKALBOT_INITIAL_SECTION=today LOKALBOT_DISMISS_ONBOARDING=1
capture "$STILLS" quick-recall        LOKALBOT_UI_TEST_WINDOW=quick-recall LOKALBOT_QUICK_RECALL_QUERY=captions LOKALBOT_CAPTURE_SIZE=660x512 LOKALBOT_DISMISS_ONBOARDING=1
capture "$STILLS" search              LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=MacBook
capture "$STILLS" models              LOKALBOT_INITIAL_SECTION=models
capture "$STILLS" cotyping            LOKALBOT_INITIAL_SECTION=cotyping LOKALBOT_COTYPING_DEMO=1
capture "$STILLS" dictation           LOKALBOT_INITIAL_SECTION=dictation LOKALBOT_DICTATION_DEMO=1
capture "$STILLS" settings            LOKALBOT_INITIAL_SECTION=settings
capture "$STILLS" chat                LOKALBOT_INITIAL_SECTION=chat LOKALBOT_DISMISS_ONBOARDING=1

echo "==> Publishing validated stills"
for name in meetings-summary meetings-transcript timeline today quick-recall \
            search models cotyping dictation settings chat; do
  mv "$STILLS/$name.png" "$OUT/$name.png"
done

if [ "$MODE" = "stills" ]; then
  pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true
  echo "==> Done: $OUT/*.png"
  exit 0
fi

echo "==> Capturing GIF sequence frames"
capture "$FRAMES" recap-mac-refresh LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=1 LOKALBOT_DETAIL_TAB=summary LOKALBOT_DISMISS_ONBOARDING=1
capture "$FRAMES" recap-northwind   LOKALBOT_INITIAL_SECTION=meetings LOKALBOT_SELECT_INDEX=5 LOKALBOT_DETAIL_TAB=summary LOKALBOT_DISMISS_ONBOARDING=1
capture "$FRAMES" search-airdrop    LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=AirDrop
capture "$FRAMES" search-northwind  LOKALBOT_INITIAL_SECTION=search LOKALBOT_INITIAL_SEARCH=Northwind
pkill -f "LokalBot UI Test Host" >/dev/null 2>&1 || true

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "==> ffmpeg not found; PNGs written, skipping GIFs"
  exit 0
fi

echo "==> Assembling GIFs"
python3 Scripts/media/assemble_gif.py "$OUT/hero.gif" 1760 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$OUT/search.png" "$OUT/chat.png" "$OUT/timeline.png" "$OUT/cotyping.png"
python3 Scripts/media/assemble_gif.py "$OUT/recap.gif" 1720 \
  "$OUT/meetings-summary.png" "$OUT/meetings-transcript.png" "$FRAMES/recap-mac-refresh.png" "$FRAMES/recap-northwind.png"
python3 Scripts/media/assemble_gif.py "$OUT/search.gif" 1720 \
  "$OUT/search.png" "$FRAMES/search-airdrop.png" "$FRAMES/search-northwind.png"

echo "==> Video rendering remains a separate reviewed workflow"
echo "    See Docs/guides/demo-film-kit.md before running a HyperFrames render script."
echo "==> Done: $OUT/{*.png, hero.gif, recap.gif, search.gif}"
