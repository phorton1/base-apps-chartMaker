#!/usr/bin/perl
#---------------------------------------------
# tool_coverage_time.pl -- what coverage actually costs
#---------------------------------------------
# Times regionCoverage() over a real set three ways:
#
#	cold        nothing memoised - what a fresh process pays
#	warm        nothing changed  - what a selection or a repaint pays
#	one edited  one region moved - what a commit pays
#
# WHY THIS EXISTS.  The cost of coverage is the thing that decides how much
# of the interface can ask for it.  It was a second for five regions, keyed
# on a counter that selection bumped, so every click in the tree paid it -
# and the fix (a per-region memo against a signature of the region's own
# content, plus a model counter that view changes do not move) is only
# worth what this measures.  The residual is one region's rasterisation,
# and the only thing that would remove it is counting by quadtree
# refinement - proportional to perimeter rather than to area.  Re-run this
# before deciding that is worth writing.
#
# READ ONLY.  It opens Patrick's own set and never saves, which is safe
# because nothing but the save path writes a .region file.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Time::HiRes qw( time );
use Pub::Utils;
use cm_defs;

# NAMED EXPLICITLY.  A bare script leaves $data_dir empty, and dm_set then
# creates its folders at the ROOT OF THE DRIVE - which is exactly what
# happened the first time this was run.

$Pub::Utils::data_dir = 'C:/base_data/data/chartMaker';

use dm_set;
use dm_region;
use dm_coverage;

my $set = $ARGV[0] || '';

loadSets();
$set ||= getActiveSet();
die "no region set to open\n" if !$set;

openSet($set);
my @ids = getRegionIds();
die "'$set' holds no regions\n" if !@ids;

print "set '$set': ".join(', ',@ids)."\n\n";

my $t0 = time();
for my $id (@ids)
{
    my $t = time();
    my $cov = regionCoverage(getRegion($id));
    printf("  %-12s cold %6.3fs  %7d tiles\n",$id,time() - $t,coverageTotal($cov));
}
printf("\n  cold total    %6.3fs\n",time() - $t0);

my $t1 = time();
regionCoverage(getRegion($_)) for @ids;
printf("  warm total    %6.3fs   (nothing changed)\n",time() - $t1);

# A region is edited IN MEMORY only.  Its signature moves, nobody else's
# does, and the next walk should cost exactly that one region.

my $reg = getRegion($ids[0]);
$reg->{geometry}[0][0][0] += 0.00001;

my $t2 = time();
regionCoverage(getRegion($_)) for @ids;
printf("  one edited    %6.3fs   ('%s' moved)\n",time() - $t2,$ids[0]);
