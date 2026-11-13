"""Fetch the official pinned checkpoint into a disposable benchmark directory."""
import hashlib
import json
from pathlib import Path
import urllib.parse
import urllib.request

ROOT = Path('/private/tmp/lokalbot-embeddinggemma2-20261006')
MODEL = 'google/embeddinggemma-2'
REVISION = '914f7f89142e33e77833254d9c9b90c3cef7303b'


def main():
    folder = ROOT / 'model'
    folder.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(
        f'https://huggingface.co/api/models/{MODEL}/revision/{REVISION}?blobs=true', timeout=30
    ) as response:
        metadata = json.load(response)
    assert metadata['sha'] == REVISION
    files = []
    for item in metadata['siblings']:
        name = item['rfilename']
        if not (name.endswith(('.json', '.safetensors', '.model', '.jinja')) or name == 'README.md'):
            continue
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        expected = item.get('lfs', {}).get('sha256')
        if not target.exists():
            partial = target.with_suffix(target.suffix + '.part')
            url = f'https://huggingface.co/{MODEL}/resolve/{REVISION}/{urllib.parse.quote(name)}'
            with urllib.request.urlopen(url, timeout=120) as response, partial.open('wb') as output:
                while chunk := response.read(4 * 1024 * 1024):
                    output.write(chunk)
            partial.replace(target)
        with target.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        assert target.stat().st_size == item['size'], name
        assert not expected or expected == digest, name
        files.append({'file': name, 'bytes': target.stat().st_size, 'sha256': digest})
        print(f'Verified {name}: {target.stat().st_size:,} bytes', flush=True)
    (ROOT / 'model-manifest.json').write_text(json.dumps({
        'repository': MODEL, 'revision': REVISION, 'files': files,
    }, indent=2) + '\n')


if __name__ == '__main__':
    main()
