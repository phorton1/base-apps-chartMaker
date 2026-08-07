#!/usr/bin/perl
#---------------------------------------------
# test_engine.pl -- the fetch engine
#---------------------------------------------
# EVERYTHING HERE IS MEASURED FROM OUTSIDE THE ENGINE.  The engine's own
# counters are what is being tested, so they cannot be the measurement:
# the stub server records the arrival time of every request it receives,
# and the assertions are about THOSE.  A pacing gate that believed it had
# paced and had not would pass any test built on its own numbers.
#
# The stub is also the only way to reach half of this.  Nobody can ask Esri
# for a 429, for a 403, or for a 500 that recovers on the third try, and a
# retry policy that has never seen a failure is a policy nobody has tested.
#
# The pool runs REAL THREADS.  ithreads clone the interpreter at spawn and
# this Perl is 5.12, so "does the pool work at all" is a genuine question
# and not a formality - see scripts/tool_thread_spike.pl for the numbers
# the design was chosen on.

use strict;
use warnings;
use LWP::UserAgent;
use JSON;
use Time::HiRes qw( time );
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use Pub::Prefs;
use cm_defs;
use cm_prefs;
use dm_source;
use dm_cache;
use dm_observe;
use dm_fetch;
use dm_engine;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/engine";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$ROOT/temp";

my $PORT = 9897;
my $STUB = "http://127.0.0.1:$PORT";

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub putSource
	# The id IS the leaf name, which is also what makes cache_key and id the
	# same string here - convenient, and it means an assertion that names
	# one is not quietly depending on the other.
{
	my ($id,$path,$extra) = @_;
	mkdir $ROOT             if !-d $ROOT;
	mkdir "$ROOT/sources"   if !-d "$ROOT/sources";
	$extra = defined($extra) ? ",\n  $extra" : '';
	open(my $fh,'>',"$ROOT/sources/$id.tsd") or die $!;
	print $fh <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "engine stub $id",
  "url": "$STUB/$path/{z}/{x}/{y}.jpg",
  "zoom": { "min": 0, "max": 20 },
  "attribution": "stub",
  "uses": ["display","build"]$extra
}
EOJ
	close $fh;
}

sub stubStats
	# Every request the stub has seen, with arrival times in ms.  THE
	# MEASUREMENT, and it comes from the far side of the socket.
{
	my $ua = LWP::UserAgent->new( timeout => 5 );
	my $r = $ua->get("$STUB/stats");
	return { count => 0, requests => [] } if !$r->is_success();
	return decode_json($r->content());
}

sub stubReset
{
	LWP::UserAgent->new( timeout => 5 )->get("$STUB/reset");
}

sub freshCache
{
	my $dir = "$ROOT/cache";
	return if !-d $dir;
	for my $sub (glob("$dir/*"))
	{
		unlink glob("$sub/*/*");
		rmdir $_ for glob("$sub/*");
		rmdir $sub;
	}
}


#---------------------------------------------
# setup
#---------------------------------------------

unlink glob("$ROOT/sources/*.tsd");

putSource("fast",'ok');
putSource("paced",'ok','"policy": { "min_interval_ms": 120, "max_concurrency": 8 }');
putSource("slow",'slow/300');
putSource("limited",'429');
putSource("denied",'403');
putSource("flaky",'flaky/2');
putSource("junk",'garbage');

my $ua = LWP::UserAgent->new( timeout => 2 );

# A LEFTOVER STUB IS INDISTINGUISHABLE FROM A FRESH ONE AND POISONS EVERY
# MEASUREMENT IN THIS FILE.  A run that dies before it can say /quit leaves
# one listening; the next run's stub then fails to bind and dies silently,
# the readiness probe succeeds against the OLD process, and its request log
# still holds the previous run's entries.  That showed up as one extra
# request and a 7 ms gap where the gate had actually held perfectly - a
# fixture fault reported as an engine fault, which is the worst kind.
#
# So anything already on this port is told to quit first, and the log is
# asserted empty before anything is measured.

$ua->get("$STUB/quit");
select(undef,undef,undef,0.3);

my $pid = system(1,"\"$^X\" \"$FindBin::Bin/tool_stub_source.pl\" $PORT");
my $up  = 0;
for (1..50)
{
	if ($ua->get("$STUB/stats")->is_success()) { $up = 1; last }
	select(undef,undef,undef,0.1);
}
die "stub did not start on $PORT\n" if !$up;

rescanSources();
obsLoad();
freshCache();

ok(scalar(@{stubStats()->{requests}}) == 0,
	"the stub answering on $PORT is a FRESH one with an empty log");

print "=== composition ===\n";

# SLOWEST WINS, FEWEST WINS.  Asserted directly, because these two
# functions are where every knob in the application finally meets and a
# sign error in either would be invisible until a provider complained.

my $fast  = getSource('fast')  or die "no fast source\n";
my $paced = getSource('paced') or die "no paced source\n";

setPref($PREF_MIN_INTERVAL,0);
setPref($PREF_MAX_CONCURRENT,4);

ok(engineInterval($fast,0) == 0,"an unpaced source with no knobs set is 0 ms");
ok(engineInterval($paced,0) == 120,"a source's declared interval is honoured");
ok(engineInterval($paced,500) == 500,
	"an advisory SLOWER than the declaration wins (got ".
	engineInterval($paced,500).")");
ok(engineInterval($paced,50) == 120,
	"an advisory FASTER than the declaration does NOT (got ".
	engineInterval($paced,50).")");

setPref($PREF_MIN_INTERVAL,900);
ok(engineInterval($fast,0) == 900,
	"the installation floor reaches a source that declares nothing");
ok(engineInterval($paced,500) == 900,
	"and wins when it is the slowest of the three");
setPref($PREF_MIN_INTERVAL,0);

# CONCURRENCY IS LATENCY COVER.  With a measured round trip of 600 ms and
# a 120 ms interval, ceil(600/120) = 5 workers cover the latency - but the
# pool preference of 4 is lower, and fewest wins.

obsNote($paced,{ rtt_ms => 600 });
setPref($PREF_MAX_CONCURRENT,8);
ok(engineConcurrency($paced,120) == 5,
	"concurrency is ceil(rtt/interval) = 5, not the declared 8 (got ".
	engineConcurrency($paced,120).")");
setPref($PREF_MAX_CONCURRENT,3);
ok(engineConcurrency($paced,120) == 3,
	"and the pool preference lowers it further (got ".
	engineConcurrency($paced,120).")");
setPref($PREF_MAX_CONCURRENT,4);


#---------------------------------------------
# the gate, measured at the far end of the socket
#---------------------------------------------

print "\n=== the pacing gate, timed by the server ===\n";

my $pool = engineStart(4);
ok($pool == 4,"a pool of 4 started (got $pool)");
ok(engineRunning() == 4,"and reports itself running");

stubReset();
freshCache();

# TWELVE TILES THROUGH FOUR WORKERS AT A 120 MS GATE.  If the gate were
# per worker rather than per source, four requests would arrive together
# every 120 ms and the smallest gap would be near zero.

my $t0 = time();
my @jobs = map { engineSubmit($paced,10,$_,7,$PRIORITY_BULK,0) } (1..12);
my @got  = map { engineCollect($_) } @jobs;
my $secs = time() - $t0;

ok(scalar(grep { $_->{status} eq 'ok' } @got) == 12,
	"all 12 tiles came back ok");
ok(scalar(grep { $_->{bytes} && length(${$_->{bytes}}) } @got) == 12,
	"and every one carried its BYTES across the thread boundary");

my $st = stubStats();
my @ms = sort { $a <=> $b } map { $_->{ms} } @{$st->{requests}};
ok(scalar(@ms) == 12,"the server saw exactly 12 requests (got ".scalar(@ms).")");

my $min_gap = 99999;
for my $i (1..$#ms)
{
	my $gap = $ms[$i] - $ms[$i-1];
	$min_gap = $gap if $gap < $min_gap;
}
my $mean_gap = ($ms[-1] - $ms[0]) / ($#ms || 1);

printf("  12 requests in %.0f ms, ideal %d ms, mean gap %.0f ms, ".
	"smallest %d ms\n",$secs*1000,120*11,$mean_gap,$min_gap);

# THE RATE IS THE ASSERTION AND THE SMALLEST GAP IS ONLY REPORTED.
#
# An earlier version of this asserted the smallest gap against 80 percent
# of the floor and failed every few runs - 94, 96, 109, 111 ms across four
# consecutive runs, against a 96 ms threshold - while the TOTAL stayed
# within one percent of ideal every single time.
#
# That is not the gate leaking.  Reservations are handed out at absolute
# times under a lock and are spaced exactly; what varies is when the
# operating system gets round to WAKING a worker for one.  Windows'
# scheduler tick is 15.6 ms here, measured - a requested 120 ms sleep
# takes 124, a 25 ms sleep takes 31 - and sleeps only ever overshoot.  A
# worker that wakes late fires late and eats into the gap behind it, while
# the reservation after that one has not moved.  So a single gap comes out
# short and everything else stays right.
#
# The smallest gap therefore measures how late the unluckiest of twelve
# wakeups was, which is a fact about Windows.  At a 120 ms interval one
# tick is 13 percent of the target, so an 80 percent threshold was
# marginal by construction and would fail intermittently forever.
#
# WHAT A PROVIDER CARES ABOUT IS THE RATE OF ARRIVALS, so that is what is
# checked - and in ONE DIRECTION.  Slower than asked for is always fine;
# faster is the only thing that would be a real fault.

ok($mean_gap >= 120*0.95,
	sprintf("the RATE honoured the 120 ms floor - mean gap %.0f ms across ".
		"4 workers, so the gate is per source, not per worker",$mean_gap));
ok($secs*1000 >= 120*10,
	sprintf("and the whole run took at least ten intervals (%.0f ms)",
		$secs*1000));


#---------------------------------------------
# concurrency really is concurrent
#---------------------------------------------

print "\n=== an unpaced source overlaps ===\n";

stubReset();
freshCache();

# FOUR 300 MS REQUESTS WITH NO INTERVAL.  Serial would be 1200 ms; the
# pool should finish in about 300.  This is the other half of the gate
# assertion: proving it paces is only worth something if it does not
# ALSO serialise everything by accident.

my $slow = getSource('slow') or die "no slow source\n";
$t0 = time();
my @sj = map { engineSubmit($slow,10,$_,9,$PRIORITY_BULK,0) } (1..4);
my @sr = map { engineCollect($_) } @sj;
my $overlap = time() - $t0;

ok(scalar(grep { $_->{status} eq 'ok' } @sr) == 4,"4 slow tiles came back");
printf("  4 x 300 ms requests took %.0f ms (serial would be 1200)\n",
	$overlap*1000);
ok($overlap < 0.9,
	sprintf("they overlapped rather than serialising (%.0f ms)",$overlap*1000));


#---------------------------------------------
# classification and retry
#---------------------------------------------

print "\n=== each class has one consequence ===\n";

stubReset();
freshCache();

my $flaky = getSource('flaky') or die "no flaky source\n";
my $r = engineFetch($flaky,10,1,1,$PRIORITY_BULK,0);
ok($r->{status} eq 'ok',
	"a server that fails twice then succeeds is RETRIED to success ".
	"(got '$r->{status}')");
ok($r->{tries} == 3,"in exactly 3 tries (got $r->{tries})");

stubReset();
freshCache();
my $denied = getSource('denied') or die "no denied source\n";
$r = engineFetch($denied,10,1,1,$PRIORITY_BULK,0);
ok($r->{status} eq 'error' && $r->{class} eq 'auth',
	"a 403 is classed 'auth' (got '".($r->{class} // '-')."')");
ok($r->{tries} == 1,
	"and is NOT retried - asking again cannot supply a credential ".
	"(tries $r->{tries})");
ok(scalar(@{stubStats()->{requests}}) == 1,
	"the server was asked exactly once");

stubReset();
freshCache();
my $junk = getSource('junk') or die "no junk source\n";
$r = engineFetch($junk,10,1,1,$PRIORITY_BULK,0);
ok($r->{status} eq 'error' && $r->{class} eq 'garbage',
	"a 200 that is not an image is classed 'garbage'");
ok($r->{tries} == 1,"and is not retried either - it will not become an image");


#---------------------------------------------
# backoff applies to the source
#---------------------------------------------

print "\n=== a 429 backs off the SOURCE ===\n";

stubReset();
freshCache();

my $limited = getSource('limited') or die "no limited source\n";
ok(engineInterval($limited,0) == 0,"the source is unpaced to begin with");

$t0 = time();
$r  = engineFetch($limited,10,1,1,$PRIORITY_BULK,0);
my $limited_secs = time() - $t0;

ok($r->{status} eq 'error' && $r->{class} eq 'rate_limited',
	"a 429 is classed 'rate_limited'");

# THE STUB SENDS 'Retry-After: 2'.  Obeying the server's own number rather
# than an invented one is the whole of the policy, and it is visible as
# elapsed time: four attempts with a 2 s wait between them cannot be quick.

printf("  4 attempts with Retry-After 2 took %.1f s\n",$limited_secs);
ok($limited_secs > 4,
	sprintf("the server's Retry-After was OBEYED, not ignored (%.1f s)",
		$limited_secs));

my $now_interval = engineInterval($limited,0);
ok($now_interval >= 2000,
	"and the source is left backed off at ${now_interval} ms, ".
	"where it was 0 before");

# THE BACKOFF IS THE SOURCE'S, NOT THE TILE'S.  A different coordinate on
# the same source is slowed; a different SOURCE is not.

ok(engineInterval($fast,0) == 0,
	"a DIFFERENT source is entirely unaffected");

my $rec = obsRecord($limited);
ok($rec->{saw_429} == 1,"the 429 reached the observation record");
ok($rec->{ceiling} eq 'elastic',
	"and the declared ceiling is now known to be elastic");


#---------------------------------------------
# the record is written by the ENGINE, not by getTile
#---------------------------------------------
# THE BUG THIS EXISTS TO CATCH.  The recording used to live in getTile,
# which was correct only while getTile was the sole route to the network.
# It stopped being that the moment dm_fill became a client and started
# calling engineSubmit directly - so a fill, the largest source of traffic
# in the whole application, silently recorded nothing.
#
# Asserting through engineSubmit rather than getTile is the point: it is
# the path that was broken, and a test that went through getTile would
# have passed throughout.

print "\n=== a submit teaches the record, not just a getTile ===\n";

stubReset();
freshCache();

my $rec_src = getSource('slow') or die "no slow source\n";
obsNote($rec_src,{ rtt_ms => 0, fetches => 0 });

my @rj = map { engineSubmit($rec_src,13,$_,4,$PRIORITY_BULK,0) } (1..4);
engineCollect($_) for @rj;

my $rr = obsRecord($rec_src);
ok($rr->{fetches} == 4,
	"4 tiles fetched by SUBMIT reached the record (fetches = $rr->{fetches})");
ok($rr->{rtt_ms} > 0,
	"and a round trip was learned from them ($rr->{rtt_ms} ms) - this is ".
	"what engineConcurrency's latency cover reads");
ok($rr->{last_ok} > 0,"and the time of last successful contact");

# AN ERROR CLASS TOO, by the same path.

my $ej = engineSubmit($junk,13,9,9,$PRIORITY_BULK,0);
engineCollect($ej);
ok(obsRecord($junk)->{last_error} eq 'garbage',
	"and a failure's CLASS reaches it by the same path (got '".
	obsRecord($junk)->{last_error}."')");


#---------------------------------------------
# interactive queues ahead of bulk
#---------------------------------------------

print "\n=== interactive queues ahead, and does not preempt ===\n";

stubReset();
freshCache();

# A BACKLOG, THEN ONE INTERACTIVE REQUEST.  With four workers busy on slow
# requests and a queue of bulk work behind them, an interactive tile must
# come back after roughly ONE slow request - not after the whole backlog.

my @bulk = map { engineSubmit($slow,11,$_,3,$PRIORITY_BULK,0) } (1..16);
select(undef,undef,undef,0.15);		# let the workers pick up their first

$t0 = time();
my $ij = engineSubmit($fast,11,999,999,$PRIORITY_INTERACTIVE,0);
my $ir = engineCollect($ij);
my $waited = time() - $t0;

ok($ir->{status} eq 'ok',"the interactive tile came back ok");
printf("  interactive waited %.0f ms with 16 bulk jobs queued behind ".
	"4 x 300 ms workers\n",$waited*1000);
ok($waited < 0.9,
	sprintf("it waited for ONE in-flight request, not the backlog (%.0f ms)",
		$waited*1000));

engineCollect($_) for @bulk;		# drain


#---------------------------------------------
# the pool survives, and stops cleanly
#---------------------------------------------

print "\n=== the pool ===\n";

my $stats = engineStats();
printf("  requests=%d retries=%d backoffs=%d interactive=%d bulk=%d\n",
	$stats->{requests} // 0,$stats->{retries} // 0,$stats->{backoffs} // 0,
	$stats->{interactive} // 0,$stats->{bulk} // 0);

ok(($stats->{interactive} // 0) >= 1,"interactive jobs were counted");
ok(($stats->{bulk} // 0) >= 30,"and bulk jobs (".($stats->{bulk} // 0).")");
ok(engineRunning() == 4,"all 4 workers are still alive after all of that");

# THE TWO THINGS THAT MUST COME BACK TO ZERO, and neither fails loudly.
#
# A ticket is a claim on the shared result store and only a COLLECT
# releases it, so a caller that walks away from a job it submitted leaves
# a row behind permanently - in the one structure whose whole claim is
# that nothing grows without bound.  A permit leak is worse to diagnose:
# it produces no error at all, just a source that gradually stops being
# fetched, noticed a long way from here.
#
# Both were real.  dm_fill abandoned its outstanding window on cancel.

ok(($stats->{uncollected} // -1) == 0,
	"every submitted job was collected - the result store is empty ".
	"(uncollected = ".($stats->{uncollected} // '?').")");
ok(!$stats->{inflight},
	"every permit taken was returned (in flight: ".
	($stats->{inflight} || 'none').")");

ok(engineStop(),"the pool stopped cleanly");
ok(engineRunning() == 0,"and reports itself stopped");

# WITH NO POOL, THE SAME CALLS STILL WORK.  This is the path the console
# and every other headless test take, and it must not be a second
# implementation - the gate below is the same gate.

freshCache();
my $after = engineFetch($fast,12,5,5,$PRIORITY_BULK,0);
ok($after->{status} eq 'ok',
	"engineFetch still works with the pool stopped (got '$after->{status}')");

freshCache();
my $j2 = engineSubmit($fast,12,6,6,$PRIORITY_BULK,0);
my $r2 = engineCollect($j2);
ok($r2->{status} eq 'ok',
	"and so do submit/collect - one API, not two (got '$r2->{status}')");

#---------------------------------------------
# a lost require race is recovered from, not merely survived
#---------------------------------------------
# THE FAILURE THIS PINS COST TWO PACKAGED BUILDS.  Pure Perl modules come
# out of the executable rather than off disk, and two threads reaching the
# same unloaded file at the same instant get fragments of it - so the
# error is a syntax error, at a line number, in a file that is not broken.
#
# WHAT MADE IT PERMANENT WAS PERL'S BOOKKEEPING AND NOT THE RACE.  A
# require that fails to compile leaves the %INC entry present and undef,
# and every attempt after that dies without going near the file.  So there
# are two separate claims here and both need asserting: that the engine
# RECOGNISES the message, and that forgetting the entry really does let a
# later attempt load the file for the first time again.
#
# NOTHING HERE TOUCHES THE NETWORK OR THE POOL.  It plants a module,
# breaks it, and watches Perl.

my $POISON_DIR = "$ROOT/poison";
mkdir $POISON_DIR if !-d $POISON_DIR;
push @INC,$POISON_DIR;

sub plantModule
{
	my ($body) = @_;
	open(my $fh,'>',"$POISON_DIR/cmPoisonTest.pm") or die $!;
	print $fh $body;
	close $fh;
}

sub tryLoad
	# Load it and hand back the failure text, or '' for success.
{
	my $okay = eval { require 'cmPoisonTest.pm'; 1 };
	my $why  = $okay ? '' : ($@ || 'no message');
	$why =~ s/\s+/ /g;
	return $why;
}

# THE MESSAGES ARE THE REAL ONES, off the log of the build that failed at
# z15 on the Ibiza region of the Example set.

my @REAL = (
	"Unmatched right curly bracket at C:/PROGRA~2/chartMaker/lib/std/".
		"utf8_heavy.pl line 6, at end of line syntax error at ".
		"utf8_heavy.pl line 176, near \"}\" BEGIN not safe after errors--".
		"compilation aborted at utf8_heavy.pl line 216. Compilation ".
		"failed in require at utf8.pm line 17.",
	"Missing right curly or square bracket at utf8_heavy.pl line 470, at ".
		"EOF Compilation failed in require at utf8.pm line 17.",
	"Attempt to reload utf8_heavy.pl aborted. Compilation failed in ".
		"require at utf8.pm line 17.",
	);

my $matched = grep { $_ =~ $dm_engine::POISON_RE } @REAL;
ok($matched == scalar(@REAL),
	"every message the failing build produced is recognised as a lost ".
	"require race ($matched of ".scalar(@REAL).")");

# AND THE REFUSALS MATTER MORE THAN THE MATCHES.  A pattern that caught
# ordinary bugs too would retry a genuine fault three times and bury it
# under two extra log lines.

my @NOT = (
	'the fetch returned nothing',
	"Can't call method \"code\" on an undefined value at dm_fetch.pm line 500.",
	'Illegal division by zero at dm_engine.pm line 300.',
	"Can't locate object method \"fetchStore\" via package \"dm_fetch\"",
	'syntax error',
	);

my $wrongly = grep { $_ =~ $dm_engine::POISON_RE } @NOT;
ok($wrongly == 0,
	"and an ordinary internal failure is not mistaken for one ".
	"($wrongly of ".scalar(@NOT)." wrongly matched)");

# NOW THE MECHANISM, END TO END.

plantModule("package cmPoisonTest;\nmy \$x = ;\n1;\n");

my $first = tryLoad();
ok($first =~ /Compilation failed in require/,
	"a module that will not compile fails the first time it is required");

my $second = tryLoad();
ok($second =~ /Attempt to reload/,
	"and after that Perl refuses to even look at it again - which is ".
	"what killed a worker for the life of the process");

my $forgot = dm_engine::_unpoison();
ok($forgot >= 1,
	"_unpoison forgets the failed load ($forgot entry/entries)");

ok(defined $INC{'Pub/Utils.pm'},
	"and leaves every module that DID load alone");

# THE PROOF: with the entry forgotten, the next require reads the file
# again rather than refusing.  Repair it first, because that is the real
# case - the file was never broken, only badly read.

plantModule("package cmPoisonTest;\nsub hello { return 'loaded' }\n1;\n");

my $third = tryLoad();
ok($third eq '',
	"and the next attempt loads the file for the first time again ".
	($third ? "(got '$third')" : ''));

ok(cmPoisonTest::hello() eq 'loaded',
	"a real module, really loaded, in a thread that had given up on it");

$ua->get("$STUB/quit");

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
