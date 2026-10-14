#!/bin/bash
# Offline authored fixtures only. No UI tests, model launcher, external
# endpoint, user-library input, or semantic-quality judge is used here.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if [[ "$#" -ne 0 ]]; then
  echo 'Usage: bash Scripts/native-grounding-regression.sh' >&2
  exit 2
fi

# Dependencies must already be cached by a normal build. Do not resolve or
# update packages during this offline regression command.
packages="${LOKALBOT_GROUNDING_PACKAGES:-$repo_root/.build/SourcePackages}"
if [[ ! -d "$packages/checkouts" || ! -d Vendor/llama-cpp || ! -d Vendor/sherpa-onnx ]]; then
  echo 'Cached Swift packages and vendored runtimes are required; prepare them with a normal build first.' >&2
  exit 2
fi
xcodegen generate
mkdir -p .build
result_root="$(mktemp -d "$repo_root/.build/native-grounding.XXXXXX")"
printf 'Offline regression artifacts: %s\n' "$result_root"
xcodebuild test -project LokalBot.xcodeproj -scheme LokalBot -destination 'platform=macOS' \
  -derivedDataPath .build/NativeGrounding -clonedSourcePackagesDirPath "$packages" \
  -disableAutomaticPackageResolution -skipPackageUpdates -onlyUsePackageVersionsFromResolvedFile \
  -jobs 4 -parallel-testing-enabled NO \
  -only-testing:LokalBotTests/NativeGroundingEvaluationTests \
  -only-testing:LokalBotTests/ChatEvidenceOrderingTests \
  -only-testing:LokalBotTests/ChatGroundingTests \
  -only-testing:LokalBotTests/ChatAgentTests \
  -only-testing:LokalBotTests/ChatCitationTests \
  -only-testing:LokalBotTests/AskRoutingTests \
  -only-testing:LokalBotTests/SearchIndexGroundingTests \
  -only-testing:LokalBotTests/RecallPassageTests \
  -only-testing:LokalBotTests/TextEngineTests \
  -resultBundlePath "$result_root/results.xcresult" CODE_SIGNING_ALLOWED=NO \
  2>&1 | tee "$result_root/test.log"
