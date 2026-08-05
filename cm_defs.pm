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
		$WIN_PROBE

		$COMMAND_OPEN_MAP
		$COMMAND_SET_OPEN
		$COMMAND_SET_SAVE
		$COMMAND_SET_SAVEAS
		$COMMAND_SET_REVERT
		$COMMAND_SET_CLOSE
		$COMMAND_SET_NEW
		$COMMAND_NEW_REGION
		$COMMAND_NEW_SOURCE
		$COMMAND_CATALOG
		$COMMAND_KEYS
		$COMMAND_PREFS
		$COMMAND_BUILD_RCT
		$COMMAND_BUILD_MBTILES
		$COMMAND_FETCH
		$COMMAND_PROBE
	);
}


our $appName = 'chartMaker';

# Identifies the application to tile servers in dm_fetch's User-Agent.
# A client that fetches systematically should say who it is.

our $appVersion = '0.1';

our $app_dir = $^O eq 'MSWin32' ?
	'C:\base\apps\chartMaker' :
	'/base/apps/chartMaker';


# THE OFFICIAL DEFAULT TSD.  When nothing has been selected, or what was
# selected is gone, this is what the map opens on.
#
# It is the Landsat WELD global annual mosaic, and it beats the other
# shipped source (Blue Marble) for two reasons that are about what this
# application is FOR.  Blue Marble reaches z8, which is BELOW the overview
# floor a conventional build uses, so it cannot participate in a
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

# THE PROBE'S RESULTS ARE A PANE, not a floating frame.  A frame came up
# behind the application and the only cure for that is 'always on top'.  A
# pane is docked, torn off or shut by the user, which is where that decision
# belongs -- and docked beside the tree it can be read against the map, which
# is the whole reason to look at it.
#
# It is NOT in the View menu, for the reason the Regions pane is not: it is
# the view of the probe MODE, and there is no such thing as opening it over a
# mode nobody entered.  Right-clicking a node opens it; closing it ends the
# mode.

our $WIN_PROBE			= 10003;

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

# A SOURCE IS NOT PART OF THE DOCUMENT, so this is not beside the set
# commands above and does not care whether a set is open.  A TSD is the
# user's own material, independent of any region set, and a first run has
# to be able to write one before there is anything to point it at.

our $COMMAND_NEW_SOURCE	= 10033;

# THE CATALOG SITS BESIDE New Source AND NOT IN THE FILE MENU, because it
# is the other way of arriving at the same act.  One writes a definition
# from nothing and the other writes it from something already known, and
# separating them by a whole menu would hide the second from anybody who
# had found the first.

our $COMMAND_CATALOG	= 10034;

# THE KEY STORE SITS WITH THEM, and in the Edit menu rather than under
# Preferences, because a key_value is USER MATERIAL and not a setting.  A
# preference changes how the application behaves; a key is a thing the user
# obtained from somebody else and without which a source they installed
# does nothing at all.  The FOLDER it lives in is the preference.

our $COMMAND_KEYS		= 10035;

# Preferences is a VIEW menu item rather than a File one, because nothing
# it changes is part of the document.

our $COMMAND_PREFS		= 10032;

# BUILD IS ITS OWN MENU.  It is not a View (it changes nothing on screen)
# and not a File operation on the document (it reads the document and
# writes something else entirely) -- it is the thing the application
# exists to do, and burying it under one of the others would say
# otherwise.

our $COMMAND_BUILD_RCT		= 10041;
our $COMMAND_FETCH			= 10042;
our $COMMAND_BUILD_MBTILES	= 10043;

# PROBE BELONGS BESIDE THEM because it is the same kind of act - it walks
# the working set, goes to the network and takes real time - and it is the
# one you run FIRST, before deciding the zmax the other three build to.

our $COMMAND_PROBE			= 10044;


1;
