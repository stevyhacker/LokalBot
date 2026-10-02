param([switch]$CaptureText, [switch]$ScreenshotBytes)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class LokalBotFocus {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@
$handle = [LokalBotFocus]::GetForegroundWindow()
[uint32]$processId = 0
[void][LokalBotFocus]::GetWindowThreadProcessId($handle, [ref]$processId)
$window = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
$focus = [System.Windows.Automation.AutomationElement]::FocusedElement
if ($null -eq $focus -or $null -eq $window) { exit 2 }
$rect = $window.Current.BoundingRectangle
$inside = $false
$ancestor = $focus
$windowIdentity = ($window.GetRuntimeId() -join ":")
for ($depth=0; $depth -lt 64 -and $null -ne $ancestor; $depth++) {
 if (($ancestor.GetRuntimeId() -join ":") -eq $windowIdentity) { $inside=$true; break }
 $ancestor = [System.Windows.Automation.TreeWalker]::RawViewWalker.GetParent($ancestor)
}
$verified = ($inside -and -not $focus.Current.IsOffscreen -and $focus.Current.ProcessId -eq $processId)
$secure = $focus.Current.IsPassword
$field = ($focus.GetRuntimeId() -join ":")
$nodes = $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
$texts = New-Object System.Collections.Generic.List[string]
if ($nodes.Count -gt 800) { $secure = $null }
for ($index=0; $index -lt [Math]::Min(800,$nodes.Count); $index++) {
 $node = $nodes[$index]
 if ($node.Current.IsOffscreen) { continue }
 if ($node.Current.IsPassword) { $secure = $true; continue }
 $b = $node.Current.BoundingRectangle
 if ($b.IsEmpty -or -not $rect.Contains($b)) { continue }
 if ($CaptureText) {
  $pattern = $null
  if ($node.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
   foreach ($range in $pattern.GetVisibleRanges()) { $texts.Add($range.GetText(4000)) }
  } elseif ($node.Current.ControlType -eq [System.Windows.Automation.ControlType]::Text) { $texts.Add($node.Current.Name) }
 }
}
$process = Get-Process -Id $processId
$browser = $process.ProcessName -match 'chrome|chromium|firefox|msedge|brave|vivaldi|opera|librewolf|zen|floorp|waterfox|browser'
if ($ScreenshotBytes) {
 if (-not $verified -or $secure -ne $false) { exit 2 }
 $bitmap = New-Object System.Drawing.Bitmap ([int]$rect.Width),([int]$rect.Height)
 $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
 $memory = New-Object System.IO.MemoryStream
 try {
  $graphics.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bitmap.Size)
  $bitmap.Save($memory,[System.Drawing.Imaging.ImageFormat]::Png)
  $bytes = $memory.ToArray()
  $stdout = [Console]::OpenStandardOutput()
  $stdout.Write($bytes,0,$bytes.Length)
  $stdout.Flush()
 } finally { $memory.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
 exit 0
}
@{observation=@{app=$process.ProcessName;title=$window.Current.Name;window=$handle.ToInt64().ToString();pid=$processId;field=$field;focus_verified=$verified;secure=$secure;domain=$null;browser=$browser};bounds=@([int]$rect.X,[int]$rect.Y,[int]$rect.Width,[int]$rect.Height);text=(($texts | Select-Object -Unique) -join "`n")} | ConvertTo-Json -Depth 5 -Compress
