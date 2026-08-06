; sizeprobe.iss - runtime harness for the Pascal in PreInstallApp.pm
;
; WHY THIS EXISTS.  A compile test proves almost nothing about Inno's Pascal
; Script.  DescribeSize was originally written with Format('%.1f GB',[...]),
; which ISCC accepts without complaint and which dies at run time with
; "Format '%.1f' invalid or incompatible with the argument" -- and it died in
; the UNINSTALLER, where the user has already agreed to remove the program
; and now cannot.  Everything here compiled before it failed.
;
; THE TRICK IS InitializeSetup RETURNING FALSE.  The code runs, writes its
; answers to a file, and setup then aborts before installing anything: no
; files, no registry key, no uninstaller, no UI.  So the real functions can
; be exercised as often as wanted with no consequences.
;
;   "C:\Program Files (x86)\Inno Setup 5\ISCC.exe" sizeprobe.iss
;   sizeprobe_out\sizeprobe.exe /VERYSILENT
;   type C:\_temp\base-apps-chartMaker\sizeprobe_result.txt
;
; WHAT IT CANNOT REACH is UninstallProgressForm, which exists only in an
; uninstaller.  That part is still proven only by uninstalling.
;
; KEEP THE FUNCTIONS BELOW IDENTICAL to the ones PreInstallApp.pm emits.
; They are a copy, and a copy that has drifted tests nothing.

[Setup]
AppName=SizeProbe
AppVersion=1.0
DefaultDirName=C:\_temp\base-apps-chartMaker\sizeprobe
OutputDir=C:\_temp\base-apps-chartMaker\sizeprobe_out
OutputBaseFilename=sizeprobe
Uninstallable=no
CreateUninstallRegKey=no
CreateAppDir=no

; NO UAC PROMPT.  An Inno installer requests admin by default, and this one
; installs nothing at all -- so running the harness threw a UAC dialog on
; Patrick's screen every time, which is a rude thing for a test to do.
;
; PrivilegesRequired=none alone did NOT stop it.  The other half is
; Windows' installer-detection heuristic, which elevates an executable
; whose version resource says "setup" or "install" regardless of what the
; manifest asks for -- and Inno stamps "<AppName> Setup" into the
; description by default.  Hence the deliberately boring strings below.
;
; UNVERIFIED, and honestly so: confirming it would mean running the thing
; again, which is the exact nuisance being fixed.  If it still prompts,
; that is why, and it costs one click.

PrivilegesRequired=none
VersionInfoDescription=chartMaker pascal harness
VersionInfoProductName=chartMaker pascal harness

[Code]

procedure WalkFolder(const Path: String; CacheHere: Boolean; var Tiles: Integer; var Files: Integer; var Bytes: Int64);
var
  FindRec: TFindRec;
  Sub: Boolean;
begin
  if FindFirst(AddBackslash(Path) + '*', FindRec) then
  begin
    try
      repeat
        if (FindRec.Name <> '.') and (FindRec.Name <> '..') then
        begin
          if (FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
          begin
            Sub := CacheHere or (CompareText(FindRec.Name, 'cache') = 0);
            WalkFolder(AddBackslash(Path) + FindRec.Name, Sub, Tiles, Files, Bytes);
          end
          else
          begin
            Files := Files + 1;
            if CacheHere then
              Tiles := Tiles + 1;
            Bytes := Bytes + Int64(FindRec.SizeHigh) * 4294967296 + Int64(FindRec.SizeLow);
          end;
        end;
      until not FindNext(FindRec);
    finally
      FindClose(FindRec);
    end;
  end;
end;

function DescribeSize(Bytes: Int64): String;
var
  Whole, Frac, Divisor: Int64;
  Suffix: String;
begin
  if Bytes >= 1073741824 then
  begin
    Divisor := 1073741824; Suffix := 'GB';
  end
  else if Bytes >= 1048576 then
  begin
    Divisor := 1048576; Suffix := 'MB';
  end
  else if Bytes >= 1024 then
  begin
    Divisor := 1024; Suffix := 'KB';
  end
  else
  begin
    Result := IntToStr(Bytes) + ' bytes';
    Exit;
  end;
  Whole := Bytes div Divisor;
  Frac := ((Bytes - Whole * Divisor) * 10) div Divisor;
  Result := IntToStr(Whole) + '.' + IntToStr(Frac) + ' ' + Suffix;
end;

function InitializeSetup(): Boolean;
var
  S, Target: String;
  Tiles, Files: Integer;
  Bytes: Int64;
begin
  S := '--- DescribeSize ---' + #13#10 +
       '0 -> ' + DescribeSize(0) + #13#10 +
       '512 -> ' + DescribeSize(512) + #13#10 +
       '1024 -> ' + DescribeSize(1024) + #13#10 +
       '1536 -> ' + DescribeSize(1536) + #13#10 +
       '1048576 -> ' + DescribeSize(1048576) + #13#10 +
       '5242880 -> ' + DescribeSize(5242880) + #13#10 +
       '1073741824 -> ' + DescribeSize(1073741824) + #13#10 +
       '3865470566 -> ' + DescribeSize(3865470566) + #13#10 +
       '12884901888 -> ' + DescribeSize(12884901888) + #13#10 +
       '1099511627776 -> ' + DescribeSize(1099511627776) + #13#10;

  Target := ExpandConstant('{userdocs}\phorton1\chartMaker');
  if not DirExists(Target) then
    Target := 'C:\_temp\base-apps-chartMaker';

  Tiles := 0; Files := 0; Bytes := 0;
  WalkFolder(Target, False, Tiles, Files, Bytes);

  S := S + #13#10 + '--- WalkFolder ---' + #13#10 +
       'path=' + Target + #13#10 +
       'files=' + IntToStr(Files) + #13#10 +
       'tiles=' + IntToStr(Tiles) + #13#10 +
       'bytes=' + IntToStr(Bytes) + #13#10 +
       'size=' + DescribeSize(Bytes) + #13#10;

  SaveStringToFile('C:\_temp\base-apps-chartMaker\sizeprobe_result.txt', S, False);
  Result := False;
end;
