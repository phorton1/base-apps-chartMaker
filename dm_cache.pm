#!/usr/bin/perl
#---------------------------------------------
# dm_cache.pm
#---------------------------------------------
# The tile cache.  See docs/implementation.md.
#
#	<CACHE_DIR>/<cache_key>/<z>/<x>_<y>.<ext>		a tile
#	<CACHE_DIR>/<cache_key>/<z>/<x>_<y>.none		a known absence
#
# CACHE_DIR is a preference and defaults into $data_dir, NOT $temp_dir.
# 'Temp' is a promise that anything may delete it, and these tiles are
# bandwidth, wall clock, and for some sources requests that should not be
# repeated.  Reconstructible is not the same as disposable.
#
# THE SOURCE KEY IS NOT OPTIONAL.  A z/x/y coordinate means something
# different in every source, so a cache without a source dimension will
# silently answer a request for one source's tile with another source's
# image -- producing a build that looks complete, contains the wrong
# imagery, and gives no indication that anything went wrong.
#
# MISSES ARE CACHED TOO.  A tile a source does not have is recorded as a
# .none marker.  That is what accumulates a real coverage picture for a
# remote source at no cost, and what stops every rebuild from
# re-requesting tiles already known to be missing.
#
# AND THE MARKER SAYS WHICH KIND OF NOTHING.  A refusal and a sentinel are
# not the same finding: a 404 is a service SAYING it has nothing, and a 200
# carrying a declared 'no data' body is a service declining to say so.  The
# second is a worse property of a service and it is exactly what a probe
# exists to surface, so it cannot be thrown away at the cache boundary and
# reconstructed later - the bytes are gone by then.
#
# It rides in the BODY of the .none file, which was empty and had no other
# job.  An existing empty marker reads as a plain absence, which is what it
# always meant, so nothing on disk needs rewriting or clearing.
#
# THREADS.  The HTTP server answers on several threads and two of them
# can be asked for the same tile at the same moment.  Every write goes to
# a per-thread temporary name and is then renamed into place, so a reader
# sees either no file or a complete one, never a partial one.
#
# This module holds no policy.  It does not decide when to fetch, when to
# expire, or how long anything lives; it reads and writes what it is told
# to and reports what it has.
#
# THAT INCLUDES REMOVING THINGS.  cacheRemoveFile and cacheRemoveKey are
# here because this module is the only one that knows the layout, and
# dm_clean is what decides which of them to call and on what.  A cleanup
# that composed its own paths would be a second statement of where a tile
# lives, and the first thing it would do wrong is delete somebody else's.
#
# AND ONE ENUMERATOR, cacheWalk.  cacheStats used to be the only thing
# that read the tree and it counted as it went, so anything wanting a
# different question - which tiles are outside a region, which are a
# fingerprinted blank - had to walk it again, in its own words, with its
# own idea of what a .tmp file is.  Now there is one walk and the callers
# differ in what they do per file.

package dm_cache;
use strict;
use warnings;
use threads;
use threads::shared;
use File::Path qw( make_path );
use Pub::Utils;
use cm_defs;
use dm_set;
	# For cacheDir() alone - the folder accessors all live in one place so
	# that moving a tree is a preference rather than a search.


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		cacheGet
		cachePutTile
		cachePutMiss
		cacheStats

		cacheKeysOnDisk
		cacheWalk
		cacheCount
		cacheRemoveFile
		cacheRemoveKey
	);
}


our $dbg_cache:shared = 1;
	# 1  = quiet; the cache is on the hot path and says nothing by default
	# 0  = one line per hit, miss and write
	# -1 = paths


my @EXTS = qw( jpeg png );


sub _dir
{
	my ($source,$z) = @_;
	return cacheDir()."/$source->{cache_key}/$z";
}


sub _stem
{
	my ($source,$z,$x,$y) = @_;
	return _dir($source,$z)."/${x}_${y}";
}


sub cacheGet
	# Returns one of:
	#	{ status => 'ok',     format => 'jpeg', bytes => \$data }
	#	{ status => 'absent', sentinel => 0|1 }
	#	undef                 -- nothing known about this tile
	#
	# The source's declared tile_format is tried first because it is
	# usually right, but the extension on disk is what actually decides,
	# since the format written is the one detected from the image itself.
{
	my ($source,$z,$x,$y) = @_;
	my $stem = _stem($source,$z,$x,$y);

	my @try = ($source->{tile_format}, grep { $_ ne $source->{tile_format} } @EXTS);
	for my $ext (@try)
	{
		my $path = "$stem.$ext";
		next if !-f $path;

		my $fh;
		if (!open($fh,'<',$path))
		{
			error("cacheGet could not read $path: $!");
			return undef;
		}
		binmode $fh;
		local $/;
		my $data = <$fh>;
		close $fh;

		display($dbg_cache,0,"cache hit  $source->{cache_key} $z/$x/$y ($ext, ".length($data)." bytes)");
		return { status => 'ok', format => $ext, bytes => \$data };
	}

	if (-f "$stem.none")
	{
		# WHICH KIND OF NOTHING, from the marker's own body.  Three syscalls
		# on a file of at most a dozen bytes, and only on tiles already known
		# to be missing - the tile path above is untouched.  An unreadable or
		# empty marker is a plain absence, which is what every marker written
		# before this meant.

		my $why = '';
		if (open(my $fh,'<',"$stem.none"))
		{
			local $/;
			$why = <$fh> // '';
			close $fh;
		}
		my $sent = $why =~ /sentinel/ ? 1 : 0;

		display($dbg_cache,0,"cache hit  $source->{cache_key} $z/$x/$y ".
			"(known absent".($sent ? ", sentinel" : '').")");
		return { status => 'absent', sentinel => $sent };
	}

	display($dbg_cache,0,"cache miss $source->{cache_key} $z/$x/$y");
	return undef;
}


sub _writeAtomic
	# Write through a per-thread temporary name and rename into place, so
	# that a concurrent reader never sees a partial file.
{
	my ($path,$dataref) = @_;

	my $dir = $path;
	$dir =~ s{/[^/]+$}{};
	if (!-d $dir)
	{
		my $err;
		make_path($dir,{ error => \$err });
		if (!-d $dir)
		{
			error("could not create $dir");
			return 0;
		}
	}

	my $tmp = "$path.$$.".threads->tid().".tmp";
	my $fh;
	if (!open($fh,'>',$tmp))
	{
		error("could not write $tmp: $!");
		return 0;
	}
	binmode $fh;
	print $fh $$dataref if defined $dataref;
	close $fh;

	# On Windows rename() onto an existing name fails, so an existing
	# file is removed first.  The window between the two is harmless:
	# both files hold the same tile.

	unlink $path if -f $path;
	if (!rename($tmp,$path))
	{
		error("could not rename $tmp to $path: $!");
		unlink $tmp;
		return 0;
	}
	return 1;
}


sub cachePutTile
{
	my ($source,$z,$x,$y,$format,$dataref) = @_;
	my $path = _stem($source,$z,$x,$y).".$format";
	display($dbg_cache,0,"cache put  $source->{cache_key} $z/$x/$y ($format, ".length($$dataref)." bytes)");
	return _writeAtomic($path,$dataref);
}


sub cachePutMiss
	# $sentinel says the source answered 200 with its declared 'no data'
	# body rather than refusing.  Written as a word rather than a flag byte
	# because somebody looking at a cache folder with a text editor is the
	# only other reader this file will ever have.
{
	my ($source,$z,$x,$y,$sentinel) = @_;
	my $stem = _stem($source,$z,$x,$y);
	display($dbg_cache,0,"cache put  $source->{cache_key} $z/$x/$y (absent".
		($sentinel ? ", sentinel" : '').")");

	# AND ANY IMAGE FOR THE SAME TILE GOES, because a tile cannot be both.
	# cacheGet looks for an image before it looks for a marker - it has to,
	# that is the common case - so a .none written beside a .jpeg is a file
	# nothing will ever read, and the cache holds two answers with the wrong
	# one winning.
	#
	# The only thing that reaches here with an image already on disk is a
	# body the .tsd NAMES as the source's 'no data' tile, which is a
	# person's assertion about that source, made by hand.  Honouring it is
	# the point of declaring it; keeping the bytes anyway would mean the
	# declaration silently did nothing to what was already cached.

	unlink("$stem.$_") for @EXTS;

	my $body = $sentinel ? "sentinel\n" : '';
	return _writeAtomic("$stem.none",\$body);
}


sub cacheKeysOnDisk
	# Every cache_key with a folder, whether or not a source still names
	# it.  The ones nothing names are exactly what a cleanup is looking
	# for, so this asks the DISK and not the source list.
{
	my $root = cacheDir();
	my $dh;
	return () if !-d $root || !opendir($dh,$root);
	my @keys = sort grep { !/^\./ && -d "$root/$_" } readdir($dh);
	closedir $dh;
	return @keys;
}


sub cacheWalk
	# Every file in one cache_key's tree, oldest question first: what is
	# in here.  Calls $fn->($z,$x,$y,$ext,$path,$size) per file and returns
	# how many times it did.
	#
	# $ext is 'none' for a marker and the image extension otherwise, which
	# is the one distinction every caller makes.  $size is the file's, and
	# is taken here because the walk has the path in hand and a caller
	# that wanted it would have to stat it a second time.
	#
	# A .tmp IS SKIPPED AND SO IS ANYTHING UNPARSEABLE.  A tmp file is a
	# write in flight on another thread - possibly this instant - and a
	# name that is not <x>_<y>.<ext> was not written by this application.
	# Neither is ours to count and neither is ours to delete.
	#
	# opts: no_size    do not stat the files; $size arrives as 0.  Reading
	#                  a directory is cheap and stat'ing every file in it
	#                  is not, so a caller that only wants to know HOW MANY
	#                  - to size a progress bar before the real walk - says
	#                  so rather than paying for the answer twice.
{
	my ($key,$fn,$opts) = @_;
	$opts ||= {};
	my $root = cacheDir()."/$key";
	return 0 if !-d $root;

	my $dh;
	if (!opendir($dh,$root))
	{
		error("cacheWalk could not read $root: $!");
		return 0;
	}
	my @zooms = sort { $a <=> $b } grep { /^\d+$/ && -d "$root/$_" } readdir($dh);
	closedir $dh;

	my $count = 0;
	for my $z (@zooms)
	{
		my $zh;
		next if !opendir($zh,"$root/$z");
		my @files = sort grep { !/^\./ && !/\.tmp$/ } readdir($zh);
		closedir $zh;

		for my $f (@files)
		{
			next if $f !~ /^(\d+)_(\d+)\.(\w+)$/;
			my ($x,$y,$ext) = ($1,$2,$3);
			my $path = "$root/$z/$f";
			$count++;
			$fn->($z,$x,$y,$ext,$path,
				$opts->{no_size} ? 0 : ((-s $path) || 0));
		}
	}
	return $count;
}


sub cacheCount
	# How many files are in one cache_key's tree.  No stat, so this is the
	# directory read and nothing else - it exists to give a progress bar a
	# total before the walk that does the work.
{
	my ($key) = @_;
	return cacheWalk($key,sub {},{ no_size => 1 });
}


sub cacheStats
	# Walk one source's cache and count what is in it, by zoom.  Returns
	# { total_tiles, total_misses, total_bytes, zooms => { z => {...} } }.
	#
	# ABSENCES ARE COUNTED AND NOT SIZED, deliberately.  A marker is nine
	# bytes or none, and adding them to a total that is read as "what this
	# source has cost" would be noise in the one number somebody is
	# actually looking at.
{
	my ($source) = @_;
	my $stats = { total_tiles => 0, total_misses => 0, total_bytes => 0, zooms => {} };

	cacheWalk($source->{cache_key},sub {
		my ($z,$x,$y,$ext,$path,$size) = @_;
		my $zs = $stats->{zooms}{$z} ||= { tiles => 0, misses => 0, bytes => 0 };
		if ($ext eq 'none')
		{
			$zs->{misses}++;
			$stats->{total_misses}++;
			return;
		}
		$zs->{tiles}++;
		$zs->{bytes} += $size;
		$stats->{total_tiles}++;
		$stats->{total_bytes} += $size;
	});

	return $stats;
}


sub cacheRemoveFile
	# One file, by the path cacheWalk gave out.  Returns 1 or 0, and says
	# why when it is 0 - a cleanup that reported a thousand removals when
	# nine hundred were refused by a read-only attribute would be worse
	# than one that did nothing.
{
	my ($path) = @_;
	return 1 if !-f $path;
	if (!unlink($path))
	{
		error("could not delete $path: $!");
		return 0;
	}
	display($dbg_cache,0,"removed $path");
	return 1;
}


sub cacheRemoveKey
	# One cache_key's whole tree.  Returns ($files,$bytes,$errors).
	#
	# WHAT IT WALKED AND NOTHING ELSE.  The zoom folders and the key
	# folder itself are removed only if they empty out, so a .tmp mid
	# write, or anything a person put in there by hand, survives along
	# with the folder holding it rather than being taken silently.
{
	my ($key) = @_;
	my ($files,$bytes,$errors) = (0,0,0);

	cacheWalk($key,sub {
		my ($z,$x,$y,$ext,$path,$size) = @_;
		if (cacheRemoveFile($path))
		{
			$files++;
			$bytes += $size if $ext ne 'none';
		}
		else
		{
			$errors++;
		}
	});

	my $root = cacheDir()."/$key";
	my $dh;
	if (-d $root && opendir($dh,$root))
	{
		my @zooms = grep { /^\d+$/ && -d "$root/$_" } readdir($dh);
		closedir $dh;
		rmdir("$root/$_") for @zooms;
		rmdir($root);
	}

	display($dbg_cache,0,"cacheRemoveKey($key) removed $files files");
	return ($files,$bytes,$errors);
}


1;
