#!/usr/bin/env bash
# Builds the companion sync core (LinuxWindows/crates/lokalbot-sync) for
# Android and generates its Kotlin bindings, for the app's :sync module:
#
#   Companion/android/sync/build/rust/jniLibs/<abi>/liblokalbot_sync.so   arm64-v8a, x86_64
#   Companion/android/sync/build/rust/kotlin/me/dotenv/lokalbot/sync/lokalbot_sync.kt
#
# Uses the NDK in ANDROID_NDK_HOME, or the newest one under $ANDROID_HOME/ndk,
# $ANDROID_SDK_ROOT/ndk, ~/Library/Android/sdk/ndk or ~/android-sdk/ndk.
# Installs cargo-ndk and the Rust Android targets when they are missing.
# Nothing is rebuilt while Cargo.lock, the crate's sources, uniffi.toml and
# this script are unchanged.
#
#   Scripts/build-sync-android.sh          build when the inputs changed
#   Scripts/build-sync-android.sh --force  build anyway
set -euo pipefail

if ! command -v cargo >/dev/null; then
  export PATH="$HOME/.cargo/bin:$PATH"
fi

cd "$(dirname "$0")/.."
ROOT=$(pwd)
WORKSPACE="$ROOT/LinuxWindows"
CRATE=LinuxWindows/crates/lokalbot-sync
OUT="$ROOT/Companion/android/sync/build/rust"
TARGET_DIR="${CARGO_TARGET_DIR:-$WORKSPACE/target}"
STAMP="$OUT/.inputs.sha256"
LIB=liblokalbot_sync.so
KOTLIN=me/dotenv/lokalbot/sync/lokalbot_sync.kt
# The app's minSdk.
MIN_SDK=29
ABIS=(arm64-v8a x86_64)
RUST_TARGETS=(aarch64-linux-android x86_64-linux-android)

force=false
case "${1:-}" in
  --force) force=true ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

log() { echo "build-sync-android: $*" >&2; }

if ! command -v cargo >/dev/null || ! command -v rustup >/dev/null; then
  log "cargo and rustup are needed; install Rust from https://rustup.rs"
  exit 1
fi

sha256() {
  if command -v sha256sum >/dev/null; then sha256sum | cut -d' ' -f1; else shasum -a 256 | cut -d' ' -f1; fi
}

inputs_hash() {
  (
    cd "$ROOT"
    {
      # The library's sources; its tests don't change what ships.
      find "$CRATE/src" -type f -not -path "$CRATE/src/tests/*"
      printf '%s\n' "$CRATE/Cargo.toml" "$CRATE/uniffi.toml" LinuxWindows/Cargo.toml \
        LinuxWindows/Cargo.lock LinuxWindows/rust-toolchain.toml Scripts/build-sync-android.sh
    } | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s %s\n' "$(sha256 < "$file")" "$file"
    done
  ) | sha256
}

outputs_present() {
  local abi
  for abi in "${ABIS[@]}"; do
    [ -s "$OUT/jniLibs/$abi/$LIB" ] || return 1
  done
  [ -s "$OUT/kotlin/$KOTLIN" ]
}

hash=$(inputs_hash)
if ! $force && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$hash" ] && outputs_present; then
  log "up to date"
  exit 0
fi

find_ndk() {
  local dir sdk newest
  for dir in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
    if [ -n "$dir" ] && [ -f "$dir/source.properties" ]; then
      echo "$dir"
      return
    fi
  done
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/android-sdk" "$HOME/Android/Sdk"; do
    [ -n "$sdk" ] && [ -d "$sdk/ndk" ] || continue
    newest=$(find "$sdk/ndk" -mindepth 2 -maxdepth 2 -name source.properties -exec dirname {} \; | sort -V | tail -n 1)
    if [ -n "$newest" ]; then
      echo "$newest"
      return
    fi
  done
  return 1
}

if ! ndk=$(find_ndk); then
  log "no Android NDK found; install one with the SDK Manager or set ANDROID_NDK_HOME"
  exit 1
fi
export ANDROID_NDK_HOME="$ndk"
log "using the NDK at $ndk"

cd "$WORKSPACE"
channel=$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)
if ! rustup toolchain list | grep -q "^$channel-"; then
  log "installing Rust $channel"
  rustup toolchain install "$channel" --profile minimal
fi
installed=$(rustup target list --installed --toolchain "$channel")
for target in "${RUST_TARGETS[@]}"; do
  if ! grep -qx "$target" <<<"$installed"; then
    log "adding the $target target"
    rustup target add --toolchain "$channel" "$target"
  fi
done
if ! cargo ndk --version >/dev/null 2>&1; then
  log "installing cargo-ndk"
  cargo install cargo-ndk --locked
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

abi_args=()
for abi in "${ABIS[@]}"; do
  abi_args+=(-t "$abi")
done
log "building ${ABIS[*]}"
cargo ndk "${abi_args[@]}" --platform "$MIN_SDK" -o "$work/jniLibs" \
  build --release --locked -p lokalbot-sync --lib
for abi in "${ABIS[@]}"; do
  if [ ! -s "$work/jniLibs/$abi/$LIB" ]; then
    log "cargo-ndk did not produce $abi/$LIB"
    exit 1
  fi
done

log "generating the Kotlin bindings"
cargo build --locked -p lokalbot-sync --features bindgen --bin uniffi-bindgen
# Release libraries are stripped of the symbols UniFFI reads its metadata
# from; the static archive of the same build keeps them.
"$TARGET_DIR/debug/uniffi-bindgen" generate --no-format --language kotlin \
  --out-dir "$work/kotlin" "$TARGET_DIR/${RUST_TARGETS[0]}/release/liblokalbot_sync.a"
if [ ! -s "$work/kotlin/$KOTLIN" ]; then
  log "the binding generator did not write $KOTLIN"
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
mv "$work/jniLibs" "$work/kotlin" "$OUT/"
echo "$hash" > "$STAMP"
log "wrote ${OUT#"$ROOT"/}"
