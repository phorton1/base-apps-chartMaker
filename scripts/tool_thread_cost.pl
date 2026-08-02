#!/usr/bin/perl
#---------------------------------------------
# tool_thread_cost.pl -- what does ONE ithread cost this application?
#---------------------------------------------
# THE MEASUREMENT BEHIND THE CEILING OF 12, which is now a hard constant
# in two places - MAX_CONCURRENT in dm_engine, and HTTP_MAX_THREADS in
# Pub::HTTP::ServerBase - so it is worth being reproducible rather than a
# number somebody once quoted in a comment.
#
# WHY THERE HAS TO BE A CEILING AT ALL.  This is a 32 bit perl
# (MSWin32-x86, ptrsize 4), so the process has about 2 GB to address, and
# every ithread CLONES THE INTERPRETER into it.  Threads are not cheap
# concurrency here; they are address space.
#
# At a pool of 32 the application did not start: the engine's workers took
# the room first, and ServerBase's own threads->create then returned undef
# - which it did not check, so it died calling detach on it, before any
# window existed, with the reason on stderr where the log never sees it.
# Both the ceiling and that null check came out of this measurement.
#
# Measured when written: 186 MB baseline with the data model and Wx loaded
# and no frame built, then ~27 MB per thread, steady from 1 to 40.
#
# Loads Wx but never creates a frame, so it weighs the application without
# needing its window.

use strict;
use warnings;
use threads;
use threads::shared;
use Thread::Queue;
use FindBin;
use lib "$FindBin::Bin/..";

$| = 1;

sub mem
	# Virtual size and private bytes for THIS process, via the same
	# counters Task Manager shows.
{
	my $pid = $$;
	my $out = `powershell -NoProfile -Command "\$p=Get-Process -Id $pid; '{0} {1}' -f [Math]::Round(\$p.VirtualMemorySize64/1MB,1),[Math]::Round(\$p.PrivateMemorySize64/1MB,1)" 2>&1`;
	my ($v,$p) = $out =~ /([\d.]+)\s+([\d.]+)/;
	return ($v || 0, $p || 0);
}

my ($v0,$p0) = mem();
printf("bare perl + threads:        virtual %8.1f MB   private %8.1f MB\n",$v0,$p0);

# Load what the application loads, short of building a window.
require Pub::Utils;              Pub::Utils->import();
require cm_defs;                 cm_defs->import();
require cm_prefs;
require dm_source;
require dm_region;
require dm_observe;
require dm_fetch;
require dm_engine;

my ($v1,$p1) = mem();
printf("+ chartMaker data model:    virtual %8.1f MB   private %8.1f MB\n",$v1,$p1);

eval { require Wx; Wx->import(); 1 };
my ($v2,$p2) = mem();
printf("+ Wx:                       virtual %8.1f MB   private %8.1f MB%s\n",
	$v2,$p2,$@ ? "  (Wx failed to load)" : '');

print "\nspawning threads one at a time:\n";
printf("%8s %12s %12s %14s\n",'threads','virtualMB','privateMB','per-thread-MB');

my $q = Thread::Queue->new();
my @thr;
my $base_v = $v2;

for my $n (1..40)
{
	my $t = threads->create(sub { $q->dequeue(); return 1 });
	if (!$t)
	{
		printf("\nthreads->create RETURNED UNDEF at thread %d\n",$n);
		last;
	}
	push @thr,$t;

	if ($n % 4 == 0 || $n <= 2)
	{
		my ($v,$p) = mem();
		printf("%8d %12.1f %12.1f %14.1f\n",
			$n,$v,$p,($v - $base_v)/$n);
	}
}

printf("\nspawned %d threads before stopping\n",scalar(@thr));
my ($vf,$pf) = mem();
printf("final: virtual %.1f MB of the ~2048 MB a 32-bit process can address\n",$vf);

$q->enqueue(1) for (1..scalar(@thr));
$_->join() for @thr;
print "joined cleanly\n";
