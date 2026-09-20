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

if [ -x "$SERVER_DIR/llama-server" ] \
   && [ "$(cat "$SERVER_DIR/.lokalbot-build" 2>/dev/null || true)" = "$BUILD_MARKER" ]; then
  echo "fetch-llama: compatible vendor already present"
  exit 0
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

rm -rf "$SERVER_DIR"
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

printf '%s\n' "$BUILD_MARKER" > "$SERVER_DIR/.lokalbot-build"

# Verify every runtime object advertises the same supported minimum before it
# enters the app bundle. This fails closed if a future CMake change ignores the
# deployment target.
for file in "$SERVER_DIR/llama-server" "$SERVER_DIR"/*.dylib; do
  minos=$(otool -l "$file" | awk '/minos/{print $2; exit}')
  if [ "$minos" != "$DEPLOYMENT_TARGET" ]; then
    echo "fetch-llama: $file has minimum macOS $minos, expected $DEPLOYMENT_TARGET" >&2
    exit 1
  fi

  if ! otool -l "$file" | awk '
    /cmd LC_RPATH/ { in_rpath = 1; next }
    in_rpath && /path @loader_path / { found = 1 }
    in_rpath && /path / { in_rpath = 0 }
    END { exit found ? 0 : 1 }
  '; then
    echo "fetch-llama: $file does not use the bundle-relative @loader_path rpath" >&2
    exit 1
  fi
done

echo "fetch-llama: compatible vendor ready"
