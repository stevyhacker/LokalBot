# Windows version of run-pi-runtime-tests.sh. The runtime's node_modules is
# reached through a junction, which is unlinked before the folder is removed.
param([Parameter(Mandatory = $true)][string]$RuntimeRoot)
$ErrorActionPreference = "Stop"
$resources = Split-Path -Parent $PSScriptRoot
$runtime = (Resolve-Path $RuntimeRoot).Path
$root = Join-Path $env:TEMP ("lokalbot-pi-tests-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force (Join-Path $root "resources\tests") | Out-Null
try {
  Copy-Item -Recurse (Join-Path $resources "lokalbot-extension") (Join-Path $root "resources")
  Copy-Item -Recurse (Join-Path $resources "lokalbot-cli-skill") (Join-Path $root "resources")
  Copy-Item (Join-Path $resources "system-prompt.md") (Join-Path $root "resources")
  Copy-Item (Join-Path $resources "tests\pi-runtime.test.ts") (Join-Path $root "resources\tests")
  New-Item -ItemType Junction -Path (Join-Path $root "node_modules") -Target (Join-Path $runtime "pi\node_modules") | Out-Null
  $env:LOKALBOT_PINNED_RUNTIME_ROOT = $runtime
  # No transpiler caches: Bun and jiti would keep them in .bun and %TEMP%.
  $env:BUN_RUNTIME_TRANSPILER_CACHE_PATH = "0"
  $env:JITI_FS_CACHE = "false"
  & (Join-Path $runtime "bun\bun.exe") test (Join-Path $root "resources\tests\pi-runtime.test.ts")
  $code = $LASTEXITCODE
} finally {
  $link = Get-Item (Join-Path $root "node_modules") -ErrorAction SilentlyContinue
  if ($link) { $link.Delete() }
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
}
exit $code
