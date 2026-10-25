"""Combine the original evidence and this extension locally; never publish."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parent
BASE = ROOT.parent


def main():
    baseline = json.loads((BASE/'evidence-manifest.json').read_text())
    files = {}
    for name, digest in baseline.items():
        payload = (BASE/name).read_bytes()
        assert hashlib.sha256(payload).hexdigest() == digest, name
        files[name] = payload
    files['evidence-manifest.json'] = (BASE/'evidence-manifest.json').read_bytes()
    required = [
        'README.md', 'REPORT.md', 'REDDIT_DRAFT.md', 'PROTOCOL_EXTENSION.md',
        'model.json', 'verified-model-files.json', 'hardware.json',
        'RUN_HISTORY.md', 'resume_preflight.py', 'resume-20261025.log',
        'PARTIAL_REPORT.md', 'partial-scores.json', 'partial-details.json',
        'partial-validation.txt', 'stop-receipt.json',
        'requirements-observed.txt', 'lmformatenforcer-revision.json',
        'compatibility_probe.py', 'compatibility.json', 'nf4-rocm714.log',
        'nf4_offload.py', 'download_model.py', 'run_windows.py',
        'validate_adapter_model.py', 'adapter-model-validation.json',
        'validate_tokenizer.py', 'tokenizer-validation.json', 'smoke-result.json',
        'analyze.py', 'audit.jsonl', 'review.json', 'scores.json', 'details.json',
        'review_progress.py', 'record_review.py',
        'chart.py', 'chart-data.csv', 'build_report.py',
        'memory-retention-with-memt.png', 'memory-retention-with-memt.svg',
        'memory-retention-with-memt-serbian.png', 'memory-retention-with-memt-serbian.svg',
        'validate_results.py', 'validation.txt', 'package_evidence.py',
        'verify_bundle.py', 'THIRD_PARTY.md', 'LICENSE-Apache-2.0.txt',
        'run.log', 'results/memt-nano-nf4-offload.jsonl',
        'results/memt-nano-nf4-offload.meta.json', 'results/COMPLETE',
        'sources/config.json', 'sources/configuration_memt.py', 'sources/modeling_memt.py',
        'sources/README.md', 'sources/generation_config.json', 'sources/chat_template.jinja',
        'sources/tokenizer_config.json', 'sources/model.safetensors.index.json',
    ]
    for name in required:
        files['memt-nano/'+name] = (ROOT/name).read_bytes()
    # Include every pinned source, not just the human-readable model/config files.
    spec = json.loads((ROOT/'model.json').read_text())
    for name, digest in spec['source_files'].items():
        payload = (ROOT/'sources'/name).read_bytes()
        assert hashlib.sha256(payload).hexdigest() == digest, name
        files['memt-nano/sources/'+name] = payload
    for path in sorted((ROOT/'preparation-failures').rglob('*')):
        if path.is_file():
            files['memt-nano/'+str(path.relative_to(ROOT))] = path.read_bytes()
    for path in sorted((ROOT/'resume-evidence').rglob('*')):
        if path.is_file():
            files['memt-nano/'+str(path.relative_to(ROOT))] = path.read_bytes()
    files['START_HERE.md'] = b'''# Memory retention: five-configuration evidence bundle

Start with [the completed MemT extension report](memt-nano/REPORT.md),
[five-configuration English chart](memt-nano/memory-retention-with-memt.png),
and [unposted Reddit draft](memt-nano/REDDIT_DRAFT.md).

The added MemT run uses all 120 frozen cases. Its primary comparison is the 96-case English slice; 24 Serbian cases are exploratory. The original four-model experiment remains intact at the archive root. [Original report](REPORT.md).

MemT uses an experimental NF4 expert-offload runtime on Windows, while the earlier arms use GGUFs and llama.cpp on Ubuntu. Each case starts fresh, so this evaluates stateless extraction and does not exercise MemT's persistent latent-memory feature. Thinking is disabled. Read the report for all scoring and methodology limits.

[Run history](memt-nano/RUN_HISTORY.md), [validated scores](memt-nano/scores.json), [semantic decisions](memt-nano/review.json), [raw responses](memt-nano/results/memt-nano-nf4-offload.jsonl), and [validation](memt-nano/validation.txt) support auditing. Run the provided scorers and validators to check saved evidence without model weights or inference. The combined-evidence-manifest.json records every bundled payload hash.

This archive is provided with the benchmark pull request. The Reddit draft remains unposted. No model weights or application-source snapshot are included.
'''
    manifest = {name: hashlib.sha256(payload).hexdigest() for name, payload in files.items()}
    (ROOT/'evidence-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    files['combined-evidence-manifest.json'] = (ROOT/'evidence-manifest.json').read_bytes()
    path = ROOT/'share-bundle-with-memt.zip'
    prefix = 'memory-retention-2026-10-23/'
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, payload in files.items():
            assert 'snapshot' not in name and not name.endswith(('.gguf', '.safetensors', '.zip'))
            archive.writestr(prefix+name, payload)
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        for name, digest in manifest.items():
            assert hashlib.sha256(archive.read(prefix+name)).hexdigest() == digest
    print(f'Verified {len(files)} files in {path.name} ({path.stat().st_size:,} bytes). Nothing uploaded.')


if __name__ == '__main__':
    main()
