#!/usr/bin/perl
#---------------------------------------------
# tool_region_counts.pl -- what a region actually costs, level by level
#---------------------------------------------
#	perl -I/base tool_region_counts.pl <path/to/x.region> [--box]
#
# Prints the region's structure and the REAL per-level tile counts, from
# the same coverage enumerator the build walks.  Nothing is estimated.
#
# WHY IT IS IN THE REPO.  The user manual quotes these numbers - "the
# traced outline 4,316 tiles against 10,639 for one box over the same
# water" - and a quoted number that nobody can regenerate goes stale the
# first time a polygon moves.  This is how it is re-derived.
#
# --box additionally reports what ONE RECTANGLE over the same bounding box
# would have cost, which is the comparison the manual's "drawing for size"
# section is built on.  It is computed rather than asserted because the
# ratio depends entirely on the shape somebody drew.
#
# It reads a file by path and touches no preferences and no data dir, so
# it works on a region anywhere - $data_dir, _res/user_data, or one
# somebody mailed you.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_region;
use dm_coverage;

my $path = shift(@ARGV) || '';
my $want_box = grep { $_ eq '--box' } @ARGV;

if (!$path || !-f $path)
{
	print "usage: tool_region_counts.pl <path/to/x.region> [--box]\n";
	exit 1;
}

my $reg = dm_region::readRegionFile($path);
die "could not read or validate $path\n" if !$reg;

printf("%s  '%s'  z%d-%d authored at %d  source %s\n",
	$reg->{id},$reg->{name},$reg->{zmin},$reg->{zmax},$reg->{zauthor},
	$reg->{source});

my $n = 0;
for my $poly (@{$reg->{geometry}})
{
	my ($w,$e,$s,$nn);
	for my $pt (@$poly)
	{
		$w  = $pt->[0] if !defined $w  || $pt->[0] < $w;
		$e  = $pt->[0] if !defined $e  || $pt->[0] > $e;
		$s  = $pt->[1] if !defined $s  || $pt->[1] < $s;
		$nn = $pt->[1] if !defined $nn || $pt->[1] > $nn;
	}
	printf("   polygon %d  %3d points  lon %.5f..%.5f  lat %.5f..%.5f\n",
		$n++,scalar(@$poly),$w,$e,$s,$nn);
}

_dumpSubs($reg->{subregions},1);

sub _dumpSubs
{
	my ($subs,$depth) = @_;
	for my $s (@$subs)
	{
		printf("   %s%-12s %-22s zmax %d  %d polygon(s)\n",
			'  ' x $depth,$s->{id},$s->{name} // '',$s->{zmax},
			scalar(@{$s->{geometry}}));
		_dumpSubs($s->{subregions},$depth+1) if $s->{subregions};
	}
}

my $cov    = regionCoverage($reg);
my $counts = coverageCounts($cov);
my $total  = coverageTotal($cov);

print "\nper level:\n";
printf("   z%-3d %8d\n",$_,$counts->{$_})
	for sort { $a <=> $b } keys %$counts;
printf("   %-4s %8d\n",'ALL',$total);

if ($want_box)
{
	# The bounding box of every polygon in the region, as one rectangle -
	# the "what if I had just drawn a box round it" number.

	my ($w,$e,$s,$n2);
	for my $poly (@{$reg->{geometry}})
	{
		for my $pt (@$poly)
		{
			$w  = $pt->[0] if !defined $w  || $pt->[0] < $w;
			$e  = $pt->[0] if !defined $e  || $pt->[0] > $e;
			$s  = $pt->[1] if !defined $s  || $pt->[1] < $s;
			$n2 = $pt->[1] if !defined $n2 || $pt->[1] > $n2;
		}
	}

	my $box = { %$reg, id => $reg->{id}.'Box',
		geometry => [[ [$w,$s],[$e,$s],[$e,$n2],[$w,$n2] ]] };
	my $bt = coverageTotal(regionCoverage($box));

	printf("\none box over the same bounds: %d tiles\n",$bt);
	printf("the drawn shape is %.1f%% of it - %d tiles saved, %.1fx\n",
		100*$total/$bt,$bt-$total,$bt/$total) if $total;
}

1;
