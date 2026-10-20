# First step of a job on a self-hosted Windows runner (setup-windows-runner.ps1):
# - fails if the runner can reach the Tailscale network, which its firewall
#   rule is meant to block;
# - lowers the job's CPU priority, so builds don't take the PC from whoever
#   is using it, and keeps the job on the CPU's performance cores (later
#   steps inherit both from the runner's worker process);
# - clears the warm target directory when the disk gets too full.
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
