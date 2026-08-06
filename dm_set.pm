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
# regions belong to a build, exactly as there is none in the output:
# the renderer enumerates the folder and merges every .rct it finds.  A
# manifest is correct only by discipline and fails silently in both
# directions -- naming a region that is gone, and missing one that is
# there.  File Explorer is the set editor, and a set is a folder you can
# zip and send to another mariner.
#
# ONE SET IS ACTIVE AT A TIME.  The map shows one set, and one set (or
# one region of it) builds, because a working set assembled ACROSS sets
# would be one no output could express.
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
# copied onto a card, so it carries the same [A-Za-z0-9] restriction a
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
use File::Path qw( make_path );
use Pub::Utils;
use cm_defs;
use cm_prefs;


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
		mbtilesDir
		rasterDir
		cacheDir
		setDir
	);
}


our $dbg_set:shared = 0;
	# 0  = the scan summary
	# -1 = one line per set



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

# EVERY FOLDER IS A PREFERENCE, defaulted under $data_dir.  Read through
# these rather than composed at any call site, so that changing where a
# tree lives is one line in a prefs file and not a search.  Nothing may
# call them at compile time: init_prefs has to have run.

sub sourcesDir
{
	return prefDir($PREF_SOURCES_DIR);
}


sub regionSetsDir
{
	return prefDir($PREF_REGION_SETS_DIR);
}


sub mbtilesDir
{
	return prefDir($PREF_MBTILES_DIR);
}


sub rasterDir
	# THE BASE, not the output folder.  A build writes to
	# rasterDir()/<set>, and it is THAT folder which is copied to the
	# consumer -- which makes the copy a copy rather than a decision about
	# which files belong together.
	#
	# On the CF card the spec requires a single outer folder called
	# \RASTER\ holding exactly one region set: that is the consumer's
	# contract, and what this folder is called on this machine is a local
	# convenience.  The copy to the card is what bridges them.
{
	return prefDir($PREF_RASTER_DIR);
}


sub cacheDir
{
	return prefDir($PREF_CACHE_DIR);
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
	# The folders are created if they are missing -- but ONLY the ones the
	# application chose the location of.
	#
	# A PATH THE USER NAMED IS NEVER CREATED.  A preference pointing at a
	# folder that is not there is far more likely to be a typo, a drive
	# that has not mounted, or a machine the prefs file was copied from
	# than it is an instruction to build an empty tree somewhere
	# unexpected.  Making it would look like it worked and would quietly
	# hide the real one.  So a default location is ours to create and a
	# named one is reported.
	#
	# It does not create a set: zero sets is a legitimate state the
	# application must present rather than paper over.
{
	for my $name (@PREF_DIRS)
	{
		my $dir = prefDir($name);
		next if !defined($dir) || $dir !~ /\S/ || -d $dir;

		if (!prefIsDefault($name))
		{
			error("$name is set to '$dir', which does not exist - ".
				"correct it in Preferences, or create the folder");
			next;
		}
		if (!make_path($dir))
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
	# The remembered name if it still names a set, else ''.
	#
	# RESOLVED ON EVERY READ, never cached.  The remembered name is a
	# pointer into folder contents and the folder is edited from outside
	# this application - that is the whole point of sets being folders - so
	# a name that resolved a moment ago can dangle now.
	#
	# NO SET OPEN IS AN ANSWER, and it used to be unreachable.  This fell
	# through to the first set in tree order, on the reasoning that
	# deleting the active set's folder should degrade to "some other set"
	# rather than to an error nobody could clear.  What that actually did
	# was make CLOSING A SET IMPOSSIBLE TO REMEMBER: Close stores '',
	# meaning nothing is remembered, this turned '' back into the first
	# set, and chartMaker.pm opened it again on the next run.  Observed on
	# a fresh install, where the map drew the example set's regions before
	# the user had opened anything and went on drawing them after they had
	# closed it.
	#
	# IT IS DEFEATED AT BOTH ENDS, which is why the one line is the whole
	# fix.  writeIniSelections deliberately writes the RESOLVED value
	# rather than the remembered one, so the manufactured answer was also
	# written back to the ini as though the user had chosen it.
	#
	# THE MODEL ALWAYS BELIEVED THIS.  dm_region::openSet says so in as
	# many words - no set open is what a brand new installation looks like
	# and what Close leaves behind - and w_frame gates New Region, Fetch
	# and both Builds on setIsOpen().  This was the one place that
	# disagreed.
	#
	# What a deleted folder now degrades to is nothing open, which the user
	# sees as the Regions window going away, and File - Open Set is how
	# they clear it.
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
	return '';
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
