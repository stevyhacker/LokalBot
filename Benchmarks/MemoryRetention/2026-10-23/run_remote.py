"""Fetch pinned public weights, then run arms sequentially on the remote host."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parent

def sha(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for b in iter(lambda:f.read(8*1024*1024),b""):h.update(b)
    return h.hexdigest()

def main():
    models=ROOT/"models";models.mkdir(exist_ok=True)
    server=Path.home()/"bonsai-lfm-eval-20261018/llama.cpp-0.7.0/build/bin/llama-server"
    for m in json.loads((ROOT/"models.json").read_text()):
        model=Path(m["reuse"]) if m.get("reuse") and Path(m["reuse"]).exists() else models/m["file"]
        if not model.exists():
            if shutil.disk_usage(ROOT).free < 22_000_000_000 and m["arm"]=="hy-memory-q4":raise RuntimeError("Not enough disk headroom for Hy weights")
            url=f"https://huggingface.co/{m['repo']}/resolve/{m['revision']}/{m['file']}"
            part=model.with_suffix(".gguf.part")
            print("download",m["arm"],url,flush=True)
            subprocess.run(["curl","--fail","-L","--retry","4","-C","-","-o",str(part),url],check=True)
            assert sha(part)==m["sha256"],"Downloaded model hash mismatch"
            part.rename(model)
        print("run",m["arm"],time.time(),flush=True)
        subprocess.run([sys.executable,str(ROOT/"runner.py"),m["arm"],str(model),"--server",str(server)],check=True)
    (ROOT/"COMPLETE").write_text(str(time.time())+"\n")

if __name__=="__main__":main()
