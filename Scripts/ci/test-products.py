#!/usr/bin/env python3
"""Transfer exact-candidate test products between jobs of one workflow run."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

spec = importlib.util.spec_from_file_location('stamp', Path(__file__).with_name('ui-build-stamp.py'))
stamp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stamp)


def identity():
    # Not the attempt: a failed-jobs-only rerun keeps the build job that passed,
    # so its consumers use products from an earlier attempt of the same run,
    # built from the same commit, toolchain and dependency lock.
    value = stamp.identity()
    for key in ('root', 'job', 'attempt'):
        value.pop(key)
    return value


# UI products are built with the release toolchain on macOS 26 and run on the
# oldest supported macOS, whose image has an older Xcode. Everything else about
# the candidate must still match; unit-test products stay on one toolchain.
CROSS_TOOLCHAIN_KEYS = {'ui': {'xcode', 'sdk'}}


def matches(saved, current, kind):
    ignored = CROSS_TOOLCHAIN_KEYS.get(kind, set())
    return ({key: value for key, value in saved.items() if key not in ignored}
            == {key: value for key, value in current.items() if key not in ignored})


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def transfer(mode, kind):
    folder = Path('.build/transfer')
    archive = folder / f'{kind}.tar'
    manifest = folder / f'{kind}.json'
    products = Path('.build/dd/Build/Products')
    if mode == 'pack':
        if not list(products.glob('*.xctestrun')):
            raise ValueError('Missing xctestrun')
        folder.mkdir(parents=True, exist_ok=True)
        subprocess.run(['tar', '-cf', str(archive), '-C', str(products), '.'], check=True)
        manifest.write_text(json.dumps(dict(identity=identity(), sha256=digest(archive),
                                           root=str(Path.cwd()), kind=kind,
                                           runner_image=dict(os=os.environ.get('ImageOS', ''),
                                                             version=os.environ.get('ImageVersion', ''))), indent=2))
    elif mode == 'unpack':
        saved = json.loads(manifest.read_text())
        current = identity()
        if not matches(saved['identity'], current, kind) or saved['kind'] != kind or saved['sha256'] != digest(archive):
            raise ValueError('Test products do not match this candidate, run, toolchain or digest')
        if saved['identity'] != current:
            print(f"Built with {saved['identity'].get('xcode', '?')} (SDK {saved['identity'].get('sdk', '?')}); "
                  f"testing with {current.get('xcode', '?')} (SDK {current.get('sdk', '?')})")
        if products.exists():
            shutil.rmtree(products)
        products.mkdir(parents=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(products)], check=True)
        for path in products.glob('*.xctestrun'):
            value = plistlib.loads(path.read_bytes())
            def relocate(node):
                if isinstance(node, dict):
                    return {key: relocate(item) for key, item in node.items()}
                if isinstance(node, list):
                    return [relocate(item) for item in node]
                if isinstance(node, str):
                    return node.replace(saved['root'] + '/.build/dd/Build/Products', '__TESTROOT__').replace(saved['root'], str(Path.cwd()))
                return node
            path.write_bytes(plistlib.dumps(relocate(value)))
        if kind == 'ui':
            target = Path('.build/dd/ui-build.json')
            target.write_text(json.dumps(stamp.identity()))
    else:
        raise ValueError('Expected pack or unpack')


if __name__ == '__main__':
    try:
        transfer(*sys.argv[1:])
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
