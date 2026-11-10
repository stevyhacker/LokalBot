#!/usr/bin/env bash
# Compares the published gpui-pre crates that GPUI Kit pins against Zed's own
# source at the commit each crate declares (`package.metadata.gpui-pre.zed-rev`).
# Prints every file that differs. Expected differences are listed in
# docs/dependency-provenance.md.
set -euo pipefail
VERSION="${1:-0.3.9}"
WORK="${2:-$(mktemp -d)}"
CRATES=(gpui-pre gpui-pre-platform gpui-pre-linux gpui-pre-windows gpui-pre-wgpu gpui-pre-macros
        gpui-pre-util gpui-pre-collections gpui-pre-sum-tree gpui-pre-refineable
        gpui-pre-scheduler gpui-pre-http-client gpui-pre-shared-string
        gpui-pre-derive-refineable gpui-pre-ztracing gpui-pre-ztracing-macro)
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
# Most crates are crates/<name>; derive_refineable is inside crates/refineable.
declare -A ZED_DIR
for crate in "${CRATES[@]}"; do
  name="${ZED_CRATE[$crate]}"
  ZED_DIR[$crate]=$(git ls-tree -d -r --name-only "$REV" crates | grep -E "/$name\$" \
    | awk '{ print length, $0 }' | sort -n | head -1 | cut -d' ' -f2- || true)
  if [ -z "${ZED_DIR[$crate]}" ]; then echo "Zed has no $name crate at $REV"; exit 1; fi
done
git sparse-checkout init --cone >/dev/null
git sparse-checkout set "${ZED_DIR[@]}" >/dev/null
git checkout --quiet "$REV"
cd ..
status=0
for crate in "${CRATES[@]}"; do
  upstream="zed/${ZED_DIR[$crate]}"
  published="x/$crate/$crate-$VERSION"
  # Sources are in src, or beside the manifest (gpui_shared_string is one file).
  if [ -d "$published/src" ]; then
    differences=$(diff -rq "$upstream/src" "$published/src" 2>&1 || true)
  else
    differences=$(for file in "$published"/*.rs; do
      diff -q "$upstream/$(basename "$file")" "$file" 2>&1 || true
    done)
  fi
  if [ -z "$differences" ]; then
    echo "identical  $crate  (zed ${ZED_DIR[$crate]})"
  else
    echo "DIFFERS    $crate  (zed ${ZED_DIR[$crate]}):"
    echo "$differences" | sed 's/^/             /'
    status=1
  fi
done
exit $status
