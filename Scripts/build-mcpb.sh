#!/bin/bash
# Build dist/LokalBot.mcpb — a one-click MCP bundle for GUI clients.
# The bundle contains no binary: its shim execs the signed helper installed
# inside LokalBot.app, avoiding a second copy that can drift or need signing.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' project.yml | head -1)
[ -n "$VERSION" ] || {
  echo "could not read CFBundleShortVersionString from project.yml" >&2
  exit 1
}

STAGE=$(mktemp -d /tmp/lokalbot-mcpb.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT

# The current official MCPB manifest specification is 0.3. ${__dirname} is
# substituted by the host at runtime and must remain literal in the JSON.
cat > "$STAGE/manifest.json" <<MANIFEST
{
  "manifest_version": "0.3",
  "name": "lokalbot",
  "display_name": "LokalBot Meetings",
  "version": "$VERSION",
  "description": "Ask your private, on-device meeting library: list, read, and search meetings, or get synthesized answers from LokalBot's local model. Requires the LokalBot app (www.lokalbot.com).",
  "author": { "name": "LokalBot" },
  "server": {
    "type": "binary",
    "entry_point": "run.sh",
    "mcp_config": {
      "command": "\${__dirname}/run.sh",
      "args": []
    }
  },
  "compatibility": { "platforms": ["darwin"] }
}
MANIFEST

cat > "$STAGE/run.sh" <<'RUNSH'
#!/bin/bash
CLI="/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli"
if [ ! -x "$CLI" ]; then
  echo "LokalBot.app not found in /Applications — install LokalBot first (https://www.lokalbot.com), then re-enable this extension." >&2
  exit 1
fi
exec "$CLI" mcp
RUNSH
chmod +x "$STAGE/run.sh"

# 2.1.2 was published more than seven days before this script was added.
MCPB_PACKAGE="@anthropic-ai/mcpb@2.1.2"
npx -y "$MCPB_PACKAGE" validate "$STAGE/manifest.json"
mkdir -p dist
npx -y "$MCPB_PACKAGE" pack "$STAGE" dist/LokalBot.mcpb
echo "built dist/LokalBot.mcpb (version $VERSION)"
