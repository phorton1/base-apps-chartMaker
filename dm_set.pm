#!/usr/bin/perl
#---------------------------------------------
# dm_set.pm
#---------------------------------------------
# Region sets, as folders.  See docs/design/regions.md.
#
#	$data_dir/sources/*.tsd
#	$data_dir/region_sets/<set>/*.region
#
# THE FILES PRESENT ARE THE SET.  There is no manifest naming which
# regions belong to a card, exactly as there is none on the card itself:
# the renderer enumerates the folder and merges every .rct it finds.  A
# manifest is correct only by discipline and fails silently in both
# directions -- naming a region that is gone, and missing one that is
# there.  File Explorer is the set editor, and a set is a folder you can
# zip and send to another mariner.
#
# ONE SET IS ACTIVE AT A TIME.  The map shows one set, and one set (or
# one region of it) builds, because a working set assembled ACROSS sets
# would be one no card could express.
#
# EXISTENCE COMES FROM THE FOLDER, SELECTION COMES FROM THE INI.  Which
# set is active is not a fact about the folder, so it is not stored in
# one; it is a per-machine selection remembered in the ini file and
# written on clean exit.  This module holds the selection in memory and
# resolves it -- see getActiveSet for what happens when the remembered
# name points at a set that is gone, which it will, because folders are
# renamed and deleted outside this application by design.
#
# A SET NAME IS A FOLDER NAME, and it becomes the name of the folder
# copied to the card, so it carries the same [A-Za-z0-9] restriction a
# region id does and for the same reason: anything else would have to be
# escaped somewhere, and the somewhere is never all the places.
#
# THREADS.  The same shared generation counter as dm_source and
# dm_region.  Changing the active set advances it, which is what makes
# every server thread reload the regions of the set now in force.

package dm_set;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		loadSets
		rescanSets
		getSetNames
		setExists
		newSet

		getActiveSet
		setActiveSet

		sourcesDir
		regionSetsDir
		setDir
	);
}


our $dbg_set:shared = 0;
	# 0  = the scan summary
	# -1 = one line per set


my $SOURCES_DIR		= 'sources';
my $REGION_SETS_DIR	= 'region_sets';

my $scan_seq:shared		= 1;
my $my_seq				= 0;
my @set_names:shared	= ();
my $active_set:shared	= '';
	# The REMEMBERED name, exactly as the ini gave it -- not the resolved
	# one.  Resolution is done on every read, because the folder it names
	# can disappear between one read and the next.


#---------------------------------------------
# paths
#---------------------------------------------

sub sourcesDir
{
	return "$data_dir/$SOURCES_DIR";
}


sub regionSetsDir
{
	return "$data_dir/$REGION_SETS_DIR";
}


sub setDir
	# The folder a named set lives in.  Returns '' for an empty name, so
	# that a caller with no active set gets a false path rather than the
	# region_sets folder itself, which would scan every set at once.
{
	my ($name) = @_;
	return '' if !defined($name) || $name !~ /\S/;
	return regionSetsDir()."/$name";
}


sub _validName
{
	my ($name) = @_;
	return defined($name) && !ref($name) && $name =~ /^[A-Za-z0-9]+$/;
}


#---------------------------------------------
# scanning
#---------------------------------------------

sub _ensureDirs
	# Both folders are created if they are missing.  This is the one place
	# the application makes a directory in the user's own data folder, and
	# it makes only these two, only empty, and only because nothing can be
	# loaded or saved without them.  It does not create a set: zero sets is
	# a legitimate state that the application must present rather than
	# paper over.
{
	for my $dir (sourcesDir(),regionSetsDir())
	{
		next if -d $dir;
		if (!mkdir($dir))
		{
			error("could not create $dir: $!");
			next;
		}
		display($dbg_set,0,"created $dir");
	}
}


sub loadSets
{
	_ensureDirs();

	my $dir = regionSetsDir();
	my $dh;
	if (!opendir($dh,$dir))
	{
		error("could not read $dir: $!");
		return 0;
	}
	my @found = sort { lc($a) cmp lc($b) }
		grep { !/^\./ && -d "$dir/$_" } readdir($dh);
	closedir $dh;

	# A folder whose name could not be a set name is REPORTED rather than
	# silently skipped.  It is almost certainly a set the user made by
	# hand, and a set that does not appear with no explanation is the
	# worst of the available behaviours.

	my @good;
	for my $name (@found)
	{
		if (!_validName($name))
		{
			warning(0,0,"region_sets/$name is not a usable set name ".
				"(letters and digits only) - ignoring it");
			next;
		}
		push @good,$name;
		display($dbg_set+1,1,"set '$name'");
	}

	@set_names = @good;
	display($dbg_set,0,"loadSets() found ".scalar(@good).
		" set".(@good == 1 ? '' : 's')." in $dir");

	$my_seq = $scan_seq;
	return scalar(@good);
}


sub rescanSets
{
	$scan_seq++;
	return loadSets();
}


sub _current
{
	loadSets() if $my_seq != $scan_seq;
}


sub _touch
	# Every mutation calls this, for the reason dm_region's copy of it
	# explains: another thread holds its own copy and has no other way to
	# learn that it is stale.
{
	$scan_seq++;
	$my_seq = $scan_seq;
}


sub getSetNames
{
	_current();
	my @names = @set_names;
	return @names;
}


sub setExists
{
	my ($name) = @_;
	return 0 if !defined $name;
	my $key = lc($name);
	return scalar(grep { lc($_) eq $key } getSetNames()) ? 1 : 0;
}


#---------------------------------------------
# the active set
#---------------------------------------------

sub getActiveSet
	# The remembered name if it still names a set, else the first set in
	# tree order, else ''.
	#
	# RESOLVED ON EVERY READ, never cached.  The remembered name is a
	# pointer into folder contents and the folder is edited from outside
	# this application - that is the whole point of sets being folders - so
	# a name that resolved a moment ago can dangle now.  Falling through to
	# the first set means deleting the active set's folder degrades to
	# "some other set" rather than to an error the user cannot clear.
{
	my @names = getSetNames();
	return '' if !@names;

	if ($active_set)
	{
		my $key = lc($active_set);
		for my $name (@names)
		{
			return $name if lc($name) eq $key;
		}
	}
	return $names[0];
}


sub setActiveSet
	# Remembers a set as the active one.  The name is stored even when it
	# does not currently resolve, because the ini is read before the first
	# scan and a set the user is about to create should not be forgotten
	# by the act of starting up.
{
	my ($name) = @_;
	$name = '' if !defined $name;
	return 0 if $name eq $active_set;

	my $was = getActiveSet();
	$active_set = $name;
	my $now = getActiveSet();

	# The REGIONS of a set are loaded per active set, so changing it makes
	# every thread's copy of the region model wrong.  Advancing the counter
	# is what tells them.

	_touch() if $now ne $was;
	display($dbg_set,0,"active set is now '$now'");
	return 1;
}


sub newSet
{
	my ($name) = @_;
	if (!_validName($name))
	{
		error("newSet: a set name must be letters and digits only - '".
			($name // '')."' is not");
		return 0;
	}
	if (setExists($name))
	{
		error("newSet: a set named '$name' already exists");
		return 0;
	}

	_ensureDirs();
	my $dir = setDir($name);
	if (!mkdir($dir))
	{
		error("newSet: could not create $dir: $!");
		return 0;
	}

	display($dbg_set,0,"created set '$name'");
	rescanSets();
	setActiveSet($name);
	return 1;
}


1;
