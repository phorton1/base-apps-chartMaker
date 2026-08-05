#!/usr/bin/perl
#---------------------------------------------
# my_test_png.pl -- a real .rct built from a service that really serves png
#---------------------------------------------
# THE CONFIRMING RUN.  test_png.pl proves the RULES against imagery it
# draws itself, offline; this asks the one question a fixture cannot -
# does a real file, built from a real service that really serves png, come
# out the other side as a real file.  It fetches ~106 tiles from LINZ over
# Waitemata Harbour, builds an .rct, then reopens that .rct and walks its
# own zoom directory, block entries and dense index to check that EVERY
# blob is jpeg and no index entry points past the end of the file.
#
# THAT LAST CHECK IS THE POINT OF DOING IT AT ALL.  Conversion changes a
# blob's LENGTH after the layout has been reasoned about, so an exporter
# that still wrote pre-conversion offsets would pass every assertion in
# test_png.pl that did not read the file back.
#
# 'my_' BECAUSE IT NEEDS A LINZ KEY, from Patrick's key store.  A standard
# LINZ key is free and needs no registration, but it expires after 90
# days - so if this fails at the key check, that is the first thing to
# look at rather than anything about png.
#
# IT TOUCHES NOTHING OF PATRICK'S.  Its own data dir under C:/_temp, its
# own cache, its own region set - and a prefs file whose only line points
# KEYS_DIR at his real folder, because that is exactly the split that
# preference exists for.  No key is copied anywhere.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_keys;
use dm_source;
use dm_set;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_image;
use dm_rct;
use dm_build;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/linz_png";

sub rmTree
{
	my ($dir) = @_;
	return if !-d $dir;
	opendir(my $dh,$dir) or return;
	for my $leaf (grep { !/^\.\.?$/ } readdir($dh))
	{
		my $p = "$dir/$leaf";
		if (-d $p) { rmTree($p) } else { unlink($p) }
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

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";

# THE ONE LINE OF PREFERENCE.  Everything else defaults inside this data
# dir; the key store alone is read from where Patrick keeps his.

putFile("$ROOT/chartMaker.prefs",
	"KEYS_DIR = /base_data/data/chartMaker\n");

$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/linz_png_temp";
init_prefs();
loadKeys();
loadSets();

print "keys dir  ".prefDir($PREF_KEYS_DIR)."\n";
print "cache     ".cacheDir()."\n\n";

putFile("$ROOT/sources/nzpng.tsd",<<'EOJ');
{
  "tsd_version": 1,
  "id": "nzpng",
  "cache_key": "nzpng",
  "name": "LINZ Aerial as PNG",
  "url": "https://basemaps.linz.govt.nz/v1/tiles/aerial/WebMercatorQuad/{z}/{x}/{y}.png?api={linz_api_key}",
  "tile_format": "png",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 22 },
  "attribution": "Sourced from the LINZ Data Service and licensed for reuse under CC BY 4.0",
  "keys": [ { "key_name": "linz_api_key",
              "label": "LINZ Basemaps API key",
              "obtain_url": "https://basemaps.linz.govt.nz/" } ],
  "uses": ["display","build"],
  "policy": { "max_concurrency": 2, "min_interval_ms": 60 }
}
EOJ
dm_source::rescanSources();

my $src = getSource('nzpng') or die "the source did not load\n";
print "source    $src->{id} declares $src->{tile_format}\n";
my $bad = sourceUnresolved($src);
die "the key does not resolve: $bad\n" if $bad;
print "key       resolves\n\n";

# WAITEMATA HARBOUR, a small box - about seventy tiles over three levels,
# which is enough to be a real file and few enough to be polite to a service
# that publishes a rate limit.

my ($LAT,$LON,$D) = (-36.843,174.760,0.010);
newSet('NzPng');
putFile("$ROOT/region_sets/NzPng/NzPng.region",<<"EOJ");
{
   "region_version" : 1,
   "id" : "NzPng",
   "name" : "Waitemata, from png",
   "zauthor" : 16,
   "zmin" : 15,
   "zmax" : 17,
   "source" : "nzpng",
   "geometry" : [ [ [ @{[$LON-$D]}, @{[$LAT-$D]} ],
                    [ @{[$LON+$D]}, @{[$LAT-$D]} ],
                    [ @{[$LON+$D]}, @{[$LAT+$D]} ],
                    [ @{[$LON-$D]}, @{[$LAT+$D]} ] ] ],
   "subregions" : []
}
EOJ
openSet('NzPng');
my $reg = getRegion('NzPng') or die "the region did not load\n";
print "region    $reg->{id} z$reg->{zmin}-$reg->{zmax}, author z$reg->{zauthor}\n\n";

print "=== building ===\n";
my $rep = buildRct(['NzPng'],{});

print "\n=== the report ===\n";
print "$_\n" for @{buildReportLines($rep)};

if (!$rep->{ok})
{
	print "\nBUILD REFUSED at '".($rep->{guard} // '?')."'\n";
	exit 1;
}

my $path = $rep->{regions}[0]{path};
print "\n=== auditing the file on disk ===\n";
print "path      $path\n";

open(my $fh,'<',$path) or die "cannot read the file: $!\n";
binmode $fh;
local $/;
my $raw = <$fh>;
close $fh;

printf("size      %.2f MB\n",length($raw)/1048576);
printf("magic     %s\n",substr($raw,0,4));

my ($zmin,$zmax) = unpack('C C',substr($raw,0x0c,2));
printf("zooms     z%d-%d\n",$zmin,$zmax);

my ($n,$jpeg,$png,$other,$overrun) = (0,0,0,0,0);
for my $i (0 .. $zmax-$zmin)
{
	my (undef,undef,$cnt,$boff) =
		unpack('C a3 V V',substr($raw,128 + $i*32,12));
	for my $b (0 .. $cnt-1)
	{
		my @be = unpack('V12',substr($raw,$boff + $b*48,48));
		my ($gw,$gh,$ioff) = ($be[4],$be[5],$be[6]);
		for my $c (0 .. $gw*$gh - 1)
		{
			my ($off,$len) = unpack('V V',substr($raw,$ioff + $c*8,8));
			next if !$off || !$len;
			if ($off + $len > length($raw)) { $overrun++; next }
			$n++;
			my $head = substr($raw,$off,8);
			if    ($head =~ /^\xFF\xD8\xFF/)        { $jpeg++ }
			elsif ($head =~ /^\x89PNG\r\n\x1A\n/)   { $png++ }
			else                                    { $other++ }
		}
	}
}

print "\n";
printf("tiles in the file   %d\n",$n);
printf("  jpeg              %d\n",$jpeg);
printf("  png               %d   <-- must be zero\n",$png);
printf("  neither           %d   <-- must be zero\n",$other);
printf("  index overruns    %d   <-- must be zero\n",$overrun);

my $ok = ($n > 0 && $jpeg == $n && !$png && !$other && !$overrun);
print "\n".($ok ?
	"THE FILE IS ENTIRELY JPEG, BUILT FROM A SERVICE THAT SERVED PNG\n" :
	"SOMETHING IS WRONG WITH THIS FILE\n");
exit($ok ? 0 : 1);
