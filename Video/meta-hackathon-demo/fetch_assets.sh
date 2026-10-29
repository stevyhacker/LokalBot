#!/bin/bash
# Fetches what the film needs but the repository doesn't keep: the CI film of
# the hackathon UI test (the footage) and the three OFL fonts.
#   bash fetch_assets.sh <meta-hackathon-film run id>
set -euo pipefail
cd "$(dirname "$0")"
RUN="${1:?give the Meta hackathon film run id (gh run list --workflow meta-hackathon-film.yml)}"
mkdir -p assets/footage assets/fonts
work="$(mktemp -d)"
gh run download "$RUN" --repo stevyhacker/LokalBot --name meta-hackathon-film --dir "$work"
cp "$work/lokalbot-live-radar-and-follow-through.mp4" assets/footage/film.mp4
rm -rf "$work"
echo "$RUN" > assets/footage/run-id.txt
for pair in "bigshouldersdisplay/BigShouldersDisplay%5Bwght%5D.ttf BigShouldersDisplay-VF.ttf" \
            "hankengrotesk/HankenGrotesk%5Bwght%5D.ttf HankenGrotesk-VF.ttf" \
            "jetbrainsmono/JetBrainsMono%5Bwght%5D.ttf JetBrainsMono-VF.ttf"; do
  set -- $pair
  [ -f "assets/fonts/$2" ] || curl -sfL -o "assets/fonts/$2" "https://github.com/google/fonts/raw/main/ofl/$1"
done
ffprobe -v error -show_entries format=duration -of csv=p=0 assets/footage/film.mp4
