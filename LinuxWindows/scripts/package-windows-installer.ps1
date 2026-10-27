# Builds the per-user Windows installer from the folder scripts/package.sh
# staged in dist/, with Inno Setup 6:
#   dist/LokalBot-<version>-windows-x86_64-setup.exe (+ .sha256)
# Run scripts/package.sh first. ISCC: the Inno Setup compiler to use (default:
# Inno Setup 6 under Program Files, for all users or this user).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$version = (Select-String -Path Cargo.toml -Pattern '^version = "(.*)"' | Select-Object -First 1).Matches[0].Groups[1].Value
$stage = Join-Path $root "dist\LokalBot-$version-windows-x86_64"
if (-not (Test-Path (Join-Path $stage 'lokalbot.exe'))) {
  throw "$stage has no lokalbot.exe; run scripts/package.sh first."
}

$iscc = $env:ISCC
if (-not $iscc) {
  $iscc = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) was not found; set ISCC.' }

$dist = Join-Path $root 'dist'
& $iscc /Q "/DAppVersion=$version" "/DSourceDir=$stage" "/DOutputDir=$dist" `
  "/DIconFile=$(Join-Path $root 'packaging\icons\lokalbot.ico')" `
  (Join-Path $root 'packaging\windows\lokalbot.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

$name = "LokalBot-$version-windows-x86_64-setup.exe"
$hash = (Get-FileHash (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLowerInvariant()
# Same format as sha256sum, so every .sha256 in a release reads alike.
[IO.File]::WriteAllText((Join-Path $dist "$name.sha256"), "$hash  $name`n")
Write-Output "dist/$name"
