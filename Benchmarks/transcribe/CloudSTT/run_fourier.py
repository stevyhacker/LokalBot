import time
import wave

import numpy as np
from vllm import LLM, SamplingParams

from common import load_manifest, load_output, save_output

MODEL = 'oruk/oruk-fourier-2b'
REVISION = '8c2a8871f1304aa2f634da4fb95e24438c4945b9'
SYSTEM = 'local-oruk-fourier-2b'
PROMPT = (
    '<|im_start|>user\n<|audio_start|><|audio_pad|><|audio_end|><|im_end|>\n'
    '<|im_start|>assistant\nlanguage English<asr_text>'
)


def transcribe(model, params, path):
    with wave.open(path, 'rb') as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError(f'Expected a 16 kHz mono PCM16 WAV at {path}')
        samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype='<i2').astype(np.float32) / 32768
    prompt = {'prompt': PROMPT, 'multi_modal_data': {'audio': (samples, 16000)}}
    output = model.generate([prompt], params, use_tqdm=False)[0].outputs[0]
    if output.finish_reason != 'stop':
        raise RuntimeError(f'{path}: generation ended with {output.finish_reason}')
    return output.text.strip()


def main():
    rows = [row for row in load_manifest() if row['set'] == 'ami']
    if not rows:
        raise SystemExit('Prepare the public AMI set first.')
    start = time.perf_counter()
    model = LLM(
        model=MODEL, revision=REVISION, tokenizer_revision=REVISION, dtype='bfloat16',
        enforce_eager=True, max_model_len=4096, max_num_seqs=1, limit_mm_per_prompt={'audio': 1},
        gpu_memory_utilization=0.7, enable_prefix_caching=False, mm_processor_cache_gb=0,
    )
    params = SamplingParams(temperature=0, max_tokens=1024)
    loaded = time.perf_counter()
    transcribe(model, params, rows[0]['path'])
    print(f'Load {loaded-start:.3f}s, warm-up {time.perf_counter()-loaded:.3f}s', flush=True)
    for row in rows:
        if (load_output(SYSTEM, row['id']) or {}).get('text') is not None:
            continue
        start = time.perf_counter()
        text = transcribe(model, params, row['path'])
        save_output(SYSTEM, row['id'], {
            'system': SYSTEM, 'chunk': row['id'], 'text': text, 'error': None,
            'latency_seconds': round(time.perf_counter() - start, 3), 'audio_seconds': row['duration'],
            'model': f'{MODEL}@{REVISION}', 'options': {'language': 'English', 'dtype': 'bfloat16',
                'temperature': 0, 'max_tokens': 1024},
            'cost_usd': None,  # This run did not measure rental cost.
            'api_charge_usd': 0.0,
        })


if __name__ == '__main__':
    main()
