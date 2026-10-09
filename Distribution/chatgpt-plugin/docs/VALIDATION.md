# Validation record — 2026-10-09

Initial local verification for this implementation was followed by the branch-preview deployment recorded below. Public directory publication and ChatGPT host validation remain separate.

## Branch preview deployment

- Master revision `3c437e93d192fb2a90def4c7c5f43b267acf830a` was merged into the draft branch in commit `893582501120873bd4a2652e8d40968caf46c6e4`, without conflicts. The PR remains draft and unmerged.
- Preview source revision: `3013ac8db48b40f34169f19dad0997f770e1a8d3`.
- Cloudflare Worker: `lokalbot-chatgpt-relay`, served at `https://mcp.lokalbot.com`; MCP endpoint: `/mcp`.
- Worker version: `3e5d3478-a8fe-42b8-8e0e-b6941b4a1653`. Deployed with `cf deploy --prebuilt --tag 3013ac8` after a successful dry run. Worker observability is disabled.
- Live verification with two disposable synthetic libraries passed through OAuth, the real companion, and the actual native CLI. It established user isolation even with colliding meeting/RPC ids and misleading device headers, summary/transcript selection, local permission revocation, unsupported-tool denial, and denial after device revocation with both old and refreshed tokens. Both synthetic device connections were revoked afterward.
- Public packaging passed live health, protected-resource metadata, and unauthenticated challenge checks. The ZIP contains only manifest, skills, icon, documentation, and license.
- Local checks now pass **22 tests**, none skipped, including preview launcher path handling and public-page access boundaries. The separately built Release helper also passed the fixture suite in its staged companion folder.
- [Hosted plugin protocol/relay validation](https://github.com/stevyhacker/LokalBot/actions/runs/37920583025) passed for `3013ac8`; native CLI validation was still queued when this record was written.
- A separate signed/notarized companion prerelease is prepared in CI, triggered only by `chatgpt-plugin-vX.Y.Z-preview.N` tags. Its publication has not run. No stable app, Sparkle feed, or installed copy was changed.
- The publisher dashboard requires account login before uploading or registering the plugin. Actual ChatGPT UI/OAuth validation, reviewer availability, and review/publication remain pending. No local UI tests ran.

## Initial implementation checks

| Check | Result |
| --- | --- |
| TypeScript adapter, companion, panel, and Worker typechecks | Passed |
| Bundled companion, local plugin, and relay build | Passed |
| Protocol, credential, OAuth, device-isolation, revocation, replacement, concurrency, packaging, and native CLI tests | 20 passed, none skipped |
| Native CLI build from repository sources and pinned ArgumentParser | Passed; no signing or installation |
| `cf build` | Passed; emitted deployment bundle; also printed an unused Docker-daemon diagnostic |
| SwiftLint on the changed Swift source/test | Passed with `--strict --no-cache` |
| `npm audit --audit-level=high` | 0 known vulnerabilities in the locked dependencies |
| Local documentation links and tracked diff whitespace | Passed |

The native integration check uses only a temporary synthetic library. It proves metadata/summary retrieval, explicit transcript selection, local permission enforcement, and resource denial after access is revoked. The installed production library was not queried.

The installed 0.10.2 CLI timed out on interactive initialization. A source-built helper with the pipe-reader fix passes the plugin test. A separate native probe compiled both the corrected `MCPProtocol.swift` and its unchanged `HEAD` version: the corrected reader returned before stdin closed; the version with the fix undone did not respond within one second. Existing test expectations were not changed; a live-pipe regression test was added.

The 20 tests cover the backend and packaging. The new native XCTest method belongs to the normal app unit-test suite; that complete hosted suite had not run when this local record was written. No local browser/UI tests ran. The GitHub workflow has been added; consult the pull request for current hosted CI results.

Still required before launch: a released compatible helper, approved Cloudflare deployment and origin, actual ChatGPT OAuth/panel/mention validation on a remote environment, companion distribution, publisher privacy/support/terms details, and OpenAI review/publication. See [the launch runbook](DEPLOYMENT.md).
