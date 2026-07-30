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
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use Pub::WX::Main;

use cm_defs;
use cm_prefs;
use cm_utils;
use dm_set;
use dm_source;
use dm_region;
use em_command;
use em_server;
use if ($^O eq 'MSWin32'), 'em_console';
use w_resources;
use w_ini;
use w_frame;

use base 'Wx::App';

setStandardTempDir($appName);
setStandardDataDir($appName);
$ini_file = "$temp_dir/$appName.ini";
init_prefs();


#---------------------------------
# main
#---------------------------------

display(0,0,"$appName.pm initializing");
display(0,1,"data_dir = $data_dir");
display(0,1,"temp_dir = $temp_dir");

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

# THE SET REMEMBERED IN THE INI IS OPENED AS THE DOCUMENT, which is what
# makes starting the application the same thing as opening what you had
# open.  Nothing is written by this: openSet reads, and only Save writes.

openSet(getActiveSet());

my $console = is_win() ? em_console->new(\&em_command::dispatchCommand) : undef;

em_server::startServer();

$console->start() if $console;

display(0,0,"starting app");

my $frame;

sub OnInit
{
	$frame = w_frame->new();
	if (!$frame)
	{
		error("unable to create frame");
		return undef;
	}
	$frame->Show(1);
	display(0,0,"$$resources{app_title} started");
	return 1;
}

my $app = chartMaker->new();
Pub::WX::Main::run($app);

display(0,0,"ending $appName.pm");
$frame->DESTROY() if $frame;
$frame = undef;


1;
