#!/usr/bin/env bash
# Builds the ZIP for the OpenAI plugin directory (ChatGPT and Codex) from
# Distribution/openai-plugin: plugin.json, skills/ and assets/ at the ZIP root.
# Upload it at https://platform.openai.com/plugins. See
# Distribution/openai-plugin/README.md.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/Distribution/openai-plugin"
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$src/plugin.json")"
out="$root/dist/lokalbot-openai-plugin-$version.zip"

python3 -m unittest "$root/Scripts/tests/test_openai_plugin.py" >/dev/null

mkdir -p "$root/dist"
rm -f "$out"
(cd "$src" && zip -q -r -X "$out" plugin.json skills assets -x '*.DS_Store')
echo "$out"
unzip -l "$out" | tail -n +2
