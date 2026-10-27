# Installs the built Windows installer silently for the current user, checks
# what it put in place, then uninstalls it and checks it cleaned up.
#   pwsh scripts/ci/check-windows-installer.ps1 dist\LokalBot-<version>-windows-x86_64-setup.exe
param([Parameter(Mandatory = $true)][string]$Setup)
$ErrorActionPreference = 'Stop'

$app = Join-Path $env:LOCALAPPDATA 'Programs\LokalBot'
$shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\LokalBot.lnk'
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$log = Join-Path $tmp 'lokalbot-setup.log'

$p = Start-Process (Resolve-Path $Setup).Path -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=$log" -Wait -PassThru
if ($p.ExitCode -ne 0) { Get-Content $log -ErrorAction SilentlyContinue; throw "setup exited with $($p.ExitCode)" }

foreach ($file in 'lokalbot.exe', 'lokalbot-cli.exe', 'LICENSE.txt', 'THIRD_PARTY_NOTICES.md', 'LICENSES\rust-crates.md', 'LICENSES\Apache-2.0.txt', 'vc-runtime\msvcp140.dll', 'vc-runtime\vcruntime140.dll', 'vc-runtime\vcruntime140_1.dll') {
  if (-not (Test-Path (Join-Path $app $file))) { throw "the installer did not install $file" }
}
if (-not (Test-Path $shortcut)) { throw 'no Start menu shortcut' }
$folder = (New-Object -ComObject Shell.Application).NameSpace((Split-Path $shortcut))
$appId = $folder.ParseName('LokalBot.lnk').ExtendedProperty('System.AppUserModel.ID')
if ($appId -ne 'com.lokalbot.LokalBot') { throw "the shortcut's app id is '$appId'" }

$entry = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' |
  ForEach-Object { Get-ItemProperty $_.PSPath } |
  Where-Object { $_.DisplayName -eq 'LokalBot' } | Select-Object -First 1
if (-not $entry) { throw 'no Installed apps entry' }
Write-Output "Installed LokalBot $($entry.DisplayVersion) in $app"

& (Join-Path $app 'lokalbot-cli.exe') --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "lokalbot-cli --help exited with $LASTEXITCODE" }

# An in-place update can add license texts the installer didn't install.
Set-Content -Path (Join-Path $app 'LICENSES\added-by-update.txt') -Value 'added'
Set-Content -Path (Join-Path $app 'vc-runtime\added-by-update.dll') -Value 'added'

$uninstaller = $entry.UninstallString.Trim('"')
Start-Process $uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait | Out-Null
# The uninstaller finishes from a copy of itself in TEMP; wait for it.
$deadline = (Get-Date).AddSeconds(60)
$left = { (Test-Path (Join-Path $app 'lokalbot.exe')) -or (Test-Path (Join-Path $app 'LICENSES')) -or (Test-Path (Join-Path $app 'vc-runtime')) }
while ((& $left) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
if (Test-Path (Join-Path $app 'lokalbot.exe')) { throw 'uninstalling left lokalbot.exe behind' }
if (Test-Path $shortcut) { throw 'uninstalling left the Start menu shortcut behind' }
if (Test-Path (Join-Path $app 'LICENSES')) { throw 'uninstalling left the LICENSES folder behind' }
if (Test-Path (Join-Path $app 'vc-runtime')) { throw 'uninstalling left the vc-runtime folder behind' }
Write-Output 'Install and uninstall checks passed'
