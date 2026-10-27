# Captures the LokalBot window on a Windows desktop session, one PNG per page.
# Usage: capture-windows.ps1 -Exe <lokalbot.exe> -Root <library> -OutDir <dir> [-Pages today,meetings] [-Theme light|dark]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Root,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string[]]$Pages = @("today"),
  [string]$Suffix = "",
  [int]$WaitSeconds = 6
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LbWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT r, int size);
}
"@
[LbWin]::SetProcessDPIAware() | Out-Null
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
foreach ($page in $Pages) {
  $env:LOKALBOT_STORAGE_ROOT = $Root
  $p = Start-Process -FilePath $Exe -ArgumentList @("--page", $page) -PassThru
  $deadline = (Get-Date).AddSeconds(40)
  while ((Get-Date) -lt $deadline) { $p.Refresh(); if ($p.HasExited -or $p.MainWindowHandle -ne 0) { break }; Start-Sleep -Milliseconds 250 }
  if ($p.HasExited) { throw "LokalBot exited with code $($p.ExitCode) before showing a window" }
  if ($p.MainWindowHandle -eq 0) { throw "LokalBot did not open a window" }
  Start-Sleep -Seconds $WaitSeconds
  $h = $p.MainWindowHandle
  [LbWin]::SetForegroundWindow($h) | Out-Null
  # Park the pointer in a corner so no hover state shows.
  [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width - 2), ([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height - 2))
  Start-Sleep -Milliseconds 600
  $frame = New-Object LbWin+RECT
  [LbWin]::DwmGetWindowAttribute($h, 9, [ref]$frame, 16) | Out-Null
  $outer = New-Object LbWin+RECT
  [LbWin]::GetWindowRect($h, [ref]$outer) | Out-Null
  $w = $outer.Right - $outer.Left; $hgt = $outer.Bottom - $outer.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $hgt
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [LbWin]::PrintWindow($h, $hdc, 2) | Out-Null
  $g.ReleaseHdc($hdc); $g.Dispose()
  $cx = $frame.Left - $outer.Left; $cy = $frame.Top - $outer.Top
  $cw = $frame.Right - $frame.Left; $ch = $frame.Bottom - $frame.Top
  if ($cw -gt 0 -and $ch -gt 0 -and $cw -le $w -and $ch -le $hgt) {
    $crop = $bmp.Clone((New-Object System.Drawing.Rectangle $cx, $cy, $cw, $ch), $bmp.PixelFormat)
    $bmp.Dispose(); $bmp = $crop
  }
  $file = Join-Path $OutDir ("windows-" + $page + $Suffix + ".png")
  $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  # Also keep a full-desktop capture so reviewers can see the app on a real Windows desktop.
  $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $desk = New-Object System.Drawing.Bitmap $screen.Width, $screen.Height
  $dg = [System.Drawing.Graphics]::FromImage($desk)
  $dg.CopyFromScreen($screen.Location, [System.Drawing.Point]::Empty, $screen.Size)
  $dg.Dispose()
  $desk.Save((Join-Path $OutDir ("windows-desktop-" + $page + $Suffix + ".png")), [System.Drawing.Imaging.ImageFormat]::Png)
  $desk.Dispose()
  Stop-Process -Id $p.Id -Force
  Start-Sleep -Milliseconds 800
  "captured $file"
}
