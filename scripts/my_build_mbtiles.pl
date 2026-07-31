#!/usr/bin/perl
#---------------------------------------------
# my_build_mbtiles.pl -- build ONE of Patrick's regions as mbtiles
#---------------------------------------------
# NEEDS PATRICK'S OWN DATA, which is what the 'my_' prefix means.  It reads
# the real data dir and the real cache and writes into the real mbtiles
# folder, because the whole point is a file OpenCPN can be pointed at.
#
# CACHE ONLY BY DEFAULT.  It runs the exporter directly rather than the
# build act, so nothing here can reach a network: a tile the cache does not
# hold is simply absent from the chart and counted.  Use 'build mbtiles'
# in the application when a fetch is actually wanted.
#
#	perl -I/base my_build_mbtiles.pl [region] [set]
#
# and it prints what it wrote, read back from the files themselves.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_cache;
use dm_region;
use dm_coverage;
use dm_mbtiles;

setStandardTempDir('chartMaker');
setStandardDataDir('chartMaker');

my $WANT_REGION = $ARGV[0] || 'Bocas';
my $WANT_SET    = $ARGV[1] || '';

loadSources();
loadSets();
my $set = $WANT_SET || getActiveSet();
openSet($set) or die "cannot open set '$set'\n";

my $reg = getRegion($WANT_REGION)
	or die "no region '$WANT_REGION' in set '$set'\n";

my $fallback = getDefaultSource() || 'esri_world_imagery';
my $ids  = regionSourceMap($reg,$fallback);
my $srcs = {};
for my $path (keys %$ids)
{
	my $src = getSource($ids->{$path})
		or die "node '$path' names source '$ids->{$path}', which is not installed\n";
	$srcs->{$path} = $src;
}

my $out = mbtilesDir()."/$set";
mkdir mbtilesDir() if !-d mbtilesDir();
mkdir $out         if !-d $out;

print "set      : $set\n";
print "region   : $WANT_REGION\n";
print "fallback : $fallback\n";
print "out      : $out/$WANT_REGION\n\n";

$dm_mbtiles::dbg_mbt = 0;

my $st = writeMbtiles($reg,$srcs,"$out/$WANT_REGION");
die "writeMbtiles failed\n" if !$st;

# READ BACK FROM THE FILES, not from the stats that wrote them.  What
# OpenCPN will see is the database, so that is what gets reported.

print "\n";
printf("%-22s %-9s %8s %14s  %s\n",'FILE','ZOOM','TILES','BYTES','BOUNDS');
for my $f (@{$st->{files}})
{
	my $info = mbtilesInfo($f->{path}) or next;
	printf("%-22s z%-2d-%-3d %8d %14d  %s\n",
		$info->{leaf},
		$info->{metadata}{minzoom},$info->{metadata}{maxzoom},
		$info->{tiles},$info->{bytes},$info->{metadata}{bounds});
}

printf("\n%d file(s), %d tiles, %d absent, %d failed, %.1f MB\n",
	$st->{blocks},$st->{tiles},$st->{absent},$st->{failed},
	$st->{size}/1048576);

if ($st->{failed})
{
	print "\nFAILED TILES (not in the cache - run a real build to fetch them):\n";
	print "  $_\n" for @{$st->{failed_tiles}}[0..($st->{failed} > 10 ? 9 : $st->{failed}-1)];
}

print "\npoint OpenCPN's chart directory at:\n  $out\n";
