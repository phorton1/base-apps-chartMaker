#!/usr/bin/perl
#---------------------------------------------
# test_fill.pl -- headless test of dm_fill.pm, the cache filler
#---------------------------------------------
# HERMETIC, and very nearly OFFLINE.  It builds its whole data dir under
# C:/_temp and pre-populates the cache itself, so the happy path never
# touches a network at all.
#
# THAT IS THE CENTRAL TRICK, not an optimisation.  Each node's tiles are
# planted in the cache under the source that node is SUPPOSED to resolve
# to, and the run is then asserted to be a 100% cache hit.  If source
# resolution were wrong in any way -- a subregion falling back to the
# region's source, inheritance not being followed, the id-to-node map
# shifted by one -- the tiles would be looked for under a source they were
# never planted under, and the run would try to fetch them.  So "cached ==
# tiles" is a much stronger statement than it looks.
#
# Only the abort section makes requests, and those are to a .invalid host
# (RFC 2606), which cannot resolve anywhere, ever.
#
# What it is pinning down:
#
#	the walk covers exactly what the build would enumerate
#	a region's source is used, and a subregion's own source overrides it
#	'inherited' resolves DOWNWARD and always terminates
#	a zmax cap prunes the walk arithmetically
#	a source naming nothing installed is SKIPPED, not fatal
#	a dead source aborts the run instead of hammering somebody's server

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
use dm_cache;
use dm_fetch;
use dm_engine;
use dm_fill;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/fill_data";

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
	my ($id,$url) = @_;
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "test source $id",
  "kind": "remote_xyz",
  "url": "$url",
  "tile_format": "jpeg",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "test",
  "uses": ["display","build"],
  "policy": { "max_concurrency": 1, "min_interval_ms": 0 }
}
EOJ
}

# A region with one subregion.  The polygon is deliberately tiny -- this
# test is about which source each node is fetched from, and a big polygon
# would only make it slower to say the same thing.

sub regionJson
	# $d sizes the box.  The source tests want it TINY, because they are
	# about which source a node resolves to and a big polygon only makes
	# them slower; the abort test wants it big enough that the region has
	# more tiles than the consecutive-failure limit, or the run would end
	# by finishing rather than by giving up and would prove nothing.
{
	my ($id,$src,$sub_src,$d) = @_;
	my ($lat,$lon) = (9.33,-82.24);
	$d ||= 0.15;
	my $ring = "[ [ @{[$lon-$d]}, @{[$lat-$d]} ], [ @{[$lon+$d]}, @{[$lat-$d]} ], ".
			   "[ @{[$lon+$d]}, @{[$lat+$d]} ], [ @{[$lon-$d]}, @{[$lat+$d]} ] ]";
	my $inner = "[ [ @{[$lon-$d/2]}, @{[$lat-$d/2]} ], [ @{[$lon+$d/2]}, @{[$lat-$d/2]} ], ".
				"[ @{[$lon+$d/2]}, @{[$lat+$d/2]} ], [ @{[$lon-$d/2]}, @{[$lat+$d/2]} ] ]";
	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "$id",
   "zauthor" : 12,
   "zmin" : 10,
   "zmax" : 12,
   "source" : "$src",
   "geometry" : [ $ring ],
   "subregions" : [
      {
         "id" : "Deep",
         "name" : "deep bit",
         "zmax" : 13,
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
$Pub::Utils::temp_dir = "$TMP/fill_temp";

loadSets();
putFile("$ROOT/sources/fill_a.tsd",tsd('fill_a','https://a.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/fill_b.tsd",tsd('fill_b','https://b.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/fill_dead.tsd",tsd('fill_dead','https://nothing.invalid/{z}/{x}/{y}.jpg'));
dm_source::rescanSources();

newSet('Fill');
putFile("$ROOT/region_sets/Fill/Alpha.region",regionJson('Alpha','fill_a','fill_b'));
putFile("$ROOT/region_sets/Fill/Beta.region",regionJson('Beta','fill_a','inherited'));
putFile("$ROOT/region_sets/Fill/Gamma.region",regionJson('Gamma','fill_a','no_such_source'));
putFile("$ROOT/region_sets/Fill/Dead.region",regionJson('Dead','fill_dead','inherited',0.5));
openSet('Fill');


#---------------------------------------------
# plant the cache
#---------------------------------------------
# The fake JPEG carries a real SOI marker because getTile checks the bytes
# it hands back, and a cache full of things that are not images would be
# testing the wrong failure.

my $JPEG = "\xFF\xD8\xFF".('x' x 64);

sub plant
	# Put every tile of one node into the cache under one source.
	# Returns how many were planted.
{
	my ($node,$src_id) = @_;
	my $src = getSource($src_id) or die "no source '$src_id'\n";
	my $n = 0;
	for my $z (keys %{$node->{levels}})
	{
		for my $key (keys %{$node->{levels}{$z}})
		{
			my ($x,$y) = split(/_/,$key);
			cachePutTile($src,$z,$x,$y,'jpeg',\$JPEG);
			$n++;
		}
	}
	return $n;
}

sub nodesOf
{
	my ($id,$opts) = @_;
	my ($cov,$nodes) = regionCoverageNodes(getRegion($id),$opts || {});
	return ($cov,$nodes);
}


#---------------------------------------------
# a subregion's own source overrides its region's
#---------------------------------------------

print "=== each node from its own source ===\n";

my ($cov_a,$nodes_a) = nodesOf('Alpha');
ok(scalar(@$nodes_a) == 2,"Alpha walks as two nodes (got ".scalar(@$nodes_a).")");
ok($nodes_a->[0]{depth} == 0 && $nodes_a->[1]{depth} == 1,
	"the region comes first, then its subregion");

my $planted = plant($nodes_a->[0],'fill_a') + plant($nodes_a->[1],'fill_b');
my $total_a = coverageTotal($cov_a);

# The planted count is per NODE and the coverage total is MERGED, so the
# two differ wherever a subregion's band overlaps its parent's levels.
# Only the merged number is what a build reads.

ok($planted >= $total_a,"planted $planted tiles across both nodes ($total_a merged)");

my $st = fillCoverage(['Alpha'],{ fallback => 'fill_a' });
ok($st->{tiles} == $total_a,
	"the walk visited every tile the build would ($st->{tiles} of $total_a)");
ok($st->{cached} == $st->{tiles},
	"EVERY tile was a cache hit - so every node used the source it names ".
	"($st->{cached} of $st->{tiles})");
ok($st->{error} == 0,"no errors");
ok($st->{absent} == 0,"nothing absent");
ok(!$st->{aborted},"not aborted");


#---------------------------------------------
# 'inherited' resolves downward
#---------------------------------------------

print "\n=== inherited resolves downward ===\n";

my ($cov_b,$nodes_b) = nodesOf('Beta');
plant($nodes_b->[0],'fill_a');
plant($nodes_b->[1],'fill_a');

# Beta's subregion says 'inherited', so it must resolve to Beta's OWN
# source rather than to the fallback.  Planting under fill_a and passing a
# DIFFERENT fallback is what makes that assertion mean something: if the
# chain fell through to the fallback instead of stopping at the region,
# these tiles would be looked for under fill_b and missed.

my $st_b = fillCoverage(['Beta'],{ fallback => 'fill_b' });
ok($st_b->{cached} == $st_b->{tiles} && $st_b->{tiles} > 0,
	"a subregion inherits its REGION's source, not the fallback ".
	"($st_b->{cached} of $st_b->{tiles})");


#---------------------------------------------
# the cap prunes the walk
#---------------------------------------------

print "\n=== a zmax cap prunes arithmetically ===\n";

my $st_cap = fillCoverage(['Alpha'],{ fallback => 'fill_a', zmax => 11 });
ok($st_cap->{tiles} < $total_a,
	"capping at z11 visits fewer tiles ($st_cap->{tiles} against $total_a)");
ok($st_cap->{error} == 0 && !$st_cap->{aborted},
	"and the capped run is clean - the z13 band simply never happens");


#---------------------------------------------
# a source naming nothing installed
#---------------------------------------------

print "\n=== an uninstalled source is skipped, not fatal ===\n";

my ($cov_g,$nodes_g) = nodesOf('Gamma');
plant($nodes_g->[0],'fill_a');

my $st_g = fillCoverage(['Gamma'],{ fallback => 'fill_a' });
ok($st_g->{cached} == $st_g->{tiles} && $st_g->{tiles} > 0,
	"the region's own tiles were still filled ($st_g->{tiles})");
ok(!$st_g->{aborted},"an uninstalled source on ONE node does not abort the run");
ok($st_g->{tiles} < coverageTotal($cov_g),
	"and the unresolvable node contributed nothing (".$st_g->{tiles}.
	" of ".coverageTotal($cov_g).")");


#---------------------------------------------
# a dead source stops rather than hammering
#---------------------------------------------
# The only section that touches a network.  .invalid cannot resolve, so
# every request fails locally and immediately.

print "\n=== a dead source aborts ===\n";

my $st_d = fillCoverage(['Dead'],{ fallback => 'fill_a' });
ok($st_d->{aborted},"a source that cannot be reached aborts the run");
ok($st_d->{error} >= 10,"after the consecutive-failure limit ($st_d->{error})");
ok($st_d->{tiles} < coverageTotal((nodesOf('Dead'))[0]),
	"having stopped well short of the whole region ($st_d->{tiles} tiles)");

# NOTHING WAS CACHED AS MISSING.  An error is not a fact about the source,
# so a run after the source comes back must fetch these rather than skip
# them -- this is what makes 'run it again' a real resume.

my $again = fillCoverage(['Dead'],{ fallback => 'fill_a' });
ok($again->{cached} == 0,"and cached no absences, so a retry really retries");


#---------------------------------------------
# a stopped run leaves nothing behind
#---------------------------------------------
# THE FILL KEEPS SEVERAL REQUESTS OUTSTANDING NOW, so stopping is no
# longer just "return early".  Every job it submitted holds a slot in the
# engine's shared result store until somebody collects it, and only the
# collect releases one - a worker has no idea whether anybody still wants
# what it fetched.  Walking away from the outstanding window therefore
# leaked a row per abandoned job, permanently, in the one structure whose
# whole claim is that nothing grows without bound.
#
# A cancel is an ordinary thing for a user to do, so this is not exotic:
# it is every cancelled fill, for as long as the application runs.

print "\n=== a stopped run collects what it already asked for ===\n";

# THE DEAD SOURCE ABOVE IS THE REAL CASE and needs no contrivance.  It
# aborts mid-walk with a full window of jobs already submitted, which is
# exactly the shape of a user cancelling: the decision to stop is taken
# while several requests are outstanding.  A stop flag set from this
# thread could not reproduce it, because with no pool the walk is
# synchronous and there is no moment at which to flip it.

my $stats = engineStats();
ok(($stats->{uncollected} // -1) == 0,
	"the aborted run left nothing uncollected (".
	($stats->{uncollected} // '?').")");
ok(!$stats->{inflight},
	"and holds no permits (in flight: ".($stats->{inflight} || 'none').")");


#---------------------------------------------
# a fetched tile is KEPT
#---------------------------------------------
# THE BUG THIS PINS COST A DAY AND WAS INVISIBLE.  When dm_fill stopped
# calling getTile and became a client of the engine, the sentinel check and
# the cache write stayed behind in getTile - so a fill fetched everything,
# wrote NOTHING, and a build's fill phase then handed the exporter an empty
# cache.  Every test here passed throughout, because they all plant the
# cache themselves and assert hits.
#
# So this asserts the opposite of everything above it: that something which
# was NOT planted and DID go out is on disk afterwards.  No network - the
# store is driven directly, which is the whole point of it being one
# function at one place rather than a step inside a fetch.

print "\n=== what goes out comes back to disk ===\n";

my $store_src = getSource('fill_a');
my $body      = "\xFF\xD8\xFF".('y' x 128);

ok(!cacheGet($store_src,9,7,7),"z9/7/7 is not in the cache to begin with");

my $stored = fetchStore($store_src,9,7,7,
	{ status => 'ok', format => 'jpeg', bytes => \$body, ms => 12 });
ok($stored->{status} eq 'ok',"a fetched tile is still reported ok");

my $back = cacheGet($store_src,9,7,7);
ok($back && $back->{status} eq 'ok',"and it IS on disk afterwards");
ok($back && ${$back->{bytes}} eq $body,"byte for byte what was fetched");

# AN ASSERTED ABSENCE IS KEPT TOO, and one derived from the TSD's own zoom
# range is not - it has no http code, costs nothing to recompute, and would
# go stale the moment the file changed.

fetchStore($store_src,9,7,8,{ status => 'absent', http => 404, ms => 9 });
my $miss = cacheGet($store_src,9,7,8);
ok($miss && $miss->{status} eq 'absent',"an absence the SOURCE asserted is kept");

fetchStore($store_src,9,7,9,{ status => 'absent', reason => 'out of range' });
ok(!cacheGet($store_src,9,7,9),
	"an absence derived from the .tsd's own range is NOT kept");

fetchStore($store_src,9,7,10,{ status => 'error', class => 'transport' });
ok(!cacheGet($store_src,9,7,10),"an error is never cached, so it can be retried");


print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
