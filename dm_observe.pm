#!/usr/bin/perl
#---------------------------------------------
# dm_observe.pm
#---------------------------------------------
# WHAT THIS MACHINE HAS LEARNED ABOUT A SERVER.
#
# There were two places facts about a source lived and neither of them
# fits this one.  A TSD is DECLARED, shareable and protocol level: it says
# what is true wherever the source is reachable, and it is written by a
# person.  The cache is DISCOVERED and per tile: it says what is at one
# coordinate.  Neither has a home for a discovered fact about the SERVER --
# how fast it answers this connection, whether it has ever rate limited
# us, whether its declared ceiling is honest.
#
# That is this module.  It is the tier between them, and it is the one
# both the fetch engine and the prober need.
#
# NOTHING HERE EVER EDITS A TSD.  A finding is promoted into a file by a
# human, deliberately, which is what keeps "declared, not detected" intact
# while still making detection worth doing.  The clearest case is
# fp_candidates: a source that answers with the same bytes over and over
# is probably saying "no tile", but only a person can look at the picture
# and decide.  So the candidate is remembered and never acted on.
#
# BOUNDED BY CONSTRUCTION, and that is a commitment rather than an
# accident.  Everything continuous is an EWMA, which deliberately forgets;
# everything event shaped is a ring of the last few.  A record is a dozen
# scalars and two short lists, permanently, however long the program runs.
# What grows without bound is the CACHE, and it always was -- tens of
# thousands of files, which is the user's real survey.  This is the small
# bounded thing beside it, and nothing PLACED ever belongs in it: a per
# location finding would need a spatial index, would go stale, and would
# recreate the declared coverage the TSD format deliberately refuses.
#
# ONE FILE PER SOURCE, AND A DIRTY BIT PER SOURCE.  The file this replaces
# held every source in one document, so it could only ever be rewritten
# whole.  Splitting it buys three things: no read-modify-write contention
# between threads touching different sources, a truncated write that loses
# one source's observations rather than all of them, and room for one
# source's content to grow without any of the others caring.  A flush
# writes nothing at all in the common case.
#
#	$temp_dir/observations/<cache_key>.json
#
# KEYED BY cache_key, THE SAME LEAF NAME THE CACHE USES, so a user has one
# name per source rather than two and can prune both together.  The honest
# consequence is that renaming a .tsd orphans its observations exactly as
# it orphans its cache, which is at least coherent and costs one run's
# measurements rather than anything durable.
#
# THE IN MEMORY COPY IS THE LIVE ONE AND THE FILE IS A CHECKPOINT OF IT.
# That is the opposite arrangement from the cache, and it is right here for
# the same reason it is wrong there: losing the last few seconds of timing
# observations costs nothing, and losing a tile costs a fetch.  Every in
# process reader - the preflight, the source list, the engine's own pacing
# decisions - reads the live structure and never the file.  Nothing in the
# running program is waiting on a flush.
#
# FLAT, NOT NESTED, BECAUSE IT IS SHARED.  Perl ithreads make a nested
# shared structure painful to build and easy to get subtly wrong, and this
# is read from the server threads, the build worker and the main thread
# alike.  So the store is ONE shared hash of scalars keyed "<key>/<field>",
# and the two list shaped fields are bounded comma joined strings.  It is
# the same discipline the build report already uses to cross a thread
# boundary as text, and it costs nothing: no field here is deep.

package dm_observe;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON;
use File::Path qw( make_path );
use Time::HiRes qw( time );
use Pub::Utils;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		obsLoad
		obsRecord
		obsField
		obsNote
		obsEwma
		obsFetched
		obsAbsent
		obsError
		obsRateLimited
		obsCandidateFingerprint
		obsMsPerTile
		obsRecordRate
		obsFlush
		obsFlushAll
		obsKeys
		obsDir
	);
}


our $dbg_observe:shared = 1;
	# 1  = quiet
	# 0  = one line per flush that actually wrote
	# -1 = every observation recorded


my $FLUSH_EVERY_SECS = 5;
	# HOW MANY SECONDS OF TIMING OBSERVATION TO RISK LOSING IN A CRASH, and
	# that is the whole question this constant answers.  Every value between
	# about five and thirty is equally fine, which is exactly why it is a
	# constant and not a preference: a user has no basis on which to choose
	# it and no outcome differs if they choose badly.  The rate knobs are
	# preferences because a connection, a conscience and a patience really
	# do differ between people.  This does not.

my $EWMA_OLD = 0.7;
my $EWMA_NEW = 0.3;
	# WEIGHTED TOWARDS WHAT WAS ALREADY KNOWN.  One run over a bad minute of
	# wifi should not become the number every future estimate is built on,
	# and one run over a good one should not either.

my $RING = 6;
	# How many recent events a ring shaped field keeps.  Small on purpose:
	# these answer "what has been going wrong lately", which needs a handful
	# and is actively harmed by a long tail that keeps a fixed problem alive
	# in the record.

my $CLEAN_RUN_REQUESTS = 2000;
	# Requests without a 429 before the record will call a ceiling honest.
	# LEARNED FROM WORK, NEVER FROM A BURST TEST: a fill sends thousands of
	# requests over hours, and "this many at this concurrency with no 429"
	# is a better empirical ceiling than any deliberate probe, obtained from
	# traffic that was going out anyway.  The one thing a burst test adds is
	# WHERE IT BREAKS, which is the one fact not worth having.


# THE FIELDS.  Every one is a scalar; the two marked as rings are comma
# joined and bounded to $RING entries.  A field that is not listed here is
# not written to disk, which keeps a typo from quietly inventing one.

my @FIELDS = qw(
	ms_per_tile rtt_ms fetches absents errors_seen
	last_ok last_error last_error_at error_ring
	saw_429 saw_429_at saw_429_interval saw_429_concurrency
	clean_requests clean_concurrency ceiling
	fp_candidates
	meta_family meta_zmax meta_format meta_probed_at );

# THE meta_ FIELDS COME FROM A DELIBERATE PROBE, everything else from work
# that was happening anyway.  They live in the same record because they are
# the same KIND of fact - discovered, about the server, this machine's
# knowledge rather than the author's claim - and separating them by how
# they were obtained would put one truth in two places.

my %IS_RING = ( error_ring => 1, fp_candidates => 1 );


my %obs:shared;			# "<cache_key>/<field>" => scalar
my %dirty:shared;		# cache_key => 1
my $last_flush:shared = 0;
my $loaded:shared = 0;


#---------------------------------------------
# where it lives
#---------------------------------------------

sub obsDir
{
	return "$temp_dir/observations";
}


sub _path
{
	my ($key) = @_;
	return obsDir()."/$key.json";
}


sub _keyOf
	# A source hash, or a bare cache_key string.  Callers in the data model
	# have the source in hand; the console and the tests sometimes only have
	# a name, and refusing them would mean a second entry point that did the
	# same thing.
{
	my ($src) = @_;
	return '' if !defined $src;
	return $src->{cache_key} || '' if ref($src) eq 'HASH';
	return $src;
}


#---------------------------------------------
# reading
#---------------------------------------------

sub obsField
{
	my ($src,$field) = @_;
	my $key = _keyOf($src);
	return '' if !$key;
	lock(%obs);
	my $got = $obs{"$key/$field"};
	return defined($got) ? $got : ($IS_RING{$field} ? '' : 0);
}


sub obsRecord
	# A PLAIN, UNSHARED COPY of one source's record.  Readers get something
	# they can hold, sort and hand to a renderer without a lock and without
	# any risk of writing back into the live structure by accident.
{
	my ($src) = @_;
	my $key = _keyOf($src);
	return {} if !$key;

	my $rec = { cache_key => $key };
	lock(%obs);
	for my $f (@FIELDS)
	{
		my $got = $obs{"$key/$f"};
		$rec->{$f} = defined($got) ? $got : ($IS_RING{$f} ? '' : 0);
	}
	return $rec;
}


sub obsKeys
	# Every source this machine has observed, which is NOT the same as every
	# source installed: a .tsd that has never been fetched from has no
	# record, and a record can outlive the file that made it.
{
	lock(%obs);
	my %seen;
	for my $k (keys %obs)
	{
		$seen{$1} = 1 if $k =~ m{^(.+)/[^/]+$};
	}
	return sort keys %seen;
}


#---------------------------------------------
# writing
#---------------------------------------------

sub obsNote
	# Set fields outright.  The dirty bit is per source, so a flush that
	# follows writes this one file and leaves the others alone.
{
	my ($src,$fields) = @_;
	my $key = _keyOf($src);
	return if !$key || !$fields;

	lock(%obs);
	for my $f (keys %$fields)
	{
		next if !grep { $_ eq $f } @FIELDS;
		$obs{"$key/$f"} = $fields->{$f};
	}
	$dirty{$key} = 1;
}


sub obsEwma
	# Fold one observation into a smoothed average, or seed it if this is
	# the first.  Zero and negative values are ignored rather than averaged
	# in: they are not fast measurements, they are absent ones.
{
	my ($src,$field,$value) = @_;
	my $key = _keyOf($src);
	return if !$key || !$value || $value <= 0;

	lock(%obs);
	my $was = $obs{"$key/$field"} || 0;
	$obs{"$key/$field"} = $was ?
		int($was * $EWMA_OLD + $value * $EWMA_NEW) : int($value);
	$dirty{$key} = 1;
}


sub _push
	# One entry onto a ring, oldest dropped.  Called with the lock held.
{
	my ($key,$field,$entry) = @_;
	my $was = $obs{"$key/$field"} || '';
	my @all = grep { length } split(/,/,$was);
	push @all,$entry;
	shift @all while @all > $RING;
	$obs{"$key/$field"} = join(',',@all);
}


sub obsFetched
	# THE BY-PRODUCT OF REAL WORK, and the reason this record can be
	# trusted.  Every successful fetch anywhere in the application - a pan
	# across the map, a preview, a fill, a build - passes through here, so
	# the numbers accumulate from traffic that was going out anyway rather
	# than from any deliberate measurement.
	#
	# ms IS THE ROUND TRIP OF ONE REQUEST, which is not the same as ms per
	# tile: a paced or concurrent run has a throughput unrelated to its
	# latency.  Both are kept because the engine needs the first to size a
	# worker pool and the preflight needs the second to quote a time.
{
	my ($src,$ms) = @_;
	my $key = _keyOf($src);
	return if !$key;

	obsEwma($src,'rtt_ms',$ms);

	lock(%obs);
	$obs{"$key/fetches"} = ($obs{"$key/fetches"} || 0) + 1;
	$obs{"$key/last_ok"} = int(time());

	# EVIDENCE TOWARDS AN HONEST CEILING.  Counted only while clean; a 429
	# resets it, which is what makes a long quiet run mean something.

	my $clean = ($obs{"$key/clean_requests"} || 0) + 1;
	$obs{"$key/clean_requests"} = $clean;
	$obs{"$key/ceiling"} = 'honest'
		if $clean >= $CLEAN_RUN_REQUESTS && !($obs{"$key/ceiling"} || '');

	$dirty{$key} = 1;
	display($dbg_observe+1,0,"obsFetched $key ${ms}ms (fetch $clean clean)");
}


sub obsAbsent
	# An absence the source asserted.  Counted separately from a fetch
	# because it is knowledge rather than failure, and separately from an
	# error because it will still be true tomorrow.
{
	my ($src) = @_;
	my $key = _keyOf($src);
	return if !$key;

	lock(%obs);
	$obs{"$key/absents"} = ($obs{"$key/absents"} || 0) + 1;
	$obs{"$key/last_ok"}  = int(time());
	$obs{"$key/clean_requests"} = ($obs{"$key/clean_requests"} || 0) + 1;
	$dirty{$key} = 1;
}


sub obsError
	# One failure, by CLASS rather than by prose.  The class is what has a
	# policy consequence; the prose is for a person reading a log.
{
	my ($src,$class) = @_;
	my $key = _keyOf($src);
	return if !$key;
	$class ||= 'unknown';

	lock(%obs);
	$obs{"$key/errors_seen"}  = ($obs{"$key/errors_seen"} || 0) + 1;
	$obs{"$key/last_error"}    = $class;
	$obs{"$key/last_error_at"} = int(time());
	_push($key,'error_ring',$class);
	$dirty{$key} = 1;
}


sub obsRateLimited
	# A 429, WITH THE CONDITIONS IT HAPPENED UNDER, which is the part that
	# makes it useful rather than merely alarming.  A rate limit at four
	# concurrent and no interval says something quite different from one at
	# a single request every two seconds.
	#
	# THE RECORD MOVES DOWN INSTANTLY AND CREEPS UP ONLY AFTER A LONG CLEAN
	# RUN.  So the clean counter resets here, and the ceiling is called
	# elastic - meaning the declared limit is not the real one and this
	# source has to be discovered rather than believed.
{
	my ($src,$interval_ms,$concurrency) = @_;
	my $key = _keyOf($src);
	return if !$key;

	lock(%obs);
	$obs{"$key/saw_429"}             = 1;
	$obs{"$key/saw_429_at"}          = int(time());
	$obs{"$key/saw_429_interval"}    = $interval_ms || 0;
	$obs{"$key/saw_429_concurrency"} = $concurrency || 0;
	$obs{"$key/clean_requests"}      = 0;
	$obs{"$key/ceiling"}             = 'elastic';
	_push($key,'error_ring','rate_limited');
	$obs{"$key/errors_seen"} = ($obs{"$key/errors_seen"} || 0) + 1;
	$dirty{$key} = 1;
}


sub obsCandidateFingerprint
	# A repeated body that MIGHT be the source's way of saying "no tile".
	#
	# REMEMBERED, NEVER ACTED ON.  Turning this into an absence
	# automatically is exactly the mistake the TSD format exists to prevent:
	# a source that legitimately serves identical tiles - solid ocean, a
	# uniform icecap - would have real imagery declared missing, and nothing
	# downstream could tell.  So a candidate waits here for a person to look
	# at the picture and put it in the file.
{
	my ($src,$bytes,$md5) = @_;
	my $key = _keyOf($src);
	return if !$key || !$bytes || !$md5;

	my $entry = "$bytes:$md5";
	lock(%obs);
	my $was = $obs{"$key/fp_candidates"} || '';
	return if index(",$was,",",$entry,") >= 0;
	_push($key,'fp_candidates',$entry);
	$dirty{$key} = 1;
	display($dbg_observe,0,"obsCandidateFingerprint $key $entry");
}


#---------------------------------------------
# what the preflight asks
#---------------------------------------------

sub obsRecordRate
	# Milliseconds per tile that was REALLY FETCHED, after a bounded act.
	# Cache hits are excluded by the caller because they say nothing about
	# the server and would make a mostly-cached run look infinitely fast,
	# which is exactly the estimate that would then mislead.
{
	my ($src,$ms_per_tile) = @_;
	obsEwma($src,'ms_per_tile',$ms_per_tile);
}


sub obsMsPerTile
{
	my ($src) = @_;
	return obsField($src,'ms_per_tile') + 0;
}


#---------------------------------------------
# disk
#---------------------------------------------

sub obsLoad
	# Read every record at startup.  A file that will not parse is reported
	# and skipped rather than fatal: this whole tier is regenerable, and
	# refusing to start over a corrupt timing file would be absurd.
{
	my $dir = obsDir();
	if (!-d $dir)
	{
		make_path($dir);
		return 0;
	}

	my $dh;
	if (!opendir($dh,$dir))
	{
		error("could not read $dir: $!");
		return 0;
	}
	my @leaves = grep { /\.json$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	my $n = 0;
	for my $leaf (@leaves)
	{
		my $key = $leaf;
		$key =~ s/\.json$//i;

		my $fh;
		next if !open($fh,'<',"$dir/$leaf");
		binmode $fh;
		local $/;
		my $text = <$fh>;
		close $fh;

		my $got = eval { decode_json($text) };
		if (!$got || ref($got) ne 'HASH')
		{
			warning(0,0,"observations: $leaf could not be read - ignoring it");
			next;
		}

		lock(%obs);
		for my $f (@FIELDS)
		{
			next if !defined $got->{$f} || ref($got->{$f});
			$obs{"$key/$f"} = $got->{$f};
		}
		$n++;
	}

	$loaded = 1;
	$last_flush = time();
	display($dbg_observe,0,"obsLoad() $n observation record".($n == 1 ? '' : 's').
		" from $dir");
	return $n;
}


sub _write
	# One record, via a temp file and a rename, exactly as the cache writes
	# a tile.  A crash mid-write then leaves the previous checkpoint intact
	# rather than a half a file that will not parse on the next start.
{
	my ($key) = @_;

	my $rec = {};
	{
		lock(%obs);
		for my $f (@FIELDS)
		{
			my $got = $obs{"$key/$f"};
			next if !defined $got;
			next if !$IS_RING{$f} && !$got;		# a zero says nothing
			next if $IS_RING{$f} && $got eq '';
			$rec->{$f} = $got;
		}
	}

	my $dir = obsDir();
	make_path($dir) if !-d $dir;

	my $path = _path($key);
	my $temp = "$path.tmp";

	my $fh;
	if (!open($fh,'>',$temp))
	{
		error("observations: could not write $temp: $!");
		return 0;
	}
	binmode $fh;
	print $fh JSON->new->canonical->pretty->encode($rec);
	close $fh;

	unlink $path if -f $path;
	if (!rename($temp,$path))
	{
		error("observations: could not rename $temp to $path: $!");
		return 0;
	}
	return 1;
}


sub obsFlush
	# ON A CLOCK, and it writes nothing at all in the common case because
	# nothing is dirty.
	#
	# THE CLOCK EXISTS BECAUSE BROWSING HAS NO END.  A fill or a build
	# finishes and can write once; a user moving around the map never
	# finishes, so a record that only wrote on completion would never
	# capture the round trip times that panning is measuring for free.  It
	# also cannot write per tile, since each write is a whole small file.
{
	my ($force) = @_;
	return 0 if !$force && (time() - $last_flush) < $FLUSH_EVERY_SECS;
	$last_flush = time();

	my @todo;
	{
		lock(%obs);
		@todo = sort keys %dirty;
		delete $dirty{$_} for @todo;
	}
	return 0 if !@todo;

	my $n = 0;
	$n += _write($_) for @todo;
	display($dbg_observe,0,"obsFlush() wrote $n record".($n == 1 ? '' : 's'));
	return $n;
}


sub obsFlushAll
	# At the end of any bounded act, and at program exit.  The same thing as
	# obsFlush with the clock ignored, named separately because the two
	# callers mean different things and reading 'obsFlush(1)' at a shutdown
	# would not say which.
{
	return obsFlush(1);
}


1;
