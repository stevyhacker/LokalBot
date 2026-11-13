"""Download pinned public checkpoints and a small, reproducible public ASR set."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request

ROOT = Path('/private/tmp/lokalbot-model-alternatives-20260907')
MODELS = [
    ('openbmb/MiniCPM5-2B-GGUF', '8ffce18336801a527a4385b318e70822fc0f876c', 'MiniCPM5-2B-Q4_K_M.gguf', 'minicpm5'),
    ('mradermacher/harrier-oss-v1-0.6b-GGUF', 'd79decec1ab9442e969e79804515b9c31683d30e', 'harrier-oss-v1-0.6b.Q8_0.gguf', 'harrier'),
    ('ibm-granite/granite-speech-5.0-470m-turboctc', '18ca3c1de6cd092b5a30c39fb0f04550b38ed1a0', None, 'granite5'),
]

def read_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)

def download(url, target, expected_sha=None, expected_size=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        digest = hashlib.file_digest(target.open('rb'), 'sha256').hexdigest()
        if (not expected_sha or digest == expected_sha) and (not expected_size or target.stat().st_size == expected_size):
            return digest
    partial = target.with_suffix(target.suffix + '.part')
    for attempt in range(3):
        try:
            digest = hashlib.sha256()
            with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as output:
                while chunk := response.read(4 * 1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
            if expected_size and partial.stat().st_size != expected_size:
                raise ValueError(f'Incorrect size: {target.name}')
            value = digest.hexdigest()
            if expected_sha and value != expected_sha:
                raise ValueError(f'Incorrect hash: {target.name}')
            partial.replace(target)
            print(f'Downloaded {target.name}: {target.stat().st_size:,} bytes; SHA256 {value}', flush=True)
            return value
        except Exception:
            if attempt == 2:
                raise
            time.sleep(2)

def prepare_model(spec):
    model, revision, filename, alias = spec
    metadata = read_json(f'https://huggingface.co/api/models/{model}/revision/{revision}?blobs=true')
    folder = ROOT / 'models' / alias
    folder.mkdir(parents=True, exist_ok=True)
    (folder / 'hub-metadata.json').write_text(json.dumps(metadata, indent=2))
    result = []
    for item in metadata['siblings']:
        name = item['rfilename']
        if filename is not None and name != filename:
            continue
        if filename is None and not (name.endswith(('.json', '.safetensors')) or name in ['README.md', 'LICENSE']):
            continue
        sha = item.get('lfs', {}).get('sha256')
        url = f'https://huggingface.co/{model}/resolve/{revision}/{urllib.parse.quote(name)}?download=true'
        digest = download(url, folder / name, sha, item.get('size'))
        result.append({'file': name, 'sha256': digest, 'bytes': (folder / name).stat().st_size})
    return {'model': model, 'revision': revision, 'alias': alias, 'files': result}

def prepare_audio():
    records = []
    datasets = [
        ('edinburghcstr/ami', 'ihm', 'test', [0, 500, 1500, 2500], 6),
        ('hf-internal-testing/librispeech_asr_dummy', 'clean', 'validation', [0], 20),
    ]
    for dataset, config, split, offsets, wanted in datasets:
        for offset in offsets:
            query = urllib.parse.urlencode({'dataset': dataset, 'config': config, 'split': split, 'offset': offset, 'length': 100})
            data = read_json('https://datasets-server.huggingface.co/rows?' + query)
            selected = []
            for item in data['rows']:
                row = item['row']
                text = row['text']
                if len(text.split()) < 8 or len(text.split()) > 65:
                    continue
                if 'end_time' in row and not 2 <= row['end_time'] - row['begin_time'] <= 24:
                    continue
                selected.append((item['row_idx'], row))
                if len(selected) == wanted:
                    break
            for row_index, row in selected:
                audio = row['audio']
                url = audio[0]['src'] if isinstance(audio, list) else audio['src']
                key = ('ami' if 'ami' in dataset else 'librispeech') + f'-{row_index}'
                target = ROOT / 'audio' / (key + '.wav')
                digest = download(url, target)
                records.append({'id': key, 'dataset': dataset, 'config': config, 'split': split,
                                'row': row_index, 'reference': row['text'], 'path': str(target),
                                'sha256': digest, 'source_url': url.split('?')[0]})
    (ROOT / 'audio-manifest.json').write_text(json.dumps(records, indent=2))
    print(f'Prepared {len(records)} public ASR clips', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('part', choices=['models', 'audio'])
    args = parser.parse_args()
    ROOT.mkdir(parents=True, exist_ok=True)
    if args.part == 'models':
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            results = list(pool.map(prepare_model, MODELS))
        (ROOT / 'models-manifest.json').write_text(json.dumps(results, indent=2))
    else:
        prepare_audio()
