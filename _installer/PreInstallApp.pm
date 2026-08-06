#---------------------------------------------
# PreInstallApp.pm  (chartMaker)
#---------------------------------------------
# Run by Cava Packager after the build but BEFORE the Inno Setup compile.
# Cava (2.0, abandonware) emits an innosetup.iss for an older Inno Setup;
# this script rewrites it for the installed Inno Setup 5.5.9, which would
# otherwise fail the compile.  Modelled on apps/navMate/_installer/PreInstallApp.pm.
#
# Cava invokes:   perl PreInstallApp.pm <release_dir> <installer_dir>
# The file rewritten is <installer_dir>/innosetup.iss.
#
# Fixups (each is an ISCC fatal under 5.5.9):
#   MinVersion=,<nt>           legacy two-part (9x,NT) form; 9x support was
#                              dropped in 5.5.x so the comma form is invalid.
#   OutputManifestFile=<path>  a path is no longer accepted; reduced to the
#                              bare filename (re-emitted in [Setup]).
#   [Languages] ...            Cava lists ~20 languages incl. Basque/Slovak
#                              whose .isl files no longer ship; the whole
#                              section is removed (default English messages).
#
# Injections Cava cannot express:
#   [Files]         seed $data_dir from _res/user_data on a fresh install
#   [Files]         the two agreement documents, as dontcopy payload
#   [UninstallDelete]  remove $temp_dir, which holds nothing authored
#   [Code]          the two scroll-gated agreement pages, and the uninstall
#                   prompt that offers to remove the user's data folder
#
# WHAT navMate HAS AND THIS DOES NOT, so the difference is not mistaken for
# an omission:
#
#   No mod-record denormalization.  That shipped e80Mod's firmware records
#   into the release tree.  Everything chartMaker ships is already inside
#   _res and rides the resource tree.
#
#   No [Run] section.  There is no post-install wizard to offer.
#
#   No firewall rules.  navMate pre-authorizes inbound RAYDP because it
#   genuinely wants to be reachable from the LAN.  chartMaker's only client
#   is a browser on this machine.  Pub::HTTP::ServerBase binds every
#   interface rather than the loopback, so Windows will still offer its
#   "allow access" prompt on a first run -- and the honest answer to that
#   prompt is Cancel, which costs nothing, because a blocked rule still
#   permits loopback.  Adding an allow rule would grant reachability the
#   application does not want.

use strict;
use warnings;

my $release_dir   = $ARGV[0];
my $installer_dir = $ARGV[1];
my $iss_file      = "$installer_dir/innosetup.iss";

my $in_languages = 0;

# WHERE THE SHIPPED MATERIAL COMES FROM AND WHERE IT LANDS.  _res/user_data
# mirrors the default $data_dir one folder per tree, which is what lets the
# installer do the simple thing: each destination is the source's own name
# under the user's folder.  dm_restore.pm holds the same mapping for the
# runtime path (Help - Restore Shipped Sources and Examples) and the two
# must agree.
#
# The application reads these trees THROUGH PREFERENCES and a user may have
# pointed one elsewhere -- which the installer cannot know and does not try
# to.  It writes the defaults, which is right for the only case it is in:
# a machine with no preferences file yet.

my $RES     = 'C:\base\apps\chartMaker\_res\user_data';
my $APP_SRC = 'C:\base\apps\chartMaker';
my $DATA    = '{userdocs}\phorton1\chartMaker';
my $TEMP    = '{localappdata}\phorton1\chartMaker';


sub seedFilesLines
	# onlyifdoesntexist  => a fresh machine only; an existing file is never
	#                       clobbered, so a reinstall cannot eat an edit.
	# uninsneveruninstall => never removed on uninstall; what happens to the
	#                       user's folder is asked in the [Code] section
	#                       below, as one question about the whole of it.
	#
	# Target is the user's OWN Documents, which is user-writable and needs
	# no elevation even though the installer itself has it.
{
	return
		"; added by PreInstallApp.pm -- seed the user's data folder on a fresh install\n".
		qq(Source: "$RES\\sources\\*"; DestDir: "$DATA\\sources"; Flags: onlyifdoesntexist uninsneveruninstall\n).
		qq(Source: "$RES\\region_sets\\Example\\*"; DestDir: "$DATA\\region_sets\\Example"; Flags: onlyifdoesntexist uninsneveruninstall\n).
		"; added by PreInstallApp.pm -- agreement docs, extracted at run time by the Notice/License [Code] pages (dontcopy = not installed)\n".
		qq(Source: "$APP_SRC\\NOTICE_TO_MARINERS.txt"; Flags: dontcopy\n).
		qq(Source: "$APP_SRC\\LICENSE.TXT"; Flags: dontcopy);
}


sub tempCleanupUninstallSection
	# An [UninstallDelete] section that removes $temp_dir.  Everything there
	# is derived -- the .ini window layout and the per-source observation
	# records -- and every value in it re-converges within a run or two, so
	# there is nothing to ask about.  The user's DATA is a separate question
	# and is asked, in CurUninstallStepChanged below.
{
	return "; added by PreInstallApp.pm -- remove derived ini/observations on uninstall\n".
		"[UninstallDelete]\n".
		qq(Type: filesandordirs; Name: "$TEMP"\n);
}


sub agreementsCodeSection
	# A [Code] section (Cava emits none) carrying two unrelated things that
	# have to share one section because Inno allows only one.
	#
	# FIRST, THE AGREEMENTS.  Inno's native license page is replaced by two
	# consistent custom pages, inserted after the Welcome page in order:
	#   1. Notice to Mariners      2. License Agreement (GPL3)
	# Each is a read-only memo of its document -- extracted at install time
	# from the dontcopy [Files] payload, so the source files stay the single
	# source of truth -- plus an "I agree" checkbox.  The checkbox is
	# SCROLL-GATED: the instant it is ticked we sample the memo's vertical
	# scrollbar via GetScrollInfo, and if the user has not reached the bottom
	# we un-tick it and prompt.  Sampling at click time catches every scroll
	# method (wheel, scrollbar, keyboard) -- the only reliable way under
	# Inno 5.x, which lacks the CreateCallback timers Inno 6 would use to
	# watch scrolling live.  A document short enough to need no scrollbar
	# counts as read, so Next enables immediately.  CreateCustomPage anchors
	# on wpWelcome regardless of whether the Welcome page is itself
	# displayed, so the ordering holds either way.
	#
	# SECOND, THE UNINSTALL QUESTION, and it is chartMaker's own.  navMate
	# asks whether to delete a database.  chartMaker's data folder holds the
	# TILE CACHE, which is the expensive thing this application accumulates:
	# bandwidth, wall clock, and for some sources requests that should not
	# be repeated.  A user answering Yes to a bare "delete your data folder"
	# would not know they were throwing away a survey that took hours.  So
	# the folder is WALKED FIRST and the question states the tile count and
	# the total size, and only then offers Yes.
	#
	# THE WALK IS THE REASON FOR THE WAIT STATE.  A large cache is hundreds
	# of thousands of files and enumerating them is not instant, so the
	# uninstall progress form is given a caption and repainted before the
	# walk starts; without that the uninstaller simply appears to hang.
	#
	# EVERY CONSTRUCT HERE WAS COMPILE-TESTED against the installed Inno
	# 5.5.9 before being written, which matters for two of them: Int64
	# exists only in the Unicode build (added 5.5.3), and
	# UninstallProgressForm dates from 5.2.3.  A byte total needs Int64 --
	# a cache well past 4 GB is an ordinary outcome, and a 32-bit
	# accumulator would silently wrap and report a fraction of the truth.
{
	return <<'EOC';

; added by PreInstallApp.pm -- agreement pages, and the uninstall data question
[Code]
type
  TScrollInfo = record
    cbSize: Cardinal;
    fMask: Cardinal;
    nMin: Integer;
    nMax: Integer;
    nPage: Cardinal;
    nPos: Integer;
    nTrackPos: Integer;
  end;

function GetScrollInfo(hWnd: HWND; BarFlag: Integer; var ScrollInfo: TScrollInfo): BOOL;
  external 'GetScrollInfo@user32.dll stdcall';

const
  SB_VERT = 1;
  SIF_RANGE = 1;
  SIF_PAGE = 2;
  SIF_POS = 4;

var
  NoticePageID, LicensePageID: Integer;
  NoticeMemo, LicenseMemo: TNewMemo;
  NoticeCheck, LicenseCheck: TNewCheckBox;

function ScrolledToBottom(Memo: TNewMemo): Boolean;
var
  SI: TScrollInfo;
begin
  SI.cbSize := SizeOf(SI);
  SI.fMask := SIF_RANGE or SIF_PAGE or SIF_POS;
  if GetScrollInfo(Memo.Handle, SB_VERT, SI) then
    Result := (SI.nMax <= 0) or (SI.nPos >= SI.nMax - Integer(SI.nPage))
  else
    Result := True;
end;

procedure GateCheck(Memo: TNewMemo; Check: TNewCheckBox);
begin
  if Check.Checked and not ScrolledToBottom(Memo) then
  begin
    Check.Checked := False;
    MsgBox('Please scroll to the bottom of the document before accepting.', mbInformation, MB_OK);
  end;
  WizardForm.NextButton.Enabled := Check.Checked;
end;

procedure NoticeCheckClick(Sender: TObject);
begin
  GateCheck(NoticeMemo, NoticeCheck);
end;

procedure LicenseCheckClick(Sender: TObject);
begin
  GateCheck(LicenseMemo, LicenseCheck);
end;

function MakeAgreementPage(AfterID: Integer; ACaption, ADescription, ADocFile, ACheckCaption: String; var Memo: TNewMemo; var Check: TNewCheckBox): Integer;
var
  Page: TWizardPage;
  A: AnsiString;
  S: String;
begin
  Page := CreateCustomPage(AfterID, ACaption, ADescription);

  Memo := TNewMemo.Create(WizardForm);
  Memo.Parent := Page.Surface;
  Memo.Left := 0;
  Memo.Top := 0;
  Memo.Width := Page.SurfaceWidth;
  Memo.Height := Page.SurfaceHeight - ScaleY(28);
  Memo.ReadOnly := True;
  Memo.WordWrap := True;
  Memo.ScrollBars := ssVertical;
  ExtractTemporaryFile(ADocFile);
  if LoadStringFromFile(ExpandConstant('{tmp}\' + ADocFile), A) then
  begin
    // A Windows edit control breaks lines only on CRLF; normalize so the memo
    // wraps correctly whether the source file is LF or CRLF.
    S := A;
    StringChangeEx(S, #13#10, #10, True);
    StringChange(S, #10, #13#10);
    Memo.Text := S;
  end
  else
    Memo.Text := '(' + ADocFile + ' could not be loaded)';

  Check := TNewCheckBox.Create(WizardForm);
  Check.Parent := Page.Surface;
  Check.Left := 0;
  Check.Top := Page.SurfaceHeight - ScaleY(22);
  Check.Width := Page.SurfaceWidth;
  Check.Height := ScaleY(20);
  Check.Caption := ACheckCaption;

  Result := Page.ID;
end;

procedure InitializeWizard();
begin
  NoticePageID := MakeAgreementPage(wpWelcome, 'Notice to Mariners', 'Please read this notice carefully before continuing.', 'NOTICE_TO_MARINERS.txt', 'I have read and agree to this Notice to Mariners.', NoticeMemo, NoticeCheck);
  NoticeCheck.OnClick := @NoticeCheckClick;

  LicensePageID := MakeAgreementPage(NoticePageID, 'License Agreement', 'Please read the following license agreement.', 'LICENSE.TXT', 'I have read and agree to the terms and conditions.', LicenseMemo, LicenseCheck);
  LicenseCheck.OnClick := @LicenseCheckClick;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = NoticePageID then
    WizardForm.NextButton.Enabled := NoticeCheck.Checked
  else if CurPageID = LicensePageID then
    WizardForm.NextButton.Enabled := LicenseCheck.Checked;
end;

// added by PreInstallApp.pm -- what the user's data folder actually holds.
// Walked once, counting every file, the bytes of every file, and separately
// the files below a folder named 'cache' (the tiles).  A folder named cache
// deeper in the tree would be counted as tiles too; nothing chartMaker
// writes creates one, and over-reporting tiles is the harmless direction.
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

// added by PreInstallApp.pm -- a size in the largest unit that fits.
//
// INTEGER ARITHMETIC ONLY, and that is not a preference.  This was written
// as Format('%.1f GB',[Bytes / 1073741824]), which COMPILES CLEANLY and
// then dies at run time with "Format '%.1f' invalid or incompatible with
// the argument" -- Inno's Pascal Script cannot pass a float through an
// array of const.  It shipped, and it fired in the uninstaller, which is
// the worst place to put a bug: the user has already said yes to removing
// the program and now cannot.
//
// The lesson is not about floats.  A compile test proved nothing here,
// because the failure only exists at run time; see _installer/sizeprobe.iss
// for the pattern that actually exercises this code without installing
// anything.
//
// It TRUNCATES rather than rounds, so 3.6 GB reads as 3.5 GB.  Carrying a
// rounded tenth means handling Frac reaching 10, and a tenth of a gigabyte
// is well inside the noise on a number whose job is to convey scale.
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

// added by PreInstallApp.pm -- opt-in removal of the user's DATA folder.
// Defaults to No.  The [UninstallDelete] section removes only the derived
// ini and observation records, never this, so region sets, tile sources,
// the key store, built output and the cache all survive an
// uninstall/reinstall unless the user explicitly asks for them to go.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  DataDir, Msg: String;
  Tiles, Files: Integer;
  Bytes: Int64;
begin
  if CurUninstallStep = usUninstall then
  begin
    DataDir := ExpandConstant('{userdocs}\phorton1\chartMaker');
    if DirExists(DataDir) then
    begin
      UninstallProgressForm.StatusLabel.Caption :=
        'Examining your chartMaker data folder. This can take a moment ...';
      UninstallProgressForm.Refresh;

      Tiles := 0;
      Files := 0;
      Bytes := 0;
      WalkFolder(DataDir, False, Tiles, Files, Bytes);

      UninstallProgressForm.StatusLabel.Caption := '';
      UninstallProgressForm.Refresh;

      Msg := 'Also delete your chartMaker data folder at:' + #13#10 + #13#10 +
        DataDir + #13#10 + #13#10 +
        'It holds your region sets, your tile source definitions, your key ' +
        'store, and everything you have built.' + #13#10 + #13#10 +
        IntToStr(Files) + ' files, ' + DescribeSize(Bytes) + ' in total.';

      if Tiles > 0 then
        Msg := Msg + #13#10 + #13#10 +
          'That includes ' + IntToStr(Tiles) + ' cached tiles. Those were ' +
          'fetched from tile servers over time, and deleting them means ' +
          'fetching them all again.';

      Msg := Msg + #13#10 + #13#10 +
        'Choose No to keep everything for a future reinstall.';

      if MsgBox(Msg, mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
        DelTree(DataDir, True, True, True);
    end;
  end;
end;
EOC
}


sub processLine
{
	my ($line) = @_;

	# The [Languages] section runs to EOF; comment all of it out.
	if ($in_languages)
	{
		return $line =~ /\S/ ? "; $line" : $line;
	}
	if ($line eq '[Languages]')
	{
		$in_languages = 1;
		return "; [Languages] removed by PreInstallApp.pm ".
			"(Basque/Slovak .isl no longer ship in Inno 5.5.9)\n; $line";
	}

	# Re-emit the 5.5.9-safe directives right after the [Setup] header.
	if ($line eq '[Setup]')
	{
		return $line."\n".
			"; added by PreInstallApp.pm\n".
			"CloseApplications=force\n".
			"OutputManifestFile=innosetup.manifest";
	}

	# NOTE: the GPL3 license is NOT wired to Inno's native LicenseFile= page (which
	# carries the "I do not accept" radio Patrick dislikes and can't scroll-gate).
	# Both the Notice to Mariners and the license are custom scroll-gated checkbox
	# pages built in the [Code] section (see agreementsCodeSection); the documents are
	# carried as dontcopy [Files] payload and extracted at run time.

	if ($line eq '[Files]')
	{
		return $line."\n".seedFilesLines();
	}

	# Inject the [UninstallDelete] section right before [Icons].
	if ($line eq '[Icons]')
	{
		return tempCleanupUninstallSection()."\n".$line;
	}

	# Drop the lines Inno 5.5.9 rejects.
	if ($line =~ /^MinVersion=/ ||         # legacy 9x,NT form -- invalid
		$line =~ /^OutputManifestFile=/)   # path form -- re-added bare in [Setup]
	{
		return "; commented by PreInstallApp.pm\n; $line";
	}

	return $line;
}


# Read, rewrite, write back.  No die/exit -- a failure just warns (Cava
# captures it) and leaves the file untouched.

my $in;
if (open($in, '<', $iss_file))
{
	my @lines = <$in>;
	close($in);

	my $text = '';
	for my $line (@lines)
	{
		chomp $line;
		$text .= processLine($line)."\n";
	}

	# Append the agreement pages and the uninstall question (Cava emits no
	# [Code] section).
	$text .= agreementsCodeSection();

	my $out;
	if (open($out, '>', $iss_file))
	{
		print $out $text;
		close($out);
		print "PreInstallApp: rewrote $iss_file for Inno 5.5.9\n";
	}
	else
	{
		warn "PreInstallApp: cannot write $iss_file: $!\n";
	}
}
else
{
	warn "PreInstallApp: cannot read $iss_file: $!\n";
}

1;
