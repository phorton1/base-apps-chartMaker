#!/usr/bin/perl
#---------------------------------------------
# dm_fill.pm
#---------------------------------------------
# Fill the cache with everything a region covers.
#
# THIS IS NOT THE FETCH ENGINE, and the name is deliberate so that it
# cannot quietly become one.  There is no queue, no concurrency, no retry
# policy and no resume: it walks the coverage the build would enumerate,
# asks getTile() for each tile in turn, and stops when it runs out.  The
# engine that does those things is specified against docs/design/build.md
# and will arrive as its own thing.
#
# What it is FOR is the gap between authoring and building.  dm_rct
# fetches nothing by design -- an uncached tile is simply absent, the miss
# bit is set, and the plotter overzooms from a present ancestor.  Reshaping
# an existing subregion therefore rebuilds happily from cache, but NEW
# ground at depth has never been fetched, and the output comes back with
# holes the E80 papers over.  It looks SOFT rather than broken, which reads
# on the water as "the imagery is bad there" instead of "we never fetched
# it."  This is what makes new ground real.
#
# RESUME IS FREE and is why none is specified.  getTile is cache first, so
# a run that is interrupted and started again asks the network only for
# what the first run did not reach.  What is NOT free is the failure
# classification -- see the abort below.

package dm_fill;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( time sleep );
use Pub::Utils;
use cm_defs;
use cm_utils;
use cm_config;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_fetch;
use dm_engine;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		fillCoverage
	);
}


our $dbg_fill:shared = 0;
	# 0  = the summary and one line per region
	# -1 = one line per zoom level
	# -2 = one line per tile


# WHEN TO GIVE UP ON A SOURCE THAT IS NOT THERE.  Not a retry policy - the
# engine below owns retries.  It is the difference between a source that is
# missing a tile and a source that is not there at all: the first is a
# result and the walk should continue, the second is nine thousand
# pointless requests aimed at somebody else's server.  An error is not
# cached, so nothing is poisoned by stopping, and running it again resumes.
#
# 'CONSECUTIVE' DOES NOT SURVIVE CONCURRENCY, which is why it is gone.  It
# counted across classes, so a flaky server that fails one request in three
# aborted a run identically to a dead host; and with four requests in
# flight, "in a row" is not a property the results even have - they finish
# in whatever order the network returns them.
#
# THE PARALLEL-SAFE PREDICATE IS ZERO SUCCESSES IN THE LAST K COMPLETIONS.
# It says the same thing about a dead host, says nothing about a server
# that is merely unreliable, and is well defined no matter how many
# requests are outstanding.

my $LOOKBACK        = 20;
my $LOOKBACK_MIN    = 20;
	# How many completions to judge on, and how many must have happened
	# before the judgement is made at all.  A run that fails its first
	# three requests has not yet said anything.

# How often to say something during a long walk.

my $PROGRESS_EVERY = 250;

# How often the DIALOG's readout is refreshed, in seconds.  Nothing to do
# with the console line above it: a watcher needs to see a number move
# often enough to believe the thing is alive, and that is a clock.

my $UI_EVERY_SECS = 0.4;

# How many failed tiles to NAME rather than merely count.  A build refuses
# on any failure at all, so what the report needs is enough of them to see
# the pattern -- one zoom, one corner, one source -- not all of them.  The
# consecutive-error abort caps the runaway case; this caps the scattered
# one, which nothing else bounds.

my $MAX_FAILED_LISTED = 100;


sub _fillNode
	# One node's own tiles, from one source.  Returns 0 if the walk should
	# stop.
{
	my ($src,$levels,$stats,$opts) = @_;

	# THE SOURCE'S FLOOR OR THE USER'S, WHICHEVER IS SLOWER.  A TSD states
	# a fact about somebody else's server and stays authoritative; the
	# advisory rate in the build configuration is the user saying they have
	# all night and would rather go slow and sure.  effectiveInterval is a
	# max(), so an advisory can never be a way to go faster than declared.

	my $interval = effectiveInterval($src,$opts->{config});

	for my $z (sort { $a <=> $b } keys %$levels)
	{
		my @keys = keys %{$levels->{$z}};

		# Deterministic order, for the same reason the RCT exporter writes
		# blobs row major: two runs of the same walk should do the same
		# things in the same sequence, or comparing two logs is guesswork.

		my @tiles = sort {
			$a->[0] <=> $b->[0] || $a->[1] <=> $b->[1]
		} map { [ split(/_/,$_) ] } @keys;

		display($dbg_fill+1,1,sprintf("z%-2d %d tiles",$z,scalar(@tiles)));

		# THE FILL IS A CLIENT THAT SUBMITS MANY, and this is the whole of
		# the change.  It used to block on one tile at a time and sleep the
		# interval itself; now it keeps up to `concurrency` requests
		# outstanding and lets the engine pace them, which is the only way
		# a rate limit can be applied across the map proxy and the fill at
		# once rather than by each of them separately.
		#
		# THE CACHE STILL SHORT CIRCUITS EVERYTHING.  getTile answers a hit
		# without touching the engine, so a mostly-cached walk runs at
		# local disk speed exactly as it did before, and only the tiles
		# that must really be fetched enter the queue.

		my $depth = engineConcurrency($src,$interval);
		$depth = 1 if $depth < 1;

		my @window;		# tiles submitted and not yet collected

		my $collect = sub
			# Take the oldest outstanding result and account for it.
		{
			my $w = shift @window or return 1;
			my $result = $w->{job} ?
				engineCollect($w->{job}) : $w->{result};
			$result->{cached} = $w->{cached};
			return _account($src,$w->{x},$w->{y},$z,$result,$stats,$opts);
		};

		my $abandon = sub
			# EVERY SUBMITTED JOB MUST BE COLLECTED, even when the walk has
			# already decided to stop.
			#
			# A ticket is a claim on a slot in the engine's shared result
			# store, and the store is emptied by the COLLECT rather than by
			# the publish - a worker has no idea whether anybody still wants
			# what it fetched.  So walking away from an outstanding job
			# leaves its fields there permanently, and since a cancel is an
			# ordinary thing for a user to do, an application left running
			# for a week would accumulate them.  That would make this the one
			# unbounded structure in a design whose whole claim is that
			# nothing grows without bound.
			#
			# THE REQUESTS ARE ALREADY IN FLIGHT, so this costs a cancel up
			# to one window's worth of waiting rather than returning
			# instantly.  That is the honest price: the tiles are being
			# fetched whether or not anybody is still listening, and the
			# alternative is to lie about having stopped.
		{
			while (my $w = shift @window)
			{
				engineCollect($w->{job}) if $w->{job};
			}
		};

		for my $t (@tiles)
		{
			my ($x,$y) = @$t;

			# CACHE FIRST, ON THIS THREAD.  Asking the engine for a tile
			# already on disk would put a thread handoff in front of a file
			# read, and a resumed run is mostly this path.

			my $hit = cacheGet($src,$z,$x,$y);
			if ($hit)
			{
				$hit->{cached} = 1;
				push @window,{ x => $x, y => $y, cached => 1, result => $hit };
			}
			else
			{
				push @window,{ x => $x, y => $y, cached => 0,
					job => engineSubmit($src,$z,$x,$y,
						$PRIORITY_BULK,$interval) };
			}

			next if @window <= $depth;
			if (!$collect->())
			{
				$abandon->();
				return 0;
			}
		}

		while (@window)
		{
			if (!$collect->())
			{
				$abandon->();
				return 0;
			}
		}
	}

	return 1;
}


sub _account
	# ONE COMPLETED TILE, whatever produced it.  Split out of the walk
	# because the walk now has two places a result arrives - a cache hit
	# taken immediately and a fetch collected later - and duplicating the
	# accounting across them is how the two quietly stop agreeing.
{
	my ($src,$x,$y,$z,$result,$stats,$opts) = @_;
	my $status = $result->{status};

	$stats->{tiles}++;
	$stats->{$status}++;
	$stats->{cached}++ if $result->{cached};

	# PER SOURCE, AND ONLY WHAT ACTUALLY WENT OUT.  This is what lets the
	# next preflight estimate a time instead of admitting it cannot.  Cache
	# hits are excluded deliberately: they say nothing about the server, and
	# averaging them in would make a mostly-cached run look infinitely fast
	# - which is precisely the estimate that would then mislead somebody
	# into starting an overnight job before dinner.

	if (!$result->{cached})
	{
		my $by = $stats->{by_source}{$src->{id}} ||= { fetched => 0, ms => 0 };
		$by->{fetched}++;
		$by->{ms} += $result->{ms} || 0;
	}

	display($dbg_fill+2,2,"$z/$x/$y $status".
		($result->{cached} ? ' (cached)' : ''));

	# ZERO SUCCESSES IN THE LAST K COMPLETIONS.  A ring of outcomes rather
	# than a counter of consecutive failures - see the note at the top for
	# why the counter could not survive having four requests in flight.
	# Cache hits do not enter it: a resumed run over cached ground would
	# otherwise fill the window with successes that never touched the
	# network and mask a source that had died.

	if (!$result->{cached})
	{
		push @{$stats->{recent}},($status eq 'error' ? 0 : 1);
		shift @{$stats->{recent}} while @{$stats->{recent}} > $LOOKBACK;
	}

	if ($status eq 'error')
	{
		$stats->{errors_seen}++;
		warning(0,1,"$src->{id} $z/$x/$y - $result->{reason}")
			if $stats->{errors_seen} <= 3;

		# NAMED, not just counted.  An error is never cached, so this is
		# the only record that this tile was ever asked for -- after the
		# walk there is nothing on disk to find it by, and the build has to
		# be able to say WHICH tiles it is refusing over.

		push @{$stats->{failed_tiles}},
			"$src->{id} $z/$x/$y - $result->{reason}"
			if @{$stats->{failed_tiles}} < $MAX_FAILED_LISTED;

		my $window = scalar(@{$stats->{recent}});
		my $wins   = 0;
		$wins += $_ for @{$stats->{recent}};

		if ($window >= $LOOKBACK_MIN && !$wins)
		{
			error("giving up: the last $window requests to '$src->{id}' ".
				"all failed - nothing has been cached as missing, so ".
				"fixing the source and running this again resumes");
			$stats->{aborted} = 1;
			return 0;
		}
	}

	# NOTHING SLEEPS HERE ANY MORE.  Politeness used to be this loop's job
	# and is now the engine's, which is the point of the engine: one gate
	# per source that the map proxy, the preview and this walk all pass
	# through, instead of three unrelated pieces of code each being polite
	# on their own account and none of them knowing about the others.

	# THE INNER BAR MOVES EVERY TILE, the text every $PROGRESS_EVERY.  A
	# number into a shared scalar is cheap next to the request that just
	# happened; rebuilding a status string in shared memory nine thousand
	# times is not, and nobody can read it changing that fast anyway.

	my $prog = $opts->{progress};
	$prog->{sub_done} = $stats->{sub_done}++ if $prog;

	# THE CONSOLE COUNTS TILES; THE DIALOG COUNTS SECONDS.
	#
	# Both used to fire every $PROGRESS_EVERY tiles, which is fine for a log
	# and was badly wrong on screen.  A cached walk crosses 250 tiles in an
	# instant, but a FETCHING one takes 250 round trips - minutes - and the
	# dialog's text sat unchanged for all of it while the bar crept a
	# fraction of a percent.  It read as hung, and then as jumping, because
	# the only thing that ever moved was the number and it moved in one leap.
	#
	# So the readout is on a clock: what the user is watching for is
	# evidence that something is still happening, and that is a question
	# about elapsed time, not about tile count.

	my $now = time();
	if ($prog && $now - $stats->{last_ui} >= $UI_EVERY_SECS)
	{
		$stats->{last_ui} = $now;
		$prog->{sub_label} = sprintf(
			"%d of %d - %d fetched, %d cached, %d absent, %d failed",
			$stats->{sub_done},$prog->{sub_total} || 0,
			$stats->{tiles} - $stats->{cached},$stats->{cached},
			$stats->{absent} || 0,$stats->{error} || 0);
	}

	if ($stats->{tiles} % $PROGRESS_EVERY == 0)
	{
		my $secs = $now - $stats->{started};
		display(0,1,sprintf(
			"%d tiles - %d fetched, %d cached, %d absent, %d errors (%.0fs)",
			$stats->{tiles},$stats->{tiles} - $stats->{cached},
			$stats->{cached},$stats->{absent} || 0,
			$stats->{error} || 0,$secs));
	}

	return 0 if progressCancelled($prog);
	return 0 if $opts->{stop} && ${$opts->{stop}};
	return 1;
}


sub fillCoverage
	# Fill the cache for these region ids.  Returns a stats hash.
	#
	# opts: zmax     a hard cap, exactly as the build applies one
	#       fallback the source a region that inherits resolves to
	#       stop     a scalar ref polled between tiles
	#       progress a shared record from newProgress(), written as the
	#                walk proceeds and polled for {cancelled}
	#
	# The progress record is OPTIONAL and everything here works without
	# one.  The console fills a cache with no dialog anywhere, and so does
	# every test -- a walk that required a watcher could not be tested.
{
	my ($ids,$opts) = @_;
	$opts ||= {};

	my $prog = $opts->{progress};

	my $stats = {
		tiles => 0, cached => 0, ok => 0, absent => 0, error => 0,
		errors_seen => 0, recent => [], aborted => 0, cancelled => 0,
		started => time(), failed_tiles => [], sub_done => 0,
		by_source => {}, last_ui => 0,
	};

	my $fallback = $opts->{fallback} || getDefaultSource();

	if ($prog)
	{
		$prog->{total} = scalar(@$ids);
		$prog->{done}  = 0;
	}

	for my $id (@$ids)
	{
		my $reg = getRegion($id);
		if (!$reg)
		{
			warning(0,0,"fill: there is no region '$id'");
			next;
		}

		my $sources = regionSourceMap($reg,$fallback);
		my ($cov,$nodes) = regionCoverageNodes($reg,
			defined $opts->{zmax} ? { zmax => $opts->{zmax} } : {});

		my $region_tiles = coverageTotal($cov);
		display(0,0,sprintf("%-16s %d tiles",$id,$region_tiles));

		# THE INNER TOTAL IS KNOWN BEFORE THE WALK, which is why the bar
		# can be a bar rather than a spinner.  coverageTotal is already
		# computed here for the display line and costs nothing more.

		if ($prog)
		{
			$prog->{label}		= $id;
			$prog->{sub_total}	= $region_tiles;
			$prog->{sub_done}	= 0;
			$prog->{sub_label}	= '';
			$stats->{sub_done}	= 0;
		}

		for my $node (@$nodes)
		{
			my $src_id = $sources->{$node->{path}} || $fallback;
			my $src    = $src_id ? getSource($src_id) : undef;

			# REFUSED HERE RATHER THAN AT THE FIRST TILE.  A source that
			# names nothing installed is an authoring error, and reporting
			# it against the node that names it says which one to fix.

			if (!$src)
			{
				warning(0,1,"'$node->{id}' names source '$src_id', ".
					"which is not installed - skipped");
				next;
			}

			display($dbg_fill+1,1,"$node->{id} from '$src_id'");

			last if !_fillNode($src,$node->{levels},$stats,$opts);
		}

		$prog->{done}++ if $prog;

		last if $stats->{aborted};

		if (progressCancelled($prog) || ($opts->{stop} && ${$opts->{stop}}))
		{
			$stats->{cancelled} = 1;
			last;
		}
	}

	$stats->{secs} = time() - $stats->{started};
	return $stats;
}


1;
