"""Run the local MLX baselines serially on the prepared chunks."""
import argparse
import time

import mlx.core as mx
from mlx_audio.stt.utils import load_model

from common import load_manifest, load_output, save_output

LOCAL = {
    'local-qwen3-asr-1.7b': ('mlx-community/Qwen3-ASR-1.7B-8bit', 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55',
                             {'language': 'English'}),
    'local-parakeet-v3': ('mlx-community/parakeet-tdt-0.6b-v3', 'ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15', {}),
}


def transcribe(model, path, options):
    result = model.generate(path, **options)
    return (result.text or '').strip()


def run(system, rows, force=False):
    repo, revision, options = LOCAL[system]
    started = time.perf_counter()
    model = load_model(repo, revision=revision)
    load_seconds = time.perf_counter() - started
    warm = time.perf_counter()
    transcribe(model, rows[0]['path'], options)  # excluded warm-up
    print(f'{system}: load {load_seconds:.1f}s, warm-up {time.perf_counter() - warm:.1f}s', flush=True)
    mx.reset_peak_memory()
    for n, row in enumerate(rows):
        if not force and (load_output(system, row['id']) or {}).get('text') is not None:
            continue
        begin = time.perf_counter()
        try:
            text, error = transcribe(model, row['path'], options), None
        except Exception as exc:  # recorded, scored as a failed chunk
            text, error = None, f'{type(exc).__name__}: {exc}'
        latency = time.perf_counter() - begin
        save_output(system, row['id'], {
            'system': system, 'chunk': row['id'], 'text': text, 'error': error,
            'latency_seconds': round(latency, 3), 'audio_seconds': row['duration'], 'cost_usd': 0.0,
            'model': f'{repo}@{revision}', 'options': options,
            'peak_memory_gib': round(mx.get_peak_memory() / 2**30, 2)})
        if n % 20 == 0:
            print(f'{system}: {n + 1}/{len(rows)} {row["id"]} {latency:.2f}s', flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('systems', nargs='*', default=list(LOCAL))
    parser.add_argument('--set', choices=['meetings', 'ami'], default=None)
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    rows = [r for r in load_manifest() if args.set in (None, r['set'])]
    for system in args.systems:
        run(system, rows, args.force)


if __name__ == '__main__':
    main()
