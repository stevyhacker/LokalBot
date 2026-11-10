# LokalBot in the MCP Registry

`server.json` is LokalBot's entry in the official
[MCP Registry](https://registry.modelcontextprotocol.io), as
`io.github.stevyhacker/lokalbot`. It names the release's one-click bundle,
`LokalBot.mcpb` (built by [`Scripts/build-mcpb.sh`](../../Scripts/build-mcpb.sh)),
with the SHA-256 GitHub reports for it. MCP clients and directories that read
the registry can then find and install it. The bundle runs the `lokalbot-cli`
helper inside LokalBot.app, so it needs the Mac app installed.

The registry keeps every version it is sent, and a published version can't be
changed. The `version`, `identifier` and `fileSha256` here show the latest
release; the publish job writes each release's own values.

## Publishing

For a stable tag, `release.yml` calls
[`mcp-registry.yml`](../../.github/workflows/mcp-registry.yml) after the macOS
job has published the release. It:

1. stops with a notice unless the `MCP_REGISTRY_PUBLISH` repository variable is
   `true`;
2. attaches `LokalBot.mcpb`, built from the tag, when the release doesn't have
   it yet, and checks the bundle's version is the tag's;
3. writes the bundle's URL and SHA-256 into a copy of `server.json`;
4. skips the version if the registry already has it, otherwise signs in with
   the registry's GitHub OIDC login (which proves the `io.github.stevyhacker`
   namespace, so there is no secret) and publishes.

Once this is on, the release attaches the bundle itself, so it no longer needs
uploading by hand. Don't replace `LokalBot.mcpb` on a release after the registry
has it: clients check the file against the SHA-256 the registry holds.

To publish a release by hand: `gh workflow run mcp-registry.yml -f tag=v<version>`.

## One-time setup (owner)

Set the repository variable once, in Settings, Secrets and variables, Actions,
Variables, or with `gh variable set MCP_REGISTRY_PUBLISH --body true --repo stevyhacker/LokalBot`.
Then publish the current release by hand (above), or wait for the next one.

## Checks

A pull request that changes this folder, the workflow or the build script runs
the workflow's `check` job: `server.json` against the schema it names, and its
`identifier` and `fileSha256` against the release's `LokalBot.mcpb`. It
publishes nothing.
