#!/bin/bash
# Builds a pinned llama.cpp server/runtime for the app's real deployment
# target. Upstream release binaries currently declare macOS 26, so copying
# them would make a nominally macOS 15 app fail at launch. Building from the
# checksum-pinned source archive keeps the public minimum honest and avoids
# host-specific CPU instructions (`GGML_NATIVE=OFF`).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=v0.4.1
DEPLOYMENT_TARGET=15.0
SOURCE_URL="https://github.com/ggml-org/llama.cpp/archive/refs/tags/$TAG.tar.gz"
SOURCE_SHA256=ef3d5b1907a391500ae11b5e61a8e2022e0deaac9790899cad9c4e02f03bfb9a
SERVER_DIR=Vendor/llama-cpp
BUILD_MARKER="$TAG-macos$DEPLOYMENT_TARGET-arm64-generic-loader-rpath"
RUNTIME_MANIFEST=.lokalbot-runtime.sha256
REQUIRED_RUNTIME_FILES=(
  llama-server
  libllama.dylib
  libllama.0.dylib
  libggml.dylib
  libggml.0.dylib
  libggml-base.dylib
  libggml-base.0.dylib
  libggml-cpu.dylib
  libggml-cpu.0.dylib
  libggml-blas.dylib
  libggml-blas.0.dylib
  libggml-metal.dylib
  libggml-metal.0.dylib
  libllama-common.dylib
  libllama-common.0.dylib
  libllama-server-impl.dylib
  libmtmd.dylib
  libmtmd.0.dylib
  include/llama.h
)

verify_sha256() {
  local actual
  actual=$(shasum -a 256 "$1" | cut -d' ' -f1)
  if [ "$actual" != "$2" ]; then
    echo "fetch-llama: SHA-256 mismatch for $1" >&2
    echo "  expected: $2" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
}

validate_runtime_layout() {
  local root="$1"
  local relative file minos
  for relative in "${REQUIRED_RUNTIME_FILES[@]}"; do
    if [ ! -s "$root/$relative" ]; then
      echo "fetch-llama: required runtime file is missing: $relative" >&2
      return 1
    fi
  done
  if [ ! -x "$root/llama-server" ]; then
    echo "fetch-llama: llama-server is not executable" >&2
    return 1
  fi

  # Verify every runtime object advertises the same supported minimum before it
  # enters the app bundle. This fails closed if a future CMake change ignores the
  # deployment target.
  for file in "$root/llama-server" "$root"/*.dylib; do
    minos=$(otool -l "$file" | awk '/minos/{print $2; exit}')
    if [ "$minos" != "$DEPLOYMENT_TARGET" ]; then
      echo "fetch-llama: $file has minimum macOS $minos, expected $DEPLOYMENT_TARGET" >&2
      return 1
    fi

    if ! otool -l "$file" | awk '
      /cmd LC_RPATH/ { in_rpath = 1; next }
      in_rpath && /path @loader_path / { found = 1 }
      in_rpath && /path / { in_rpath = 0 }
      END { exit found ? 0 : 1 }
    '; then
      echo "fetch-llama: $file does not use the bundle-relative @loader_path rpath" >&2
      return 1
    fi
  done
}

write_runtime_receipt() {
  local root="$1"
  local manifest="$root/$RUNTIME_MANIFEST"
  local digest
  (
    cd "$root"
    find . \( -type f -o -type l \) \
      ! -name .lokalbot-build ! -name "$RUNTIME_MANIFEST" -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do shasum -a 256 "$file"; done
  ) > "$manifest"
  test -s "$manifest"
  digest=$(shasum -a 256 "$manifest" | cut -d' ' -f1)
  printf '%s\n%s\n' "$BUILD_MARKER" "$digest" > "$root/.lokalbot-build"
}

validate_runtime_receipt() {
  local root="$1"
  local marker="$root/.lokalbot-build"
  local manifest="$root/$RUNTIME_MANIFEST"
  local expected actual listed_files runtime_files
  [ "$(sed -n '1p' "$marker" 2>/dev/null || true)" = "$BUILD_MARKER" ] || return 1
  expected=$(sed -n '2p' "$marker" 2>/dev/null || true)
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || {
    echo "fetch-llama: runtime receipt is missing its manifest digest" >&2
    return 1
  }
  [ -s "$manifest" ] || {
    echo "fetch-llama: runtime content manifest is missing" >&2
    return 1
  }
  actual=$(shasum -a 256 "$manifest" | cut -d' ' -f1)
  [ "$actual" = "$expected" ] || {
    echo "fetch-llama: runtime manifest does not match its build marker" >&2
    return 1
  }
  if ! (cd "$root" && shasum -a 256 -c "$RUNTIME_MANIFEST" >/dev/null); then
    echo "fetch-llama: cached runtime content failed verification" >&2
    return 1
  fi
  listed_files=$(awk '{ sub(/^[0-9a-f]+[[:space:]]+/, ""); print }' "$manifest" | LC_ALL=C sort)
  runtime_files=$(
    cd "$root"
    find . \( -type f -o -type l \) \
      ! -name .lokalbot-build ! -name "$RUNTIME_MANIFEST" -print \
      | LC_ALL=C sort
  )
  if [ "$listed_files" != "$runtime_files" ]; then
    echo "fetch-llama: cached runtime inventory does not match its manifest" >&2
    return 1
  fi
}

validate_runtime() {
  validate_runtime_layout "$1" && validate_runtime_receipt "$1"
}

if [ -x "$SERVER_DIR/llama-server" ] \
   && [ "$(sed -n '1p' "$SERVER_DIR/.lokalbot-build" 2>/dev/null || true)" = "$BUILD_MARKER" ]; then
  if validate_runtime "$SERVER_DIR"; then
    echo "fetch-llama: compatible vendor already present"
    exit 0
  fi
  echo "fetch-llama: cached vendor is incomplete or changed; rebuilding" >&2
fi

command -v cmake >/dev/null || {
  echo "fetch-llama: cmake is required (brew install cmake)" >&2
  exit 1
}

echo "fetch-llama: building llama.cpp $TAG for macOS $DEPLOYMENT_TARGET..."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/source.tar.gz" "$SOURCE_URL"
verify_sha256 "$tmp/source.tar.gz" "$SOURCE_SHA256"
mkdir -p "$tmp/source"
tar -xzf "$tmp/source.tar.gz" -C "$tmp/source" --strip-components=1

cmake -S "$tmp/source" -B "$tmp/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  '-DCMAKE_INSTALL_RPATH=@loader_path' \
  -DBUILD_SHARED_LIBS=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_CCACHE=OFF \
  -DLLAMA_BUILD_IS_DEV=OFF \
  -DLLAMA_BUILD_COMMIT="$TAG" \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF \
  -DLLAMA_OPENSSL=OFF
cmake --build "$tmp/build" --config Release --target llama-server --parallel

FINAL_SERVER_DIR="$SERVER_DIR"
mkdir -p "$(dirname "$SERVER_DIR")"
SERVER_DIR=$(mktemp -d "$SERVER_DIR.staging.XXXXXX")
trap 'rm -rf "$tmp" "$SERVER_DIR"' EXIT
mkdir -p "$SERVER_DIR/include"
cp "$tmp/build/bin/llama-server" "$SERVER_DIR/"
cp "$tmp/build/bin"/*.dylib "$SERVER_DIR/"
cp "$tmp/source/LICENSE" "$SERVER_DIR/LICENSE.llama.cpp"
chmod +x "$SERVER_DIR/llama-server"

# Public C headers for the in-process libllama module. They come from the same
# verified source archive as the binary, so API and runtime cannot drift.
for header in \
  include/llama.h \
  ggml/include/ggml.h \
  ggml/include/ggml-backend.h \
  ggml/include/ggml-alloc.h \
  ggml/include/ggml-cpu.h \
  ggml/include/ggml-opt.h \
  ggml/include/gguf.h; do
  cp "$tmp/source/$header" "$SERVER_DIR/include/"
done

cat > "$SERVER_DIR/include/module.modulemap" <<'EOF'
module LlamaCore {
    header "llama.h"
    header "ggml.h"
    header "ggml-backend.h"
    header "ggml-alloc.h"
    header "ggml-cpu.h"
    header "ggml-opt.h"
    header "gguf.h"
    export *
}
EOF

validate_runtime_layout "$SERVER_DIR"
write_runtime_receipt "$SERVER_DIR"
validate_runtime "$SERVER_DIR"
# Publish only a fully validated build; a failed attempt leaves the prior
# vendor directory and its marker untouched.
if [ -e "$FINAL_SERVER_DIR" ]; then mv "$FINAL_SERVER_DIR" "$tmp/previous"; fi
if ! mv "$SERVER_DIR" "$FINAL_SERVER_DIR"; then
  if [ -e "$tmp/previous" ]; then mv "$tmp/previous" "$FINAL_SERVER_DIR"; fi
  exit 1
fi

echo "fetch-llama: compatible vendor ready"
