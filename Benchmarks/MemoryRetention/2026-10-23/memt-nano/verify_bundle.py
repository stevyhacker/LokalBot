"""Verify the local evidence archive and reproduce checks from a clean extraction."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit
import zipfile

ROOT = Path(__file__).resolve().parent
PREFIX = 'memory-retention-2026-10-23/'


def main():
    path = ROOT/'share-bundle-with-memt.zip'
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        assert len(names) == len(set(names)), 'Duplicate archive entries'
        assert archive.testzip() is None
        for name in names:
            pure = PurePosixPath(name)
            assert not pure.is_absolute() and '..' not in pure.parts, name
        manifest = json.loads(archive.read(PREFIX+'combined-evidence-manifest.json'))
        assert set(names) == {PREFIX+name for name in manifest} | {PREFIX+'combined-evidence-manifest.json'}
        for name, digest in manifest.items():
            assert hashlib.sha256(archive.read(PREFIX+name)).hexdigest() == digest, name
        with tempfile.TemporaryDirectory(prefix='memt-bundle-check-') as temp:
            archive.extractall(temp)
            base = Path(temp)/PREFIX
            for script in [base/'test_score.py', base/'validate_results.py',
                           base/'memt-nano/validate_results.py']:
                check = subprocess.run([sys.executable, str(script)], cwd=base,
                                       text=True, capture_output=True)
                print(check.stdout.strip())
                if check.stderr:
                    print(check.stderr.strip())
                assert check.returncode == 0, script.name
    missing = []
    count = 0
    for name in ['README.md', 'REPORT.md', 'REDDIT_DRAFT.md', 'RUN_HISTORY.md', 'PARTIAL_REPORT.md']:
        source = ROOT/name
        for target in re.findall(r'\]\(([^)]+)\)', source.read_text()):
            parsed = urlsplit(target)
            if parsed.scheme or target.startswith('#'):
                continue
            local = source.parent/unquote(parsed.path)
            count += 1
            if not local.exists():
                missing.append((name, target))
    assert not missing, missing
    for name in ['README.md', 'REPORT.md', 'REDDIT_DRAFT.md', 'RUN_HISTORY.md',
                 'build_report.py', 'chart.py', 'validate_results.py', 'package_evidence.py',
                 'verify_bundle.py', 'resume_preflight.py']:
        assert all(line == line.rstrip(' \t') for line in (ROOT/name).read_text().splitlines()), name
    print(f'PASS: {len(names)} ZIP entries; all payload hashes and CRCs; clean-extraction tests '
          f'and both result validators; {count} local document/image links; authored-file whitespace.')


if __name__ == '__main__':
    main()
