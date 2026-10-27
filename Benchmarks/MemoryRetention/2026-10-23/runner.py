"""Run one frozen arm on remote CPU llama.cpp; durable JSONL, resumable by hash."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parent

def sha(path):
    h=hashlib.sha256()
    with open(path,"rb") as f:
        for block in iter(lambda:f.read(8*1024*1024),b""): h.update(block)
    return h.hexdigest()

def request(port,path,body=None,timeout=600):
    data=None if body is None else json.dumps(body).encode()
    req=urllib.request.Request(f"http://127.0.0.1:{port}{path}",data=data,headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(req,timeout=timeout) as r: return json.load(r)

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("arm");ap.add_argument("model");ap.add_argument("--server",required=True)
    ap.add_argument("--port",type=int,default=18943)
    args=ap.parse_args()
    frozen=json.loads((ROOT/"frozen.json").read_text())
    for path,digest in frozen["files"].items():
        assert sha(ROOT/path)==digest, f"Frozen input modified: {path}"
    spec=next(m for m in json.loads((ROOT/"models.json").read_text()) if m["arm"]==args.arm)
    assert sha(args.model)==spec["sha256"], "Model checksum mismatch"
    out=ROOT/"results";out.mkdir(exist_ok=True)
    raw=out/f"{args.arm}.jsonl"
    identity={"arm":args.arm,"frozen_sha256":sha(ROOT/"frozen.json"),"model_sha256":spec["sha256"],"server_sha256":sha(args.server)}
    meta_path=out/f"{args.arm}.meta.json"
    if meta_path.exists():
        previous=json.loads(meta_path.read_text())
        assert previous["identity"]==identity, "Cannot resume different inputs"
    else:
        previous={"identity":identity,"runs":[]}
    done={}
    if raw.exists():
        for line in raw.read_text().splitlines():
            r=json.loads(line);assert r["id"] not in done;done[r["id"]]=r
    prompts=json.loads((ROOT/"prompts.json").read_text())
    assert set(done)<=set(p["id"] for p in prompts)
    if len(done)==len(prompts): print("already complete",args.arm);return
    with socket.socket() as s: s.bind(("127.0.0.1",args.port))
    cmd=[args.server,"-m",args.model,"--host","127.0.0.1","--port",str(args.port),"-c","8192","--jinja","--no-webui","--parallel","1","-t","12"]
    env={k:subprocess.getoutput(v) for k,v in {"utc":"date -u +%FT%TZ","uname":"uname -a","cpu":"lscpu","memory":"free -b","load":"uptime","server_version":f"{args.server} --version"}.items()}
    run={"command":cmd,"environment":env,"start":time.time(),"starting_completed":len(done)}
    previous["runs"].append(run)
    meta_path.write_text(json.dumps(previous,indent=2)+"\n")
    with open(out/f"{args.arm}.server.log","a") as log:
        proc=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT)
        try:
            for _ in range(300):
                if proc.poll() is not None: raise RuntimeError("llama-server exited; see server log")
                try: request(args.port,"/health",timeout=2);break
                except Exception: time.sleep(1)
            else: raise RuntimeError("server readiness timed out")
            props=request(args.port,"/props",timeout=10)
            (out/f"{args.arm}.props.json").write_text(json.dumps(props,ensure_ascii=False,indent=2)+"\n")
            schema=json.loads((ROOT/"schema.json").read_text())
            with raw.open("a") as f:
                for p in prompts:
                    if p["id"] in done: continue
                    body={"model":args.arm,"messages":[{"role":"system","content":p["system"]},{"role":"user","content":p["user"]}],
                        "response_format":{"type":"json_schema","json_schema":{"name":"response","strict":True,"schema":schema}},
                        "temperature":0,"seed":0,"max_tokens":1024,"thinking_budget_tokens":0,"chat_template_kwargs":{"enable_thinking":False}}
                    t=time.time()
                    entry={"id":p["id"],"started":t,"load":os.getloadavg()}
                    try:
                        reply=request(args.port,"/v1/chat/completions",body)
                        choice=reply["choices"][0]
                        entry.update(content=choice["message"].get("content") or "",reasoning=choice["message"].get("reasoning_content") or "",
                            finish=choice.get("finish_reason"),usage=reply.get("usage"),timings=reply.get("timings"),response=reply)
                    except Exception as e: entry.update(error=repr(e),content="")
                    entry["wall_seconds"]=time.time()-t
                    f.write(json.dumps(entry,ensure_ascii=False)+"\n");f.flush();os.fsync(f.fileno())
                    done[p["id"]]=entry
                    print(args.arm,len(done),"/",len(prompts),p["id"],round(entry["wall_seconds"],2),entry.get("finish",entry.get("error")),flush=True)
        finally:
            if proc.poll() is None:
                proc.terminate()
                try: proc.wait(timeout=20)
                except subprocess.TimeoutExpired: proc.kill();proc.wait()
            run["end"]=time.time();run["completed"]=len(done)
            run["end_load"]=os.getloadavg()
            meta_path.write_text(json.dumps(previous,indent=2)+"\n")

if __name__=="__main__": main()
