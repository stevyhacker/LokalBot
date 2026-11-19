# Windows code signing (SignPath Foundation)

Part of the [release runbook](../../RELEASING.md) and [Linux and Windows](linux-and-windows.md).

LokalBot uses [SignPath.io](https://signpath.io) with a free open-source certificate issued by the [SignPath Foundation](https://signpath.org) to Authenticode-sign Windows release executables (`lokalbot.exe`, `lokalbot-cli.exe`) and the Inno Setup installer (`LokalBot-<version>-windows-x86_64-setup.exe`).

## Architecture

1. **`linux-windows-release.yml` stays secret-free.** It compiles `lokalbot.exe` and `lokalbot-cli.exe` on a clean GitHub-hosted `windows-2025` runner with embedded Windows `VERSIONINFO` resources (`ProductName = LokalBot`, matching `ProductVersion` from `LinuxWindows/Cargo.toml`).
2. **`windows-sign.yml` runs on stable tags once `SIGNPATH_ENABLED=true`.** After macOS release gates pass, it:
   - submits `lokalbot.exe` and `lokalbot-cli.exe` to SignPath (`artifact-configuration-slug: windows-binaries`) — upstream `vc-runtime/*.dll` files are left unsigned per SignPath Foundation policy;
   - verifies `Get-AuthenticodeSignature` is `Valid` on both executables and repacks `LokalBot-<version>-windows-x86_64.zip` so portable installs, Scoop installs, and in-place auto-updates receive signed binaries;
   - rebuilds `LokalBot-<version>-windows-x86_64-setup.exe` from the signed binaries and submits it to SignPath (`artifact-configuration-slug: windows-installer`);
   - verifies `Get-AuthenticodeSignature` on `setup.exe` and runs `LinuxWindows/scripts/ci/check-windows-installer.ps1`.
3. **`linux-windows-publish` runs last.** It signs `windows-x86_64.json` over the **signed** zip's bytes with `SPARKLE_PRIVATE_KEY` and uploads the signed zip and installer to the GitHub release.

## One-time setup (after SignPath Foundation approval)

1. **Create the SignPath project** with slug `lokalbot` connected to `stevyhacker/LokalBot` via the GitHub Actions origin verifier.
2. **Upload the two artifact configurations** from `LinuxWindows/packaging/windows/signpath/`:
   - `windows-binaries.xml` → slug `windows-binaries`
   - `windows-installer.xml` → slug `windows-installer`
   Enforce SignPath's file metadata restrictions (`ProductName = LokalBot`) on both configurations.
3. **Create signing policy `release-signing`** linked to the SignPath Foundation certificate, requiring manual approval by project Approvers.
4. **Add GitHub repository secrets and variable:**
   ```sh
   gh secret set SIGNPATH_ORG_ID --repo stevyhacker/LokalBot
   gh secret set SIGNPATH_API_TOKEN --repo stevyhacker/LokalBot
   gh variable set SIGNPATH_ENABLED --body true --repo stevyhacker/LokalBot
   ```
5. **Publish the required Code Signing Policy** on `README.md`, `lokalbot.com`, and release pages (only after approval):
   > **Code signing policy:** Free code signing provided by [SignPath.io](https://signpath.io), certificate by [SignPath Foundation](https://signpath.org).
   >
   > - **Committers and reviewers:** repository maintainers of `stevyhacker/LokalBot`
   > - **Approvers:** repository owner (`@stevyhacker`)
   > - **Privacy policy:** [lokalbot.com/privacy](https://www.lokalbot.com/privacy) — LokalBot processes recordings, transcripts, summaries, and screen memory locally on your computer and does not transfer user data to any LokalBot server.

## Verification after a signed release

On Windows:

```powershell
Get-AuthenticodeSignature .\LokalBot-<version>-windows-x86_64-setup.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`Status` must be `Valid`, with `SignPath Foundation` in `SignerCertificate.Subject` and a valid RFC 3161 `TimeStamperCertificate`.
