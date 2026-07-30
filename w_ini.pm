#!/usr/bin/perl
#---------------------------------------------
# w_ini.pm
#---------------------------------------------
# The few things that survive a session, and nothing else.
#
#	active_set			which region set the map shows and the card builds from
#	default_source		the TSD used for ordinary rendering
#	unchecked_<set>		which regions of a set are hidden on the map
#	last_browse			the folder the last Browse landed in
#
# WHY THE INI AND NOT THE PREFS FILE.  A PREFERENCE IS A DECISION; THE INI
# IS WHERE YOU LEFT THINGS.  Which folder a Browse button should open in
# is not a choice anybody made, it is a convenience -- so it belongs with
# the frame rectangle, the notebook layout and the open panes, all of
# which are already saved here on a clean exit.  Putting it in
# chartMaker.prefs would mean a file whose whole purpose is to state what
# was deliberately changed gaining a line nobody ever decided.
#
# A ctrl-C loses all of it, which is the correct price for state worth one
# radio button.
#
# WRITTEN AT EXIT, NOT WHEN IT CHANGES.  w_frame::saveState clears the
# config and rewrites it, so a key written mid-session would be wiped on
# the way out.  Everything here is therefore held in memory and persisted
# by writeIniSelections, which is the only writer.
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
		getLastBrowseDir
		setLastBrowseDir
	);
}


our $dbg_ini:shared = 0;


my $KEY_ACTIVE_SET		= 'active_set';
my $KEY_DEFAULT_SOURCE	= 'default_source';
my $KEY_UNCHECKED		= 'unchecked_';
my $KEY_LAST_BROWSE		= 'last_browse';


my $last_browse = '';
	# WHERE THE LAST FOLDER CHOSEN WAS, whichever field it was chosen for.
	# One value for all of them and not one each, because the operation
	# this actually serves is moving SEVERAL folders to a new home: having
	# picked D:/charts/sources, the next Browse wants to open at D:/charts
	# rather than back where the field it is editing happens to point.


sub getLastBrowseDir
{
	return $last_browse;
}


sub setLastBrowseDir
{
	my ($dir) = @_;
	$last_browse = (defined($dir) && -d $dir) ? $dir : '';
}


sub readIniSelections
	# Called once, at startup, AFTER $ini_file is set and the config has
	# been read, and BEFORE the first scan -- both selections are stored
	# unresolved, so neither cares whether what they name exists yet.
{
	my $set = readConfig($KEY_ACTIVE_SET) || '';
	my $src = readConfig($KEY_DEFAULT_SOURCE) || '';

	# Validated on the way in: a remembered folder is a pointer at a
	# filesystem that has moved on, and opening a dialog at a path that
	# is gone is worse than opening it at nothing.

	setLastBrowseDir(readConfig($KEY_LAST_BROWSE) || '');

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
	writeConfig($KEY_LAST_BROWSE,getLastBrowseDir());

	if ($set)
	{
		writeConfig($KEY_UNCHECKED.lc($set),join(',',getUncheckedIds()));
	}
	display($dbg_ini,0,"ini selections written: set='$set' source='$src'");
}


1;
