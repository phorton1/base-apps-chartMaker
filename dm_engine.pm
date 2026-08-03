#!/usr/bin/perl
#---------------------------------------------
# dm_engine.pm
#---------------------------------------------
# ONE PATH FROM A COORDINATE TO BYTES, and browsing, filling, sampling and
# probing are four callers of it with different priorities and budgets.
#
# THE ENGINE SITS BELOW getTile's CALLERS, NOT ABOVE dm_fill.  That is the
# whole architecture in one line and it was arrived at by rejecting the
# obvious alternative.  Putting it at or above the fill would leave the map
# proxy unpaced -- panning is unbounded traffic aimed at somebody else's
# server -- and would let a future prober bypass the limiter entirely,
# which is the worst possible new bypass, since half of what a prober wants
# to measure is found by pushing.
#
#	proxy (interactive)   fill (bulk)   sampler (bulk)
#	          \               |              /
#	           +--------------+-------------+
#	                          |
#	                     THE ENGINE
#	     queue, two priorities, per-source pacing gate,
#	     concurrency, classification, backoff
#	                          |
#	                  getTile  (cache first)
#
# COMPOSITION, ONE OPERATOR PER AXIS:
#
#	interval    = max( tsd.min_interval_ms, pref.min_interval,
#	                   cfg.advisory, backoff )
#	concurrency = min( tsd.max_concurrency, pref.max_concurrent,
#	                   ceil(rtt/interval) )
#
# Slowest wins, fewest wins.  Every knob at every tier can only make the
# client GENTLER, and no combination of settings anywhere goes faster than
# the TSD declared.  Backoff is in the max() for exactly that reason: it is
# another voice that can only slow things down, and a fifth contributor
# later costs nothing.
#
# CONCURRENCY IS LATENCY COVER AND THAT BOUNDS IT.  At interval I and round
# trip R, serial gets one tile per max(I,R).  The useful worker count is
# ceil(R/I); beyond that they idle.  So the engine computes its own figure
# from the MEASURED round trip rather than believing max_concurrency, and
# the interval gate is PER SOURCE -- one shared next-allowed-time -- rather
# than per worker, which is the only arrangement that yields one request
# per interval however many workers are pushing.
#
# THE POOL IS THE GLOBAL CEILING and it lives for the program's lifetime.
# Measured on this machine: spawning a thread costs 5 ms against a small
# interpreter and 44 ms against one holding 20 MB, so a pool created inside
# a build worker would cost nine times what one created at startup does,
# and would grow worse the longer the session ran.  A source's declared
# max_concurrency cannot raise the pool; it is a permit count within it.
#
# THE ENGINE GOVERNS WHEN A REQUEST GOES OUT, NEVER WHEN A RESULT IS
# STORED.  Tiles still commit one at a time, on arrival, in every mode --
# panning the map, a preview, a fill and a build alike.  The two properties
# that depend on that are resume being nearly free and the coverage picture
# accumulating from ordinary use, and neither is the engine's to spend.
#
# IT IS OPTIONAL AND THE APPLICATION WORKS WITHOUT IT.  With no pool
# started, engineFetch does the fetch on the calling thread, paced by the
# same gate.  That is not a fallback bolted on for safety: the console
# fills a cache with no wx anywhere, and every headless test runs this way,
# so a path that only worked with a pool running would be a path that could
# not be tested.

package dm_engine;
use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;
use Time::HiRes qw( time sleep );
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_source;
use dm_observe;

# NOT 'use dm_fetch', DELIBERATELY.  dm_fetch uses THIS module - getTile is
# the engine's front door - so a use in both directions is a cycle, and a
# cycle in Perl resolves by whichever file the loader reached first, which
# is a coin toss that shows up as a missing subroutine.  The dependency is
# real but it runs one way at compile time and the other way at run time,
# so fetchTile is called fully qualified below.  By then dm_fetch has
# finished compiling, because nothing can reach this module except through
# it.


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		engineStart
		engineStop
		engineRunning
		engineFetch
		engineSubmit
		engineCollect
		engineInterval
		engineConcurrency
		engineStats

		$PRIORITY_INTERACTIVE
		$PRIORITY_BULK
	);
}


our $dbg_engine:shared = 1;
	# 1  = quiet
	# 0  = pool start and stop, and every backoff
	# -1 = one line per job


our $PRIORITY_INTERACTIVE = 'i';
our $PRIORITY_BULK        = 'b';


my $RETRY_LIMIT = 3;
	# How many times a RETRYABLE class is tried again before the tile is
	# reported as failed.  Small on purpose: the retries that help are the
	# ones for a blip, and a source that is really down produces thousands
	# of tiles each burning three requests.

my $BACKOFF_START_MS = 2000;
my $BACKOFF_MAX_MS   = 60000;
	# BACKOFF APPLIES TO THE SOURCE, NOT TO THE TILE.  A 429 slows
	# everything aimed at that source; it does not mean retry this
	# coordinate sooner.  It doubles to a minute and decays on success.

my $DEFAULT_POOL = 4;

my $MAX_POOL = 12;
	# THE HARD CEILING, AND IT IS AN ADDRESS SPACE LIMIT RATHER THAN A
	# TASTE ONE.  This is a 32 bit perl - MSWin32-x86, ptrsize 4 - so the
	# process has about 2 GB to address, and every ithread clones the
	# interpreter into it.  MEASURED at 27 MB per thread, steady from 4
	# threads to 40, against a 186 MB baseline with the data model and wx
	# loaded and no frame built.
	#
	# At 32 the application DOES NOT START.  The pool is spawned before the
	# http server, takes the room, and then ServerBase's threads->create
	# returns undef and it dies calling detach on it - before any window
	# exists, with the reason on stderr where the output ring never sees it.
	#
	# 12 costs about 324 MB and leaves the failure out of reach.  Nothing
	# shipped can use more anyway: the most any source declares is Esri's
	# max_concurrency of 6, and engineConcurrency takes the min.


#---------------------------------------------
# the shared state
#---------------------------------------------
# ALL FLAT, for the reason dm_observe gives at length: a nested shared
# structure in this Perl is painful to build and easy to get subtly wrong,
# and nothing here is deep.

my $queue;						# Thread::Queue of encoded jobs
my @pool;						# the worker threads
my $pool_size:shared    = 0;
my $running:shared      = 0;
my $next_job:shared     = 0;

my %result:shared;				# "<job>/<field>" => scalar
my %gate:shared;				# cache_key => next allowed epoch
my %inflight:shared;			# cache_key => requests out right now
my %backoff:shared;				# cache_key => current backoff ms
my %backoff_until:shared;		# cache_key => epoch it expires

my %counters:shared;			# name => n, for engineStats


sub _bump
{
	my ($name) = @_;
	lock(%counters);
	$counters{$name} = ($counters{$name} || 0) + 1;
}


#---------------------------------------------
# composition
#---------------------------------------------

sub engineInterval
	# THE SLOWEST VOICE WINS.  Any of these may make the client gentler and
	# none of them may make it faster, which is what makes the whole set
	# safe to extend: adding a contributor can never produce a combination
	# that goes faster than the TSD declared.
	#
	# advisory_ms is passed IN rather than read here, because it comes from
	# a build configuration that belongs to one run and does not exist for
	# the map proxy.  The engine has no opinion about where it came from.
{
	my ($source,$advisory_ms) = @_;
	return 0 if !$source;

	my $tsd  = $source->{policy}{min_interval_ms} || 0;
	my $pref = prefVal($PREF_MIN_INTERVAL) || 0;
	my $adv  = $advisory_ms || 0;

	my $key  = $source->{cache_key} || '';
	my $back = 0;
	{
		lock(%backoff);
		$back = $backoff{$key} || 0
			if ($backoff_until{$key} || 0) > time();
	}

	my $ms = $tsd;
	$ms = $pref if $pref > $ms;
	$ms = $adv  if $adv  > $ms;
	$ms = $back if $back > $ms;
	return $ms;
}


sub engineConcurrency
	# FEWEST WINS, and the third term is the one that is actually
	# interesting.  A source declaring six concurrent is describing what it
	# will TOLERATE, not what is useful: at a 500 ms interval and a 200 ms
	# round trip, a second worker has nothing to do but wait.  ceil(R/I) is
	# how many are needed to cover the latency and no more.
	#
	# WITH NO INTERVAL THERE IS NOTHING TO COVER FOR, so the measured term
	# drops out and the declared ceiling stands - which is the unpaced case,
	# and the only one where a source's own number is the binding limit.
{
	my ($source,$advisory_ms) = @_;
	return 1 if !$source;

	my $tsd  = $source->{policy}{max_concurrency} || $DEFAULT_POOL;
	my $pref = prefVal($PREF_MAX_CONCURRENT) || $DEFAULT_POOL;

	my $n = $tsd;
	$n = $pref if $pref < $n;

	my $interval = engineInterval($source,$advisory_ms);
	if ($interval > 0)
	{
		my $rtt   = obsField($source,'rtt_ms') || 0;
		my $cover = $rtt > 0 ? int(($rtt + $interval - 1) / $interval) : 1;
		$cover = 1 if $cover < 1;
		$n = $cover if $cover < $n;
	}

	$n = 1 if $n < 1;
	return $n;
}


#---------------------------------------------
# the gate
#---------------------------------------------

sub _claimSlot
	# WAIT UNTIL THIS SOURCE'S NEXT ALLOWED TIME, THEN CLAIM THE ONE AFTER.
	#
	# The lock covers the read AND the write, which is the entire point: two
	# workers must not both see the same slot as free.  The sleep happens
	# OUTSIDE the lock, or one waiting worker would block every other
	# source's workers too.
	#
	# WHAT IS EXACT IS THE RATE; WHAT JITTERS IS ONE GAP.  Reservations are
	# spaced perfectly because they are absolute times taken under a lock,
	# but a worker wakes when the platform gets round to it, and Windows'
	# scheduler tick is 15.6 ms - measured here, a requested 25 ms sleep
	# takes 31 ms and a 5 ms sleep takes 15 ms.  A worker that wakes late
	# fires late and eats into the slot reserved after it, so consecutive
	# ARRIVALS vary by up to about one tick either side of the interval
	# while the long-run rate stays correct.
	#
	# Measured, 40 requests at each interval, with the smallest observed
	# gap and how many fell under 80 percent of the target:
	#
	#	 25 ms   rate +3%     smallest 14 ms    14 of 39 under
	#	 60 ms   rate +1%     smallest 47 ms     1 of 39 under
	#	120 ms   rate +0.4%   smallest 108 ms    0 of 39 under
	#	250 ms   rate +0.1%   smallest 235 ms    0 of 39 under
	#	500 ms   rate +0.1%   smallest 488 ms    0 of 39 under
	#
	# So the jitter is a constant of the platform rather than a proportion,
	# and it disappears into the noise at any interval a person would
	# actually set for politeness.  THE ERROR IS ALWAYS IN THE SAFE
	# DIRECTION: every measured total came out at or slower than the ideal,
	# never faster, because a late wake never advances the next reservation.
	#
	# Sleeping to just short of the target and busy-waiting the remainder
	# would remove the jitter and is deliberately not done: it would burn a
	# core to make a number look tidy, and the thing a provider actually
	# cares about is the rate of arrivals rather than any single gap.
{
	my ($key,$interval) = @_;
	return if !$interval;

	my $wait = 0;
	{
		lock(%gate);
		my $now  = time();
		my $next = $gate{$key} || 0;
		$next = $now if $next < $now;
		$wait = $next - $now;
		$gate{$key} = $next + $interval / 1000;
	}
	sleep($wait) if $wait > 0;
}


sub _claimPermit
	# PER SOURCE CONCURRENCY, INSIDE THE POOL.  A permit is not a thread:
	# the pool size is the global ceiling and this only stops one source
	# from occupying all of it.  Spins rather than waiting on a condition
	# because the wait is bounded by one request and the contention is low.
{
	my ($key,$limit) = @_;
	while (1)
	{
		{
			lock(%inflight);
			my $now = $inflight{$key} || 0;
			if ($now < $limit)
			{
				$inflight{$key} = $now + 1;
				return;
			}
		}
		sleep(0.01);
	}
}


sub _releasePermit
{
	my ($key) = @_;
	lock(%inflight);
	my $now = $inflight{$key} || 0;
	$inflight{$key} = $now > 0 ? $now - 1 : 0;
}


sub _backOff
	# A RATE LIMIT SLOWS THE SOURCE, and doubles if it happens again while
	# already backed off.  Retry-After is obeyed when the server gave one,
	# because a number the server chose beats a number we invented.
{
	my ($key,$retry_after) = @_;

	lock(%backoff);
	my $was = $backoff{$key} || 0;
	my $now = $was ? $was * 2 : $BACKOFF_START_MS;
	$now = $BACKOFF_MAX_MS if $now > $BACKOFF_MAX_MS;
	$now = $retry_after * 1000
		if $retry_after && $retry_after * 1000 > $now;

	$backoff{$key}       = $now;
	$backoff_until{$key} = time() + $now / 1000;

	display($dbg_engine,0,"engine: backing off '$key' to ${now}ms".
		($retry_after ? " (Retry-After ${retry_after}s)" : ''));
	_bump('backoffs');
}


sub _backOffDecay
	# A CLEAN RESULT RELAXES IT, halving rather than clearing.  Clearing
	# outright would send the next burst straight back into the limit,
	# which is how a client oscillates instead of settling.
{
	my ($key) = @_;
	lock(%backoff);
	return if !$backoff{$key};
	my $now = int($backoff{$key} / 2);
	if ($now < $BACKOFF_START_MS / 2)
	{
		delete $backoff{$key};
		delete $backoff_until{$key};
		return;
	}
	$backoff{$key} = $now;
	$backoff_until{$key} = time() + $now / 1000;
}


#---------------------------------------------
# doing one job
#---------------------------------------------

sub _doFetch
	# THE ONE PLACE A REQUEST ACTUALLY LEAVES, whether a worker or the
	# calling thread is running it.  Gate, permit, fetch, classify, retry,
	# and hand back a result.  Everything above this decides WHETHER; this
	# decides nothing except how many times to try.
{
	my ($source,$z,$x,$y,$advisory) = @_;
	my $key = $source->{cache_key} || $source->{id};

	my $tries = 0;
	my $result;

	while (1)
	{
		$tries++;
		my $interval = engineInterval($source,$advisory);
		my $limit    = engineConcurrency($source,$advisory);

		# PERMIT FIRST, THEN SLOT, THEN FETCH WITH NOTHING IN BETWEEN.
		#
		# _claimSlot reserves an instant and waits for it, so a request
		# leaves on time only if nothing delays it afterwards.  Claiming
		# the permit SECOND would put an unbounded wait between the
		# reservation and the request: a worker could hold a slot while
		# blocked on a permit, fire late, and eat into the slot reserved
		# after it.  Taking the permit first means the wait happens while
		# already holding one, so the reservation is the last thing before
		# the request.
		#
		# Permits are held for longer this way, which is not a cost: a
		# paced source has no use for concurrency beyond ceil(rtt/interval)
		# and engineConcurrency already says so.

		_claimPermit($key,$limit);
		_claimSlot($key,$interval);
		$result = eval { dm_fetch::fetchTile($source,$z,$x,$y) };
		my $died = $@;
		_releasePermit($key);

		# A WORKER MUST NOT DIE OF SOMEBODY ELSE'S BUG.  One thrown
		# exception inside a pool thread would take the worker out and
		# quietly shrink the pool for the rest of the session, which would
		# look like the application getting slower rather than like a fault.

		if ($died || !$result)
		{
			my $why = $died || 'the fetch returned nothing';
			$why =~ s/\s+/ /g;
			$result = { status => 'error', class => 'transport',
				reason => "internal: ".substr($why,0,120) };
		}

		_bump('requests');

		# THE OBSERVATION RECORD LEARNS FROM WORK THAT WAS HAPPENING ANYWAY,
		# and this is the only place that sees all of it.  Every caller
		# reaches the network through here - the map proxy, the preview, the
		# evaluator, a fill, a build - so panning around measures a server's
		# round trip for free, and a fill contributes thousands of requests
		# towards knowing whether its declared ceiling is honest.
		#
		# EVERY ATTEMPT, INCLUDING THE ONES THAT WILL BE RETRIED.  A retry
		# is a real request that really went out, and a record that counted
		# only final outcomes would understate what this machine actually
		# sent - which is the number that matters to whoever is on the far
		# end of it.
		#
		# It was in getTile until dm_fill stopped going through getTile.

		# WHAT IT MEANS AND WHAT TO KEEP, at the one place a request lands.
		#
		# The sentinel check and the cache write live here for exactly the
		# reason the observation record does: this is the ONLY route to the
		# network, and anything hanging off "the only route" has to be here
		# rather than in one of its callers.  They were in getTile, which
		# stopped being the only route the moment dm_fill became a client of
		# this engine - and a fill then cached nothing at all.
		#
		# BEFORE the observation record is written, because a body that
		# turns out to be the source's 'no data' tile is an ABSENCE, and
		# recording it as a successful fetch would teach the record that a
		# service which answers every request with a sentinel is healthy.

		$result = dm_fetch::fetchStore($source,$z,$x,$y,$result);

		my $status = $result->{status} // 'error';
		my $class  = $result->{class}  || '';

		if ($status eq 'ok')
		{
			obsFetched($source,$result->{ms});
		}
		elsif ($status eq 'absent')
		{
			obsAbsent($source) if defined $result->{ms};
		}
		elsif ($class ne 'rate_limited')
		{
			# A rate limit is recorded by _backOff below instead, because
			# only that path knows the interval and concurrency it happened
			# under - which is the whole of what makes a 429 useful rather
			# than merely alarming.

			obsError($source,$class || 'unknown');
		}

		# ON A CLOCK, so browsing checkpoints itself.  A pan across the map
		# is a bounded act to nobody, so there is no later moment at which
		# what it measured would otherwise be written.

		obsFlush();

		if ($status ne 'error')
		{
			_backOffDecay($key);
			last;
		}

		# EACH CLASS HAS EXACTLY ONE POLICY CONSEQUENCE, and this is where
		# they are spent.  auth and garbage are not retried at all: a
		# credential problem cannot be fixed by asking again, and a 200 that
		# is not an image will not become one.

		if ($class eq 'rate_limited')
		{
			_backOff($key,$result->{retry_after});
			obsRateLimited($source,$interval,$limit);
			next if $tries <= $RETRY_LIMIT;
			last;
		}

		if ($class eq 'auth' || $class eq 'garbage')
		{
			_bump('unretried');
			last;
		}

		# transport and server: try again a few times.
		last if $tries > $RETRY_LIMIT;
		_bump('retries');
	}

	$result->{tries} = $tries;
	return $result;
}


#---------------------------------------------
# the pool
#---------------------------------------------

sub _encode
{
	my ($job,$src_id,$z,$x,$y,$advisory) = @_;
	return join("\t",$job,$src_id,$z,$x,$y,$advisory || 0);
}


sub _worker
	# ONE WORKER, FOR THE LIFE OF THE PROGRAM.  It resolves the source by id
	# rather than being handed one, because a source hash is a nest of
	# references and cannot cross a thread boundary -- and because
	# dm_source already gives every thread its own copy, refreshed through a
	# shared generation counter.  That machinery exists for the http server
	# threads and this is the same problem.
{
	my ($me) = @_;

	while (defined(my $encoded = $queue->dequeue()))
	{
		last if $encoded eq 'STOP';

		my ($job,$src_id,$z,$x,$y,$advisory) = split(/\t/,$encoded);
		display($dbg_engine-1,0,"engine worker $me: $src_id $z/$x/$y");

		my $src = getSource($src_id);
		my $result = $src ?
			_doFetch($src,$z,$x,$y,$advisory) :
			{ status => 'error', class => 'auth',
			  reason => "source '$src_id' is not installed" };

		_publish($job,$result);
	}

	display($dbg_engine,0,"engine worker $me: stopped");
	return $me;
}


sub _publish
	# THE RESULT CROSSES BACK AS FLAT FIELDS, one shared hash keyed
	# "<job>/<field>".  Binary is fine in a shared scalar -- measured, a
	# 64 KB blob of every byte value round trips with its digest intact --
	# so the tile itself comes back rather than being re-read from disk.
{
	my ($job,$result) = @_;

	lock(%result);
	$result{"$job/status"} = $result->{status} // 'error';
	$result{"$job/http"}   = $result->{http}   // 0;
	$result{"$job/ms"}     = $result->{ms}     // 0;
	$result{"$job/class"}  = $result->{class}  // '';
	$result{"$job/reason"} = $result->{reason} // '';
	$result{"$job/format"} = $result->{format} // '';
	$result{"$job/tries"}  = $result->{tries}  // 1;
	$result{"$job/bytes"}  = $result->{bytes} ? ${$result->{bytes}} : '';
	$result{"$job/done"}   = 1;
	cond_broadcast(%result);
}


sub _collectOne
	# Wait for one job and take its fields out of the shared store.  The
	# delete matters: leaving them would make this hash the one unbounded
	# thing in the design.
{
	my ($job) = @_;

	my $out = {};
	lock(%result);
	cond_wait(%result) until $result{"$job/done"};

	$out->{status} = delete $result{"$job/status"};
	$out->{http}   = delete $result{"$job/http"};
	$out->{ms}     = delete $result{"$job/ms"};
	$out->{class}  = delete $result{"$job/class"};
	$out->{reason} = delete $result{"$job/reason"};
	$out->{format} = delete $result{"$job/format"};
	$out->{tries}  = delete $result{"$job/tries"};

	my $bytes = delete $result{"$job/bytes"};
	$out->{bytes} = \$bytes if defined($bytes) && length($bytes);

	delete $result{"$job/done"};

	$out->{http}  = undef if !$out->{http};
	$out->{class} = undef if !length($out->{class}  // '');
	$out->{format}= undef if !length($out->{format} // '');
	return $out;
}


sub engineStart
	# SPAWNED ONCE, AS EARLY AS POSSIBLE.  See the measurement at the top:
	# the cost is per thread and scales with what the interpreter is
	# holding, so this belongs beside loadSources and before wx exists.
{
	my ($n) = @_;
	return 0 if $running;

	$n ||= prefVal($PREF_MAX_CONCURRENT) || $DEFAULT_POOL;
	$n = 1  if $n < 1;
	$n = $MAX_POOL if $n > $MAX_POOL;

	# THREAD CREATION CAN FAIL, AND IT FAILS QUIETLY.  This is a 32 bit
	# perl, so the process has a 2 GB address space and every ithread
	# clones the interpreter into it.  Past some count that depends on how
	# much the interpreter is holding, threads->create RETURNS UNDEF rather
	# than dying - measured in a bare interpreter at 109 threads, and at 43
	# with only 20 MB of data loaded.
	#
	# Taking the result on trust was worse than the failure it hides: the
	# array would hold undefs, $pool_size would claim workers that do not
	# exist, and engineStop would die calling join on undef - at exit, long
	# after anyone could connect it to a pool that came up short.

	$queue = Thread::Queue->new();
	@pool  = ();

	for my $i (1..$n)
	{
		my $t = threads->create(\&_worker,$i);
		if (!$t)
		{
			warning(0,0,"engineStart: could only create ".scalar(@pool).
				" of $n workers - this perl is 32 bit and ran out of room. ".
				"Lower MAX_CONCURRENT.");
			last;
		}
		push @pool,$t;
	}

	# A POOL OF NOTHING WOULD BE WORSE THAN NO POOL, because a submitted
	# job would sit in a queue nobody is reading and every caller would
	# block on it forever.  Falling back to unpooled means fetches happen
	# on the calling thread through the same gate - slower, and working.

	if (!@pool)
	{
		error("engineStart: no workers could be created - fetches will ".
			"happen on the calling thread");
		$queue = undef;
		return 0;
	}

	$pool_size = scalar(@pool);
	$running   = 1;

	display($dbg_engine,0,"engineStart() pool of $pool_size");
	return $pool_size;
}


sub engineStop
{
	return 0 if !$running;
	$running = 0;

	$queue->enqueue('STOP') for (1..$pool_size);
	$_->join() for @pool;
	@pool = ();

	display($dbg_engine,0,"engineStop() pool joined");
	return 1;
}


sub engineRunning { return $running ? $pool_size : 0 }


#---------------------------------------------
# what callers use
#---------------------------------------------

sub engineSubmit
	# PUT A TILE IN THE QUEUE AND RETURN A TICKET.  Interactive work goes to
	# the FRONT, which is the two-class queue in one line: an interactive
	# request waits for the shortest in-flight request rather than for the
	# backlog, and never preempts one.  A fill of nine thousand tiles
	# therefore costs a panning user one round trip, not an hour.
{
	my ($source,$z,$x,$y,$priority,$advisory) = @_;
	return undef if !$source;

	my $job;
	{
		lock($next_job);
		$job = ++$next_job;
	}

	# WITH NO POOL, THE WORK HAPPENS NOW AND THE TICKET IS ALREADY SPENT.
	#
	# Submit and collect have to stay usable in both modes or every caller
	# grows a branch, and a branch here would mean the console and the
	# headless tests exercised a different path from the application -- for
	# the one piece of code whose entire job is pacing.  So the unpooled
	# case fetches on this thread and publishes the result against the
	# ticket, and engineCollect finds it waiting.
	#
	# There is no concurrency in this mode, which is not a limitation being
	# worked around: with no pool there ARE no other threads to overlap
	# with, and the gate paces it identically either way.

	if (!$running)
	{
		_publish($job,_doFetch($source,$z,$x,$y,$advisory));
		return $job;
	}

	my $encoded = _encode($job,$source->{id},$z,$x,$y,$advisory);
	if (($priority || $PRIORITY_BULK) eq $PRIORITY_INTERACTIVE)
	{
		$queue->insert(0,$encoded);
		_bump('interactive');
	}
	else
	{
		$queue->enqueue($encoded);
		_bump('bulk');
	}
	return $job;
}


sub engineCollect
{
	my ($job) = @_;
	return undef if !defined $job;
	return _collectOne($job);
}


sub engineFetch
	# THE SYNCHRONOUS FRONT DOOR, and what getTile calls.
	#
	# WITH NO POOL IT DOES THE WORK HERE, through the same gate.  That is
	# what keeps the console, the headless tests and a packaged build that
	# never starts a pool on exactly one code path -- and it means the
	# pacing rules are exercised by every test rather than only by the
	# threaded one.
{
	my ($source,$z,$x,$y,$priority,$advisory) = @_;

	if (!$running)
	{
		return _doFetch($source,$z,$x,$y,$advisory);
	}

	my $job = engineSubmit($source,$z,$x,$y,$priority,$advisory);
	return _collectOne($job);
}


sub engineStats
	# What the engine has done, for the console and for a test to assert
	# on.  Deliberately counters rather than history: this is the same
	# bounded-by-construction rule the observation record follows.
{
	lock(%counters);
	my $out = { pool => ($running ? $pool_size : 0), queued => 0 };
	$out->{$_} = $counters{$_} for keys %counters;
	$out->{queued} = $queue->pending() if $queue;

	# UNCOLLECTED RESULTS, which is the one number here that should always
	# come back to zero.  A ticket is a claim on this store and only a
	# collect releases it, so a caller that walks away from a job it
	# submitted leaks a row - and this is how a test can say so rather than
	# waiting for a week-long session to show it.

	{
		lock(%result);
		my %jobs;
		$jobs{$1} = 1 for grep { m{^(\d+)/} && ($1) } keys %result;
		$out->{uncollected} = scalar(keys %jobs);
	}

	# IN FLIGHT PER SOURCE, which should also settle to zero.  A permit
	# leak would not show up as an error: it shows up as a source that
	# gradually stops being fetched at all, which is much harder to trace
	# back here from where it is noticed.

	{
		lock(%inflight);
		my @busy = grep { $inflight{$_} } keys %inflight;
		$out->{inflight} = join(',',map { "$_=$inflight{$_}" } sort @busy);
	}

	{
		lock(%backoff);
		my @backed = grep { ($backoff_until{$_} || 0) > time() } keys %backoff;
		$out->{backed_off} = join(',',sort @backed);
	}
	return $out;
}


1;
