#!/usr/bin/env bash
# Writes ../LICENSES/rust-crates.md: every Rust crate compiled into the Linux
# and Windows app, the license it is used under, and that license's text as
# the crate ships it. cargo-about reads Cargo.lock and the crates' sources;
# about.toml and about.hbs hold its configuration and template.
#
#   scripts/third-party-licenses.sh          rewrite the file
#   scripts/third-party-licenses.sh --check  fail if the file is out of date
#
# Run it after changing Cargo.lock. It downloads the pinned cargo-about
# (checked by SHA-256) into the target directory on first use; CARGO_ABOUT
# names another binary of the same version.
set -euo pipefail
cd "$(dirname "$0")/.."
ABOUT_VERSION=0.9.2
OUT=../LICENSES/rust-crates.md

check=false
case "${1:-}" in
  --check) check=true ;;
  "") ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

about="${CARGO_ABOUT:-}"
if [ -z "$about" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
      triple=x86_64-unknown-linux-musl
      sha256=9099a59e820c38a68b9d65f300662a567d56562f9a10f6aa4c7e86c17c2566af ;;
    Darwin-arm64)
      triple=aarch64-apple-darwin
      sha256=ae72f0df0c399a1e96336f696fa55b1b28679fd725632eba8cf8e4568467cc3e ;;
    *)
      echo "No pinned cargo-about for $(uname -s) $(uname -m); set CARGO_ABOUT to cargo-about $ABOUT_VERSION." >&2
      exit 1 ;;
  esac
  dir="${CARGO_TARGET_DIR:-target}/tools/cargo-about-$ABOUT_VERSION-$triple"
  about="$dir/cargo-about"
  if [ ! -x "$about" ]; then
    archive="cargo-about-$ABOUT_VERSION-$triple.tar.gz"
    curl -fsSL --retry 3 -o "$tmp/$archive" \
      "https://github.com/EmbarkStudios/cargo-about/releases/download/$ABOUT_VERSION/$archive"
    if command -v sha256sum >/dev/null; then
      echo "$sha256  $tmp/$archive" | sha256sum -c - >/dev/null
    else
      echo "$sha256  $tmp/$archive" | shasum -a 256 -c - >/dev/null
    fi
    tar -xzf "$tmp/$archive" -C "$tmp"
    mkdir -p "$dir"
    mv "$tmp/cargo-about-$ABOUT_VERSION-$triple/cargo-about" "$about"
  fi
fi
have=$("$about" --version | awk '{print $2}')
if [ "$have" != "$ABOUT_VERSION" ]; then
  echo "$about is cargo-about $have; this list is made with $ABOUT_VERSION." >&2
  exit 1
fi

# --offline keeps the output the same on every machine: license text comes
# only from the downloaded crates, never from their git repositories.
cargo fetch --locked --quiet
"$about" generate --workspace --locked --offline --fail \
  -c about.toml -o "$tmp/generated.md" about.hbs
# Some crates ship their license with Windows line endings; Git stores LF.
new="$tmp/rust-crates.md"
tr -d '\r' < "$tmp/generated.md" > "$new"

if $check; then
  if ! diff -u "$OUT" "$new" > "$tmp/diff"; then
    head -n 80 "$tmp/diff"
    echo "LICENSES/rust-crates.md is out of date. Run LinuxWindows/scripts/third-party-licenses.sh and commit the result." >&2
    exit 1
  fi
  echo "LICENSES/rust-crates.md is up to date."
else
  cat "$new" > "$OUT"
  echo "Wrote LICENSES/rust-crates.md"
fi
