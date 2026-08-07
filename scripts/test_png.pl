#!/usr/bin/perl
#---------------------------------------------
# test_png.pl -- headless test of PNG conversion at the RCT exporter seam
#---------------------------------------------
# HERMETIC AND OFFLINE.  It builds its own data dir under C:/_temp, draws
# its own imagery with GD and plants every tile itself, so nothing here
# touches a network, a key or Patrick's data.
#
# THE 2x2 IS THE WHOLE SUBJECT.  tile_format in a .tsd is an EXPECTATION
# and the real format arrives per tile from the magic bytes, so a source
# and its tiles can disagree in either direction:
#
#	                 declares jpeg      declares png
#	  serves jpeg    the ordinary case  was refused before it started
#	  serves png     died mid-write     was refused before it started
#
# Three of those four were broken, and all three were the same mistake:
# the declaration treated as evidence.  This file exists to keep them
# fixed, so every cell is built end to end rather than reasoned about.
#
# IT SKIPS ITSELF WHEN THERE IS NO DECODER, exactly as test_image.pl does.
# The application is designed to run without GD, and in that configuration
# a png source SHOULD be refused - so the skip is not a gap, it is the
# other half of the design, and the one assertion that still runs is that
# the refusal is still there.
#
# What it pins down:
#
#	an .rct still CARRIES jpeg only - conversion did not widen the format
#	a png-declaring source is no longer refused before a build starts
#	all four cells of the matrix build a card
#	every blob in the card is jpeg, read back out of the file itself
#	the card is still structurally sound - offsets and lengths line up
#	the converted count is reported, and is zero when nothing converted
#	THE CACHE IS NOT TOUCHED - it still holds the png the service sent
#	quality reaches the encoder, and a caller's value beats the preference
#	a png that will not decode is refused, and says so

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_utils;
use cm_prefs;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_image;
use dm_rct;
use dm_mbtiles;
use dm_build;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/png_data";

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_).
		" at line ".(caller)[2]."\n" if @_ != 2;
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
		if (-d $path) { rmTree($path) } else { unlink($path) }
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

sub slurp
{
	my ($path) = @_;
	open(my $fh,'<',$path) or return undef;
	binmode $fh;
	local $/;
	my $data = <$fh>;
	close $fh;
	return $data;
}


#---------------------------------------------
# what a card is made of, read back out of one
#---------------------------------------------

sub cardBlobs
	# Every tile in an .rct, as bytes, by walking the file's own zoom
	# directory, block entries and dense index.
	#
	# READ RATHER THAN REMEMBERED, which is the point.  Asserting on what
	# writeRct returned would only prove the exporter agrees with itself;
	# conversion changes the LENGTH of a blob, so the offsets it wrote have
	# to be checked against the bytes that landed.  A card whose index
	# still pointed at pre-conversion lengths would pass every other test
	# in this file and be garbage on the plotter.
{
	my ($path) = @_;
	my $raw = slurp($path) or return ();
	return () if substr($raw,0,4) ne 'RCT1';

	my ($zmin,$zmax) = unpack('C C',substr($raw,0x0c,2));
	my @out;

	for my $i (0 .. $zmax-$zmin)
	{
		my (undef,undef,$cnt,$boff) =
			unpack('C a3 V V',substr($raw,128 + $i*32,12));

		for my $b (0 .. $cnt-1)
		{
			my @be = unpack('V12',substr($raw,$boff + $b*48,48));
			my ($gw,$gh,$ioff) = ($be[4],$be[5],$be[6]);

			for my $cell (0 .. $gw*$gh - 1)
			{
				my ($off,$len) =
					unpack('V V',substr($raw,$ioff + $cell*8,8));
				next if !$off || !$len;

				# THE ONE CHECK THAT CATCHES A BAD LAYOUT.  An offset or
				# length past the end of the file means the index and the
				# blobs disagree, which is exactly the failure a change to
				# blob lengths could introduce.

				return ('OVERRUN') if $off + $len > length($raw);
				push @out,substr($raw,$off,$len);
			}
		}
	}
	return @out;
}


sub allJpeg
{
	my (@blobs) = @_;
	return 0 if !@blobs;
	for my $b (@blobs)
	{
		return 0 if $b eq 'OVERRUN';
		return 0 if substr($b,0,3) ne "\xFF\xD8\xFF";
	}
	return 1;
}


#---------------------------------------------
# fixtures
#---------------------------------------------

sub tsd
{
	my ($id,$fmt) = @_;
	my $ext = ($fmt eq 'png') ? 'png' : 'jpg';
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


sub regionJson
{
	my ($id,$src) = @_;
	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "region $id",
   "zauthor" : 12,
   "zmin" : 12,
   "zmax" : 13,
   "source" : "$src",
   "geometry" : [ [ [ -82.40, 9.20 ], [ -82.28, 9.20 ],
                    [ -82.28, 9.32 ], [ -82.40, 9.32 ] ] ],
   "subregions" : []
}
EOJ
}


#---------------------------------------------
# is there a decoder at all
#---------------------------------------------

print "=== is there a decoder ===\n";
my $can = imageCan();
ok(defined $can,"imageCan answers rather than dying (got ".($can ? 1 : 0).")");

# THE FORMAT DID NOT WIDEN, and this is the assertion that says conversion
# is a doorway rather than a new capability of the container.  It is true
# with or without a decoder, so it runs either way.

ok(rctCanCarry('jpeg'),"an .rct carries jpeg");
ok(!rctCanCarry('png'),"an .rct still does NOT carry png - it converts it");
ok(mbtilesCanCarry('png'),"an mbtiles genuinely holds png, and converts nothing");

if (!$can)
{
	ok(!rctCanConvert('png'),
		"with no decoder, png cannot be converted either");
	print "\nSKIPPED the rest - no decoder installed, which is a supported\n";
	print "configuration in which refusing a png source is CORRECT.\n";
	print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
	exit($fails ? 1 : 0);
}

ok(rctCanConvert('png'),"with a decoder, an .rct can take a png in");
ok(!rctCanConvert('gif'),"and still refuses a format nobody considered");
ok(!rctCanConvert(undef),"and an undefined format is not a yes");


#---------------------------------------------
# the imagery
#---------------------------------------------
# ONE TILE, DRAWN ONCE and used for every coordinate.  What is being
# measured is a codec path, not the ground, and 300 identical tiles
# exercise it exactly as well as 300 different ones for a fraction of the
# setup.  It carries real structure rather than flat colour because a flat
# tile compresses to nothing and would make the quality assertions
# meaningless.

require GD;

my $img = GD::Image->new(256,256,1);
for my $by (0 .. 15)
{
	for my $bx (0 .. 15)
	{
		my $c = $img->colorAllocate(
			(($bx * 37 + $by * 11) % 256),
			(($bx * 91 + $by * 53) % 256),
			(($bx * 17 + $by * 29) % 256));
		$img->filledRectangle($bx*16,$by*16,$bx*16+15,$by*16+15,$c);
	}
}
my $white = $img->colorAllocate(255,255,255);
$img->line(0,0,255,255,$white);
$img->line(255,0,0,255,$white);

my $JPEG = $img->jpeg(85);
my $PNG  = $img->png();

print "\n=== fixture imagery ===\n";
ok(length($JPEG) > 1000,"drew a jpeg tile (".length($JPEG)." bytes)");
ok(length($PNG)  > 1000,"drew a png tile (".length($PNG)." bytes)");
ok(substr($PNG,0,8) eq "\x89PNG\r\n\x1a\n","and the png really is one");


#---------------------------------------------
# the data dir
#---------------------------------------------

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/png_temp";

loadSets();

# FOUR SOURCES, ONE PER CELL.  The declaration is in the .tsd and the
# reality is what gets planted, and the two are crossed deliberately.

putFile("$ROOT/sources/cell_a.tsd",tsd('cell_a','jpeg'));	# serves jpeg
putFile("$ROOT/sources/cell_b.tsd",tsd('cell_b','jpeg'));	# serves png
putFile("$ROOT/sources/cell_c.tsd",tsd('cell_c','png'));	# serves jpeg
putFile("$ROOT/sources/cell_d.tsd",tsd('cell_d','png'));	# serves png
putFile("$ROOT/sources/cell_x.tsd",tsd('cell_x','png'));	# serves rubbish
dm_source::rescanSources();

newSet('Png');
putFile("$ROOT/region_sets/Png/CellA.region",regionJson('CellA','cell_a'));
putFile("$ROOT/region_sets/Png/CellB.region",regionJson('CellB','cell_b'));
putFile("$ROOT/region_sets/Png/CellC.region",regionJson('CellC','cell_c'));
putFile("$ROOT/region_sets/Png/CellD.region",regionJson('CellD','cell_d'));
putFile("$ROOT/region_sets/Png/CellX.region",regionJson('CellX','cell_x'));
openSet('Png');

mkdir "$ROOT/raster" if !-d "$ROOT/raster";


sub plant
	# Every tile of one region, in the format its SERVICE would have sent,
	# which is not necessarily the format its .tsd declares.
{
	my ($id,$bytes) = @_;
	my $reg  = getRegion($id) or die "no region $id\n";
	my $map  = regionSourceMap($reg);
	my $fmt  = (substr($$bytes,0,3) eq "\xFF\xD8\xFF") ? 'jpeg' : 'png';

	my (undef,$nodes) = regionCoverageNodes($reg,{});
	my $n = 0;
	for my $node (@$nodes)
	{
		my $src = getSource($map->{$node->{path}}) or die "no source\n";
		for my $z (sort { $a <=> $b } keys %{$node->{levels}})
		{
			for my $key (sort keys %{$node->{levels}{$z}})
			{
				my ($x,$y) = split(/_/,$key);
				cachePutTile($src,$z,$x,$y,$fmt,$bytes);
				$n++;
			}
		}
	}
	return $n;
}

my $JUNK = "\x89PNG\r\n\x1a\n".("not really a png" x 8);

print "\n=== planting ===\n";
my $na = plant('CellA',\$JPEG);
my $nb = plant('CellB',\$PNG);
my $nc = plant('CellC',\$JPEG);
my $nd = plant('CellD',\$PNG);
my $nx = plant('CellX',\$JUNK);
ok($na > 0 && $na == $nb && $nb == $nc && $nc == $nd,
	"each cell has the same $na tiles planted");

# THE CACHE KEYS OFF THE DETECTED FORMAT, NOT THE DECLARATION, and this
# says so on disk: cell_b declares jpeg in its .tsd and every file under
# it is a .png.

my @b_files = glob(cacheDir()."/cell_b/12/*");
ok(scalar(@b_files) && !grep({ !/\.png$/ } @b_files),
	"cell_b declares jpeg and its cache holds .png files");


#---------------------------------------------
# 1 - the preflight no longer refuses a declaration
#---------------------------------------------

print "\n=== the preflight gate ===\n";

for my $cell (qw( CellA CellB CellC CellD ))
{
	my $r = buildOutput([$cell],{},'rct');
	ok($r->{ok},"$cell builds a card".
		($r->{ok} ? '' : " - refused at '".($r->{guard} // '?')."': ".
		 ($r->{refused} // '')));
}

# CellC AND CellD ARE THE ONES THAT USED TO BE REFUSED, both because they
# declare png, and one of them serves jpeg exclusively.

my $rc = buildOutput(['CellC'],{},'rct');
ok($rc->{ok} && $rc->{totals}{converted} == 0,
	"CellC declares png, serves jpeg, and converts NOTHING (".
	($rc->{totals}{converted} // '?').")");


#---------------------------------------------
# 2 - every cell writes a card of jpeg
#---------------------------------------------

print "\n=== what landed in the card ===\n";

my %expect_converted = (
	CellA => 0,	CellB => $nb,
	CellC => 0,	CellD => $nd );

for my $cell (qw( CellA CellB CellC CellD ))
{
	my $r = buildOutput([$cell],{},'rct');
	my $path = $r->{regions} && $r->{regions}[0] ?
		$r->{regions}[0]{path} : '';
	my @blobs = cardBlobs($path);

	ok(scalar(@blobs) == $na,
		"$cell wrote $na tiles into the card (".scalar(@blobs).")");
	ok(allJpeg(@blobs),
		"$cell - every blob in the file is jpeg, and no index overran");
	ok($r->{totals}{converted} == $expect_converted{$cell},
		"$cell converted $expect_converted{$cell} tile(s) (".
		$r->{totals}{converted}.")");
}


#---------------------------------------------
# 3 - the bytes really changed, and only where they had to
#---------------------------------------------

print "\n=== copied or re-encoded ===\n";

my $ra = buildOutput(['CellA'],{},'rct');
my @a_blobs = cardBlobs($ra->{regions}[0]{path});
ok($a_blobs[0] eq $JPEG,
	"a jpeg tile is copied BYTE FOR BYTE - conversion did not touch it");

my $rd = buildOutput(['CellD'],{},'rct');
my @d_blobs = cardBlobs($rd->{regions}[0]{path});
ok($d_blobs[0] ne $PNG && substr($d_blobs[0],0,3) eq "\xFF\xD8\xFF",
	"a png tile is re-encoded, and what landed is jpeg");


#---------------------------------------------
# 4 - the cache is not touched
#---------------------------------------------
# THE RULE THE WHOLE DESIGN RESTS ON.  The cache mirrors what the service
# sent; the format a card needs is a property of the card.  A conversion
# that wrote back would make the cache a record of what we last built
# rather than of what was served.

print "\n=== the cache after a conversion ===\n";

my @d_files = glob(cacheDir()."/cell_d/12/*");
ok(scalar(@d_files) && !grep({ !/\.png$/ } @d_files),
	"cell_d's cache still holds .png files after building a card");
ok(slurp($d_files[0]) eq $PNG,
	"and the bytes are still exactly what the service sent");


#---------------------------------------------
# 5 - quality reaches the encoder
#---------------------------------------------

print "\n=== quality ===\n";

my $lo = buildOutput(['CellD'],{ quality => 40 },'rct');
my $lo_bytes = $lo->{totals}{bytes};
my $hi = buildOutput(['CellD'],{ quality => 95 },'rct');
my $hi_bytes = $hi->{totals}{bytes};

ok($lo->{ok} && $hi->{ok},"a card builds at q40 and at q95");
ok($hi_bytes > $lo_bytes,
	"q95 writes a bigger card than q40 ($hi_bytes vs $lo_bytes)");
ok($lo->{quality} == 40 && $hi->{quality} == 95,
	"and the report says which quality it used");

# A CALLER'S VALUE BEATS THE PREFERENCE, which is what lets a test pin the
# number without touching anybody's settings.

my $def = buildOutput(['CellD'],{},'rct');
ok($def->{quality} == prefVal($PREF_JPEG_QUALITY),
	"with no caller value the preference is used (".
	($def->{quality} // '?').")");
ok(prefVal($PREF_JPEG_QUALITY) == 90,"and it defaults to 90");

# NOTHING TO CONVERT MEANS NOTHING TO CHANGE.  A jpeg source is immune to
# the setting entirely, which is the sentence the preferences dialog makes
# and this is the assertion behind it.

my $a40 = buildOutput(['CellA'],{ quality => 40 },'rct');
my $a95 = buildOutput(['CellA'],{ quality => 95 },'rct');
ok($a40->{totals}{bytes} == $a95->{totals}{bytes},
	"a jpeg source builds the same card at q40 and q95 - untouched");


#---------------------------------------------
# 6 - a png that will not decode
#---------------------------------------------
# THE FAILURE THAT MUST STAY LOUD.  Conversion cannot be allowed to
# degrade into "pass the original through": that is precisely the card
# that reports success and is blank on the water.

print "\n=== undecodable bytes ===\n";

my $rx = buildOutput(['CellX'],{},'rct');
ok(!$rx->{ok},"a source serving undecodable png does NOT build a card");
ok(($rx->{guard} // '') eq 'export',
	"it fails at the exporter, not the preflight - the declaration was ".
	"fine and the BYTES were not (guard '".($rx->{guard} // '?')."')");

# THE REASON HAS TO REACH THE REPORT.  'could not be written' is what the
# build says about every export failure, and on its own it sends somebody
# to the console log to find out which tile of which source was wrong.
#
# scalar() AROUND THE MATCH IS NOT DECORATION.  A failed match in list
# context returns the EMPTY LIST, so ok() would be called with one
# argument and die about its own arity instead of reporting a failure -
# which is exactly what happened while this file was being written.

my $detail = join("\n",@{$rx->{detail} || []});
ok(scalar($detail =~ /would not decode/i),
	"and the report itself says the bytes would not decode");
ok(scalar($detail =~ /cell_x/),
	"naming the source that served them");
ok(scalar($detail =~ m|12/\d+/\d+|),
	"and the tile it gave up on");


#---------------------------------------------
# 7 - the report says so
#---------------------------------------------

print "\n=== the report ===\n";

my $lines = buildReportLines($rd);
ok(scalar(grep { /re-encoded at quality/ } @$lines),
	"a build that converted says so in its report");
ok(scalar(grep { /quality 90/ } @$lines),
	"and names the quality it used");

my $a_lines = buildReportLines($ra);
ok(!scalar(grep { /re-encoded/ } @$a_lines),
	"a build that converted nothing says nothing about it");


print "\n".($fails ? "$fails FAILED" : "ALL PASSED")."\n";
exit($fails ? 1 : 0);
