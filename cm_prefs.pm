#!/usr/bin/perl
#---------------------------------------------
# cm_prefs.pm
#---------------------------------------------
# chartMaker preferences.
#
# No prefs file is written until something changes one.  The changeable
# prefs are placed into the prefs hash as in-hash non-defaults: they ARE
# the discoverable list, and a hand-made chartMaker.prefs in $data_dir
# overrides any of them.  set-only-if-absent never clobbers a file value,
# and Pub::Prefs::writePrefs comments out any line that has come back to
# its default -- so the file stays a DIFF against the code rather than a
# snapshot, and changing a default here still reaches anyone who never
# overrode it.
#
# ORDER OF OPERATIONS.  $data_dir is established first and is deliberately
# NOT a preference: the preferences file lives in it, so a preference
# naming it could not be read without already knowing it.  Everything else
# hangs off it --
#
#	setStandardDataDir()   ->  $data_dir
#	init_prefs()           ->  reads $data_dir/chartMaker.prefs,
#	                           defaults computed from $data_dir
#	loadSets/loadSources   ->  read those folders
#
# which is why init_prefs is called in chartMaker.pm before anything is
# scanned, and why nothing may read a folder pref at compile time.
#
# ONE KNOWN PERSISTENT PLACE.  Every folder defaults inside $data_dir --
# sources, region sets, both output trees and the tile cache.  An
# installed copy and a development copy then differ by a prefs file rather
# than by a code branch, and there is no environment variable anywhere.
#
# THE CACHE IS NOT TEMPORARY.  It defaults into $data_dir rather than
# $temp_dir because "temp" is a promise that anything may delete it, and a
# tile cache is bandwidth, wall clock and, for some sources, requests that
# should not be repeated.  It is an asset that happens to be reconstructible.

package cm_prefs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		init_prefs
		prefDir
		prefVal
		prefDefault
		prefIsDefault

		$PREF_HTTP_PORT
		$PREF_MAP_BROWSER
		$PREF_MAP_MAX_ZOOM

		$PREF_MAX_CONCURRENT
		$PREF_MIN_INTERVAL
		$PREF_NUM_SAMPLES
		$PREF_PROBE_ZMIN
		$PREF_PROBE_ZMAX

		$PREF_SOURCES_DIR
		$PREF_REGION_SETS_DIR
		$PREF_MBTILES_DIR
		$PREF_RASTER_DIR
		$PREF_CACHE_DIR

		$PREF_NEW_ZAUTHOR
		$PREF_NEW_ZMIN
		$PREF_NEW_ZMAX

		@PREF_DIRS
	);
	push @EXPORT, grep { $_ ne 'initPrefs' } @Pub::Prefs::EXPORT;
}


our $PREF_HTTP_PORT			= 'HTTP_PORT';
our $PREF_MAP_BROWSER		= 'MAP_BROWSER';
our $PREF_MAP_MAX_ZOOM		= 'MAP_MAX_ZOOM';

our $PREF_MAX_CONCURRENT	= 'MAX_CONCURRENT';
our $PREF_MIN_INTERVAL		= 'MIN_INTERVAL';
our $PREF_NUM_SAMPLES		= 'NUM_SAMPLES';
our $PREF_PROBE_ZMIN		= "PROBE_ZMIN";
our $PREF_PROBE_ZMAX		= "PROBE_ZMAX";

our $PREF_SOURCES_DIR		= 'SOURCES_DIR';
our $PREF_REGION_SETS_DIR	= 'REGION_SETS_DIR';
our $PREF_MBTILES_DIR		= 'MBTILES_DIR';
our $PREF_RASTER_DIR		= 'RASTER_DIR';
our $PREF_CACHE_DIR			= 'CACHE_DIR';

our $PREF_NEW_ZAUTHOR		= 'NEW_ZAUTHOR';
our $PREF_NEW_ZMIN			= 'NEW_ZMIN';
our $PREF_NEW_ZMAX			= 'NEW_ZMAX';

# THE FIVE FOLDERS, in the order a dialog should show them: what is read,
# then what is written, then what is kept.

our @PREF_DIRS = (
	$PREF_SOURCES_DIR,
	$PREF_REGION_SETS_DIR,
	$PREF_MBTILES_DIR,
	$PREF_RASTER_DIR,
	$PREF_CACHE_DIR );


# THE PLAIN DEFAULTS, which are just values.

my %defaults = (
	$PREF_MAP_BROWSER		=> '',
	$PREF_MAP_MAX_ZOOM		=> 22,

	# THE TWO RATE KNOBS, AND WHY THESE ARE PREFERENCES WHERE THE FLUSH
	# INTERVAL IS NOT.  A user's connection, conscience and patience really
	# do differ: somebody on a metered link over a satellite phone and
	# somebody on fibre want different numbers, and somebody who has been
	# asked politely by a provider wants a different number again.  That is
	# what makes these worth asking about.
	#
	# BOTH COMPOSE ONE WAY ONLY.  MIN_INTERVAL is a floor UNDER every
	# source and MAX_CONCURRENT a ceiling OVER the pool, so neither can
	# ever be a way to go faster than a TSD declared - which is what makes
	# them safe to expose at all.
	#
	# MAX_CONCURRENT REQUIRES A RESTART and the dialog says so.  The pool
	# is spawned once while the interpreter is still small, because a
	# thread costs 5 ms to spawn then and 44 ms once the application is
	# loaded - measured on this machine, and the reason the pool is not
	# resized on the fly.
	#
	# FOUR, because it is the useful worker count at a typical 200 ms round
	# trip and 50 ms interval, and because a client-wide cap is the only
	# limiter measured in the right unit: a ban is per client rather than
	# per source, and several services share infrastructure.

	$PREF_MAX_CONCURRENT	=> 4,
	$PREF_MIN_INTERVAL		=> 0,

	# HOW MANY TILES THE SAMPLER DRAWS PER LEVEL, and a TABLE rather than a
	# scalar because the levels are not alike: a coarse level holds so few
	# tiles that min(count, level size) enumerates it whatever this says,
	# while a deep level is the one somebody is actually asking about and
	# is where more points buy a better map.
	#
	# '*:N' is the default for any level not named, and 'z:N' overrides one.
	# So '*:24,19:40' means twenty-four everywhere and forty at z19.
	#
	# IT DOES NOT COMPOSE WITH THE RATE KNOBS and does not need to.  Raising
	# it sends more requests but not faster ones, because the sampler goes
	# through the engine and the engine still paces it.  That independence
	# is why it can be a plain number where a rate can only ever be a max().

	$PREF_NUM_SAMPLES		=> '*:24',

	# THE RANGE A PROBE OPENS AT, and z0 is not in it.  A z0 tile is the
	# whole world and probing one says nothing about anywhere; the useful
	# range starts around z10.  These are the defaults a probe dialog
	# offers - not a limit, since a .tsd can hide depth it really has and
	# finding that out is half the point.

	$PREF_PROBE_ZMIN		=> 10,
	$PREF_PROBE_ZMAX		=> 22,

	# THE LEVELS A NEW REGION STARTS WITH, and nothing else.  Changing
	# them never touches a region that exists: they are seeds, so they are
	# a preference, where zauthor itself could never be one.
	#
	# 15 and 10 suit a commercial aerial source.  A set built on the
	# shipped GIBS sources, which stop at z12, wants something much lower
	# - which is the whole reason these are reachable.

	$PREF_NEW_ZAUTHOR		=> 15,
	$PREF_NEW_ZMIN			=> 10,
	$PREF_NEW_ZMAX			=> 16,
);


# THE FOLDER DEFAULTS ARE COMPUTED, NEVER STORED.  They are a leaf name
# under $data_dir, resolved on every read rather than frozen at startup.
#
# Two things fall out of that, and both matter.  A folder line appears in
# the prefs file only when somebody actually sets one, so the file stays a
# statement of what was CHANGED.  And the default follows $data_dir if it
# moves, which is what makes a test able to point the whole application at
# a fixture directory by assigning one variable.

my %dir_leaf = (
	$PREF_SOURCES_DIR		=> 'sources',
	$PREF_REGION_SETS_DIR	=> 'region_sets',
	$PREF_MBTILES_DIR		=> 'mbtiles',
	$PREF_RASTER_DIR		=> 'raster',
	$PREF_CACHE_DIR			=> 'cache',
);


sub prefDefault
{
	my ($name) = @_;
	return "$data_dir/$dir_leaf{$name}" if $dir_leaf{$name};
	return $defaults{$name};
}


sub prefDir
	# A folder preference, or its default if nobody has set one.  EVERY
	# read of a folder goes through here, so there is exactly one place
	# that knows a default exists.
{
	my ($name) = @_;
	my $have = getPref($name);
	return (defined($have) && $have =~ /\S/) ? $have : prefDefault($name);
}


sub prefVal
	# The same for everything that is not a folder.
	#
	# NOTHING DEPENDS ON init_prefs HAVING RUN.  A default resolved here
	# rather than written into the prefs hash at startup means a module
	# loaded on its own - by a headless test, say - behaves exactly as it
	# does inside the application, instead of quietly reading undef and
	# failing a validator three calls later.
{
	my ($name) = @_;
	my $have = getPref($name);
	return defined($have) ? $have : $defaults{$name};
}


sub prefIsDefault
	# Whether a preference still holds the value the code would give it.
	#
	# THE ONE PLACE THIS MATTERS is folder creation: the application may
	# make a folder it chose the location of, and may not make one the
	# user named.  A path that is merely missing is reported; a path the
	# user never set is ours to create.
{
	my ($name) = @_;
	my $have = getPref($name);
	return 1 if !defined($have) || $have !~ /\S/;
	my $want = prefDefault($name);
	return defined($want) && $have eq $want ? 1 : 0;
}


sub init_prefs
{
	Pub::Prefs::initPrefs("$data_dir/$appName.prefs", {});

	# HTTP_PORT's default is deliberately absent here: it lives in
	# em_server::new(), which is the module that knows what a port is for.
	#
	# The FOLDERS are deliberately absent too - see prefDir.  Nothing puts
	# a computed path into the prefs hash, so a folder line exists only
	# when somebody chose one.

	for my $name (sort keys %defaults)
	{
		setPref($name,$defaults{$name})
			if !defined getPref($name);
	}
}


1;
