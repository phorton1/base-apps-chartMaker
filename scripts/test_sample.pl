#!/usr/bin/perl
#---------------------------------------------
# test_sample.pl -- headless test of dm_sample.pm, the probe
#---------------------------------------------
# HERMETIC, and offline except where a failure is the point.  It builds its
# whole data dir under C:/_temp and plants the cache itself.
#
# THE SUBJECT OF A PROBE IS A SOURCE, and most of what is asserted here is
# that the region contributes NOTHING to the answer except its polygons.
# The fixture is built to catch the old framing if it ever comes back: the
# region declares zauthor 12 / zmin 10 / zmax 12 and names source A, while
# the probe is run over it with source B across z9-z14.  Every one of those
# numbers is a trap, and a sampler that consulted any of them would sample
# the wrong levels or the wrong service and this would say so.
#
# What it is pinning down:
#
#	the region supplies polygons and NOTHING else
#	the probed source is the one asked for, never the assigned one
#	the range is the one asked for, never the region's band
#	a range wider than the .tsd is clamped, and the report says so
#	samples land inside the polygon at every level
#	a deep level is sampled WITHOUT being enumerated
#	min(num_samples, level size) reports all, not a sample
#	absent is counted and never confused with a failure
#	a REFUSAL and a SENTINEL are counted apart, and neither is 'found'
#	network failures never enter the ratio
#	a repeated body becomes a candidate fingerprint, ONCE
#	a halt leaves a smaller sample, not a broken one
#	EVERY run accumulates - another source, or the same one again
#	only Clear removes anything

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;
use cm_utils;
use cm_state;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_engine;
use dm_observe;
use dm_sample;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/sample_data";

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

sub tsd
{
	my ($id,$url,$zmin,$zmax,$fp) = @_;
	$zmin = 0  if !defined $zmin;
	$zmax = 19 if !defined $zmax;
	$fp = $fp ? qq(\n  "absent_fingerprints": [ $fp ],) : '';
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "test source $id",
  "url": "$url",
  "tile_format": "jpeg",
  "tile_size": 256,
  "crs": "EPSG:3857",$fp
  "zoom": { "min": $zmin, "max": $zmax },
  "attribution": "test",
  "uses": ["display","build"],
  "policy": { "max_concurrency": 1, "min_interval_ms": 0 }
}
EOJ
}

sub regionJson
{
	my ($id,$src,$sub_src,$d) = @_;
	my ($lat,$lon) = (9.33,-82.24);
	my $ring = "[ [ @{[$lon-$d]}, @{[$lat-$d]} ], [ @{[$lon+$d]}, @{[$lat-$d]} ], ".
			   "[ @{[$lon+$d]}, @{[$lat+$d]} ], [ @{[$lon-$d]}, @{[$lat+$d]} ] ]";
	my $inner = "[ [ @{[$lon-$d/4]}, @{[$lat-$d/4]} ], [ @{[$lon+$d/4]}, @{[$lat-$d/4]} ], ".
				"[ @{[$lon+$d/4]}, @{[$lat+$d/4]} ], [ @{[$lon-$d/4]}, @{[$lat+$d/4]} ] ]";

	# EVERY NUMBER IN HERE IS A TRAP.  A probe must ignore all of them.
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
         "id" : "Detail",
         "name" : "detail area",
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
$Pub::Utils::temp_dir = "$TMP/sample_temp";
rmTree("$TMP/sample_temp");

loadSets();
putFile("$ROOT/sources/samp_a.tsd",tsd('samp_a','https://a.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/samp_b.tsd",tsd('samp_b','https://b.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/samp_narrow.tsd",
	tsd('samp_narrow','https://n.example.com/{z}/{x}/{y}.jpg',8,11));
putFile("$ROOT/sources/samp_dead.tsd",tsd('samp_dead','https://nothing.invalid/{z}/{x}/{y}.jpg'));
dm_source::rescanSources();

newSet('Samp');
putFile("$ROOT/region_sets/Samp/Alpha.region",
	regionJson('Alpha','samp_a','samp_a',0.15));
putFile("$ROOT/region_sets/Samp/Wide.region",
	regionJson('Wide','samp_a','samp_a',0.6));
openSet('Samp');


#---------------------------------------------
# plant the cache
#---------------------------------------------
# A fake JPEG with a real SOI marker, since getTile checks the bytes it
# hands back.  Planted for source B over the levels the probe will ask for,
# which are NOT the levels the region declares.

my $JPEG = "\xFF\xD8\xFF".('x' x 9000);
my $FILL = "\xFF\xD8\xFF".('x' x 300);	# one repeated body, for fingerprints

sub plantLevel
{
	my ($src_id,$polys,$z,$bytes) = @_;
	my $src = getSource($src_id) or die "no source '$src_id'\n";
	my $set = coverageQuantise($polys,$z);
	my $n = 0;
	for my $key (keys %$set)
	{
		my ($x,$y) = split(/_/,$key);
		cachePutTile($src,$z,$x,$y,'jpeg',\$bytes);
		$n++;
	}
	return $n;
}

my ($polys,$label) = sampleScope('Alpha');
ok($polys && @$polys,"sampleScope resolved 'Alpha' to polygons");
ok($label eq 'Alpha',"and labelled it 'Alpha'");

# A PATH OR A BARE ID.  The map knows the full path it walked; the tree
# carries only the node's own id.  An id is unique within a whole region by
# validation, so both are unambiguous and both surfaces must work.

my ($sp) = sampleScope({ region => 'Alpha', sub => 'Alpha/Detail' });
ok($sp && @$sp,"a subregion resolves by full path");
my ($sb) = sampleScope({ region => 'Alpha', sub => 'Detail' });
ok($sb && @$sb,"and by bare id, which is all the tree has");
ok($sp->[0][0][0] == $sb->[0][0][0],"both find the same polygons");
my ($no) = sampleScope({ region => 'Alpha', sub => 'NoSuchNode' });
ok(!$no,"a name that is not there resolves to nothing");

# THE BAND IS WHAT THE DIALOG OPENS ON, and it is the levels the node will
# actually be BUILT at - not a preference, and not the source's declared
# range, which is the one number a probe exists not to trust.
#
# The fixture region declares zmin 10 / zauthor 12 / zmax 12, and its 'Detail'
# subregion declares zmax 13.  So the subregion's band is 13..13 - it starts
# where its parent's zmax leaves off, which is the whole reason a subregion
# carries only a zmax.

my ($blo,$bhi) = sampleBand('Alpha');
ok($blo == 10 && $bhi == 12,
	"a region's band is its own zmin..zmax (got z$blo-$bhi)");

my ($slo,$shi) = sampleBand({ region => 'Alpha', sub => 'Detail' });
ok($slo == 13 && $shi == 13,
	"a subregion's band starts above its PARENT's zmax (got z$slo-$shi)");

my @none = sampleBand({ region => 'Alpha', sub => 'NoSuchNode' });
ok(!@none,"and a node that is not there has no band at all");

# NOTHING ABOUT THE BAND REACHES THE SAMPLER.  It is a default for a dialog;
# what gets probed is what the caller asked for, and this is the assertion
# that stops the two quietly becoming one.
my $wide = sampleService('samp_b','Alpha',{ zmin => 9, zmax => 14 });
ok(scalar(grep { $_->{z} == 9 } @{$wide->{rows}}),
	"a run asked for z9 still samples z9, below the region's band");

my $planted = 0;
$planted += plantLevel('samp_b',$polys,$_,$JPEG) for (9..14);
ok($planted > 0,"planted $planted tiles for samp_b over z9-z14");


#---------------------------------------------
# the region supplies polygons and nothing else
#---------------------------------------------

print "\n=== the source is the subject ===\n";

my $r = sampleService('samp_b','Alpha',{ zmin => 9, zmax => 14 });

ok(!$r->{cancelled},"the run finished");
ok($r->{source} eq 'samp_b',"it probed the source it was ASKED for");
ok($r->{totals}{failed} == 0,
	"nothing went to the network ($r->{totals}{failed} failures)");
ok($r->{totals}{found} > 0,"it found $r->{totals}{found} tiles");

my %rows = map { $_->{z} => $_ } @{$r->{rows}};

# THE TRAP.  The region says zauthor 12, zmin 10, zmax 12 and names samp_a.
# A probe that consulted ANY of that would have sampled z10-z12 from samp_a
# and every one of these would fail.

ok($rows{9} && $rows{14},
	"it sampled the range it was asked for, z9 and z14 included");
ok(!$rows{15},"and not past it");
ok($rows{10}{source} eq 'samp_b',"every row names the probed source");
ok(scalar(grep { $_->{source} ne 'samp_b' } @{$r->{rows}}) == 0,
	"no row came from the region's assigned source");


#---------------------------------------------
# clamping to what the file declares
#---------------------------------------------

print "\n=== the file's range is NOT a ceiling ===\n";

# A .tsd can lie in both directions - promising more than the service
# delivers, and hiding depth it actually has.  Clamping to zoom.max would
# answer the FILE, which is the one answer nobody needs because it is
# already written in the file.  samp_narrow declares z8-11.

my $n = sampleService('samp_narrow','Alpha',{ zmin => 2, zmax => 18 });
my @nz = sort { $a <=> $b } map { $_->{z} } @{$n->{rows}};
ok(@nz && $nz[0] == 2 && $nz[-1] == 18,
	"a range wider than the .tsd is asked ANYWAY (got z$nz[0]-z$nz[-1])");
ok($n->{note} =~ /past the file's declared z8-11/,
	"and the report says it went past what the file declares");

# The widening must not leak: the source is copied, so nothing that
# identifies it - the id the engine gates on, the cache key - changes.
ok(getSource('samp_narrow')->{zoom}{max} == 11,
	"the installed source still declares z11 afterwards");


#---------------------------------------------
# samples land inside the polygon
#---------------------------------------------

print "\n=== every sample is inside the area ===\n";

# MEETS the polygon, not CONTAINS ITS CENTRE.  A tile at a coarse level is
# larger than a small area and covers it without its centre being anywhere
# near it, so the centre test would report the correct answer as wrong -
# which is exactly the bug this assertion was written with.

my $outside = 0;
for my $mark (@{$r->{marks}})
{
	my ($z,$x,$y,$outcome) = split(/\//,$mark);
	$outside++ if !coverageTileHits($polys,$z,$x,$y);
}
ok($outside == 0,"every sampled tile meets the polygon ($outside did not)");


#---------------------------------------------
# a deep level without enumerating it
#---------------------------------------------

print "\n=== z19 without enumerating z19 ===\n";

my ($wide) = sampleScope('Wide');
my ($set,$az) = dm_sample::_strataFor($wide,19,24);
ok($az < 19,"strata for z19 sit at z$az, above the sample level");
ok(scalar(keys %$set) >= 24,
	"the descent stopped once it had enough cells (".scalar(keys %$set).")");

my ($tiles,$exhaustive) = dm_sample::_tilesFor($wide,19,24);
ok(scalar(@$tiles) > 0 && scalar(@$tiles) <= 24,
	"it drew ".scalar(@$tiles)." tiles at z19");
ok(!$exhaustive,"and reports a sample rather than the whole level");


#---------------------------------------------
# all, versus sampled
#---------------------------------------------

print "\n=== all, not sampled ===\n";

my $z9 = $rows{9};
my $z9set = coverageQuantise($polys,9);
ok($z9->{exhaustive},"z9 holds fewer tiles than the sample count, so it is 'all'");
ok($z9->{samples} <= scalar(keys %$z9set),
	"and it asked about no more than the level holds ".
	"($z9->{samples} of ".scalar(keys %$z9set).")");


#---------------------------------------------
# absent is not failure
#---------------------------------------------

print "\n=== an absence and a failure are different things ===\n";

# samp_a has nothing planted at all, and its url does not resolve, so every
# request FAILS.  Those must not be counted as absences.

my $d = sampleService('samp_dead','Alpha',{ zmin => 9, zmax => 9 });
ok($d->{totals}{failed} > 0,"the dead host failed ($d->{totals}{failed} times)");
ok($d->{totals}{absent} == 0,"and not one failure was counted as an absence");
ok($d->{totals}{found} == 0,"nor as imagery");
ok($d->{totals}{samples} == 0,"the sample count excludes them");
ok(!@{$d->{marks}},"and a failure leaves no mark on the map");

my $dl = sampleLines($d);
ok(scalar(grep { /FAILED/ } @$dl),"the report names the failures separately");


#---------------------------------------------
# a repeated body is a candidate fingerprint
#---------------------------------------------

print "\n=== a repeated body is offered, never acted on ===\n";

my ($apolys) = sampleScope('Alpha');
plantLevel('samp_a',$apolys,9,$FILL);
plantLevel('samp_a',$apolys,10,$FILL);

my $f = sampleService('samp_a','Alpha',{ zmin => 9, zmax => 10 });
ok($f->{totals}{found} > 0,"the fill tiles were found ($f->{totals}{found})");

my $cand = obsField(getSource('samp_a'),'fp_candidates') // '';
ok($cand =~ /^\d+:[0-9a-f]+$/,
	"a candidate fingerprint was recorded as bytes:md5 ($cand)");
ok(scalar(grep { length } split(/,/,$cand)) == 1,
	"exactly one entry, however many times the body was seen");

# NEVER ACTED ON.  The tiles are still imagery as far as everything else is
# concerned; only a person editing the .tsd can change that.
ok($f->{totals}{absent} == 0,
	"and the repeated body was NOT turned into an absence");


#---------------------------------------------
# a refusal and a sentinel are two findings
#---------------------------------------------

print "\n=== a sentinel is not a refusal ===\n";

# THE WHOLE POINT.  A 404 is a service saying it has nothing here.  A 200
# carrying its declared 'no data' body is a service DECLINING to say so, and
# nobody knows that at all unless somebody fingerprinted the body - so
# folding the two into one 'absent' throws away the finding that a candidate
# evaluation most needs.
#
# THE FIXTURE IS THE HARD CASE ON PURPOSE.  The tiles are planted as ordinary
# IMAGES in the cache, which is exactly the state a cache is in when a
# fingerprint is declared after the fact.  A probe reading the cache without
# asking dm_fetch what a hit means reports every one of these as FOUND, which
# is not a smaller answer than the truth but the opposite of it.

require Digest::MD5;
my $fp_md5 = Digest::MD5::md5_hex($FILL);
putFile("$ROOT/sources/samp_sent.tsd",
	tsd('samp_sent','https://s.example.com/{z}/{x}/{y}.jpg',0,19,
		qq({ "bytes": @{[length($FILL)]}, "md5": "$fp_md5" })));
dm_source::rescanSources();

my $ssrc = getSource('samp_sent');
ok($ssrc && @{$ssrc->{absent_fingerprints} || []} == 1,
	"samp_sent declares one absent_fingerprint");

plantLevel('samp_sent',$apolys,9,$FILL);		# the declared no-data body
plantLevel('samp_sent',$apolys,10,$JPEG);		# ordinary imagery

my $s = sampleService('samp_sent','Alpha',{ zmin => 9, zmax => 10 });
my %srows = map { $_->{z} => $_ } @{$s->{rows}};

ok($srows{9} && $srows{9}{sentinel} > 0,
	"z9 counted ".($srows{9}{sentinel} // 0)." no-data bodies");
ok($srows{9}{found} == 0,
	"and NOT one of them as imagery, though they were cached as images");
ok($srows{9}{absent} == 0,
	"nor as a refusal, which is a different finding about the service");
ok($srows{10}{found} > 0 && $srows{10}{sentinel} == 0,
	"real imagery at z10 is untouched by any of it");

ok(scalar(grep { m{^9/\d+/\d+/sentinel/} } @{$s->{marks}}) > 0,
	"the map is handed a 'sentinel' mark, not an 'absent' one");
ok(scalar(grep { m{/absent/} } @{$s->{marks}}) == 0,
	"and no absent mark at all");

# THE CACHE CONVERGES, so the second probe is as right as the first and does
# not have to decode anything to be.
my $again_sent = cacheGet($ssrc,9,(split(/_/,(keys %{coverageQuantise($apolys,9)})[0])));
ok($again_sent && $again_sent->{status} eq 'absent',
	"the reclassified tile is a .none in the cache now");
ok($again_sent->{sentinel},
	"and the marker remembers WHICH KIND of nothing it was");

my $sl = sampleLines($s);
ok(scalar(grep { /declared 'no data' image/ } @$sl),
	"the report says it answers with a blank rather than refusing");
ok(scalar(grep { /no-data/ } @$sl),
	"and the table has its own column for it");


#---------------------------------------------
# a halt leaves a smaller sample
#---------------------------------------------

print "\n=== halt ===\n";

probeClearStop();
my $seen = 0;
my $c = sampleService('samp_b','Alpha',{
	zmin => 9, zmax => 14,
	publish => sub { $seen++; probeRequestStop() if $seen >= 2 } });

ok($c->{cancelled},"the run reports that it was halted");
ok(scalar(@{$c->{rows}}) == 2,
	"it kept the rows it had finished (got ".scalar(@{$c->{rows}}).")");
ok($c->{totals}{found} > 0,"and their counts are still true");
ok(scalar(grep { /HALTED/ } @{sampleLines($c)}),"the report says so, first");

probeClearStop();
my $again = sampleService('samp_b','Alpha',{ zmin => 9, zmax => 10 });
ok(!$again->{cancelled},"a cleared stop does not carry into the next run");


#---------------------------------------------
# several sources accumulate
#---------------------------------------------

print "\n=== the mode holds several sources ===\n";

probeReset();
probeBeginSource('samp_a');
probeAddUnit('samp_a','row one',['9/1/1/found']);
probeEndSource('samp_a','done a');
probeBeginSource('samp_b');
probeAddUnit('samp_b','row two',['9/2/2/absent']);
probeEndSource('samp_b','done b');

my $srcs = probeSources();
ok(scalar(@$srcs) == 2,"two sources are held at once");
ok($srcs->[0]{id} eq 'samp_a' && $srcs->[1]{id} eq 'samp_b',
	"in the order they were first probed");
ok(scalar(@{probeMarkList()}) == 2,"both sets of marks are present");
ok(scalar(grep { /^samp_a / } @{probeMarkList()}) == 1,
	"and each mark names its source");

# A RE-RUN ADDS, IT DOES NOT REPLACE.  Selection draws different points
# every time, so a second run of one source over the same ground is more of
# the same sample rather than a repeat of it - which is the whole reason to
# run it twice, and dropping the first run threw exactly that away.

probeBeginSource('samp_a');
probeAddUnit('samp_a','row three',['9/3/3/found']);
ok(scalar(@{probeSources()}) == 2,
	"re-probing one source does not add a second entry for it");
ok(scalar(grep { /^samp_a / } @{probeMarkList()}) == 2,
	"but its earlier marks are KEPT and the new ones join them");
ok(scalar(grep { /^samp_b / } @{probeMarkList()}) == 1,
	"and the other source's are untouched either way");
ok(scalar(@{probeMarkList()}) == 3,"nothing a run does removes anything");

probeReset();
ok(scalar(@{probeMarkList()}) == 0 && scalar(@{probeSources()}) == 0,
	"Clear is the only thing that takes anything away");

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
