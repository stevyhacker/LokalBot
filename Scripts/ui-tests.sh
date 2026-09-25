#!/bin/bash
# LokalBot UI test runner: remote by default, foreground only by opt-in.
#
# Drives the dedicated LokalBot UI Test Host via XCUITest against a
# synthetic meetings library — no microphone/screen-recording permissions,
# no real audio, no network. The host is compiled with LOKALBOT_UI_TEST=1
# and skips every side-effectful subsystem (Core Audio polling,
# accessibility-trusted detector, Sparkle, screenshots).
#
# Local XCUITest sends real mouse and keyboard events. It therefore owns the
# foreground while it runs; it cannot be made invisible in the same login
# session without weakening these into non-UI tests. Prefer --remote, which
# dispatches the existing GitHub Actions job and returns immediately.
#
# Prereq for explicit --foreground runs (macOS TCC): the controlling terminal
# and generated test runner MUST hold:
#   • Privacy & Security → Automation → Xcode  (allowed)
#   • Privacy & Security → Accessibility       (allowed)
# without these, the XCUITest runner fails with
# "Timed out while enabling automation mode." — that error is the missing
# TCC grant, NOT a bug in the suite. The UI-test target is development-signed
# with a stable bundle identity so the grant survives ordinary rebuilds.
#
# Usage:
#   Scripts/ui-tests.sh                # dispatch all tests without stealing focus
#   Scripts/ui-tests.sh --remote       # explicit form of the default above
#   Scripts/ui-tests.sh --remote MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
#   Scripts/ui-tests.sh --build-only   # compile without launching the app
#   Scripts/ui-tests.sh --test-only --only MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
#                                     # hosted CI: reuse this job's build
#   Scripts/ui-tests.sh --foreground --skip RedesignUITests/testWorkspaceVisualMatrix
#   Scripts/ui-tests.sh --foreground   # run all tests in this login session
#   Scripts/ui-tests.sh --foreground MainWindowUITests/testSearchFindsTranscriptHitAndDeepLinks
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)/LokalBot.xcodeproj"
DERIVED=".build/dd"
SCHEME="LokalBot UI Test Host"

MODE=""
ONLY=()
SKIP=()
RESULT=""
ROOT="$(dirname "$PROJECT")"
STAMP="$ROOT/$DERIVED/ui-build.json"

usage() {
  sed -n '2,/^set -euo pipefail$/p' "$0" \
    | sed '$d; s/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --remote)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="remote"
      ;;
    --build-only)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="build"
      ;;
    --test-only)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="test"
      ;;
    --only|--skip|--result)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "$1 requires a value" >&2; exit 2; }
      case "$1" in
        --only) ONLY+=("${2#LokalBotUITests/}") ;;
        --skip) SKIP+=("${2#LokalBotUITests/}") ;;
        --result) RESULT="$2" ;;
      esac
      shift
      ;;
    --foreground)
      [ -z "$MODE" ] || { echo "Choose only one execution mode." >&2; exit 2; }
      MODE="foreground"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -n "$1" ]; then ONLY+=("${1#LokalBotUITests/}"); fi
      ;;
  esac
  shift
done

# A reuse request must never implicitly take control of a developer's desktop.
if [ "$MODE" = "test" ] && [ "${CI:-}" != "true" ]; then
  echo "--test-only is for hosted CI; use --foreground for an explicit local run." >&2
  exit 2
fi

# A developer invocation is remote by default. CI keeps running the suite on
# its hosted macOS session, where foreground ownership cannot disturb anyone.
if [ -z "$MODE" ] && [ -z "${CI:-}" ]; then
  MODE="remote"
fi

if [ "$MODE" = "remote" ]; then
  if [ "${#ONLY[@]}" -gt 1 ] || [ "${#SKIP[@]}" -gt 0 ] || [ -n "$RESULT" ]; then
    echo "Remote dispatch accepts one filter; multiple filters/results are hosted-runner options." >&2
    exit 2
  fi
  command -v gh >/dev/null 2>&1 || {
    echo "GitHub CLI (gh) is required for --remote." >&2
    exit 2
  }

  BRANCH="$(git -C "$(dirname "$PROJECT")" branch --show-current)"
  if [ -z "$BRANCH" ]; then
    echo "--remote requires a named branch." >&2
    exit 2
  fi

  # A remote runner cannot see working-tree changes. Refuse to report a green
  # result for stale UI code while still allowing unrelated local work.
  UI_PATHS=(
    LokalBot
    LokalBotUITests
    project.yml
    Scripts/ui-tests.sh
    Scripts/ci
    .github/workflows/ui-tests.yml
  )
  if ! git -C "$(dirname "$PROJECT")" diff --quiet HEAD -- "${UI_PATHS[@]}" \
      || [ -n "$(git -C "$(dirname "$PROJECT")" ls-files --others --exclude-standard -- "${UI_PATHS[@]}")" ]; then
    echo "Remote UI tests would not include the current UI/test changes." >&2
    echo "Commit and push those paths first, then rerun --remote." >&2
    exit 2
  fi

  UPSTREAM="$(git -C "$ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [ -z "$UPSTREAM" ] || [[ "$UPSTREAM" != */* ]]; then
    echo "--remote requires an upstream remote branch." >&2
    exit 2
  fi
  UPSTREAM_REMOTE="${UPSTREAM%%/*}"
  UPSTREAM_BRANCH="${UPSTREAM#*/}"
  # Refresh the actual remote ref before comparing it. If the branch advances
  # again between this fetch and dispatch, candidate_sha makes the hosted job
  # fail rather than reporting another commit as validation for this checkout.
  git -C "$ROOT" fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  if [ "$HEAD_SHA" != "$(git -C "$ROOT" rev-parse "$UPSTREAM")" ]; then
    echo "--remote requires the current HEAD to be pushed to its upstream branch." >&2
    exit 2
  fi

  gh workflow run ui-tests.yml --ref "$UPSTREAM_BRANCH" \
    --raw-field "filter=${ONLY[0]:-}" \
    --raw-field "candidate_sha=$HEAD_SHA"
  echo "Dispatched UI tests for exact candidate $HEAD_SHA"
  exit 0
fi

cd "$ROOT"

if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  swift Scripts/ci/prepare-display.swift
  swift Scripts/ci/prepare-display.swift --verify-only
fi

ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -destination 'platform=macOS'
  -derivedDataPath "$DERIVED"
  -clonedSourcePackagesDirPath .build/SourcePackages
)

# CI runners hold no signing certificate; let workflows opt out of signing
# (CODE_SIGNING_ALLOWED=NO Scripts/ui-tests.sh) without changing local runs.
if [ "${CODE_SIGNING_ALLOWED:-}" != "" ]; then
  ARGS+=("CODE_SIGNING_ALLOWED=${CODE_SIGNING_ALLOWED}")
fi

TEST_ARGS=()
if [ "${#ONLY[@]}" -gt 0 ]; then
  for filter in "${ONLY[@]}"; do
    TEST_ARGS+=(-only-testing:"LokalBotUITests/$filter")
  done
else
  TEST_ARGS+=(-only-testing:LokalBotUITests)
fi
if [ "${#SKIP[@]}" -gt 0 ]; then
  for filter in "${SKIP[@]}"; do
    TEST_ARGS+=(-skip-testing:"LokalBotUITests/$filter")
  done
fi
if [ -n "$RESULT" ]; then
  TEST_ARGS+=(-resultBundlePath "$RESULT")
fi

if [ "$MODE" = "test" ]; then
  python3 Scripts/ci/ui-build-stamp.py verify "$STAMP"
else
  # A failed build must invalidate the preceding build's reuse stamp.
  rm -f "$STAMP"
  echo "→ building for testing…"
  xcodebuild "${ARGS[@]}" -only-testing:LokalBotUITests build-for-testing
  if [ "${CI:-}" = "true" ]; then
    python3 Scripts/ci/ui-build-stamp.py write "$STAMP"
  fi
fi

if [ "$MODE" = "build" ]; then
  exit 0
fi

echo "→ running UI tests…"
# Consume the portable run configuration directly; downstream runners need no
# generated project, native vendor build or Swift package resolution.
RUN_FILES=("$DERIVED"/Build/Products/*.xctestrun)
[ "${#RUN_FILES[@]}" -eq 1 ] && [ -f "${RUN_FILES[0]}" ] || { echo "Expected one xctestrun" >&2; exit 2; }
xcodebuild test-without-building -xctestrun "${RUN_FILES[0]}" \
  -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
  -parallel-testing-enabled NO "${TEST_ARGS[@]}"
