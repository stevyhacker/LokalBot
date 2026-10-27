#!/usr/bin/env bash
# Compares the published gpui-pre crates that GPUI Kit pins against Zed's own
# source at the commit each crate declares (`package.metadata.gpui-pre.zed-rev`).
# Prints every file that differs. Expected differences are listed in
# docs/dependency-provenance.md.
set -euo pipefail
VERSION="${1:-0.3.9}"
WORK="${2:-$(mktemp -d)}"
CRATES=(gpui-pre gpui-pre-platform gpui-pre-linux gpui-pre-windows gpui-pre-wgpu gpui-pre-macros
        gpui-pre-util gpui-pre-collections gpui-pre-sum-tree gpui-pre-refineable)
mkdir -p "$WORK" && cd "$WORK"
declare -A ZED_CRATE
REV=""
for crate in "${CRATES[@]}"; do
  curl -sfL -A "lokalbot-provenance" "https://crates.io/api/v1/crates/$crate/$VERSION/download" -o "$crate.crate"
  mkdir -p "x/$crate" && tar xzf "$crate.crate" -C "x/$crate"
  manifest="x/$crate/$crate-$VERSION/Cargo.toml"
  ZED_CRATE[$crate]=$(sed -n 's/^zed-crate = "\(.*\)"/\1/p' "$manifest")
  rev=$(sed -n 's/^zed-rev = "\(.*\)"/\1/p' "$manifest")
  if [ -n "$REV" ] && [ "$rev" != "$REV" ]; then echo "$crate declares a different zed-rev: $rev"; exit 1; fi
  REV="$rev"
done
echo "All crates declare zed@$REV"
if [ ! -d zed ]; then
  git clone --quiet --filter=blob:none --no-checkout https://github.com/zed-industries/zed.git zed
fi
cd zed
git sparse-checkout init --cone >/dev/null
dirs=(); for crate in "${CRATES[@]}"; do dirs+=("crates/${ZED_CRATE[$crate]}"); done
git sparse-checkout set "${dirs[@]}" >/dev/null
git checkout --quiet "$REV"
cd ..
status=0
for crate in "${CRATES[@]}"; do
  upstream="zed/crates/${ZED_CRATE[$crate]}/src"
  published="x/$crate/$crate-$VERSION/src"
  if diff -rq "$upstream" "$published" >/dev/null; then
    echo "identical  $crate  (zed crates/${ZED_CRATE[$crate]})"
  else
    echo "DIFFERS    $crate  (zed crates/${ZED_CRATE[$crate]}):"
    diff -rq "$upstream" "$published" | sed 's/^/             /' || true
    status=1
  fi
done
exit $status
