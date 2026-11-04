#!/bin/bash
# Prepares the Agents clip on a Linux box: the released CLI on a fictional library
# (Scripts/seed_demo_library.py needs a Mac, so seed there and copy it to
# $W/library first), and an isolated Claude Code workspace whose only MCP server
# is that CLI. Claude Code signs in from ~/.claude/.credentials.json; the token
# stays in the scene's environment and is never written anywhere.
#
#   VERSION=0.12.1 prepare.sh
set -euo pipefail
W=$HOME/work/landing-demos
VERSION=${VERSION:-0.12.1}
mkdir -p "$W"
cd "$W"
archive=LokalBot-$VERSION-linux-x86_64.tar.gz
[ -f "$archive" ] || curl -fsSL -o "$archive" "https://github.com/stevyhacker/lokalbot/releases/download/v$VERSION/$archive"
mkdir -p release
tar -xzf "$archive" -C release --strip-components=1
mkdir -p library/control
echo landing-demos > library/control/agent-access-enabled
H=$W/home; rm -rf "$H"; mkdir -p "$H/.config/claude" "$H/shop-api"
cat > "$H/shop-api/README.md" <<'MD'
# shop-api
Checkout and catalog service. Caching layer: to be decided.
MD
python3 - "$W" "$H" <<'PY'
import json, sys
W, H = sys.argv[1], sys.argv[2]
work = f"{H}/shop-api"; cfg = f"{H}/.config/claude"
json.dump({
  "hasCompletedOnboarding": True, "theme": "dark-ansi", "hasSeenAutoDefaultNudge": True,
  "hasResetAutoModeOptInForDefaultOffer": True, "autoUpdates": False, "numStartups": 5,
  "hasSeenTasksHint": True, "tipsHistory": {}, "lastOnboardingVersion": "2.1.316", "bypassPermissionsModeAccepted": False,
  "projects": {work: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True, "allowedTools": []}},
}, open(f"{cfg}/.claude.json", "w"), indent=2)
json.dump({"permissions": {"defaultMode": "default", "allow": ["mcp__lokalbot"]}, "spinnerTipsEnabled": False},
          open(f"{cfg}/settings.json", "w"), indent=2)
json.dump({"mcpServers": {"lokalbot": {"command": f"{W}/release/lokalbot-cli", "args": ["mcp"],
          "env": {"LOKALBOT_STORAGE_ROOT": f"{W}/library"}}}}, open(f"{H}/mcp.json", "w"), indent=2)
PY
cat > "$W/scene.sh" <<'SH'
#!/bin/bash
# Runs inside the recorded terminal. The token stays in the environment only.
W=$HOME/work/landing-demos; TOKEN=$(python3 -c 'import json,os; print(json.load(open(os.path.expanduser("~/.claude/.credentials.json")))["claudeAiOauth"]["accessToken"])')
export HOME=$W/home CLAUDE_CONFIG_DIR=$W/home/.config/claude CLAUDE_CODE_OAUTH_TOKEN=$TOKEN
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_DISABLE_FAST_MODE=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_HIDE_ACCOUNT_INFO=1 DISABLE_AUTOUPDATER=1
export TERM=xterm-256color COLORTERM=truecolor
cd "$HOME/shop-api"
clear
exec /home/ubuntu/.local/bin/claude --model sonnet --permission-mode default --strict-mcp-config --mcp-config "$HOME/mcp.json" --setting-sources project,user
SH
chmod +x "$W/scene.sh"
command -v asciinema >/dev/null || /home/ubuntu/.local/bin/uv tool install asciinema >/dev/null 2>&1 || true
ls /home/ubuntu/.local/bin | grep -E 'asciinema|claude'
