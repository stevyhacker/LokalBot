# MCP Registry

Part of the [release runbook](../../RELEASING.md).

For a stable tag, the `mcp-registry` job (`.github/workflows/mcp-registry.yml`)
runs after the macOS job publishes the release. It attaches `LokalBot.mcpb`
(built from the tag) when the release lacks it, writes the bundle's URL and
SHA-256 into `Distribution/mcp-registry/server.json`, and publishes
`io.github.stevyhacker/lokalbot` `<version>` to the official MCP Registry with
GitHub OIDC, so there is no secret and nothing to set up. When the registry
already has the version, when the `MCP_REGISTRY_PUBLISH` repository variable is
`false`, or in a fork (whose owner the entry's namespace doesn't name), it
says so and succeeds; the bundle is attached in every case. Don't replace a
release's `LokalBot.mcpb` after the registry has it. To publish by hand:
`gh workflow run mcp-registry.yml -f tag=v<version>`. See
[Distribution/mcp-registry/README.md](../../Distribution/mcp-registry/README.md).
