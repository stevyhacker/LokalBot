#!/usr/bin/env python3
"""Records the Claude Code scene in tmux with asciinema. Usage: record.py <name> <cols> <rows> <prompt>"""
import subprocess, sys, time, os, random, re
name, cols, rows, prompt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
W = os.path.expanduser("~/work/landing-demos")
S = f"landing-{name}"
def tm(*a, **k): return subprocess.run(["tmux", *a], capture_output=True, text=True, **k)
tm("kill-session", "-t", S)
cast = f"{W}/{name}.cast"
cmd = f"{os.path.expanduser('~/.local/bin/asciinema')} rec --overwrite -q --cols {cols} --rows {rows} -c {W}/scene.sh {cast}"
tm("new-session", "-d", "-s", S, "-x", cols, "-y", rows, cmd)
def pane(): return tm("capture-pane", "-p", "-t", S).stdout
def wait(pred, timeout, label):
    t = time.time()
    while time.time() - t < timeout:
        p = pane()
        if pred(p): return p
        time.sleep(0.25)
    print("TIMEOUT", label); print(pane()); return None
wait(lambda p: "❯" in p or "> " in p, 40, "prompt")
time.sleep(1.5)
for ch in prompt:
    tm("send-keys", "-t", S, "-l", ch)
    time.sleep(random.uniform(0.015, 0.05))
time.sleep(0.35)
tm("send-keys", "-t", S, "Enter")
t0 = time.time()
# Busy while the spinner line ("esc to interrupt") shows; approve anything that asks.
time.sleep(2)
while time.time() - t0 < 180:
    p = pane()
    if "Do you want" in p or "Allow" in p and "1." in p:
        print("permission prompt seen"); tm("send-keys", "-t", S, "Enter")
    if "esc to interrupt" not in p and time.time() - t0 > 6:
        time.sleep(2.0)
        if "esc to interrupt" not in pane(): break
    time.sleep(0.3)
print("answered after", round(time.time() - t0, 1))
time.sleep(2.0)
print(pane())
tm("send-keys", "-t", S, "C-c"); time.sleep(0.4); tm("send-keys", "-t", S, "C-c"); time.sleep(1.0)
tm("kill-session", "-t", S)
print("cast", os.path.getsize(cast))
