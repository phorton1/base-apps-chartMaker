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
		$DEFAULT_SOURCE_ID

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


# THE OFFICIAL DEFAULT TSD.  When nothing has been selected, or what was
# selected is gone, this is what the map opens on.
#
# It is the Landsat WELD global annual mosaic, and it beats the other
# shipped source (Blue Marble) for two reasons that are about what this
# application is FOR.  Blue Marble reaches z8, which is BELOW the overview
# floor a conventional card is built at, so it cannot participate in a
# build at all.  WELD reaches z12, and where WELD has no data is the open
# ocean -- it covers coastlines, which is the only place aerial raster
# charting means anything.  "Not truly global" is a non-cost when the
# missing part is the middle of the Pacific.
#
# A PREFERENCE, NOT A REQUIREMENT.  Sources are found by scanning, so this
# id may name nothing; whoever resolves it falls through to the first
# source in tree order.  The alternative of a 'default' flag inside a TSD
# was rejected: two files could claim it and it would need this same
# tiebreak anyway.

our $DEFAULT_SOURCE_ID = 'gibs_weld_annual';

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
# THE BASE, not the output folder.  Sets are folders now, so a build
# writes to $RASTER_DIR/<set> and it is THAT folder you copy to the
# card -- which makes the copy a copy rather than a decision about which
# .rct files belong together.
#
# The base itself is still a hardcoded path and must not survive into the
# installed product as one; it wants to move under $data_dir (something
# like $data_dir/RCT_REGIONS) rather than sit at the root of a drive.

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
