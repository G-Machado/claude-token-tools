# Dev loop for --preview: launch TokenChat on a fixture, PrintWindow the window to a PNG, kill it.
# powershell -File preview/capture.ps1 -Exe <abs TokenChat.App.exe> -Fixture <abs preview/asks.jsonl> -Out <png>
# -Fixture a.jsonl,b.jsonl opens a tab per fixture (split here: -File passes the list as one string).
# The first launch of a fresh build can take 20 s+ (the PNG shows the start page): use -Settle 25000 for that one.
param([string]$Exe, [string]$Fixture, [string]$Out, [int]$Settle = 6000)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Cap {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@
[void][Cap]::SetProcessDPIAware()
$argv = @($Fixture -split ',' | ForEach-Object { '--preview'; '"{0}"' -f $_ })
$p = Start-Process -FilePath $Exe -ArgumentList $argv -PassThru
try {
  $deadline = (Get-Date).AddSeconds(20)
  while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $p.Refresh() }
  if ($p.MainWindowHandle -eq 0) { throw "no window after 20 s (exited: $($p.HasExited))" }
  Start-Sleep -Milliseconds $Settle
  $h = $p.MainWindowHandle
  $r = New-Object Cap+RECT
  [void][Cap]::GetWindowRect($h, [ref]$r)
  $w = $r.R - $r.L; $ht = $r.B - $r.T
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc()
  [void][Cap]::PrintWindow($h, $dc, 2)
  $g.ReleaseHdc($dc); $g.Dispose()
  $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
  "captured ${w}x${ht} -> $Out"
} finally {
  if (-not $p.HasExited) { $p.Kill() }
}
