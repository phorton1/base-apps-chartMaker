#!/usr/bin/perl
#---------------------------------------------
# w_ini.pm
#---------------------------------------------
# The three selections that survive a session, and nothing else.
#
#	active_set			which region set the map shows and the card builds from
#	default_source		the TSD used for ordinary rendering
#	unchecked_<set>		which regions of a set are hidden on the map
#
# WHY THE INI AND NOT THE PREFS FILE.  chartMaker.prefs is a hand-edited
# file -- the only way a user changes a pref is by opening it in an
# editor, or through a preferences dialog that does not exist.  Writing
# one is not part of the program lifecycle.  Writing the ini IS: the
# frame rectangle, the notebook layout and the open panes are already
# saved there on a clean exit, and these three belong in exactly that
# company.  A ctrl-C loses them, which is the correct price for state
# worth one radio button.
#
# WHY A MODULE AND NOT TWO FUNCTIONS.  The read happens at startup in
# chartMaker.pm and the write happens at shutdown in w_frame.pm.  Split
# across two files, the key names would be written twice and would
# eventually disagree; here they are written once, as constants, and the
# two halves cannot drift.
#
# THIS IS THE ONLY MODULE THAT KNOWS BOTH.  dm_set and dm_source hold
# their selection in memory and resolve it; they know nothing about the
# ini, which is what keeps them loadable by the headless test harnesses
# without wx.

package w_ini;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::AppConfig;
use cm_defs;
use dm_set;
use dm_source;
use dm_region;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		readIniSelections
		writeIniSelections
	);
}


our $dbg_ini:shared = 0;


my $KEY_ACTIVE_SET		= 'active_set';
my $KEY_DEFAULT_SOURCE	= 'default_source';
my $KEY_UNCHECKED		= 'unchecked_';


sub readIniSelections
	# Called once, at startup, AFTER $ini_file is set and the config has
	# been read, and BEFORE the first scan -- both selections are stored
	# unresolved, so neither cares whether what they name exists yet.
{
	my $set = readConfig($KEY_ACTIVE_SET) || '';
	my $src = readConfig($KEY_DEFAULT_SOURCE) || '';

	setActiveSet($set)		if $set;
	setDefaultSource($src)	if $src;

	# The hidden list is per set and can only be read once the active set
	# has resolved, which needs the scan the caller is about to do.  It is
	# therefore read here but applied by the caller's own load order --
	# getActiveSet() below does the scan itself.

	my $now = getActiveSet();
	if ($now)
	{
		my $hidden = readConfig($KEY_UNCHECKED.lc($now)) || '';
		setUncheckedIds(grep { /\S/ } split(/,/,$hidden));
	}

	display($dbg_ini,0,"ini selections: set='".getActiveSet().
		"' source='".getDefaultSource()."'");
}


sub writeIniSelections
	# Called on a clean exit, from w_frame::saveState, AFTER the frame has
	# cleared and rewritten the config -- see the note there.
	#
	# The RESOLVED values are written, not the remembered ones.  If the
	# remembered set was deleted and the application fell through to
	# another, the one the user was actually looking at is the one to come
	# back to; writing back a name known to be dangling would be a
	# fallback that never ends.
{
	my $set = getActiveSet();
	my $src = getDefaultSource();

	writeConfig($KEY_ACTIVE_SET,$set);
	writeConfig($KEY_DEFAULT_SOURCE,$src);

	if ($set)
	{
		writeConfig($KEY_UNCHECKED.lc($set),join(',',getUncheckedIds()));
	}
	display($dbg_ini,0,"ini selections written: set='$set' source='$src'");
}


1;
