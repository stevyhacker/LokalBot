<#
Sets up a self-hosted GitHub Actions runner for the "Linux & Windows" workflow
on a Windows 11 PC. Run it elevated (Windows PowerShell 5.1 is fine), with a
runner registration token on stdin:

  gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token |
    ssh PC 'powershell -NoProfile -ExecutionPolicy Bypass -File setup-windows-runner.ps1 -Url https://github.com/OWNER/REPO'

Needs Visual Studio Build Tools with the C++ workload, Git for Windows,
7-Zip and CMake. Installs PowerShell 7 machine-wide if it is missing, and a
Rust toolchain under -Root, apart from any user's own.

The runner is a service running as NETWORK SERVICE, with -Root locked to
SYSTEM, Administrators and that account, and an outbound firewall rule that
keeps the service (and the build tools it starts) off the Tailscale network.
Jobs only build and test; the workflow runs its desktop checks on GitHub's
runners. See README.md.
#>
param(
  [Parameter(Mandatory = $true)][string]$Url,
  [string]$Name = 'lokalbot-windows',
  [string]$Root = 'C:\gh'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Label = 'lokalbot-windows'
$RunnerVersion = '2.338.0'
$RunnerSha256 = 'f48e0750a21812bca5f82de5f7f5aeae71abee647fab5a582f1742d07eba455f'
$Toolchain = '1.99.1'
$PwshVersion = '7.6.7'
$PwshSha256 = 'ec575cef9ec56fcd905de0d5eeac9cb7f81a0a65abb87bb5cd0e87fdfe2b8cc0'
$TailnetRule = 'GitHub Actions runner: no Tailscale network'

$token = [Console]::In.ReadLine()
if (-not $token) { throw 'Pass a runner registration token on stdin.' }

function Save-Verified([string]$Uri, [string]$Path, [string]$Sha256) {
  Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Path
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
  if ($actual -ne $Sha256.ToLowerInvariant()) {
    Remove-Item -LiteralPath $Path
    throw "Checksum mismatch for $Uri"
  }
}

function Invoke-Checked([string]$File, [string[]]$Arguments) {
  & $File @Arguments
  if ($LASTEXITCODE) { throw "$File exited with $LASTEXITCODE" }
}

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere) -or
    -not (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)) {
  throw 'Install Visual Studio Build Tools with the "Desktop development with C++" workload first.'
}
foreach ($tool in 'C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\7-Zip\7z.exe', 'C:\Program Files\CMake\bin\cmake.exe') {
  if (-not (Test-Path $tool)) { throw "Missing $tool" }
}

$runnerDir = Join-Path $Root 'runner'
if (Test-Path (Join-Path $runnerDir '.runner')) {
  throw "A runner is already configured in $runnerDir; remove it first (README.md)."
}

Write-Host '== folders'
New-Item -ItemType Directory -Force $Root | Out-Null
# SYSTEM, Administrators and NETWORK SERVICE only (by SID: account names are
# localized), so the runner and its toolchain can't be changed from an
# ordinary user session.
Invoke-Checked icacls.exe @($Root, '/inheritance:r', '/grant:r',
  '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-20:(OI)(CI)M', '/T', '/Q')
foreach ($dir in 'runner', 'w', 't', 'cargo', 'rustup', 'downloads') {
  New-Item -ItemType Directory -Force (Join-Path $Root $dir) | Out-Null
}
$downloads = Join-Path $Root 'downloads'

if (-not (Test-Path 'C:\Program Files\PowerShell\7\pwsh.exe')) {
  Write-Host "== PowerShell $PwshVersion (machine-wide; a Store install is per user)"
  $msi = Join-Path $downloads "PowerShell-$PwshVersion-win-x64.msi"
  Save-Verified "https://github.com/PowerShell/PowerShell/releases/download/v$PwshVersion/PowerShell-$PwshVersion-win-x64.msi" $msi $PwshSha256
  $install = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @(
    '/i', "`"$msi`"", '/quiet', '/norestart', 'ADD_PATH=0', 'USE_MU=0', 'ENABLE_MU=0',
    'ENABLE_PSREMOTING=0', 'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0', 'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=0')
  if ($install.ExitCode -ne 0) { throw "PowerShell MSI exited with $($install.ExitCode)" }
}

Write-Host "== Rust $Toolchain"
$env:RUSTUP_HOME = Join-Path $Root 'rustup'
$env:CARGO_HOME = Join-Path $Root 'cargo'
$rustupBase = 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe'
$rustupSha = Invoke-WebRequest -UseBasicParsing "$rustupBase.sha256"
$rustupSha = if ($rustupSha.Content -is [byte[]]) { [Text.Encoding]::ASCII.GetString($rustupSha.Content) } else { $rustupSha.Content }
$init = Join-Path $downloads 'rustup-init.exe'
Save-Verified $rustupBase $init ($rustupSha.Trim().Split(' ')[0])
Invoke-Checked $init @('-y', '--profile', 'minimal', '--default-toolchain', $Toolchain, '--no-modify-path', '-c', 'rustfmt', '-c', 'clippy')

Write-Host "== runner $RunnerVersion"
$zip = Join-Path $downloads "actions-runner-win-x64-$RunnerVersion.zip"
Save-Verified "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip" $zip $RunnerSha256
Expand-Archive -Force -Path $zip -DestinationPath $runnerDir

Push-Location $runnerDir
try {
  # Read by config.cmd instead of --token, so the token never shows up in a
  # process list. The service runs as NETWORK SERVICE by default.
  $env:ACTIONS_RUNNER_INPUT_TOKEN = $token
  Invoke-Checked .\config.cmd @('--unattended', '--url', $Url, '--name', $Name, '--labels', $Label,
    '--work', (Join-Path $Root 'w'), '--runasservice', '--replace')
} finally {
  Remove-Item Env:ACTIONS_RUNNER_INPUT_TOKEN -ErrorAction SilentlyContinue
  Pop-Location
}
$service = Get-Service "actions.runner.*.$Name"

Write-Host '== job environment'
# Jobs keep a warm target directory instead of restoring a cache. The Windows
# runner reads .env (not .path, which only the Linux service script reads),
# so PATH goes there. Git's bin comes before System32 so `bash` is Git Bash
# rather than WSL; Git's usr\bin stays off PATH because its link.exe would
# shadow the MSVC linker.
$rootSlash = $Root.Replace('\', '/')
$jobPath = @(
  "$Root\cargo\bin",
  'C:\Program Files\PowerShell\7',
  'C:\Program Files\Git\bin',
  'C:\Program Files\Git\cmd',
  'C:\Program Files\7-Zip',
  'C:\Program Files\CMake\bin',
  "$env:SystemRoot\System32",
  $env:SystemRoot,
  "$env:SystemRoot\System32\Wbem",
  "$env:SystemRoot\System32\WindowsPowerShell\v1.0",
  "$env:SystemRoot\System32\OpenSSH") -join ';'
$jobEnv = @(
  "CARGO_HOME=$Root\cargo",
  "RUSTUP_HOME=$Root\rustup",
  "CARGO_TARGET_DIR=$rootSlash/t",
  "PATH=$jobPath")
Set-Content -LiteralPath (Join-Path $runnerDir '.env') -Value $jobEnv -Encoding ascii

Write-Host '== Tailscale block'
# With an unrestricted service SID in the service's token (inherited by the
# processes it starts), a firewall rule can match the runner alone. Matching
# NETWORK SERVICE instead would also cut off Windows' own DNS client.
Invoke-Checked sc.exe @('sidtype', $service.Name, 'unrestricted')
Get-NetFirewallRule -DisplayName $TailnetRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $TailnetRule -Direction Outbound -Action Block -Profile Any `
  -Service $service.Name -RemoteAddress '100.64.0.0/10', 'fd7a:115c:a1e0::/48' | Out-Null

Restart-Service $service.Name
(Get-Service $service.Name).Status
Write-Host "Runner $Name ($Label) is installed as $($service.Name)."
