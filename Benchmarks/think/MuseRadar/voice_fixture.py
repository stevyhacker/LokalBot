"""Voice a radar fixture with macOS `say`: one 16 kHz mono WAV per track, each line placed at its fixture time.

The microphone track ("local") and the call track ("them") get different voices, as a real call has two
tracks. Writes me.wav, them.wav and lines.json (where each line actually starts and ends) to the output folder.
Synthetic fixtures only: the audio is meant to be streamed to Muse Voice Transcribe by `--radar-replay --audio`.
"""
import argparse
import json
import pathlib
import subprocess
import tempfile
import wave

RATE = 16000
VOICES = {'local': 'Samantha', 'them': 'Daniel'}
TAIL_SECONDS = 4


def speak(text, voice, folder, index):
    aiff = folder / f'{index}.aiff'
    out = folder / f'{index}.wav'
    subprocess.run(['say', '-v', voice, '-o', str(aiff), text], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', f'LEI16@{RATE}', '-c', '1', str(aiff), str(out)], check=True)
    with wave.open(str(out)) as w:
        return w.readframes(w.getnframes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('fixture', type=pathlib.Path)
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    fixture = json.loads(args.fixture.read_text())
    args.output.mkdir(parents=True, exist_ok=True)
    tracks = {'local': bytearray(), 'them': bytearray()}
    placed = []
    with tempfile.TemporaryDirectory() as scratch:
        for index, line in enumerate(fixture['lines']):
            speaker = 'local' if line['speaker'] in ('local', 'me') else 'them'
            pcm = speak(line['text'], VOICES[speaker], pathlib.Path(scratch), index)
            track = tracks[speaker]
            # A line never starts before the same track's previous line ends.
            start = max(int(line['time'] * RATE) * 2, len(track))
            track.extend(b'\x00' * (start - len(track)))
            track.extend(pcm)
            placed.append({'line': index + 1, 'speaker': speaker, 'start': start / 2 / RATE,
                           'end': len(track) / 2 / RATE, 'text': line['text']})
    length = max(len(t) for t in tracks.values()) + TAIL_SECONDS * RATE * 2
    for speaker, name in (('local', 'me.wav'), ('them', 'them.wav')):
        track = tracks[speaker] + b'\x00' * (length - len(tracks[speaker]))
        with wave.open(str(args.output / name), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(bytes(track))
    (args.output / 'lines.json').write_text(json.dumps(placed, indent=1))
    print(f"{len(placed)} lines, {length / 2 / RATE:.1f} s per track, in {args.output}")


if __name__ == '__main__':
    main()
