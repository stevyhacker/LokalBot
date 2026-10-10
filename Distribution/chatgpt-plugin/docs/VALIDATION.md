# Validation record — 2026-10-09

Initial local verification for this implementation was followed by the branch-preview deployment recorded below. Public directory publication and ChatGPT host validation remain separate.

## Branch preview deployment

- Master revision `3c437e93d192fb2a90def4c7c5f43b267acf830a` was merged into the draft branch in commit `893582501120873bd4a2652e8d40968caf46c6e4`, without conflicts. The PR remains draft and unmerged.
- Initial deployed source revision: `3013ac8db48b40f34169f19dad0997f770e1a8d3`; signed companion source revision: `3516e42954cd549e5055f3e8d6e74fed56626aa6`.
- Cloudflare Worker: `lokalbot-chatgpt-relay`, served at `https://mcp.lokalbot.com`; MCP endpoint: `/mcp`.
- The initial Worker version was `3e5d3478-a8fe-42b8-8e0e-b6941b4a1653`; the deployment at `3516e42` was `7ab0db65-48cb-4bae-b521-c96674a38d47`. Both used `cf` after a successful dry run. Existing OAuth KV was preserved and Worker observability is disabled.
- Live verification with two disposable synthetic libraries passed through OAuth, the real companion, and the actual native CLI. It established user isolation even with colliding meeting/RPC ids and misleading device headers, summary/transcript selection, local permission revocation, unsupported-tool denial, and denial after device revocation with both old and refreshed tokens. Both synthetic device connections were revoked afterward.
- Public packaging passed live health, protected-resource metadata, and unauthenticated challenge checks. The ZIP contains only manifest, skills, icon, documentation, and license.
- Local checks now pass **22 tests**, none skipped, including preview launcher path handling and public-page access boundaries. The separately built Release helper also passed the fixture suite in its staged companion folder.
- [Hosted plugin protocol and native CLI validation](https://github.com/stevyhacker/LokalBot/actions/runs/37921172308) passed for `3516e42`. The same revision passed SwiftLint, XcodeGen, the macOS app build, macOS XCTest, day-in-the-life checks, generated web pages, and the website build. The draft PR's UI jobs were skipped; the aggregate UI gate is not evidence of UI execution.

## Published companion

- [Preview 0.1.0-preview.1](https://github.com/stevyhacker/LokalBot/releases/tag/chatgpt-plugin-v0.1.0-preview.1) was published on October 9, 2026 by the [tag workflow](https://github.com/stevyhacker/LokalBot/actions/runs/37923635678). Protocol, native CLI, and signed companion jobs all passed at `3516e42954cd549e5055f3e8d6e74fed56626aa6`.
- The download is a separate GitHub prerelease, not the latest stable release. It contains the foreground Node companion and an Apple Silicon Release CLI. No stable app, Sparkle feed, or installed copy was changed.
- Public DMG SHA-256: `9e2bba6f8bb7d3c3ab462d7a9a292a58e12785aa90eda22c0451c39307df206b`. It matches the independently downloaded `SHA256SUMS` and GitHub asset digest.
- The DMG and embedded CLI passed strict signature verification. The CLI is signed with Developer ID Application for team `3N8B4562P4`, with hardened runtime enabled. Apple accepted notarization submission `daef3ba6-f574-407a-9225-2f383c4986a7`; the downloaded DMG's stapled ticket validates and Gatekeeper accepts it as `Notarized Developer ID`.
- The embedded `SOURCE.json` matches the separately published file and the exact tagged source commit. The embedded CLI contains only `arm64`.
- The entire companion was downloaded without GitHub credentials, copied out of the read-only DMG, and tested through the deployed relay with two disposable synthetic libraries. OAuth, summary/transcript selection, user isolation, permission denial, forbidden tools, and old/refreshed-token denial after revocation all passed. The temporary devices were revoked and the DMG was ejected. No real library was queried or app installed.

## OpenAI submission status

- A dedicated LokalBot project is prepared in OpenAI Platform. The upload flow currently stops at the publisher identity-verification gate before selecting a ZIP. No plugin draft, domain challenge, registered plugin ID, review submission, or directory listing has been created.
- The public ZIP is prepared with remote MCP configuration, skills, a logo, privacy/support/terms links, and explicit Apple Silicon, macOS, Node, foreground-helper, and network requirements. Its setup commands use the preview launcher so they select the bundled compatible CLI. The subtitle meets the current 30-character submission limit.
- Listing URLs returned HTTP 200. Public packaging passed deployed discovery checks; the packaging/launcher tests and the public-page/OAuth-boundary tests passed after the setup-copy changes. Typechecks, bundles, and the deployment dry run passed.
- Actual ChatGPT OAuth, panel/composer behavior, a continuously available synthetic reviewer device, test-case recordings, and OpenAI review/publication remain pending. No local UI tests ran.

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

The initial 20 tests covered the backend and packaging; the suite subsequently grew to 22. The new native XCTest method belongs to the normal app unit-test suite, which passed in hosted CI at the signed preview source revision. No local browser/UI tests ran. Consult the pull request for newer hosted CI results.

Still required before directory launch: resolving the publisher upload gate, actual ChatGPT OAuth/panel/mention validation on a remote environment, reliable synthetic reviewer access and a walkthrough, and OpenAI review/publication. See [the launch runbook](DEPLOYMENT.md).
