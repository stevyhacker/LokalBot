"""Mix the voice lines over the bed into assets/sound/final-mix.wav.

Narration and the call sit at about -16 LUFS integrated; Ana's lines get a
slight call-audio colour (band-limited) so the call reads as a call. The bed
ducks under speech and rises in gaps and over the title and end card.
"""
import json
import subprocess
from pathlib import Path

P = Path(__file__).resolve().parent
E = json.loads((P / 'edit.json').read_text())
LINES = {x['id']: x for x in json.loads((P / 'narration.json').read_text())['lines']}
total = E['duration']


def take(line_id):
    return E.get('takes', {}).get(line_id, f'assets/voice/{line_id}-s11.mp3')


def duration(path):
    return float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', str(path)],
                                check=True, capture_output=True, text=True).stdout)


voice = E['voice']
spans = [(start, start + duration(P / take(lid))) for lid, start in voice]
# Bed gain: -26 dB under speech, -15 dB in gaps, eased over 0.4 s.
expr = '0.178'
for a, b in spans:
    up = f'clip((t-{a - 0.4:.3f})/0.4,0,1)*clip(({b + 0.4:.3f}-t)/0.4,0,1)'
    expr = f'({expr})*(1-{up})+0.05*{up}'
args = ['ffmpeg', '-v', 'error', '-y']
for lid, _ in voice:
    args += ['-i', str(P / take(lid))]
args += ['-i', str(P / 'assets/bgm/bed.wav')]
f = []
for i, (lid, start) in enumerate(voice):
    ms = int(round(start * 1000))
    colour = ',highpass=f=180,lowpass=f=6500' if LINES[lid]['voice'] == 'ana' else ''
    f.append(f'[{i}:a]aresample=48000{colour},pan=stereo|c0=c0|c1=c0,adelay={ms}|{ms}[v{i}]')
n = len(voice)
f.append(''.join(f'[v{i}]' for i in range(n)) + f'amix=inputs={n}:normalize=0,loudnorm=I=-16:TP=-2:LRA=7[vo]')
f.append(f"[{n}:a]atrim=0:{total},volume='{expr}':eval=frame,afade=t=in:d=1.5,afade=t=out:st={total - 3}:d=3[bed]")
f.append(f'[vo][bed]amix=inputs=2:normalize=0,apad=pad_dur=2,atrim=0:{total},loudnorm=I=-16:TP=-1.5:LRA=11,'
         f'aresample=48000,apad=whole_dur={total}[out]')
out = P / 'assets/sound/final-mix.wav'
out.parent.mkdir(parents=True, exist_ok=True)
args += ['-filter_complex', ';'.join(f), '-map', '[out]', '-ar', '48000', '-ac', '2', '-c:a', 'pcm_s16le', '-t', str(total), str(out)]
subprocess.run(args, check=True)
r = subprocess.run(['ffmpeg', '-v', 'info', '-i', str(out), '-af', 'ebur128=peak=true', '-f', 'null', '-'],
                   capture_output=True, text=True).stderr
print(out, [l.strip() for l in r.splitlines() if l.strip().startswith(('I:', 'Peak:', 'LRA:'))][-3:])
