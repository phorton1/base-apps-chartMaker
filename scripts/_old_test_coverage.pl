#!/usr/bin/perl
#---------------------------------------------
# t_coverage.pl -- headless test of dm_coverage.pm
#---------------------------------------------

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_region;
use dm_coverage;

my $TMP = 'C:/_temp/dat-openCPN-chartMaker';
my $DIR = "$TMP/regions";
my $KML = 'C:/dat/openCPN/chartMaker_old/masks/coverage.kml';

mkdir $DIR if !-d $DIR;
unlink glob("$DIR/*.region");
unlink "$DIR/workspace.json";
$Pub::Utils::data_dir = $DIR;

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_)."\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

rescanRegions();
importKmlFile($KML,15);
rescanRegions();
addSubregion('BocasDelToro','Popa00',9.334083,-82.242050,0.5,18);
rescanRegions();


print "=== the fixed grid ===\n";
my ($x,$y) = lonLatToTile(-82.24,9.33,10);
ok($x == 278 && $y == 485,"Bocas at z10 is tile 278/485 (got $x/$y)");

my ($w,$s,$e,$n) = tileBounds(10,278,485);
ok($w < -82.24 && $e > -82.24,sprintf("the tile spans that longitude (%.4f..%.4f)",$w,$e));
ok($s < 9.33 && $n > 9.33,sprintf("and that latitude (%.4f..%.4f)",$s,$n));

my ($x2,$y2) = lonLatToTile($w + ($e-$w)/2, $s + ($n-$s)/2, 10);
ok($x2 == 278 && $y2 == 485,"a tile's own centre maps back to it");


print "\n=== parents are the same set as re-intersecting ===\n";
# The claim the whole derivation rests on.  If it were false, coarse
# levels computed by walking up would disagree with coverage computed
# directly, and the two would differ exactly at region boundaries.
my $bocas = getRegion('BocasDelToro');
for my $z (11..14)
{
	my $direct  = dm_coverage::_quantise($bocas->{geometry},$z);
	my $derived = dm_coverage::_quantise($bocas->{geometry},15);
	$derived = dm_coverage::_parentsOf($derived) for ($z..14);

	my @only_direct  = grep { !$derived->{$_} } keys %$direct;
	my @only_derived = grep { !$direct->{$_} }  keys %$derived;
	ok(!@only_direct && !@only_derived,
		sprintf("z%d: %d tiles, identical both ways%s",$z,scalar(keys %$direct),
			(@only_direct || @only_derived) ?
				" (".scalar(@only_direct)." / ".scalar(@only_derived)." differ)" : ""));
}


print "\n=== zauthor..zmax is complete, not re-intersected ===\n";
# Completeness over the region's own band is not an optimisation.  The
# plotter cuts its reveal mask from the polygon at zauthor and paints at
# whatever level the view scale asks for, so every level the card
# carries must be a superset of the revealed set.
my $at15 = dm_coverage::_quantise($bocas->{geometry},15);
my $at16 = dm_coverage::_childrenOf($at15);
my $re16 = dm_coverage::_quantise($bocas->{geometry},16);
ok(scalar(keys %$at16) == 4 * scalar(keys %$at15),
	sprintf("zauthor z15 -> zmax z16 gives exactly 4x (%d -> %d)",
		scalar(keys %$at15),scalar(keys %$at16)));
ok(scalar(keys %$re16) < scalar(keys %$at16),
	sprintf("re-intersecting at z16 would give fewer (%d) - completeness is deliberate",
		scalar(keys %$re16)));
my @missing = grep { !$at16->{$_} } keys %$re16;
ok(!@missing,"and the complete set is a superset of what re-intersecting finds");


print "\n=== bands: a subregion supplies only what its parent does not ===\n";
my $cov = regionCoverage($bocas);
my $counts = coverageCounts($cov);
printf("  z%-2d %6d tiles\n",$_,$counts->{$_}) for sort { $a <=> $b } keys %$counts;

ok($counts->{17} && $counts->{18},"z17 and z18 exist - the Popa00 subregion");

# A SUBREGION IS NOT FILLED, it is authored at its own zmax.  Popa00
# quantises its polygon at z18 and takes PARENTS back down to the band
# floor, so z18 is at most 4x z17 and is strictly less wherever the box
# does not fill its parent tiles.  Filling from z17 instead would cost
# 4x z17 tiles to describe the same ground.
ok($counts->{18} <= 4 * $counts->{17},
	sprintf("z18 (%d) is at most 4x z17 (%d) - parents, not a fill",
		$counts->{18},$counts->{17}));
my $p17 = dm_coverage::_parentsOf(dm_coverage::_quantise($bocas->{subregions}[0]{geometry},18));
ok(scalar(keys %$p17) == $counts->{17},
	sprintf("z17 IS the parents of the z18 set (%d)",scalar(keys %$p17)));
ok($counts->{16} > $counts->{15},"z16 is the region's own zmax level");

# Popa00 is a 1 nm box reaching z18; it must NOT reach below z17
my $solo = regionCoverage({ %$bocas, subregions => [] });
my $solo_counts = coverageCounts($solo);
ok(!$solo_counts->{17},"without the subregion there is no z17 at all");
ok($solo_counts->{16} == $counts->{16},
	sprintf("the subregion adds NO z16 tiles (%d vs %d) - its band starts at z17",
		$solo_counts->{16},$counts->{16}));


print "\n=== the five Panama regions ===\n";
my $grand = 0;
for my $id (getRegionIds())
{
	my $c = regionCoverage(getRegion($id));
	my $t = coverageTotal($c);
	$grand += $t;
	my $cc = coverageCounts($c);
	printf("  %-16s %6d tiles   %s\n",$id,$t,
		join(' ',map { "z$_=$cc->{$_}" } sort { $a <=> $b } keys %$cc));
}
printf("  %-16s %6d tiles\n",'TOTAL',$grand);
ok($grand > 5000 && $grand < 60000,"the whole chartset is $grand tiles - a plausible build");


print "\n=== the predicate agrees with the enumerator ===\n";
my $hits = 0;
my $miss = 0;
for my $key (keys %{$cov->{15}})
{
	my ($tx,$ty) = split(/_/,$key);
	coverageHas($cov,15,$tx,$ty) ? $hits++ : $miss++;
}
ok($miss == 0,"every enumerated z15 tile answers yes to the predicate ($hits)");
ok(!coverageHas($cov,15,0,0),"and a tile off in the Atlantic answers no");

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
