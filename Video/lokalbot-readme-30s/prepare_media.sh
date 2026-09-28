#!/bin/bash
# Cut the recorded native takes into scene clips and mix the narration track.
#   TAKES=<dir with t-*.mov>  VOICE=<dir with the selected Breeze WAVs>  ./prepare_media.sh
# Outputs (ignored by git): assets/clips/*.mp4, assets/voice/narration.wav
set -euo pipefail
cd "$(dirname "$0")"
: "${TAKES:?set TAKES to the folder of recorded takes}"
: "${VOICE:?set VOICE to the folder of selected narration WAVs}"
mkdir -p assets/clips assets/voice
enc=(-an -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 30 -movflags +faststart)

# clip NAME TAKE SRC_START SRC_LENGTH OUT_LENGTH [FREEZE_SECONDS]
clip() {
  local name=$1 take=$2 start=$3 length=$4 out=$5 freeze=${6:-0}
  local speed; speed=$(python3 -c "print($length / ($out - $freeze))")
  local vf="setpts=PTS/$speed,fps=30"
  if [ "$freeze" != "0" ]; then vf="$vf,tpad=stop_mode=clone:stop_duration=$freeze"; fi
  ffmpeg -v error -y -ss "$start" -t "$length" -i "$TAKES/$take.mov" -vf "$vf" -t "$out" "${enc[@]}" "assets/clips/$name.mp4"
  printf '%-10s %s %ss -> %ss (x%.3f)\n' "$name" "$take" "$length" "$out" "$speed"
}
clip recall     t-recall     0.40 5.51 5.10
clip meeting    t-meeting    0.90 3.71 3.50
clip transcript t-transcript 1.55 2.40 2.40
clip ask        t-ask        0.55 2.10 2.10
clip today      t-today      0.10 1.90 1.90
clip timeline   t-timeline   2.10 1.50 1.50
clip writing    t-writing    0.00 1.40 3.20 1.80

# Narration: trim edge silence from each line, place it at its cue, normalize for the web.
cues=(v1:0.20 v2:3.00 v3:5.20 v4:10.20 v5:13.70 v6:18.25 v7:21.60 v8:25.10)
inputs=(); filters=""; mix=""
for i in "${!cues[@]}"; do
  id=${cues[$i]%%:*}; at=${cues[$i]##*:}; ms=$(python3 -c "print(int($at*1000))")
  inputs+=(-i "$VOICE/$id.wav")
  filters+="[$i:a]silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse,aresample=48000,adelay=${ms}|${ms}[a$i];"
  mix+="[a$i]"
done
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${filters}${mix}amix=inputs=${#cues[@]}:normalize=0,apad=whole_dur=30,atrim=0:30,loudnorm=I=-16:TP=-1.5:LRA=11,aformat=channel_layouts=stereo" -ar 48000 assets/voice/narration.wav
echo "narration $(ffprobe -v error -show_entries format=duration -of csv=p=0 assets/voice/narration.wav)s"
