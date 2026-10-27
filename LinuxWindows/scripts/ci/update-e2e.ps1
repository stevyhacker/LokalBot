# End-to-end update from a dry-run feed on this computer (Windows). Extracts
# the packaged archive into a scratch folder the way a user runs it, starts
# lokalbot-cli as an MCP server (an agent holds lokalbot-cli.exe open), serves
# an update over plain HTTP on 127.0.0.1 signed with a throwaway key, and has
# the extracted LokalBot check, download, verify, install and relaunch itself.
#
#   update-e2e.ps1 -Archive <zip> -Update <zip> -Tool <lokalbot-update-feed.exe> -Work <dir>
#
# The two archives may be the same file: the installed copy then pretends to
# be 0.0.1 (LOKALBOT_UPDATE_CURRENT_VERSION), which the relaunched copy does
# not inherit. Needs Python and a desktop session.
#
# On a computer where the installer never registered LokalBot, the folder
# also gets the installer's Installed apps entry at an older version, which
# must name the new version afterwards: winget reads it.
param(
    [Parameter(Mandatory)] [string] $Archive,
    [Parameter(Mandatory)] [string] $Update,
    [Parameter(Mandatory)] [string] $Tool,
    [Parameter(Mandatory)] [string] $Work
)
$ErrorActionPreference = "Stop"

function VersionOf([string] $Path) {
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    if ($name -notmatch '^LokalBot-(\d+\.\d+\.\d+)-windows-x86_64$') { throw "unexpected archive name $name" }
    $Matches[1]
}
$oldVersion = VersionOf $Archive
$newVersion = VersionOf $Update
$Archive = (Resolve-Path $Archive).Path
$Update = (Resolve-Path $Update).Path
$Tool = (Resolve-Path $Tool).Path

if (Test-Path $Work) { Remove-Item -Recurse -Force $Work }
New-Item -ItemType Directory -Force $Work, "$Work\serve", "$Work\library" | Out-Null
$Work = (Resolve-Path $Work).Path
Expand-Archive -Path $Archive -DestinationPath $Work
$app = Join-Path $Work "LokalBot-$oldVersion-windows-x86_64"
$exe = Join-Path $app "lokalbot.exe"
$cli = Join-Path $app "lokalbot-cli.exe"
$library = Join-Path $Work "library"
$log = Join-Path $library "logs\lokalbot.log"

# The update, signed with a key made for this run only.
Copy-Item $Update "$Work\serve\"
$key = Join-Path $Work "key"
$bytes = New-Object byte[] 32
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
[IO.File]::WriteAllText($key, [Convert]::ToBase64String($bytes))
$public = (& $Tool public-key --key-file $key).Trim()
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
& $Tool sign --archive (Join-Path "$Work\serve" (Split-Path $Update -Leaf)) --platform windows-x86_64 `
    --version $newVersion --tag "v$newVersion" --key-file $key `
    --download-base "http://127.0.0.1:$port" --notes-url "http://127.0.0.1:$port/notes" `
    --output "$Work\serve\windows-x86_64.json"
if ($LASTEXITCODE -ne 0) { throw "signing failed" }
$httpLog = Join-Path $Work "http"
$http = Start-Process -FilePath python -ArgumentList "-m", "http.server", "$port", "--bind", "127.0.0.1", "--directory", "$Work\serve" `
    -PassThru -NoNewWindow -RedirectStandardOutput "$httpLog.out" -RedirectStandardError "$httpLog.err"
# LokalBot reads the feed as soon as it starts; Python can take a while to listen.
$deadline = (Get-Date).AddSeconds(60)
while ($true) {
    try {
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 "http://127.0.0.1:$port/windows-x86_64.json" | Out-Null
        break
    } catch {
        if ($http.HasExited) { throw "the feed server exited: $(Get-Content "$httpLog.err" -Raw)" }
        if ((Get-Date) -gt $deadline) { throw "the feed server did not answer on port $port" }
        Start-Sleep -Milliseconds 500
    }
}

function WaitFor([string] $Pattern, [int] $Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while (-not ((Test-Path $log) -and (Select-String -Path $log -SimpleMatch -Pattern $Pattern -Quiet))) {
        if ((Get-Date) -gt $deadline) {
            if (Test-Path $log) { Get-Content $log -Tail 60 | Write-Host }
            throw "Timed out waiting for: $Pattern"
        }
        Start-Sleep -Seconds 1
    }
}

# lokalbot.iss's AppId. A real installation's entry is left alone.
$entryKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{CFF062EB-30DC-4ED9-8586-AB0B54B52A85}_is1"
$ownEntry = -not (Test-Path $entryKey)
if ($ownEntry) {
    New-Item -Path $entryKey -Force | Out-Null
    foreach ($value in @{ DisplayName = "LokalBot"; InstallLocation = "$app\"; "Inno Setup: App Path" = $app; DisplayVersion = "0.0.1" }.GetEnumerator()) {
        New-ItemProperty -Path $entryKey -Name $value.Key -Value $value.Value | Out-Null
    }
    foreach ($name in "MajorVersion", "VersionMajor", "MinorVersion", "VersionMinor") {
        New-ItemProperty -Path $entryKey -Name $name -PropertyType DWord -Value 0 | Out-Null
    }
} else {
    Write-Host "LokalBot's installer registered a copy on this computer; not checking Installed apps."
}

$env:LOKALBOT_STORAGE_ROOT = $library
try {
    # A library for the MCP server, then the server itself, which keeps
    # lokalbot-cli.exe running for the whole update.
    Start-Process -FilePath $exe -ArgumentList "--seed-demo" -Wait -NoNewWindow
    $settingsPath = Join-Path $library "settings.json"
    $settings = if (Test-Path $settingsPath) { Get-Content $settingsPath -Raw | ConvertFrom-Json } else { [pscustomobject]@{} }
    $settings | Add-Member -NotePropertyName onboardingCompleted -NotePropertyValue $true -Force
    $settings | Add-Member -NotePropertyName checkForUpdates -NotePropertyValue $true -Force
    $settings | ConvertTo-Json -Depth 20 | Set-Content -Encoding utf8 $settingsPath
    $mcpInfo = New-Object Diagnostics.ProcessStartInfo $cli, "mcp"
    $mcpInfo.UseShellExecute = $false
    $mcpInfo.RedirectStandardInput = $true
    $mcpInfo.RedirectStandardOutput = $true
    $mcpInfo.RedirectStandardError = $true
    $mcp = [Diagnostics.Process]::Start($mcpInfo)
    Start-Sleep -Seconds 2
    if ($mcp.HasExited) { throw "lokalbot-cli mcp exited: $($mcp.StandardError.ReadToEnd())" }

    # A file the update brings back: extracted folders get their notices refreshed.
    Set-Content -Path (Join-Path $app "THIRD_PARTY_NOTICES.md") -Value "edited by the test"
    # A license text the installed copy lacks, as when a release adds one.
    Remove-Item (Join-Path $app "LICENSES\MIT.txt")

    $env:LOKALBOT_UPDATE_FEED_URL = "http://127.0.0.1:$port/windows-x86_64.json"
    $env:LOKALBOT_UPDATE_PUBLIC_KEY = $public
    if ($oldVersion -eq $newVersion) { $env:LOKALBOT_UPDATE_CURRENT_VERSION = "0.0.1" }
    # `install-update` is the command form of Install and Relaunch.
    $first = Start-Process -FilePath $exe -ArgumentList "install-update" -PassThru
    WaitFor "updates: installed LokalBot $newVersion" 240
    WaitFor "LokalBot $newVersion started after an update" 120
    if (-not $first.WaitForExit(60000)) { throw "the old copy did not quit" }
    WaitFor "updates: up to date at $newVersion" 120

    $expected = Join-Path $Work "expected"
    Expand-Archive -Path $Update -DestinationPath $expected
    $expectedApp = Join-Path $expected "LokalBot-$newVersion-windows-x86_64"
    foreach ($file in "lokalbot.exe", "lokalbot-cli.exe", "THIRD_PARTY_NOTICES.md", "LICENSES\MIT.txt") {
        if ((Get-FileHash (Join-Path $app $file)).Hash -ne (Get-FileHash (Join-Path $expectedApp $file)).Hash) {
            throw "$file was not replaced"
        }
    }
    if ($ownEntry) {
        $entry = Get-ItemProperty $entryKey
        $parts = $newVersion.Split(".")
        if ($entry.DisplayVersion -ne $newVersion) {
            throw "Installed apps still lists $($entry.DisplayVersion), not $newVersion"
        }
        foreach ($name in "MajorVersion", "VersionMajor") {
            if ($entry.$name -ne [int]$parts[0]) { throw "$name is $($entry.$name), not $($parts[0])" }
        }
        foreach ($name in "MinorVersion", "VersionMinor") {
            if ($entry.$name -ne [int]$parts[1]) { throw "$name is $($entry.$name), not $($parts[1])" }
        }
        Write-Host "Installed apps lists LokalBot $newVersion."
    }
    # The running MCP server keeps the old CLI as lokalbot-cli.exe.old; the
    # old app's file is gone once that copy has exited.
    if ($mcp.HasExited) { throw "the MCP server stopped during the update" }
    if (-not (Test-Path "$cli.old")) { throw "the running CLI was not renamed aside" }
    $deadline = (Get-Date).AddSeconds(30)
    while (Test-Path "$exe.old") {
        if ((Get-Date) -gt $deadline) { throw "lokalbot.exe.old was not removed after the relaunch" }
        Start-Sleep -Seconds 1
    }
    # Once the agent lets go of the old CLI, the relaunched copy deletes it.
    $mcp.StandardInput.Close()
    if (-not $mcp.WaitForExit(10000)) { $mcp.Kill() }
    $deadline = (Get-Date).AddSeconds(90)
    while (Test-Path "$cli.old") {
        if ((Get-Date) -gt $deadline) { throw "lokalbot-cli.exe.old was not removed after the MCP server exited" }
        Start-Sleep -Seconds 2
    }
    $relaunched = Get-CimInstance Win32_Process -Filter "Name = 'lokalbot.exe'" |
        Where-Object { $_.CommandLine -like "*--after-update*" }
    if (-not $relaunched) { throw "the relaunched LokalBot is not running" }
    Select-String -Path $log -Pattern "updates:|after an update" | ForEach-Object { $_.Line } | Write-Host
    Write-Host "Updated $oldVersion -> $newVersion and relaunched; the running MCP server kept working."
} finally {
    Get-CimInstance Win32_Process -Filter "Name = 'lokalbot.exe' OR Name = 'lokalbot-cli.exe'" |
        Where-Object { $_.ExecutablePath -like "$Work*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $http.Id -Force -ErrorAction SilentlyContinue
    if ($ownEntry) { Remove-Item -Path $entryKey -Recurse -Force -ErrorAction SilentlyContinue }
}
