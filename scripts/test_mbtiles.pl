#!/usr/bin/perl
#---------------------------------------------
# test_mbtiles.pl -- headless test of dm_mbtiles.pm and the node identity
#---------------------------------------------
# HERMETIC AND OFFLINE.  It builds its own data dir under C:/_temp and
# plants every tile itself, so nothing here touches a network or Patrick's
# data.
#
# TWO SUBJECTS, and they belong in one file because the second exists for
# the first:
#
#	A NODE IS IDENTIFIED BY ITS PATH.  An id is unique within a region and
#	says nothing across them; "<depth>:<id>" was not unique even within one,
#	because two subregions of different parents at the same depth may share
#	an id.  The model now refuses that at load, and every consumer keys by
#	path.  An exporter that writes a file per node depends on both.
#
#	MBTILES IS A PEER OF RCT, not a conversion of it.  One file per node,
#	because the format carries one maxzoom for a whole file and OpenCPN
#	derives the chart scale from it.
#
# What it pins down:
#
#	a duplicate id anywhere in a region is refused at load
#	the source map is keyed by path, and two branches do not collide
#	one .mbtiles per node, named by node id, inside a region folder
#	each file's zoom range is its OWN band - the whole point of the split
#	the TMS row flip, checked against the arithmetic and not against itself
#	tile bytes round trip EXACTLY - the blob binding is not text
#	a png source builds here and is refused for RCT, in the same fixture
#	an absent tile is simply not a row

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use DBI;
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_rct;
use dm_mbtiles;
use dm_build;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/mbt_data";

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_)."\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}


sub rmTree
{
	my ($dir) = @_;
	return if !-d $dir;
	opendir(my $dh,$dir) or return;
	for my $leaf (grep { !/^\.\.?$/ } readdir($dh))
	{
		my $path = "$dir/$leaf";
		-d $path ? rmTree($path) : unlink($path);
	}
	closedir $dh;
	rmdir $dir;
}

sub putFile
{
	my ($path,$text) = @_;
	open(my $fh,'>',$path) or die "cannot write $path: $!";
	print $fh $text;
	close $fh;
}

sub leaves
{
	my ($dir) = @_;
	return () if !-d $dir;
	opendir(my $dh,$dir) or return ();
	my @f = sort grep { !/^\.\.?$/ } readdir($dh);
	closedir $dh;
	return @f;
}

sub tsd
{
	my ($id,$fmt) = @_;
	$fmt ||= 'jpeg';
	my $ext = $fmt eq 'png' ? 'png' : 'jpg';
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "test source $id",
  "url": "https://$id.example.com/{z}/{x}/{y}.$ext",
  "tile_format": "$fmt",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "(c) test $id",
  "uses": ["display","build"],
  "policy": { "max_concurrency": 1, "min_interval_ms": 0 }
}
EOJ
}


#---------------------------------------------
# a region with TWO branches
#---------------------------------------------
# The shape the old key got wrong.  'East' and 'West' are two subregions at
# depth 1; each holds its own child, and BOTH children are at depth 2.  Had
# the two children shared an id, "<depth>:<id>" would have been one entry
# and one of them would have been built from the other's source.  The model
# now refuses that outright, so this fixture gives them distinct ids and the
# refusal is tested separately below.

sub regionJson
{
	my ($id,$dup) = @_;
	my ($lat,$lon) = (9.33,-82.24);
	my $d = 0.20;

	my $box = sub {
		my ($clat,$clon,$half) = @_;
		return "[ [ @{[$clon-$half]}, @{[$clat-$half]} ], ".
			   "[ @{[$clon+$half]}, @{[$clat-$half]} ], ".
			   "[ @{[$clon+$half]}, @{[$clat+$half]} ], ".
			   "[ @{[$clon-$half]}, @{[$clat+$half]} ] ]";
	};

	my $outer = $box->($lat,$lon,$d);
	my $east  = $box->($lat,$lon + $d/2,$d/4);
	my $west  = $box->($lat,$lon - $d/2,$d/4);
	my $ekid  = $box->($lat,$lon + $d/2,$d/8);
	my $wkid  = $box->($lat,$lon - $d/2,$d/8);

	# The two grandchildren: distinct ids normally, the SAME id when the
	# caller is manufacturing the collision.

	my $e_kid_id = 'EastKid';
	my $w_kid_id = $dup ? 'EastKid' : 'WestKid';

	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "two branch $id",
   "zauthor" : 12,
   "zmin" : 11,
   "zmax" : 12,
   "source" : "mbt_a",
   "geometry" : [ $outer ],
   "subregions" : [
      {
         "id" : "East",
         "name" : "east",
         "zmax" : 13,
         "source" : "mbt_b",
         "geometry" : [ $east ],
         "subregions" : [
            {
               "id" : "$e_kid_id",
               "name" : "east kid",
               "zmax" : 14,
               "source" : "inherited",
               "geometry" : [ $ekid ],
               "subregions" : []
            }
         ]
      },
      {
         "id" : "West",
         "name" : "west",
         "zmax" : 13,
         "source" : "mbt_a",
         "geometry" : [ $west ],
         "subregions" : [
            {
               "id" : "$w_kid_id",
               "name" : "west kid",
               "zmax" : 14,
               "source" : "inherited",
               "geometry" : [ $wkid ],
               "subregions" : []
            }
         ]
      }
   ]
}
EOJ
}


rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/mbt_temp";

loadSets();
putFile("$ROOT/sources/mbt_a.tsd",  tsd('mbt_a'));
putFile("$ROOT/sources/mbt_b.tsd",  tsd('mbt_b'));
putFile("$ROOT/sources/mbt_png.tsd",tsd('mbt_png','png'));
dm_source::rescanSources();

newSet('Mbt');
putFile("$ROOT/region_sets/Mbt/Tree.region",regionJson('Tree'));
openSet('Mbt');

my $reg = getRegion('Tree');
ok($reg && $reg->{id} eq 'Tree',"the two-branch fixture loaded");


#---------------------------------------------
# 1 - a node is identified by its path
#---------------------------------------------

my (undef,$nodes) = regionCoverageNodes($reg,{});
my @paths = map { $_->{path} } @$nodes;

ok(scalar(@paths) == 5,"five nodes in the tree (".scalar(@paths).")");
ok((grep { $_ eq 'Tree/East/EastKid' } @paths) &&
   (grep { $_ eq 'Tree/West/WestKid' } @paths),
	"the walk reports full paths, not bare ids");

# THE TWO GRANDCHILDREN ARE AT THE SAME DEPTH.  That is the whole reason
# depth+id was not an identity, said as an assertion rather than as a
# comment, so a walk that stopped nesting would fail here.

my %depth = map { $_->{path} => $_->{depth} } @$nodes;
ok($depth{'Tree/East/EastKid'} == 2 && $depth{'Tree/West/WestKid'} == 2,
	"both grandchildren are at depth 2 - depth+id could not have told ".
	"them apart");

my $srcs = regionSourceMap($reg,'mbt_a');
ok($srcs->{'Tree'} eq 'mbt_a' && $srcs->{'Tree/East'} eq 'mbt_b' &&
   $srcs->{'Tree/West'} eq 'mbt_a',
	"the source map is keyed by path");

# INHERITANCE FOLLOWS THE BRANCH, and this is the assertion the old key
# could not have passed with two identically named children: EastKid
# inherits mbt_b through East, WestKid inherits mbt_a through West.

ok($srcs->{'Tree/East/EastKid'} eq 'mbt_b',
	"a grandchild inherits down ITS OWN branch (east -> mbt_b)");
ok($srcs->{'Tree/West/WestKid'} eq 'mbt_a',
	"and the other branch is unaffected (west -> mbt_a)");


#---------------------------------------------
# 2 - a duplicate id anywhere in the region is refused
#---------------------------------------------
# Written straight into the folder, because this is about what the LOADER
# accepts.  Nothing in the application can create one of these - addSubregion
# has always refused a duplicate anywhere in the tree - so the only way in
# is a file, which is exactly the case the validator now covers.

putFile("$ROOT/region_sets/Mbt/Dup.region",regionJson('Dup',1));
putFile("$ROOT/region_sets/Mbt/Self.region",<<'EOJ');
{
   "region_version" : 1,
   "id" : "Self",
   "name" : "names its own child after itself",
   "zauthor" : 12,
   "zmin" : 11,
   "zmax" : 12,
   "source" : "mbt_a",
   "geometry" : [ [ [ -82.4, 9.2 ], [ -82.2, 9.2 ], [ -82.2, 9.4 ], [ -82.4, 9.4 ] ] ],
   "subregions" : [
      {
         "id" : "Self",
         "name" : "same id as its parent",
         "zmax" : 13,
         "source" : "inherited",
         "geometry" : [ [ [ -82.35, 9.25 ], [ -82.25, 9.25 ], [ -82.25, 9.35 ], [ -82.35, 9.35 ] ] ],
         "subregions" : []
      }
   ]
}
EOJ

openSet('Mbt');
ok(!getRegion('Dup'),
	"two subregions with one id in different branches - the region is refused");
ok(!getRegion('Self'),
	"a subregion sharing its parent's id - refused, one namespace per region");
ok(getRegion('Tree'),"and the valid region beside them still loaded");

unlink("$ROOT/region_sets/Mbt/Dup.region");
unlink("$ROOT/region_sets/Mbt/Self.region");
openSet('Mbt');
$reg = getRegion('Tree');


#---------------------------------------------
# planting
#---------------------------------------------

my $JPEG = "\xFF\xD8\xFF".join('',map { chr($_ % 256) } (0..511));
my $PNG  = "\x89PNG\r\n\x1a\n".join('',map { chr($_ % 256) } (0..511));
	# NOT 'xxxx'.  These carry a NUL and every byte value there is, because
	# the thing most likely to be wrong about a blob is that it went in as
	# text and came back truncated at the first NUL or mangled by an
	# encoding.  A payload of printable ASCII would pass that bug.

sub plantAll
	# Every tile of every node, each under the source that node resolves to.
	# $absent is a count of tiles to mark ABSENT instead, taken off the
	# front of the deepest node, so the sparse case is real rather than
	# simulated.
{
	my ($reg,$map,$fmt,$absent) = @_;
	$fmt    ||= 'jpeg';
	$absent ||= 0;
	my $bytes = $fmt eq 'png' ? \$PNG : \$JPEG;

	my (undef,$nodes) = regionCoverageNodes($reg,{});
	my $planted = 0;
	my $marked  = 0;

	for my $node (@$nodes)
	{
		my $src = getSource($map->{$node->{path}}) or die "no source\n";
		for my $z (sort { $a <=> $b } keys %{$node->{levels}})
		{
			for my $key (sort keys %{$node->{levels}{$z}})
			{
				my ($x,$y) = split(/_/,$key);
				if ($node->{depth} == 2 && $marked < $absent)
				{
					cachePutMiss($src,$z,$x,$y);
					$marked++;
					next;
				}
				cachePutTile($src,$z,$x,$y,$fmt,$bytes);
				$planted++;
			}
		}
	}
	return ($planted,$marked);
}

my ($planted,$marked) = plantAll($reg,$srcs,'jpeg',3);
ok($planted > 0,"planted $planted tiles into the cache");
ok($marked == 3,"and marked 3 as absent");


#---------------------------------------------
# 3 - one file per node
#---------------------------------------------

my $OUT = "$ROOT/mbtiles/Mbt";
mkdir "$ROOT/mbtiles" if !-d "$ROOT/mbtiles";
mkdir $OUT            if !-d $OUT;

my $objs = { map { $_ => getSource($srcs->{$_}) } keys %$srcs };
my $st = writeMbtiles($reg,$objs,"$OUT/Tree");

ok($st,"writeMbtiles returned stats");
ok($st && $st->{blocks} == 5,"one file per node - five files (".
	($st ? $st->{blocks} : 0).")");

my @got = grep { /\.mbtiles$/ } leaves("$OUT/Tree");
ok(scalar(@got) == 5,"five .mbtiles on disk (".scalar(@got).")");
ok((grep { $_ eq 'EastKid.mbtiles' } @got) &&
   (grep { $_ eq 'WestKid.mbtiles' } @got),
	"each is named for its node, and the two grandchildren do not collide");
ok(!(grep { /\.tmp$/ } leaves("$OUT/Tree")),"no temp file was left behind");


#---------------------------------------------
# 4 - each file's zoom range is its OWN band
#---------------------------------------------
# THE REASON THE SPLIT EXISTS.  As one file this region would announce
# maxzoom 14 over its whole extent; as five, the z11-12 file says 12 and
# only the two small grandchildren say 14.

my $root_info = mbtilesInfo("$OUT/Tree/Tree.mbtiles");
my $kid_info  = mbtilesInfo("$OUT/Tree/EastKid.mbtiles");

ok($root_info && $root_info->{metadata}{minzoom} == 11 &&
	$root_info->{metadata}{maxzoom} == 12,
	"the region's own file is z11-12, not z14");
ok($kid_info && $kid_info->{metadata}{minzoom} == 14 &&
	$kid_info->{metadata}{maxzoom} == 14,
	"the grandchild's file is z14 alone - its band above its parent");
ok($root_info->{zoom_min} == $root_info->{metadata}{minzoom} &&
   $root_info->{zoom_max} == $root_info->{metadata}{maxzoom},
	"the metadata agrees with the rows actually present");

ok($root_info->{metadata}{format} eq 'jpg',
	"a jpeg source declares format 'jpg' (".
	($root_info->{metadata}{format} // '').")");
ok($root_info->{metadata}{attribution} =~ /test mbt_a/,
	"the source's attribution travels in the metadata");

# BOUNDS COVER EVERY TILE IN THE FILE, including the coarse ones, so a
# reader clipping to them cannot drop imagery it was given.

my ($bw,$bs,$be,$bn) = split(/,/,$root_info->{metadata}{bounds});
ok($bw < -82.24 && $be > -82.24 && $bs < 9.33 && $bn > 9.33,
	"bounds contain the region centre ($root_info->{metadata}{bounds})");


#---------------------------------------------
# 5 - the TMS row flip, and the bytes
#---------------------------------------------
# CHECKED AGAINST THE ARITHMETIC, not against a second call to the same
# code.  A tile's XYZ y is taken from the coverage the exporter was given,
# and the row it must occupy is computed here independently.

my ($tree_node) = grep { $_->{path} eq 'Tree' } @$nodes;
my $z = (sort { $a <=> $b } keys %{$tree_node->{levels}})[0];
my ($tx,$ty) = split(/_/,(sort keys %{$tree_node->{levels}{$z}})[0]);
my $want_row = (1 << $z) - 1 - $ty;

my $dbh = DBI->connect("dbi:SQLite:dbname=$OUT/Tree/Tree.mbtiles",'','',
	{ RaiseError => 0, PrintError => 0 });
my ($n_at) = $dbh->selectrow_array(
	"SELECT COUNT(*) FROM tiles WHERE zoom_level=? AND tile_column=? ".
	"AND tile_row=?",undef,$z,$tx,$want_row);
ok($n_at == 1,"z$z x$tx y$ty is stored at TMS row $want_row");

my ($n_wrong) = $dbh->selectrow_array(
	"SELECT COUNT(*) FROM tiles WHERE zoom_level=? AND tile_column=? ".
	"AND tile_row=?",undef,$z,$tx,$ty);
ok($n_wrong == 0 || $ty == $want_row,
	"and NOT at the unflipped row - a mirrored file is otherwise perfect");

my ($blob) = $dbh->selectrow_array(
	"SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? ".
	"AND tile_row=?",undef,$z,$tx,$want_row);
ok(defined($blob) && $blob eq $JPEG,
	"the tile came back byte for byte - the blob is not text (".
	(defined($blob) ? length($blob) : -1)." of ".length($JPEG)." bytes)");
$dbh->disconnect();


#---------------------------------------------
# 6 - absent is simply not a row
#---------------------------------------------

my $sum = 0;
$sum += mbtilesInfo("$OUT/Tree/$_")->{tiles} for @got;
ok($sum == $st->{tiles},"the rows on disk match what was reported ".
	"($sum vs $st->{tiles})");
ok($st->{absent} == 3,"the three absent tiles are counted (".
	$st->{absent}.")");
ok($sum == $planted,"and are not rows - $sum rows for $planted planted tiles");
ok($st->{failed} == 0,"nothing failed");


#---------------------------------------------
# 7 - png builds here and is refused for a card
#---------------------------------------------
# THE PEER DIFFERENCE, in one fixture so it cannot drift.  Same source,
# same region, two exporters, two answers - and both are right.

ok(mbtilesCanCarry('png') && !rctCanCarry('png'),
	"mbtiles carries png and RCT does not");

putFile("$ROOT/region_sets/Mbt/Png.region",<<'EOJ');
{
   "region_version" : 1,
   "id" : "Png",
   "name" : "a png region",
   "zauthor" : 12,
   "zmin" : 12,
   "zmax" : 12,
   "source" : "mbt_png",
   "geometry" : [ [ [ -82.4, 9.2 ], [ -82.3, 9.2 ], [ -82.3, 9.3 ], [ -82.4, 9.3 ] ] ],
   "subregions" : []
}
EOJ
openSet('Mbt');

my $png_reg  = getRegion('Png');
my $png_srcs = regionSourceMap($png_reg,'mbt_png');
plantAll($png_reg,$png_srcs,'png');

my $png_st = writeMbtiles($png_reg,
	{ map { $_ => getSource($png_srcs->{$_}) } keys %$png_srcs },
	"$OUT/Png");
ok($png_st && $png_st->{tiles} > 0,"a png region writes an mbtiles");
ok(mbtilesInfo("$OUT/Png/Png.mbtiles")->{metadata}{format} eq 'png',
	"and its metadata says png");

my $png_rct = buildOutput(['Png'],{ fallback => 'mbt_png' },'rct');
ok(!$png_rct->{ok} && $png_rct->{guard} eq 'format',
	"the SAME region is refused for an RCT build, at the format guard");


#---------------------------------------------
# 8 - the whole act, through dm_build
#---------------------------------------------

my $r = buildOutput(['Tree'],{ fallback => 'mbt_a' },'mbtiles');
ok($r->{ok},"build mbtiles succeeds ($r->{refused})");
ok($r->{format} eq 'mbtiles',"the report says which format it was");
ok($r->{out_dir} eq "$ROOT/mbtiles/Mbt",
	"and it defaulted to the mbtiles folder, not the raster one ".
	"($r->{out_dir})");
ok(-f "$ROOT/mbtiles/Mbt/Tree/EastKid.mbtiles",
	"the region folder holds the node files");
ok($r->{regions}[0]{blocks} == 5,"the report counts five files");

# THE FILL IS FORMAT-BLIND.  Everything was already cached by the RCT-shaped
# planting above, so this build fetched nothing at all - which is the
# property that makes a second output cheap.

ok($r->{fill} && $r->{fill}{cached} == $r->{fill}{tiles},
	"the build fetched nothing - the cache is shared across formats");

my $lines = buildReportLines($r);
ok(scalar(grep { /chart folder\(s\)/ } @$lines),
	"the report calls them chart folders rather than cards");


print "\n".($fails ? "$fails FAILED" : "ALL PASSED")."\n";
exit($fails ? 1 : 0);
