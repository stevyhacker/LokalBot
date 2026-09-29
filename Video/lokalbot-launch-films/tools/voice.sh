#!/bin/bash
# Regenerate one film's narration, its word times, and timeline.js / timeline.json.
#   ONETAKE=<onetake checkout> ELEVENLABS_API_KEY=... tools/voice.sh <pullout|streams|machine|tech>
# Voices are ElevenLabs premades on eleven_v4: Liam narrates; Sarah and Chris speak the two meeting lines.
# The generated audio (vo/liam, vo/meeting, vo/meeting1) is ignored by git.
set -euo pipefail
: "${ONETAKE:?set ONETAKE to a checkout of github.com/feitangyuan/onetake (see README)}"
: "${ELEVENLABS_API_KEY:?set ELEVENLABS_API_KEY}"
cd "$(dirname "$0")/.."
D=${1:?film: pullout, streams, machine or tech}
PY=(uv run -q --no-project --python 3.12)
words() { "${PY[@]}" --with faster-whisper python "$ONETAKE/scripts/vo_tools.py" words "$@" --lang en --model base.en; }

python3 tools/eleven_vo.py "$D/vo/read.txt" "$D/vo/liam"
EXTRA=()
case $D in
  pullout)
    python3 tools/eleven_vo.py "$D/vo/read.txt" "$D/vo/liam" --lines 2 --seed 99    # seed 42 read "heard it" as "hurt it"
    python3 tools/eleven_vo.py "$D/vo/meeting.txt" "$D/vo/meeting" --voice EXAVITQu4vr4xnSDxMaL --first 0   # Sarah
    STARTS=3.75,5.95,9.75,14.2,16.5,21.0,25.9; EXTRA=(--meet 0.45 --bars 72) ;;
  streams)
    python3 tools/eleven_vo.py "$D/vo/read.txt" "$D/vo/liam" --lines 7 --seed 5     # seed 42 said "what you've said"
    python3 tools/eleven_vo.py "$D/vo/meeting.txt" "$D/vo/meeting" --voice iP95p4xoKVk53GoZ742B --first 0   # Chris
    STARTS=0.6,3.8,5.6,9.2,14.3,16.9,24.75; EXTRA=(--meet 19.6 --bars 64) ;;
  machine)
    STARTS=0.9,2.8,7.3,9.8,14.3,17.5,22.6 ;;
  tech)
    python3 tools/eleven_vo.py "$D/vo/meeting.txt" "$D/vo/meeting" --voice EXAVITQu4vr4xnSDxMaL --first 0   # Sarah
    STARTS=0.8,6.9,9.3,14.0,20.45,27.2,32.85,39.2,44.95,50.8,55.8; EXTRA=(--meet 41.75 --bars 72); DUR=60 ;;
  *) echo "unknown film: $D" >&2; exit 2 ;;
esac
words "$D/vo/liam" --lines "$D/vo/lines.txt"
if [ -f "$D/vo/meeting.txt" ]; then
  mkdir -p "$D/vo/meeting1" && cp "$D/vo/meeting/t0.wav" "$D/vo/meeting1/t1.wav"
  words "$D/vo/meeting1" --lines "$D/vo/meeting.txt"
fi
python3 tools/build_timeline.py "$D" --starts "$STARTS" --dur "${DUR:-30}" "${EXTRA[@]}"
