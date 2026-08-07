#!/usr/bin/perl
#---------------------------------------------
# test_geometry.pl -- polygons against polygons
#---------------------------------------------
# THE PRIMITIVE IS ONE QUESTION - do two segments strictly cross - and
# every rule the editor and the model enforce is built out of it. So it is
# tested on its own, in coordinates a person can check by eye, before
# anything built on it is tested at all.
#
# THE CASE THIS EXISTS FOR was reproduced on screen: cut a concave notch
# into a region, then drag a subregion vertex around the far side of the
# notch. Every corner of the subregion is inside its parent and an EDGE is
# not, and the per-vertex test that guarded containment for a year cannot
# see it. What it costs is the nested-coverage invariant - tiles out there
# have no coarser ancestor, so they are built and can never be revealed.
#
# NOTHING HERE TOUCHES THE DISK. The primitives are pure, and
# _checkContainment reads only geometry and subregions, so a region is a
# hash written in place rather than a fixture.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_coverage;
use dm_region;

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

# Rings are [lon,lat] pairs, counter-clockwise, unclosed - the same shape
# a .region file holds.

sub box
{
	my ($x0,$y0,$x1,$y1) = @_;
	return [ [$x0,$y0], [$x1,$y0], [$x1,$y1], [$x0,$y1] ];
}


print "=== segments cross, and touching is not crossing ===\n";

my $A = [0,0]; my $B = [10,10];
ok(segmentsCross($A,$B,[0,10],[10,0]),"an X crosses");
ok(!segmentsCross($A,$B,[20,20],[30,30]),"two far apart do not");
ok(!segmentsCross($A,$B,[0,1],[10,11]),"parallel do not");
ok(!segmentsCross($A,$B,[10,10],[20,0]),"a shared endpoint is not a crossing");
ok(!segmentsCross($A,$B,[5,5],[10,0]),
	"nor is a T junction - one ending ON the other");
ok(!segmentsCross($A,$B,[5,5],[15,15]),"nor is a collinear overlap");

# The tolerance, from both sides of it.  GEOM_EPS is 1e-9 degrees.

ok(!segmentsCross([0,0],[1,0],[0.5,-1e-12],[0.5,-2e-12]),
	"a segment ending a picometre short does not reach");
ok(segmentsCross([0,0],[1,0],[0.5,-1e-6],[0.5,1e-6]),
	"one crossing by a micro-degree does");


print "\n=== a ring against itself ===\n";

ok(!ringSelfCrosses(box(0,0,10,10)),"a square does not cross itself");
ok(!ringSelfCrosses([[0,0],[10,0],[10,10],[5,4],[0,10]]),
	"nor does a concave shape");
ok(ringSelfCrosses([[0,0],[10,0],[0,10],[10,10]]),"a bowtie does");


print "\n=== two polygons ===\n";

ok(!polygonsOverlap([box(0,0,4,4)],[box(6,6,10,10)]),
	"two boxes apart do not overlap");
ok(polygonsOverlap([box(0,0,6,6)],[box(4,4,10,10)]),
	"two that interpenetrate do");
ok(polygonsOverlap([box(0,0,10,10)],[box(3,3,7,7)]),
	"and one wholly inside the other does, though no edge crosses anything");

# THE ONE THAT MATTERS FOR AUTHORS.  Sharing a border, or meeting at a
# corner, is a thing people do on purpose and must not be an overlap.

ok(!polygonsOverlap([box(0,0,5,10)],[box(5,0,10,10)]),
	"two sharing a border exactly do NOT overlap");
ok(!polygonsOverlap([box(0,0,5,5)],[box(5,5,10,10)]),
	"nor do two meeting at one corner");
ok(!polygonsOverlap([box(0,0,5,10)],[box(5.0000000001,0,10,10)]),
	"nor do two a tenth of a nanodegree apart");


print "\n=== containment, and the notch that per-vertex could not see ===\n";

# A 'C' opening to the right: the notch is x 4..10, y 3..7.

my $C = [ [0,0],[10,0],[10,3],[4,3],[4,7],[10,7],[10,10],[0,10] ];

sub node
{
	my ($id,$geom,@subs) = @_;
	return { id => $id, geometry => $geom, subregions => [ @subs ] };
}

my $inside = node('R',[$C],node('S',[box(1,1,3,9)]));
ok(dm_region::_checkContainment('t',$inside),
	"a subregion wholly inside its parent is accepted");

my $out = node('R',[$C],node('S',[box(1,1,3,20)]));
ok(!dm_region::_checkContainment('t',$out),
	"one with a vertex outside is refused, as it always was");

# EVERY CORNER INSIDE, ONE EDGE OUT.  (6,2) and (8,2) are in the lower arm,
# (6,8) is in the upper one, and the edge from (6,2) to (6,8) runs straight
# through the notch, which is not part of the region at all.

my $notch = node('R',[$C],node('S',[[ [6,2],[8,2],[6,8] ]]));
ok(!scalar(outsideVertices([$C],[[ [6,2],[8,2],[6,8] ]])),
	"the notch case has NO vertex outside - which is why it used to pass");
ok(!dm_region::_checkContainment('t',$notch),
	"and it is refused now, on the edge");

my $hard = node('R',[$C],node('S',[box(0,0,3,10)]));
ok(dm_region::_checkContainment('t',$hard),
	"a subregion drawn hard against the parent's boundary is still accepted");


print "\n=== siblings, and a node's own polygons ===\n";

my $apart = node('R',[box(0,0,20,20)],
	node('A',[box(1,1,5,5)]),node('B',[box(10,10,15,15)]));
ok(dm_region::_checkContainment('t',$apart),"two siblings apart are accepted");

my $touch = node('R',[box(0,0,20,20)],
	node('A',[box(1,1,5,5)]),node('B',[box(5,1,9,5)]));
ok(dm_region::_checkContainment('t',$touch),
	"two siblings sharing a border are accepted");

my $over = node('R',[box(0,0,20,20)],
	node('A',[box(1,1,6,6)]),node('B',[box(4,4,9,9)]));
ok(!dm_region::_checkContainment('t',$over),"two siblings overlapping are refused");

my $twobody = node('R',[box(0,0,4,4),box(6,6,10,10)]);
ok(dm_region::_checkContainment('t',$twobody),
	"a node with two separate bodies is fine");

my $selfover = node('R',[box(0,0,6,6),box(4,4,10,10)]);
ok(!dm_region::_checkContainment('t',$selfover),
	"but not two bodies of one node over the same ground");

my $bow = node('R',[[ [0,0],[10,0],[0,10],[10,10] ]]);
ok(!dm_region::_checkContainment('t',$bow),"nor a polygon that crosses itself");

# DEPTH, because the walk recurses and a rule that stopped at the first
# level would be silently half a rule.

my $deep = node('R',[box(0,0,20,20)],
	node('A',[box(1,1,10,10)],
		node('A1',[box(2,2,5,5)]),node('A2',[box(4,4,8,8)])));
ok(!dm_region::_checkContainment('t',$deep),
	"and it reaches subregions of subregions");


print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
