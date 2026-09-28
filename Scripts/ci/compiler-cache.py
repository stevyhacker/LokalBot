#!/usr/bin/env python3
"""Bounded Xcode CAS reuse. Products and provenance are never cached."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

CACHE = Path('.build/compilation-cache')
CAS = CACHE / 'cas'
EVIDENCE = Path('.build/ci')
LIMIT = 2 * 1024 ** 3
INPUTS = ('LokalBot/', 'CLI/', 'LokalBotTests/', 'LokalBotUITests/')


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fingerprint(paths):
    return hashlib.sha256(json.dumps([(str(p), digest(p)) for p in sorted(paths)],
                                     separators=(',', ':')).encode()).hexdigest()


def emit(**values):
    if target := os.environ.get('GITHUB_OUTPUT'):
        with open(target, 'a') as stream:
            for key, value in values.items():
                stream.write(f'{key}={value}\n')


def prepare(kind):
    if kind not in ('unit', 'ui'):
        raise ValueError('Expected unit or ui')
    files = [Path(p) for p in output('git', 'ls-files', '-z').split('\0') if p]
    # These settings include the generated scheme, dependency pins, scripts and
    # all build arguments. No broad cross-toolchain/dependency restore prefix.
    build_scripts = {'Scripts/ci/compiler-cache.py', 'Scripts/ui-tests.sh',
                     'Scripts/fetch-llama.sh', 'Scripts/fetch-sherpa.sh',
                     '.github/workflows/build.yml', '.github/workflows/ui-tests.yml'}
    settings = [p for p in files if str(p) == 'project.yml' or p.name == 'Package.resolved'
                or str(p) in build_scripts]
    generated = list(Path('LokalBot.xcodeproj').glob('**/*.xcscheme'))
    generated += [Path('LokalBot.xcodeproj/project.pbxproj')]
    identity = dict(version=1, kind=kind, xcode=output('xcodebuild', '-version'),
                    swift=output('xcrun', 'swiftc', '--version'),
                    sdk=output('xcrun', '--sdk', 'macosx', '--show-sdk-version'),
                    sdk_build=output('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'),
                    arch=output('uname', '-m'), configuration='Debug', signing='NO',
                    settings=fingerprint(settings + generated))
    compatible = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    source = fingerprint([p for p in files if str(p).startswith(INPUTS)])
    prefix = f'xcode-cas-v1-{kind}-{compatible}-'
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    (EVIDENCE / 'cache-identity.json').write_text(json.dumps(identity, indent=2) + '\n')
    (EVIDENCE / 'source.json').write_text(json.dumps(dict(commit=output('git', 'rev-parse', 'HEAD'),
                                                        sources=source, identity=identity,
                                                        run=os.environ.get('GITHUB_RUN_ID', ''),
                                                        attempt=os.environ.get('GITHUB_RUN_ATTEMPT', '')), indent=2) + '\n')
    emit(key=prefix + source, prefix=prefix)
    print(json.dumps(dict(key=prefix + source, identity=identity), indent=2))


def cache_files():
    result = {}
    total = 0
    if not CAS.is_dir() or CAS.is_symlink():
        raise ValueError('Missing cache directory')
    for path in sorted(CAS.rglob('*')):
        if path.is_symlink():
            raise ValueError('Cache contains a symbolic link')
        if path.is_file():
            total += path.stat().st_size
            if total > LIMIT:
                raise ValueError('Compiler cache exceeds 2 GiB budget')
            result[str(path.relative_to(CAS))] = digest(path)
    if not result:
        raise ValueError('Empty compiler cache')
    return result, total


def discard():
    if CACHE.is_symlink():
        CACHE.unlink()
    elif CACHE.exists():
        shutil.rmtree(CACHE)


def validate():
    try:
        if CACHE.is_symlink():
            raise ValueError('Cache root is a symbolic link')
        saved = json.loads((CACHE / 'manifest.json').read_text())
        expected = json.loads((EVIDENCE / 'cache-identity.json').read_text())
        if saved['identity'] != expected:
            raise ValueError('Incompatible compiler cache')
        files, size = cache_files()
        if saved['files'] != files or saved['bytes'] != size:
            raise ValueError('Compiler cache digest mismatch')
        print(f'Validated {size} compiler-cache bytes')
        return True
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f'Compiler cache unavailable; compiling cleanly: {error}')
        discard()
        return False


def clean_products():
    # Always build the checked-out revision. A cache can never supply a stamp,
    # xctestrun, executable, or incremental build database from another run.
    dd = Path('.build/dd')
    if dd.exists():
        shutil.rmtree(dd)


def build(command):
    mode = os.environ.get('COMPILER_CACHE_MODE', 'off')
    if mode not in ('warm', 'cold', 'off'):
        raise ValueError('Expected warm, cold or off cache mode')
    if not command or command[0] != 'xcodebuild' or 'build-for-testing' not in command:
        raise ValueError('Expected xcodebuild build-for-testing')
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    restored = validate() if mode == 'warm' else False
    if mode != 'warm':
        discard()
    validation_seconds = time.monotonic() - started
    clean_products()
    CAS.mkdir(parents=True, exist_ok=True)
    attempts = []
    for cached in ([True, False] if mode != 'off' else [False]):
        args = command + [f'COMPILATION_CACHE_ENABLE_CACHING={"YES" if cached else "NO"}',
                          'COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES',
                          f'COMPILATION_CACHE_CAS_PATH={CAS.resolve()}']
        start = time.monotonic()
        log_path = EVIDENCE / f'compile-{len(attempts) + 1}.log'
        with log_path.open('w') as log:
            process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            for line in process.stdout:
                print(line, end='', flush=True)
                log.write(line)
            code = process.wait()
        log = log_path.read_text()
        metrics = re.search(r'(\d+) hits / (\d+) cacheable tasks', log)
        attempts.append(dict(caching=cached, exit=code, seconds=round(time.monotonic() - start, 2),
                             hit_remarks=len(re.findall(r'(?:cache hit|replay(?:ed|ing).*cached)', log, re.I)),
                             miss_remarks=len(re.findall(r'cache miss', log, re.I)),
                             task_hits=int(metrics[1]) if metrics else None,
                             cacheable_tasks=int(metrics[2]) if metrics else None))
        if code == 0:
            break
        if cached:
            print('::warning::Cached build failed; retrying once with a fresh build directory and caching disabled')
            discard()
            clean_products()
    report = dict(mode=mode, restored=restored, validation_seconds=round(validation_seconds, 2),
                  attempts=attempts, seconds=round(time.monotonic() - started, 2), exit=code)
    (EVIDENCE / 'compile.json').write_text(json.dumps(report, indent=2) + '\n')
    emit(cache_save=str(code == 0 and attempts[-1]['caching'] and mode == 'warm').lower())
    if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(summary, 'a') as stream:
            stream.write(f"\nCompiler cache: `{mode}`, restored `{restored}`, total {report['seconds']}s. "
                         f"Attempts: `{json.dumps(attempts)}`\n")
    return code


def seal():
    started = time.monotonic()
    try:
        files, size = cache_files()
        identity = json.loads((EVIDENCE / 'cache-identity.json').read_text())
        (CACHE / 'manifest.json').write_text(json.dumps(dict(identity=identity, bytes=size, files=files)))
        (EVIDENCE / 'cache-save.json').write_text(json.dumps(dict(bytes=size, seconds=round(time.monotonic() - started, 2))))
        emit(save='true')
        print(f'Compiler cache: {size} bytes, sealed in {time.monotonic() - started:.2f}s')
    except (OSError, ValueError) as error:
        # An oversized/unusable accelerator is optional, never a build failure.
        print(f'::notice::Not saving compiler cache: {error}')
        emit(save='false')
        discard()


if __name__ == '__main__':
    try:
        mode, *args = sys.argv[1:]
        if mode == 'key':
            prepare(*args)
        elif mode == 'build':
            sys.exit(build(args))
        elif mode == 'seal':
            seal()
        else:
            raise ValueError('Expected key, build or seal')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
