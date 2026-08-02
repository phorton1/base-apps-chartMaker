#!/usr/bin/perl
#---------------------------------------------
# tool_fetch_bench.pl -- does concurrency actually buy wall clock?
#---------------------------------------------
# THE ONE CLAIM IN THE ENGINE THAT WAS ASSERTED RATHER THAN MEASURED.
# Pacing was measured against a stub, but a stub answers in about 2 ms, and
# at 2 ms round trip concurrency cannot help anybody - there is no latency
# to cover.  Whether a second worker earns its keep is a question about a
# real server on a real connection, and nothing local can answer it.
#
# It matters because the composition rule says
#
#	concurrency = min( tsd.max_concurrency, pool, ceil(rtt/interval) )
#
# and the third term DROPS OUT when a source declares no interval - which
# both shipped sources do.  So for them the binding limit is whatever the
# TSD asks for or whatever the pool allows, and neither number came from a
# measurement.  This is that measurement.
#
# HOW IT IS FAIR.  The same tiles are fetched at every pool size, with the
# cache cleared in between, so each condition does identical work.  It uses
# its OWN data dir under C:/_temp, so the user's real cache is never read,
# written or cleared.
#
# ON VOLUME AND MANNERS.  NASA GIBS is US Government work and explicitly
# redistributable, so it carries the bulk of this.  Esri is included
# because it is what the real regions actually use, at a deliberately small
# tile count - Esri's terms prohibit systematically harvesting the service,
# and a benchmark is not a licence to do it.  The totals are printed so the
# cost of running this is never a surprise.
#
#   perl tool_fetch_bench.pl [tiles_per_condition]

use strict;
use warnings;
use POSIX qw( floor );
use Time::HiRes qw( time );
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use Pub::Prefs;
use cm_defs;
use cm_prefs;
use dm_set;
use dm_source;
use dm_cache;
use dm_observe;
use dm_fetch;
use dm_engine;

$| = 1;

my $TILES = shift(@ARGV) || 24;
my @POOLS = (1,2,4,6);

my $ROOT = 'C:/_temp/base-apps-chartMaker/bench';
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$ROOT/temp";

mkdir $ROOT           if !-d $ROOT;
mkdir "$ROOT/sources" if !-d "$ROOT/sources";
unlink glob("$ROOT/sources/*.tsd");


sub putSource
{
	my ($leaf,$json) = @_;
	open(my $fh,'>',"$ROOT/sources/$leaf") or die $!;
	print $fh $json;
	close $fh;
}

# THE TWO SHIPPED SOURCES, copied rather than referenced, so this benchmark
# measures what the application would do and not what one machine's data
# dir happens to contain today.

putSource('esri.tsd',<<'EOJ');
{
  "tsd_version": 1,
  "id": "bench_esri",
  "name": "Esri - ArcGIS World Imagery",
  "kind": "remote_xyz",
  "url": "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
  "tile_format": "jpeg",
  "zoom": { "min": 0, "max": 23 },
  "attribution": "Source: Esri, Vantor, Earthstar Geographics, and the GIS User Community",
  "uses": ["display","build"],
  "policy": { "max_concurrency": 6, "min_interval_ms": 0 },
  "absent_fingerprints": [
    { "bytes": 2521, "md5": "f27d9de7f80c13501f470595e327aa6d" }
  ]
}
EOJ

putSource('weld.tsd',<<'EOJ');
{
  "tsd_version": 1,
  "id": "bench_gibs",
  "name": "NASA GIBS - Landsat WELD True Colour",
  "kind": "remote_xyz",
  "url": "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual/default/2000-12-01/GoogleMapsCompatible_Level12/{z}/{y}/{x}.jpeg",
  "tile_format": "jpeg",
  "zoom": { "min": 0, "max": 12 },
  "attribution": "Imagery courtesy of NASA/GSFC EOSDIS GIBS",
  "uses": ["display","build"],
  "policy": { "max_concurrency": 4, "min_interval_ms": 0 }
}
EOJ

rescanSources();
obsLoad();
setPref($PREF_MIN_INTERVAL,0);


sub tileOf
{
	my ($lat,$lon,$z) = @_;
	my $n   = 2 ** $z;
	my $rad = $lat * 3.14159265358979 / 180;
	return ( floor(($lon + 180) / 360 * $n),
			 floor((1 - log(sin($rad)/cos($rad) + 1/cos($rad)) / 3.14159265358979) / 2 * $n) );
}


sub tileBlock
	# A square-ish run of tiles around Bocas del Toro, which is the ground
	# both shipped sources actually hold imagery over.
{
	my ($z,$count) = @_;
	my ($cx,$cy) = tileOf(9.33,-82.24,$z);
	my $side = int(sqrt($count)) + 1;
	my @out;
	for my $dy (0..$side)
	{
		for my $dx (0..$side)
		{
			push @out,[ $z, $cx + $dx, $cy + $dy ];
			return @out if @out >= $count;
		}
	}
	return @out;
}


sub clearCache
	# EVERY CONDITION MUST DO THE SAME WORK.  getTile answers a hit without
	# touching the engine at all, so leaving the cache in place would make
	# every run after the first measure the speed of a local disk.
{
	my ($src) = @_;
	my $dir = cacheDir()."/$src->{cache_key}";
	return if !-d $dir;
	for my $z (glob("$dir/*"))
	{
		unlink glob("$z/*");
		rmdir $z;
	}
	rmdir $dir;
}


sub runCondition
	# One pool size, one source, the same tiles.  Returns wall clock and
	# what actually came back, because a fast run that fetched nothing is
	# not a fast run.
{
	my ($src,$tiles,$pool) = @_;

	clearCache($src);
	setPref($PREF_MAX_CONCURRENT,$pool);

	engineStop() if engineRunning();
	engineStart($pool);

	my $t0 = time();
	my @jobs = map {
		engineSubmit($src,$_->[0],$_->[1],$_->[2],$PRIORITY_BULK,0)
	} @$tiles;

	my %got;
	my $bytes = 0;
	for my $j (@jobs)
	{
		my $r = engineCollect($j);
		$got{$r->{status}}++;
		$bytes += length(${$r->{bytes}}) if $r->{bytes};
	}
	my $secs = time() - $t0;

	return { secs => $secs, ok => $got{ok} || 0,
		absent => $got{absent} || 0, error => $got{error} || 0,
		bytes => $bytes,
		concurrency => engineConcurrency($src,0),
		rtt => obsField($src,'rtt_ms') };
}


sub bench
{
	my ($id,$z,$label) = @_;

	my $src = getSource($id) or die "no source '$id'\n";
	my @tiles = tileBlock($z,$TILES);

	printf("\n=== %s ===\n",$label);
	printf("%d tiles at z%d, each pool size fetching the SAME tiles cold\n",
		scalar(@tiles),$z);
	printf("declared max_concurrency %d, min_interval_ms %d\n",
		$src->{policy}{max_concurrency} // 0,
		$src->{policy}{min_interval_ms} // 0);
	printf("total requests this section: %d\n\n",
		scalar(@tiles) * scalar(@POOLS));

	printf("  %-6s %8s %9s %9s %8s %7s  %s\n",
		'pool','conc','secs','tiles/s','speedup','rtt','result');

	my $base;
	for my $pool (@POOLS)
	{
		my $r = runCondition($src,\@tiles,$pool);
		$base = $r->{secs} if !defined $base;

		printf("  %-6d %8d %9.2f %9.2f %7.2fx %6dms  %d ok, %d absent, %d error\n",
			$pool,$r->{concurrency},$r->{secs},
			scalar(@tiles)/$r->{secs},$base/$r->{secs},
			$r->{rtt},$r->{ok},$r->{absent},$r->{error});
	}
}


printf("fetch benchmark: %d tiles per condition, pools %s\n",
	$TILES,join(',',@POOLS));

bench('bench_gibs',11,'NASA GIBS - redistributable, carries the bulk of this');
bench('bench_esri',14,'Esri - what the real regions use, deliberately small');

engineStop() if engineRunning();

print "\nNote: the cache used here is under C:/_temp/base-apps-chartMaker/bench,\n";
print "so nothing above touched the real tile cache.\n";
