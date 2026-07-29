#!/usr/bin/perl
#---------------------------------------------
# t_fetch.pl -- headless test of dm_fetch + dm_cache
#---------------------------------------------
# Hits the real NASA GIBS endpoint.  This is the test that decides
# whether the shipped TSD's url template is actually right.

use strict;
use warnings;
use POSIX qw( floor );
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_source;
use dm_cache;
use dm_fetch;

my $TMP = 'C:/_temp/dat-openCPN-chartMaker';

$Pub::Utils::data_dir = "$TMP/tsd_good";
$Pub::Utils::temp_dir = "$TMP/fetch";

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub tileOf
	# lat/lon to tile x,y at zoom z -- web mercator, the fixed grid
{
	my ($lat,$lon,$z) = @_;
	my $n   = 2 ** $z;
	my $rad = $lat * 3.14159265358979 / 180;
	my $x   = floor(($lon + 180) / 360 * $n);
	my $y   = floor((1 - log(sin($rad)/cos($rad) + 1/cos($rad)) / 3.14159265358979) / 2 * $n);
	return ($x,$y);
}


rescanSources();
my $gibs = getSource('gibs_weld_annual');
die "no gibs source\n" if !$gibs;

# Bocas del Toro
my ($x,$y) = tileOf(9.33,-82.24,10);

# Start cold.  These assertions distinguish a network fetch from a cache
# hit, so leaving the previous run's entries in place makes the test pass
# or fail depending on whether it has been run before.

unlink("$TMP/fetch/cache/gibs/10/${x}_${y}.jpeg");
unlink("$TMP/fetch/cache/gibs/10/1023_1.none");

print "=== GIBS live fetch: Bocas del Toro at z10 = $x/$y ===\n";

my $r = getTile($gibs,10,$x,$y);
ok($r->{status} eq 'ok',
	"status is ok (got '$r->{status}'".
	(defined($r->{http}) ? ", http $r->{http}" : '').
	(defined($r->{reason}) ? ", $r->{reason}" : '').")");

if ($r->{status} eq 'ok')
{
	ok($r->{format} eq 'jpeg',"detected format is jpeg (got $r->{format})");
	ok(length(${$r->{bytes}}) > 1000,
		"tile is ".length(${$r->{bytes}})." bytes");
	ok(!$r->{cached},"first call was a network fetch");
	ok(defined($r->{ms}),"took $r->{ms} ms");

	my $path = "$TMP/fetch/cache/gibs/10/${x}_${y}.jpeg";
	ok(-f $path,"written to the cache at cache/gibs/10/${x}_${y}.jpeg");

	my $again = getTile($gibs,10,$x,$y);
	ok($again->{status} eq 'ok' && $again->{cached},"second call is a cache hit");
	ok(length(${$again->{bytes}}) == length(${$r->{bytes}}),
		"cached bytes are the same length");
}


print "\n=== outside the declared protocol range ===\n";
my $deep = getTile($gibs,13,$x,$y);
ok($deep->{status} eq 'absent',"z13 is absent (declared zoom.max is 12)");
ok(!defined($deep->{http}),"no http request was made");
ok(!-f "$TMP/fetch/cache/gibs/13/${x}_${y}.none",
	"a range-derived absence is NOT written to the cache");


print "\n=== a real absence, if the source gives one ===\n";
my $off = getTile($gibs,10,1023,1);
print "  z10/1023/1 -> $off->{status}".
	(defined($off->{http}) ? " (http $off->{http})" : '').
	(defined($off->{reason}) ? " - $off->{reason}" : '')."\n";
if ($off->{status} eq 'absent' && defined($off->{http}))
{
	ok(-f "$TMP/fetch/cache/gibs/10/1023_1.none",
		"a source-asserted absence IS written to the cache");
	my $again = getTile($gibs,10,1023,1);
	ok($again->{cached},"the absence is served from the cache next time");
}


print "\n=== cache stats ===\n";
my $stats = cacheStats($gibs);
print "  tiles=$stats->{total_tiles} misses=$stats->{total_misses} bytes=$stats->{total_bytes}\n";
print "  z$_: tiles=$stats->{zooms}{$_}{tiles} misses=$stats->{zooms}{$_}{misses}\n"
	for sort { $a <=> $b } keys %{$stats->{zooms}};
ok($stats->{total_tiles} >= 1,"cacheStats sees at least one tile");

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
