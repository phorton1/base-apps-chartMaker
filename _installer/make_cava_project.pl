#!/usr/bin/perl
#---------------------------------------------
# make_cava_project.pl
#---------------------------------------------
# Creates (or recreates) the Cava Packager project in base_dist/chartMaker:
#
#	C:/base_dist/chartMaker/cava20.cpkgproj		the project, a SQLite database
#	C:/base_dist/chartMaker/cava20/msw/installer.config	the Installer tab, a Storable hash
#
# WHY A SCRIPT RATHER THAN THE CAVA GUI.  Both files are opaque - one is a
# SQLite database with an undocumented 48-column schema, the other a frozen
# Perl hash - and neither can be reviewed in a diff or reasoned about in a
# code review.  Authoring them here puts every value that defines the build
# in one readable place, and makes recreating the project from nothing a
# command rather than an afternoon of clicking through tabs.
#
# THE SCHEMA IS COPIED, NOT DECLARED.  The .cpkgproj starts as a byte copy
# of navMate's, whose rows are then deleted and rewritten.  Cava 2.0 is
# abandonware with a ddlversion field and no published DDL, so a
# hand-written CREATE TABLE that differed in any detail would be found out
# only when the packager refused to open the file.  Copying makes that
# impossible.
#
# IT IS NOT PART OF THE BUILD.  Cava owns these files once it has opened
# them - it writes build counters and its own verbosemask into them - so
# this runs once to bring the project into being, and after that only if
# the project has to be recreated.  RUNNING IT DISCARDS ANYTHING CAVA HAS
# WRITTEN SINCE, which is why it refuses to overwrite without --force.
#
# IT IS NOT IN scripts/, which is for headless harnesses that exercise the
# application.  This builds the thing that builds the application, and
# belongs beside PreInstallApp.pm and the icons it bundles.
#
# Run from git bash:
#	/c/Perl/bin/perl.exe -I/base _installer/make_cava_project.pl [--force]

use strict;
use warnings;
use DBI;
use File::Copy qw(copy);
use File::Path qw(make_path);
use Archive::Zip qw( :ERROR_CODES );

# store(), NOT nstore().  navMate's installer.config begins 'pst0' followed
# by the byteorder string '1234', which is Storable's NATIVE format; the
# network-order form nstore() writes has a different header.  retrieve()
# reads either, but the two files should be the same kind of thing.

use Storable qw(store);

my $FORCE = grep { $_ eq '--force' } @ARGV;

# --icons REBUILDS ONLY THE ICON BUNDLE, and it exists so that changing the
# artwork does not cost the project.  The .cpkgproj is Cava's once Cava has
# opened it - build counters and its own generated values are written back
# into it - so re-running the whole generator to pick up a new .ico would
# throw all of that away.  The zip is regenerable and owned by nobody.

my $ICONS_ONLY = grep { $_ eq '--icons' } @ARGV;

# --version SETS THE VERSION AND TOUCHES NOTHING ELSE, for the same reason
# --icons exists: it is step 2 of cutting a release, and the alternative is
# hunting three fields across the packager's Distribution tab by hand on
# the one day when getting it wrong is expensive.
#
# THE VERSION LIVES IN THE PROJECT AND NOT IN THE SOURCE.  Cava stamps it
# into the executables, and cm_utils::appVersion() reads it back out of the
# packaged build - so this is the single place it is written, and
# $appVersion in cm_defs is only the string a run from source falls back to.
#
# Cava maintains version_build itself; this sets the three that name the
# release, which are also the three the installer filename is built from.

my $SET_VERSION = '';
for my $i (0..$#ARGV)
{
	next if $ARGV[$i] ne '--version';
	$SET_VERSION = $ARGV[$i+1] // '';
	die "--version needs a version like 0.1.0\n"
		if $SET_VERSION !~ /^(\d+)\.(\d+)\.(\d+)$/;
	last;
}

my $TEMPLATE = 'C:/base_dist/navMate/cava20.cpkgproj';
my $DIST     = 'C:/base_dist/chartMaker';
my $PROJ     = "$DIST/cava20.cpkgproj";
my $MSW      = "$DIST/cava20/msw";
my $ICFG     = "$MSW/installer.config";

# THIS MACHINE, as Cava identifies it.  local_config_values and local_path
# are keyed by it, so the paths below are recorded against the same node
# navMate's project already uses rather than a second one Cava would then
# treat as an unconfigured machine.

my $LOCALNODE = 'E7BBFBC9-6C00-1014-AC27-DD4F4860BBFB';

# GUIDS ARE FIXED HERE AND NEVER REGENERATED.  project_class_id becomes the
# installer's AppID, which is how Windows recognizes an upgrade as the same
# product rather than a second copy; a run of this script that minted a new
# one would strand every installation already out there.  They are distinct
# from navMate's for the same reason.

my $PROJECT_CLASS_ID = '1F8203F7-FFFD-1ACA-AE5F-58A3F1A07DF0';
my $CLASS_ID_GUI     = 'BD64ECD0-79E9-4D8D-2596-71D734DF67E5';
my $CLASS_ID_CONSOLE = '455736B3-A404-760A-77F9-5A7CEC8F4392';
my $ICON_GUID_GUI    = 'E26F9D11-D904-DD15-1CF3-1FCE394483F0';
my $ICON_GUID_CONSOLE= '8B90CBDF-FAAD-FEC7-681D-2D6E01C0BB7A';

my $APP_DIR = 'C:/base/apps/chartMaker';


#---------------------------------------------
# config_values
#---------------------------------------------
# The whole of the Distribution tab.  Every row navMate has, because a
# missing one is a field Cava finds unset rather than defaulted.
#
# VERSION IS FOUR PARTS and only the first three are ours: Cava maintains
# version_build itself.  The installer filename is assembled from major,
# minor and release by the name_append_* flags below, so this is what makes
# it chartMaker-msw-x86-0-1-0.exe.

my %CONFIG = (
	abspath					=> '1',
	allowdebugbuild			=> '0',
	appfolder				=> 'chartMaker',
	appinfo_bundlename		=> 'My App Bundle',
	appinfo_disableupdates	=> 'false',
	appinfo_executable		=> 'chartMaker',
	appinfo_iconfile		=> '',
	appinfo_infostring		=> '',
	appinfo_shortversion	=> '',
	appinfo_version			=> '',
	codemask				=> '1',
	comment					=> '',
	compressvirtual			=> '1',
	copyright				=> 'Copyright (C) 2026 Patrick Horton',
	ddlversion				=> '48',
	ldescription			=> '',
	location				=> '2',
	macprojectstyle			=> '7',
	packagediagnostic		=> '0',
	packagetests			=> '0',
	passphrase				=> '',
	prefix					=> 'cp-',
	product_name			=> 'chartMaker',
	project_class_id		=> $PROJECT_CLASS_ID,
	project_name			=> 'chartMaker',
	project_type			=> '1',
	trademark				=> '',
	vendor					=> 'phorton1',
	version_build			=> '0',
	version_major			=> '0',
	version_minor			=> '1',
	version_release			=> '0',
	winaltlayout			=> '0',
	zipres					=> '0',
	zipstd					=> '0',
	ziptst					=> '0',
	zipusr					=> '0',
	zipvrt					=> '0',
);


#---------------------------------------------
# the two executables
#---------------------------------------------
# ONE PROGRAM, TWO EXECUTABLES, and the pairing reads backwards until you
# know why: the GUI exe is built from the SHELL script and the console exe
# from the real one.  Cava keys an executable to exactly one entry script,
# so a second executable needs a second file, and chartMakerGUI.pm is that
# file - fourteen lines that require chartMaker.pm.
#
# exec_type   1 = windowed, run by wperl, no console
#             2 = console, run by perl
#
# manifest_exec_level 1 = asInvoker.  Neither executable is elevated:
# chartMaker writes only to the user's own directories.  The INSTALLER is a
# separate question and does need elevation, because it writes to Program
# Files - see require_privileges below.
#
# THE GREY ICON IS THE CONSOLE ONE, which is navMate's convention and the
# only thing that distinguishes the two in a Start menu.

my @EXECUTABLES = (
	{
		exec_name				=> 'chartMakerGUI',
		script_key				=> 'chartMakerGUI.pm',
		file_path				=> "$APP_DIR/chartMakerGUI.pm",
		exec_type				=> 1,
		class_id				=> $CLASS_ID_GUI,
		icon_bundle				=> 'chartMaker.ico',
		mac_app_primary			=> 0,
		version_description		=> 'chartMakerGUI.exe',
		manifest_name			=> 'chartMakerGUI.Application',
		manifest_description	=> 'chartMakerGUI.Application',
	},
	{
		exec_name				=> 'chartMaker',
		script_key				=> 'chartMaker.pm',
		file_path				=> "$APP_DIR/chartMaker.pm",
		exec_type				=> 2,
		class_id				=> $CLASS_ID_CONSOLE,
		icon_bundle				=> 'chartMakerGrey.ico',
		mac_app_primary			=> 1,
		version_description		=> 'chartMaker.exe',
		manifest_name			=> 'chartMaker.Application',
		manifest_description	=> 'chartMaker.Application',
	},
);


#---------------------------------------------
# forced includes
#---------------------------------------------
# WHAT A STATIC SCAN CANNOT SEE.  Each of these is loaded by name at
# runtime, so nothing in the source spells it out for the scanner to find.
# Every entry needs a reason or it is cargo.

my @INCLUDE = (
	# dm_mbtiles speaks to DBI, which loads its driver by name.  The MBTiles
	# exporter is the only thing that needs it.
	[ 'DBD/SQLite.pm'			=> 'DBD::SQLite' ],

	# Pub::UA fetches every tile over https, and LWP resolves its protocol
	# handler by scheme at request time.  Without this the packaged build
	# reaches no tile server at all.
	[ 'LWP/Protocol/https.pm'	=> 'LWP::Protocol::https' ],

	# Regions, sources, the catalog and the build configuration are all
	# JSON, and the application uses both modules directly.
	[ 'JSON.pm'					=> 'JSON' ],
	[ 'JSON/PP.pm'				=> 'JSON::PP' ],

	# Used throughout, and the fetch engine's worker pool depends on them.
	[ 'threads.pm'				=> 'threads' ],
	[ 'threads/shared.pm'		=> 'threads::shared' ],
);


#---------------------------------------------
# this machine
#---------------------------------------------
# extrapaths RESOLVES THE BARE-NAME USES.  chartMaker loads its own modules
# by bare name - use cm_defs, use dm_set, use w_frame - which is a permanent
# convention, so the application folder goes on the path alongside C:/base,
# which is what resolves Pub::.
#
# The last_build fields are a fresh project's: nothing has been built.

my %LOCAL = (
	extrapaths					=> "C:/base;$APP_DIR",
	perlpath					=> 'C:/Perl/bin/perl.exe',
	resource_path				=> "$APP_DIR/_res",
	last_build					=> '0',
	last_build_dmg				=> '',
	last_build_installer		=> '',
	last_build_installer_capable=> '1',
	last_build_sfx				=> '',
	last_release_string			=> '',
	postbuildscript				=> '',
	pre_installer_script		=> '',
	testfolder					=> '',
	userdir_path				=> '',
);

# verbosemask is deliberately absent.  It is a different random 64-character
# string in every one of Patrick's projects, so it is something Cava
# generates per project rather than anything meaningful, and Cava will write
# its own the first time it opens this.


#---------------------------------------------
# the Installer tab
#---------------------------------------------
# A frozen Perl hash rather than a table, and the one place the installer's
# shape is decided.
#
# require_privileges IS ABOUT THE INSTALLER AND NOT THE APPLICATION.  It
# becomes PrivilegesRequired=admin, which is needed to write Program Files.
# Both executables still run asInvoker afterwards.
#
# The name_append_* flags assemble the output filename.  major, minor and
# release are on and build is off, so a release is named for the version
# people quote rather than for a counter that moves on every scan.

my $INSTALLER_CONFIG = {
	allow_install_path_change	=> '1',
	config_good					=> 0,
	create_uninstaller			=> 1,
	default_install_path		=> '$PROGFILES\\$APPFOLDER',
	desktopicons				=> [
		{
			GUID		=> $ICON_GUID_GUI,
			Name		=> 'chartMaker',
			altIcon		=> '',
			desktop		=> '1',
			exec		=> 'chartMakerGUI',
			execparams	=> '',
			menu		=> '1',
		},
		{
			GUID		=> $ICON_GUID_CONSOLE,
			Name		=> 'chartMaker Console',
			altIcon		=> '',
			desktop		=> '1',
			exec		=> 'chartMaker',
			execparams	=> '',
			menu		=> '1',
		},
	],
	do_post_install				=> 0,
	doinstaller					=> '1',
	include_license				=> 0,
	installer_capable			=> '1',
	installer_type				=> 5,
	installerversion			=> 29,
	license_text				=> '',
	name						=> 'chartMaker',
	name_append_arch			=> '1',
	name_append_osid			=> '1',
	name_append_vbuild			=> 0,
	name_append_vmajor			=> '1',
	name_append_vminor			=> '1',
	name_append_vrelease		=> '1',
	pre_installer_script		=> "$APP_DIR/_installer/PreInstallApp.pm",
	program_group				=> 'chartMaker',
	require_privileges			=> '1',
	toplevel_folder				=> 'chartMaker',
};


#---------------------------------------------
# main
#---------------------------------------------

sub main
{
	if ($ICONS_ONLY)
	{
		writeIconBundle();
		return;
	}

	if ($SET_VERSION)
	{
		setVersion($SET_VERSION);
		return;
	}

	die "template not found: $TEMPLATE\n" if !-f $TEMPLATE;

	if (-f $PROJ && !$FORCE)
	{
		print "$PROJ already exists.\n";
		print "Re-run with --force to discard it and everything Cava has\n";
		print "written into it (build counters, verbosemask) and start over.\n";
		return;
	}

	make_path($MSW) if !-d $MSW;
	make_path("$DIST/cava20/linux") if !-d "$DIST/cava20/linux";
	make_path("$DIST/cava20/osx")   if !-d "$DIST/cava20/osx";

	unlink($PROJ) if -f $PROJ;
	copy($TEMPLATE,$PROJ) or die "cannot copy $TEMPLATE -> $PROJ: $!\n";
	print "copied the schema from navMate's project\n";

	my $dbh = DBI->connect("dbi:SQLite:dbname=$PROJ","","",
		{ RaiseError => 1, PrintError => 0, AutoCommit => 0 });

	# EVERY TABLE IS EMPTIED, including the ones chartMaker leaves empty.
	# What is being copied is the schema and nothing else, and a row of
	# navMate's surviving into this project would be invisible until it
	# produced a wrong build.

	for my $t (qw(
		additional_binary config_values exclude_module executable
		include_module local_config_values local_path script
		shared_library user_folder ))
	{
		$dbh->do("DELETE FROM $t");
	}

	my $sth = $dbh->prepare(
		"INSERT INTO config_values (config_name,config_value) VALUES (?,?)");
	$sth->execute($_,$CONFIG{$_}) for sort keys %CONFIG;
	print "wrote ".scalar(keys %CONFIG)." config_values\n";

	$sth = $dbh->prepare(
		"INSERT INTO executable (exec_name,script_key,exec_type,class_id,".
		"icon_bundle,mac_app_primary,version_description,manifest_name,".
		"manifest_description,manifest_exec_level,manifest_ui_access,".
		"manifest_adv_flags,manifest_custom_file,manifest_common_controls,".
		"extended_data,usesafeputenv,redirect_handles,use_altbin) ".
		"VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)");
	my $sth_script = $dbh->prepare(
		"INSERT INTO script (script_key,file_path,codemask,location) ".
		"VALUES (?,?,?,?)");
	my $sth_path = $dbh->prepare(
		"INSERT INTO local_path (localnode,context,pathkey,localpath) ".
		"VALUES (?,?,?,?)");

	for my $e (@EXECUTABLES)
	{
		die "missing entry script $e->{file_path}\n" if !-f $e->{file_path};

		$sth->execute(
			$e->{exec_name}, $e->{script_key}, $e->{exec_type}, $e->{class_id},
			$e->{icon_bundle}, $e->{mac_app_primary}, $e->{version_description},
			$e->{manifest_name}, $e->{manifest_description},
			1,		# manifest_exec_level  = asInvoker
			0,		# manifest_ui_access
			0,		# manifest_adv_flags
			'',		# manifest_custom_file
			1,		# manifest_common_controls
			'',		# extended_data
			0,		# usesafeputenv
			0,		# redirect_handles
			0);		# use_altbin

		# codemask 1 and location 32 are navMate's, and mean pack the source
		# as plain text.  chartMaker is public on GitHub, so masking would
		# obscure nothing and would only make the shipped copy harder to
		# compare against the published one.

		$sth_script->execute($e->{script_key},$e->{file_path},1,32);
		$sth_path->execute($LOCALNODE,'scriptpath',$e->{script_key},$e->{file_path});

		print "wrote executable $e->{exec_name} ".
			"(".($e->{exec_type} == 1 ? 'windowed' : 'console').", ".
			"$e->{icon_bundle})\n";
	}

	$sth = $dbh->prepare(
		"INSERT INTO include_module (module_key,module_name) VALUES (?,?)");
	$sth->execute(@$_) for @INCLUDE;
	print "wrote ".scalar(@INCLUDE)." forced includes\n";

	$sth = $dbh->prepare(
		"INSERT INTO local_config_values (localnode,config_name,config_value) ".
		"VALUES (?,?,?)");
	$sth->execute($LOCALNODE,$_,$LOCAL{$_}) for sort keys %LOCAL;
	print "wrote ".scalar(keys %LOCAL)." local_config_values\n";

	$dbh->commit();
	$dbh->disconnect();
	print "wrote $PROJ\n";

	store($INSTALLER_CONFIG,$ICFG) or die "cannot write $ICFG: $!\n";
	print "wrote $ICFG\n";

	writeIconBundle();
}


sub setVersion
	# Rewrite version_major/minor/release in an EXISTING project, leaving
	# everything else -- including version_build and everything Cava has
	# written since -- exactly as it was.
	#
	# CAVA MUST BE CLOSED.  It is single instance and holds the SQLite file
	# open; worse, it writes the whole project back on exit, so a version
	# set underneath a running Cava is silently reverted the moment the
	# packager is shut down.  Nothing here can detect that, which is why it
	# is said out loud.
{
	my ($version) = @_;
	my ($major,$minor,$release) = $version =~ /^(\d+)\.(\d+)\.(\d+)$/;

	die "no project at $PROJ - run without --version to create it\n"
		if !-f $PROJ;

	my $dbh = DBI->connect("dbi:SQLite:dbname=$PROJ","","",
		{ RaiseError => 1, PrintError => 0, AutoCommit => 0 });

	my $was = join('.',map {
			$dbh->selectrow_array(
				"SELECT config_value FROM config_values WHERE config_name = ?",
				undef,$_)
		} qw( version_major version_minor version_release ));

	my $sth = $dbh->prepare(
		"UPDATE config_values SET config_value = ? WHERE config_name = ?");
	$sth->execute($major,'version_major');
	$sth->execute($minor,'version_minor');
	$sth->execute($release,'version_release');

	$dbh->commit();
	$dbh->disconnect();

	print "version $was -> $version\n";
	print "the installer will be named chartMaker-msw-x86-".
		join('-',$major,$minor,$release).".exe\n";
	print "\nCava must have been CLOSED when this ran - it rewrites the\n";
	print "project on exit and would put the old version back.\n";
}


sub writeIconBundle
	# THE ICONS CAVA STAMPS INTO THE EXECUTABLES.  It keeps them zipped,
	# one flat 'iconresource/' folder inside cava20/iconresource.zip, and
	# an executable row names one by leaf name.
	#
	# THE .ico FILES THEMSELVES LIVE IN THE APPLICATION REPO, in
	# _installer/icons, and this zip is built from them.  That is the
	# opposite of navMate, whose zip is the only copy and is untracked -
	# so navMate's icons are not in any repository at all.  Here the art is
	# tracked with the source that it belongs to and the bundle is
	# regenerable, which is what the .gitignore assumes.
{
	my $src = "$APP_DIR/_installer/icons";
	my $zip_path = "$DIST/cava20/iconresource.zip";
	my @icons = ('chartMaker.ico','chartMakerGrey.ico');

	my $zip = Archive::Zip->new();
	$zip->addDirectory('iconresource/');
	for my $ico (@icons)
	{
		die "missing icon $src/$ico\n" if !-f "$src/$ico";
		my $member = $zip->addFile("$src/$ico","iconresource/$ico");
		die "cannot add $ico to the icon bundle\n" if !$member;
	}
	die "cannot write $zip_path\n"
		if $zip->writeToFileNamed($zip_path) != AZ_OK;
	print "wrote $zip_path (".scalar(@icons)." icons)\n";
}

main();

1;
