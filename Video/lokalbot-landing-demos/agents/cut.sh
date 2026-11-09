#!/bin/bash
# Renders the chosen Claude Code takes to H.264, wide (16:10) and tall (4:5), in both themes.
#   cut.sh <wide cast> <wide segs> <tall cast> <tall segs>
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd ~/work/landing-demos
export NODE_PATH=$(npm root -g) RENDER_ROOT=$PWD
WIDE=$1; WSEG=$2; TALL=$3; TSEG=$4
mkdir -p out
X=(-c:v libx264 -preset veryslow -crf 21 -tune animation -pix_fmt yuv420p -movflags +faststart -an -fps_mode cfr -r 30)
for theme in dark light; do
  rm -rf fr-w-$theme fr-t-$theme
  FONT=15 PAD=30 PADY=30 SEGS=$WSEG node "$HERE/render.js" $WIDE.cast fr-w-$theme 960 600 $theme 30
  ffmpeg -v error -y -f concat -safe 0 -i fr-w-$theme/frames.txt "${X[@]}" out/agents-wide-$theme.mp4
  FONT=16.6 PAD=20 PADY=24 SEGS=$TSEG node "$HERE/render.js" $TALL.cast fr-t-$theme 540 675 $theme 30
  ffmpeg -v error -y -f concat -safe 0 -i fr-t-$theme/frames.txt "${X[@]}" out/agents-tall-$theme.mp4
  for cut in wide tall; do
    ffmpeg -v error -y -sseof -0.5 -i out/agents-$cut-$theme.mp4 -frames:v 1 out/agents-$cut-$theme-last.png
    ffmpeg -v error -y -ss 1.2 -i out/agents-$cut-$theme.mp4 -frames:v 1 out/agents-$cut-$theme-mid.png
  done
done
ls -la out/*.mp4
