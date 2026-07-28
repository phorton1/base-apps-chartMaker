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


my @view_menu = (
	$COMMAND_OPEN_MAP,
	$ID_SEPARATOR,
	$CLOSE_ALL_PANES,
	$CLOSE_OTHER_PANES );


my @main_menu = (
	'view_menu,&View' );


my $command_data = {
	%{$resources->{command_data}},
	$COMMAND_OPEN_MAP	=> ['Map',	'Open the Leaflet map in a browser'],
};


$resources = { %$resources,
	app_title		=> $appName,
	command_data	=> $command_data,
	main_menu		=> \@main_menu,
	view_menu		=> \@view_menu,
};


1;
