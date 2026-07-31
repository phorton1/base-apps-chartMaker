#!/usr/bin/perl
#---------------------------------------------
# w_resources.pm
#---------------------------------------------
# chartMaker's wx resources -- the application title, the command data
# (menu labels and hints), and the menus themselves.
#
# Merges into the $resources hash that Pub::WX::Resources defines.  The
# base already supplies Close All / Close Others in its view_menu; those
# are appended here after a separator.

package w_resources;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Resources;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$resources
	);
}


# THE FILE MENU IS THE REGION SET.  A set is the document this
# application edits - opened, saved and closed - and the Regions window is
# its view rather than something to be shown and hidden on its own, which
# is why it is not in the View menu.

my @file_menu = (
	$COMMAND_SET_OPEN,
	$COMMAND_SET_NEW,
	$ID_SEPARATOR,
	$COMMAND_SET_SAVE,
	$COMMAND_SET_SAVEAS,
	$COMMAND_SET_REVERT,
	$ID_SEPARATOR,
	$COMMAND_SET_CLOSE );


# Creating a region needs somewhere to put it and something to show it in,
# so it lives here and is enabled only when both are true.

my @edit_menu = (
	$COMMAND_NEW_REGION );


my @view_menu = (
	$WIN_SOURCES,
	$COMMAND_OPEN_MAP,
	$ID_SEPARATOR,
	$CLOSE_ALL_PANES,
	$CLOSE_OTHER_PANES,
	$ID_SEPARATOR,
	$COMMAND_PREFS );


# BUILD IS ITS OWN MENU, with Fetch above it.
#
# The two are one act and two acts at once.  Build fetches everything it
# needs, so Fetch is never REQUIRED -- but it is the half that takes the
# hour, and being able to run it on its own is what lets an author fill a
# region overnight and build in a minute the next morning.  Fetch alone
# also refuses nothing, because it writes no card: a source that cannot
# carry to an RCT can still legitimately have its tiles fetched.

my @build_menu = (
	$COMMAND_FETCH,
	$ID_SEPARATOR,
	$COMMAND_BUILD_RCT,
	$COMMAND_BUILD_MBTILES );


my @main_menu = (
	'file_menu,&File',
	'edit_menu,&Edit',
	'view_menu,&View',
	'build_menu,&Build' );


my $command_data = {
	%{$resources->{command_data}},
	$WIN_REGIONS		=> ['Regions',		'The regions of the open set'],
	$WIN_SOURCES		=> ['Sources',		'Show the tile source definitions'],
	$COMMAND_OPEN_MAP	=> ['Map',			'Open the Leaflet map in a browser'],
	$COMMAND_SET_OPEN	=> ['Open Set...',	'Open a region set'],
	$COMMAND_SET_NEW	=> ['New Set...',	'Create an empty region set and open it'],
	$COMMAND_SET_SAVE	=> ['Save',			'Write the open set to disk'],
	$COMMAND_SET_SAVEAS	=> ['Save As...',	'Write it to a new set and continue there'],
	$COMMAND_SET_REVERT	=> ['Revert',		'Throw away every unsaved change and re-read the folder'],
	$COMMAND_SET_CLOSE	=> ['Close',		'Close the open set'],
	$COMMAND_NEW_REGION	=> ['New Region...','Create a region in the open set'],
	$COMMAND_PREFS		=> ['Preferences...','Folders, the map, and what a new region starts with'],
	$COMMAND_FETCH		=> ['Fetch Tiles',	'Fill the cache with every tile the build will read'],
	$COMMAND_BUILD_RCT	=> ['Build RCT Card','Fetch, then write the set as .rct card files'],
	$COMMAND_BUILD_MBTILES => ['Build MBTiles',
		'Fetch, then write the set as .mbtiles charts - one per detail area'],
};


$resources = { %$resources,
	app_title		=> $appName,
	command_data	=> $command_data,
	main_menu		=> \@main_menu,
	file_menu		=> \@file_menu,
	edit_menu		=> \@edit_menu,
	view_menu		=> \@view_menu,
	build_menu		=> \@build_menu,
};


1;
