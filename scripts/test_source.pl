#!/usr/bin/perl
#---------------------------------------------
# t_source.pl -- headless test of dm_source.pm
#---------------------------------------------
# Writes .tsd fixtures into temp subdirs, points $data_dir at each in
# turn, and reports what loaded and what was refused.
#
# The fixtures go into <dir>/sources, because that is where dm_source
# scans -- $data_dir itself holds sources/ and region_sets/ and no loose
# files of either kind.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_source;

my $TMP = 'C:/_temp/base-apps-chartMaker';

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub freshDir
	# EVERY FIXTURE DIR IS EMPTIED BEFORE IT IS FILLED.  putFile only ever
	# added, so a fixture that was renamed left the old file behind and
	# the two then raced on id: the loser is whichever sorts later, which
	# made a rename look like the new file simply not taking effect.  That
	# is a test lying about the code, which is worse than no test.
{
	my ($dir) = @_;
	mkdir $dir if !-d $dir;
	mkdir "$dir/sources" if !-d "$dir/sources";
	unlink glob("$dir/sources/*.tsd");
}


sub putFile
{
	my ($dir,$leaf,$text) = @_;
	mkdir $dir if !-d $dir;
	mkdir "$dir/sources" if !-d "$dir/sources";
	open(my $fh,'>',"$dir/sources/$leaf")
		or die "cannot write $dir/sources/$leaf: $!";
	print $fh $text;
	close $fh;
}

sub useDir
{
	my ($dir) = @_;
	$Pub::Utils::data_dir = $dir;
	return dm_source::rescanSources();
}


#---------------------------------------------
# fixtures
#---------------------------------------------

my $GIBS = <<'EOJ';
{
  "tsd_version": 1,
  "id": "gibs_weld_annual",
  "name": "NASA GIBS - Landsat WELD True Colour (global annual)",
  "kind": "remote_xyz",
  "url": "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual/default/2000-12-01/GoogleMapsCompatible_Level12/{z}/{y}/{x}.jpeg",
  "tile_format": "jpeg",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 12 },
  "attribution": "Imagery courtesy of NASA/GSFC Earth Science Data and Information System (GIBS)",
  "license": "US Government work - not subject to copyright (17 USC 105)",
  "redistributable": "yes",
  "uses": ["display","build"],
  "policy": { "max_concurrency": 4, "min_interval_ms": 0 }
}
EOJ

my $TMS = <<'EOJ';
{
  "tsd_version": 1,
  "id": "tms_test",
  "name": "TMS row flip and subdomains",
  "kind": "remote_xyz",
  "url": "https://{s}.example.com/{z}/{x}/{-y}.png",
  "subdomains": "abc",
  "tile_format": "png",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "test",
  "uses": ["display"]
}
EOJ

my $QUAD = <<'EOJ';
{
  "tsd_version": 1,
  "id": "quad_test",
  "name": "Quadkey addressing",
  "kind": "remote_xyz",
  "url": "https://example.com/tile/{q}.jpeg",
  "zoom": { "min": 1, "max": 20 },
  "attribution": "test",
  "absent_fingerprints": [
    { "bytes": 2521, "md5": "F27D9DE7F80C13501F470595E327AA6D" }
  ],
  "absent_headers": [
    { "name": "X-VE-Tile-Info", "value": "  no-tile  " }
  ],
  "registration": "GCJ-02",
  "uses": ["display","overlay"]
}
EOJ

my %BAD = (
	'no_attrib.tsd' => '{ "tsd_version":1, "id":"a", "name":"A", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10}, "uses":["display"] }',
	'unknown_field.tsd' => '{ "tsd_version":1, "id":"b", "name":"B", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10}, "uses":["display"],
		"attribution":"t", "bounds":[1,2,3,4] }',
	'bad_placeholder.tsd' => '{ "tsd_version":1, "id":"c", "name":"C", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}/{apikey}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t" }',
	'big_tiles.tsd' => '{ "tsd_version":1, "id":"d", "name":"D", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "tile_size":512, "zoom":{"max":10},
		"uses":["display"], "attribution":"t" }',
	'not_a_tile.tsd' => '{ "tsd_version":1, "id":"e", "name":"E", "kind":"remote_xyz",
		"url":"https://e.com/static.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t" }',
	'no_subdomains.tsd' => '{ "tsd_version":1, "id":"f", "name":"F", "kind":"remote_xyz",
		"url":"https://{s}.e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t" }',
	'future.tsd' => '{ "tsd_version":9, "id":"g", "name":"G", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t" }',
	'wms.tsd' => '{ "tsd_version":1, "id":"h", "name":"H", "kind":"wms",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t" }',
	'bad_uses.tsd' => '{ "tsd_version":1, "id":"i", "name":"I", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["export"], "attribution":"t" }',
	'reserved_id.tsd' => '{ "tsd_version":1, "id":"inherited", "name":"J",
		"kind":"remote_xyz", "url":"https://e.com/{z}/{x}/{y}.png",
		"zoom":{"max":10}, "uses":["display"], "attribution":"t" }',
	'fp_not_array.tsd' => '{ "tsd_version":1, "id":"k", "name":"K", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t", "absent_fingerprints":{"bytes":1} }',
	'fp_bad_md5.tsd' => '{ "tsd_version":1, "id":"l", "name":"L", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t",
		"absent_fingerprints":[{"bytes":2521,"md5":"not-a-digest"}] }',
	'fp_no_bytes.tsd' => '{ "tsd_version":1, "id":"m", "name":"M", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t",
		"absent_fingerprints":[{"md5":"f27d9de7f80c13501f470595e327aa6d"}] }',
	'hdr_not_array.tsd' => '{ "tsd_version":1, "id":"n", "name":"N", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t",
		"absent_headers":{"name":"X-A","value":"b"} }',
	'hdr_no_value.tsd' => '{ "tsd_version":1, "id":"o", "name":"O", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t",
		"absent_headers":[{"name":"X-VE-Tile-Info"}] }',
	'hdr_bad_name.tsd' => '{ "tsd_version":1, "id":"p", "name":"P", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t",
		"absent_headers":[{"name":"X: Tile Info","value":"no-tile"}] }',
	'reg_not_a_name.tsd' => '{ "tsd_version":1, "id":"q", "name":"Q", "kind":"remote_xyz",
		"url":"https://e.com/{z}/{x}/{y}.png", "zoom":{"max":10},
		"uses":["display"], "attribution":"t",
		"registration":"shifted by about 500m, mostly north, see the notes" }',
	'broken.tsd' => '{ this is not json',
);


#---------------------------------------------
# the good dir
#---------------------------------------------

print "=== valid sources ===\n";
my $good = "$TMP/tsd_good";
freshDir($good);
putFile($good,'weld_annual.tsd',$GIBS);
putFile($good,'tms.tsd',$TMS);
putFile($good,'quad.tsd',$QUAD);

my $n = useDir($good);
ok($n == 3,"3 valid sources loaded (got $n)");
ok(join(',',getSourceIds()) eq 'gibs_weld_annual,quad_test,tms_test',
	"ids are ".join(',',getSourceIds()));

# A REGION MAY ONLY NAME A SOURCE THAT SAYS 'build'.  Two of the three
# fixtures are display-only, so this is the filter working rather than
# the list happening to be short.

ok(join(',',getBuildSourceIds()) eq 'gibs_weld_annual',
	"only build-capable sources are offered to a region (got ".
	join(',',getBuildSourceIds()).")");

my $gibs = getSource('gibs_weld_annual');
ok($gibs,"gibs source found");
# The leaf name, NOT the id -- the fixture is written as weld_annual.tsd
# and its id is gibs_weld_annual, so this only passes if the cache key
# comes from the file.  test_fetch.pl consumes this same fixture dir and
# asserts the cache PATH, so the two must agree about the leaf.

ok($gibs && $gibs->{cache_key} eq 'weld_annual',
	"cache_key is the leaf name minus .tsd");
ok($gibs && $gibs->{tile_size} == 256,"tile_size defaulted/kept at 256");
ok($gibs && $gibs->{crs} eq 'EPSG:3857',"crs defaulted to EPSG:3857");
ok($gibs && $gibs->{redistributable} eq 'yes',"redistributable read");

my $q = getSource('quad_test');

# The fingerprint of a server that answers 200 with a picture of the word
# 'no'.  Stored lower case whatever the file said, so a comparison never
# has to think about it.

ok($q && ref($q->{absent_fingerprints}) eq 'ARRAY' &&
	scalar(@{$q->{absent_fingerprints}}) == 1,
	"absent_fingerprints read");
ok($q && $q->{absent_fingerprints}[0]{bytes} == 2521,
	"fingerprint byte length read");
ok($q && $q->{absent_fingerprints}[0]{md5} eq 'f27d9de7f80c13501f470595e327aa6d',
	"fingerprint md5 folded to lower case");
# The same absence said in a header.  Lower cased on the way in so that
# two files declaring the same header in different cases produce the same
# structure, and trimmed so a value that was padded in the file still
# compares equal to what a server actually sends.

ok($q && ref($q->{absent_headers}) eq 'ARRAY' &&
	scalar(@{$q->{absent_headers}}) == 1,
	"absent_headers read");
ok($q && $q->{absent_headers}[0]{name} eq 'x-ve-tile-info',
	"absent_header name folded to lower case");
ok($q && $q->{absent_headers}[0]{value} eq 'no-tile',
	"absent_header value trimmed");

ok($q && $q->{registration} eq 'GCJ-02',"registration read");

ok($q && grep({ $_ eq 'overlay' } @{$q->{uses}}),
	"'overlay' is a legal use");
ok(!grep({ $_ eq 'quad_test' } getBuildSourceIds()),
	"and an overlay is still not offered as a build source");

ok($q && $q->{redistributable} eq 'unknown',"redistributable defaults to unknown");
ok($q && $q->{tile_format} eq 'jpeg',"tile_format defaults to jpeg");
ok($q && $q->{zoom}{min} == 1,"zoom.min read");

my $t = getSource('tms_test');
ok($t && ref($t->{subdomains}) eq 'ARRAY' && scalar(@{$t->{subdomains}}) == 3,
	"subdomains string expanded to 3 entries");


#---------------------------------------------
# addressing
#---------------------------------------------

print "\n=== addressing ===\n";

my $url = sourceTileUrl($gibs,10,283,481);
ok(defined($url) && $url =~ m{/10/481/283\.jpeg$},
	"gibs url is z/y/x (row before column): ".($url // 'undef'));

ok(!defined(sourceTileUrl($gibs,13,1,1)),"z13 refused - above declared zoom.max 12");
ok(!defined(sourceTileUrl($gibs,-1,1,1)),"z-1 refused - below declared zoom.min");

# TMS row flip: at z10 there are 1024 rows, so y=481 flips to 1023-481=542
my $turl = sourceTileUrl($t,10,283,481);
ok(defined($turl) && $turl =~ m{/10/283/542\.png$},
	"TMS {-y} flipped 481 to 542: ".($turl // 'undef'));
ok(defined($turl) && $turl =~ m{^https://[abc]\.example\.com/},
	"subdomain substituted");

my %seen;
$seen{$1}++ while (sourceTileUrl($t,10,1,1) // '') =~ m{^https://([abc])\.} and
	scalar(keys %seen) < 3 and scalar(keys %seen) + 0 == scalar(keys %seen);
# round robin: three consecutive calls should give three different subdomains
my @subs;
push @subs, (sourceTileUrl($t,10,1,1) =~ m{^https://(\w)\.})[0] for (1..3);
ok(scalar(keys %{{ map { $_ => 1 } @subs }}) == 3,
	"subdomains round robin: ".join(',',@subs));

# quadkey: the canonical Bing example, z3 x=3 y=5 -> "213"
my $qurl = sourceTileUrl($q,3,3,5);
ok(defined($qurl) && $qurl =~ m{/tile/213\.jpeg$},
	"quadkey z3/3/5 = 213: ".($qurl // 'undef'));


#---------------------------------------------
# the bad dir
#---------------------------------------------

print "\n=== rejections (each should report one specific reason) ===\n";
my $bad = "$TMP/tsd_bad";
freshDir($bad);
putFile($bad,$_,$BAD{$_}) for keys %BAD;
my $b = useDir($bad);
ok($b == 0,"no invalid source loaded (got $b)");


#---------------------------------------------
# duplicate ids
#---------------------------------------------

print "\n=== duplicate id ===\n";
my $dup = "$TMP/tsd_dup";
freshDir($dup);
putFile($dup,'aaa.tsd',$QUAD);
putFile($dup,'zzz.tsd',$QUAD);
my $d = useDir($dup);
ok($d == 1,"duplicate id loaded once (got $d)");
ok(getSource('quad_test')->{file} eq 'aaa.tsd',"first file alphabetically wins");


print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
