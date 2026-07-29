#!/usr/bin/perl
#---------------------------------------------
# cm_defs.pm
#---------------------------------------------
# chartMaker foundational constants.  Depends on nothing but Pub::.
#
# $appName lives HERE rather than in w_resources.pm (where navMate keeps
# its equivalent) because chartMaker.pm needs it to establish the standard
# directories before any wx module has been compiled.

package cm_defs;
use strict;
use warnings;
use threads;
use threads::shared;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appName
		$appVersion
		$app_dir
		$RASTER_DIR

		$WIN_REGIONS
		$WIN_SOURCES
		$COMMAND_OPEN_MAP
	);
}


our $appName = 'chartMaker';

# Identifies the application to tile servers in dm_fetch's User-Agent.
# A client that fetches systematically should say who it is.

our $appVersion = '0.1';

our $app_dir = $^O eq 'MSWin32' ?
	'C:\dat\openCPN\chartMaker' :
	'/dat/openCPN/chartMaker';

# Where the .rct exporter writes a card.  THE FOLDER IS THE CARD: the
# renderer enumerates it and merges every .rct it finds, so there is no
# manifest and any subset of the files is a valid set.
#
# TWO DIFFERENT FACTS SHARE THE NAME 'RASTER' AND SHOULD NOT BE CONFUSED.
# On the CF card the spec requires a single outer folder called \RASTER\
# holding exactly one region set - that is the consumer's contract.  What
# the folder is called on THIS machine is a local convenience, and its
# current name and location are a vestige of the old chartMaker rather
# than anything the format asks for.  The copy to the card is what bridges
# them, and it is the same producer-side/consumer-side seam as the 8.3
# short name.
#
# A constant for now.  It wants to become one folder per region set -
# something like $data_dir/RCT_REGIONS/<set> - once sets are folders,
# which is a natural upgrade rather than a rewrite, and it must not
# survive into the installed product as a hardcoded path.

our $RASTER_DIR = $^O eq 'MSWin32' ?
	'C:/dat/openCPN/RASTER' :
	'/dat/openCPN/RASTER';


#---------------------------------------------
# command and window ids
#---------------------------------------------
# Pub::WX reserves everything below 200 for system use.
# chartMaker uses the 10000 range, as navMate does.

# Panes are 10001..10019, plain commands from 10020.

our $WIN_REGIONS		= 10001;
our $WIN_SOURCES		= 10002;

our $COMMAND_OPEN_MAP	= 10021;


1;
