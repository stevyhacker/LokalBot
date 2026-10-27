"""Run the public Core ML + MLX implementation on local clips, offline.

Constructs a model skeleton from JSON on PyTorch's meta device, then installs
the publisher's Core ML encoder and safetensors MLX decoder. No pickle file
is opened or deserialized. This replaces only the vendor's skeleton-loading
step; inference uses the unchanged published encoder/decoder implementations.
"""
import json
import os
import sys
import time
import zipfile
from pathlib import Path

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'

import mlx.core as mx
import soundfile as sf
import torch
from transformers import WhisperProcessor, WhisperConfig, GenerationConfig
from thestage_speechkit.apple import ASRPipeline
from thestage_speechkit.apple.model import (
    TheWhisperForConditionalGeneration, ANEEncoder, HFMLXDecoder, load_mlx_decoder,
)

out = Path(sys.argv[1])
root = out / 'models/stage-turbo'
assets = root / 'free/macos_15_ios_18/S/10sec'
clips = json.loads((out / 'clips.json').read_text())
probe = '--probe' in sys.argv[2:]
timestamp_mode = True if '--segment-mode' in sys.argv[2:] else 'word'
if probe:
    clips = [c for c in clips if c['id'] in ('english-system-1', 'english-synthetic-control')]
start = time.perf_counter()
encoder = assets / 'encoder.mlmodelc'
if not encoder.exists():
    with zipfile.ZipFile(assets / 'encoder.mlmodelc.zip') as archive:
        for member in archive.infolist():
            if not (assets / member.filename).resolve().is_relative_to(assets.resolve()):
                raise ValueError('Archive path escapes model directory')
        archive.extractall(assets)
config = WhisperConfig.from_pretrained(str(assets), local_files_only=True)
with torch.device('meta'):
    model = TheWhisperForConditionalGeneration(config)
model.generation_config = GenerationConfig.from_pretrained(str(assets), local_files_only=True)
model.model.encoder = ANEEncoder(str(encoder))
decoder = load_mlx_decoder(str(assets / 'decoder'), max_source_positions=500)
model.model.decoder = HFMLXDecoder(decoder)
decoder.set_alignment_heads(model.generation_config.alignment_heads)
model.device_param = torch.nn.Parameter(torch.ones(1, device='cpu'))
model.proj_out = torch.nn.Identity()
processor = WhisperProcessor.from_pretrained(str(assets), chunk_length=10, local_files_only=True)
pipe = ASRPipeline(model=model, tokenizer=processor.tokenizer,
                   feature_extractor=processor.feature_extractor, chunk_length_s=10)
load_seconds = time.perf_counter() - start

def decode(samples, language):
    options = {'do_sample': False, 'num_beams': 1, 'use_cache': True, 'task': 'transcribe'}
    if language is not None:
        options['language'] = language
    else:
        options['language'] = None
    return pipe({'array': samples, 'sampling_rate': 16000}, return_timestamps=timestamp_mode,
                generate_kwargs=options)

first, rate = sf.read(clips[0]['wav'], dtype='float32')
decode(first[:80_000], None)
mx.synchronize()
print(f'Stage turbo loaded and warmed; load {load_seconds:.3f}s', flush=True)
result_name = ('stage-segment-mode.jsonl' if timestamp_mode is True
               else 'stage-word-probe.jsonl' if probe else 'stage-turbo.jsonl')
with (out / result_name).open('w') as result_file:
    for clip in clips:
        samples, rate = sf.read(clip['wav'], dtype='float32')
        assert rate == 16000 and samples.ndim == 1
        for language in ([None, 'bs'] if clip['group'] == 'bcms' else [None]):
            mx.synchronize()
            begin = time.perf_counter()
            result = decode(samples, language)
            mx.synchronize()
            elapsed = time.perf_counter() - begin
            row = {'model': 'stage-turbo-S', 'id': clip['id'], 'group': clip['group'],
                   'timestampMode': 'segment' if timestamp_mode is True else 'word',
                   'language': language or 'auto', 'text': result['text'],
                   'audioSeconds': len(samples) / rate, 'decodeSeconds': elapsed,
                   'loadSeconds': load_seconds,
                   'segments': [{'start': c['timestamp'][0], 'end': c['timestamp'][1]}
                                for c in result.get('chunks', [])]}
            result_file.write(json.dumps(row, ensure_ascii=False) + '\n')
            result_file.flush()
            print(f'{clip["id"]} {language or "auto"}: {elapsed:.3f}s', flush=True)
