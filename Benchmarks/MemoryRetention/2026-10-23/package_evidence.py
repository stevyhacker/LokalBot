"""Create a reviewable local share bundle; never uploads or publishes anything."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parent
names=['README.md','REPORT.md','REDDIT_DRAFT.md','PROTOCOL.md','TRANSFER.md','cases.json','build_cases.py','prompts.json','build_prompts.py','schema.json','models.json','frozen.json','runner.py','run_remote.py','score.py','test_score.py','review.json','scores.json','details.json','chart-data.csv','chart.py','build_report.py','prepare_audit.py','validate_results.py','package_evidence.py','runtime-checksums.txt','validation.txt','memory-retention.png','memory-retention.svg','memory-retention-serbian.png','memory-retention-serbian.svg','operational-summary.json']
names+=['citation_diagnostic.py','citation-diagnostic.json']
paths=[ROOT/n for n in names]
paths += sorted((ROOT/'results').glob('*'))+sorted((ROOT/'audit').glob('*'))
paths=[p for p in paths if p.is_file()]
assert all((ROOT/n).exists() for n in names),'Missing deliverable'
assert not any('snapshot' in p.name or p.suffix=='.gguf' for p in paths)
manifest={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
(ROOT/'evidence-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
paths.append(ROOT/'evidence-manifest.json')
with zipfile.ZipFile(ROOT/'share-bundle.zip','w',zipfile.ZIP_DEFLATED,compresslevel=9) as z:
    for p in paths:z.write(p,arcname='memory-retention-2026-10-23/'+str(p.relative_to(ROOT)))
with zipfile.ZipFile(ROOT/'share-bundle.zip') as z:
    assert z.testzip() is None
    assert not any('snapshot' in n for n in z.namelist())
    for name,digest in manifest.items():assert hashlib.sha256(z.read('memory-retention-2026-10-23/'+name)).hexdigest()==digest
print(f'Created and verified local share-bundle.zip: {len(paths)} files, {(ROOT/"share-bundle.zip").stat().st_size:,} bytes. Nothing uploaded.')
