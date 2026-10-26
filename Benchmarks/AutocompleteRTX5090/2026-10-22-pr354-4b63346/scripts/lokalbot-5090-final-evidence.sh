#!/usr/bin/env bash
set -euo pipefail
root=/workspace/pr354-validation
for status in setup benchmark full-validation repair; do
  test "$(cat "$root/$status-exit-code.txt")" = 0
done
nvidia-smi > "$root/nvidia-smi-final.txt"
ps -eo pid,comm | grep -E 'llama-server|autocomplete-eval' > "$root/remaining-model-processes.txt" || true
sha256sum "$root"/autocomplete-{master,vulkan,cuda}/models/LFM2.5-1.2B-Instruct-Q4_K_M.gguf > "$root/model-checksums.txt"
python3 /tmp/lokalbot-5090-summarize-matched.py "$root"
python3 - <<'PY'
from pathlib import Path
import tarfile
root=Path('/workspace/pr354-validation')
with tarfile.open('/tmp/lokalbot-5090-matched-evidence.tar.gz','w:gz') as archive:
    for p in sorted(root.iterdir()):
        if p.is_file() and p.suffix in {'.log','.txt','.json','.csv'}:
            archive.add(p,arcname='evidence/'+p.name)
    for p in sorted(Path('/tmp').glob('lokalbot-5090-*.sh')):
        archive.add(p,arcname='scripts/'+p.name)
    for p in sorted(Path('/tmp').glob('lokalbot-5090-*.py')):
        archive.add(p,arcname='scripts/'+p.name)
PY
