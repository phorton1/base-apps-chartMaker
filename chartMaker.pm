#!/usr/bin/perl
#---------------------------------------------
# chartMaker.pm
#---------------------------------------------
# The chartMaker application entry point.
#
# Brings up the three UX surfaces that everything else is built on:
#
#	the console	 - em_console.pm reading keystrokes, em_command.pm dispatching
#	the wx frame - w_frame.pm, an empty notebook and a View menu
#	the map		 - em_server.pm serving the Leaflet applet from _res/site
#
# Run it from a cmd.exe window:  perl chartMaker.pm

package chartMaker;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw( wxOK wxICON_EXCLAMATION );
	# The only wx this file needs: the two startup failures are reported
	# here because here is where wx is alive and the frame is not.
use Pub::Utils;
use Pub::SingleInstance;
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use Pub::WX::Main;

use cm_defs;
use cm_prefs;
use cm_utils;
use dm_set;
use dm_source;
use dm_region;
use dm_observe;
use dm_engine;
use em_command;
use em_server;
use em_console;
use w_resources;
use w_ini;
use w_frame;

use base 'Wx::App';

setStandardTempDir($appName);
setStandardDataDir($appName);

# A NAMED PROFILE MOVES BOTH ROOTS, and it is one more environment-keyed
# default rather than a development-only path -- it behaves identically in
# a packaged build, which is the rule Deployment states.
#
# BOTH roots move, and $temp_dir is the one that is easy to forget.  It
# holds the ini (the pane layout, the active set, the display source), the
# single-instance lock and the observation records, so a profile sharing it
# would fight the ordinary copy for all three.  Moving it is what lets two
# profiles run AT THE SAME TIME.
#
# The port must differ, since two instances cannot bind one, and a profile
# that wants the ordinary cache says so -- both are ordinary preferences in
# the profile's own chartMaker.prefs, so neither needs anything here.

my $profile = $ENV{CHARTMAKER_PROFILE} || '';
if ($profile ne '')
{
	$profile =~ s/[^A-Za-z0-9_-]//g;
	if ($profile ne '')
	{
		$data_dir .= ".$profile";
		$temp_dir .= ".$profile";
		my_mkdir($data_dir) if !-d $data_dir;
		my_mkdir($temp_dir) if !-d $temp_dir;
	}
}

$ini_file = "$temp_dir/$appName.ini";
init_prefs();


#---------------------------------
# main
#---------------------------------

display(0,0,"$appName.pm initializing");
display(0,1,"data_dir = $data_dir");
display(0,1,"temp_dir = $temp_dir");

# ONE COPY AT A TIME, AND THE CHECK COMES BEFORE ANYTHING COSTLY.
#
# A second instance is refused rather than warned about, because the two
# would fight over things nothing here arbitrates: one HTTP port, one ini
# holding the selections, and one cache being written by two processes
# that each believe they are alone.
#
# IT IS CHECKED HERE AND REPORTED IN OnInit, which is the awkward part and
# is not avoidable: this is the right MOMENT to find out - before twelve
# threads are spawned and a port is bound - and the wrong moment to say
# so, because wx is not alive yet and a dialog needs it.  So the answer is
# carried forward a few lines and the frame is never built.
#
# KEYED THROUGH $temp_dir, so a development copy and an installed copy are
# different instances and may run together.  They already resolve to
# different roots, so this needs no rule of its own.

my $single_ok = takeSingleInstance($appName,{ quiet => 1 });
my $server_state = 'not started';

if ($single_ok)
{

# THE INI IS READ BEFORE ANYTHING IS SCANNED.  Pub::WX::Frame reads the
# config file itself, but not until the frame is constructed, which is
# long after the model has been loaded and the server has started.  The
# selections are needed first -- which region set to load is the whole
# question -- so the config is read here explicitly.  Reading it twice is
# harmless; it is a file of lines and nothing has written to it yet.

Pub::WX::AppConfig::initialize();
readIniSelections();

# Sets, then sources, then regions -- and all three BEFORE the server
# starts, so that the threads it spawns inherit them.  Regions are last
# because which folder they come from is a property of the active set.
# A later rescan reaches the server threads through each module's shared
# generation counter.

loadSets();
loadSources();

# WHAT THIS MACHINE HAS LEARNED ABOUT EACH SERVER, read here for the same
# reason the sets and sources are: the server threads inherit it when they
# are spawned, and a preflight run before the first fetch should be able to
# quote a time from what the last run measured.

obsLoad();

# THE POOL IS SPAWNED HERE AND NOWHERE ELSE, and the position in this file
# is the whole reason it is a pool at all.  ithreads CLONE THE INTERPRETER
# at spawn: measured on this machine, a thread costs 5 ms against a small
# interpreter and 44 ms once ~20 MB is loaded.  Spawning before wx exists
# and before the server threads start is therefore nine times cheaper than
# spawning on demand inside a build, and it does not get worse as the
# session goes on.
#
# It is also why MAX_CONCURRENT requires a restart, which the preferences
# dialog says.

engineStart();

# THE SET REMEMBERED IN THE INI IS OPENED AS THE DOCUMENT, which is what
# makes starting the application the same thing as opening what you had
# open.  Nothing is written by this: openSet reads, and only Save writes.

openSet(getActiveSet());

# AND THEN WHICH OF ITS REGIONS WERE HIDDEN, which has to be after the open
# rather than with the rest of the ini: the list is keyed by the OPEN set,
# and until the line above there is not one.

applyIniUnchecked();

# THE CONSOLE IS COMPILED IN ALWAYS AND STARTED ONLY WHERE THERE IS ONE.
#
# Two executables are built from this one source: a console-bearing one
# under perl and a windowed one under wperl.  They are the same program and
# there is no packaged-only code path, so em_console is an ordinary
# unconditional use - which is also the only form a static packaging scan
# can see.
#
# WHAT DIFFERS IS THE RUN AND NOT THE BUILD.  Under wperl there is no
# console to read, and constructing the reader there gets as far as
# reporting that it could not open one, to nobody.  IsGUI() is true in
# exactly that executable and false everywhere else, including a
# development run, which keeps its console.

my $console = Cava::Packager::IsGUI() ?
	undef :
	em_console->new(\&em_command::dispatchCommand);

em_server::startServer();

# WHETHER THE PORT WAS ACTUALLY THERE, asked here because start() cannot
# answer it: the bind happens on the server thread, after start() has
# returned.  The thread records the outcome and this waits the few
# milliseconds it takes to resolve - see Pub::HTTP::ServerBase.
#
# NOT FATAL.  Without the server there is no map, no tile proxy and no
# /api, but the whole wx side still works: the region tree, editing,
# preferences, and a build from what is already cached.  So it is reported
# and the application carries on.

$server_state = em_server::serverState();
warning(0,0,"the http server did not start - $server_state")
	if $server_state =~ /^failed/;

$console->start() if $console;

display(0,0,"starting app");

}	# if ($single_ok)


my $frame;

sub OnInit
{
	# THE REFUSAL IS REPORTED HERE BECAUSE HERE IS WHERE WX IS ALIVE, and
	# the frame is then never built.
	#
	# IT EXITS RATHER THAN RETURNING FALSE, and that is not a shortcut.
	# Returning false makes wx complain that OnInit must return true, which
	# Error.pm turns into a catchable exception - and Pub::WX::Main::run
	# catches it, shows its own Exception Dialog, and does
	# 'goto AFTER_EXCEPTION', which re-enters MainLoop.  The result is a
	# process that will not die and a second dialog nobody asked for.
	# Observed exactly that.  Nothing has been loaded or started at this
	# point, so there is nothing an orderly shutdown would have to do.

	if (!$single_ok)
	{
		my $dlg = Wx::MessageDialog->new(undef,
			"Only one instance of $appName may run at a time.",
			$appName,
			wxOK | wxICON_EXCLAMATION);
		$dlg->ShowModal();
		$dlg->Destroy();
		display(0,0,"$appName: refusing to start a second instance");
		exit(0);
	}

	$frame = w_frame->new();
	if (!$frame)
	{
		error("unable to create frame");
		return undef;
	}
	$frame->Show(1);
	display(0,0,"$$resources{app_title} started");

	# AFTER Show(1), DELIBERATELY.  The application works without a server
	# and the user should see it working before being told what is missing
	# - a modal thrown up over a blank screen reads as "it failed to
	# start", which is precisely what did not happen.

	if ($server_state =~ /^failed/)
	{
		my $port = getPref($PREF_HTTP_PORT);
		my $dlg = Wx::MessageDialog->new($frame,
			"The map could not be started.\n\n".
			"$appName could not open port $port:\n$server_state\n\n".
			"Everything else works - regions, editing, preferences, and ".
			"building from tiles already in the cache. Only the map, the ".
			"tile proxy and the web API are unavailable.\n\n".
			"This usually means another program is using the port. It can ".
			"be changed in Preferences.",
			"No map",
			wxOK | wxICON_EXCLAMATION);
		$dlg->ShowModal();
		$dlg->Destroy();
	}

	return 1;
}

my $app = chartMaker->new();
Pub::WX::Main::run($app);

display(0,0,"ending $appName.pm");

# NOTHING IS TORN DOWN THAT WAS NEVER SET UP.  A refused second instance
# reaches here having loaded nothing, spawned nothing and bound nothing,
# and flushing an observation record it never read would write an empty
# one over the real one.

if ($single_ok)
{
	# THE LAST CHECKPOINT.  Browsing has no end, so whatever the clock has
	# not yet written is written here - and this is the only flush that
	# matters to a session that never built anything and only moved around
	# the map.

	obsFlushAll();

	# THE POOL IS DRAINED BEFORE ANYTHING ELSE IS TORN DOWN.  A worker
	# holding a socket when the interpreter goes away is how a clean exit
	# becomes a crash dialog, and this is the one place that can be sure
	# nothing is still asking for tiles.

	engineStop();
}

$frame->DESTROY() if $frame;
$frame = undef;

# The lock would be released by the operating system anyway, which is the
# whole reason it is a lock rather than a pid file.  Doing it explicitly
# just means the file stops claiming this pid a moment earlier.

releaseSingleInstance();


1;
