#!/usr/bin/env bash
set -euo pipefail

if [[ "${CODE_SIGNING_ALLOWED:-}" != "YES" ]]; then
  echo "sign-bundled-native-code: code signing disabled; skipping"
  exit 0
fi

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
  echo "sign-bundled-native-code: no signing identity; skipping"
  exit 0
fi

resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
roots=(
  "${resources}/llama-cpp"
  "${resources}/sherpa-onnx"
)

sign_file() {
  local path="$1"
  echo "sign-bundled-native-code: signing ${path#$TARGET_BUILD_DIR/}"
  /usr/bin/codesign \
    --force \
    --sign "$identity" \
    --timestamp \
    --options runtime \
    "$path"
}

for root in "${roots[@]}"; do
  [[ -d "$root" ]] || continue
  while IFS= read -r -d '' file; do
    sign_file "$file"
  done < <(/usr/bin/find "$root" -type f \( -name "*.dylib" -o -perm -111 \) -print0)
done
