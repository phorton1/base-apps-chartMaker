#!/usr/bin/perl
#---------------------------------------------
# t_region.pl -- headless test of dm_region.pm
#---------------------------------------------
# Imports the REAL coverage.kml from the old chartMaker into a scratch
# data dir.  The acceptance criterion is that the new model can express
# the five Panama regions, so that is what this tests.

use strict;
use warnings;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_region;

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

sub slurp
{
	my ($p) = @_;
	open(my $f,'<',$p) or return '';
	local $/; my $t = <$f>; close $f; return $t;
}


print "=== importing the real coverage.kml ===\n";
rescanRegions();
my @made = importKmlFile($KML,15);
ok(scalar(@made) == 5,"5 regions imported (got ".scalar(@made).": ".join(',',@made).")");

rescanRegions();
my @ids = getRegionIds();
ok(scalar(@ids) == 5,"5 regions load back from disk");

my $bocas = getRegion('BocasDelToro');
ok(defined($bocas),"BocasDelToro exists");
ok($bocas && scalar(@{$bocas->{geometry}}) == 2,
	"Bocas del Toro kept BOTH polygons (got ".
	($bocas ? scalar(@{$bocas->{geometry}}) : 0).")");

my $sanblas = getRegion('SanBlas');
ok($sanblas && scalar(@{$sanblas->{geometry}}) == 2,
	"San Blas kept BOTH polygons (got ".
	($sanblas ? scalar(@{$sanblas->{geometry}}) : 0).")");

my $total = 0;
$total += scalar(@{getRegion($_)->{geometry}}) for @ids;
ok($total == 7,"7 polygons across 5 regions, as in the KML (got $total)");

my $pts = 0;
$pts += regionPointCount(getRegion($_)) for @ids;
# The KML holds 91+13+49+118+83+5+39 = 398 points, each ring repeating its
# first point to close.  The model closes rings implicitly, so 7 go away.
ok($pts == 391,"391 points - 398 in the KML less one closing repeat per ring (got $pts)");

ok($bocas && $bocas->{name} eq 'Bocas del Toro',
	"the parenthesised display name was used (got '".($bocas?$bocas->{name}:'')."')");
ok($bocas && $bocas->{zauthor} == 15,"zauthor is 15");
ok($bocas && $bocas->{zmin} == 10 && $bocas->{zmax} == 16,
	"zmin 10, zmax 16 - the levels the region carries");
ok($bocas && $bocas->{id} eq 'BocasDelToro',
	"the KML's own CamelCase token became the id, not a flattened slug");


print "\n=== the saved file ===\n";
my $raw = slurp("$DIR/BocasDelToro.region");
ok($raw =~ /"zauthor" : 15/ ? 1 : 0,
	'zauthor is written as a JSON number');
ok($raw !~ /"zauthor" : "/ ? 1 : 0,'and is not quoted');
ok($raw =~ /"region_version" : 2/ ? 1 : 0,'written as region_version 2');
ok($raw !~ /canonical_zoom/ ? 1 : 0,'canonical_zoom is gone from the format');
ok($raw !~ /"-?\d+\.\d+"/ ? 1 : 0,'no coordinate is written as a quoted string');
ok($raw !~ /"file"/ ? 1 : 0,'the internal "file" field is not written to disk');


print "\n=== round trip ===\n";
my $before = JSON::PP->new->canonical->encode(
	{ map { $_ => getRegion($_)->{geometry} } @ids });
saveRegion(getRegion($_)) for @ids;
rescanRegions();
my $after = JSON::PP->new->canonical->encode(
	{ map { $_ => getRegion($_)->{geometry} } @ids });
ok($before eq $after,"geometry survives a save/reload round trip unchanged");


print "\n=== create, rename, delete ===\n";
my $new = newRegion('Test Bay',16);
ok($new && $new->{id} eq 'TestBay',"newRegion suggested id 'TestBay' from 'Test Bay'");
ok($new && scalar(@{$new->{geometry}}) == 0,"a new region has no geometry");
ok(!defined(newRegion('Test Bay')),"a duplicate id is refused");
ok(!defined(newRegion('Other','TESTBAY')),
	"and a duplicate differing only in CASE is refused too");
ok(renameRegion('TestBay','Renamed Bay'),"renameRegion succeeded");
rescanRegions();
ok(getRegion('TestBay')->{name} eq 'Renamed Bay',"the name changed");
ok(getRegion('TestBay')->{id} eq 'TestBay',"the id did NOT change");


print "\n=== setRegionId moves the file and the sets together ===\n";
setChecked('TestBay',1);
ok(setRegionId('TestBay','TB'),"setRegionId succeeded");
rescanRegions();
ok(!defined(getRegion('TestBay')) ? 1 : 0,"the old id resolves to nothing");
ok(defined(getRegion('TB')),"the new one resolves");
ok(-f "$DIR/TB.region" && !-f "$DIR/TestBay.region",
	"the file moved with it");
ok(isChecked('TB') ? 1 : 0,"and the set that named it followed - still checked");
ok(defined(getRegion('tb')),"lookup folds case");
ok(!setRegionId('TB','no good'),"an id with a space is refused");
ok(!setRegionId('TB','BocasDelToro'),"and one that collides is refused");
ok(!setRegionId('TB','BOCASDELTORO'),
	"including a collision that differs only in case");
setRegionId('TB','TestBay');
setChecked('TestBay',0);


print "\n=== the Popa00 detail area (the old DETAIL_AREAS entry) ===\n";
# capture.py: lat 9.334083, lon -82.242050, half_nm 0.5, zmin 17, zmax 18
# In this model that is ONE subregion with zmax 18.  It quantises its own
# polygon at 18 and takes parents back to the band floor of 17 -- there
# is no authored level and nothing is filled.
my $popa = addSubregion('BocasDelToro','Popa00',9.334083,-82.242050,0.5,18);
ok(defined($popa),"Popa00 added under BocasDelToro");
ok($popa && $popa->{zmax} == 18,"zmax 18 - its band is z17-18");
ok($popa && !exists($popa->{zauthor}),
	"a subregion has NO zauthor - it never cuts a reveal contour");

rescanRegions();
my $b2 = getRegion('BocasDelToro');
ok(scalar(@{$b2->{subregions}}) == 1,"it survived the reload");
my ($found,$parent) = findSubregion($b2,'Popa00');
ok(defined($found),"findSubregion locates it");
ok($parent && $parent->{id} eq 'BocasDelToro',"and reports the right parent");

my $box = $found->{geometry}[0];
ok(scalar(@$box) == 4,"the box has 4 corners");
my @lats = sort { $a <=> $b } map { $_->[1] } @$box;
my @lons = sort { $a <=> $b } map { $_->[0] } @$box;
my $hlat = ($lats[-1] - $lats[0]) * 60;
my $hlon = ($lons[-1] - $lons[0]) * 60 * cos(9.334083 * 3.14159265358979 / 180);
ok(abs($hlat - 1.0) < 0.001,sprintf("it is %.4f nm north-south",$hlat));
ok(abs($hlon - 1.0) < 0.001,sprintf("and %.4f nm east-west - square on the water",$hlon));

ok(scalar(@{getRegion('BocasDelToro')->{geometry}}) == 2,
	"the parent still has its two polygons");
ok(deleteSubregion('BocasDelToro','Popa00'),"deleteSubregion works");
rescanRegions();
ok(scalar(@{getRegion('BocasDelToro')->{subregions}}) == 0,"and it is gone");
addSubregion('BocasDelToro','Popa00',9.334083,-82.242050,0.5,18);


print "\n=== the working set ===\n";
ok(scalar(getWorkingSet()) == 0,"the working set starts empty");
setChecked('BocasDelToro',1);
setChecked('SanBlas',1);
ok(scalar(getWorkingSet()) == 2,"two regions checked");
ok(isChecked('BocasDelToro') ? 1 : 0,"bocas is checked");
ok(!isChecked('Portobelo') ? 1 : 0,"portobelo is not");
setChecked('BocasDelToro',0);
ok(scalar(getWorkingSet()) == 1,"unchecking removed it");

setDefaultSource('gibs_weld_annual');
ok(getDefaultSource() eq 'gibs_weld_annual',"default_source stored");
ok(-f "$DIR/workspace.json","workspace.json was written");

setChecked('TestBay',1);
ok(isChecked('TestBay') ? 1 : 0,"test_bay checked before deletion");
ok(deleteRegion('TestBay'),"deleteRegion succeeded");
rescanRegions();
ok(!defined(getRegion('TestBay')) ? 1 : 0,"the region is gone");
ok(!isChecked('TestBay') ? 1 : 0,
	"and its membership left with it - nothing to prune");
ok(scalar(getRegionIds()) == 5,"back to the 5 imported regions");


print "\n=== validation ===\n";
my @bad = (
	[ 'no_id',     '{"region_version":2,"name":"X","zauthor":15,"zmin":10,"zmax":16}' ],
	[ 'bad_zoom',  '{"region_version":2,"id":"a","name":"X","zauthor":99,"zmin":10,"zmax":16}' ],
	[ 'unknown',   '{"region_version":2,"id":"b","name":"X","zauthor":15,"zmin":10,'.
				   '"zmax":16,"bounds":[1]}' ],
	[ 'future',    '{"region_version":9,"id":"c","name":"X","zauthor":15,"zmin":10,"zmax":16}' ],
	[ 'short_poly','{"region_version":2,"id":"d","name":"X","zauthor":15,"zmin":10,'.
				   '"zmax":16,"geometry":[[[0,0],[1,1]]]}' ],
	[ 'bad_lat',   '{"region_version":2,"id":"e","name":"X","zauthor":15,"zmin":10,'.
				   '"zmax":16,"geometry":[[[0,0],[1,1],[2,88]]]}' ],
	[ 'spaced_id', '{"region_version":2,"id":"San Blas","name":"X","zauthor":15,'.
				   '"zmin":10,"zmax":16}' ],
	[ 'zauth_low', '{"region_version":2,"id":"f","name":"X","zauthor":9,"zmin":10,"zmax":16}' ],
	[ 'zauth_high','{"region_version":2,"id":"g","name":"X","zauthor":17,"zmin":10,"zmax":16}' ],
	[ 'sub_zauth', '{"region_version":2,"id":"h","name":"X","zauthor":15,"zmin":10,'.
				   '"zmax":16,"subregions":[{"id":"s","name":"S","zmax":18,"zauthor":17}]}' ],
	[ 'broken',    '{ not json' ],
);
for my $b (@bad)
{
	open(my $fh,'>',"$DIR/$b->[0].region"); print $fh $b->[1]; close $fh;
}
my $n = rescanRegions();
ok($n == 5,"all ".scalar(@bad)." invalid files refused, the 5 good ones still load (got $n)");
unlink "$DIR/$_->[0].region" for @bad;


print "\n=== a version 1 file is UPGRADED, not refused ===\n";
# Anyone's existing regions must keep loading.  Rejecting them would
# leave no way to fix them from inside the application.
open(my $v1,'>',"$DIR/old_style.region");
print $v1 '{"region_version":1,"id":"old_style","name":"Old Style",'.
		  '"canonical_zoom":14,"subregions":[{"id":"det","name":"Det",'.
		  '"canonical_zoom":16,"geometry":[[[0,0],[1,0],[1,1]]]}]}';
close $v1;
rescanRegions();
my $up = getRegion('OldStyle');
ok(defined($up),"a version 1 file with a legacy id still loads");
ok($up && $up->{id} eq 'OldStyle',"'old_style' was read as 'OldStyle'");
ok($up && $up->{zauthor} == 14,"canonical_zoom 14 became zauthor 14");
ok($up && $up->{zmin} == 10,"zmin defaulted to the old overview floor of 10");
ok($up && $up->{zmax} == 15,"zmax became canonical + 1 - the old one-level fill");
ok($up && $up->{subregions}[0]{zmax} == 17,
	"the subregion's canonical 16 became zmax 17, the same way");
ok($up && !exists($up->{subregions}[0]{zauthor}),
	"and it gained no zauthor");
deleteRegion('OldStyle');
rescanRegions();

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
