"""Prepare public-audio fixtures for the optional native Granite 5 XCTest.

Requires the retained September 7 benchmark models/audio/results. Run using
that benchmark's pinned Python environment. No private meeting data is read.
"""
import argparse
import json
from pathlib import Path

import numpy as np
import soundfile as sf

parser = argparse.ArgumentParser()
parser.add_argument('--benchmark', type=Path, default=Path('/private/tmp/lokalbot-model-alternatives-20260907'))
parser.add_argument('--output', type=Path, default=Path('/private/tmp/lokalbot-model-integration-20260908/parity'))
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
audio = {row['id']: row for row in json.loads((args.benchmark/'audio-manifest.json').read_text())}
reference = json.loads((args.benchmark/'results/granite5-asr.json').read_text())
clips = []
for row in reference['rows']:
    samples, rate = sf.read(audio[row['id']]['path'], dtype='float32')
    if rate != 16000 or samples.ndim != 1:
        raise ValueError('Expected the original mono 16 kHz public fixture')
    path = args.output/(row['id']+'.f32')
    np.asarray(samples, dtype='<f4').tofile(path)
    clips.append({'id': row['id'], 'samples': str(path), 'audio': audio[row['id']]['path'], 'text': row['text']})
manifest = {'modelDirectory': str(args.benchmark/'models/granite5'), 'clips': clips}
path = args.output/'manifest.json'
path.write_text(json.dumps(manifest, indent=2))
print(path)
