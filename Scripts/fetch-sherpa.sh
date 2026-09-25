#!/bin/bash
# Fetches the pinned sherpa-onnx offline CLIs (+ onnxruntime dylibs)
# into Vendor/sherpa-onnx/, which the Xcode build copies into the app bundle.
# This is the ONNX-runtime path for SenseVoice (CJK) and GigaAM (Russian) —
# models WhisperKit/FluidAudio don't cover well — and Kokoro TTS. Run as an
# Xcode pre-build phase, mirroring fetch-llama.sh; idempotent and safe to run
# manually.
#
# Integration model (same as the bundled llama-server): we bundle the
# `sherpa-onnx-offline`/`sherpa-onnx-offline-tts` binaries + dylibs, copy them
# out of the bundle on first run, and invoke them as subprocesses — no C++/ONNX
# linking into the Swift app, no notarization-of-linked-lib dance.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=v1.13.6
ONNXRUNTIME_VERSION=v1.24.4  # this release variant reports macOS 14.0, satisfying our 15.0 target
DEPLOYMENT_TARGET=15.0
ARTIFACT="sherpa-onnx-$VERSION-onnxruntime-${ONNXRUNTIME_VERSION#v}-osx-arm64-shared.tar.bz2"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$ARTIFACT"
# SHA-256 of the release artifact — a GitHub release asset can be replaced in
# place, so verify before bundling. Recompute when bumping VERSION:
#   shasum -a 256 <file>
ARCHIVE_SHA256=0ab4203d8f04dfb86dc182e65105c2e3e36faceacb15aaa577bc064fbbce71f6
SHERPA_LICENSE_URL="https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/$VERSION/LICENSE"
SHERPA_LICENSE_SHA256=cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30
ONNXRUNTIME_LICENSE_URL="https://raw.githubusercontent.com/microsoft/onnxruntime/$ONNXRUNTIME_VERSION/LICENSE"
ONNXRUNTIME_LICENSE_SHA256=2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
DEST=Vendor/sherpa-onnx
BUILD_MARKER="$VERSION-onnxruntime-$ONNXRUNTIME_VERSION-macos$DEPLOYMENT_TARGET-arm64-verified"

verify_sha256() {
  local actual
  actual=$(shasum -a 256 "$1" | cut -d' ' -f1)
  if [ "$actual" != "$2" ]; then
    echo "fetch-sherpa: SHA-256 mismatch for $1" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

version_exceeds() {
  local lhs_major lhs_minor lhs_patch rhs_major rhs_minor rhs_patch
  IFS=. read -r lhs_major lhs_minor lhs_patch <<< "$1"
  IFS=. read -r rhs_major rhs_minor rhs_patch <<< "$2"
  lhs_minor=${lhs_minor:-0}; lhs_patch=${lhs_patch:-0}
  rhs_minor=${rhs_minor:-0}; rhs_patch=${rhs_patch:-0}
  (( lhs_major > rhs_major \
     || (lhs_major == rhs_major && lhs_minor > rhs_minor) \
     || (lhs_major == rhs_major && lhs_minor == rhs_minor && lhs_patch > rhs_patch) ))
}

validate_runtime() {
  local file minos asr_help tts_help flag
  test -s "$1/libonnxruntime.dylib" && test -s "$1/libsherpa-onnx-c-api.dylib" || return 1
# A bundle that advertises macOS 15.0 cannot quietly include a runtime that
# only loads on a later point release. Verify the architecture, deployment
# target, and bundle-relative rpath for every native object before packaging.
for file in "$1/sherpa-onnx-offline" "$1/sherpa-onnx-offline-tts" "$1"/*.dylib; do
  if ! file -b "$file" | grep -q 'Mach-O 64-bit.*arm64'; then
    echo "fetch-sherpa: $file is not an arm64 Mach-O runtime" >&2
    return 1
  fi
  minos=$(otool -l "$file" | awk '/minos/{print $2; exit}')
  if [ -z "$minos" ] || version_exceeds "$minos" "$DEPLOYMENT_TARGET"; then
    echo "fetch-sherpa: $file requires macOS ${minos:-unknown}; app supports $DEPLOYMENT_TARGET" >&2
    return 1
  fi
  if ! otool -l "$file" | awk '
    /cmd LC_RPATH/ { in_rpath = 1; next }
    in_rpath && /path @loader_path/ { found = 1 }
    in_rpath && /path / { in_rpath = 0 }
    END { exit found ? 0 : 1 }
  '; then
    echo "fetch-sherpa: $file has no bundle-relative @loader_path rpath" >&2
    return 1
  fi
done

# Fail closed if an older compatible release ever drops an option LokalBot
# depends on for SenseVoice, GigaAM, or Kokoro.
asr_help=$(DYLD_LIBRARY_PATH="$1" "$1/sherpa-onnx-offline" --help 2>&1)
for flag in --model-type --nemo-ctc-model --sense-voice-model --sense-voice-use-itn; do
  grep -q -- "$flag" <<< "$asr_help" || {
    echo "fetch-sherpa: ASR runtime is missing required option $flag" >&2
    return 1
  }
done
tts_help=$(DYLD_LIBRARY_PATH="$1" "$1/sherpa-onnx-offline-tts" --help 2>&1)
for flag in --kokoro-model --kokoro-voices --kokoro-tokens --kokoro-data-dir; do
  grep -q -- "$flag" <<< "$tts_help" || {
    echo "fetch-sherpa: TTS runtime is missing required option $flag" >&2
    return 1
  }
done

}

if [ -x "$DEST/sherpa-onnx-offline" ] \
   && [ -x "$DEST/sherpa-onnx-offline-tts" ] \
   && [ "$(cat "$DEST/.lokalbot-build" 2>/dev/null || true)" = "$BUILD_MARKER" ]; then
  validate_runtime "$DEST"
  echo "fetch-sherpa: compatible vendor already present"
  exit 0
fi

echo "fetch-sherpa: downloading sherpa-onnx ${VERSION}..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/sherpa.tar.bz2" "$URL"
verify_sha256 "$tmp/sherpa.tar.bz2" "$ARCHIVE_SHA256"
curl -fsSL -o "$tmp/LICENSE.sherpa-onnx" "$SHERPA_LICENSE_URL"
verify_sha256 "$tmp/LICENSE.sherpa-onnx" "$SHERPA_LICENSE_SHA256"
curl -fsSL -o "$tmp/LICENSE.onnxruntime" "$ONNXRUNTIME_LICENSE_URL"
verify_sha256 "$tmp/LICENSE.onnxruntime" "$ONNXRUNTIME_LICENSE_SHA256"
tar -xjf "$tmp/sherpa.tar.bz2" -C "$tmp"
src="$tmp/${ARTIFACT%.tar.bz2}"

FINAL_DEST="$DEST"
mkdir -p "$(dirname "$DEST")"
DEST=$(mktemp -d "$DEST.staging.XXXXXX")
trap 'rm -rf "$tmp" "$DEST"' EXIT
# Only the offline file-based recogniser, offline TTS, and dylibs. Microphone,
# websocket, and other tools aren't needed. Flat layout; the app spawns the
# binary with DYLD_LIBRARY_PATH pointed at this directory.
cp "$src/bin/sherpa-onnx-offline" "$DEST/"
cp "$src/bin/sherpa-onnx-offline-tts" "$DEST/"
cp "$src"/lib/*.dylib "$DEST/"
cp "$tmp/LICENSE.sherpa-onnx" "$DEST/"
cp "$tmp/LICENSE.onnxruntime" "$DEST/"
chmod +x "$DEST/sherpa-onnx-offline"
chmod +x "$DEST/sherpa-onnx-offline-tts"

validate_runtime "$DEST"

printf '%s\n' "$BUILD_MARKER" > "$DEST/.lokalbot-build"
if [ -e "$FINAL_DEST" ]; then mv "$FINAL_DEST" "$tmp/previous"; fi
if ! mv "$DEST" "$FINAL_DEST"; then
  if [ -e "$tmp/previous" ]; then mv "$tmp/previous" "$FINAL_DEST"; fi
  exit 1
fi
echo "fetch-sherpa: compatible vendor ready"
