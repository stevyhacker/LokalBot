"""Check the frozen run identity and preserve the original 30-case evidence."""
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import time

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    metadata = json.loads((ROOT/'results/memt-nano-nf4-offload.meta.json').read_text())
    identity = metadata['identity']
    for group in ['inputs', 'software']:
        for name, digest in identity[group].items():
            assert sha(ROOT/name) == digest, name
    for package, version in identity['packages'].items():
        assert importlib.metadata.version(package) == version, package
    for name in ['BNB_ROCM_VERSION', 'MIOPEN_FIND_MODE']:
        assert os.environ.get(name) == identity['settings'][name], name
    raw = ROOT/'results/memt-nano-nf4-offload.jsonl'
    assert sha(raw) == 'b425d06487a29f791623678378af66340944110f3cec7f80a00cb54da6a67d8f'
    records = [json.loads(line) for line in raw.read_text(encoding='utf-8').splitlines()]
    assert len(records) == len({r['id'] for r in records}) == 30
    prompts = json.loads((ROOT/'prompts.json').read_text(encoding='utf-8'))
    assert [r['id'] for r in records] == [r['id'] for r in prompts[:30]]
    spec = json.loads((ROOT/'model.json').read_text())
    for name, digest in spec['source_files'].items():
        if (ROOT/'model'/name).exists():
            assert sha(ROOT/'model'/name) == digest, name
    for weight in spec['weights']:
        assert (ROOT/'model'/weight['file']).stat().st_size == weight['bytes']
    output = ROOT/'resume-evidence'
    output.mkdir(exist_ok=True)
    assert not (output/'preflight.json').exists(), 'A resume preflight already exists; inspect it first.'
    shutil.copyfile(raw, output/'initial-30.jsonl')
    shutil.copyfile(ROOT/'smoke-result.json', output/'initial-smoke-result.json')
    shutil.copyfile(ROOT/'stop-receipt.json', output/'stop-receipt.json')
    result = dict(status='passed', time=time.time(), retained_responses=30,
        retained_bytes=raw.stat().st_size, retained_sha256=sha(raw),
        retained_ids=[r['id'] for r in records], next_case=prompts[30]['id'],
        note='Resume the same frozen identity. The prior user-interrupted case had no saved completion. No observed completion is retried or overwritten.')
    (output/'preflight.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
