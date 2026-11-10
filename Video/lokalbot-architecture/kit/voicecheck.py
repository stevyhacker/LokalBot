#!/usr/bin/env python3
"""voicecheck.py <project> [ids...]: for each take, where speech starts and ends, its level, and what whisper hears."""
import json, subprocess, struct, sys, math, glob, os, tempfile
project = sys.argv[1]; only = set(sys.argv[2:])
def bounds(path):
    raw = subprocess.run(["ffmpeg","-loglevel","error","-i",path,"-ac","1","-ar","16000","-f","s16le","-"],capture_output=True).stdout
    n = len(raw)//2; v = struct.unpack(f"<{n}h", raw)
    peak = max(abs(x) for x in v) or 1
    th = peak*0.03
    first = next(i for i,x in enumerate(v) if abs(x)>th); last = n-1-next(i for i,x in enumerate(reversed(v)) if abs(x)>th)
    rms = math.sqrt(sum(x*x for x in v[first:last])/max(1,last-first))
    return first/16000, last/16000, 20*math.log10(peak/32768), 20*math.log10(rms/32768)
def hear(path):
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(["npx","--yes","hyperframes@0.8.150","transcribe",path,"--dir",d,"--engine","whisper","--model","small.en","--json"],capture_output=True,text=True)
        try:
            data = json.loads(r.stdout[r.stdout.index("{"):])
            words = json.load(open(data["transcriptPath"]))
            words = words if isinstance(words, list) else words.get("words", [])
            return " ".join(w.get("text", w.get("word", "")) for w in words).strip()
        except Exception as e:
            return f"?? {e} " + (r.stderr or r.stdout)[-160:]
for path in sorted(glob.glob(project+"/assets/voice/*.mp3")):
    name = os.path.basename(path)[:-4]
    if only and not any(name.startswith(o) for o in only): continue
    a,b,pk,rms = bounds(path)
    print(f"{name:16s} speech {a:.2f}-{b:.2f} ({b-a:.2f}s) peak {pk:.1f} dB rms {rms:.1f} dB | {hear(path)}")
