#!/bin/bash
set -euo pipefail
measured=$(ffmpeg -hide_banner -i "$1" -af ebur128 -f null - 2>&1 | awk '/^ *I:/{v=$2} END{print v}')
if [ -z "${measured:-}" ] || [ "$measured" = "-inf" ]; then
  ffmpeg -y -loglevel error -i "$1" -c:v copy -c:a aac -b:a 192k -ar 48000 -movflags +faststart "$2"
  exit 0
fi
gain=$(python3 -c "print(round(min(8.0, -16.0 - ($measured)), 2))")
ffmpeg -y -loglevel error -i "$1" -c:v copy \
  -af "volume=${gain}dB,alimiter=limit=0.841:attack=3:release=60:level=disabled" -c:a aac -b:a 192k -ar 48000 \
  -movflags +faststart "$2"
echo "measured $measured LUFS, gain $gain dB"
ffmpeg -hide_banner -i "$2" -af "ebur128=peak=true" -f null - 2>&1 | grep -E "^ +I:|Peak:" | tail -2
