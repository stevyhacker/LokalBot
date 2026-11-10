#!/usr/bin/env python3
"""Record the agent scene: Claude Code, in a terminal, asking LokalBot about the offsite.

    record.py <work-dir> <library> <prompt>

Runs the real Claude Code in a detached tmux pane (no window opens) whose only tool is
the installed `lokalbot-cli mcp` on the film's fictional library, types the prompt, and
saves what the terminal showed as timed snapshots (ANSI text) in <work-dir>/frames.json.
Claude Code signs in as usual; built-in tools, plugins and user settings are left out,
so the answer can only come from LokalBot. The session Claude Code saves for the scratch
folder under ~/.claude/projects can be deleted afterwards.
"""
import json
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path

work, library, prompt = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3]
COLS, ROWS = 64, 22
SESSION = "one-decision-agent"
project = work / "offsite"
project.mkdir(parents=True, exist_ok=True)
cli = shutil.which("lokalbot-cli")
claude = shutil.which("claude")
(work / "mcp.json").write_text(json.dumps({"mcpServers": {"lokalbot": {
    "command": cli, "args": ["mcp"], "env": {"LOKALBOT_STORAGE_ROOT": str(library)}}}}, indent=2))
# ask_library needs the LokalBot app serving this library, and waits a minute before saying
# it is not running. The film's library has no app behind it, so the agent gets the read tools.
settings = json.dumps({"permissions": {"allow": ["mcp__lokalbot"], "deny": ["mcp__lokalbot__ask_library"]},
                       "spinnerTipsEnabled": False})
scene = work / "scene.sh"
scene.write_text(f"""#!/bin/bash
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_HIDE_ACCOUNT_INFO=1 DISABLE_AUTOUPDATER=1
export TERM=xterm-256color COLORTERM=truecolor
cd {project}
clear
exec {claude} --model sonnet --permission-mode default --strict-mcp-config --mcp-config {work / 'mcp.json'} --setting-sources project \\
  --tools "" --disable-slash-commands --settings '{settings}' \\
  --append-system-prompt 'Answer in at most three short lines of plain text, and name the meeting it came from.'
""")
scene.chmod(0o755)


def tm(*args):
    return subprocess.run(["tmux", *args], capture_output=True, text=True)


def pane(ansi=False):
    return tm("capture-pane", "-p", *(["-e"] if ansi else []), "-t", SESSION).stdout


frames, started = [], None


def snap():
    text = pane(ansi=True)
    if not frames or frames[-1]["ansi"] != text:
        frames.append({"t": round(time.time() - started, 3), "ansi": text})


def wait(predicate, timeout, label):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if started:
            snap()
        if predicate(pane()):
            return True
        time.sleep(0.1)
    print("TIMEOUT", label)
    print(pane())
    return False


tm("kill-session", "-t", SESSION)
tm("new-session", "-d", "-s", SESSION, "-x", str(COLS), "-y", str(ROWS), str(scene))
# A folder Claude Code has not seen asks whether to trust it; this one holds nothing.
for _ in range(120):
    text = pane()
    if "trust" in text.lower() and "1." in text:
        tm("send-keys", "-t", SESSION, "Enter")
        time.sleep(1.0)
    if "❯" in text and "trust" not in text.lower():
        break
    time.sleep(0.25)
time.sleep(2.0)
started = time.time()
snap()
events = []
time.sleep(0.6)
random.seed(11)
events.append({"t": round(time.time() - started, 3), "kind": "type"})
for character in prompt:
    tm("send-keys", "-t", SESSION, "-l", character)
    snap()
    time.sleep(random.uniform(0.03, 0.07))
time.sleep(0.4)
snap()
events.append({"t": round(time.time() - started, 3), "kind": "enter"})
tm("send-keys", "-t", SESSION, "Enter")
asked = time.time()
time.sleep(1.5)
while time.time() - asked < 180:
    snap()
    text = pane()
    if "Do you want" in text or ("Allow" in text and "1." in text):
        print("permission prompt seen")
        tm("send-keys", "-t", SESSION, "Enter")
    if "esc to interrupt" not in text and time.time() - asked > 5:
        time.sleep(1.5)
        snap()
        if "esc to interrupt" not in pane():
            break
    time.sleep(0.08)
events.append({"t": round(time.time() - started, 3), "kind": "answered"})
for _ in range(15):
    snap()
    time.sleep(0.1)
print("answered after", round(time.time() - asked, 1), "s;", len(frames), "frames")
print(pane())
tm("send-keys", "-t", SESSION, "C-c")
time.sleep(0.4)
tm("send-keys", "-t", SESSION, "C-c")
time.sleep(1.0)
tm("kill-session", "-t", SESSION)
(work / "frames.json").write_text(json.dumps({"cols": COLS, "rows": ROWS, "prompt": prompt,
                                              "events": events, "frames": frames}, indent=1))
