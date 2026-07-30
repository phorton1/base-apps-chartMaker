# tool_shot.ps1 -- screenshot the running chartMaker window
#
#   powershell -File tool_shot.ps1 [-out <path.png>]
#
# BY OWNING PROCESS, NOT BY TITLE.  Three windows in a running session
# answer to "chartMaker" - the frame, the console, and the browser tab -
# and picking one by title picks a different one on different days.  The
# perl process that has a main window is the application, unambiguously.
#
# The pixels come off the SCREEN rather than out of the window, so the
# window has to be visible and not covered.  That is a real limitation and
# the reason this is a tool rather than a test: it reports what a person
# would see, which is the only thing worth checking by eye.

param([string]$out = "C:\_temp\dat-openCPN-chartMaker\shot.png")

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@
Add-Type -AssemblyName System.Drawing

$p = Get-Process perl -ErrorAction SilentlyContinue |
     Where-Object { $_.MainWindowTitle -ne "" } | Select-Object -First 1
if (-not $p) { Write-Output "chartMaker is not running"; exit 1 }

$r = New-Object W+RECT
[void][W]::GetWindowRect($p.MainWindowHandle, [ref]$r)

$w  = $r.R - $r.L
$h  = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)

Write-Output ("$($p.Id) '$($p.MainWindowTitle)' $($r.L),$($r.T) ${w}x${h} -> $out")
