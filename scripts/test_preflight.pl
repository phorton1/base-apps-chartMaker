#!/usr/bin/perl
#---------------------------------------------
# test_preflight.pl -- cm_config and dm_analysis, headless
#---------------------------------------------
# HERMETIC AND ENTIRELY OFFLINE.  It builds its own data dir under C:/_temp
# and plants its own cache; nothing here can reach a network, because
# nothing here is supposed to - the whole point of the analysis is that it
# answers before anything is committed to.
#
# What it is pinning down:
#
#	no file until somebody configures something, and none once reset
#	editing the configuration does NOT make the set dirty
#	'all selected' is stored as ALL, not as a list naming everything
#	a stale id in the file is dropped rather than breaking the set
#	the index scan agrees, tile for tile, with probing each tile
#	an advisory rate can only ever make you slower
#	the folder survey separates replace from leave-alone
#	disagreement is REPORTED, and it reads the folder as well as the set

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_config;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_rct;
use dm_observe;
use dm_analysis;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/pre_data";

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
	my ($id,$url,$interval) = @_;
	$interval ||= 0;
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
  "policy": { "max_concurrency": 1, "min_interval_ms": $interval }
}
EOJ
}

sub regionJson
{
	my ($id,$src,$sub_src,$zauthor) = @_;
	$zauthor ||= 12;
	my ($lat,$lon) = (9.33,-82.24);
	my $d = 0.15;
	my $ring = "[ [ @{[$lon-$d]}, @{[$lat-$d]} ], [ @{[$lon+$d]}, @{[$lat-$d]} ], ".
			   "[ @{[$lon+$d]}, @{[$lat+$d]} ], [ @{[$lon-$d]}, @{[$lat+$d]} ] ]";
	my $inner = "[ [ @{[$lon-$d/2]}, @{[$lat-$d/2]} ], [ @{[$lon+$d/2]}, @{[$lat-$d/2]} ], ".
				"[ @{[$lon+$d/2]}, @{[$lat+$d/2]} ], [ @{[$lon-$d/2]}, @{[$lat+$d/2]} ] ]";
	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "$id",
   "zauthor" : $zauthor,
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
$Pub::Utils::temp_dir = "$TMP/pre_temp";
rmTree("$TMP/pre_temp");
mkdir "$TMP/pre_temp";

loadSets();
putFile("$ROOT/sources/pre_a.tsd",tsd('pre_a','https://a.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/pre_b.tsd",tsd('pre_b','https://b.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/pre_slow.tsd",tsd('pre_slow','https://s.example.com/{z}/{x}/{y}.jpg',500));
dm_source::rescanSources();

newSet('Pre');
putFile("$ROOT/region_sets/Pre/Alpha.region",regionJson('Alpha','pre_a','pre_b'));
putFile("$ROOT/region_sets/Pre/Beta.region", regionJson('Beta', 'pre_a','pre_a'));
openSet('Pre');

my $CFG_FILE = "$ROOT/region_sets/Pre/build.json";


#---------------------------------------------
# the configuration file
#---------------------------------------------

print "=== no file until somebody configures something ===\n";

ok(!-f $CFG_FILE,"a fresh set has no build.json");

my $cfg = buildConfig();
ok(configIsDefault($cfg),"and its configuration reads as all-default");
ok(!defined($cfg->{regions}),"regions is undef, meaning ALL");
ok($cfg->{out_dir} eq '',"out_dir is empty, meaning the default");

my @sel = configSelectedIds($cfg);
ok(scalar(@sel) == 2,"which selects both regions (".join(',',@sel).")");

ok(defaultOutDir() eq "$ROOT/raster/Pre",
	"the default output folder is raster/<set> (".defaultOutDir().")");

# SAVING SOMETHING THAT SAYS NOTHING WRITES NOTHING.  The file is a record
# of what was CHANGED, exactly as chartMaker.prefs is.

saveBuildConfig($cfg);
ok(!-f $CFG_FILE,"saving an all-default configuration still writes no file");


print "\n=== a real selection persists ===\n";

$cfg->{regions} = ['Alpha'];
saveBuildConfig($cfg);
ok(-f $CFG_FILE,"selecting one region writes build.json");

my $back = buildConfig();
ok(join(',',@{$back->{regions} || []}) eq 'Alpha',"and it reads back");
ok(join(',',configSelectedIds($back)) eq 'Alpha',"selecting exactly that region");

# THE ONE THING THIS FILE'S PLACEMENT RESTS ON.  dm_region scans the folder
# for /\.region$/i and derives dirtiness from the .region leaves present,
# so build.json is invisible to both.  If that were ever not true, changing
# the output folder would mark the set dirty and the build would then
# refuse to run because the set is dirty - which is circular and would be
# maddening to diagnose.

ok(!isSetDirty(),"and writing it does NOT make the set dirty");
ok(scalar(getRegionIds()) == 2,"nor does the loader see it as a region");


print "\n=== ALL is not the same as a list naming everything ===\n";

$cfg->{regions} = undef;
saveBuildConfig($cfg);
ok(!-f $CFG_FILE,"going back to ALL removes the file again");

# The distinction that has to survive: a set with no selection builds whole
# and a region added later joins it; a deliberate subset must NOT silently
# acquire a region added next week.  Storing the list either way would
# collapse the two.

$cfg->{regions} = ['Alpha','Beta'];
saveBuildConfig($cfg);
my $both = buildConfig();
ok(defined($both->{regions}),"a list naming BOTH regions is still a list");
putFile("$ROOT/region_sets/Pre/Gamma.region",regionJson('Gamma','pre_a','pre_a'));
closeSet(); openSet('Pre');
ok(scalar(getRegionIds()) == 3,"a third region appears in the set");
ok(join(',',configSelectedIds(buildConfig())) eq 'Alpha,Beta',
	"and is NOT swept into the deliberate subset");

$cfg = buildConfig();
$cfg->{regions} = undef;
saveBuildConfig($cfg);
ok(scalar(configSelectedIds(buildConfig())) == 3,
	"whereas ALL picks it up automatically");


print "\n=== a stale id degrades quietly ===\n";

$cfg->{regions} = ['Alpha','NoSuchRegion'];
saveBuildConfig($cfg);
ok(join(',',configSelectedIds(buildConfig())) eq 'Alpha',
	"an id that no longer exists is dropped, not fatal");

$cfg->{regions} = undef;
saveBuildConfig($cfg);


#---------------------------------------------
# advisory rates
#---------------------------------------------

print "\n=== an advisory rate can only make you slower ===\n";

my $fast = getSource('pre_a')    or die "no pre_a\n";
my $slow = getSource('pre_slow') or die "no pre_slow\n";

ok(effectiveInterval($fast,undef) == 0,"an unpaced source with no advisory is 0");
ok(effectiveInterval($slow,undef) == 500,"a paced source keeps its declared 500");

my $rcfg = { rates => { pre_a => 200, pre_slow => 100 } };
ok(effectiveInterval($fast,$rcfg) == 200,"an advisory slows an unpaced source to 200");
ok(effectiveInterval($slow,$rcfg) == 500,
	"but CANNOT speed a paced one up - 100 against a declared 500 stays 500");


#---------------------------------------------
# the analysis
#---------------------------------------------

print "\n=== the index scan agrees with probing every tile ===\n";

my $JPEG = "\xFF\xD8\xFF".('x' x 64);

sub plant
{
	my ($id,$src,$sub_src,$skip) = @_;
	my (undef,$nodes) = regionCoverageNodes(getRegion($id),{});
	my %skip = map { $_ => 1 } @{$skip || []};
	my ($n,$i) = (0,0);
	my @left;
	for my $depth (0..$#$nodes)
	{
		my $node = $nodes->[$depth];
		my $s = getSource($depth ? $sub_src : $src) or next;
		for my $z (sort { $a <=> $b } keys %{$node->{levels}})
		{
			for my $key (sort keys %{$node->{levels}{$z}})
			{
				my ($x,$y) = split(/_/,$key);
				$i++;
				if ($skip{$i}) { push @left,[$s,$z,$x,$y]; next }
				cachePutTile($s,$z,$x,$y,'jpeg',\$JPEG);
				$n++;
			}
		}
	}
	return ($n,\@left);
}

my (undef,$gaps) = plant('Alpha','pre_a','pre_b',[2,9,20,33]);
ok(scalar(@$gaps) == 4,"planted Alpha with four deliberate gaps");

# Two of the gaps become RECORDED ABSENCES; two stay unknown.  That is the
# distinction the whole build rests on and the analysis must keep it.

cachePutMiss(@{$gaps->[0]});
cachePutMiss(@{$gaps->[1]});

my $an = analyseFetch(['Alpha'],{ fallback => 'pre_a' });
ok($an->{totals}{need} == 2,"two tiles need fetching ($an->{totals}{need})");
ok($an->{totals}{absent} == 2,"two are recorded absences ($an->{totals}{absent})");

# The naive answer, computed here the way cacheGet would, as the check on
# the fast one.  If these ever disagree the fast one is lying.

my ($p_need,$p_absent,$p_cached) = (0,0,0);
{
	my $srcs = regionSourceMap(getRegion('Alpha'),'pre_a');
	my (undef,$nodes) = regionCoverageNodes(getRegion('Alpha'),{});
	for my $node (@$nodes)
	{
		my $s = getSource($srcs->{$node->{path}}) or next;
		for my $z (keys %{$node->{levels}})
		{
			for my $key (keys %{$node->{levels}{$z}})
			{
				my ($x,$y) = split(/_/,$key);
				my $stem = cacheDir()."/$s->{cache_key}/$z/${x}_${y}";
				if    (-f "$stem.jpeg") { $p_cached++ }
				elsif (-f "$stem.none") { $p_absent++ }
				else                    { $p_need++   }
			}
		}
	}
}
ok($p_need == $an->{totals}{need} && $p_absent == $an->{totals}{absent} &&
   $p_cached == $an->{totals}{cached},
	"probing every tile gives the identical answer ($p_cached/$p_absent/$p_need)");


print "\n=== per source, because a set may use several ===\n";

ok(scalar(@{$an->{source_order}}) == 2,
	"Alpha's two nodes report as two sources (".
	join(',',@{$an->{source_order}}).")");
ok($an->{sources}{pre_b} && $an->{sources}{pre_b}{total} > 0,
	"the subregion's own source is counted separately");


print "\n=== the estimate is honest about what it does not know ===\n";

ok(!$an->{est_known} || $an->{totals}{need} == 0,
	"an unpaced source with no measurement offers NO time estimate");

my $al = analysisLines($an,'build');
ok(scalar(grep { /No time estimate yet/ } @$al),
	"and says so rather than inventing a number");

# A PACED SOURCE NEEDS NO MEASUREMENT - its declared floor is arithmetic.

closeSet();
putFile("$ROOT/region_sets/Pre/Delta.region",regionJson('Delta','pre_slow','pre_slow'));
openSet('Pre');
my $an2 = analyseFetch(['Delta'],{ fallback => 'pre_slow' });
ok($an2->{est_known},"a paced source CAN estimate with no measurement");
ok($an2->{secs_est} > 0,"and the estimate is its declared interval x the count ".
	sprintf("(%.0fs for %d tiles)",$an2->{secs_est},$an2->{totals}{need}));

obsRecordRate(getSource('pre_a'),300);
ok(obsMsPerTile(getSource('pre_a')) == 300,
	"a measured rate round-trips through the observation record");

# ONE MEASURED SOURCE IS NOT ENOUGH when the region uses two.  Alpha's
# subregion is built from pre_b and still has a tile to fetch, so the
# estimate must STILL refuse - a total that silently omitted the
# unmeasured source would be an underestimate presented as a fact.

my $an3 = analyseFetch(['Alpha'],{ fallback => 'pre_a' });
ok(!$an3->{est_known},
	"measuring only ONE of the two sources still offers no total");
ok($an3->{sources}{pre_a}{est_known} && !$an3->{sources}{pre_b}{est_known},
	"and it is per source - pre_a knows, pre_b does not");

obsRecordRate(getSource('pre_b'),300);
my $an3b = analyseFetch(['Alpha'],{ fallback => 'pre_a' });
ok($an3b->{est_known},"with both measured, the estimate is offered");


#---------------------------------------------
# the output folder survey
#---------------------------------------------

print "\n=== what is already in the output folder ===\n";

my $OUT = "$ROOT/raster/Pre";
mkdir "$ROOT/raster" if !-d "$ROOT/raster";
mkdir $OUT if !-d $OUT;

# Real cards, written by the real exporter - a hand-made file would prove
# only that the header reader agrees with the test's own idea of a header.

my $srcs_a = { map { $_ => getSource($_ eq 'Alpha' ? 'pre_a' : 'pre_b') }
			   keys %{regionSourceMap(getRegion('Alpha'),'pre_a')} };
writeRct(getRegion('Alpha'),$srcs_a,"$OUT/Alpha.rct");
my $srcs_b = { map { $_ => getSource('pre_a') }
			   keys %{regionSourceMap(getRegion('Beta'),'pre_a')} };
writeRct(getRegion('Beta'),$srcs_b,"$OUT/Beta.rct");

ok(-f "$OUT/Alpha.rct" && -f "$OUT/Beta.rct","two cards exist in the folder");

my $info = rctCardInfo("$OUT/Alpha.rct");
ok($info && $info->{zauthor} == 12,"a card's header reports its zauthor ".
	"($info->{zauthor})");
ok($info->{stem} eq 'Alpha',"and its stem ($info->{stem})");

my $an4 = analyseFetch(['Alpha'],{ fallback => 'pre_a', out_dir => $OUT });
ok(scalar(@{$an4->{overwrite}}) == 1,
	"building Alpha alone would REPLACE one card");
ok($an4->{overwrite}[0]{stem} eq 'Alpha',"and it is Alpha's");
ok(scalar(@{$an4->{foreign}}) == 1,
	"while one card in the folder is NOT part of this build");
ok($an4->{foreign}[0]{stem} eq 'Beta',"and it is Beta's");


print "\n=== disagreement is reported, and it reads the FOLDER too ===\n";

ok(!$an4->{zagree},"Alpha and the Beta card on disk agree, so nothing is said");

# THE CASE A CHECK ACROSS THE BUILD ALONE WOULD MISS.  Build one region
# with a new zauthor into a folder of cards built earlier: the regions
# being built agree perfectly with each other, because there is only one.

closeSet();
putFile("$ROOT/region_sets/Pre/Alpha.region",regionJson('Alpha','pre_a','pre_b',11));
openSet('Pre');

my $an5 = analyseFetch(['Alpha'],{ fallback => 'pre_a', out_dir => $OUT });
ok($an5->{zagree},"a lone region at a new zauthor DOES disagree with the folder");
ok($an5->{zagree}{zauthor},"and it is zauthor that differs");

my $an6 = analyseFetch(['Alpha'],{ fallback => 'pre_a' });
ok(!$an6->{zagree},
	"with no folder to compare against, one region cannot disagree with itself");


print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
