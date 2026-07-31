#!/usr/bin/perl
#---------------------------------------------
# dm_mbtiles.pm
#---------------------------------------------
# The MBTiles exporter -- one folder per region, one .mbtiles file per
# NODE inside it.  See docs/design/mbtiles.md.
#
# THE BOUNDARY IS THE COVERAGE ENUMERATOR PLUS THE CACHE, exactly as it is
# for dm_rct.  The two exporters are peers over that boundary and neither
# reads the other's output: an mbtiles is not an intermediate.
#
# NOTHING IS FETCHED HERE.  A tile the cache does not hold is simply not a
# row.  Filling the cache is the build's job and happens before this runs.
#
# ONE FILE PER NODE, AND THAT IS THE WHOLE DESIGN.  MBTiles carries ONE
# minzoom and ONE maxzoom for a whole file, and OpenCPN derives the chart's
# scale from the maximum.  So a region whose coverage is z10-16 everywhere
# except a one-square-mile detail box at z20 would, as a single file,
# announce itself as a z20 chart across its entire extent -- and be
# preferred by chart selection at scales where it holds nothing but
# magnified z16.  RCT does not have this problem because depth is carried
# per coverage block, which is to say SPATIALLY.  MBTiles has nowhere to
# put that, so the split has to happen in the filesystem instead: each node
# becomes its own chart, internally uniform in depth, and the reader's
# scale-based selection is then working from something true.
#
# It also settles the encoding question for free.  A file has one 'format'
# and a node has one source, so the declared format is always the format of
# every tile in the file.  A per-region file spanning two sources could not
# have said anything honest there.
#
# NAMED BY THE NODE'S ID, inside a folder named for the region.  That is
# safe because an id is unique within its whole region (dm_region's
# validator), so no two files in one folder can collide -- and the region
# folder keeps two regions' identically named detail boxes apart.  The full
# path is therefore the node's path, which is also how the source map keys
# it.
#
# SPARSE BY DESIGN.  Coverage is polygon-derived and never rectangular, so
# these files are partially populated at every zoom.  A reader that assumes
# a full rectangle is wrong about this format generally, not about us.
#
# NO BYTE-REPRODUCIBILITY CLAIM, unlike an .rct.  Rows are inserted in
# row-major order so the CONTENT is deterministic, but a SQLite file
# carries page allocation state and two builds are not promised to be
# identical byte for byte.  The RCT invariant does not transfer, and
# pretending it did would be a claim nobody had tested.

package dm_mbtiles;
use strict;
use warnings;
use DBI qw( :sql_types );
use Pub::Utils;
use cm_defs;
use dm_cache;
use dm_coverage;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		writeMbtiles
		mbtilesCanCarry
		mbtilesFormats
		mbtilesNodeName
		mbtilesInfo
	);
}


our $dbg_mbt:shared = 0;
	# 0  = one line per region and per file
	# -1 = one line per zoom within a file
	# -2 = per tile


my $MAX_FAILED_LISTED = 100;
	# The same clamp dm_rct uses, for the same reason: a source that went
	# away fails every tile, and a list of nine thousand is not more useful
	# than twenty and a total.


#---------------------------------------------
# what this format can carry
#---------------------------------------------
# A WHITELIST, like dm_rct's, and for the same reason -- a format nobody
# has considered is refused rather than shipped.  It is a longer list here
# because MBTiles genuinely holds both: the tiles table is a blob and the
# metadata says what the blobs are.  Nothing is transcoded.

my %CARRIED = (
	jpeg	=> 'jpg',
	png		=> 'png',
);


sub mbtilesFormats
{
	return sort keys %CARRIED;
}


sub mbtilesCanCarry
{
	my ($fmt) = @_;
	return 0 if !defined($fmt);
	return $CARRIED{$fmt} ? 1 : 0;
}


sub mbtilesNodeName
	# The leaf a node is written as.  An id is already [A-Za-z0-9] by
	# validation, and this asserts it rather than trusting it, because the
	# value is about to become a path.
{
	my ($id) = @_;
	return undef if !defined($id) || $id !~ /^[A-Za-z0-9]+$/;
	return "$id.mbtiles";
}


#---------------------------------------------
# reading one back
#---------------------------------------------

sub mbtilesInfo
	# What one .mbtiles on disk says about itself: its metadata table and
	# its actual row count.  Used by the tests and by anything that wants
	# to survey a folder without trusting what wrote it.
{
	my ($path) = @_;
	return undef if !-f $path;

	my $dbh = DBI->connect("dbi:SQLite:dbname=$path",'','',
		{ RaiseError => 0, PrintError => 0, AutoCommit => 1 });
	return undef if !$dbh;

	my %meta;
	my $rows = $dbh->selectall_arrayref("SELECT name,value FROM metadata");
	if ($rows)
	{
		$meta{$_->[0]} = $_->[1] for @$rows;
	}

	my ($tiles) = $dbh->selectrow_array("SELECT COUNT(*) FROM tiles");
	my ($zmin,$zmax) = $dbh->selectrow_array(
		"SELECT MIN(zoom_level),MAX(zoom_level) FROM tiles");
	$dbh->disconnect();

	my $leaf = $path;
	$leaf =~ s{^.*[/\\]}{};

	return {
		path		=> $path,
		leaf		=> $leaf,
		stem		=> ($leaf =~ /^(.*)\.[^.]*$/ ? $1 : $leaf),
		metadata	=> \%meta,
		tiles		=> $tiles || 0,
		zoom_min	=> $zmin,
		zoom_max	=> $zmax,
		bytes		=> -s $path,
	};
}


#---------------------------------------------
# one node, one file
#---------------------------------------------

sub _bounds
	# west,south,east,north over every tile in this node, at every level it
	# holds.
	#
	# THE UNION, NOT THE DEEPEST LEVEL.  A coarse tile covers more ground
	# than the polygon that produced it, and it is really in the file -- so
	# bounds that described only the finest level would be a claim the file
	# itself contradicts, and a reader clipping to it would drop imagery it
	# had been given.
{
	my ($levels) = @_;
	my ($w,$s,$e,$n);

	for my $z (keys %$levels)
	{
		for my $key (keys %{$levels->{$z}})
		{
			my ($x,$y) = split(/_/,$key);
			my ($tw,$ts,$te,$tn) = tileBounds($z,$x,$y);
			$w = $tw if !defined($w) || $tw < $w;
			$s = $ts if !defined($s) || $ts < $s;
			$e = $te if !defined($e) || $te > $e;
			$n = $tn if !defined($n) || $tn > $n;
		}
	}
	return (defined($w) ? ($w,$s,$e,$n) : ());
}


sub _writeNode
	# One node as one .mbtiles.  Returns a stats hash, or undef.
{
	my ($node,$src,$path,$region_name) = @_;

	my @zooms = sort { $a <=> $b } keys %{$node->{levels}};
	return _err("_writeNode: '$node->{path}' has no coverage") if !@zooms;

	my $zoom_min = $zooms[0];
	my $zoom_max = $zooms[-1];

	my $stats = { tiles => 0, absent => 0, failed => 0, bytes => 0,
				  failed_tiles => [], zooms => {} };

	# ---- collect the bytes first, so a refusal costs no file at all.
	#
	# The whole node is held in memory before the database is opened.  That
	# is a real cost -- a z20 detail box is tens of megabytes -- and it buys
	# the property that a format refusal, which can only be discovered per
	# tile, never leaves a half-written database behind.  dm_rct makes the
	# same trade for the same reason.

	my @rows;
	for my $z (@zooms)
	{
		my ($zt,$za,$zf) = (0,0,0);

		# ROW-MAJOR, so rows land in the order a viewport reads them and
		# two builds of the same node insert identically.  Perl's hash
		# order is randomised per process; iterating the keys would make
		# the insert sequence differ every run for no reason.

		for my $key (sort { my ($ax,$ay) = split(/_/,$a);
							my ($bx,$by) = split(/_/,$b);
							$ay <=> $by || $ax <=> $bx }
					 keys %{$node->{levels}{$z}})
		{
			my ($x,$y) = split(/_/,$key);
			my $got = cacheGet($src,$z,$x,$y);

			# NOTHING ON DISK is not the same answer as a cached absence.
			# Neither becomes a row, so this file cannot tell them apart
			# either -- but the build's ledger can, and only one of them is
			# a defect.

			if (!$got)
			{
				$zf++;
				push @{$stats->{failed_tiles}},"$src->{id} $z/$x/$y"
					if @{$stats->{failed_tiles}} < $MAX_FAILED_LISTED;
				next;
			}
			if ($got->{status} ne 'ok')
			{
				$za++;
				next;
			}

			# THE DECLARATION IS NOT THE EVIDENCE.  dm_cache records the
			# format sniffed from the bytes at fetch time, so a source that
			# declares jpeg and serves png is caught here for the price of
			# a string compare -- and this format's metadata would then be
			# lying to every reader about every tile in the file.
			#
			# No image is decoded.  This reads a fact the cache already
			# established.

			if (!mbtilesCanCarry($got->{format}))
			{
				return _err("_writeNode: '$node->{path}' - source ".
					"'$src->{id}' served $got->{format} at $z/$x/$y, which ".
					"an mbtiles cannot carry");
			}
			if ($got->{format} ne $src->{tile_format})
			{
				return _err("_writeNode: '$node->{path}' - source ".
					"'$src->{id}' declares $src->{tile_format} and served ".
					"$got->{format} at $z/$x/$y - one file has one format, ".
					"so the metadata would describe only some of its tiles");
			}

			# TMS COUNTS ROWS FROM THE SOUTH and every source chartMaker
			# reads counts them from the north.  This one line is the whole
			# of that difference, and getting it wrong produces a file that
			# is structurally perfect and vertically mirrored.

			push @rows,[ $z, $x, ((1 << $z) - 1 - $y), $got->{bytes} ];
			$stats->{bytes} += length(${$got->{bytes}});
			$zt++;
		}

		$stats->{zooms}{$z} = { tiles => $zt, absent => $za, failed => $zf };
		$stats->{tiles}  += $zt;
		$stats->{absent} += $za;
		$stats->{failed} += $zf;
		display($dbg_mbt-1,2,sprintf("z%-2d %6d tiles %5d absent %5d failed",
			$z,$zt,$za,$zf));
	}

	# ---- write it.
	#
	# THROUGH A TEMP FILE AND A RENAME, for the reason dm_rct and dm_cache
	# both do: a crash or a full disk in the middle would otherwise leave a
	# file that opens, answers queries, and is missing most of its imagery.
	# The rename is the moment the chart exists.

	my $tmp = "$path.tmp";
	unlink($tmp) if -e $tmp;

	my $dbh = DBI->connect("dbi:SQLite:dbname=$tmp",'','',
		{ RaiseError => 0, PrintError => 0, AutoCommit => 1 });
	return _err("_writeNode: could not create $tmp: ".($DBI::errstr // ''))
		if !$dbh;

	# A build is not a durable transaction log.  If this dies halfway the
	# temp file is discarded and the whole thing runs again, so paying for
	# journalling per insert buys nothing and costs most of the wall clock.

	$dbh->do("PRAGMA journal_mode = OFF");
	$dbh->do("PRAGMA synchronous = OFF");

	# The MBTiles 1.3 schema, exactly.  No extra tables and no extra
	# columns: a chartMaker-specific field in a standard container is how a
	# format stops being the standard one.

	my $ok = 1;
	$ok &&= $dbh->do("CREATE TABLE metadata (name text, value text)");
	$ok &&= $dbh->do("CREATE TABLE tiles (zoom_level integer, ".
		"tile_column integer, tile_row integer, tile_data blob)");
	$ok &&= $dbh->do("CREATE UNIQUE INDEX name ON metadata (name)");
	$ok &&= $dbh->do("CREATE UNIQUE INDEX tile_index ON tiles ".
		"(zoom_level, tile_column, tile_row)");

	if (!$ok)
	{
		my $err = $DBI::errstr // '';
		$dbh->disconnect();
		unlink($tmp);
		return _err("_writeNode: could not create the schema in $tmp: $err");
	}

	my ($w,$s,$e,$n) = _bounds($node->{levels});
	my $bounds = defined($w) ?
		sprintf("%.6f,%.6f,%.6f,%.6f",$w,$s,$e,$n) : '';
	my $center = defined($w) ?
		sprintf("%.6f,%.6f,%d",($w+$e)/2,($s+$n)/2,$zoom_max) : '';

	# ATTRIBUTION TRAVELS WITH THE TILES, in the metadata key the format
	# already has for it.  An .rct carries the same text in its own blob;
	# neither invents a place to put it.

	my %meta = (
		name		=> $node->{id},
		description	=> ($node->{depth} ?
						"$region_name - $node->{path}" : $region_name),
		type		=> 'baselayer',
		version		=> '1.0.0',
		format		=> $CARRIED{$src->{tile_format}},
		minzoom		=> $zoom_min,
		maxzoom		=> $zoom_max,
		bounds		=> $bounds,
		center		=> $center,
		attribution	=> ($src->{attribution} // ''),
	);

	my $msth = $dbh->prepare("INSERT INTO metadata (name,value) VALUES (?,?)");
	$msth->execute($_,$meta{$_}) for sort keys %meta;

	my $tsth = $dbh->prepare("INSERT INTO tiles ".
		"(zoom_level,tile_column,tile_row,tile_data) VALUES (?,?,?,?)");

	# ONE TRANSACTION FOR THE WHOLE FILE.  Ten thousand autocommitted
	# inserts is ten thousand commits, and the difference is minutes.

	$dbh->begin_work();
	for my $row (@rows)
	{
		$tsth->bind_param(1,$row->[0]);
		$tsth->bind_param(2,$row->[1]);
		$tsth->bind_param(3,$row->[2]);

		# BOUND AS A BLOB EXPLICITLY.  Without the type the driver stores
		# the bytes as text, which corrupts every tile that contains a NUL
		# -- which is every JPEG.

		$tsth->bind_param(4,${$row->[3]},SQL_BLOB);
		if (!$tsth->execute())
		{
			my $err = $DBI::errstr // '';
			$dbh->rollback();
			$dbh->disconnect();
			unlink($tmp);
			return _err("_writeNode: insert failed at ".
				"$row->[0]/$row->[1]/$row->[2]: $err");
		}
	}

	if (!$dbh->commit())
	{
		my $err = $DBI::errstr // '';
		$dbh->disconnect();
		unlink($tmp);
		return _err("_writeNode: could not commit $tmp: $err");
	}
	$dbh->disconnect();

	# Windows rename() will not replace an existing file, so the previous
	# chart has to go first.  The window between the two is the one moment
	# a rebuild is destructive, and it is as short as it can be made.

	unlink($path) if -e $path;
	if (!rename($tmp,$path))
	{
		error("_writeNode: could not rename $tmp to $path: $!");
		unlink($tmp);
		return undef;
	}

	$stats->{path}     = $path;
	$stats->{name}     = $node->{id};
	$stats->{node}     = $node->{path};
	$stats->{zoom_min} = $zoom_min;
	$stats->{zoom_max} = $zoom_max;
	$stats->{size}     = -s $path;
	$stats->{bounds}   = $bounds;

	display($dbg_mbt,1,sprintf("%-20s z%-2d-%-2d %7d tiles %10.2f MB",
		$node->{id},$zoom_min,$zoom_max,$stats->{tiles},
		$stats->{size}/1048576));
	return $stats;
}


#---------------------------------------------
# one region, one folder
#---------------------------------------------

sub writeMbtiles
	# Write one region as a FOLDER of .mbtiles files, one per node.
	#
	# $sources is the RESOLVED source map for this region's whole tree --
	# { "<node path>" => source object } -- as dm_region::regionSourceMap
	# produces it and the build validates it.  Whether a source is
	# installed, may build, and can be carried by this format are three
	# questions the build answers before any of this runs.
	#
	# opts: zmax    a hard cap from the build     (default none)
	#
	# Returns a stats hash for the whole region, or undef on failure.
{
	my ($reg,$sources,$dir,$opts) = @_;
	$opts ||= {};

	return _err("writeMbtiles: no region")     if !$reg;
	return _err("writeMbtiles: no source map") if !$sources || !%$sources;

	return _err("writeMbtiles: region id '".($reg->{id} // '?')."' is not ".
		"usable as a folder name") if !mbtilesNodeName($reg->{id});

	display($dbg_mbt,0,"writeMbtiles($reg->{id}) -> $dir");

	my (undef,$nodes) = regionCoverageNodes($reg,{ zmax => $opts->{zmax} });
	return _err("writeMbtiles: '$reg->{id}' has no coverage at all")
		if !$nodes || !@$nodes;

	# A NODE WITH NO SOURCE IS A BUILD ERROR THAT GOT THIS FAR.  The build
	# resolves and validates every node's source first, so reaching here
	# means the map and the tree disagree -- which would otherwise show up
	# as one detail area silently missing from the chart folder.

	for my $node (@$nodes)
	{
		return _err("writeMbtiles: '$reg->{id}' node '$node->{path}' has no ".
			"resolved source - the source map does not match the region tree")
			if !$sources->{$node->{path}};
		return _err("writeMbtiles: '$reg->{id}' node '$node->{path}' has an ".
			"id that cannot be a file name") if !mbtilesNodeName($node->{id});
	}

	# THE REGION FOLDER IS CREATED, and that is not a violation of the
	# standing rule about folders.  The rule is about locations the user
	# chose: the build refuses an output folder that does not exist and
	# creates only the default one.  Inside a folder that has been settled,
	# the layout is this exporter's own business.

	if (!-d $dir && !mkdir($dir))
	{
		return _err("writeMbtiles: could not create $dir: $!");
	}

	my $stats = { tiles => 0, absent => 0, failed => 0, bytes => 0,
				  blocks => 0, files => [], failed_tiles => [],
				  zoom_min => undef, zoom_max => undef };

	for my $node (@$nodes)
	{
		my $path = "$dir/".mbtilesNodeName($node->{id});
		my $st = _writeNode($node,$sources->{$node->{path}},$path,$reg->{name});
		return undef if !$st;

		push @{$stats->{files}},$st;
		$stats->{tiles}  += $st->{tiles};
		$stats->{absent} += $st->{absent};
		$stats->{failed} += $st->{failed};
		$stats->{bytes}  += $st->{size};
		$stats->{blocks}++;

		push @{$stats->{failed_tiles}},@{$st->{failed_tiles}}
			if @{$stats->{failed_tiles}} < $MAX_FAILED_LISTED;

		$stats->{zoom_min} = $st->{zoom_min}
			if !defined($stats->{zoom_min}) ||
				$st->{zoom_min} < $stats->{zoom_min};
		$stats->{zoom_max} = $st->{zoom_max}
			if !defined($stats->{zoom_max}) ||
				$st->{zoom_max} > $stats->{zoom_max};
	}

	$stats->{path} = $dir;
	$stats->{name} = $reg->{id};
	$stats->{size} = $stats->{bytes};

	display($dbg_mbt,0,sprintf("%s  z%d-%d  %d tiles  %d file(s)  %d bytes",
		$reg->{id},$stats->{zoom_min},$stats->{zoom_max},
		$stats->{tiles},$stats->{blocks},$stats->{size}));
	return $stats;
}


sub _err
{
	my ($msg) = @_;
	error($msg);
	return undef;
}


1;
