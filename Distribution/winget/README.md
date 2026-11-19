# Winget distribution for LokalBot

Multi-file Windows Package Manager (`winget`, schema `1.6.0`) manifests for
`LokalBot.LokalBot` (`winget install LokalBot.LokalBot`), matching the per-user
Inno Setup installer built from
[`LinuxWindows/packaging/windows/lokalbot.iss`](../../LinuxWindows/packaging/windows/lokalbot.iss).

## Validate on Windows

```powershell
winget validate --manifest Distribution\winget
winget install --manifest Distribution\winget
```

## Submit to `microsoft/winget-pkgs`

1. Fork `microsoft/winget-pkgs` (or install `wingetcreate`).
2. Place the three YAML files at:
   `manifests/l/LokalBot/LokalBot/<version>/`
3. Run `winget validate` and open a PR against `microsoft/winget-pkgs` (or run
   `wingetcreate submit Distribution\winget`).
4. For future releases, `wingetcreate update LokalBot.LokalBot --version <version> --urls <setup-exe-url>`
   (or a release workflow using `vedantmgoyal9/winget-releaser`) automates updates.

## Note on Windows code signing

Until the Windows installer is code-signed (for example via SignPath.io for open
source or Azure Trusted Signing), Windows SmartScreen warns on first launch, and
`winget-pkgs` reviewers may note unsigned binaries. Signing `LokalBot-<version>-windows-x86_64-setup.exe`
before or alongside Winget submission removes both SmartScreen friction and review delays.
