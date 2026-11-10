#!/bin/bash
# Cuts the filmed takes into the film's six footage clips. Waits are cut, typing is
# sped up, and a still state is held where the film needs time to read; nothing inside a
# window is redrawn. Frame numbers are 30 fps frames of the takes filmed on 2026-11-09 and
# 2026-11-10;
# a new take needs its numbers read again from the take's events (clips/<take>.json).
#
#   cut.sh <film-out-dir with clips/> <project assets/footage dir>
set -euo pipefail
CLIPS=$(cd "$1/clips" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
X=(-an -c:v libx264 -preset slow -crf 14 -pix_fmt yuv420p -r 30 -g 15 -movflags +faststart)
ff() { ffmpeg -y -loglevel error "$@"; }

# The call, in real time: "Agreed. Decision made." arrives 0.4 s in, the decision line
# 3.4 s in. 6.5 s.
ff -i "$CLIPS/live.mp4" -vf "trim=start_frame=438:end_frame=633,setpts=PTS-STARTPTS" "${X[@]}" "$OUT/call.mp4"

# The notes: the scrolled summary holds 3.3 s (its first frame held 2.2 s), then the click
# on the decision's citation and the transcript opening at that line: 6.4 s. Its last
# frame is held 5.2 s more, behind the search panel that opens over it.
ff -i "$CLIPS/notes.mp4" -vf "trim=start_frame=138:end_frame=264,setpts=PTS-STARTPTS,tpad=start_mode=clone:start_duration=2.2:stop_mode=clone:stop_duration=5.2" \
  "${X[@]}" "$OUT/notes.mp4"

# Search: typing and the results, the idle second before the arrow keys cut, the last
# frame held. 5.4 s.
ff -i "$CLIPS/search.mp4" -filter_complex "
  [0:v]trim=start_frame=16:end_frame=68,setpts=PTS-STARTPTS[a];
  [0:v]trim=start_frame=92:end_frame=178,setpts=PTS-STARTPTS[b];
  [a][b]concat=n=2:v=1,tpad=stop_mode=clone:stop_duration=0.8[v]" -map "[v]" "${X[@]}" "$OUT/search.mp4"

# Autocomplete: the typing at 1.45x and 1.2x with the pause between its two bursts cut
# (the clip opens mid-word, after an early suggestion the typing overtook), the suggestion
# at real speed, the Tabs at 1.25x, then the finished sentence held (the app's next
# suggestion comes four frames later). 6.1 s.
ff -i "$CLIPS/autocomplete.mp4" -filter_complex "
  [0:v]trim=start_frame=47:end_frame=71,setpts=(PTS-STARTPTS)/1.45[a];
  [0:v]trim=start_frame=94:end_frame=124,setpts=(PTS-STARTPTS)/1.2[b];
  [0:v]trim=start_frame=124:end_frame=156,setpts=PTS-STARTPTS[c];
  [0:v]trim=start_frame=156:end_frame=232,setpts=(PTS-STARTPTS)/1.25[d];
  [a][b][c][d]concat=n=4:v=1,fps=30,tpad=stop_mode=clone:stop_duration=1.6[v]" -map "[v]" "${X[@]}" "$OUT/autocomplete.mp4"

# Dictation, in real time: the empty document, Option-Shift held 0.6 s in, the spoken request
# heard and previewed, then (0.4 s of holding after the last word cut) the release, half a
# second of composing and the pasted sentence, held. 9.8 s.
ff -i "$CLIPS/dictation.mp4" -filter_complex "
  [0:v]trim=start_frame=18:end_frame=176,setpts=PTS-STARTPTS[a];
  [0:v]trim=start_frame=189:end_frame=310,setpts=PTS-STARTPTS[b];
  [a][b]concat=n=2:v=1,tpad=stop_mode=clone:stop_duration=0.5[v]" -map "[v]" "${X[@]}" "$OUT/dictation.mp4"

# The Timeline: the day, a click on one session and what it opens, then (two idle seconds
# cut) the list scrolled to the afternoon. That frame is held from 1.1 s after the scroll:
# the take's pointer rested on a row, and its hover tooltip comes up at frame 240. 7.0 s.
ff -i "$CLIPS/timeline.mp4" -filter_complex "
  [0:v]trim=start_frame=57:end_frame=130,setpts=PTS-STARTPTS[a];
  [0:v]trim=start_frame=186:end_frame=240,setpts=PTS-STARTPTS[b];
  [a][b]concat=n=2:v=1,tpad=stop_mode=clone:stop_duration=2.8[v]" -map "[v]" "${X[@]}" "$OUT/timeline.mp4"

for clip in call notes search autocomplete dictation timeline; do
  printf '%s ' "$clip"
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$clip.mp4"
done
