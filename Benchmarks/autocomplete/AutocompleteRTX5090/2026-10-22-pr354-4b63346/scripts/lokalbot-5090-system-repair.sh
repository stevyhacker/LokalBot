#!/usr/bin/env bash
set -euo pipefail
root=/workspace/pr354-validation
export PATH="/root/.cargo/bin:$PATH"
export XDG_RUNTIME_DIR=/tmp/lokalbot-xdg
trap 'echo $? > /workspace/pr354-validation/repair-exit-code.txt' EXIT
python3 - <<'PY'
import json,shutil
from pathlib import Path
root=Path('/workspace/pr354-validation')
records=list((root/'e2e-bundled/runtimes/llama-cpp').glob('*/install.json'))
record=next(p for p in records if json.loads(p.read_text())['backend']=='cuda')
data=json.loads(record.read_text())
assert data['cudaLibraries']!='system'
server=record.parent/data['server']
system=Path('/usr/local/cuda-13.4/lib64'); system.mkdir(parents=True)
for name in ['libcudart.so.13','libcublas.so.13','libcublasLt.so.13']:
    shutil.copy2(server.parent/name,system/name)
new=root/'e2e-system'; new.mkdir()
(new/'models').symlink_to(root/'e2e-bundled/models',target_is_directory=True)
PY
cd /workspace/lokalbot/LinuxWindows
export CUDA_HOME=/usr/local/cuda-13.4
LOKALBOT_E2E_ROOT="$root/e2e-system" LOKALBOT_E2E_BACKEND=cuda cargo test --release --locked -j16 -p lokalbot-ai --test e2e_runtime installs_runtime_downloads_models_and_answers -- --ignored --nocapture --test-threads=1 > "$root/e2e-system.log" 2>&1
python3 - <<'PY'
import hashlib,json
from pathlib import Path
root=Path('/workspace/pr354-validation')
p=next((root/'e2e-system/runtimes/llama-cpp').glob('*/install.json'))
r=json.loads(p.read_text()); assert r['cudaLibraries']=='system',r
binary=p.parent/r['server']
assert not (binary.parent/'libcublas.so.13').exists()
(root/'repair-before.json').write_text(json.dumps({'record':r,'server_inode':binary.stat().st_ino,'server_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()},indent=2))
Path('/usr/local/cuda-13.4').rename(root/'removed-system-cuda')
PY
LOKALBOT_E2E_ROOT="$root/e2e-system" LOKALBOT_E2E_BACKEND=cuda cargo test --release --locked -j16 -p lokalbot-ai --test e2e_runtime installs_runtime_downloads_models_and_answers -- --ignored --nocapture --test-threads=1 > "$root/e2e-repair.log" 2>&1
python3 - <<'PY'
import hashlib,json
from pathlib import Path
root=Path('/workspace/pr354-validation')
p=next((root/'e2e-system/runtimes/llama-cpp').glob('*/install.json'))
r=json.loads(p.read_text()); assert r['cudaLibraries']!='system'
binary=p.parent/r['server']; before=json.loads((root/'repair-before.json').read_text())
assert binary.stat().st_ino==before['server_inode']
assert hashlib.sha256(binary.read_bytes()).hexdigest()==before['server_sha256']
assert all((binary.parent/name).is_file() for name in ['libcudart.so.13','libcublas.so.13','libcublasLt.so.13'])
assert not any((p.parent.parent/'.downloads').glob('*'))
(root/'repair-after.json').write_text(json.dumps({'record':r,'server_inode':binary.stat().st_ino,'server_sha256':before['server_sha256'],'server_replaced':False,'completed_archives_remaining':0},indent=2))
print('System reuse and in-place companion repair passed; server inode and digest unchanged.')
PY
