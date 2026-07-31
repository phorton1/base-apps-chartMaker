#!/usr/bin/perl
#---------------------------------------------
# tool_progress_demo.pl -- drive w_progress and w_report with a FAKE worker
#---------------------------------------------
# The build dialog, its two bars, its cancel and the report that follows
# it, with no model, no cache, no network and no data dir.  The worker
# counts.
#
# WHY A FAKE WORKER IS THE RIGHT TEST HERE.  What can go wrong in this
# half is wx and threads: a timer that does not fire inside a modal loop,
# a gauge that divides by zero on an empty region, a dialog destroyed from
# inside its own event loop, a shared record that does not survive the
# thread boundary.  None of that is about tiles, and running a real build
# to find out would take an hour and would touch somebody's server.
#
#	perl -I/base tool_progress_demo.pl          runs to completion
#	perl -I/base tool_progress_demo.pl cancel   cancels itself at 40%
#
# The 'cancel' form is the one worth running twice: a cancel has to leave
# the worker able to notice, set finished LAST, and still produce a report.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use threads;
use threads::shared;
use Time::HiRes qw( sleep );
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Resources;
use cm_defs;
use cm_utils;
use w_resources;
use w_progress;
use w_report;

use base 'Wx::App';

$| = 1;
	# Redirected stdout is block buffered, and this script is normally
	# killed while a modal dialog is still up -- without this, everything
	# it said is discarded at exactly the moment it is wanted.

setStandardTempDir('chartMaker');

my $SELF_CANCEL = (($ARGV[0] // '') eq 'cancel');

my $REGIONS		= 4;
my $PER_REGION	= 60;
my $TICK_MS		= ($ARGV[1] // 0) + 0 || 25;
	# A second argument slows the fake walk down, for when the point is to
	# LOOK at the dialog rather than to check that it completes.


sub fakeWorker
	# Exactly the shape of _buildWorker: write the counters, poll
	# {cancelled}, render text, set {finished} LAST.
{
	my ($prog) = @_;

	$prog->{phase} = 'Fetching';
	my $stopped = 0;

	for my $r (1..$REGIONS)
	{
		$prog->{label}		= "Region$r";
		$prog->{sub_total}	= $PER_REGION;
		$prog->{sub_done}	= 0;
		$prog->{sub_label}	= '';

		for my $t (1..$PER_REGION)
		{
			if ($prog->{cancelled})
			{
				$stopped = 1;
				last;
			}
			$prog->{sub_done} = $t;
			$prog->{sub_label} = sprintf(
				"%d tiles - %d fetched, %d cached, 0 absent, 0 errors",
				$t,$t - int($t/3),int($t/3)) if $t % 10 == 0;
			sleep($TICK_MS / 1000);
		}
		last if $stopped;
		$prog->{done} = $r;
	}

	# A ZERO-TOTAL REGION ON THE WAY OUT.  An empty inner level is a real
	# case -- a region capped below its own zmin contributes nothing -- and
	# it is exactly the shape that divides by zero in a gauge.

	if (!$stopped)
	{
		$prog->{phase}		= 'Writing';
		$prog->{label}		= 'Empty';
		$prog->{sub_total}	= 0;
		$prog->{sub_done}	= 0;
		$prog->{sub_label}	= '';
		sleep(0.4);
	}

	$prog->{ok} = $stopped ? 0 : 1;
	push @{$prog->{lines}},
		$stopped ? (
			"CANCELLED - nothing was written.",
			"Errors are never cached, so building again resumes where this stopped.",
		) : (
			"Built $REGIONS card(s) in 0m 06s",
			"C:/nowhere/raster/Demo",
			'',
			(map { sprintf("  %-12s z%2d-%-2d %7d tiles %5d absent %3d blk %8.1f MB",
				"Region$_.rct",10,18,9931,0,9,67.3) } (1..$REGIONS)),
			'',
			sprintf("  %-12s %14d tiles %5d absent %12.1f MB",
				'TOTAL',9931*$REGIONS,0,67.3*$REGIONS),
		);

	$prog->{finished} = 1;
}


sub OnInit
	# ONLY BRINGS THE FRAME UP.  The work is kicked off by a one-shot timer
	# so that it runs INSIDE MainLoop, which is where a menu handler runs
	# in the real application.  Calling ShowModal from OnInit instead hangs
	# with no window: a modal dialog is an event loop, and at that point
	# there is not yet an event loop for it to nest inside.
{
	my ($this) = @_;

	# WELL TO THE RIGHT, because the dialogs centre on this frame and the
	# point of running this is to LOOK at them.  Put at 300,200 they come
	# up underneath whatever terminal launched the script, which reads as
	# "no window appeared".

	my $frame = Wx::Frame->new(undef,-1,'progress demo',[1500,120],[520,240]);
	$frame->Show(1);
	$frame->Raise();

	$this->{frame} = $frame;
	$this->{kick}  = Wx::Timer->new($frame,9900);
	Wx::Event::EVT_TIMER($frame,9900,sub { runDemo($frame) });
	$this->{kick}->Start(300,1);

	return 1;
}


sub runDemo
{
	my ($frame) = @_;

	my $prog = newProgress($REGIONS,'');
	$prog->{active} = 1;
	$prog->{phase}  = 'Starting';

	threads->create(\&fakeWorker,$prog)->detach();

	# SELF-CANCEL FROM A TIMER, not from the worker.  A cancel arrives on
	# the main thread in real use and this has to be the same path -- a
	# worker that cancelled itself would never touch onCancel at all.

	my $timer;
	if ($SELF_CANCEL)
	{
		$timer = Wx::Timer->new($frame,9901);
		Wx::Event::EVT_TIMER($frame,9901,sub {
			print "  -- firing cancel\n";
			$prog->{cancelled} = 1;
		});
		$timer->Start(int($REGIONS * $PER_REGION * $TICK_MS * 0.4),1);
	}

	my $dlg = w_progress->new($frame,'Building RCT Card (demo)',$prog);
	$dlg->run();

	print "  dialog returned: finished=$prog->{finished} ok=$prog->{ok} ".
		"cancelled=$prog->{cancelled} lines=".scalar(@{$prog->{lines}})."\n";

	my $outcome = $prog->{cancelled} && !$prog->{ok} ? 'cancelled' :
				  $prog->{ok} ? 'built' : 'refused';
	print "  outcome: $outcome\n";

	w_report->show($frame,$outcome,[ @{$prog->{lines}} ]);

	print "  report closed - done\n";
	$frame->Destroy();
}


# main->new(), not tool_progress_demo->new().  'use base' in a .pl sets
# @ISA on package main, which is where OnInit is too - there is no package
# statement in this file, so naming one would look for the method in a
# package that does not exist.

my $app = main->new();
$app->MainLoop();
print "ALL DONE\n";
