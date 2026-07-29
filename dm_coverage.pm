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
# of the revealed set at every level the card carries.  A partially
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
		coverageHas
		coverageCounts
		coverageTotal
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


sub _ringHitsRect
	# Positive-area intersection between a ring and a lon/lat rectangle.
	#
	# Three ways it can be true, and all three are needed: a vertex
	# inside the rectangle, a rectangle corner inside the ring (the ring
	# swallows the tile whole), or an edge crossing an edge (the ring
	# passes through without either of the first two).
{
	my ($ring,$w,$s,$e,$n) = @_;

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
{
	my ($cov,$reg,$floor,$opts,$depth,$nodes) = @_;
	$depth ||= 0;

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

	if (!$depth)
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

	push @$nodes,{ id => $reg->{id}, depth => $depth, levels => $mine }
		if $nodes;

	# A subregion supplies only the band above this level's zmax.
	_walk($cov,$_,$reg->{zmax}+1,$opts,$depth+1,$nodes)
		for @{$reg->{subregions} || []};
}


sub regionCoverage
	# { zoom => { "x_y" => 1 } } for a whole region, subregions included.
	#
	# THE REGION CARRIES THE LEVELS.  zauthor, zmin and zmax are the
	# region's own, because the region definition IS the specification of
	# what to build -- there is no separate target object holding them.
	#
	# opts: zmax  a hard cap from the build     (default none)
	#       zmin  override the region's floor   (default none)
{
	my ($reg,$opts) = @_;
	$opts ||= {};

	my $floor = defined $opts->{zmin} ? $opts->{zmin} :
		defined $reg->{zmin} ? $reg->{zmin} : $DEF_ZMIN;

	my $cov = {};
	display($dbg_cover,0,"regionCoverage($reg->{id}) zauthor=".
		($reg->{zauthor} // '?')." zmin=$floor zmax=".($reg->{zmax} // '?').
		(defined $opts->{zmax} ? " cap=$opts->{zmax}" : ''));
	_walk($cov,$reg,$floor,$opts,0,$opts->{nodes});
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
