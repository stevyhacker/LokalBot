#!/usr/bin/env python3
"""Word timings for every voice take, used to time the edit and the captions.

  python3 word_timings.py [--model base.en]

Needs faster-whisper (runs locally, nothing is uploaded). Reads the takes
listed in production/*-generation.json and writes production/word-timings.json:
{file: [[word, start, end], ...]}. Prints each take's transcript next to its
script line, so a take that misreads a word stands out.
"""
import argparse
import json
import re
import subprocess
from pathlib import Path

import numpy as np
from faster_whisper import WhisperModel

HERE = Path(__file__).resolve().parent


def words(text):
    return re.sub(r'\[[^\]]*\]', '', text).lower().replace('-', ' ').split()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', default='base.en')
    args = parser.parse_args()
    model = WhisperModel(args.model, device='cpu', compute_type='int8', cpu_threads=4)
    out_path = HERE / 'production' / 'word-timings.json'
    out = json.loads(out_path.read_text()) if out_path.exists() else {}
    for report in sorted((HERE / 'production').glob('*-generation.json')):
        for row in json.loads(report.read_text())['rows']:
            pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(HERE / row['file']), '-f', 'f32le', '-ac', '1', '-ar', '16000', '-'],
                                 check=True, capture_output=True).stdout
            segments, _ = model.transcribe(np.frombuffer(pcm, dtype=np.float32), language='en', beam_size=5, word_timestamps=True)
            timed = [[w.word.strip(), round(w.start, 3), round(w.end, 3)] for s in segments for w in s.words]
            out[row['file']] = timed
            heard = ' '.join(w[0] for w in timed)
            flag = '' if [re.sub(r'\W', '', w) for w in words(heard)] == [re.sub(r'\W', '', w) for w in words(row['text'])] else '  <- differs'
            print(f"{row['file']}: {heard}{flag}", flush=True)
    out_path.write_text(json.dumps(out, indent=1, ensure_ascii=False) + '\n')


if __name__ == '__main__':
    main()
