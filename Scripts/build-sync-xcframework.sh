#!/bin/bash
# Builds the companion sync core (LinuxWindows/crates/lokalbot-sync) for the
# Mac, iPhone/iPad and the Apple-silicon iOS Simulator, and writes a local
# Swift package the Mac and iOS apps depend on:
#
#   Vendor/lokalbot-sync/Package.swift                library product LokalBotSync
#   Vendor/lokalbot-sync/LokalBotSyncFFI.xcframework  static libraries, C header, module map
#   Vendor/lokalbot-sync/Sources/LokalBotSync/        generated UniFFI Swift bindings
#
# Arm64 only, like the Mac app (Scripts/fetch-llama.sh, fetch-sherpa.sh).
# Nothing is rebuilt while Cargo.lock, the crate's sources, uniffi.toml and
# this script are unchanged. Safe to run from an Xcode build phase: it runs
# itself again in a clean environment, so Xcode's SDKROOT, ARCHS and
# deployment-target variables cannot leak into the Rust cross builds.
#
#   Scripts/build-sync-xcframework.sh          build when the inputs changed
#   Scripts/build-sync-xcframework.sh --force  build anyway
set -euo pipefail

if [ -z "${LOKALBOT_SYNC_CLEAN_ENV:-}" ]; then
  # Keep wherever the caller's cargo and rustup live: CI images and custom
  # installations don't always use ~/.cargo/bin.
  rust_path="$HOME/.cargo/bin"
  for tool in cargo rustup; do
    if found=$(command -v "$tool" 2>/dev/null); then
      rust_path="$rust_path:$(dirname "$found")"
    fi
  done
  keep=(
    LOKALBOT_SYNC_CLEAN_ENV=1
    "HOME=$HOME"
    "USER=${USER:-$(id -un)}"
    "TMPDIR=${TMPDIR:-/tmp}"
    "TERM=${TERM:-dumb}"
    "PATH=$rust_path:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  )
  # The Xcode that invoked us, and a custom Rust installation, still apply.
  for name in DEVELOPER_DIR RUSTUP_HOME CARGO_HOME CARGO_TARGET_DIR; do
    if [ -n "${!name:-}" ]; then
      keep+=("$name=${!name}")
    fi
  done
  exec /usr/bin/env -i "${keep[@]}" /bin/bash "$0" "$@"
fi

cd "$(dirname "$0")/.."
ROOT=$(pwd)
WORKSPACE="$ROOT/LinuxWindows"
CRATE=LinuxWindows/crates/lokalbot-sync
OUT="$ROOT/Vendor/lokalbot-sync"
TARGET_DIR="${CARGO_TARGET_DIR:-$WORKSPACE/target}"
STAMP="$OUT/.inputs.sha256"
LIB=liblokalbot_sync.a
# Package.swift's platforms.
export MACOSX_DEPLOYMENT_TARGET=15.0
export IPHONEOS_DEPLOYMENT_TARGET=18.0
TARGETS=(aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim)

force=false
case "${1:-}" in
  --force) force=true ;;
  "") ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

log() { echo "build-sync-xcframework: $*" >&2; }

if ! command -v cargo >/dev/null || ! command -v rustup >/dev/null; then
  log "cargo and rustup are needed; install Rust from https://rustup.rs"
  exit 1
fi

inputs_hash() {
  (
    cd "$ROOT"
    {
      # The library's sources; its tests don't change what ships.
      find "$CRATE/src" -type f -not -path "$CRATE/src/tests/*"
      printf '%s\n' "$CRATE/Cargo.toml" "$CRATE/uniffi.toml" LinuxWindows/Cargo.toml \
        LinuxWindows/Cargo.lock LinuxWindows/rust-toolchain.toml Scripts/build-sync-xcframework.sh
    } | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s %s\n' "$(shasum -a 256 < "$file" | cut -d' ' -f1)" "$file"
    done
  ) | shasum -a 256 | cut -d' ' -f1
}

hash=$(inputs_hash)
if ! $force && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$hash" ] \
  && [ -f "$OUT/Package.swift" ] && [ -f "$OUT/Sources/LokalBotSync/LokalBotSync.swift" ] \
  && [ -f "$OUT/LokalBotSyncFFI.xcframework/Info.plist" ]; then
  log "up to date"
  exit 0
fi

cd "$WORKSPACE"
channel=$(sed -n 's/^channel = "\(.*\)"$/\1/p' rust-toolchain.toml)
if ! rustup toolchain list | grep -q "^$channel-"; then
  log "installing Rust $channel"
  rustup toolchain install "$channel" --profile minimal
fi
installed=$(rustup target list --installed --toolchain "$channel")
for target in "${TARGETS[@]}"; do
  if ! grep -qx "$target" <<<"$installed"; then
    log "adding the $target target"
    rustup target add --toolchain "$channel" "$target"
  fi
done

for target in "${TARGETS[@]}"; do
  log "building $target"
  cargo rustc --release --locked -p lokalbot-sync --lib --target "$target" --crate-type staticlib
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

log "generating the Swift bindings"
cargo build --locked -p lokalbot-sync --features bindgen --bin uniffi-bindgen
"$TARGET_DIR/debug/uniffi-bindgen" generate --no-format --language swift \
  --out-dir "$work/swift" "$TARGET_DIR/aarch64-apple-darwin/release/$LIB"
for file in LokalBotSync.swift LokalBotSyncFFI.h LokalBotSyncFFI.modulemap; do
  if [ ! -s "$work/swift/$file" ]; then
    log "the binding generator did not write $file"
    exit 1
  fi
done

# The header and module map sit in a folder named after the module, so they
# never collide with another XCFramework's module.modulemap in Xcode's
# shared include directory; clang finds <dir>/<Module>/module.modulemap.
headers="$work/headers/LokalBotSyncFFI"
mkdir -p "$headers"
cp "$work/swift/LokalBotSyncFFI.h" "$headers/"
cp "$work/swift/LokalBotSyncFFI.modulemap" "$headers/module.modulemap"

# A Rust static library carries its own copy of the Rust standard library, so
# two of them in one app (FluidAudio's text processing is another) clash on
# symbols like _rust_eh_personality. Prelink each slice into one object in
# which only the UniFFI functions stay global, and check that those are
# exactly the functions the header declares.
printf '_uniffi_lokalbot_sync_*\n_ffi_lokalbot_sync_*\n' > "$work/exports.txt"
grep -oE '\b(uniffi|ffi)_lokalbot_sync_[A-Za-z0-9_]+\(' "$work/swift/LokalBotSyncFFI.h" \
  | tr -d '(' | sed 's/^/_/' | LC_ALL=C sort -u > "$work/declared.txt"
prelink() {
  local target="$1" platform="$2" minimum="$3" sdk="$4"
  local dir="$work/libs/$target"
  mkdir -p "$dir"
  xcrun ld -r -arch arm64 -platform_version "$platform" "$minimum" "$(xcrun --sdk "$sdk" --show-sdk-version)" \
    -exported_symbols_list "$work/exports.txt" -force_load "$TARGET_DIR/$target/release/$LIB" \
    -o "$dir/lokalbot_sync.o"
  xcrun libtool -static -o "$dir/$LIB" "$dir/lokalbot_sync.o"
  xcrun nm -gUj "$dir/$LIB" | grep '^_' | LC_ALL=C sort -u > "$dir/exported.txt"
  if ! cmp -s "$work/declared.txt" "$dir/exported.txt"; then
    log "$target exports differ from the header's functions:"
    diff "$work/declared.txt" "$dir/exported.txt" | head -n 20 >&2
    exit 1
  fi
}
prelink aarch64-apple-darwin macos "$MACOSX_DEPLOYMENT_TARGET" macosx
prelink aarch64-apple-ios ios "$IPHONEOS_DEPLOYMENT_TARGET" iphoneos
prelink aarch64-apple-ios-sim ios-simulator "$IPHONEOS_DEPLOYMENT_TARGET" iphonesimulator

package="$work/package"
mkdir -p "$package/Sources/LokalBotSync"
cp "$work/swift/LokalBotSync.swift" "$package/Sources/LokalBotSync/"
xcframework_args=()
for target in "${TARGETS[@]}"; do
  xcframework_args+=(-library "$work/libs/$target/$LIB" -headers "$work/headers")
done
xcrun xcodebuild -create-xcframework "${xcframework_args[@]}" \
  -output "$package/LokalBotSyncFFI.xcframework" >/dev/null

cat > "$package/Package.swift" <<'SWIFT'
// swift-tools-version:5.10
// Generated by Scripts/build-sync-xcframework.sh from
// LinuxWindows/crates/lokalbot-sync. Do not edit; run the script again.
import PackageDescription

let package = Package(
    name: "LokalBotSync",
    platforms: [.macOS("15.0"), .iOS("18.0")],
    products: [
        .library(name: "LokalBotSync", targets: ["LokalBotSync"]),
    ],
    targets: [
        .binaryTarget(name: "LokalBotSyncFFI", path: "LokalBotSyncFFI.xcframework"),
        .target(
            name: "LokalBotSync",
            dependencies: ["LokalBotSyncFFI"],
            path: "Sources/LokalBotSync",
            linkerSettings: [.linkedFramework("CoreFoundation")]
        ),
    ]
)
SWIFT
echo "$hash" > "$package/.inputs.sha256"

rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
mv "$package" "$OUT"
log "wrote ${OUT#"$ROOT"/}"
