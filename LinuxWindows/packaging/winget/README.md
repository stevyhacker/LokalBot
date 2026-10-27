# LokalBot on winget

[winget](https://learn.microsoft.com/windows/package-manager/) manifests for the
per-user Windows installer, as package `stevyhacker.LokalBot`. Once
[microsoft/winget-pkgs](https://github.com/microsoft/winget-pkgs) has it,
`winget install LokalBot` works, and winget front ends such as UniGetUI and
winstall list it.

`manifests/` mirrors winget-pkgs' layout, so a version folder can be copied into
a fork unchanged:

```
manifests/s/stevyhacker/LokalBot/0.11.0/
  stevyhacker.LokalBot.yaml                  version
  stevyhacker.LokalBot.installer.yaml        installer
  stevyhacker.LokalBot.locale.en-US.yaml     default locale
```

The installer manifest has to agree with
[`../windows/lokalbot.iss`](../windows/lokalbot.iss): `InstallerType: inno`,
`Scope: user` (`PrivilegesRequired=lowest`), and `ProductCode`, which is the
`AppId` GUID plus Inno Setup's `_is1`. `AppsAndFeaturesEntries` repeats what the
installer writes to Installed apps (`UninstallDisplayName`, `AppPublisher`).
winget reads the installed version from that entry's `DisplayVersion`.
LokalBot's own updater writes the new version there after it updates itself,
and each start corrects an entry an older updater left behind
(`lokalbot_update::installed_apps`).

## Checks

```sh
winget validate --manifest LinuxWindows\packaging\winget\manifests\s\stevyhacker\LokalBot\0.11.0
```

On a pull request that changes these files, `.github/workflows/winget.yml` runs
`winget validate`, compares `InstallerSha256` with the release's `.sha256`
asset, installs LokalBot from the manifest silently, checks the files and the
Installed apps version, and uninstalls it silently, all on a GitHub-hosted
runner. Installing from a local manifest needs `winget settings --enable
LocalManifestFiles`, a machine-wide admin setting; that runner is thrown away
afterwards. winget also marks an installer from a local manifest as an
Internet download, so SmartScreen holds the unsigned installer at a prompt.
The check sets `SEE_MASK_NOZONECHECKS=1` for that step to skip that prompt.
Installs from winget-pkgs are marked trusted and don't get it.

## Releases

For each stable tag, the `winget` job in `release.yml` runs `wingetcreate
update` with the new installer's URL and opens the winget-pkgs pull request
(see [RELEASING.md](../../../RELEASING.md#winget)). It needs the `WINGET_TOKEN`
secret and a package that winget-pkgs already has. Without either, it says so
and succeeds. From then on winget-pkgs holds the current manifests; the files
here only change when the installer does (its scope, `AppId` or switches).

## One-time setup (owner)

1. **Fork** microsoft/winget-pkgs to the account that will submit:
   `gh repo fork microsoft/winget-pkgs --clone=false`.
2. **Create a classic personal access token** with only the `public_repo`
   scope, at <https://github.com/settings/tokens/new?scopes=public_repo&description=LokalBot%20winget>.
   wingetcreate does not support fine-grained tokens. Give it an expiry and
   put a reminder in the calendar.
3. **Add it as a repository secret**:
   `gh secret set WINGET_TOKEN --repo stevyhacker/LokalBot` (paste the token
   when asked). Only `winget.yml`'s submit job reads it, on a GitHub-hosted
   runner.
4. **Submit the first version** (0.11.0), one of:
   - On Windows, with [wingetcreate](https://github.com/microsoft/winget-create):
     ```powershell
     wingetcreate token --store   # signs in to GitHub, or set WINGET_CREATE_GITHUB_TOKEN
     wingetcreate submit --prtitle "New package: stevyhacker.LokalBot version 0.11.0" LinuxWindows\packaging\winget\manifests\s\stevyhacker\LokalBot\0.11.0
     ```
   - From any computer, with git: clone your fork, copy
     `manifests/s/stevyhacker/LokalBot/0.11.0` to the same path in it, commit
     on a new branch, push, and open the pull request against
     `microsoft/winget-pkgs` `master`, completing its checklist.
5. **Wait for the merge.** winget-pkgs' bots validate the pull request and
   install LokalBot in a sandbox, then a moderator merges it; that usually
   takes a day or two. Answer any `Needs-Author-Feedback` label there. After
   the merge, `winget install LokalBot` and `winget upgrade LokalBot` work,
   and every later stable release is submitted by the release job.

Leave `winget install LokalBot` out of the README and the website until step 5
is done.
