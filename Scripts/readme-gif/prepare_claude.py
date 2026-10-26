#!/usr/bin/env python3
"""Prepare an isolated Claude Code workspace for the agent scene.

    python3 Scripts/readme-gif/prepare_claude.py <dir> <library-dir>

Writes <dir>/config (used as CLAUDE_CONFIG_DIR, so the person's own Claude Code
settings, hooks, status line and CLAUDE.md stay out of the shot), a
workspace with the page the agent edits, and an MCP config whose only server is
lokalbot-cli reading the fictional library. claude_scene.sh signs in with the
Claude subscription login; the config marks onboarding done, answers the
auto-mode offer, and trusts the workspace, so the session opens straight to
the prompt.
"""
import json
import os
import sys
from pathlib import Path

CLI = "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli"
PAGE = """<section class="pricing">
  <h2>Pricing</h2>
  <div class="plan">
    <h3>Team</h3>
    <p class="price">TBD</p>
  </div>
</section>
"""


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    root, library = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
    config, work = root / "config", root / "launch-site"
    config.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    (work / "pricing.html").write_text(PAGE)
    (config / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True,
        "theme": os.environ.get("CLAUDE_THEME", "light"),
        "hasSeenAutoDefaultNudge": True,
        "hasResetAutoModeOptInForDefaultOffer": True,
        "autoUpdates": False,
        "projects": {str(work): {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True,
                                 "allowedTools": []}},
    }, indent=2))
    (config / "settings.json").write_text(json.dumps({
        "permissions": {"defaultMode": "default", "allow": ["mcp__lokalbot", "Read", "Edit"]},
    }, indent=2))
    (root / "mcp.json").write_text(json.dumps({"mcpServers": {"lokalbot": {
        "command": CLI, "args": ["mcp"], "env": {"LOKALBOT_STORAGE_ROOT": str(library)}}}}, indent=2))
    print(work)


if __name__ == "__main__":
    main()
