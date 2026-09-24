"""Download pinned public artifacts for the local diarization comparison."""
import concurrent.futures
import hashlib
import json
import pathlib
import shutil
import urllib.request

ROOT = pathlib.Path('/private/tmp/lokalbot-nemotron-bench')
MODEL_REV = '53445f72d5735e33406ccce7b92116bce7ab1ab7'
BASELINE_REV = 'df2625ac79a7ac6b65ad868fee6d80f320da4232'
CORPUS_REV = '722d8891643e1e4dc62cfd0d198fa05a1646c3cc'
MEETINGS = ['EN2002a', 'ES2004a', 'IS1009a', 'TS3003a']
evidence = pathlib.Path(__file__).resolve().parent / 'results/2026-09-23/downloads.json'
EXPECTED = {x['url']: x['sha256'] for x in json.loads(evidence.read_text())} if evidence.exists() else {}

def get_json(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return json.load(r)

def download(job):
    url, path = job
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temporary = path.with_suffix(path.suffix + '.partial')
        with urllib.request.urlopen(url, timeout=180) as r, temporary.open('wb') as f:
            shutil.copyfileobj(r, f)
        temporary.rename(path)
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    if url in EXPECTED and digest != EXPECTED[url]:
        raise ValueError(f'Checksum changed: {url}')
    print(f'{path.name}: {path.stat().st_size:,} bytes', flush=True)
    return {'url': url, 'path': str(path), 'bytes': path.stat().st_size, 'sha256': digest}

if __name__ == '__main__':
    model = get_json('https://huggingface.co/api/models/FluidInference/nemotron-3-diarization-coreml/revision/' + MODEL_REV)
    baseline = get_json('https://huggingface.co/api/models/FluidInference/speaker-diarization-coreml/revision/' + BASELINE_REV)
    jobs = []
    baseline_dir = ROOT / 'models/baseline/speaker-diarization'
    baseline_dir.mkdir(parents=True, exist_ok=True)
    for entry in baseline['siblings']:
        name = entry['rfilename']
        if name.startswith(('Segmentation.mlmodelc/', 'Embedding.mlmodelc/', 'FBank.mlmodelc/', 'PldaRho.mlmodelc/')) or name in ['plda-parameters.json', 'xvector-transform.json', 'config.json']:
            jobs.append((f'https://huggingface.co/FluidInference/speaker-diarization-coreml/resolve/{BASELINE_REV}/{name}', baseline_dir / name))
    variants = ['offline', 'fast128', 'low', 'c128_split_w8a8']
    for entry in model['siblings']:
        name = entry['rfilename']
        if name in ['learnable_sil_emb.bin', 'pre_encode_proj_t.bin', 'README.md', 'CONVERSION_NOTES.md', 'BENCHMARKS.md'] or any('/Nemotron3Diarizer_' + v + '.mlmodelc/' in name for v in variants):
            # Flatten preset parents so the explicit local model loader can be used.
            local = name.split('/', 1)[1] if name.startswith(('monolithic/', 'split/')) else name
            jobs.append((f'https://huggingface.co/FluidInference/nemotron-3-diarization-coreml/resolve/{MODEL_REV}/{name}', ROOT / 'models/nemotron' / local))
    manifest = []
    for meeting in MEETINGS:
        for condition, suffix in [('mhm', 'Mix-Headset'), ('sdm', 'Array1-01')]:
            path = ROOT / 'audio' / f'{meeting}.{suffix}.wav'
            if condition == 'mhm':
                url = f'https://huggingface.co/datasets/FluidInference/ami-corpus-mirror/resolve/{CORPUS_REV}/sdm/{meeting}.{suffix}.wav'
            else:
                url = f'https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{meeting}/audio/{meeting}.{suffix}.wav'
            jobs.append((url, path))
            manifest.append({'id': f'{meeting}_{condition}', 'meeting': meeting, 'condition': condition,
                'audio': str(path), 'reference': str(ROOT / 'references/AMI/test' / f'{meeting}.rttm')})
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        provenance = list(pool.map(download, jobs))
    (baseline_dir / '.fluidaudio-revision').write_text(BASELINE_REV + '\n')
    (ROOT / 'downloads.json').write_text(json.dumps(provenance, indent=2))
