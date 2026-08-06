@echo off
rem ---------------------------------------------
rem run_manual.bat -- launch the app in the MANUAL authoring profile
rem ---------------------------------------------
rem The user manual is written and screenshotted against the development
rem build, and a development $data_dir holds Patrick's own region sets and
rem .tsd files.  None of those may appear in a screenshot, so the manual
rem gets a data dir of its own.
rem
rem CHARTMAKER_PROFILE moves BOTH roots (see chartMaker.pm):
rem
rem     $data_dir   /base_data/data/chartMaker.manual
rem     $temp_dir   /base_data/temp/chartMaker.manual
rem
rem Moving $temp_dir is what makes the profile independent - its own ini,
rem its own single-instance lock, its own observation records - and it is
rem why THIS AND THE ORDINARY COPY CAN RUN AT THE SAME TIME.
rem
rem Two things are set once in the profile's own chartMaker.prefs rather
rem than here, because both are ordinary preferences:
rem
rem     HTTP_PORT   something other than 9884 - two instances cannot bind one
rem     CACHE_DIR   the shared dev cache, so screenshots never wait on a fetch
rem
rem Help - Regenerate Examples is what puts the shipped .tsd files and the
rem example region set into an empty profile.
rem
rem IT LIVES AT THE TOP LEVEL rather than in scripts/, beside chartMaker.pm,
rem because it is typed by hand in a cmd.exe session already sitting in this
rem folder:
rem
rem     chartMaker.pm     the ordinary profile - your own material
rem     run_manual        the manual profile - the shipped example only
rem
rem That pairing is the whole reason.  scripts/run_chartmaker.bat is a
rem different thing: a launcher Claude starts on Patrick's behalf, which is
rem why it is with the other things Claude runs.
rem
rem Otherwise identical to it, including the console window and the
rem deliberate pause.

rem SETLOCAL, AND IT IS LOAD BEARING.  Without it `set` outlives this batch
rem file and stays set in the cmd.exe window that ran it - so the next
rem `chartMaker.pm` typed in the SAME window silently comes up in the manual
rem profile, and work meant for the dev data lands in the example data.
rem That happened once and cost a region.  setlocal scopes the variable to
rem this file; perl runs inside it and still inherits it.

setlocal
title chartMaker MANUAL PROFILE
set CHARTMAKER_PROFILE=manual
cd /d C:\base\apps\chartMaker
C:\Perl\bin\perl.exe -IC:\base -IC:\base\apps\chartMaker C:\base\apps\chartMaker\chartMaker.pm
echo.
echo ==== chartMaker (manual profile) exited ====
pause
