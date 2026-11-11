# First step of a job on a self-hosted Windows runner (setup-windows-runner.ps1):
# - fails if the runner can reach the Tailscale network, which its firewall
#   rule is meant to block;
# - lowers the job's CPU priority, so builds don't take the PC from whoever
#   is using it, and keeps the job on the CPU's performance cores (later
#   steps inherit both from the runner's worker process);
# - clears the warm target directory when the disk gets too full;
# - removes programs another branch's build may have left in it (below).
$ErrorActionPreference = 'Stop'

$client = New-Object Net.Sockets.TcpClient
try {
  $reached = $false
  try { $reached = $client.ConnectAsync('100.100.100.100', 53).Wait(3000) } catch [AggregateException] { }
  if ($reached) {
    throw 'This runner can reach the Tailscale network. Check the firewall rule from setup-windows-runner.ps1.'
  }
} finally {
  $client.Dispose()
}

$worker = Get-Process -Id (Get-CimInstance Win32_Process -Filter "ProcessId = $PID").ParentProcessId
$worker.PriorityClass = 'BelowNormal'
Write-Host "Steps now run at below-normal priority (worker $($worker.Id))."

# On a hybrid CPU, Windows moves long-running work of a process without a
# foreground window to the efficient cores within seconds, whatever its
# priority: every rustc of a job ran on the PC's 4 E-cores while its 6
# P-cores idled. An affinity mask, which the processes the worker starts
# inherit, keeps steps on the most performant cores.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CpuSets {
  [DllImport("kernel32.dll", SetLastError = true)]
  static extern bool GetSystemCpuSetInformation(IntPtr info, uint length, out uint returned, IntPtr process, uint flags);
  // Group 0's logical processors in the highest efficiency class, or 0.
  public static long MostPerformant() {
    uint size;
    GetSystemCpuSetInformation(IntPtr.Zero, 0, out size, IntPtr.Zero, 0);
    IntPtr info = Marshal.AllocHGlobal((int)size);
    try {
      if (!GetSystemCpuSetInformation(info, size, out size, IntPtr.Zero, 0)) return 0;
      long mask = 0; int best = -1;
      for (int at = 0; at < size; at += Marshal.ReadInt32(info, at)) {
        // SYSTEM_CPU_SET_INFORMATION: Group at 12, LogicalProcessorIndex at 14, EfficiencyClass at 18.
        if (Marshal.ReadInt16(info, at + 12) != 0) continue;
        int cls = Marshal.ReadByte(info, at + 18), cpu = Marshal.ReadByte(info, at + 14);
        if (cpu > 63) continue;
        if (cls > best) { best = cls; mask = 0; }
        if (cls == best) mask |= 1L << cpu;
      }
      return mask;
    } finally { Marshal.FreeHGlobal(info); }
  }
}
'@
$mask = [CpuSets]::MostPerformant()
if ($mask -and $mask -ne [long]$worker.ProcessorAffinity) {
  $worker.ProcessorAffinity = [IntPtr]$mask
  Write-Host ("Steps now run on the most performant cores (mask 0x{0:X})." -f $mask)
}

$target = $env:CARGO_TARGET_DIR
if (-not $target) { throw 'The runner sets CARGO_TARGET_DIR in its .env.' }
New-Item -ItemType Directory -Force $target | Out-Null
$drive = Get-PSDrive ((Resolve-Path $target).Drive.Name)
$freeGb = [int]($drive.Free / 1GB)
Write-Host "Warm target in $target; $freeGb GB free on $($drive.Name):."
$minFree = if ($env:MIN_FREE_GB) { [int]$env:MIN_FREE_GB } else { 40 }
if ($freeGb -lt $minFree) {
  Write-Host 'Clearing the warm target to free space.'
  Get-ChildItem -Force $target | Remove-Item -Recurse -Force
}

# On Windows (MSVC) cargo leaves the hash out of the file names of programs
# (binaries and examples): every branch's lokalbot-cli is deps\lokalbot_cli.exe,
# while libraries and test programs get one file per build. When a job's own
# build of a program is still up to date in cargo's records, from an earlier
# job, cargo doesn't link it again, and the job tests and packages the file the
# last branch left: a 0.12.2 run tested a 0.12.3 lokalbot-cli that way.
# Those records change with package versions, dependencies, features and the
# toolchain, which all come from the manifests. So when the manifests differ
# from the last job's, remove the unhashed programs and cargo builds each again.
# Otherwise they stay warm. (On Linux, programs have hashed names too, and cargo
# refreshes the copy tests run, so check-runner.sh needs none of this.)
$manifests = Get-ChildItem -Recurse -File -Force -Include 'Cargo.toml', 'Cargo.lock', 'rust-toolchain', 'rust-toolchain.toml', 'config', 'config.toml' |
  Where-Object { $_.Name -like 'Cargo.*' -or $_.Name -like 'rust-toolchain*' -or $_.Directory.Name -eq '.cargo' } |
  Where-Object { $_.FullName -notmatch '[\\/](target|node_modules)[\\/]' } |
  ForEach-Object { '{0} {1}' -f [IO.Path]::GetRelativePath($PWD.Path, $_.FullName), (Get-FileHash -LiteralPath $_.FullName).Hash } |
  Sort-Object
$stamp = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($manifests -join "`n")))
$stampFile = Join-Path $target 'manifests.sha256'
$last = if (Test-Path -LiteralPath $stampFile) { (Get-Content -LiteralPath $stampFile -Raw).Trim() } else { '' }
if ($stamp -ne $last) {
  $removed = 0
  foreach ($profileDir in 'debug', 'release') {
    foreach ($sub in '.', 'deps', 'examples') {
      $dir = Join-Path (Join-Path $target $profileDir) $sub
      if (-not (Test-Path -LiteralPath $dir)) { continue }
      Get-ChildItem -LiteralPath $dir -File -Force |
        Where-Object { $_.Extension -in '.exe', '.pdb' -and $_.BaseName -notmatch '-[0-9a-f]{16}$' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; $removed++ }
    }
  }
  Set-Content -LiteralPath $stampFile -Value $stamp
  Write-Host "The manifests changed since the last job: removed $removed programs with unhashed names, so cargo links them again."
}
