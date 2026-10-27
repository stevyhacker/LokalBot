# Puts a job's sources into the workspace of a self-hosted Windows runner
# (setup-windows-runner.ps1), which keeps its workspace and a warm target
# directory between jobs.
#
# cargo rebuilds a crate when one of its files is newer than its last build.
# Extracted from the source archive, every file has the commit's time, so a
# job rebuilt every workspace crate, and a job for a commit older than the
# last build reused that build for sources it never compiled. Here a file
# gets the current time only when its content differs from the file the last
# job left, and everything not in the archive is removed.
param(
  [Parameter(Mandatory)] [string] $From,
  [Parameter(Mandatory)] [string] $To
)
$ErrorActionPreference = 'Stop'

# Written after a complete sync. Without it (the first job, an interrupted
# sync, or a job that cleared the workspace) no file's time can be trusted.
$marker = Join-Path $To '.sources-synced'
$trusted = Test-Path -LiteralPath $marker
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue

$from = (Resolve-Path -LiteralPath $From).Path
$to = (New-Item -ItemType Directory -Force $To).FullName
$sources = Get-ChildItem -LiteralPath $from -Recurse -File -Force
$wanted = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in $sources) { [void]$wanted.Add([IO.Path]::GetRelativePath($from, $file.FullName)) }

# Remove first, so a file that became a folder (or the reverse) can be written.
$removed = 0
foreach ($file in Get-ChildItem -LiteralPath $to -Recurse -File -Force) {
  if (-not $wanted.Contains([IO.Path]::GetRelativePath($to, $file.FullName))) {
    Remove-Item -LiteralPath $file.FullName -Force
    $removed++
  }
}
Get-ChildItem -LiteralPath $to -Recurse -Directory -Force |
  Sort-Object { $_.FullName.Length } -Descending |
  Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force) } |
  Remove-Item -Force

$now = Get-Date
$changed = 0
foreach ($file in $sources) {
  $dest = Join-Path $to ([IO.Path]::GetRelativePath($from, $file.FullName))
  $old = Get-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
  if ($trusted -and $old -and $old.Length -eq $file.Length -and
      (Get-FileHash -LiteralPath $dest).Hash -eq (Get-FileHash -LiteralPath $file.FullName).Hash) {
    continue
  }
  New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
  Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
  (Get-Item -LiteralPath $dest -Force).LastWriteTime = $now
  $changed++
}

Set-Content -LiteralPath $marker -Value $now.ToString('o')
$note = if ($trusted) { '' } else { ' (no complete sync before, so every file counts as changed)' }
Write-Host "$changed of $($sources.Count) files changed, $removed removed$note."
