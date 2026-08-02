# tool_shot.ps1 -- screenshot the running chartMaker window
#
#   powershell -File tool_shot.ps1 [-out <path.png>]
#
# BY OWNING PROCESS, NOT BY TITLE.  Three windows in a running session
# answer to "chartMaker" - the frame, the console, and the browser tab -
# and picking one by title picks a different one on different days.  The
# perl process that has a main window is the application.
#
# UNAMBIGUOUS ONLY WHILE THERE IS ONE.  'the first perl with a window' is
# a coin toss the moment two chartMakers exist, and the consequence is not
# a bad screenshot - it is measuring, moving or closing somebody else's
# process while believing it is yours.  That happened.  So this REFUSES
# when there is more than one candidate rather than guessing, and -procId
# says which.  Pass the pid of the instance you started.
#
# A tooltip counts as a window, incidentally: hovering over a control can
# make a 20 pixel tip the process's "main" window for as long as it shows.
#
# The pixels come off the SCREEN rather than out of the window, so the
# window has to be visible and not covered.  That is a real limitation and
# the reason this is a tool rather than a test: it reports what a person
# would see, which is the only thing worth checking by eye.

param(
  [string]$out = "C:\_temp\base-apps-chartMaker\shot.png",
  [int]$procId = 0)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@
Add-Type -AssemblyName System.Drawing

if ($procId -gt 0) {
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if (-not $p) { Write-Output "no process $procId"; exit 1 }
} else {
  $all = @(Get-Process perl -ErrorAction SilentlyContinue |
           Where-Object { $_.MainWindowTitle -ne "" })
  if ($all.Count -eq 0) { Write-Output "chartMaker is not running"; exit 1 }
  if ($all.Count -gt 1) {
    Write-Output "REFUSING: $($all.Count) windowed perl processes -"
    $all | ForEach-Object { Write-Output "  pid $($_.Id)  '$($_.MainWindowTitle)'" }
    Write-Output "pass -procId to say which one you mean."
    exit 2
  }
  $p = $all[0]
}

$r = New-Object W+RECT
[void][W]::GetWindowRect($p.MainWindowHandle, [ref]$r)

$w  = $r.R - $r.L
$h  = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.L, $r.T, 0, 0, $bmp.Size)
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)

Write-Output ("$($p.Id) '$($p.MainWindowTitle)' $($r.L),$($r.T) ${w}x${h} -> $out")
