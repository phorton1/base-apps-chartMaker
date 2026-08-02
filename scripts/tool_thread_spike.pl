#!/usr/bin/perl
#---------------------------------------------
# tool_thread_spike.pl -- can this Perl carry a worker pool?
#---------------------------------------------
# MEASURED BEFORE THE ENGINE IS WRITTEN, because the engine's whole shape
# depends on the answers and finding them out afterwards would mean
# rewriting it.  Four questions, in the order that a bad answer would kill
# the design:
#
#	1  what does spawning N threads actually cost, and does it grow with
#	   how much the interpreter is holding when they spawn
#	2  can a Thread::Queue carry a BINARY blob intact - a jpeg is not text
#	   and Perl's shared scalars have opinions about that
#	3  does a shared pacing gate actually pace, measured from the outside
#	4  does a worker pool survive being handed the real modules
#
# This is a TOOL rather than a test: it reports numbers to decide a design
# with, and numbers are not pass or fail.  Run it, read it, then write the
# engine.

use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;
use Time::HiRes qw( time sleep );
use Digest::MD5 qw( md5_hex );

$| = 1;

printf("perl %vd, threads %s, threads::shared %s, Thread::Queue %s\n\n",
	$^V,$threads::VERSION,$threads::shared::VERSION,$Thread::Queue::VERSION);


#---------------------------------------------
# 1 -- what does a pool cost, and when
#---------------------------------------------
# THE REASON THE POOL LIVES FOR THE PROGRAM'S LIFETIME rests on this
# number.  ithreads CLONE THE INTERPRETER at spawn, so a pool created
# inside a build worker clones whatever that thread was holding.  If the
# cost is flat this is a micro-optimisation; if it scales with the heap it
# is the difference between a pool and no pool.

print "=== 1. spawn cost, small interpreter ===\n";

sub timeSpawn
{
	my ($n) = @_;
	my $t0 = time();
	my @thr = map { threads->create(sub { return 1 }) } (1..$n);
	my $spawned = time() - $t0;
	$_->join() for @thr;
	return ($spawned, time() - $t0);
}

for my $n (1,4,8,16)
{
	my ($spawn,$total) = timeSpawn($n);
	printf("  %2d threads: spawn %6.0f ms  (%5.1f ms each), joined at %6.0f ms\n",
		$n,$spawn*1000,$spawn*1000/$n,$total*1000);
}

# NOW WITH A FAT INTERPRETER.  20 MB of ordinary Perl data, which is a
# fair stand-in for a loaded region set plus a cache index plus wx.

print "\n=== 1b. spawn cost after allocating ~20 MB ===\n";
my @ballast;
push @ballast,{ id => "row_$_", data => ('x' x 200), n => $_ } for (1..40000);
printf("  ballast: %d hashes\n",scalar(@ballast));

for my $n (1,4,8,16)
{
	my ($spawn,$total) = timeSpawn($n);
	printf("  %2d threads: spawn %6.0f ms  (%5.1f ms each), joined at %6.0f ms\n",
		$n,$spawn*1000,$spawn*1000/$n,$total*1000);
}
@ballast = ();


#---------------------------------------------
# 2 -- can a queue carry a jpeg
#---------------------------------------------
# IF THIS FAILS THE ENGINE CANNOT RETURN BYTES and every result has to go
# back through the cache on disk, which is a different design.  Tested with
# real binary: high bytes, embedded NULs, and a length that matters.

print "\n=== 2. binary payloads across a Thread::Queue ===\n";

my $blob = join('',map { chr($_ % 256) } (0..65535));
my $want = md5_hex($blob);
printf("  test blob: %d bytes, md5 %s\n",length($blob),substr($want,0,16));

my $to_worker   = Thread::Queue->new();
my $from_worker = Thread::Queue->new();

my $echo = threads->create(sub {
	while (defined(my $item = $to_worker->dequeue()))
	{
		last if $item eq 'STOP';
		$from_worker->enqueue($item);
	}
	return 1;
});

$to_worker->enqueue($blob);
my $back = $from_worker->dequeue();
my $got  = md5_hex($back);

printf("  round trip: %d bytes, md5 %s -- %s\n",
	length($back),substr($got,0,16),
	($got eq $want && length($back) == length($blob)) ? "INTACT" : "CORRUPTED");

$to_worker->enqueue('STOP');
$echo->join();

# A SHARED SCALAR IS THE OTHER CANDIDATE and behaves differently enough to
# be worth measuring separately.

my $shared_blob:shared = '';
my $setter = threads->create(sub { $shared_blob = $blob; return 1 });
$setter->join();
printf("  shared scalar: %d bytes, md5 %s -- %s\n",
	length($shared_blob),substr(md5_hex($shared_blob),0,16),
	md5_hex($shared_blob) eq $want ? "INTACT" : "CORRUPTED");


#---------------------------------------------
# 3 -- does a shared gate actually pace
#---------------------------------------------
# THE GATE IS PER SOURCE AND SHARED, NOT PER WORKER, which is the only
# arrangement that produces one request per interval no matter how many
# workers are pushing.  Measured from OUTSIDE the gate: the engine's own
# numbers are what is being tested, so they cannot be the measurement.

print "\n=== 3. a shared per-source pacing gate ===\n";

my $INTERVAL = 0.050;			# 50 ms between requests
my $next_allowed:shared = 0;
my @stamps:shared;

sub gate
	# Wait until this source's next allowed time, then claim the one after
	# it.  The lock covers the read AND the write, which is the whole
	# point: two workers must not both see the same slot as free.
{
	my $wait = 0;
	{
		lock($next_allowed);
		my $now = time();
		$next_allowed = $now if $next_allowed < $now;
		$wait = $next_allowed - $now;
		$next_allowed += $INTERVAL;
	}
	sleep($wait) if $wait > 0;
}

my $started = time();
my @workers = map {
	threads->create(sub {
		for (1..5)
		{
			gate();
			my $at = time() - $started;
			lock(@stamps);
			push @stamps,$at;
		}
		return 1;
	})
} (1..4);
$_->join() for @workers;

my @sorted = sort { $a <=> $b } @stamps;
printf("  4 workers x 5 requests = %d, at %.0f ms interval\n",
	scalar(@sorted),$INTERVAL*1000);
printf("  elapsed %.0f ms, ideal %.0f ms\n",
	($sorted[-1] - $sorted[0])*1000,$INTERVAL*1000*(scalar(@sorted)-1));

my ($min_gap,$violations) = (999,0);
for my $i (1..$#sorted)
{
	my $gap = $sorted[$i] - $sorted[$i-1];
	$min_gap = $gap if $gap < $min_gap;
	$violations++ if $gap < $INTERVAL * 0.8;
}
printf("  smallest gap between ANY two requests: %.1f ms\n",$min_gap*1000);
printf("  gaps shorter than 80%% of the interval: %d -- %s\n",
	$violations,$violations ? "THE GATE LEAKS" : "the gate holds");


#---------------------------------------------
# 4 -- a pool that outlives its work
#---------------------------------------------
# THE POOL IS SPAWNED ONCE AND FED FOREVER, which is not the same thing as
# spawning threads per job.  What matters here is that a worker blocked on
# an empty queue costs nothing and wakes promptly.

print "\n=== 4. a persistent pool, fed and drained ===\n";

my $work    = Thread::Queue->new();
my $results = Thread::Queue->new();
my $POOL    = 4;

my @pool = map {
	my $id = $_;
	threads->create(sub {
		while (defined(my $job = $work->dequeue()))
		{
			last if $job eq 'STOP';
			$results->enqueue("$id:$job");
		}
		return $id;
	})
} (1..$POOL);

printf("  pool of %d spawned, idle\n",$POOL);
sleep(0.25);
printf("  after 250 ms idle, all still alive: %s\n",
	(scalar(grep { $_->is_running() } @pool) == $POOL) ? "yes" : "NO");

my $t0 = time();
$work->enqueue("job$_") for (1..200);
my %by_worker;
for (1..200)
{
	my $r = $results->dequeue();
	my ($who) = $r =~ /^(\d+):/;
	$by_worker{$who}++;
}
printf("  200 jobs through the pool in %.0f ms\n",(time()-$t0)*1000);
printf("  spread across workers: %s\n",
	join(', ',map { "w$_=$by_worker{$_}" } sort keys %by_worker));

$work->enqueue('STOP') for (1..$POOL);
$_->join() for @pool;
print "  pool joined cleanly\n";

print "\nspike complete\n";
