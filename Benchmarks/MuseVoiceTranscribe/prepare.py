"""Download the Nemotron study's AMI audio and verify every file is byte-identical to it."""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import shutil
import urllib.request
import wave

HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(os.environ.get('MUSE_BENCH_DATA', '/private/tmp/lokalbot-muse-voice-bench'))
STUDY = HERE.parent / 'NemotronDiarization/results/2026-09-23'


def download(job):
    url, expected, path = job
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temporary = path.with_suffix(path.suffix + '.partial')
        with urllib.request.urlopen(url, timeout=180) as r, temporary.open('wb') as f:
            shutil.copyfileobj(r, f)
        temporary.rename(path)
    digest = hashlib.file_digest(path.open('rb'), 'sha256').hexdigest()
    if digest != expected:
        raise ValueError(f'{path.name} differs from the Nemotron study audio: {digest}')
    with wave.open(str(path)) as w:
        assert (w.getframerate(), w.getnchannels(), w.getsampwidth()) == (16000, 1, 2), path
    print(f'{path.name}: {path.stat().st_size:,} bytes, SHA-256 matches', flush=True)


if __name__ == '__main__':
    hashes = {x['url']: x['sha256'] for x in json.loads((STUDY / 'downloads.json').read_text())}
    manifest, jobs = [], []
    for item in json.loads((STUDY / 'manifest.json').read_text()):
        name = pathlib.Path(item['audio']).name
        url = next(u for u in hashes if u.endswith('/' + name))
        jobs.append((url, hashes[url], ROOT / 'audio' / name))
        manifest.append(dict(item, audio=str(ROOT / 'audio' / name),
                             reference=str(STUDY / 'references' / f"{item['meeting']}.rttm")))
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(download, jobs))
    (ROOT / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    print(f'Wrote {ROOT / "manifest.json"} with {len(manifest)} recordings')
