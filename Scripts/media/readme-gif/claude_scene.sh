#!/bin/bash
set -euo pipefail
DIR=$1
cd "$DIR/launch-site"
export CLAUDE_CONFIG_DIR="$DIR/config"
unset ANTHROPIC_API_KEY
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
export CLAUDE_CODE_OAUTH_TOKEN
export CLAUDE_CODE_DISABLE_FAST_MODE=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export PS1='$ '
clear
exec claude --model sonnet --permission-mode default --strict-mcp-config --mcp-config "$DIR/mcp.json" \
  --setting-sources project,user ${CLAUDE_SCENE_DEBUG:+--debug-file "$CLAUDE_SCENE_DEBUG"}
