# Windows code signing (SignPath Foundation)

Part of the [release runbook](../../RELEASING.md) and [Linux and Windows](linux-and-windows.md).

LokalBot uses [SignPath.io](https://signpath.io) with a free open-source certificate issued by the [SignPath Foundation](https://signpath.org) to Authenticode-sign Windows release executables (`lokalbot.exe`, `lokalbot-cli.exe`) and the Inno Setup installer (`LokalBot-<version>-windows-x86_64-setup.exe`).

## Architecture

1. **`linux-windows-release.yml` stays secret-free.** It compiles `lokalbot.exe` and `lokalbot-cli.exe` on a clean GitHub-hosted `windows-2025` runner with embedded Windows `VERSIONINFO` resources (`ProductName = LokalBot`, matching `ProductVersion` from `LinuxWindows/Cargo.toml`).
2. **`windows-sign.yml` signs ONLY LokalBot's own binaries.** On stable tags (when `SIGNPATH_ENABLED=true`) or manual `workflow_dispatch` test runs, it:
   - submits `lokalbot.exe` and `lokalbot-cli.exe` inside a GitHub Actions artifact zip to SignPath (`artifact-configuration-slug: windows-binaries`) — upstream `vc-runtime/*.dll` files are left unsigned per SignPath Foundation policy;
   - verifies `Get-AuthenticodeSignature` on both executables and repacks `LokalBot-<version>-windows-x86_64.zip` so portable installs, Scoop installs, and in-place auto-updates receive signed binaries;
   - rebuilds `LokalBot-<version>-windows-x86_64-setup.exe` from the signed binaries and submits it to SignPath (`artifact-configuration-slug: windows-installer`);
   - verifies `Get-AuthenticodeSignature` on `setup.exe` and runs `LinuxWindows/scripts/ci/check-windows-installer.ps1`.
3. **`linux-windows-publish` runs last.** It signs `windows-x86_64.json` over the **signed** zip's bytes with `SPARKLE_PRIVATE_KEY` and uploads the signed zip and installer to the GitHub release.

## One-time setup (SignPath Foundation onboarding)

1. **Accept the SignPath emails in order:**
   - Create your SignPath account first (with 2FA enabled) and accept the **OSS organization invitation**.
   - **Only after** accepting the invitation, confirm the **CI user email address** (SignPath cannot complete CI user confirmation beforehand).
2. **Connect GitHub Actions as a Trusted Build System:**
   - In SignPath, configure the GitHub.com Trusted Build System for `stevyhacker/LokalBot` (install the SignPath GitHub App if prompted): https://about.signpath.io/documentation/trusted-build-systems/github
3. **Create the SignPath project** with slug `lokalbot` bound to repository `stevyhacker/LokalBot`.
4. **Upload the two artifact configurations** from `LinuxWindows/packaging/windows/signpath/`:
   - `windows-binaries.xml` → slug `windows-binaries` (signs `lokalbot.exe` and `lokalbot-cli.exe` with `product-name="LokalBot"`)
   - `windows-installer.xml` → slug `windows-installer` (signs `LokalBot-*-windows-x86_64-setup.exe` with `product-name="LokalBot"`)
5. **Create two signing policies under project `lokalbot`:**
   - `test-signing` → linked to SignPath's provided **self-signed test certificate**, bound to GitHub Actions origin `stevyhacker/LokalBot`.
   - `release-signing` → linked to the **SignPath Foundation production certificate** once imported, requiring manual approval by project Approvers (`@stevyhacker`).
6. **Add GitHub repository secrets** (do NOT set `SIGNPATH_ENABLED=true` until the production certificate is imported):
   ```sh
   gh secret set SIGNPATH_ORG_ID --repo stevyhacker/LokalBot
   gh secret set SIGNPATH_API_TOKEN --repo stevyhacker/LokalBot
   ```
   - `SIGNPATH_ORG_ID`: Organization ID UUID from SignPath.
   - `SIGNPATH_API_TOKEN`: API token generated for the SignPath CI user.
7. **Run an end-to-end test-signing verification** (uses the self-signed test certificate without cutting a release tag):
   ```sh
   gh workflow run windows-sign.yml --repo stevyhacker/LokalBot -f signing_policy_slug=test-signing
   ```
   When it finishes green, confirm both signing requests appear in SignPath under `lokalbot` and download `release-windows-x86_64-signed` to inspect the test signatures.
8. **Request production certificate review:** reply to SignPath Foundation (`oss-support@signpath.org`) once the test-signing run succeeds so they can review the setup, order the production certificate, and import it into your organization.
9. **Enable production signing on releases:** once SignPath imports the production certificate and you bind it to `release-signing`, enable signing in `release.yml`:
   ```sh
   gh variable set SIGNPATH_ENABLED --body true --repo stevyhacker/LokalBot
   ```

## Verification after a signed release

On Windows:

```powershell
Get-AuthenticodeSignature .\LokalBot-<version>-windows-x86_64-setup.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`Status` must be `Valid`, with `SignPath Foundation` in `SignerCertificate.Subject` and a valid RFC 3161 `TimeStamperCertificate`.
