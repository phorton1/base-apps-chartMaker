; sample_cava.iss - a stand-in for what Cava Packager emits.
;
; WHAT IT IS FOR.  PreInstallApp.pm rewrites Cava's generated innosetup.iss,
; and the only way to find out whether it still produces a compilable script
; is to run it on one.  Doing that for real means a full Cava scan and build
; - minutes, and a GUI - which is far too expensive to do after every edit,
; so PreInstallApp went untested between builds and shipped a bug into an
; uninstaller.
;
; This is the shape Cava emits, hand-made and cut to the parts PreInstallApp
; actually keys on: the [Setup] directives it rewrites (MinVersion with the
; legacy comma form, OutputManifestFile with a path), and the [Files],
; [Run], [Icons] and [Languages] headers it injects at or removes.
;
; THE ROUND TRIP:
;
;   copy sample_cava.iss to a scratch dir as innosetup.iss
;   perl PreInstallApp.pm <scratch>/release <scratch>
;   "C:\Program Files (x86)\Inno Setup 5\ISCC.exe" <scratch>\innosetup.iss
;
; A successful compile means the rewrite is structurally sound and every
; [Files] source it injects exists.  It does NOT mean the Pascal behaves -
; that only runs at install time, which is what sizeprobe.iss is for.
;
; KEEP IT LOOKING LIKE CAVA'S OUTPUT.  Its value is entirely in being
; representative; a version edited into something convenient tests nothing.
; Compare against base_dist/chartMaker/installer/innosetup.iss after a real
; build if there is ever any doubt.

[Setup]
AppID={{11111111-2222-3333-4444-555555555555}
AppName=chartMaker
AppVersion=0.1.0.1
AppVerName=chartMaker 0.1.0.1
AppPublisher=phorton1
DefaultDirName={pf}\chartMaker
DisableDirPage=no
DefaultGroupName=chartMaker
DisableProgramGroupPage=no
LicenseFile=
OutputDir=C:\_temp\base-apps-chartMaker\iss_out
OutputBaseFilename=chartMaker-msw-x86-0-1-0
Compression=lzma/Max
SolidCompression=true
AppCopyright=Copyright (C) 2026 Patrick Horton
TimeStampsInUTC=true
OutputManifestFile=C:\_temp\base-apps-chartMaker\iss_out\innosetup.manifest
InternalCompressLevel=Max
ShowLanguageDialog=no
UninstallDisplayName=chartMaker
VersionInfoVersion=0.1.0.1
UninstallFilesDir={app}\bin
MinVersion=,5.1.2600
PrivilegesRequired=admin
UsePreviousSetupType=false

[Tasks]
Name: desktopicon; Description: "Create desktop icons"; GroupDescription: "Additional icons:"

[Files]
Source: "C:\base\apps\chartMaker\_installer\icons\chartMaker.ico"; DestDir: "{app}\bin"; Flags: ignoreversion
Source: "C:\base\apps\chartMaker\_installer\icons\chartMakerGrey.ico"; DestDir: "{app}\bin"; Flags: ignoreversion

[Run]

[Icons]
Name: "{group}\chartMaker"; Filename: "{app}\bin\chartMakerGUI.exe"; WorkingDir: "{app}\bin"

[Languages]
Name: "eu"; MessagesFile: "compiler:Languages\Basque.isl"
Name: "sk"; MessagesFile: "compiler:Languages\Slovak.isl"
