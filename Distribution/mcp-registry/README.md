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

1. attaches `LokalBot.mcpb`, built from the tag, when the release doesn't have
   it yet, and checks the bundle's version is the tag's;
2. writes the bundle's URL and SHA-256 into a copy of `server.json`;
3. skips the version if the registry already has it, otherwise signs in with
   the registry's GitHub OIDC login (which proves the `io.github.stevyhacker`
   namespace, so there is no secret) and publishes.

The release attaches the bundle itself, so it needs no uploading by hand. Don't
replace `LokalBot.mcpb` on a release after the registry has it: clients check
the file against the SHA-256 the registry holds.

There is nothing to set up. Steps 2 and 3 are skipped, with a notice, in a fork
(the sign-in can only publish under the repository owner's own namespace) and
while the `MCP_REGISTRY_PUBLISH` repository variable is `false`; step 1 runs
either way.

To publish a release by hand, for example one made before this job existed:
`gh workflow run mcp-registry.yml -f tag=v<version>`.

## Checks

A pull request that changes this folder, the workflow or the build script runs
the workflow's `check` job: `server.json` against the schema it names, and its
`identifier` and `fileSha256` against the release's `LokalBot.mcpb`. It
publishes nothing.
