#!/usr/bin/perl
#---------------------------------------------
# tool_backoff_starve.pl -- a KNOWN LIMITATION, kept reproducible
#---------------------------------------------
# THIS DEMONSTRATES A FAULT THAT HAS NOT BEEN FIXED, which is why it is a
# tool and not a test: it would fail, and a suite that is expected to fail
# teaches people to ignore it.
#
# WHAT IT SHOWS.  A worker that is backing off sleeps at the pacing gate
# while still holding its slot in the pool.  Fill every worker with tiles
# for one rate limited source and there is nobody left to serve anything
# else - so an INTERACTIVE tile, from a completely healthy source, at the
# head of the queue, waits behind them.  Interactive priority puts a job
# at the front of the queue; it cannot conjure a free worker.
#
# It compounds, which is what turns a delay into a hang: each 429 doubles
# the source's backoff, and every gate claim pushes that source's
# next-allowed time out by the CURRENT backoff, so four tiles and four
# workers reach the one minute ceiling quickly and the map is unresponsive
# for minutes.  Measured: with one bulk tile and three workers free, the
# interactive tile returns in 0.01s.  With four, it did not return in
# eight minutes and the run was killed.
#
# THE DESIGN ALREADY SAYS WHAT TO DO and it was not done.  The note in
# docs/notes/fetch_engine.md reads "retries go to the back of the queue so
# a slow tile does not hold a worker"; dm_engine retries in place instead.
# Re-queueing alone is not quite the whole fix either - the re-queued job
# would still wait at the gate when a worker picked it up - so the real
# answer is probably for a worker to DEFER a job whose source is backed
# off while other work is waiting, which needs a bound to avoid livelock.
# That is a scheduling decision, not a patch.
#
#   perl tool_backoff_starve.pl
#
# TAKES MINUTES AND IS MEANT TO.  Kill it when the verdict prints.

use strict;
use warnings;
use LWP::UserAgent;
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

my $ROOT = 'C:/_temp/base-apps-chartMaker/starve';
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$ROOT/temp";

my $PORT = 9894;
my $STUB = "http://127.0.0.1:$PORT";

# HOW MANY WORKERS TO OCCUPY.  Set this BELOW the pool size and the
# interactive tile comes back instantly, which is the control: the fault
# is saturation, not priority being broken.

my $POOL   = 4;
my $OCCUPY = shift(@ARGV);
$OCCUPY = $POOL if !defined $OCCUPY;

mkdir $ROOT           if !-d $ROOT;
mkdir "$ROOT/sources" if !-d "$ROOT/sources";
unlink glob("$ROOT/sources/*.tsd");

for my $s ( ['limited','429'], ['good','ok'] )
{
	open(my $fh,'>',"$ROOT/sources/$s->[0].tsd") or die $!;
	print $fh qq({"tsd_version":1,"id":"$s->[0]","name":"$s->[0]",).
		qq("kind":"remote_xyz","url":"$STUB/$s->[1]/{z}/{x}/{y}.jpg",).
		qq("zoom":{"min":0,"max":22},"attribution":"stub",).
		qq("uses":["display"]});
	close $fh;
}

my $ua = LWP::UserAgent->new( timeout => 3 );
$ua->get("$STUB/quit");
select(undef,undef,undef,0.3);
system(1,"\"$^X\" \"$FindBin::Bin/tool_stub_source.pl\" $PORT");
for (1..50)
{
	last if $ua->get("$STUB/stats")->is_success();
	select(undef,undef,undef,0.1);
}

rescanSources();
obsLoad();
setPref($PREF_MIN_INTERVAL,0);
setPref($PREF_MAX_CONCURRENT,$POOL);

for my $sub (glob("$ROOT/cache/*"))
{
	unlink glob("$sub/*/*");
	rmdir $_ for glob("$sub/*");
	rmdir $sub;
}

my $limited = getSource('limited') or die "no limited source\n";
my $good    = getSource('good')    or die "no good source\n";

engineStart($POOL);
printf("pool of %d, occupying %d worker(s) with a 429 source\n",
	engineRunning(),$OCCUPY);

# The stub answers these with 429 and 'Retry-After: 2', so each one is
# retried and each retry waits.

my @bulk = map { engineSubmit($limited,10,$_,1,$PRIORITY_BULK,0) } (1..$OCCUPY);
select(undef,undef,undef,0.4);		# let the workers pick them up

my $t0 = time();
my $r  = engineCollect(
	engineSubmit($good,10,1,1,$PRIORITY_INTERACTIVE,0));
my $waited = time() - $t0;

printf("interactive tile from a HEALTHY source waited %.2fs (status %s)\n",
	$waited,$r->{status});
printf("VERDICT: %s\n",$waited > 1.5 ?
	"STARVED - every worker was asleep in another source's backoff" :
	"fine - a worker was free");

engineCollect($_) for @bulk;
engineStop();
$ua->get("$STUB/quit");
