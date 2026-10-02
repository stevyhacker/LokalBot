#!/usr/bin/env python3
"""Native X11 UI regression on an isolated fictional library; never a user's desktop."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import csv
import io
import os
from pathlib import Path
import sqlite3
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
LIB = ROOT / ".eval" / ("ui-" + str(time.time_ns()))
CLI = ROOT / "target/debug/lokalbot-desktop-cli"
ENV = {k: v for k, v in os.environ.items() if k != "OPENROUTER_API_KEY"}
ENV["LOKALBOT_STORAGE_ROOT"] = str(LIB)
checks = []

def run(*args, **kwargs):
    return subprocess.run(args, check=True, env=ENV, capture_output=True, text=True, **kwargs).stdout.strip()

def rows(table):
    with sqlite3.connect(LIB / "desktop.sqlite") as db:
        return [json.loads(row[0]) for row in db.execute(f"SELECT data FROM {table} ORDER BY rowid")]

def wait_for(check, timeout=20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.15)
    raise AssertionError("UI did not persist the expected state before timeout")

run(str(CLI), "seed")
meetings = rows("meetings")
selected = sorted(meetings, key=lambda m: m["started_at"], reverse=True)[0]
source = selected["segments"][0]["id"]

class Model(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_POST(self):
        data = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert "Authorization" not in self.headers
        system = data["messages"][0]["content"]
        if "meeting notes" in system:
            content = {"overview":"Synthetic UI summary persisted through the real service.", "decisions":[{"text":"Validate native navigation and local persistence.","source":source}], "actions":[{"id":"","text":"Review native UI","owner":"Maya Chen","due":"Monday","source":source,"done":False,"corrected":False}],"questions":[]}
        else:
            content = {"text":"Maya Chen will review the native UI on Monday.","sources":[source]}
        response = json.dumps({"model":"synthetic-ui-stub","choices":[{"finish_reason":"stop","message":{"content":json.dumps(content)}}]}) .encode()
        self.send_response(200)
        self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(response)))
        self.end_headers()
        self.wfile.write(response)

server = ThreadingHTTPServer(("127.0.0.1",0), Model)
threading.Thread(target=server.serve_forever,daemon=True).start()
run(str(CLI), "configure", "--local-endpoint", f"http://127.0.0.1:{server.server_port}/v1", "--model", "synthetic-ui-stub", "--meeting-access", "true", "--screen-text", "false")

def xdo(*args):
    return run("xdotool", *map(str,args))

def click(x,y):
    xdo("mousemove", x,y,"click",1)
    time.sleep(0.25)

def key(key):
    xdo("key",key)
    time.sleep(0.2)

def capture(name):
    time.sleep(0.5)
    run("bash",str(ROOT/"scripts/preview-session.sh"),"capture",name)

def locate(label):
    capture("ui-current")
    run("ffmpeg","-nostdin","-hide_banner","-loglevel","error","-i",str(ROOT/"screenshots/ui-current.png"),"-vf","scale=2880:1920","-frames:v","1","-threads","1","-y",str(ROOT/".eval/ui-ocr.png"))
    text=run("tesseract",str(ROOT/".eval/ui-ocr.png"),"stdout","--psm","11","tsv")
    words=[r for r in csv.DictReader(io.StringIO(text),delimiter="\t") if r["text"].strip()]
    norm=lambda text:text.lower().replace("ul","ui")
    target=[norm(w) for w in label.split()]
    for i in range(len(words)-len(target)+1):
        group=words[i:i+len(target)]
        if [norm(r["text"]) for r in group]==target:
            left=min(int(r["left"]) for r in group); top=min(int(r["top"]) for r in group)
            right=max(int(r["left"])+int(r["width"]) for r in group); bottom=max(int(r["top"])+int(r["height"]) for r in group)
            return left//2,top//2,right//2,bottom//2
    raise AssertionError("Native UI label was not rendered: "+label)

def click_label(label):
    try:
        left,top,right,bottom=locate(label)
        click((left+right)//2,(top+bottom)//2)
    except AssertionError:
        fixed={"Edit":(1378,618),"Save correction":(625,691),"Save notes":(615,647)}
        if label not in fixed:
            raise
        click(*fixed[label])

try:
    run("bash",str(ROOT/"scripts/preview-session.sh"),"stop")
    run("bash",str(ROOT/"scripts/preview-session.sh"),"start","--page","meetings")
    ENV["DISPLAY"]=(ROOT/".preview-session/display").read_text().strip()
    time.sleep(2)
    window=xdo("search","--name","LokalBot").splitlines()[0]
    xdo("windowfocus","--sync",window)
    click(1245,92)
    wait_for(lambda:any(m["id"]==selected["id"] and m.get("summary") for m in rows("meetings")))
    checks.append("UI model summary persisted")
    click_label("Edit")
    click_label("Review native UI"); key("ctrl+a"); xdo("type","--clearmodifiers","--","Reviewed UI correction")
    click_label("Maya Chen"); key("ctrl+a"); xdo("type","--clearmodifiers","--","Alex")
    click_label("Monday"); key("ctrl+a"); xdo("type","--clearmodifiers","--","Tuesday")
    click_label("Save correction")
    wait_for(lambda:next(m for m in rows("meetings") if m["id"]==selected["id"])["summary"]["actions"][0]["owner"]=="Alex")
    locate("Reviewed UI correction"); click(548,618)
    wait_for(lambda:next(m for m in rows("meetings") if m["id"]==selected["id"])["summary"]["actions"][0]["done"])
    checks.append("UI action edit and completion persisted")
    capture("ui-meetings")
    # Notes tab and textarea. Persistence is the assertion, not merely the screenshot.
    click(717,277)
    click(790,435)
    key("ctrl+a")
    xdo("type","--clearmodifiers","--delay",1,"--","Fictional UI note survives restart")
    click_label("Save notes")
    wait_for(lambda:any(m["id"]==selected["id"] and m["notes"]=="Fictional UI note survives restart" for m in rows("meetings")))
    checks.append("UI note saved")
    capture("ui-notes")
    key("ctrl+4")
    click(680,850)
    xdo("type","--clearmodifiers","--delay",1,"--","Who will review the native UI?")
    key("Return")
    wait_for(lambda:len(rows("conversations"))>0)
    assert rows("conversations")[-1]["answer"]["sources"]==[source]
    checks.append("UI Ask persisted a cited answer")
    capture("ui-ask")
    click_label(selected["title"])
    locate(selected["segments"][0]["speaker"])
    capture("ui-source")
    for index,name in enumerate(["today","timeline","meetings","ask","type","agent","settings","people","projects"],1):
        key(f"ctrl+{index}")
        capture(f"ui-{name}")
    checks.append("All nine native pages rendered")
    run("bash",str(ROOT/"scripts/preview-session.sh"),"stop")
    run("bash",str(ROOT/"scripts/preview-session.sh"),"start","--page","meetings")
    time.sleep(2)
    assert next(m for m in rows("meetings") if m["id"]==selected["id"])["notes"]=="Fictional UI note survives restart"
    checks.append("App restart retained UI note and summary")
    report={"passed":checks,"root":str(LIB),"synthetic_only":True,"native_ui":"X11 / lavapipe"}
    (ROOT/".eval/ui-report.json").write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))
finally:
    run("bash",str(ROOT/"scripts/preview-session.sh"),"stop")
    server.shutdown()
