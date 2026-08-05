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
# absent from the file, which the format expresses natively (the miss bit
# is set and the plotter overzooms from a present ancestor).  Filling the
# cache is the build's job and happens before this runs.
#
# ONE BLOCK IS ONE NODE, SO ONE BLOCK HAS ONE SOURCE.  A subregion may
# name a source of its own, so this module is handed the whole tree's
# source map rather than a single source -- but it never needs a per-tile
# lookup, because the block structure already follows the node structure
# exactly.  The map is of RESOLVED SOURCE OBJECTS, keyed by node PATH
# the way dm_region::regionSourceMap reports them: this module does not
# know how to turn a source id into a source, and must not learn, because
# whether a source is installed, may build, and can be carried by THIS
# format are three questions the build answers before it gets here.
#
# ABSENT AND FAILED ARE NOT THE SAME MISSING TILE, even though the file
# cannot tell them apart.  A cached '.none' marker is the source asserting
# it has no such tile, which is a fact about the ground and correct to
# ship.  Nothing on disk at all means the fetch never succeeded, which is
# a hole that should not have been there.  Both set the miss bit and both
# overzoom; only the second one is a defect, so they are counted apart and
# the build refuses on the second.  See docs/design/build.md.
#
# BLOCKS ARE FEW AND LARGE, deliberately.  The firmware builds its reveal
# aperture as a list of screen rectangles, closing a run at every block
# edge as well as at every absent cell, out of a budget shared across the
# whole chartset.  Fragmenting a zoom spends that budget on seams rather than
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
use dm_image;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		writeRct
		rctFileName
		rctCanCarry
		rctCanConvert
		rctFormats
		rctFileInfo
		rctScanFolder
		rctLastError
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

# How many failed tiles to NAME rather than merely count.  A source that
# went away fails every tile in a region, and a list of nine thousand of
# them is not more useful than a list of twenty and a total -- it is just
# slower to produce and impossible to read.

my $MAX_FAILED_LISTED = 100;

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


#---------------------------------------------
# what this format can carry
#---------------------------------------------
# THE FORMAT'S OWN KNOWLEDGE, asked by the build before it spends an hour
# and again per tile while it writes.  It lives here because "what can an
# .rct hold" is a fact about .rct files, and the day a second exporter
# arrives it will answer for itself rather than the build carrying a table
# of everybody's formats.
#
# This is a whitelist and not a blacklist on purpose.  A format nobody has
# considered is refused rather than shipped, because the failure it
# produces is a file that builds, reports success, and is blank on the
# water.
#
# Format conversion has since arrived, and this is now the place a format
# that still cannot be carried is refused, rather than the place every
# non-JPEG is refused.

# WHY THE LAST WRITE FAILED, kept because an exporter answers with undef
# and undef carries no reason.  The build turns that into "could not be
# written", which is true of every failure here and useful for none of
# them: the sentence somebody actually needs - which source, which tile,
# what was wrong with its bytes - is the one _err composes and would
# otherwise throw away into the log.
#
# RECORDED RATHER THAN RETURNED, because every failure path in this module
# is a bare 'return undef' and threading a reason back through all of them
# would be a much larger change than the problem is worth.
#
# ONE COPY PER THREAD, which is what makes it safe.  A build runs on a
# worker, and a file-scoped 'my' is copied into each thread rather than
# shared, so two builds can never read each other's reason.

my $last_error = '';


sub rctLastError
{
	return $last_error;
}


my @CARRIED = qw( jpeg );


# WHAT IT CANNOT HOLD BUT CAN TAKE IN.  A png is decoded and written back
# out as jpeg on the way into the file, which is an encoder and not the
# image-processing stack this application refuses: same 256 pixels, same
# ground, a container the plotter can read.
#
# IT IS A SEPARATE LIST FROM @CARRIED ON PURPOSE.  What the container
# holds is a fact about the .rct format and never changes; what can be
# converted into it is a fact about what this INSTALLATION can decode, and
# is false on a machine with no GD at all.  Folding them into one list
# would make "an .rct holds jpeg" depend on which libraries are present.

my @CONVERTED = qw( png );


sub rctFormats
{
	return @CARRIED;
}


sub rctCanCarry
{
	my ($fmt) = @_;
	return 0 if !defined($fmt);
	return scalar(grep { $_ eq $fmt } @CARRIED);
}


sub rctCanConvert
	# Whether a tile in $fmt can be turned into something this format
	# carries, HERE, on this machine.  A format nobody has considered is
	# refused, and so is every format when there is no decoder installed -
	# which is a supported configuration and not an error.
{
	my ($fmt) = @_;
	return 0 if !defined($fmt);
	return 0 if !grep { $_ eq $fmt } @CONVERTED;
	return imageCan() ? 1 : 0;
}


sub rctFileName
	# The 8.3 short name the file carries.  The stem is the region id and
	# nothing else -- see docs/design/rct.md on why this is asserted here
	# rather than trusted.
{
	my ($id) = @_;
	return undef if !defined($id) || $id !~ /^[A-Za-z0-9]{1,8}$/;
	return "$id.rct";
}


#---------------------------------------------
# the attribution blob
#---------------------------------------------
# Free-form credit text for the imagery in ONE file, located by
# attrib_offset (0x38) and attrib_length (0x3C) and written at the very
# end, after the tile data.  Normative spec:
# Pub/Ray/docs/e80_firmware/deployment/raster_chart_format.md.
#
# PER FILE, NOT PER CHARTSET, and that is the one place it differs from
# zauthor and zmin.  Those are properties of the chartset because the
# firmware fuses every .rct into one pyramid; a credit is a property of
# the imagery in this region, and a region may legitimately be built from
# a different source than the one beside it.  So each file carries its
# own and a consumer collects the distinct strings across the set.
#
# 0/0 MEANS NO ATTRIBUTION, which is also exactly what a file written
# before the field existed reads as -- 0x38 was reserved-zero.  That
# indistinguishability is deliberate and is why nothing needs a version
# bump.

my $ATTRIB_MAX_LINE = 200;
	# Not a format limit -- the blob is unbounded.  It is a sanity clamp on
	# a string that came out of somebody's .tsd file.


sub _asciify
	# 7-BIT ASCII OR NOTHING.  The eventual consumer is a firmware font
	# renderer, so the encoding question is settled by the producer rather
	# than left to it: bytes 0x20-0x7E plus 0x0A, and nothing else.
	#
	# TRANSLITERATED RATHER THAN STRIPPED, because dropping is worse than
	# it looks -- a stripped copyright sign leaves "Imagery  Google" and a
	# stripped accent turns "Jose" into "Jos".  A credit line is the one
	# piece of text in a file that somebody may have a legal interest in
	# being legible.
{
	my ($text) = @_;
	return '' if !defined($text) || $text !~ /\S/;

	# The symbols worth spelling out.  Written as escapes because no
	# source file in this tree carries a byte above 0x7F.

	$text =~ s/\x{00A9}/(c)/g;
	$text =~ s/\x{00AE}/(r)/g;
	$text =~ s/\x{2122}/(tm)/g;
	$text =~ s/\x{00B0}/ deg/g;
	$text =~ s/[\x{2018}\x{2019}]/'/g;
	$text =~ s/[\x{201C}\x{201D}]/"/g;
	$text =~ s/[\x{2013}\x{2014}]/-/g;
	$text =~ s/\x{2026}/.../g;

	# Latin-1 letters to their unaccented forms.

	$text =~ tr/\x{00C0}-\x{00C5}\x{00C7}\x{00C8}-\x{00CB}\x{00CC}-\x{00CF}\x{00D1}\x{00D2}-\x{00D6}\x{00D9}-\x{00DC}\x{00DD}/AAAAAACEEEEIIIINOOOOOUUUUY/;
	$text =~ tr/\x{00E0}-\x{00E5}\x{00E7}\x{00E8}-\x{00EB}\x{00EC}-\x{00EF}\x{00F1}\x{00F2}-\x{00F6}\x{00F9}-\x{00FC}\x{00FD}\x{00FF}/aaaaaaceeeeiiiinooooouuuuyy/;

	# Line endings to a single LF, tabs to a space, and then anything
	# still outside the permitted set simply goes.

	$text =~ s/\r\n?/\n/g;
	$text =~ s/\t/ /g;
	$text =~ s/[^\x20-\x7E\n]//g;

	my @lines;
	for my $line (split(/\n/,$text))
	{
		$line =~ s/\s+/ /g;
		$line =~ s/^\s+|\s+$//g;
		next if $line !~ /\S/;
		$line = substr($line,0,$ATTRIB_MAX_LINE);
		push @lines,$line;
	}
	return join("\n",@lines);
}


sub _attributionFor
	# The distinct credits of the sources this file's tiles actually came
	# from, in walk order - the region's own first, then its subregions'.
	#
	# DEDUPLICATED, because the common case is a region and its detail
	# boxes all built from one source, and repeating one credit three
	# times would be noise on a small display.
{
	my ($nodes,$sources) = @_;
	my (@out,%seen);

	for my $node (@$nodes)
	{
		my $src = $sources->{$node->{path}} or next;
		my $text = _asciify($src->{attribution});
		next if !length($text);
		next if $seen{$text}++;
		push @out,$text;
	}
	return join("\n",@out);
}


#---------------------------------------------
# reading a file back
#---------------------------------------------

sub rctFileInfo
	# What one .rct on disk says about itself, from its first 24 bytes.
	#
	# THE FILE IS A BETTER WITNESS THAN THE SET, which is the whole reason
	# this exists.  "Every .rct in one folder must agree on zauthor and zmin"
	# is a statement about a FOLDER, and a folder can hold files built at
	# different times from different sets or from a region since renamed.
	# Asking the region files answers a question about what would be built
	# now; asking the files answers the question the firmware will ask.
	#
	# 128 bytes per file and no seeking, so a folder of them costs
	# nothing to survey.
{
	my ($path) = @_;
	return undef if !-f $path;

	my $fh;
	return undef if !open($fh,'<',$path);
	binmode $fh;
	my $got = read($fh,my $head,64);
	if (!$got || $got < 64)
	{
		close $fh;
		return undef;
	}

	my ($magic,$ver,$hbytes,$tsize,$zauthor,undef,$zmin,$zmax,undef,
		$proj,$flags,undef,$aoff,$alen)
		= unpack('a4 v v v C C C C v V V a32 V V',$head);

	if ($magic ne $MAGIC)
	{
		close $fh;
		return undef;
	}

	# THE CREDIT IS READ BACK BECAUSE THE FILE IS ALREADY OPEN.  A folder
	# survey opens every file anyway, so knowing what each one credits
	# costs one seek - and "what does this chartset say it is made from"
	# is a question only the files can answer once they have been copied
	# onto a card and the set that built them is elsewhere.
	#
	# CLAMPED, because attrib_length is a file-supplied u32 and must never
	# reach an allocator unchecked.  A corrupt or truncated file fails to
	# a blank credit, which is always correct.

	my $attrib = '';
	if ($aoff && $alen && $alen <= 65536 && $aoff + $alen <= (-s $path))
	{
		seek($fh,$aoff,0);
		read($fh,$attrib,$alen);
		$attrib = '' if $attrib =~ /[^\x20-\x7E\n]/;
	}
	close $fh;

	my $leaf = $path;
	$leaf =~ s{^.*[/\\]}{};

	return {
		path		=> $path,
		leaf		=> $leaf,
		stem		=> ($leaf =~ /^(.*)\.[^.]*$/ ? $1 : $leaf),
		version		=> $ver,
		zauthor		=> $zauthor,
		zoom_min	=> $zmin,
		zoom_max	=> $zmax,
		attribution	=> $attrib,
		bytes		=> -s $path,
	};
}


sub rctScanFolder
	# Every readable .rct in one folder, by lower-cased stem.  Files that
	# are not .rct files are skipped rather than reported: a folder the user
	# nominated is theirs and may hold anything.
{
	my ($dir) = @_;
	my %out;
	return \%out if !$dir || !-d $dir;

	my $dh;
	return \%out if !opendir($dh,$dir);
	my @leaves = sort grep { /\.rct$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	for my $leaf (@leaves)
	{
		my $info = rctFileInfo("$dir/$leaf") or next;
		$out{lc($info->{stem})} = $info;
	}
	return \%out;
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
	#
	# THE SOURCE RIDES ON THE BLOCK, and that is the whole of per-node
	# sources in this exporter.  Because a block is exactly one node's
	# tiles at one zoom, the source a cell is read from is a property of
	# the block rather than of the cell -- so a subregion built from a
	# different source than its parent costs one field here and no lookup
	# in the loop that runs nine thousand times.
	#
	# Keyed by the node's PATH, because nothing shorter identifies a node:
	# an id is unique only within its region, and depth+id was not unique
	# even there.  See dm_region::regionSourceMap.
{
	my ($nodes,$sources) = @_;
	my %by_zoom;

	for my $node (@$nodes)
	{
		my $src = $sources->{$node->{path}};
		for my $z (sort { $a <=> $b } keys %{$node->{levels}})
		{
			my $blk = _blockOf($z,$node->{levels}{$z});
			next if !$blk;
			$blk->{owner}  = $node->{id};
			$blk->{source} = $src;
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
	# $sources is the RESOLVED source map for this region's whole tree --
	# { "<node path>" => source object } -- as dm_region::regionSourceMap
	# produces it and the build validates it.  See the header on why this
	# is a map rather than a source, and why the objects arrive already
	# resolved.
	#
	# opts: zmax    a hard cap from the build     (default none)
	#
	# Returns a stats hash, or undef on failure.
{
	my ($reg,$sources,$path,$opts) = @_;
	$opts ||= {};
	$last_error = '';

	return _err("writeRct: no region")      if !$reg;
	return _err("writeRct: no source map")  if !$sources || !%$sources;

	my $name = rctFileName($reg->{id});
	return _err("writeRct: region id '$reg->{id}' is not a usable 8.3 stem ".
		"- at most 8 characters, [A-Za-z0-9] only") if !$name;

	display($dbg_rct,0,"writeRct($reg->{id}) -> $path");

	my ($cov,$nodes) = regionCoverageNodes($reg,{ zmax => $opts->{zmax} });
	my $by_zoom = _planBlocks($nodes,$sources);

	# A NODE WITH NO SOURCE IS A BUILD ERROR THAT GOT THIS FAR.  The build
	# resolves and validates every node's source before any of this runs,
	# so reaching here means the map and the tree disagree -- which would
	# otherwise show up as a whole subregion silently absent from the file.

	for my $z (keys %$by_zoom)
	{
		for my $blk (@{$by_zoom->{$z}})
		{
			return _err("writeRct: '$reg->{id}' node '$blk->{owner}' has no ".
				"resolved source - the source map does not match the region ".
				"tree") if !$blk->{source};
		}
	}

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

	my $stats = { tiles => 0, absent => 0, failed => 0, converted => 0,
				  bytes => 0, blocks => 0, zooms => {}, failed_tiles => [] };
	my @blobs;			# [ \$data ] in write order
	my $blob_bytes = 0;

	# WHAT A CONVERTED TILE IS WRITTEN AT, resolved by the caller and passed
	# in rather than read here.  This runs on a worker thread and the
	# exporter has no business learning about the preferences system to get
	# one integer; dm_image clamps it, so an absent or silly value is safe.

	my $quality = $opts->{quality};

	for my $z ($zoom_min..$zoom_max)
	{
		my $zt = 0;
		my $za = 0;
		my $zf = 0;
		my $zc = 0;
		for my $blk (@{$by_zoom->{$z}})
		{
			$blk->{cells} = {};

			# ROW-MAJOR, and not merely for tidiness.  Perl's hash order
			# is randomised per process, so iterating the keys would place
			# the blobs differently on every build - two builds of the
			# same region would differ in tens of megabytes and could not
			# be diffed.  Sorting also stores tiles that are read together
			# next to each other, which is what a viewport asks the file
			# for.

			for my $key (sort { my ($ax,$ay) = split(/_/,$a);
								my ($bx,$by) = split(/_/,$b);
								$ay <=> $by || $ax <=> $bx }
						 keys %{$blk->{keys}})
			{
				my ($x,$y) = split(/_/,$key);
				my $got = cacheGet($blk->{source},$z,$x,$y);

				# NOTHING ON DISK is not the same answer as a cached
				# absence.  The file writes the same miss bit for both, so
				# this is the last moment the difference exists at all.

				if (!$got)
				{
					$zf++;
					push @{$stats->{failed_tiles}},
						"$blk->{source}{id} $z/$x/$y"
						if @{$stats->{failed_tiles}} < $MAX_FAILED_LISTED;
					next;
				}
				if ($got->{status} ne 'ok')
				{
					$za++;
					next;
				}

				# THE DECLARATION IS NOT THE EVIDENCE, and this is the line
				# where that stops being a principle and starts being the
				# code.  dm_cache records the format DETECTED FROM THE
				# BYTES at fetch time, so what the .tsd claimed does not
				# come into it: a source that declares jpeg and serves png
				# and a source that honestly declares png are the same case
				# here, and both are settled by one string compare.
				#
				# AND THIS IS WHERE AN IMAGE FINALLY ENTERS THIS PROCESS.
				# It did not before, and the sentence saying so was true
				# and worth keeping right up until the day a file could be
				# built from a png source at all.  What enters is one tile,
				# decoded and written straight back out as jpeg.  Nothing
				# is resampled, reprojected or composited - the image
				# stack this application refuses is still refused - and
				# THE CACHE IS NOT TOUCHED.  The cache holds what the
				# service sent; the format an .rct needs is a property of
				# the format, so the conversion lives at this seam and
				# nowhere earlier.

				my $bytes = $got->{bytes};
				if (!rctCanCarry($got->{format}))
				{
					my $conv = rctCanConvert($got->{format}) ?
						imageToJpeg($bytes,$quality) : undef;
					if (!$conv)
					{
						return _err("writeRct: '$reg->{id}' - source ".
							"'$blk->{source}{id}' served $got->{format} at ".
							"$z/$x/$y, which an RCT cannot carry".
							(rctCanConvert($got->{format}) ?
								" and which would not decode" :
							 imageCan() ?
								" and cannot be converted" :
								" and cannot be converted, because no image ".
								"decoder is installed").
							" - the file would be structurally valid and ".
							"blank on the plotter");
					}
					$bytes = $conv;
					$zc++;
				}

				push @blobs,$bytes;
				$blk->{cells}{$key} = {
					index	=> $#blobs,
					length	=> length($$bytes),
				};
				$blob_bytes += length($$bytes);
				$zt++;
			}
			$stats->{blocks}++;
		}
		$stats->{zooms}{$z} = { tiles => $zt, absent => $za, failed => $zf,
								converted => $zc,
								blocks => scalar(@{$by_zoom->{$z}}) };
		$stats->{tiles}     += $zt;
		$stats->{absent}    += $za;
		$stats->{failed}    += $zf;
		$stats->{converted} += $zc;
		display($dbg_rct,1,sprintf("z%-2d %6d tiles %5d absent %5d failed  %d block(s)%s",
			$z,$zt,$za,$zf,scalar(@{$by_zoom->{$z}}),
			$zc ? sprintf("  %d converted",$zc) : ''));
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

	# THE ATTRIBUTION BLOB IS LAST, after the tile data, and that position
	# is why it costs nothing.  Variable-length data anywhere earlier would
	# move the zoom directory, whose position is a compiled-in constant in
	# the consumer - so putting it at the end means NOTHING ELSE IN THE
	# LAYOUT MOVES: every existing offset stays valid, a reader built
	# before the field ignores it, and one built after reads an older file
	# as "no attribution".

	my $attrib = _attributionFor($nodes,$sources);
	my $attrib_offset = length($attrib) ? $off : 0;
	my $attrib_length = length($attrib);
	$stats->{attribution} = $attrib;

	# ---- write
	#
	# THROUGH A TEMP FILE AND A RENAME, for the reason dm_cache writes
	# tiles the same way: a file is written over many seconds and a
	# cancel, a crash or a full disk in the middle of it would otherwise
	# leave a .rct that looks complete and is a fragment.  The plotter
	# would read the header, believe the zoom directory, and follow
	# offsets into a file that stops early.  The rename is the moment the
	# file exists, and nothing before it is visible under the real name.

	my $tmp = "$path.tmp";
	my $fh;
	if (!open($fh,'>',$tmp))
	{
		error("writeRct: could not open $tmp: $!");
		return undef;
	}
	binmode $fh;

	print $fh pack('a4 v v v C C C C v V V a32 V V a48 a16',
		$MAGIC, $FORMAT_VERSION, $HEADER_BYTES, $TILE_SIZE,
		$reg->{zauthor}, 0, $zoom_min, $zoom_max, 0,
		$PROJECTION, 0,
		"\0" x 32,
		$attrib_offset,				# 0x38
		$attrib_length,				# 0x3C
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

	# NOT NUL TERMINATED AND NOT PADDED - attrib_length counts text bytes
	# exactly, so a consumer wanting a C string allocates length+1 and
	# terminates it itself.  Correctness never depends on the producer
	# having written a terminator.

	print $fh $attrib if $attrib_length;

	if (!close($fh))
	{
		error("writeRct: could not finish writing $tmp: $!");
		unlink($tmp);
		return undef;
	}

	# Windows rename() will not replace an existing file, so the previous
	# file has to go first.  The window between the two is the one moment
	# a rebuild is destructive, and it is as short as it can be made.

	unlink($path) if -e $path;
	if (!rename($tmp,$path))
	{
		error("writeRct: could not rename $tmp to $path: $!");
		unlink($tmp);
		return undef;
	}

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
	$last_error = $msg;
	error($msg);
	return undef;
}


1;
