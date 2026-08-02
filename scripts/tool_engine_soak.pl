#!/usr/bin/perl
#---------------------------------------------
# tool_engine_soak.pl -- hammer the engine and look for what leaks
#---------------------------------------------
# THE SHORT TESTS CANNOT FIND THESE.  test_engine.pl asserts behaviour over
# a few dozen requests; a race, a permit leak or a lost wakeup shows up
# once in hundreds and then only under contention.  So this runs thousands
# of jobs across several sources at once, with failures and rate limits
# mixed in, and checks the things that should be INVARIANT rather than the
# things that should be true once.
#
# Four invariants, and each of them fails silently in production:
#
#	1  every submitted job is collected exactly once, and the shared
#	   result store comes back to empty.  A leak here is unbounded growth
#	   in the one structure documented as bounded.
#
#	2  every permit taken is returned.  A leak shows up not as an error
#	   but as a source that gradually stops being fetched at all, which is
#	   very hard to trace back to here from where it is noticed.
#
#	3  no job is lost and none is answered twice.  A lost wakeup would
#	   hang a caller forever; a double publish would corrupt whoever gets
#	   the second one.
#
#	4  the gate holds under contention, not just when it is quiet.
#
# A TOOL RATHER THAN A TEST because it takes minutes and reports numbers.
# What it finds should become an assertion in test_engine.pl.
#
#   perl tool_engine_soak.pl [rounds]

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

$| = 1;

my $ROUNDS = shift(@ARGV) || 6;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/soak";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$ROOT/temp";

my $PORT = 9896;
my $STUB = "http://127.0.0.1:$PORT";

my $problems = 0;

sub check
{
	my ($cond,$what) = @_;
	print(($cond ? "  ok    " : "  PROBLEM ").$what."\n");
	$problems++ if !$cond;
}

sub putSource
{
	my ($id,$path,$extra) = @_;
	mkdir $ROOT           if !-d $ROOT;
	mkdir "$ROOT/sources" if !-d "$ROOT/sources";
	$extra = defined($extra) ? ",\n  $extra" : '';
	open(my $fh,'>',"$ROOT/sources/$id.tsd") or die $!;
	print $fh <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "soak $id",
  "kind": "remote_xyz",
  "url": "$STUB/$path/{z}/{x}/{y}.jpg",
  "zoom": { "min": 0, "max": 22 },
  "attribution": "stub",
  "uses": ["display","build"]$extra
}
EOJ
	close $fh;
}

sub freshCache
	# EVERY ROUND MUST REALLY FETCH.  A cache hit never reaches the engine,
	# so a soak that let the cache fill would quietly stop testing anything
	# after its first round.
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

# THE PACED SOURCE GETS ITS OWN STUB PATH, which is the only way the gate
# can be measured at all.  Both of these answer 200 with an image, so
# sharing '/ok/' made their requests indistinguishable in the server's log
# and the smallest-gap figure was really the unpaced source's.

putSource('s_plain','ok');
putSource('s_paced','png','"policy": { "min_interval_ms": 120 }');
putSource('s_slow','slow/60');
putSource('s_flaky','flaky/1');
putSource('s_junk','garbage');
putSource('s_gone','404');

my $ua = LWP::UserAgent->new( timeout => 3 );
$ua->get("$STUB/quit");
select(undef,undef,undef,0.3);

system(1,"\"$^X\" \"$FindBin::Bin/tool_stub_source.pl\" $PORT");
my $up = 0;
for (1..50)
{
	if ($ua->get("$STUB/stats")->is_success()) { $up = 1; last }
	select(undef,undef,undef,0.1);
}
die "stub did not start on $PORT\n" if !$up;

rescanSources();
obsLoad();
setPref($PREF_MIN_INTERVAL,0);
setPref($PREF_MAX_CONCURRENT,6);

my @SOURCES = map { getSource($_) or die "no $_\n" }
	qw( s_plain s_paced s_slow s_flaky s_junk s_gone );

engineStart(6);
printf("pool of %d, %d rounds\n\n",engineRunning(),$ROUNDS);

my $t_all   = time();
my $total   = 0;
my %seen_job;
my %by_status;

for my $round (1..$ROUNDS)
{
	freshCache();
	my $t0 = time();

	# A MIXED BATCH, SUBMITTED ALL AT ONCE.  Six sources with different
	# policies and different failure modes, interleaved rather than run in
	# blocks, so the gate is holding several independent next-allowed
	# times at the same moment and the workers are contending for all of
	# them.  A per-source gate that was accidentally global would show up
	# here as everything crawling at the slowest source's rate.

	my @jobs;
	for my $i (1..120)
	{
		my $src = $SOURCES[$i % scalar(@SOURCES)];

		# One request in twenty is interactive, which is roughly what a
		# user panning during a fill looks like.

		my $pri = ($i % 20 == 0) ? $PRIORITY_INTERACTIVE : $PRIORITY_BULK;
		push @jobs,[ $src,engineSubmit($src,14,$i,$round,$pri,0) ];
	}

	$total += scalar(@jobs);

	for my $j (@jobs)
	{
		my ($src,$id) = @$j;

		# EVERY TICKET IS UNIQUE.  A duplicate would mean two callers
		# waiting on one slot, which is the shape of a lost result.

		$problems++, print "  PROBLEM duplicate job id $id\n"
			if $seen_job{$id}++;

		my $r = engineCollect($id);
		$by_status{ $r->{status} // 'undef' }++;
	}

	my $st = engineStats();
	printf("round %d: %3d jobs in %5.1fs  uncollected=%s  inflight=%s  queued=%d\n",
		$round,scalar(@jobs),time()-$t0,
		$st->{uncollected},($st->{inflight} || 'none'),$st->{queued});

	check($st->{uncollected} == 0,
		"round $round left nothing uncollected")
		if $st->{uncollected};
	check(!$st->{inflight},"round $round returned every permit")
		if $st->{inflight};
}

printf("\n%d jobs in %.1fs\n",$total,time()-$t_all);
printf("statuses: %s\n",join(', ',map { "$_=$by_status{$_}" }
	sort keys %by_status));


#---------------------------------------------
# the invariants
#---------------------------------------------

print "\n=== invariants ===\n";

my $st = engineStats();

check(scalar(keys %seen_job) == $total,
	"every job id was unique (".scalar(keys %seen_job)." of $total)");
check($st->{uncollected} == 0,
	"the shared result store is empty (uncollected = $st->{uncollected})");
check(!$st->{inflight},
	"every permit was returned (in flight: ".($st->{inflight} || 'none').")");
check($st->{queued} == 0,"the queue is empty (queued = $st->{queued})");
check(engineRunning() == 6,"all 6 workers survived");

# EVERY SUBMITTED JOB WAS ANSWERED.  Not the same as 'no errors' - an
# error is an answer.  A job with no answer at all would have hung the
# collect above, so reaching here proves it, but the count is worth
# stating because a silent 'undef' status would not have hung anything.

my $answered = 0;
$answered += $by_status{$_} for keys %by_status;
check($answered == $total,"every job produced a status ($answered of $total)");
check(!$by_status{undef},"and none of them was undef");

# THE FAILING SOURCES REALLY DID FAIL, or the soak was not soaking.  A
# stub that silently started answering 200 to everything would make every
# invariant above pass while testing nothing interesting.

check(($by_status{error} || 0) > 0,
	"the failing sources really failed (".($by_status{error} || 0)." errors)");
check(($by_status{absent} || 0) > 0,
	"the 404 source really 404'd (".($by_status{absent} || 0)." absent)");
check(($by_status{ok} || 0) > 0,
	"and the good sources really succeeded (".($by_status{ok} || 0)." ok)");


#---------------------------------------------
# the gate held under contention
#---------------------------------------------

print "\n=== the gate, under contention ===\n";

my $stats_json = do {
	my $r = $ua->get("$STUB/stats");
	$r->is_success() ? decode_json($r->content()) : { requests => [] };
};

# ONLY THE PACED SOURCE'S OWN REQUESTS.  The stub sees every source on one
# socket, so the gap that matters is between requests to the SAME source -
# which is what a per-source gate promises and a global one would not.

my @paced = sort { $a <=> $b }
	map { $_->{ms} }
	grep { $_->{path} =~ m{^/png/} } @{$stats_json->{requests}};

my @plain = sort { $a <=> $b }
	map { $_->{ms} }
	grep { $_->{path} =~ m{^/ok/} } @{$stats_json->{requests}};

my $FLOOR = 120;

if (@paced > 2)
{
	my ($min,$under) = (99999,0);
	for my $i (1..$#paced)
	{
		my $gap = $paced[$i] - $paced[$i-1];
		$min = $gap if $gap < $min;
		$under++ if $gap < $FLOOR * 0.8;
	}

	# THE RATE IS THE ASSERTION, AND THE GAP IS ONLY REPORTED.
	#
	# An earlier version of this asserted the smallest gap against a 25 ms
	# floor and failed steadily, which cost an hour of looking for a leak
	# in the engine.  There is none: reservations are spaced exactly, but a
	# worker wakes when Windows gets round to it and the scheduler tick
	# here is 15.6 ms, so at a 25 ms floor a single gap can be off by more
	# than half the interval while the long-run rate stays correct.  The
	# floor above is 120 ms because that is the scale a person actually
	# sets for politeness, and at that scale the jitter vanishes.
	#
	# What matters to a provider is the rate of arrivals, so that is what
	# is checked - and it is checked in ONE DIRECTION.  Slower than asked
	# for is always fine; faster is the only failure.

	my $span = ($paced[-1] - $paced[0]) / 1000;
	my $mean = $span / ($#paced || 1) * 1000;
	printf("  paced source (%d ms): %d requests over %.1fs, mean gap %.0f ms, ".
		"smallest %d ms, %d under 80%%\n",
		$FLOOR,scalar(@paced),$span,$mean,$min,$under);

	check($mean >= $FLOOR * 0.95,
		sprintf("the long-run RATE honoured the floor (%.0f ms mean against ".
			"a %d ms floor)",$mean,$FLOOR));
	check($under == 0,
		"and no single gap fell under 80 percent of it either");

	# THE UNPACED SOURCE MUST NOT HAVE BEEN SLOWED WITH IT.  A gate that
	# was accidentally global rather than per source would pass the test
	# above and fail this one, and 'everything is slow' is a much harder
	# symptom to trace than 'nothing is paced'.

	if (@plain > 2)
	{
		my $pmin = 99999;
		for my $i (1..$#plain)
		{
			my $gap = $plain[$i] - $plain[$i-1];
			$pmin = $gap if $gap < $pmin;
		}
		printf("  unpaced source: %d requests, smallest gap %d ms\n",
			scalar(@plain),$pmin);
		check($pmin < $FLOOR*0.8,
			"and the UNPACED source was not slowed with it - the gate is ".
			"per source, not global");
	}
}

engineStop();
check(engineRunning() == 0,"the pool stopped cleanly after all of that");

$ua->get("$STUB/quit");

print "\n".($problems ? "$problems PROBLEM(S)\n" : "no problems found\n");
