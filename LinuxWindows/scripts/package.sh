#!/usr/bin/env bash
# Builds release binaries and packs them for the current platform into dist/.
# Linux: LokalBot-<version>-linux-x86_64.tar.gz (with install.sh)
# Windows (Git Bash or CI): LokalBot-<version>-windows-x86_64.zip
#
# VC_REDIST_DIR (Windows): a Microsoft.VC14x.CRT folder to take the Visual C++
# runtime from, instead of the newest Visual Studio with the C++ build tools.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
# Self-hosted CI runners keep a warm target directory elsewhere.
TARGET=${CARGO_TARGET_DIR:-target}

# The x64 Microsoft.VC14x.CRT folder of the newest Visual Studio (or Build
# Tools) with the C++ build tools, at its default redistributable version.
vc_redist_dir() {
  local vswhere vs version
  vswhere=$(cygpath -u 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe')
  vs=$("$vswhere" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | tr -d '\r')
  [ -n "$vs" ] || { echo "vswhere found no Visual Studio with the C++ build tools; set VC_REDIST_DIR." >&2; return 1; }
  vs=$(cygpath -u "$vs")
  version=$(tr -d '[:space:]' < "$vs/VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt")
  ls -d "$vs/VC/Redist/MSVC/$version/x64/Microsoft.VC"*.CRT | sort -V | tail -1
}

cargo build --release --locked -p lokalbot-app -p lokalbot-cli
mkdir -p dist
case "$(uname -s)" in
  Linux)
    NAME="LokalBot-$VERSION-linux-x86_64"
    STAGE="dist/$NAME"
    rm -rf "$STAGE" && mkdir -p "$STAGE/icons"
    cp "$TARGET/release/lokalbot" "$TARGET/release/lokalbot-cli" "$STAGE/"
    cp packaging/linux/com.lokalbot.LokalBot.desktop packaging/linux/install.sh "$STAGE/"
    cp packaging/icons/lokalbot-*.png "$STAGE/icons/"
    cp ../LICENSE "$STAGE/LICENSE" 2>/dev/null || true
    # The third-party notices and every license text they name (including
    # LICENSES/rust-crates.md, the statically linked crates) ship with the
    # binaries.
    cp ../THIRD_PARTY_NOTICES.md "$STAGE/"
    cp -R ../LICENSES "$STAGE/LICENSES"
    tar -C dist -czf "dist/$NAME.tar.gz" "$NAME"
    (cd dist && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
    echo "dist/$NAME.tar.gz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    NAME="LokalBot-$VERSION-windows-x86_64"
    STAGE="dist/$NAME"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    cp "$TARGET/release/lokalbot.exe" "$TARGET/release/lokalbot-cli.exe" "$STAGE/"
    # llama.cpp's Windows builds import the Visual C++ runtime, which Windows
    # lacks until something installs the Visual C++ Redistributable. Ship the
    # build machine's copy, unmodified (Distributable Code under the Visual
    # Studio license terms); LokalBot copies it beside each llama-server.exe
    # (lokalbot-ai's runtime.rs).
    CRT=${VC_REDIST_DIR:-$(vc_redist_dir)}
    mkdir -p "$STAGE/vc-runtime"
    for dll in msvcp140.dll vcruntime140.dll vcruntime140_1.dll; do
      cp "$CRT/$dll" "$STAGE/vc-runtime/"
    done
    cp ../LICENSE "$STAGE/LICENSE.txt" 2>/dev/null || true
    cp ../THIRD_PARTY_NOTICES.md "$STAGE/"
    cp -R ../LICENSES "$STAGE/LICENSES"
    (cd dist && 7z a -tzip "$NAME.zip" "$NAME" >/dev/null)
    (cd dist && sha256sum "$NAME.zip" > "$NAME.zip.sha256")
    echo "dist/$NAME.zip"
    ;;
  *) echo "unsupported platform: $(uname -s)"; exit 1 ;;
esac
