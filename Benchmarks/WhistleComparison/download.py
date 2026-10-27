"""Fetch public Whistle weights/runtime only; never takes audio as input."""
import hashlib
import json
import sys
from pathlib import Path
import requests

SPECS = [
    ('Cactus-Compute/whistle', 'b358ddadd89b7a713b5aa131f23032d3cca1b251', ['whistle.cact', 'LICENSE']),
    ('Cactus-Compute/needle3', '2ae11323dc000f5e70c49f7403efa6af12ba9e67',
     ['macos-arm64/needle', 'macos-arm64/libneedle.a', 'macos-arm64/needle.h', 'LICENSE']),
]

def main():
    root = Path(sys.argv[1])
    records = []
    for repo, revision, names in SPECS:
        response = requests.get(f'https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true', timeout=40)
        response.raise_for_status()
        metadata = {f['rfilename']: f for f in response.json()['siblings']}
        for name in names:
            target = root / 'models' / repo.split('/')[-1] / name
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                with requests.get(f'https://huggingface.co/{repo}/resolve/{revision}/{name}', stream=True, timeout=60) as r:
                    r.raise_for_status()
                    with target.open('wb') as out:
                        for chunk in r.iter_content(1 << 20):
                            out.write(chunk)
            digest = hashlib.sha256(target.read_bytes()).hexdigest()
            expected = metadata[name].get('lfs', {}).get('sha256')
            if expected and expected != digest:
                raise ValueError(f'Hash mismatch: {name}')
            records.append(dict(repo=repo, revision=revision, file=name, bytes=target.stat().st_size,
                                sha256=digest, verifiedLFS=bool(expected)))
            print(f'{name}: {target.stat().st_size} bytes, SHA256 {digest}', flush=True)
    (root / 'downloads.json').write_text(json.dumps(records, indent=2) + '\n')

if __name__ == '__main__':
    main()
