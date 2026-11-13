"""Download public weights only. Never reads or sends any evaluation audio."""
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from huggingface_hub import HfApi, snapshot_download

out = Path(sys.argv[1])
api = HfApi(token=False)
jobs = [
    ('argmaxinc/whisperkit-coreml', '0f63a7800b00dd0226abd051b906c246e1907482',
     ['openai_whisper-large-v3/**'], 'argmax'),
    ('TheStageAI/thewhisper-large-v3-turbo', '5ce95e7a5890cb2191c5c783d8f818f799930705',
     ['free/macos_15_ios_18/S/10sec/**'], 'stage-turbo'),
]

def fetch(job):
    repo, revision, patterns, name = job
    info = api.model_info(repo, revision=revision)
    root = out / 'models' / name
    print(f'Downloading {repo}@{info.sha}', flush=True)
    snapshot_download(repo, revision=info.sha, token=False, local_dir=root,
                      allow_patterns=patterns, ignore_patterns=['*.pkl', '**/.DS_Store'], max_workers=6)
    record = {'repository': repo, 'revision': info.sha, 'patterns': patterns, 'path': str(root),
              'downloadBytes': sum(p.stat().st_size for p in root.rglob('*') if p.is_file() and '.cache' not in p.parts)}
    (out / f'{name}-download.json').write_text(json.dumps(record, indent=2))
    print(json.dumps(record), flush=True)

with ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(fetch, jobs))
