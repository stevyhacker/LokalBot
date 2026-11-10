#!/bin/bash
# Build the light cut as its own HyperFrames project in build-light/ (ignored by git):
# the same composition with data-theme="light" and the light-appearance clips.
#   TAKES=<light takes> CLIPS=assets/clips-light ./prepare_media.sh   # once
#   ./make_light.sh && (cd build-light && npx --yes hyperframes@0.8.82 render --quality high --fps 30 --output renders/video.mp4)
set -euo pipefail
cd "$(dirname "$0")"
[ -d assets/clips-light ] || { echo "cut the light clips first (see prepare_media.sh)" >&2; exit 1; }
mkdir -p build-light
ln -sfn ../assets build-light/assets
cp hyperframes.json build-light/
printf '{\n  "id": "lokalbot-readme-45s-light",\n  "name": "lokalbot-readme-45s-light",\n  "createdAt": "2026-09-28T19:00:00.000Z"\n}\n' > build-light/meta.json
sed -e 's/<div id="root" data-composition-id="main"/<div id="root" data-theme="light" data-composition-id="main"/' \
    -e 's#assets/clips/#assets/clips-light/#g' \
    -e 's#<title>LokalBot — 45-second README demo</title>#<title>LokalBot — 45-second README demo (light)</title>#' \
    -e 's#html, body { width: 1920px; height: 1080px; overflow: hidden; background: \#06080a; }#html, body { width: 1920px; height: 1080px; overflow: hidden; background: \#f3f6f6; }#' \
    index.html > build-light/index.html
grep -q 'data-theme="light" data-composition-id' build-light/index.html
echo "build-light/index.html: $(grep -c 'assets/clips-light/' build-light/index.html) light clips"
