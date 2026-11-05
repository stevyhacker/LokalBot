#!/usr/bin/env bash
# Signs the Android release APK: aligns it, signs it with apksigner and checks
# the result. The release signs with the real key (release.yml, android-publish)
# and CI signs with a throwaway one (companion-android.yml), through this script.
#
# Signing stays out of the Gradle build, so no build script runs beside the key.
#
#   ANDROID_KEYSTORE_PASSWORD=... Scripts/sign-android-release.sh \
#     UNSIGNED.apk OUT.apk KEYSTORE.p12 [CERTIFICATE_SHA256]
#
# With CERTIFICATE_SHA256 it refuses a key whose certificate has another digest
# and leaves no OUT.apk: Android installs an update only from the key that signed
# the installed copy, so a wrong key would strand everyone on the older version.
set -euo pipefail

unsigned=${1:?usage: $0 UNSIGNED.apk OUT.apk KEYSTORE.p12 [CERTIFICATE_SHA256]}
out=${2:?usage: $0 UNSIGNED.apk OUT.apk KEYSTORE.p12 [CERTIFICATE_SHA256]}
keystore=${3:?usage: $0 UNSIGNED.apk OUT.apk KEYSTORE.p12 [CERTIFICATE_SHA256]}
expected=${4:-}
: "${ANDROID_KEYSTORE_PASSWORD:?ANDROID_KEYSTORE_PASSWORD must hold the keystore password}"

sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}
# shellcheck disable=SC2012 # version-named folders, one name per line
build_tools="$sdk/build-tools/$(ls "$sdk/build-tools" | sort -V | tail -n 1)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# -P 16 keeps native libraries on 16 KB pages, which newer devices need.
"$build_tools/zipalign" -f -P 16 4 "$unsigned" "$work/aligned.apk"
"$build_tools/apksigner" sign \
  --ks "$keystore" --ks-type PKCS12 --ks-pass env:ANDROID_KEYSTORE_PASSWORD \
  --v4-signing-enabled false \
  --out "$work/signed.apk" "$work/aligned.apk"

"$build_tools/zipalign" -c -P 16 4 "$work/signed.apk"
report=$("$build_tools/apksigner" verify --verbose --print-certs "$work/signed.apk")
# Build-tools 36 prints "Signer #1 certificate ..." and 37 "V3.0 Signer: certificate ...".
digest=$(sed -n -E 's/^.*Signer.* certificate SHA-256 digest: ([0-9a-f]{64})$/\1/p' <<<"$report" | sort -u)
if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sign-android-release: expected one certificate digest from apksigner, in:" >&2
  echo "$report" >&2
  exit 1
fi
if [[ -n "$expected" && "$digest" != "$expected" ]]; then
  echo "sign-android-release: the key's certificate is $digest, not $expected" >&2
  exit 1
fi

mv "$work/signed.apk" "$out"
echo "sign-android-release: $out, certificate SHA-256 $digest"
