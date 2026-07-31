@echo off
rem ---------------------------------------------
rem run_chartmaker.bat -- launch the app in a window that SHOWS THE LOG
rem ---------------------------------------------
rem This is how the application gets started for Patrick.  The point is the
rem console window: it carries the display() output as it happens, and it
rem is also where console commands are typed - 'build mbtiles all', 'fetch',
rem 'dbg', and the rest of em_command's vocabulary.
rem
rem A .BAT RATHER THAN A COMMAND LINE, because the problem was argument
rem quoting rather than anything about the shell.  Start-Process on a .bat
rem works; Start-Process cmd -ArgumentList '/k','<perl ...>' silently
rem produces no window at all.
rem
rem PAUSE IS DELIBERATE - it keeps a crash message on screen after perl
rem exits.  It also means killing perl alone leaves this shell behind, so
rem anything that kills the app should match cmd.exe on '*chartMaker*' too.
rem
rem The paths are hardcoded to this machine's Perl and repo root, which is
rem what a launcher is.

title chartMaker LOG
cd /d C:\base\apps\chartMaker
C:\Perl\bin\perl.exe -IC:\base -IC:\base\apps\chartMaker C:\base\apps\chartMaker\chartMaker.pm
echo.
echo ==== chartMaker exited ====
pause
