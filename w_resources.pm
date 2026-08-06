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
#
# AND THEN THE TWO THINGS THAT ARE NOBODY'S DOCUMENT, below a separator:
# the key store and the cleanup.  Neither belongs to the open set, both act
# on the user's own material on this machine, and the File menu is where
# somebody looks first for something they cannot otherwise find.

my @file_menu = (
	$COMMAND_SET_OPEN,
	$COMMAND_SET_NEW,
	$ID_SEPARATOR,
	$COMMAND_SET_SAVE,
	$COMMAND_SET_SAVEAS,
	$COMMAND_SET_REVERT,
	$ID_SEPARATOR,
	$COMMAND_SET_CLOSE,
	$ID_SEPARATOR,
	$COMMAND_KEYS,
	$COMMAND_CLEAN );


# Creating a region needs somewhere to put it and something to show it in,
# so it lives here and is enabled only when both are true.

my @edit_menu = (
	$COMMAND_NEW_REGION,
	$ID_SEPARATOR,
	$COMMAND_NEW_SOURCE,
	$COMMAND_CATALOG );


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
# also refuses nothing, because it writes no output: a source that cannot
# carry to an RCT can still legitimately have its tiles fetched.

# PROBE IS NOT HERE, and was.  It is reached by right-clicking the node to
# probe, in the tree or on the map, because the gesture is what says where
# to look - a menu item would have to ask for an area it was never told,
# and that answer could disagree with what the user was pointing at.
#
# NOR IS THE PROBE PANE IN THE VIEW MENU, for the reason the Regions pane is
# not: it is the view of a MODE rather than a thing to be shown and hidden on
# its own.  Opening it over a mode nobody entered would show an empty table
# with a Halt button for a run that never started.

my @build_menu = (
	$COMMAND_FETCH,
	$ID_SEPARATOR,
	$COMMAND_BUILD_RCT,
	$COMMAND_BUILD_MBTILES );


# THE HELP MENU.  The manual, the way to put the shipped material back,
# and the version - three answers to "what is this and how do I use it",
# which is the one menu a user looks in without being told to.
#
# REGENERATE SITS BETWEEN THEM DELIBERATELY.  The manual walks a reader
# through opening the example set and changing it, so the way back belongs
# next to the manual that told them to do it.

my @help_menu = (
	$COMMAND_HELP_MANUAL,
	$COMMAND_REGEN_EXAMPLES,
	$ID_SEPARATOR,
	$COMMAND_ABOUT );


my @main_menu = (
	'file_menu,&File',
	'edit_menu,&Edit',
	'view_menu,&View',
	'build_menu,&Build',
	'help_menu,&Help' );


my $command_data = {
	%{$resources->{command_data}},
	$WIN_REGIONS		=> ['Regions',		'The regions of the open set'],
	$WIN_SOURCES		=> ['Sources',		'Show the tile source definitions'],
	$WIN_PROBE			=> ['Probe',		'What the probe found, level by level'],
	$COMMAND_OPEN_MAP	=> ['Map',			'Open the Leaflet map in a browser'],
	$COMMAND_SET_OPEN	=> ['Open Set...',	'Open a region set'],
	$COMMAND_SET_NEW	=> ['New Set...',	'Create an empty region set and open it'],
	$COMMAND_SET_SAVE	=> ['Save',			'Write the open set to disk'],
	$COMMAND_SET_SAVEAS	=> ['Save As...',	'Write it to a new set and continue there'],
	$COMMAND_SET_REVERT	=> ['Revert',		'Throw away every unsaved change and re-read the folder'],
	$COMMAND_SET_CLOSE	=> ['Close',		'Close the open set'],
	$COMMAND_NEW_REGION	=> ['New Region...','Create a region in the open set'],
	$COMMAND_NEW_SOURCE	=> ['New Source...','Write a new tile source definition'],
	$COMMAND_CATALOG	=> ['Tile Source Catalog...',
		'The tile services chartMaker knows about, and creating sources from them'],
	$COMMAND_KEYS		=> ['Key Store...',
		'Values for the {key_names} that source urls contain'],
	$COMMAND_CLEAN		=> ['Clean Up Caches...',
		'What is cached, what still uses it, and removing what nothing does'],
	$COMMAND_PREFS		=> ['Preferences...','Folders, the map, and what a new region starts with'],
	$COMMAND_FETCH		=> ['Fetch Tiles',	'Fill the cache with every tile the build will read'],
	$COMMAND_BUILD_RCT	=> ['Build RCT','Fetch, then write the set as .rct files'],
	$COMMAND_BUILD_MBTILES => ['Build MBTiles',
		'Fetch, then write the set as .mbtiles charts - one per detail area'],
	$COMMAND_HELP_MANUAL	=> ['User Manual',
		'Open the chartMaker User Manual on GitHub in your web browser'],
	# NOT 'Regenerate Examples...', which is what this said and which cost
	# an evening: with every .tsd deleted and the map grey, its own author
	# went to File Explorer to copy the files back rather than to this
	# menu item, because 'examples' reads as tutorial data and what was
	# wanted was the IMAGERY.  The hint below was right the whole time; the
	# label was the part being read.

	$COMMAND_REGEN_EXAMPLES	=> ['Restore Shipped Sources and Examples...',
		'Put back the sources and the example region set that ship with the application'],
	$COMMAND_ABOUT			=> ['About chartMaker',
		'The version, and a link to the project'],
};


$resources = { %$resources,
	app_title		=> $appName,
	command_data	=> $command_data,
	main_menu		=> \@main_menu,
	file_menu		=> \@file_menu,
	edit_menu		=> \@edit_menu,
	view_menu		=> \@view_menu,
	build_menu		=> \@build_menu,
	help_menu		=> \@help_menu,
};


1;
