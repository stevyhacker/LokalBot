#!/bin/bash
# Run only on the trusted release runner after all compilation and tests finish.
set -euo pipefail
umask 077
artifact="${1:?Pass the finished helper or disk image}"
test -f "$artifact"
keychain="$RUNNER_TEMP/lokalbot-preview-signing.keychain-db"
certificate="$RUNNER_TEMP/lokalbot-preview-signing.p12"
cleanup() {
  security lock-keychain "$keychain" >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -f "$certificate"
  security list-keychains -d user -s login.keychain-db >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
security create-keychain -p "$KEYCHAIN_PWD" "$keychain"
security set-keychain-settings -lut 300 "$keychain"
security unlock-keychain -p "$KEYCHAIN_PWD" "$keychain"
printf '%s' "$MACOS_CERTIFICATE" | base64 --decode > "$certificate"
security import "$certificate" -k "$keychain" -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign
rm -f "$certificate"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PWD" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db
identity_hash="$(security find-identity -v -p codesigning "$keychain" | \
  awk -v team="($NOTARY_APPLE_TEAM_ID)" '$0 ~ /Developer ID Application/ && index($0, team) {print $2}')"
if [[ ! "$identity_hash" =~ ^[0-9A-F]{40}$ ]]; then
  echo 'Expected one Developer ID Application identity for the configured team.' >&2
  exit 1
fi
if [[ "$artifact" == *.dmg ]]; then
  codesign --force --sign "$identity_hash" --keychain "$keychain" --timestamp "$artifact"
else
  codesign --force --sign "$identity_hash" --keychain "$keychain" --options runtime --timestamp "$artifact"
fi
cleanup
trap - EXIT
codesign --verify --strict --verbose=2 "$artifact"
