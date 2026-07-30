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
		$DEFAULT_SOURCE_ID
		$SOURCE_INHERITED

		$WIN_REGIONS
		$WIN_SOURCES

		$COMMAND_OPEN_MAP
		$COMMAND_SET_OPEN
		$COMMAND_SET_SAVE
		$COMMAND_SET_SAVEAS
		$COMMAND_SET_REVERT
		$COMMAND_SET_CLOSE
		$COMMAND_SET_NEW
		$COMMAND_NEW_REGION
		$COMMAND_PREFS
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

# THE SOURCE A REGION DID NOT CHOOSE.  A region or subregion names the
# source it is to be built from; this is the value meaning "not my
# decision", and it is what everything is created with, so adding the
# field changed no existing behaviour.
#
# It resolves DOWNWARD: a subregion inherits its parent's answer, and a
# region that inherits falls through to whatever source the application
# would use anyway.  A chain of inheritance therefore always terminates,
# which is the property that lets the field be optional.
#
# It is a RESERVED SOURCE ID, not a separate kind of value, so one string
# field holds both answers and no reader has to test two things.  A TSD
# claiming this id is refused at load - see dm_source - because a real
# source called 'inherited' would silently become unreachable.

our $SOURCE_INHERITED = 'inherited';


#---------------------------------------------
# command and window ids
#---------------------------------------------
# Pub::WX reserves everything below 200 for system use.
# chartMaker uses the 10000 range, as navMate does.

# Panes are 10001..10019, plain commands from 10020.

our $WIN_REGIONS		= 10001;
our $WIN_SOURCES		= 10002;

our $COMMAND_OPEN_MAP	= 10021;

# THE DOCUMENT'S OWN COMMANDS.  A region set is opened, saved and closed
# like any other document, so these are a File menu rather than anything
# chartMaker invented.

our $COMMAND_SET_OPEN	= 10022;
our $COMMAND_SET_SAVE	= 10023;
our $COMMAND_SET_SAVEAS	= 10024;
our $COMMAND_SET_REVERT	= 10027;
our $COMMAND_SET_CLOSE	= 10025;
our $COMMAND_SET_NEW	= 10026;

our $COMMAND_NEW_REGION	= 10031;

# Preferences is a VIEW menu item rather than a File one, because nothing
# it changes is part of the document.

our $COMMAND_PREFS		= 10032;


1;
