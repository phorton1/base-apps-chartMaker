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
		$DEFAULT_VIEW_SOURCE_ID
		$DEFAULT_BUILD_SOURCE_ID
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
		$COMMAND_CLEAN
		$COMMAND_PREFS
		$COMMAND_BUILD_RCT
		$COMMAND_BUILD_MBTILES
		$COMMAND_FETCH
		$COMMAND_PROBE
		$COMMAND_HELP_MANUAL
		$COMMAND_REGEN_EXAMPLES
		$COMMAND_ABOUT
		$USER_MANUAL_URL
		$REPO_URL
	);
}


our $appName = 'chartMaker';

# THE VERSION A RUN FROM SOURCE HAS.  A packaged build carries the real
# number in its version resource, stamped there by the packager, and
# cm_utils::appVersion() prefers that; this is the fallback for everything
# else, and the only version a development copy can honestly claim.
#
# IT IS NOT READ DIRECTLY.  Everything that shows or sends a version calls
# appVersion(), which is what keeps the About box and the User-Agent from
# disagreeing.  See cm_utils.

our $appVersion = '0.1.0';

our $app_dir = $^O eq 'MSWin32' ?
	'C:\base\apps\chartMaker' :
	'/base/apps/chartMaker';


# TWO DEFAULTS, BECAUSE THEY ANSWER TWO DIFFERENT QUESTIONS, and one
# constant answering both was wrong in a way that only showed on a first
# run: what the MAP OPENS ON, and what a NEW REGION IS BORN NAMING.
#
# They pull in opposite directions.  The map should open on imagery a
# newcomer recognises anywhere in the world, which is a global viewer.  A
# region must name something that can BUILD, which a global viewer is not
# - both of the ones shipped here are display-only by their operators'
# terms.  Held in one constant, satisfying either broke the other:
# whichever way it was set, the application either opened on a blank
# ocean somewhere or created regions naming a source no build could read.
#
# THE MAP OPENS ON ESRI.  It has imagery everywhere, so wherever the user
# first looks there is something there, and a first run should not depend
# on happening to live in one of two countries.  It is display-only and
# that is fine: nothing is built from what the map is showing.
#
# It is also why this is NOT the answer to the second question.  A region
# born naming esri would name a source that fails at the only moment it
# matters, hours into a build.

our $DEFAULT_VIEW_SOURCE_ID = 'esri_world_imagery';

# THE SOURCE A NEW REGION IS BORN NAMING, and everything below is about
# this one.
#
# IT MUST BE ONE THAT CAN BUILD.  Two of the four shipped files are
# display-only by their operators' terms, so a new region born naming either
# of them would name something no build could ever read.  That narrows it to
# the two national orthophoto services, and between those it is decided by
# what a FIRST chartset looks like.
#
# SPAIN, BECAUSE OF WHAT EACH ONE DOES WHERE IT STOPS.  Both are national
# land products whose coverage reaches about one z15 tile past the shore,
# and neither footprint follows a tile boundary, so both leave partly filled
# tiles all along their edge.  What they fill them WITH is the whole
# difference.  IGN France sends flat white - the brightest thing on a
# composited chart, glaring against the imagery beside it, and impossible to
# trim because a partial tile is unique bytes that no fingerprint can catch.
# Spain sends its upsampled global backdrop, which over water is a dark blue
# that simply reads as water.  A first build wants the forgiving edge.
#
# Spain also measures deeper where it matters: real detail flat at about 4.0
# from z14 through z18 over north Ibiza, against a declared z20.
#
# IGN FRANCE STILL SHIPS, AND IS STILL THE ANSWER OVER FRENCH WATER -
# including the overseas departments, where nothing else open reaches chart
# depth at all.  This decides which imagery a NEW REGION is born naming; it
# is not a ranking of the two.
#
# BOTH REPLACED THE LANDSAT WELD MOSAIC, which was global and buildable but
# only to z12.  That combination read well and meant little: z12 is far
# below anything worth carrying to sea, so nothing was ever going to be
# built from it.  A default that can produce a real chartset somewhere
# beats one that can produce a useless chartset anywhere.
#
# A PREFERENCE, NOT A REQUIREMENT.  Sources are found by scanning, so this
# id may name nothing; whoever resolves it falls through to the first
# source in tree order.  The alternative of a 'default' flag inside a TSD
# was rejected: two files could claim it and it would need this same
# tiebreak anyway.
#
# THIS ONE IS EXPECTED TO GO.  It exists because a region is currently
# born with a source already chosen for it, guessed from what the map
# happens to be showing.  Once a region can be created with NO source and
# the user names one when the program first needs it, nothing has to guess
# and there is nothing left for this to answer.

our $DEFAULT_BUILD_SOURCE_ID = 'ign_es_pnoa';

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

# THE KEY STORE IS NOT UNDER PREFERENCES, because a key_value is USER
# MATERIAL and not a setting.  A preference changes how the application
# behaves; a key is a thing the user obtained from somebody else and
# without which a source they installed does nothing at all.  The FOLDER it
# lives in is the preference.
#
# It is in the FILE menu, with the cleanup below it.  Both are about the
# user's own material on this machine rather than about the open document,
# and the File menu is the first place anybody looks for a thing they
# cannot otherwise find.

our $COMMAND_KEYS		= 10035;

# CLEANING UP IS NOT AN EDIT AND NOT A BUILD.  It acts on what earlier
# builds and browsing left behind - caches with no source, sources no
# region names, blanks cached before anybody knew they were blanks - and
# none of that is part of the open set.  It is enabled with no set open,
# because a folder of tiles nothing uses is exactly the state somebody
# starts the application in order to deal with.

our $COMMAND_CLEAN		= 10036;

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


# THE HELP MENU, and the middle one is the reason it exists.
#
# REGENERATE EXAMPLES IS NOT A CONVENIENCE.  _res/user_data is copied into
# the user's folders BY THE INSTALLER, under an existence guard, and that
# was the only path to it - so a deleted source cost a reinstall and a
# development copy could not be seeded with the shipped bundle at all.  The
# user manual tells its reader to open the example set and break it, which
# is only honest if there is a way back.
#
# It is HERE rather than in the File menu beside the key store and the
# cleanup, even though it is the same kind of thing - the user's own
# material on this machine.  What separates it is that the other two act on
# what the USER accumulated and this one puts back what the APPLICATION
# shipped, which is a question about the program rather than about the
# work: the same shelf the manual and the version number sit on.

our $COMMAND_HELP_MANUAL	= 10051;
our $COMMAND_REGEN_EXAMPLES	= 10052;
our $COMMAND_ABOUT			= 10053;

# THE MANUAL IS OPENED ON GITHUB rather than from a bundled copy, which is
# what navMate does.  It renders there, it never has to be packed, and a
# reader who followed a link from the repository and a reader who used the
# menu are looking at the same page.  The cost is that it needs a
# connection, and that is a cost navMate already accepts.

our $REPO_URL = 'https://github.com/phorton1/base-apps-chartMaker';
our $USER_MANUAL_URL = "$REPO_URL/blob/master/user_manual/readme.md";


1;
