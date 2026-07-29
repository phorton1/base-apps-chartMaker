#!/usr/bin/perl
#---------------------------------------------
# dm_coverage.pm
#---------------------------------------------
# Which tiles a region covers.  See docs/design/regions.md.
#
# The polygon meets the grid EXACTLY ONCE, at the region's canonical
# zoom.  After that the polygon is out of the picture and everything is
# derived from that one tile set:
#
#	coarser   the parents of the canonical set.  This is provably the
#	          same set as intersecting the polygon at that zoom -- a
#	          parent contains its child, and a coarse tile is exactly
#	          tiled by its descendants -- so taking parents is simply
#	          the cheap way to compute it.
#
#	finer     the COMPLETE set of children, not the ones the polygon
#	          touches.  A canonical tile is included because the polygon
#	          touches it, so the chart already claims the whole tile;
#	          leaving out children that miss the polygon would put a
#	          resolution cliff inside an area the chart says it covers.
#
# EACH LEVEL SUPPLIES ONLY THE BAND ITS PARENT DOES NOT REACH.  Because a
# subregion lies inside its parent, its tiles at the parent's canonical
# zoom are already in the parent's set.  Nothing enforces the partition;
# it falls out of containment.
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

my $DEF_ZMIN = 10;	# overview floor - an output property, defaulted here
my $DEF_FILL = 1;	# levels below canonical that get filled completely


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
	# $floor is the zoom below which this level contributes nothing --
	# the parent's canonical zoom plus one, because the parent already
	# covers its canonical zoom and everything coarser.
{
	my ($cov,$reg,$floor,$opts) = @_;

	my $c    = $reg->{canonical_zoom};
	my $fill = $opts->{fill};
	my $cap  = $opts->{zmax};

	# The target's cap can pull the quantising zoom in.  min(region,
	# target) -- the region asks, the target decides.

	my $qz = defined($cap) && $cap < $c ? $cap : $c;

	my $set = _quantise($reg->{geometry},$qz);
	display($dbg_cover,1,sprintf("%-16s canonical z%-2d quantised at z%-2d -> %d tiles",
		$reg->{id},$c,$qz,scalar(keys %$set)));
	_addLevel($cov,$qz,$set);

	# coarser: parents, down to this level's floor
	my $up = $set;
	for (my $z = $qz-1; $z >= $floor; $z--)
	{
		$up = _parentsOf($up);
		_addLevel($cov,$z,$up);
	}

	# finer: complete fill, bounded by the target's cap
	my $down  = $set;
	my $stop  = $qz + $fill;
	$stop = $cap if defined($cap) && $cap < $stop;
	for (my $z = $qz+1; $z <= $stop; $z++)
	{
		$down = _childrenOf($down);
		_addLevel($cov,$z,$down);
	}

	# A subregion supplies only what this level does not reach.
	_walk($cov,$_,$qz+1,$opts) for @{$reg->{subregions} || []};
}


sub regionCoverage
	# { zoom => { "x_y" => 1 } } for a whole region, subregions included.
	#
	# opts: zmin  the overview floor            (default 10)
	#       fill  levels below canonical        (default 1)
	#       zmax  a hard cap from the target    (default none)
{
	my ($reg,$opts) = @_;
	$opts ||= {};
	$opts->{zmin} = $DEF_ZMIN if !defined $opts->{zmin};
	$opts->{fill} = $DEF_FILL if !defined $opts->{fill};

	my $cov = {};
	display($dbg_cover,0,"regionCoverage($reg->{id}) zmin=$opts->{zmin} ".
		"fill=$opts->{fill}".(defined $opts->{zmax} ? " zmax=$opts->{zmax}" : ''));
	_walk($cov,$reg,$opts->{zmin},$opts);
	return $cov;
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
