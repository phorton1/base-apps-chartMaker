#!/usr/bin/perl
#---------------------------------------------
# test_preview.pl -- headless test of the preview classification
#---------------------------------------------
# HERMETIC and entirely OFFLINE.  It never starts a server and never fetches
# a tile: what is under test is the decision, not the drawing.
#
# The decision is what the card HOLDS AT ONE ZOOM, and there are only two
# answers:
#
#	the card carries this tile at this zoom -> draw it, from the right source
#	it does not                             -> draw nothing, and let the
#	                                           greyed base map show through
#
# NO FALLBACK, and that is the point rather than an omission. An earlier
# version answered with the deepest ANCESTOR the card held, reproducing what
# a plotter does when you zoom past the built depth. It made the built edge
# unreadable: real imagery and magnified imagery look alike, so the card
# appeared to extend a long way past where it actually stopped. Zooming in
# until the imagery stops IS the answer to "how deep did I build here", and
# it only works if the imagery actually stops.
#
# It also pins INNERMOST WINS: where a subregion overlaps its parent at a
# shared zoom, the tile is built from the subregion's source, and preview
# must draw it from that one or it is showing imagery the card will not
# contain.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/prev_data";

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_)."\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}


#---------------------------------------------
# a data dir from nothing
#---------------------------------------------

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

sub tsd
{
	my ($id) = @_;
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "test source $id",
  "kind": "remote_xyz",
  "url": "https://$id.example.com/{z}/{x}/{y}.jpg",
  "tile_format": "jpeg",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "test",
  "uses": ["display","build"]
}
EOJ
}

# One region carried z10-13, with a detail area inside it going to z15 and
# built from a DIFFERENT source.  That shape is what makes every assertion
# below distinguishable from every other.

my ($LAT,$LON) = (9.33,-82.24);

sub regionJson
{
	my ($id,$src,$sub_src) = @_;
	my $d = 0.2;
	my $i = 0.05;
	my $ring  = "[ [ @{[$LON-$d]}, @{[$LAT-$d]} ], [ @{[$LON+$d]}, @{[$LAT-$d]} ], ".
				"[ @{[$LON+$d]}, @{[$LAT+$d]} ], [ @{[$LON-$d]}, @{[$LAT+$d]} ] ]";
	my $inner = "[ [ @{[$LON-$i]}, @{[$LAT-$i]} ], [ @{[$LON+$i]}, @{[$LAT-$i]} ], ".
				"[ @{[$LON+$i]}, @{[$LAT+$i]} ], [ @{[$LON-$i]}, @{[$LAT+$i]} ] ]";
	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "$id",
   "zauthor" : 12,
   "zmin" : 10,
   "zmax" : 13,
   "source" : "$src",
   "geometry" : [ $ring ],
   "subregions" : [
      {
         "id" : "Deep",
         "name" : "deep bit",
         "zmax" : 15,
         "source" : "$sub_src",
         "geometry" : [ $inner ],
         "subregions" : []
      }
   ]
}
EOJ
}

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/prev_temp";

loadSets();
putFile("$ROOT/sources/wide.tsd",tsd('wide'));
putFile("$ROOT/sources/deep.tsd",tsd('deep'));
dm_source::rescanSources();

newSet('Prev');
putFile("$ROOT/region_sets/Prev/Alpha.region",regionJson('Alpha','wide','deep'));
openSet('Prev');

my $cov = mergedCoverageSources([ getRegion('Alpha') ],'fallback_src');

# The tile containing the region's centre, at each level of interest.
sub at { my ($z) = @_; my ($x,$y) = lonLatToTile($LON,$LAT,$z); return ($x,$y) }

sub classify
	# One tile, asked for on its own - the rectangle is that tile alone.
{
	my ($z,$x,$y) = @_;
	return previewTiles($cov,$z,$x,$y,$x,$y)->{"${x}_${y}"};
}


#---------------------------------------------
# carried at this zoom
#---------------------------------------------

print "=== the card carries it ===\n";

my ($x12,$y12) = at(12);
ok(classify(12,$x12,$y12),"a tile at the authored level is carried at z12");
ok((classify(12,$x12,$y12) || '') eq 'wide',"from the region's own source");

# The subregion's band is z14-15, so at z14 the only tiles carried are the
# detail area's - and they are built from ITS source.

my ($x14,$y14) = at(14);
ok(classify(14,$x14,$y14),"the detail area is carried at z14");
ok((classify(14,$x14,$y14) || '') eq 'deep',
	"INNERMOST WINS - the subregion's source, not its parent's");


#---------------------------------------------
# past the built depth, the imagery STOPS
#---------------------------------------------

print "\n=== past the built depth the imagery stops ===\n";

# z16 is one level past the deepest thing in this set (the subregion's zmax
# is 15), so the card holds nothing there - and preview must say so rather
# than magnifying z15 to fill the hole.

my ($x16,$y16) = at(16);
ok(!defined(classify(16,$x16,$y16)),
	"a tile past every zmax is NOT drawn - no fallback to an ancestor");

my ($x19,$y19) = at(19);
ok(!defined(classify(19,$x19,$y19)),
	"and four levels further past it, still nothing");

# OUTSIDE THE DETAIL AREA the region itself stops at z13, so the same zoom
# gives different answers in different places. Depth is spatial, and this is
# what makes zooming in until the imagery stops a real measurement of it.

my ($xi,$yi) = at(15);
ok(classify(15,$xi,$yi),"inside the detail area z15 IS carried");

my ($xo,$yo) = lonLatToTile($LON+0.15,$LAT+0.15,15);
ok(!defined(classify(15,$xo,$yo)),
	"while at the same zoom, outside it, the card stops at the region's z13");


#---------------------------------------------
# outside coverage
#---------------------------------------------

print "\n=== outside coverage ===\n";

my ($xf,$yf) = lonLatToTile($LON+5,$LAT+5,12);
ok(!defined(classify(12,$xf,$yf)),
	"a tile nowhere near the region is absent from the result");

my ($x9,$y9) = at(9);
ok(!defined(classify(9,$x9,$y9)),
	"a zoom above the set's floor holds nothing");


#---------------------------------------------
# a rectangle, not just single tiles
#---------------------------------------------

print "\n=== a viewport-shaped question ===\n";

my $rect = previewTiles($cov,12,$x12-1,$y12-1,$x12+1,$y12+1);
ok(scalar(keys %$rect) == 9,
	"a 3x3 rectangle inside the region classifies all nine ".
	"(got ".scalar(keys %$rect).")");
my $unsourced = scalar(grep { !$_ } values %$rect);
ok($unsourced == 0,"every one of them names a source");


#---------------------------------------------

print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
