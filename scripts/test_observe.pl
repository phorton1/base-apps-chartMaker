#!/usr/bin/perl
#---------------------------------------------
# test_observe.pl -- headless test of dm_observe.pm
#---------------------------------------------
# The observation record: what this machine has learned about a server, as
# opposed to what a TSD declares about it or what the cache knows about one
# tile.
#
# Three properties are worth more than the rest and each has a section
# below.  It must be BOUNDED, because it is written on every fetch forever.
# It must SURVIVE A RESTART, because the whole point is that the next
# preflight can quote a time.  And it must be PER SOURCE ON DISK, because
# the file it replaces held everything in one document and could only ever
# be rewritten whole.
#
# No network and no threads.  The thread safety is a lock discipline rather
# than an algorithm, and a test that spawned threads to poke at it would be
# testing Perl rather than this module.

use strict;
use warnings;
use JSON;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_observe;

my $TMP = 'C:/_temp/base-apps-chartMaker';
$Pub::Utils::temp_dir = "$TMP/observe";

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub readRecord
	# What actually reached disk, read back as plain JSON rather than
	# through this module -- otherwise a bug that never wrote anything
	# would be invisible, because the in-memory copy would answer.
{
	my ($key) = @_;
	my $path = obsDir()."/$key.json";
	return undef if !-f $path;
	open(my $fh,'<',$path) or return undef;
	binmode $fh;
	local $/;
	my $text = <$fh>;
	close $fh;
	return eval { decode_json($text) };
}


# A CLEAN SLATE, because half of what is asserted is whether something
# reached disk and a previous run's files would answer first.

if (-d obsDir())
{
	unlink glob(obsDir()."/*.json");
	unlink glob(obsDir()."/*.tmp");
}

# A source is identified by its cache_key, so a bare hash with one field
# in it is a complete stand-in here and nothing needs a .tsd on disk.

my $a = { cache_key => 'src_a', id => 'source_a' };
my $b = { cache_key => 'src_b', id => 'source_b' };


#---------------------------------------------
# the smoothed rate
#---------------------------------------------

print "=== the smoothed rate ===\n";

obsLoad();

ok(obsMsPerTile($a) == 0,"an unobserved source has no rate");

obsRecordRate($a,300);
ok(obsMsPerTile($a) == 300,"the first observation is taken as it stands");

# 300 * 0.7 + 800 * 0.3 = 450.  ONE BAD MINUTE OF WIFI MUST NOT BECOME THE
# NUMBER, which is the entire reason this is smoothed rather than replaced.

obsRecordRate($a,800);
ok(obsMsPerTile($a) == 450,
	"a second observation is folded in, not substituted (got ".
	obsMsPerTile($a).", want 450)");

obsRecordRate($a,0);
ok(obsMsPerTile($a) == 450,"a zero observation is ignored rather than averaged in");

obsRecordRate($a,-5);
ok(obsMsPerTile($a) == 450,"and so is a negative one");

ok(obsMsPerTile($b) == 0,"one source's observations do not reach another");


#---------------------------------------------
# per source on disk
#---------------------------------------------

print "\n=== one file per source ===\n";

obsFlushAll();

ok(-f obsDir()."/src_a.json","src_a reached disk");
ok(!-f obsDir()."/src_b.json",
	"src_b, which has no observations, has NO file - a flush writes ".
	"nothing in the common case");

my $on_disk = readRecord('src_a');
ok($on_disk && $on_disk->{ms_per_tile} == 450,"and the file holds the rate");

# A FLUSH WITH NOTHING DIRTY WRITES NOTHING.  Cheap to assert and it is the
# property that makes flushing on a clock free.

my $wrote = obsFlushAll();
ok($wrote == 0,"a second flush with nothing dirty writes no file at all");

obsRecordRate($b,120);
$wrote = obsFlushAll();
ok($wrote == 1,"and touching ONE source flushes exactly one file");


#---------------------------------------------
# surviving a restart
#---------------------------------------------

print "\n=== surviving a restart ===\n";

# obsLoad reads what is on disk into the live structure, which is what a
# fresh process does.  Reading into a process that already has the values
# proves nothing, so they are cleared first the only way a caller can --
# by loading over the top after the files were written by someone else.

my $n = obsLoad();
ok($n == 2,"obsLoad found 2 records (got $n)");
ok(obsMsPerTile($a) == 450,"src_a's rate survived");
ok(obsMsPerTile($b) == 120,"src_b's rate survived");


#---------------------------------------------
# what a fetch teaches it
#---------------------------------------------

print "\n=== learned from work that was happening anyway ===\n";

obsFetched($a,250);
obsFetched($a,250);
obsFetched($a,250);
my $rec = obsRecord($a);
ok($rec->{fetches} == 3,"three fetches counted (got $rec->{fetches})");
ok($rec->{rtt_ms} > 0,"a round trip time was learned ($rec->{rtt_ms}ms)");
ok($rec->{last_ok} > 0,"and the time of last successful contact");

# ROUND TRIP IS NOT MILLISECONDS PER TILE.  A paced or concurrent run has a
# throughput unrelated to its latency, so both are kept and neither is
# derived from the other.

ok($rec->{rtt_ms} != $rec->{ms_per_tile},
	"round trip ($rec->{rtt_ms}) and ms per tile ($rec->{ms_per_tile}) ".
	"are separate measurements");

obsAbsent($a);
ok(obsRecord($a)->{absents} == 1,"an absence is counted, and separately");

obsError($a,'transport');
obsError($a,'server');
$rec = obsRecord($a);
ok($rec->{errors_seen} == 2,"errors counted");
ok($rec->{last_error} eq 'server',"the last error class is kept");
ok($rec->{error_ring} eq 'transport,server',
	"and a short ring of recent ones (got '$rec->{error_ring}')");


#---------------------------------------------
# bounded by construction
#---------------------------------------------

print "\n=== bounded by construction ===\n";

# THE PROPERTY THE WHOLE DESIGN RESTS ON.  This is written on every fetch,
# forever, and it must not grow.  Twenty errors into a ring that keeps six
# is the cheap version of "run it for a month".

obsError($a,"class$_") for (1..20);
$rec = obsRecord($a);
my @ring = split(/,/,$rec->{error_ring});
ok(scalar(@ring) == 6,
	"20 errors into a ring of 6 leaves 6 (got ".scalar(@ring).")");
ok($ring[-1] eq 'class20',"and the newest is kept");
ok($ring[0] eq 'class15',"and the oldest is dropped");

# A CANDIDATE IS ONE ENTRY THAT COUNTS UP, not one entry per sighting.
# The repeat IS the evidence, so the number is the whole point of the
# record and it must survive being seen again.

obsCandidateFingerprint($a,2521,'f27d9de7f80c13501f470595e327aa6d',20,7,9);
obsCandidateFingerprint($a,2521,'f27d9de7f80c13501f470595e327aa6d',20,7,9);
my @cand = obsCandidates($a);
ok(scalar(@cand) == 1,
	"a fingerprint candidate is one entry, not one per sighting (got ".
	scalar(@cand).")");
ok($cand[0]{count} == 2,"and the sightings are counted (got $cand[0]{count})");
ok($cand[0]{bytes} == 2521 &&
   $cand[0]{md5} eq 'f27d9de7f80c13501f470595e327aa6d',
	"with the pair that identifies the body");
ok($cand[0]{z} == 20 && $cand[0]{x} == 7 && $cand[0]{y} == 9,
	"and the coordinate of the tile, so the picture can be found without ".
	"a second copy of it");

# COUNTS ARE HANDED OVER IN BATCHES, because a solid run of ten thousand
# identical tiles must not take this record's lock ten thousand times.

obsCandidateFingerprint($a,2521,'f27d9de7f80c13501f470595e327aa6d',20,7,9,64);
ok((obsCandidates($a))[0]{count} == 66,"a batch adds its whole delta");

# THE HIGHEST COUNTS KEEP THE SPACE.  Dropping the oldest would be wrong
# here: the entry seen ten thousand times is exactly the one a burst of
# one-off oddities would push out.

obsCandidateFingerprint($a,$_,sprintf("%032x",$_),1,1,1) for (1..20);
my @fps = obsCandidates($a);
ok(scalar(@fps) == 6,
	"candidates are bounded (got ".scalar(@fps).")");
ok($fps[0]{md5} eq 'f27d9de7f80c13501f470595e327aa6d',
	"and the most-seen candidate survived 20 one-off arrivals");

# THE WHOLE RECORD, WEIGHED.  A dozen scalars and two short lists is the
# commitment; a few hundred bytes is what that looks like on disk.

obsFlushAll();
my $size = -s obsDir()."/src_a.json";
ok($size < 2000,
	"the whole record is $size bytes after 20 errors and 21 candidates");


#---------------------------------------------
# rate limiting
#---------------------------------------------

print "\n=== a 429 and what it means ===\n";

# THE CONDITIONS ARE THE POINT.  A rate limit at four concurrent with no
# interval says something quite different from one at a request every two
# seconds, and a record that kept only "was rate limited" could not tell
# the engine which.

obsFetched($b,100) for (1..5);
ok(obsRecord($b)->{clean_requests} == 5,"clean requests counted");

obsRateLimited($b,250,4);
$rec = obsRecord($b);
ok($rec->{saw_429} == 1,"a 429 is remembered");
ok($rec->{saw_429_interval} == 250 && $rec->{saw_429_concurrency} == 4,
	"with the interval and concurrency it happened under");
ok($rec->{clean_requests} == 0,
	"and the clean run resets - the record moves DOWN instantly");
ok($rec->{ceiling} eq 'elastic',
	"the declared ceiling is now known to be elastic rather than believed");


#---------------------------------------------
# a corrupt file is not fatal
#---------------------------------------------

print "\n=== a corrupt record ===\n";

# THIS WHOLE TIER IS REGENERABLE.  Refusing to start over a damaged timing
# file would be absurd, so it is reported and skipped.

open(my $fh,'>',obsDir()."/src_bad.json") or die $!;
print $fh "{ this is not json";
close $fh;

my $n2 = obsLoad();
ok($n2 == 2,"a corrupt record is skipped, the other 2 still load (got $n2)");
ok(obsMsPerTile($a) > 0,"and the good records are intact");


print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
