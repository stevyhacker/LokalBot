#!/bin/bash
# Runs inside the Terminal window filmed for the agent scene.
#   claude_scene.sh <claude-dir>   (prepared by prepare_claude.py)
# Starts an interactive Claude Code session in the workspace, with only the
# LokalBot MCP server, an isolated config, and a clean prompt. It signs in
# with the Claude subscription login Claude Code already keeps in the login
# keychain; the token is passed in the environment only, never written or
# shown. (An API key cannot be used here: the API refuses interactive
# Claude Code sessions on an account without prepaid credit.)
set -euo pipefail
DIR=$1
cd "$DIR/launch-site"
export CLAUDE_CONFIG_DIR="$DIR/config"
unset ANTHROPIC_API_KEY
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
export CLAUDE_CODE_OAUTH_TOKEN
# Standard-speed requests only, and no session-title or other background calls.
export CLAUDE_CODE_DISABLE_FAST_MODE=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export PS1='$ '
clear
exec claude --model sonnet --permission-mode default --strict-mcp-config --mcp-config "$DIR/mcp.json" \
  --setting-sources project,user ${CLAUDE_SCENE_DEBUG:+--debug-file "$CLAUDE_SCENE_DEBUG"}
