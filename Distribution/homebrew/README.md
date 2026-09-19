# Homebrew distribution for LokalBot

This directory contains the Homebrew cask for [LokalBot](https://www.lokalbot.com)
(`lokalbot.rb`) and notes on validating it and shipping it to users.

- Cask token: `lokalbot`
- Cask snapshot packaged here: **0.8.3**. The live tap is authoritative for
  installation and follows stable releases automatically (see below).
- Requirements enforced by the cask: Apple Silicon (M1+), macOS 15.0+
- Style verified against `Homebrew/homebrew-cask` `CONTRIBUTING.md`, the
  [Cask Cookbook stanza order](https://docs.brew.sh/Cask-Cookbook#stanza-order),
  and the livecheck GitHub strategies in `Homebrew/brew`.

## 1. Validate locally

Homebrew resolves casks through tap structure, so `brew style` / `brew info` /
`brew audit` will **not** accept a bare file path like
`./Distribution/homebrew/lokalbot.rb`. Put the cask in a throwaway local tap
first (this is exactly what we ran; it is safe to delete afterwards):

```sh
ruby -c Distribution/homebrew/lokalbot.rb          # Syntax OK

brew tap-new --no-git local/scratch
mkdir -p "$(brew --repository)/Library/Taps/local/homebrew-scratch/Casks"
cp Distribution/homebrew/lokalbot.rb \
   "$(brew --repository)/Library/Taps/local/homebrew-scratch/Casks/"

brew style --cask local/scratch/lokalbot       # style gate
brew info --cask local/scratch/lokalbot        # parses + prints metadata
brew livecheck local/scratch/lokalbot          # release discovery
brew audit --new --cask local/scratch/lokalbot # strict online new-cask audit
```

Expected results:

| Command | Expected |
| --- | --- |
| `ruby -c …` | `Syntax OK` |
| `brew style …` | `1 file inspected, no offenses detected` |
| `brew info …` | shows `lokalbot (LokalBot): 0.6.2 (auto_updates)`, the desc, and `Required: arm64 architecture, macOS >= 15` |
| `brew livecheck …` | shows `0.6.2 ==> 0.6.2` |
| `brew audit …` | must exit 0 before an upstream submission can proceed (downloads the ~55 MB DMG, verifies sha256, checks signing and policy eligibility) |

Verified on this machine: `ruby -c`, `brew style`, `brew info`, and
`brew livecheck local/scratch/lokalbot` (`0.6.2 ==> 0.6.2`, proving the
`:github_releases` strategy resolves the version). A clean install put
`LokalBot.app` in `/Applications`; Gatekeeper accepted the notarized Developer
ID app; uninstall removed it; and the previous installation was restored
byte-for-byte. The full local audit was blocked because Homebrew's current
toolchain requires Xcode 27 while this machine has Xcode 26.6. Hosted CI did
run the audit and rejected the upstream submission on Homebrew's notability
policy. The sha256 was also verified independently:

```sh
curl -sLO https://github.com/stevyhacker/lokalbot/releases/download/v0.6.2/LokalBot.dmg
shasum -a 256 LokalBot.dmg
# 17817f2cae9beb5c14a43aedad98bd6d51c9985261414791e73c1b30df173842
```

Clean up the scratch tap when done:

```sh
brew untap local/scratch
```

## 2. Submit upstream to Homebrew/homebrew-cask

**Current status (2026-08-21): blocked by upstream policy.** Draft PR
[#282446](https://github.com/Homebrew/homebrew-cask/pull/282446) was closed by
automation because Homebrew requires the account owner to read and complete its
current PR template personally. Hosted audit also reports that the
self-submitted repository does not meet the current notability threshold. The
deprecated `verified:` stanza reported in the same run has been removed, but
that code fix cannot address notability. Keep the own tap below as the shipping
path until the project has enough adoption to pass a fresh audit.

Follow both [CONTRIBUTING.md](https://github.com/Homebrew/homebrew-cask/blob/HEAD/CONTRIBUTING.md)
and the maintained [pull-request guide](https://docs.brew.sh/How-To-Open-a-Homebrew-Pull-Request#cask-related-pull-request).
The important constraints are one PR per cask, two-space indentation, no
extraneous comments, and a disclosure in the opening comment naming any
AI/LLM tool and model used. Do not add AI attribution trailers, and answer all
maintainer questions yourself.

Steps:

1. Fork `Homebrew/homebrew-cask`, run `brew tap --force homebrew/cask`, and add
   the fork as a pushable remote in `$(brew --repository homebrew/cask)`.
2. Create a branch from the current `origin/HEAD`, then add the file at exactly
   `Casks/l/lokalbot.rb` (one-letter subdirectory by the cask token's first
   character).
3. With the owner's approval to install locally, run the current cask gates:

   ```sh
   HOMEBREW_NO_INSTALL_FROM_API=1 brew install --cask lokalbot
   brew uninstall --cask lokalbot
   brew audit --new --cask lokalbot
   brew style --fix --cask lokalbot
   brew lgtm --online
   ```

   If the installed Xcode blocks a local gate, record the exact output, but do
   not call the gate passed and do not treat the caveat as a substitute for
   green hosted CI.
4. Use the current new-cask commit convention:

   ```sh
   git add Casks/l/lokalbot.rb
   git commit -m "lokalbot 0.6.2 (new cask)"
   ```

5. Push the branch to the fork and open the PR against
   `Homebrew/homebrew-cask` → `main`. PR body template
   (GitHub inserts most of this via the PR template — keep those checklist
   items and add):

   ```markdown
   Create lokalbot 0.6.2 (new cask)

   - Website: https://www.lokalbot.com
   - Repo (source): https://github.com/stevyhacker/lokalbot
   - DMG is Developer ID signed, notarized, stapled; updates via Sparkle
     (appcast attached to each release).
   - Local validation: <list each command and its actual result; disclose any
     Xcode-blocked command as not run or blocked, never as passed>.
   - Disclosure: this cask was drafted with an LLM assistant (<tool/model>); I
     reviewed every line.
   ```

6. Hosted CI must be green before the PR is considered complete. A local Xcode
   limitation belongs in the PR body but does not excuse a failed hosted job.

### Realistic risk: notability

`homebrew/cask` applies an acceptance bar to self-submitted apps. On 2026-08-21
its hosted audit reported: fewer than 90 forks, fewer than 90 watchers, and
fewer than 225 stars. Do not relitigate or manufacture traction. Re-run the
current audit after real adoption clears the policy, then have the account
owner personally complete Homebrew's current template and answer maintainer
questions.

## 3. Shipping path: own tap

The public tap is live at
[`stevyhacker/homebrew-tap`](https://github.com/stevyhacker/homebrew-tap).
Repo layout is minimal — just the cask at the root of the default branch:

```
homebrew-tap/
└── Casks/
    └── lokalbot.rb      # same file as Distribution/homebrew/lokalbot.rb
```

No `tap_migrations.json`, no formulae needed. Copy-paste install for users:

```sh
brew tap stevyhacker/tap https://github.com/stevyhacker/homebrew-tap
brew install --cask lokalbot
```

(Once the tap exists under your account, the short form
`brew tap stevyhacker/tap` also works.)

Release synchronization:

1. Publish the stable GitHub release with both `LokalBot.dmg` and `appcast.xml`.
2. The tap's [Sync LokalBot release workflow](https://github.com/stevyhacker/homebrew-tap/actions/workflows/sync-lokalbot.yml)
   checks hourly. It downloads new assets, verifies their release SHA-256 digests
   and sizes, checks appcast/DMG consistency, and updates the tap cask. It refuses
   prereleases, incomplete releases, downgrades, and same-version checksum changes.
3. For immediate synchronization after publication, dispatch it explicitly:
   `gh workflow run sync-lokalbot.yml --repo stevyhacker/homebrew-tap --ref main`.
   Verify the run succeeds and the live cask matches the release before promoting
   Homebrew. Scheduled runs may be delayed or disabled after 60 days of repository
   inactivity; the release check must not assume the schedule has run.
4. No cross-repository secret is needed: the tap workflow uses its own
   `GITHUB_TOKEN`. This repository's cask is a reference snapshot, not the package
   Homebrew installs. Refresh it from the verified tap when updating these docs.
5. `brew livecheck` discovers available versions; it does **not** update the
   cask. Upstream Homebrew remains a separate submission, if accepted later.
