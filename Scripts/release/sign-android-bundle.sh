#!/usr/bin/env bash
set -euo pipefail

unsigned=${1:?usage: $0 UNSIGNED.aab OUT.aab KEYSTORE [CERTIFICATE_SHA256]}
out=${2:?usage: $0 UNSIGNED.aab OUT.aab KEYSTORE [CERTIFICATE_SHA256]}
keystore=${3:?usage: $0 UNSIGNED.aab OUT.aab KEYSTORE [CERTIFICATE_SHA256]}
expected=${4:-}
: "${PLAY_UPLOAD_KEYSTORE_PASSWORD:?PLAY_UPLOAD_KEYSTORE_PASSWORD must hold the keystore password}"

key_password=${PLAY_UPLOAD_KEY_PASSWORD:-$PLAY_UPLOAD_KEYSTORE_PASSWORD}
export PLAY_UPLOAD_KEYSTORE_PASSWORD
export PLAY_UPLOAD_KEY_PASSWORD="$key_password"

alias_name=${PLAY_UPLOAD_KEY_ALIAS:-}
if [[ -z "$alias_name" ]]; then
  listing=$(LC_ALL=C keytool -list -v -keystore "$keystore" -storepass:env PLAY_UPLOAD_KEYSTORE_PASSWORD)
  aliases=$(awk '
    /^Alias name: / { alias = substr($0, 13) }
    /^Entry type: PrivateKeyEntry$/ { print alias }
  ' <<<"$listing")
  count=$(awk 'NF { n++ } END { print n + 0 }' <<<"$aliases")
  if [[ "$count" -ne 1 ]]; then
    echo "sign-android-bundle: expected one PrivateKeyEntry in keystore (found $count); set PLAY_UPLOAD_KEY_ALIAS" >&2
    exit 1
  fi
  alias_name=$aliases
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

LC_ALL=C jarsigner \
  -keystore "$keystore" \
  -storepass:env PLAY_UPLOAD_KEYSTORE_PASSWORD \
  -keypass:env PLAY_UPLOAD_KEY_PASSWORD \
  -signedjar "$work/signed.aab" \
  "$unsigned" \
  "$alias_name" >/dev/null

verify_output=$(LC_ALL=C jarsigner -verify "$work/signed.aab")
if ! grep -qx 'jar verified.' <<<"$verify_output"; then
  echo "sign-android-bundle: jarsigner verification did not report 'jar verified.': $verify_output" >&2
  exit 1
fi

cert_report=$(LC_ALL=C keytool -printcert -jarfile "$work/signed.aab")
digest=$(awk '/^[[:space:]]*SHA256:[[:space:]]*/ { print $2 }' <<<"$cert_report" \
  | tr -d ':' | tr 'A-F' 'a-f' | sort -u)
if [[ ! "$digest" =~ ^[0-9a-f]{64}$ ]]; then
  echo "sign-android-bundle: expected one SHA-256 certificate digest from keytool -printcert, in:" >&2
  echo "$cert_report" >&2
  exit 1
fi
if [[ -n "$expected" && "$digest" != "$expected" ]]; then
  echo "sign-android-bundle: the key's certificate is $digest, not $expected" >&2
  exit 1
fi

mv "$work/signed.aab" "$out"
echo "sign-android-bundle: $out, alias $alias_name, certificate SHA-256 $digest"
