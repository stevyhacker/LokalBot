# Raises the CI runner's display resolution (GitHub's Windows runners start at
# 1024x768) so screenshots show the whole window. Best effort.
param([int]$Width = 1920, [int]$Height = 1080)
try {
  Set-DisplayResolution -Width $Width -Height $Height -Force -ErrorAction Stop
  "Set-DisplayResolution: ${Width}x${Height}"
  return
} catch {
  "Set-DisplayResolution unavailable, using ChangeDisplaySettings: $($_.Exception.Message)"
}
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class LbDisplay {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll")] public static extern bool EnumDisplaySettings(string device, int mode, ref DEVMODE dm);
  [DllImport("user32.dll")] public static extern int ChangeDisplaySettings(ref DEVMODE dm, int flags);
}
"@
$dm = New-Object LbDisplay+DEVMODE
$dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
[LbDisplay]::EnumDisplaySettings($null, -1, [ref]$dm) | Out-Null
$dm.dmPelsWidth = $Width
$dm.dmPelsHeight = $Height
$dm.dmFields = 0x00080000 -bor 0x00100000
$result = [LbDisplay]::ChangeDisplaySettings([ref]$dm, 0)
"ChangeDisplaySettings result: $result (0 = changed)"
