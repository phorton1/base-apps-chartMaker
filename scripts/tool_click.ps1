# tool_click.ps1 -- focus a window by PID and click a point inside it
#
#   powershell -File tool_click.ps1 -procId <pid> -x <x> -y <y>
#   powershell -File tool_click.ps1 -procId <pid> -focusOnly
#
# THE OTHER HALF OF tool_shot.ps1.  That one reads pixels off the screen
# and therefore needs its window visible; this is what makes it visible,
# and what drives the window once it is.
#
# BY PID, NEVER BY TITLE.  Three windows answer to "chartMaker" - the
# frame, the console and the browser - so a title match picks a different
# one on different days.  Pass the pid of the instance you started.
#
# COORDINATES ARE WINDOW-RELATIVE, which is what makes this usable at all:
# they can be read straight off a tool_shot.ps1 capture of the same
# window, because that capture starts at the same origin.
#
# ATTACHTHREADINPUT IS NOT OPTIONAL.  Windows refuses SetForegroundWindow
# outright unless the calling thread already owns the foreground - so a
# bare call silently does nothing and the click lands on whatever was in
# front. Attaching to the thread that does own it makes the call legal for
# as long as we stay attached, and it detaches again immediately.
#
# CLICKS RATHER THAN SendKeys, because SendKeys is unreliable here and a
# click is not.  A menu opens with a click; the item under it needs a
# second call with coordinates read from a fresh screenshot, since a
# window index goes stale between calls.

param(
  [int]$procId,
  [int]$x,
  [int]$y,
  [switch]$focusOnly)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class U {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int c);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out R r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f,uint x,uint y,uint d,int e);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a,uint b,bool f);
  public struct R { public int L,T,Rt,B; }
}
"@

$p = Get-Process -Id $procId
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { Write-Output "no main window for $procId"; exit 1 }

# ATTACHTHREADINPUT, because SetForegroundWindow is refused outright unless
# the calling thread already owns the foreground.  Attaching to the thread
# that does own it makes the call legal for as long as we stay attached.

$fg = [U]::GetForegroundWindow()
$dummy = 0
$fgThread = [U]::GetWindowThreadProcessId($fg,[ref]$dummy)
$me = [U]::GetCurrentThreadId()
[void][U]::AttachThreadInput($fgThread,$me,$true)
[void][U]::ShowWindow($h,9)          # SW_RESTORE
[void][U]::SetForegroundWindow($h)
Start-Sleep -Milliseconds 400
[void][U]::AttachThreadInput($fgThread,$me,$false)

$r = New-Object U+R
[void][U]::GetWindowRect($h,[ref]$r)
Write-Output "window $($r.L),$($r.T) - $($r.Rt),$($r.B)"

if ($focusOnly) { exit 0 }

$sx = $r.L + $x
$sy = $r.T + $y
[void][U]::SetCursorPos($sx,$sy)
Start-Sleep -Milliseconds 150
[U]::mouse_event(0x0002,0,0,0,0)     # LEFTDOWN
Start-Sleep -Milliseconds 60
[U]::mouse_event(0x0004,0,0,0,0)     # LEFTUP
Write-Output "clicked $sx,$sy"
