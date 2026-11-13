# Handover: distribution launch tasks (for Codex)

_Date: 2026-08-21. The distribution implementation and repair commits are on `origin/master`; this document now records the executed result rather than an unpushed starting state._
_Repo: `stevyhacker/lokalbot`. Verified machine state: `gh` is authenticated as **stevyhacker** with SSH git protocol and `repo` scope; `claude` is installed; `hf` 1.28.0 is installed through `uv` and authenticated as **stevyhacker** with a token that cannot create a Collection or Space through the API; the signed-in Hugging Face web session and git credential can publish those resources; Raycast is authenticated as **stevan_bogosavljevic**._

## Execution update

| Task | Result on 2026-08-21 |
| --- | --- |
| Repository integration | Distribution commits `91e2b46`, `83549ee`, `de810a8`, `9b8e82d`, `67ba763`, `5c32843`, `9c8538a`, and `c0e5039` are on `origin/master`. Unrelated `Video/` and `script/` work remains untouched. |
| Own Homebrew tap | Complete: [`stevyhacker/homebrew-tap`](https://github.com/stevyhacker/homebrew-tap) serves LokalBot 0.6.2 with sha256 `17817f2cae9beb5c14a43aedad98bd6d51c9985261414791e73c1b30df173842`. Clean install, signature, Gatekeeper, and uninstall checks passed; the previous `/Applications/LokalBot.app` was restored byte-for-byte. Tap head: `eb34397`. |
| Upstream Homebrew cask | Blocked by policy: draft [PR #282446](https://github.com/Homebrew/homebrew-cask/pull/282446) was closed until the account owner personally completes the current template. Hosted audit also rejects the self-submission as below the current notability threshold. The separate deprecated-`verified:` finding is fixed on fork branch head `fdef914ed14`. Do not claim this task accepted or CI-green. |
| Claude Code plugin | `claude plugin validate .`, public marketplace installation in a clean scratch project, namespaced command discovery, and MCP initialization passed. The community-directory form redirects to Anthropic login, so account login/2FA and the final form submission remain owner-gated. |
| Console.dev | Pitch sent to `hello@console.dev` after re-checking the current selection criteria and newsletter cadence. |
| skills.sh | Public-repo discovery and a clean `npx skills add stevyhacker/lokalbot --skill lokalbot-cli --agent codex -y` install passed. The listing is live at <https://www.skills.sh/stevyhacker/lokalbot/lokalbot-cli>, and the README badge is published. |
| Uneed / DevHunt | Uneed's **Preview my product** step is complete: it scraped LokalBot's logo, GitHub URL, and repository description. Saving and scheduling the listing now requires account creation/login and remains owner-gated. DevHunt remains at its login page. |
| Hugging Face | Complete: the public [recommended-model Collection](https://huggingface.co/collections/stevyhacker/lokalbot-recommended-local-stack) contains the six verified repos and six curation notes, and the public [benchmark Space](https://huggingface.co/spaces/stevyhacker/lokalbot-benchmarks) is running the static dashboard at commit `d3315ea`. No third-party weights were uploaded. The optional Collection description remains unset because the inline editor did not persist it and the installed API token returns 403 for Collection metadata writes. |
| Raycast | Store submission [PR #30399](https://github.com/raycast/extensions/pull/30399) is open and ready for review. Both commands passed lint/build and an in-app synthetic-data test; changelog and core hosted checks pass. No private meeting data was used for validation. |

## Artifact state

| Artifact | Path | Local status |
| --- | --- | --- |
| Cask v0.6.2 (sha256 verified) + tap guide | `Distribution/homebrew/` | committed and published; upstream-policy status recorded |
| Raycast extension | `Distribution/raycast/` | committed; Store PR open for review |
| Claude Code plugin + `/lokalbot:recall` | `.claude-plugin/`, `Distribution/claude-plugin/` | committed; public install verified; directory form awaiting owner login |
| HF collection/Space specs + benchmark data | `Distribution/huggingface/` | committed and published; Collection and static Space publicly verified |
| Submission copy | `Docs/archive/distribution-submissions-2026-08.md` | committed; Console pitch sent; Uneed preview complete; remaining account-backed submissions owner-gated |
| Shared privacy/namespace guidance | `.agents/skills/lokalbot-cli/SKILL.md`, `README.md`, `.gitignore` | committed; skills.sh listing and badge live |

## Retained runbook

The original procedure remains below for reproducibility. Do not repeat a task
already marked complete in the execution table; re-check current policy and
external state before resuming a blocked task.

Before any future public task:

1. Run `git status --short` and review the complete repair diff. Preserve every unrelated untracked file.
2. This handover is **not** authorization to commit, push, create a public repository, open a PR, send email, publish an extension, or submit a form. Require an explicit owner instruction for each public action or an instruction that clearly authorizes the complete launch sequence.
3. When commit authorization exists, stage only the paths in the table plus this handover; create a follow-up commit such as `Repair distribution launch workflow and privacy boundary`.
4. When push authorization exists, push `master`, then verify `origin/master` equals local `HEAD` before Task 3 or any public submission depends on the repaired files.

---

## Task 1 — Own Homebrew tap

1. Read-only preflight: `gh repo view stevyhacker/homebrew-tap`. If it already exists, inspect it and do not recreate it.
2. After explicit approval to create the public repository, use separate create and clone commands because `gh repo create --clone` does not accept a destination:

   ```sh
   tap_dir="$(mktemp -d /tmp/lokalbot-homebrew-tap.XXXXXX)"
   gh repo create stevyhacker/homebrew-tap --public
   gh repo clone stevyhacker/homebrew-tap "$tap_dir"
   ```

3. Add a one-line `README.md` containing `Homebrew tap for LokalBot`. Copy `Distribution/homebrew/lokalbot.rb` to `$tap_dir/Casks/lokalbot.rb`, commit as `Add lokalbot 0.6.2`, and push the initial branch as `main`.
4. Verify without installing the app:

   ```sh
   brew tap stevyhacker/tap
   brew info --cask stevyhacker/tap/lokalbot
   brew cat --cask stevyhacker/tap/lokalbot | rg 'version|sha256'
   ```

   Require version `0.6.2` and sha256 `17817f2cae9beb5c14a43aedad98bd6d51c9985261414791e73c1b30df173842`. Do **not** run `brew install` on this machine without separate owner approval.

**Acceptance:** the public tap exists; the fully qualified cask resolves as 0.6.2 with the expected sha256; no installation occurred.

## Task 2 — Upstream Homebrew cask PR

1. Re-read the current [Homebrew Cask contributing rules](https://raw.githubusercontent.com/Homebrew/homebrew-cask/HEAD/CONTRIBUTING.md) and [cask PR guide](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request#cask-related-pull-request) immediately before starting.
2. From the LokalBot root, save `lokalbot_root="$PWD"`. If the fork does not exist, create it without cloning: `gh repo fork Homebrew/homebrew-cask --clone=false`. Then prepare Homebrew's contribution checkout:

   ```sh
   brew tap --force homebrew/cask
   hbc_dir="$(brew --repository homebrew/cask)"
   cd "$hbc_dir"
   git remote get-url stevyhacker >/dev/null 2>&1 || git remote add stevyhacker git@github.com:stevyhacker/homebrew-cask.git
   git fetch origin
   git switch -c lokalbot-0.6.2-new-cask origin/HEAD
   cp "$lokalbot_root/Distribution/homebrew/lokalbot.rb" Casks/l/lokalbot.rb
   ```

3. With explicit approval to install/uninstall locally, run the current gates:

   ```sh
   HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask lokalbot
   brew uninstall --cask lokalbot
   brew audit --new --cask lokalbot
   brew style --fix --cask lokalbot
   brew lgtm --online
   ```

   Review every style edit. If Xcode 26.6 blocks a local command, record the exact command and output as **blocked**, not passed. A local caveat never substitutes for hosted CI.
4. Commit as `lokalbot 0.6.2 (new cask)`, push to the `stevyhacker` fork remote, and open the PR against `Homebrew/homebrew-cask:main`. The opening body must disclose the actual AI tool/model used, summarize LokalBot, link the canonical site/source, note signing/notarization, and report each local gate's real result.
5. If maintainers challenge notability, reply politely with verifiable links only. Answer maintainer questions yourself. Do not rewrite published history unless the current guide or a maintainer requires it; if required, use `--force-with-lease`.

**Acceptance:** PR open; all hosted CI green; local results reported honestly; no failed job waived by the Xcode caveat.

## Task 3 — Claude Code plugin: verify, then list

1. Before submission, run `claude plugin validate .` from the LokalBot root and review every warning.
2. After the repaired files are on public `master`, start Claude Code in a scratch directory and run:

   ```text
   /plugin marketplace add stevyhacker/lokalbot
   /plugin install lokalbot@lokalbot
   /reload-plugins
   ```

   Confirm the namespaced `/lokalbot:recall` command appears. Do not expect `/recall`, and do not query private meeting data merely to validate installation.
3. Headless MCP initialization check:

   ```sh
   printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}\n' | lokalbot-cli mcp | head -c 400
   ```

4. Submit using `Docs/archive/distribution-submissions-2026-08.md` §4b. Individual authors use <https://platform.claude.com/plugins/submit>; Team/Enterprise directory owners may use <https://claude.ai/admin-settings/directory/submissions/plugins/new>. The old `clau.de` short link is documentation-only. Stop for owner login, organization access, 2FA, or the final submission click unless explicitly authorized.

**Acceptance:** validation passes; public installation works; `/lokalbot:recall` appears; MCP initialization responds; submission is completed only with authorization or explicitly handed back.

## Task 4 — Launch platforms

Use `Docs/archive/distribution-submissions-2026-08.md` field by field. Its agent-facing copy now states the real boundary: LokalBot does not upload library content, but an external client may transmit tool inputs/results under its own privacy terms.

- **Console.dev:** re-check the current selection page and newsletter cadence. Draft the pitch to `hello@console.dev`; if sending is not explicitly authorized, create `Docs/outbox/` and save the final draft as `Docs/outbox/console-dev-pitch.md`.
- **Uneed.best / DevHunt:** Uneed's anonymous preview is complete. Account creation/login, saving, launch scheduling, and final submission remain owner-gated unless explicitly authorized. DevHunt still requires login.
- Coordinating launch dates with Show HN is a marketing hypothesis, not a guaranteed GitHub Trending mechanism. Do not present it as a measured fact.

**Acceptance:** live fields re-verified; all `github.com/stevyhacker/lokalbot/blob/...` links use `master`; email drafted; every send/submission either authorized and completed or clearly owner-gated.

## Task 5 — Hugging Face

Completed on 2026-08-21 after explicit authorization. The active `hf` CLI is version 1.28.0 and `hf auth whoami` returns `stevyhacker`, but that token lacks Collection/Space API-write permission; publication used the signed-in web session and the authenticated Space git remote instead.

Published resources:

- Collection: <https://huggingface.co/collections/stevyhacker/lokalbot-recommended-local-stack>
- Static Space: <https://huggingface.co/spaces/stevyhacker/lokalbot-benchmarks> (`d3315ea`)

Reproduction path:

1. Write `Distribution/huggingface/scripts/create_collection.py` with `huggingface_hub`; create `LokalBot recommended local stack` using the six API-verified repositories and description in `Distribution/huggingface/COLLECTION.md`.
2. Create the static Space from `Distribution/huggingface/SPACE-benchmark.md`; generate its body from `benchmark-summary.md`.
3. Run both, capture their public URLs, and append them to `Distribution/huggingface/README.md`.

**Acceptance:** Collection and Space live; URLs recorded; zero third-party weights uploaded.

## Task 6 — Raycast extension

1. Run `cd Distribution/raycast && npm ci && npm run build`. The generated `raycast-env.d.ts` is intentionally ignored and included by `tsconfig.json`.
2. Verify `npm pkg get scripts.publish` returns `npx @raycast/api@latest publish`.
3. Review `npm audit` before publishing. As of this handover it reports two low-severity findings from the Windows-only esbuild development-server advisory through `@raycast/api` 1.104.25; the offered fix is a fresh major API upgrade, so do not apply it blindly.
4. `npm run publish` requires the owner's Raycast session and is an external Store action. Prepare it, but do not run it without explicit publish authorization.

**Acceptance:** `npm run build` succeeds; the publish script exists; publishing is completed only with authorization or handed to the owner as one command.

---

## Ground rules

- Preserve unrelated tracked and untracked work; stage only exact intended paths.
- Never rehost third-party model weights.
- No commit, push, public repository creation, PR, email, listing, Space, Collection, form submission, or Store publish without explicit authorization.
- All product claims come from the fact whitelist in `Docs/archive/distribution-submissions-2026-08.md`. For external agents, distinguish LokalBot's local bridge from the connected client's privacy terms.
- Anything requiring a password, token entry, 2FA, interactive OAuth consent, or organization permission stops for the owner.
