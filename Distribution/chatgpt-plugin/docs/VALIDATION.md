# Validation record — 2026-10-09

Local verification for this implementation, including a final protocol check after rebasing onto repository revision `0d9464e`. This is not hosted CI, a deployment report, or public listing evidence.

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
