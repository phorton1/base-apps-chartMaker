#!/usr/bin/perl
#---------------------------------------------
# dm_coverage.pm
#---------------------------------------------
# Which tiles a region covers.  See docs/design/regions.md.
#
# The polygon meets the grid EXACTLY ONCE, at the region's AUTHORED zoom
# (zauthor).  After that the polygon is out of the picture and everything
# is derived from that one tile set:
#
#	coarser   the parents of the authored set, down to zmin.  This is
#	          provably the same set as intersecting the polygon at that
#	          zoom -- a parent contains its child, and a coarse tile is
#	          exactly tiled by its descendants -- so taking parents is
#	          simply the cheap way to compute it.
#
#	finer     the COMPLETE set of children, up to zmax -- not the ones
#	          the polygon touches.  An authored tile is included because
#	          the polygon touches it, so the chart already claims the
#	          whole tile; leaving out children that miss the polygon
#	          would put a resolution cliff inside an area the chart says
#	          it covers.
#
# COMPLETENESS OVER [zauthor..zmax] IS NOT AN OPTION.  The plotter cuts
# its reveal mask from the polygon at zauthor and paints at whatever
# level the view scale calls for, so the painted set must be a superset
# of the revealed set at every level the file carries.  A partially
# populated level would open an aperture onto ground nothing painted.
#
# A SUBREGION SUPPLIES THE BAND ITS PARENT DOES NOT REACH: from the
# parent's zmax + 1 up to its own zmax.  Equality at the start is the
# only value that neither gaps nor duplicates.  It quantises its OWN
# polygon at its OWN zmax and takes parents back down to the band's
# floor, which is far cheaper than quantising coarse and filling: the
# tiles it adds are the ones its polygon actually touches at the depth
# it asked for.
#
# ONE COMPUTATION, TWO ENTRY POINTS.  regionCoverage() enumerates, and
# coverageHas() asks about one tile.  Preview uses the second and the
# build uses the first, over the same result -- which is what makes a
# preview a test of the build rather than an illustration of it.
#
# This module holds no control flow and no caching policy.  It computes
# what it is asked for and hands it back; whoever wants to keep the
# answer around can keep it.

package dm_coverage;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw( floor );
use Pub::Utils;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		lonLatToTile
		tileBounds
		regionCoverage
		regionCoverageNodes
		coverageQuantise
		coverageTileHits
		coverageChildren
		coverageHas
		coverageCounts
		coverageTotal
		previewTiles
		polygonsContainPoint
		outsideVertices
		segmentsCross
		ringsCross
		ringSelfCrosses
		polygonsOverlap
	);
}


our $dbg_cover:shared = 1;
	# 1 = quiet
	# 0 = per region and per zoom
	# -1 = per polygon


my $PI = 3.14159265358979;

my $DEF_ZMIN = 10;	# only for a region that somehow carries no zmin


#---------------------------------------------
# the fixed grid
#---------------------------------------------

sub lonLatToTile
{
	my ($lon,$lat,$z) = @_;
	my $n   = 2 ** $z;
	my $rad = $lat * $PI / 180;
	my $x   = floor(($lon + 180) / 360 * $n);
	my $y   = floor((1 - log(sin($rad)/cos($rad) + 1/cos($rad)) / $PI) / 2 * $n);
	$x = 0 if $x < 0;  $x = $n-1 if $x > $n-1;
	$y = 0 if $y < 0;  $y = $n-1 if $y > $n-1;
	return ($x,$y);
}


sub _tileWest  { my ($x,$z) = @_; return $x / (2**$z) * 360 - 180 }

sub _tileNorth
{
	my ($y,$z) = @_;
	my $t = $PI - 2 * $PI * $y / (2**$z);
	return 180 / $PI * atan2((exp($t) - exp(-$t))/2, 1);
}


sub tileBounds
	# west, south, east, north.  A tile IS an axis-aligned rectangle in
	# lon/lat -- the latitude spacing is uneven, but the edges are still
	# lines of constant latitude.
{
	my ($z,$x,$y) = @_;
	return (_tileWest($x,$z), _tileNorth($y+1,$z),
			_tileWest($x+1,$z), _tileNorth($y,$z));
}


#---------------------------------------------
# polygon against tile rectangle
#---------------------------------------------

sub _pointInRing
	# Ray casting.  Used for both "is a tile corner inside the polygon"
	# and nothing else -- one implementation, so the answer cannot depend
	# on which caller asked.
{
	my ($x,$y,$ring) = @_;
	my $in = 0;
	my $n  = scalar(@$ring);
	for (my $i = 0, my $j = $n-1; $i < $n; $j = $i++)
	{
		my ($xi,$yi) = @{$ring->[$i]};
		my ($xj,$yj) = @{$ring->[$j]};
		$in = !$in
			if (($yi > $y) != ($yj > $y)) &&
			   ($x < ($xj-$xi) * ($y-$yi) / ($yj-$yi) + $xi);
	}
	return $in ? 1 : 0;
}


sub _segsCross
{
	my ($ax,$ay,$bx,$by,$cx,$cy,$dx,$dy) = @_;
	my $d1 = ($bx-$ax)*($cy-$ay) - ($by-$ay)*($cx-$ax);
	my $d2 = ($bx-$ax)*($dy-$ay) - ($by-$ay)*($dx-$ax);
	my $d3 = ($dx-$cx)*($ay-$cy) - ($dy-$cy)*($ax-$cx);
	my $d4 = ($dx-$cx)*($by-$cy) - ($dy-$cy)*($bx-$cx);
	return (($d1 > 0) != ($d2 > 0)) && (($d3 > 0) != ($d4 > 0)) ? 1 : 0;
}


our $EDGE_EPSILON = 1e-9;
	# HOW CLOSE TO A TILE EDGE COUNTS AS BEING ON IT.  About four
	# thousandths of an inch on the ground - five orders of magnitude
	# above the float error it has to absorb, seven below the tile it
	# protects.  See docs/design/editing.md.
	#
	# It exists because a tile corner's LATITUDE is an irrational value
	# stored as a double and written to JSON at the platform's default
	# precision, which loses the last few bits.  A vertex snapped to a
	# grid intersection therefore comes back a hair off the true edge, and
	# with an intersects predicate a polygon a hair over a boundary claims
	# the whole tile beyond it - so a seam drawn perfectly on the grid
	# would still contest a row of tiles.
	#
	# The rectangle is INSET by it, never expanded.  A polygon that
	# reaches a tile by less than this is not covering it in any sense
	# anybody means, and a boundary lying along a tile edge belongs to the
	# tile it is inside, not to both.


sub _ringHitsRect
	# Positive-area intersection between a ring and a lon/lat rectangle.
	#
	# Three ways it can be true, and all three are needed: a vertex
	# inside the rectangle, a rectangle corner inside the ring (the ring
	# swallows the tile whole), or an edge crossing an edge (the ring
	# passes through without either of the first two).
{
	my ($ring,$w,$s,$e,$n) = @_;

	# Inset before any test, so all three agree about where the edge is.

	my $eps = $EDGE_EPSILON;
	if ($e - $w > 2*$eps && $n - $s > 2*$eps)
	{
		$w += $eps; $s += $eps; $e -= $eps; $n -= $eps;
	}

	for my $p (@$ring)
	{
		return 1 if $p->[0] > $w && $p->[0] < $e &&
					$p->[1] > $s && $p->[1] < $n;
	}

	return 1 if _pointInRing($w,$s,$ring);

	my @corners = ([$w,$s],[$e,$s],[$e,$n],[$w,$n]);
	my $cnt = scalar(@$ring);
	for (my $i = 0; $i < $cnt; $i++)
	{
		my ($ax,$ay) = @{$ring->[$i]};
		my ($bx,$by) = @{$ring->[($i+1) % $cnt]};

		# cheap reject: the edge's own box misses the rectangle
		next if ($ax < $w && $bx < $w) || ($ax > $e && $bx > $e) ||
				($ay < $s && $by < $s) || ($ay > $n && $by > $n);

		for my $c (0..3)
		{
			my ($cx,$cy) = @{$corners[$c]};
			my ($dx,$dy) = @{$corners[($c+1) % 4]};
			return 1 if _segsCross($ax,$ay,$bx,$by,$cx,$cy,$dx,$dy);
		}
	}
	return 0;
}


sub polygonsContainPoint
	# Is a point inside ANY of these polygons?  Coverage is a union, so a
	# region made of two disjoint bodies contains a point that is in
	# either one.
{
	my ($polys,$lon,$lat) = @_;
	for my $ring (@$polys)
	{
		next if scalar(@$ring) < 3;
		return 1 if _pointInRing($lon,$lat,$ring);
	}
	return 0;
}


sub outsideVertices
	# Which of the inner polygons' vertices fall outside the outer ones.
	# Returns a list of [polygon index, vertex index, lon, lat].
	#
	# PER VERTEX, and deliberately not a true polygon-containment test.
	# The editor refuses a vertex placed outside a parent, one click at a
	# time, so a per-vertex check is exactly the same rule the user was
	# already held to - and a stricter test would reject shapes the
	# interface allowed them to build.
{
	my ($outer,$inner) = @_;
	my @out;
	my $pi = 0;
	for my $ring (@{$inner || []})
	{
		my $vi = 0;
		for my $pt (@$ring)
		{
			# ON THE BOUNDARY COUNTS AS INSIDE, and it has to.  A point
			# exactly on an edge is what a ray cast is worst at, and it is
			# not a rare case: the snap grid exists so that an author can
			# put a subregion's boundary exactly on its parent's, and two
			# vertices snapped to one grid point are bit identical.  A
			# rule that refused that would be fighting the convention the
			# editor offers.

			push @out,[$pi,$vi,$pt->[0],$pt->[1]]
				if !polygonsContainPoint($outer,$pt->[0],$pt->[1]) &&
				   !_pointOnEdge($outer,$pt->[0],$pt->[1]);
			$vi++;
		}
		$pi++;
	}
	return @out;
}


#---------------------------------------------
# polygons against polygons
#---------------------------------------------
# EVERYTHING BELOW ASKS ONE QUESTION - do two segments strictly cross -
# and everything the editor and the model refuse is built out of it: a
# ring against itself is a bowtie, a ring against a sibling's is an
# overlap, and a child's edges against its parent's is the containment
# test that outsideVertices above could never be.
#
# WHY outsideVertices IS NOT ENOUGH, and it is not a nicety.  It tests
# VERTICES, so a subregion can have every corner inside a parent while an
# EDGE runs outside it - cut a concave notch into a region and drag a
# subregion vertex around the far side of the notch, and every check in
# the program agrees.  What that breaks is the nested-coverage invariant:
# the tiles out there have no coarser ancestor, so my_test_rct reports
# orphans, and on the E-Series that imagery is written and can never be
# revealed, because the reveal aperture is cut from the region's own
# coverage at zoom_author.
#
# STRICTLY CROSSING, AND TOUCHING IS NOT CROSSING.  Two shapes that share
# a boundary exactly, or meet at one point, do not overlap - and sharing a
# boundary is a thing authors do on purpose.  So collinear edges and
# shared endpoints are all "no".

our $GEOM_EPS = 1e-9;
	# A DEGREE TOLERANCE, and the two numbers it sits between are what
	# make it defensible rather than a feeling.  One pixel at the map's
	# deepest zoom of 22 is 360/(256*2^22) = 3.4e-7 degrees, about 3.7 cm
	# at the equator; a double holds a longitude near 1.5 to about 1e-16.
	# So this is roughly 340 times finer than anything a person could
	# point at and ten million times coarser than the noise, and there are
	# nine orders of magnitude of daylight on either side of it.
	#
	# IT QUANTISES THE COMPARISON, NEVER THE DATA.  Geometry is stored as
	# drawn; this only decides what counts as touching.  The applet holds
	# the same constant, because a rule enforced in two places with two
	# tolerances is two rules.


sub _sideOf
	# Which side of the line a->b the point p is on: 1, -1, or 0 for on
	# it, where ON means within GEOM_EPS.
	#
	# MEASURED AS A DISTANCE AND NOT AS A CROSS PRODUCT.  The cross
	# product's units are degrees squared and its magnitude scales with
	# the segment's length, so one threshold against it would mean a
	# different distance on a long edge than on a short one - a region's
	# outline and a detail box's differ by two orders of magnitude here.
{
	my ($ax,$ay,$bx,$by,$px,$py) = @_;
	my $dx = $bx - $ax;
	my $dy = $by - $ay;
	my $len = sqrt($dx*$dx + $dy*$dy);
	return 0 if $len <= 0;
	my $dist = ($dx*($py-$ay) - $dy*($px-$ax)) / $len;
	return 0 if abs($dist) <= $GEOM_EPS;
	return $dist > 0 ? 1 : -1;
}


sub segmentsCross
	# Do the two segments STRICTLY cross - each straddling the other's
	# line.  A shared endpoint, a T junction and any collinear overlap all
	# answer no, because a zero on either side kills the product.
{
	my ($a,$b,$c,$d) = @_;
	my $d1 = _sideOf(@$c,@$d,@$a);
	my $d2 = _sideOf(@$c,@$d,@$b);
	return 0 if $d1 * $d2 >= 0;
	my $d3 = _sideOf(@$a,@$b,@$c);
	my $d4 = _sideOf(@$a,@$b,@$d);
	return $d3 * $d4 < 0 ? 1 : 0;
}


sub _edges
	# One ring as a list of [from,to], closing back to the start.
{
	my ($ring) = @_;
	return () if !$ring || scalar(@$ring) < 3;
	my @e;
	for my $i (0..$#$ring)
	{
		push @e,[$ring->[$i],$ring->[($i+1) % scalar(@$ring)]];
	}
	return @e;
}


sub ringsCross
	# The first place an edge of one polygon set strictly crosses an edge
	# of the other, as [lon,lat] of the crossing's first vertex, or undef.
{
	my ($a,$b) = @_;
	for my $ra (@{$a || []})
	{
		for my $ea (_edges($ra))
		{
			for my $rb (@{$b || []})
			{
				for my $eb (_edges($rb))
				{
					return [ $ea->[0][0], $ea->[0][1] ]
						if segmentsCross($ea->[0],$ea->[1],$eb->[0],$eb->[1]);
				}
			}
		}
	}
	return undef;
}


sub ringSelfCrosses
	# A bowtie: two edges of ONE ring that cross.  Adjacent edges are
	# skipped because they share an endpoint by construction and a shared
	# endpoint is not a crossing anyway - the skip is for speed, not for
	# correctness.
{
	my ($ring) = @_;
	my @e = _edges($ring);
	return undef if scalar(@e) < 4;
	for my $i (0..$#e)
	{
		for my $j ($i+2..$#e)
		{
			next if $i == 0 && $j == $#e;		# closing edge touches the first
			return [ $e[$i][0][0], $e[$i][0][1] ]
				if segmentsCross($e[$i][0],$e[$i][1],$e[$j][0],$e[$j][1]);
		}
	}
	return undef;
}


sub _pointOnEdge
	# Is the point ON one of these polygons' edges, within GEOM_EPS?  Used
	# only to keep a shared boundary from reading as containment.
{
	my ($polys,$x,$y) = @_;
	for my $ring (@{$polys || []})
	{
		for my $e (_edges($ring))
		{
			my ($p,$q) = @$e;
			next if _sideOf(@$p,@$q,$x,$y) != 0;

			# On the infinite line; now inside the segment's own span,
			# with the tolerance allowed at each end.

			my ($lo_x,$hi_x) = $p->[0] <= $q->[0] ?
				($p->[0],$q->[0]) : ($q->[0],$p->[0]);
			my ($lo_y,$hi_y) = $p->[1] <= $q->[1] ?
				($p->[1],$q->[1]) : ($q->[1],$p->[1]);
			return 1 if $x >= $lo_x - $GEOM_EPS && $x <= $hi_x + $GEOM_EPS &&
						$y >= $lo_y - $GEOM_EPS && $y <= $hi_y + $GEOM_EPS;
		}
	}
	return 0;
}


sub polygonsOverlap
	# Do these two polygon sets share INTERIOR area?  Returns a point at
	# the offence, or undef.
	#
	# TWO WAYS TO OVERLAP AND BOTH ARE NEEDED.  Either an edge crosses an
	# edge, or one shape is wholly inside the other and no edge crosses
	# anything - a small box drawn in the middle of a big one is the second
	# case entirely.
	#
	# A vertex sitting ON the other's boundary does NOT count, which is
	# what lets two areas share a border, or meet at a corner, without
	# being called an overlap.
{
	my ($a,$b) = @_;
	my $hit = ringsCross($a,$b);
	return $hit if $hit;

	for my $pair ([$a,$b],[$b,$a])
	{
		my ($inner,$outer) = @$pair;
		for my $ring (@{$inner || []})
		{
			for my $pt (@$ring)
			{
				next if !polygonsContainPoint($outer,$pt->[0],$pt->[1]);
				next if _pointOnEdge($outer,$pt->[0],$pt->[1]);
				return [ $pt->[0], $pt->[1] ];
			}
		}
	}
	return undef;
}


#---------------------------------------------
# quantising one level's own polygons
#---------------------------------------------

sub _quantise
	# The tiles at zoom z whose rectangle meets any of these polygons.
	# This is the ONLY place a polygon becomes tiles.
{
	my ($polys,$z) = @_;
	my %set;

	for my $ring (@$polys)
	{
		next if scalar(@$ring) < 3;

		my (@lon,@lat);
		for my $p (@$ring) { push @lon,$p->[0]; push @lat,$p->[1] }
		@lon = sort { $a <=> $b } @lon;
		@lat = sort { $a <=> $b } @lat;

		my ($x0,$y0) = lonLatToTile($lon[0], $lat[-1],$z);	# NW corner
		my ($x1,$y1) = lonLatToTile($lon[-1],$lat[0], $z);	# SE corner

		my $tested = 0;
		my $hit    = 0;
		for my $x ($x0..$x1)
		{
			for my $y ($y0..$y1)
			{
				$tested++;
				my ($w,$s,$e,$n) = tileBounds($z,$x,$y);
				next if !_ringHitsRect($ring,$w,$s,$e,$n);
				$set{"${x}_${y}"} = 1;
				$hit++;
			}
		}
		display($dbg_cover+2,1,"z$z ring of ".scalar(@$ring).
			" points: $hit of $tested tiles in the bounding box");
	}
	return \%set;
}


sub _parentsOf
{
	my ($set) = @_;
	my %up;
	for my $key (keys %$set)
	{
		my ($x,$y) = split(/_/,$key);
		$up{ int($x/2)."_".int($y/2) } = 1;
	}
	return \%up;
}


sub _childrenOf
{
	my ($set) = @_;
	my %down;
	for my $key (keys %$set)
	{
		my ($x,$y) = split(/_/,$key);
		for my $dx (0,1)
		{
			for my $dy (0,1)
			{
				$down{ (2*$x+$dx)."_".(2*$y+$dy) } = 1;
			}
		}
	}
	return \%down;
}


sub coverageQuantise
	# THE TILES AT ONE ZOOM THAT MEET THESE POLYGONS, and nothing about
	# regions, bands or zauthor.
	#
	# Public for the probe, whose subject is a SERVICE rather than a build:
	# it needs the geometry of an area and an explicit zoom range, and none
	# of the region's own levels mean anything to it.  Everything else here
	# goes through _walk, which exists to apply the band rule; this is the
	# one caller that must not.
{
	my ($polys,$z) = @_;
	return _quantise($polys,$z);
}


sub coverageTileHits
	# Does one tile's rectangle meet any of these polygons?
	#
	# THE SAME TEST coverageQuantise APPLIES, exposed for the one caller
	# that produces candidate tiles by ARITHMETIC rather than by
	# quantising: a descendant of a covering cell may lie inside the cell
	# and outside the area, and it has to be judged by the same geometry
	# or the sample and the walk would disagree about what is inside.
	#
	# Not a point test.  A tile is in when its rectangle MEETS the polygon,
	# which at coarse levels is the only answer that can be right - a tile
	# larger than the whole area contains it without its centre being
	# anywhere near it.
{
	my ($polys,$z,$x,$y) = @_;
	my ($w,$s,$e,$n) = tileBounds($z,$x,$y);
	for my $ring (@$polys)
	{
		next if scalar(@$ring) < 3;
		return 1 if _ringHitsRect($ring,$w,$s,$e,$n);
	}
	return 0;
}


sub coverageChildren
	# ONE LEVEL FINER, ARITHMETICALLY.  Below a node's quantised level
	# coverage IS the complete children of that level, so descending is
	# arithmetic and needs no polygon.  That is what lets the sampler reach
	# z19 strata without ever enumerating z19: it walks in strata mode,
	# which stops at the quantised level, and descends from there only as
	# far as it needs to have enough cells to draw from.
	#
	# Public for that caller.  Nothing here decides how far to go.
{
	my ($set) = @_;
	return _childrenOf($set);
}


#---------------------------------------------
# the coverage of a whole region
#---------------------------------------------

sub _addLevel
	# Merge one level's tiles into the accumulating coverage.
{
	my ($cov,$z,$set) = @_;
	$cov->{$z} ||= {};
	$cov->{$z}{$_} = 1 for keys %$set;
}


sub _walk
	# One region or subregion, then its children.
	#
	# $floor is the zoom below which this level contributes nothing.  For
	# the region it is zmin; for a subregion it is the parent's zmax + 1,
	# because the parent already covers its zmax and everything coarser.
	#
	# THE TWO ARE NOT THE SAME SHAPE, and that is the whole of the model.
	# A region has an authored level with a band above it: it quantises at
	# zauthor and fills complete children to zmax.  A subregion has no
	# authored level at all -- it quantises at its own zmax, the finest
	# thing it will carry, and only reaches back down to the floor.
	#
	# $nodes, when given, also collects each node's OWN contribution
	# separately.  The merged coverage is what a build enumerates, but an
	# exporter needs to know which tiles form one detail cluster -- a
	# coverage block wants to wrap an actual cluster, and the merge has
	# already thrown that away.  Same walk, so the two can never disagree.
	#
	# $path is the node's ancestry as ids joined by '/', and it is what
	# every consumer keys a node BY -- see the note on the node hash below.
{
	my ($cov,$reg,$floor,$opts,$depth,$nodes,$path) = @_;
	$depth ||= 0;
	$path  = $reg->{id} if !defined($path);

	my $cap  = $opts->{zmax};
	my $mine = {};

	# The build's cap can pull the quantising zoom in.  min(region,
	# build) -- the region asks, the build decides.

	my $own = $depth ? $reg->{zmax} : $reg->{zauthor};
	my $qz  = defined($cap) && $cap < $own ? $cap : $own;

	# A band entirely above the cap contributes nothing.  This is how
	# 'build --zmax 16' prunes a z17-18 detail area arithmetically,
	# without anything having to know it is a detail area.

	if ($qz < $floor)
	{
		display($dbg_cover,1,sprintf("%-16s band z%d-%d is above the cap - skipped",
			$reg->{id},$floor,$own));
		return;
	}

	my $set = _quantise($reg->{geometry},$qz);
	display($dbg_cover,1,sprintf("%-16s %s z%-2d quantised at z%-2d -> %d tiles",
		$reg->{id},$depth ? 'zmax   ' : 'zauthor',$own,$qz,scalar(keys %$set)));
	_addLevel($cov,$qz,$set);
	_addLevel($mine,$qz,$set);

	# coarser: parents, down to this level's floor
	my $up = $set;
	for (my $z = $qz-1; $z >= $floor; $z--)
	{
		$up = _parentsOf($up);
		_addLevel($cov,$z,$up);
		_addLevel($mine,$z,$up);
	}

	# finer: complete children to zmax, bounded by the cap.  A subregion
	# has already quantised AT its zmax, so this loop is a region's alone.
	#
	# STRATA MODE STOPS HERE, and it is not the same thing as a cap.  A cap
	# is a statement about the whole walk and SKIPS any node whose band lies
	# above it, which would silently drop exactly the detail areas a survey
	# is being run to judge.  Strata mode keeps every node and declines only
	# the descent, because below the quantised level coverage is the
	# complete children of it and the sampler can get there by arithmetic.
	# Capping a region at z15 to avoid enumerating z19 loses the z17-18
	# subregion; this does not.

	if (!$depth && !$opts->{strata})
	{
		my $stop = $reg->{zmax};
		$stop = $cap if defined($cap) && $cap < $stop;
		my $down = $set;
		for (my $z = $qz+1; $z <= $stop; $z++)
		{
			$down = _childrenOf($down);
			_addLevel($cov,$z,$down);
			_addLevel($mine,$z,$down);
		}
	}

	# THE PATH IS THE NODE'S IDENTITY, and id is not.  An id is unique
	# within a region but says nothing across regions, and depth+id was
	# not even unique within one - two subregions of different parents at
	# the same depth may share an id, and every consumer keying on
	# "<depth>:<id>" silently gave one of them the other's answer.  The
	# path cannot collide, because siblings are unique by validation.
	#
	# 'Bocas', 'Bocas/Popa00', 'Bocas/Popa00/Dock'.  '/' is safe as the
	# joiner because an id is [A-Za-z0-9] and can never contain one.

	# qz, floor and zmax say what BAND this node supplies, which the levels
	# hash cannot say for itself in strata mode - it stops at qz, and a
	# consumer would read that as "this node ends here".  They are the
	# node's own numbers after the cap has been applied, so a caller never
	# has to redo min(region,build) for itself.

	push @$nodes,{ id => $reg->{id}, depth => $depth, path => $path,
				   levels => $mine, qz => $qz, floor => $floor,
				   zmax => (defined($cap) && defined($reg->{zmax}) &&
							$cap < $reg->{zmax} ? $cap : $reg->{zmax}) }
		if $nodes;

	# A subregion supplies only the band above this level's zmax.
	_walk($cov,$_,$reg->{zmax}+1,$opts,$depth+1,$nodes,"$path/$_->{id}")
		for @{$reg->{subregions} || []};
}


# WHAT A REGION COVERS IS A FUNCTION OF THE REGION, so the last answer is
# kept beside the question that produced it.  The question is the region's
# own content - its levels, its polygons, its subregions - and nothing else
# reaches this computation, so a matching signature means a valid answer no
# matter what else changed in the application.
#
# That is why the signature is the key rather than a version number and a
# list of what was dirtied: nothing has to be told which region changed, and
# an invalidation cannot be forgotten at a call site.  Building the string
# costs microseconds against a walk that costs a fifth of a second.
#
# ONE ENTRY PER REGION, holding only its latest signature: the previous
# coverage of a region that has just been edited is of no use to anybody,
# and keeping it would grow without bound across a session of editing.
#
# The result is READ ONLY to callers.  Nothing mutates it today; a caller
# that did would be corrupting every later answer as well as its own.
#
# Per thread, like every other cache here -- each thread pays once.

my %cov_by_sig;

sub _regionSig
{
	my ($reg) = @_;
	my $s = ($reg->{id} // '').':'.($reg->{zauthor} // '').':'.
			($reg->{zmin} // '').':'.($reg->{zmax} // '');
	for my $poly (@{$reg->{geometry} || []})
	{
		$s .= '|'.join(',',map { $_->[0].' '.$_->[1] } @$poly);
	}
	$s .= '{'._regionSig($_).'}' for @{$reg->{subregions} || []};
	return $s;
}


sub regionCoverage
	# { zoom => { "x_y" => 1 } } for a whole region, subregions included.
	#
	# THE REGION CARRIES THE LEVELS.  zauthor, zmin and zmax are the
	# region's own, because the region definition IS the specification of
	# what to build -- there is no separate target object holding them.
	#
	# opts: zmax    a hard cap from the build     (default none)
	#       zmin    override the region's floor   (default none)
	#       strata  stop at each node's quantised level and do not fill
	#               children below it - see _walk.  For the sampler.
{
	my ($reg,$opts) = @_;
	$opts ||= {};

	my $floor = defined $opts->{zmin} ? $opts->{zmin} :
		defined $reg->{zmin} ? $reg->{zmin} : $DEF_ZMIN;

	# The caps are part of the question, and so is whether the per-node
	# breakdown was asked for - a caller that wants the nodes cannot be
	# served an answer that was computed without them.

	my $want = $opts->{nodes} ? 1 : 0;
	my $key = ($reg->{id} // '').'|'.($opts->{zmin} // '').'|'.
			  ($opts->{zmax} // '').'|'.$want.'|'.($opts->{strata} ? 1 : 0);
	my $sig = _regionSig($reg);

	my $have = $cov_by_sig{$key};
	if ($have && $have->{sig} eq $sig)
	{
		display($dbg_cover,0,"regionCoverage($reg->{id}) unchanged");
		push @{$opts->{nodes}},@{$have->{nodes}} if $want;
		return $have->{cov};
	}

	my $cov = {};
	display($dbg_cover,0,"regionCoverage($reg->{id}) zauthor=".
		($reg->{zauthor} // '?')." zmin=$floor zmax=".($reg->{zmax} // '?').
		(defined $opts->{zmax} ? " cap=$opts->{zmax}" : ''));
	_walk($cov,$reg,$floor,$opts,0,$opts->{nodes});

	$cov_by_sig{$key} = { sig => $sig, cov => $cov,
		nodes => $want ? [ @{$opts->{nodes}} ] : undef };
	return $cov;
}


sub regionCoverageNodes
	# The same walk, reported PER NODE instead of merged:
	#
	#	[ { id, depth, levels => { z => { "x_y" => 1 } } }, ... ]
	#
	# in walk order, so the region comes first and its subregions follow.
	# The exporter needs this because a coverage block should wrap one
	# actual cluster of tiles, and the merged answer has already lost
	# which tiles belonged together.
	#
	# Returns ($merged,$nodes) so a caller that wants both pays for one
	# walk.  They cannot disagree; there is only one implementation.
{
	my ($reg,$opts) = @_;
	$opts ||= {};
	my @nodes;
	my $cov = regionCoverage($reg,{ %$opts, nodes => \@nodes });
	return ($cov,\@nodes);
}


sub coverageHas
	# The predicate.  Preview asks this of the same structure the build
	# enumerates, which is the whole point.
{
	my ($cov,$z,$x,$y) = @_;
	return 0 if !$cov->{$z};
	return $cov->{$z}{"${x}_${y}"} ? 1 : 0;
}


sub previewTiles
	# WHAT THE OUTPUT ACTUALLY HOLDS over a rectangle of tiles at one zoom.
	# Returns { "x_y" => source id } for the tiles in coverage AT THIS ZOOM,
	# and nothing at all for the rest.
	#
	# AT THIS ZOOM, and no fallback.  A file carries tiles at the levels a
	# region was built to and nothing below them; a plotter papers over the
	# difference by magnifying whatever ancestor it has, and an earlier
	# version of this reproduced that.  It was the wrong question.  What an
	# author needs to see is which tiles are in the output at the level being
	# looked at - so that zooming in until the imagery stops IS the answer
	# to "how deep did I build here", read directly off the map.
	#
	# It is therefore the same question the tile footprint asks, and
	# deliberately so: the footprint draws the outlines, this fills them in,
	# and the two cannot disagree because they read the same structure.
	#
	# $cov is the merged coverage of the working set, valued by the SOURCE
	# each tile would be built from rather than by 1.
{
	my ($cov,$z,$x0,$y0,$x1,$y1) = @_;
	my %out;

	my $level = $cov->{$z};
	return \%out if !$level;

	for my $x ($x0..$x1)
	{
		for my $y ($y0..$y1)
		{
			my $src = $level->{"${x}_${y}"};
			$out{"${x}_${y}"} = $src if $src;
		}
	}

	return \%out;
}


sub coverageCounts
{
	my ($cov) = @_;
	my %counts;
	$counts{$_} = scalar(keys %{$cov->{$_}}) for keys %$cov;
	return \%counts;
}


sub coverageTotal
{
	my ($cov) = @_;
	my $total = 0;
	$total += scalar(keys %{$cov->{$_}}) for keys %$cov;
	return $total;
}


1;
