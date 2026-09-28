#!/bin/bash
# Cut the recorded native takes into scene clips and mix the narration track.
#   TAKES=<dir with t-*.mov>  VOICE=<dir with n01..n11.wav from voice/elevenlabs_v4.py>  ./prepare_media.sh
#   TAKES=<dir with light t-*.mov>  CLIPS=assets/clips-light  ./prepare_media.sh   # light cut, clips only
# Outputs (ignored by git): $CLIPS/*.mp4 + toolbar.png (default assets/clips), assets/voice/narration.wav when VOICE is set
set -euo pipefail
cd "$(dirname "$0")"
: "${TAKES:?set TAKES to the folder of recorded takes}"
CLIPS=${CLIPS:-assets/clips}
mkdir -p "$CLIPS"
enc=(-an -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p -r 30 -movflags +faststart)

# clip NAME TAKE SRC_START SRC_LENGTH OUT_LENGTH [FREEZE_SECONDS]
clip() {
  local name=$1 take=$2 start=$3 length=$4 out=$5 freeze=${6:-0}
  local speed; speed=$(python3 -c "print($length / ($out - $freeze))")
  # Clone the last frame past the cut and count output frames, so every clip fills its slot exactly.
  local frames; frames=$(python3 -c "print(round($out * 30))")
  local vf="trim=duration=$length,setpts=(PTS-STARTPTS)/$speed,fps=30,tpad=stop_mode=clone:stop_duration=$(python3 -c "print($freeze + 0.2)")"
  ffmpeg -v error -y -ss "$start" -i "$TAKES/$take.mov" -vf "$vf" -frames:v "$frames" "${enc[@]}" "$CLIPS/$name.mp4"
  printf '%-10s %s %ss -> %ss (x%.3f)\n' "$name" "$take" "$length" "$out" "$speed"
}
# Every take plays at its recorded speed; the writing take holds its last frame.
clip recall     t-recall     0.30 5.80 5.80
clip meeting    t-meeting    0.90 3.60 3.60
clip transcript t-transcript 1.40 3.60 3.60
clip ask        t-ask        0.20 3.10 3.10
clip today      t-today      0.20 2.30 2.30
clip timeline   t-timeline   0.50 2.80 2.80
clip writing    t-writing    0.20 3.40 4.00 0.60
# Toolbar from the meeting take, laid over the transcript take whose capture draws the labels black (dark cut only).
ffmpeg -v error -y -ss 2.0 -i "$CLIPS/meeting.mp4" -frames:v 1 -vf crop=496:70:806:4 "$CLIPS/toolbar.png"

# Narration: trim edge silence from each line, place it at its cue, normalize for the web.
[ -n "${VOICE:-}" ] || exit 0
mkdir -p assets/voice
cues=(n01:0.12 n02:5.10 n03:10.12 n04:15.00 n05:17.35 n06:21.55 n07:25.15 n08:28.75 n09:31.85 n10:36.90 n11:40.70)
inputs=(); filters=""; mix=""
for i in "${!cues[@]}"; do
  id=${cues[$i]%%:*}; at=${cues[$i]##*:}; ms=$(python3 -c "print(int($at*1000))")
  inputs+=(-i "$VOICE/$id.wav")
  filters+="[$i:a]silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse,aresample=48000,adelay=${ms}|${ms}[a$i];"
  mix+="[a$i]"
done
ffmpeg -v error -y "${inputs[@]}" -filter_complex "${filters}${mix}amix=inputs=${#cues[@]}:normalize=0,apad=whole_dur=45,atrim=0:45,loudnorm=I=-16:TP=-1.5:LRA=11,aformat=channel_layouts=stereo" -ar 48000 assets/voice/narration.wav
echo "narration $(ffprobe -v error -show_entries format=duration -of csv=p=0 assets/voice/narration.wav)s"
