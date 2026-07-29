#!/usr/bin/perl
#---------------------------------------------
# dm_rct.pm
#---------------------------------------------
# The RCT exporter -- one .rct file per region, for the E-Series aerial
# overlay.  See docs/design/rct.md, and the NORMATIVE byte specification
# at Pub/Ray/docs/e80_firmware/deployment/raster_chart_format.md.
#
# THE BOUNDARY IS THE COVERAGE ENUMERATOR PLUS THE CACHE, not a file.
# This module reads dm_coverage for which tiles, and dm_cache for their
# bytes.  It does not read an mbtiles: mbtiles is a peer output, not an
# intermediate, and an RCT needs the region's authored level and polygon
# -- neither of which is a fact about a container of tiles.
#
# NOTHING IS FETCHED HERE.  A tile the cache does not hold is simply
# absent from the card, which the format expresses natively (the miss bit
# is set and the plotter overzooms from a present ancestor).  Filling the
# cache is the build's job and happens before this runs.
#
# BLOCKS ARE FEW AND LARGE, deliberately.  The firmware builds its reveal
# aperture as a list of screen rectangles, closing a run at every block
# edge as well as at every absent cell, out of a budget shared across the
# whole card.  Fragmenting a zoom spends that budget on seams rather than
# on coverage.  So: one block over the whole region at its own levels,
# and one block per subregion at the levels only that subregion reaches.
# That is exactly the structure regionCoverageNodes() reports.
#
# ALL INTEGERS LITTLE-ENDIAN.  Signed 32-bit fields are written through
# _u32() rather than pack 'l<', because the semicircle values are the one
# place a sign error puts imagery on the wrong side of the world.

package dm_rct;
use strict;
use warnings;
use POSIX qw( floor ceil );
use Pub::Utils;
use cm_defs;
use dm_cache;
use dm_coverage;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		writeRct
		rctCardName
	);
}


our $dbg_rct:shared = 0;
	# 0  = one line per region and per zoom
	# -1 = one line per block
	# -2 = per tile


my $MAGIC			= 'RCT1';
my $FORMAT_VERSION	= 1;
my $HEADER_BYTES	= 128;
my $TILE_SIZE		= 256;
my $PROJECTION		= 3857;

my $ZDIR_ENTRY		= 32;
my $BLK_ENTRY		= 48;
my $IDX_ENTRY		= 8;

# E80 display mercator.  NOT WGS84 -- the geodetic-to-geocentric
# reduction is about 6.9 km at 9.3N, which is a real offset rather than a
# rounding term.  International-1924, a = 6378388.

my $PI	= 3.14159265358979;
my $S31	= 2147483648.0;		# 2^31 semicircles == 180 degrees
my $C1	= 1.006764293;		# a^2/b^2, the geodetic reduction


#---------------------------------------------
# small helpers
#---------------------------------------------

sub _u32
	# A signed value as the unsigned 32-bit pattern that 'V' will write.
{
	my ($v) = @_;
	$v = int($v + ($v < 0 ? -0.5 : 0.5));
	$v = -2147483648 if $v < -2147483648;
	$v =  2147483647 if $v >  2147483647;
	return $v < 0 ? $v + 4294967296 : $v;
}


sub _semiEasting
{
	my ($lon) = @_;
	return _u32($lon * $S31 / 180.0);
}


sub _semiNorthing
{
	my ($lat) = @_;
	my $rad = $lat * $PI / 180.0;
	my $psi = atan2(sin($rad)/cos($rad) / $C1, 1);
	return _u32(($S31 / $PI) * log(sin($PI/4 + $psi/2) / cos($PI/4 + $psi/2)));
}


sub rctCardName
	# The 8.3 short name the card carries.  The stem is the region id and
	# nothing else -- see docs/design/rct.md on why this is asserted here
	# rather than trusted.
{
	my ($id) = @_;
	return undef if !defined($id) || $id !~ /^[A-Za-z0-9]{1,8}$/;
	return "$id.rct";
}


#---------------------------------------------
# blocks
#---------------------------------------------

sub _blockOf
	# The bounding rectangle of one set of "x_y" keys, plus the tiles it
	# holds.  A block's rectangle may still contain absent cells; the
	# presence bitmap is what says which.
{
	my ($z,$set) = @_;
	my (@xs,@ys);
	for my $key (keys %$set)
	{
		my ($x,$y) = split(/_/,$key);
		push @xs,$x;  push @ys,$y;
	}
	return undef if !@xs;

	my ($x0,$x1) = (sort { $a <=> $b } @xs)[0,-1];
	my ($y0,$y1) = (sort { $a <=> $b } @ys)[0,-1];

	return {
		z		=> $z,
		x_min	=> $x0,  x_max => $x1,
		y_min	=> $y0,  y_max => $y1,
		grid_w	=> $x1 - $x0 + 1,
		grid_h	=> $y1 - $y0 + 1,
		keys	=> $set,
	};
}


sub _planBlocks
	# Per zoom, the list of blocks, from the per-node coverage.
	#
	# A node contributes one block at each zoom it reaches.  The region is
	# node 0 and covers its own band; each subregion covers only the band
	# above its parent, so at those zooms the region contributes nothing
	# and only the detail clusters appear -- which is precisely the
	# "one small rectangle per area of actual coverage" the format asks
	# for, with no clustering heuristic anywhere.
{
	my ($nodes) = @_;
	my %by_zoom;

	for my $node (@$nodes)
	{
		for my $z (sort { $a <=> $b } keys %{$node->{levels}})
		{
			my $blk = _blockOf($z,$node->{levels}{$z});
			next if !$blk;
			$blk->{owner} = $node->{id};
			push @{$by_zoom{$z}},$blk;
		}
	}
	return \%by_zoom;
}


sub _checkDisjoint
	# Blocks within one zoom OF ONE FILE must not overlap: a tile has to
	# be addressed by exactly one of them.  Across files they may and do,
	# but that is the renderer's problem and it resolves it by testing
	# presence rather than containment.
{
	my ($z,$blocks,$where) = @_;
	for (my $i = 0; $i < @$blocks; $i++)
	{
		for (my $j = $i+1; $j < @$blocks; $j++)
		{
			my ($a,$b) = ($blocks->[$i],$blocks->[$j]);
			next if $a->{x_max} < $b->{x_min} || $b->{x_max} < $a->{x_min};
			next if $a->{y_max} < $b->{y_min} || $b->{y_max} < $a->{y_min};
			error("$where z$z: blocks '$a->{owner}' and '$b->{owner}' overlap ".
				"- a tile would be addressed twice");
			return 0;
		}
	}
	return 1;
}


#---------------------------------------------
# the file
#---------------------------------------------

sub writeRct
	# Write one region as one .rct file.
	#
	# opts: zmax    a hard cap from the build     (default none)
	#       source  the tile source to read       (required)
	#
	# Returns a stats hash, or undef on failure.
{
	my ($reg,$source,$path,$opts) = @_;
	$opts ||= {};

	return _err("writeRct: no region")   if !$reg;
	return _err("writeRct: no source")   if !$source;

	my $name = rctCardName($reg->{id});
	return _err("writeRct: region id '$reg->{id}' is not a usable 8.3 stem ".
		"- at most 8 characters, [A-Za-z0-9] only") if !$name;

	display($dbg_rct,0,"writeRct($reg->{id}) -> $path");

	my ($cov,$nodes) = regionCoverageNodes($reg,{ zmax => $opts->{zmax} });
	my $by_zoom = _planBlocks($nodes);

	my @zooms = sort { $a <=> $b } keys %$by_zoom;
	return _err("writeRct: '$reg->{id}' has no coverage at all") if !@zooms;

	my $zoom_min = $zooms[0];
	my $zoom_max = $zooms[-1];

	# The zoom directory is CONTIGUOUS from zoom_min to zoom_max -- the
	# count is derived, not stored, so a gap cannot be expressed.  A gap
	# would also strand the levels above it: overzoom climbs one level at
	# a time and would fall through.

	for my $z ($zoom_min..$zoom_max)
	{
		return _err("writeRct: '$reg->{id}' has no tiles at z$z, inside its ".
			"own z$zoom_min-$zoom_max range - the pyramid would have a hole ".
			"that overzoom cannot climb through")
			if !$by_zoom->{$z};
		return undef if !_checkDisjoint($z,$by_zoom->{$z},"writeRct '$reg->{id}'");
	}

	# ---- collect the tile bytes, and learn which cells are really there

	my $stats = { tiles => 0, absent => 0, bytes => 0, blocks => 0,
				  zooms => {} };
	my @blobs;			# [ \$data ] in write order
	my $blob_bytes = 0;

	for my $z ($zoom_min..$zoom_max)
	{
		my $zt = 0;
		my $za = 0;
		for my $blk (@{$by_zoom->{$z}})
		{
			$blk->{cells} = {};

			# ROW-MAJOR, and not merely for tidiness.  Perl's hash order
			# is randomised per process, so iterating the keys would place
			# the blobs differently on every build - two builds of the
			# same region would differ in tens of megabytes and could not
			# be diffed.  Sorting also stores tiles that are read together
			# next to each other, which is what a viewport asks the card
			# for.

			for my $key (sort { my ($ax,$ay) = split(/_/,$a);
								my ($bx,$by) = split(/_/,$b);
								$ay <=> $by || $ax <=> $bx }
						 keys %{$blk->{keys}})
			{
				my ($x,$y) = split(/_/,$key);
				my $got = cacheGet($source,$z,$x,$y);

				if (!$got || $got->{status} ne 'ok')
				{
					$za++;
					next;
				}
				push @blobs,$got->{bytes};
				$blk->{cells}{$key} = {
					index	=> $#blobs,
					length	=> length(${$got->{bytes}}),
				};
				$blob_bytes += length(${$got->{bytes}});
				$zt++;
			}
			$stats->{blocks}++;
		}
		$stats->{zooms}{$z} = { tiles => $zt, absent => $za,
								blocks => scalar(@{$by_zoom->{$z}}) };
		$stats->{tiles}  += $zt;
		$stats->{absent} += $za;
		display($dbg_rct,1,sprintf("z%-2d %6d tiles %5d absent  %d block(s)",
			$z,$zt,$za,scalar(@{$by_zoom->{$z}})));
	}
	$stats->{bytes} = $blob_bytes;

	# ---- lay the file out.  Every offset is absolute, so the sizes have
	# to be known before a single byte is written.

	my $nz  = $zoom_max - $zoom_min + 1;
	my $off = $HEADER_BYTES + $nz * $ZDIR_ENTRY;

	for my $z ($zoom_min..$zoom_max)
	{
		$by_zoom->{$z}[0]{_zoom_blocks_offset} = $off;
		$off += $BLK_ENTRY * scalar(@{$by_zoom->{$z}});
	}
	for my $z ($zoom_min..$zoom_max)
	{
		for my $blk (@{$by_zoom->{$z}})
		{
			my $cells = $blk->{grid_w} * $blk->{grid_h};
			$blk->{index_offset}  = $off;   $off += $cells * $IDX_ENTRY;
			$blk->{bitmap_offset} = $off;   $off += int(($cells + 7) / 8);
		}
	}

	my @blob_offset;
	for my $i (0..$#blobs)
	{
		$blob_offset[$i] = $off;
		$off += length(${$blobs[$i]});
	}

	# ---- write

	my $fh;
	if (!open($fh,'>',$path))
	{
		error("writeRct: could not open $path: $!");
		return undef;
	}
	binmode $fh;

	print $fh pack('a4 v v v C C C C v V V a32 a8 a48 a16',
		$MAGIC, $FORMAT_VERSION, $HEADER_BYTES, $TILE_SIZE,
		$reg->{zauthor}, 0, $zoom_min, $zoom_max, 0,
		$PROJECTION, 0,
		"\0" x 32,
		"\0" x 8,					# reserved: there is no coded region field
		substr($reg->{name} // '',0,47),
		"\0" x 16);

	for my $z ($zoom_min..$zoom_max)
	{
		print $fh pack('C a3 V V a16 a4',
			$z, "\0" x 3,
			scalar(@{$by_zoom->{$z}}),
			$by_zoom->{$z}[0]{_zoom_blocks_offset},
			"\0" x 16, "\0" x 4);
	}

	for my $z ($zoom_min..$zoom_max)
	{
		for my $blk (@{$by_zoom->{$z}})
		{
			my ($w,undef,undef,$n) = tileBounds($z,$blk->{x_min},$blk->{y_min});
			my (undef,$s,$e,undef) = tileBounds($z,$blk->{x_max},$blk->{y_max});

			print $fh pack('V8 V4',
				$blk->{x_min}, $blk->{x_max}, $blk->{y_min}, $blk->{y_max},
				$blk->{grid_w}, $blk->{grid_h},
				$blk->{index_offset}, $blk->{bitmap_offset},
				_semiEasting($w),  _semiEasting($e),
				_semiNorthing($n), _semiNorthing($s));

			display($dbg_rct+2,2,sprintf("z%-2d %-10s x %d..%d y %d..%d  %dx%d",
				$z,$blk->{owner},$blk->{x_min},$blk->{x_max},
				$blk->{y_min},$blk->{y_max},$blk->{grid_w},$blk->{grid_h}));
		}
	}

	# Dense index and presence bitmap, one pair per block, in the same
	# row-major order.  BIT = 1 MEANS ABSENT.

	for my $z ($zoom_min..$zoom_max)
	{
		for my $blk (@{$by_zoom->{$z}})
		{
			my $cells = $blk->{grid_w} * $blk->{grid_h};
			my $bits  = "\0" x int(($cells + 7) / 8);
			my $index = '';

			for my $row (0..$blk->{grid_h}-1)
			{
				for my $col (0..$blk->{grid_w}-1)
				{
					my $x = $blk->{x_min} + $col;
					my $y = $blk->{y_min} + $row;
					my $cell = $blk->{cells}{"${x}_${y}"};

					if ($cell)
					{
						$index .= pack('V V',
							$blob_offset[$cell->{index}],$cell->{length});
					}
					else
					{
						$index .= pack('V V',0,0);
						my $p = $row * $blk->{grid_w} + $col;
						vec($bits,$p,1) = 1;
					}
				}
			}
			print $fh $index;
			print $fh $bits;
		}
	}

	print $fh ${$_} for @blobs;
	close $fh;

	$stats->{path}     = $path;
	$stats->{name}     = $name;
	$stats->{zoom_min} = $zoom_min;
	$stats->{zoom_max} = $zoom_max;
	$stats->{size}     = -s $path;

	display($dbg_rct,0,sprintf("%s  z%d-%d  %d tiles  %d block(s)  %d bytes",
		$name,$zoom_min,$zoom_max,$stats->{tiles},$stats->{blocks},$stats->{size}));
	return $stats;
}


sub _err
{
	my ($msg) = @_;
	error($msg);
	return undef;
}


1;
