#!/usr/bin/perl
#---------------------------------------------
# test_set.pl -- headless test of dm_set.pm and the set-scoped dm_region
#---------------------------------------------
# HERMETIC.  It builds its whole data dir from nothing under C:/_temp and
# never reads anything of Patrick's, which is what lets it assert exact
# counts.  Every fixture is written inline, the way test_source.pl writes
# its own .tsd files.
#
# What it is actually pinning down:
#
#	the files present ARE the set          - a region appears by being copied in
#	ids are unique PER SET                 - the same id in two sets is two regions
#	selection degrades, never errors       - a deleted set falls through to another
#	checked is a view, not a membership    - and it does not leak between sets
#	nothing writes outside the active set  - saves land in the right folder

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_region;

my $TMP  = 'C:/_temp/dat-openCPN-chartMaker';
my $ROOT = "$TMP/sets_data";

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

sub regionJson
{
	my ($id,$name,$lat,$lon) = @_;
	my $d = 0.05;
	return <<"EOJ";
{
   "region_version" : 2,
   "id" : "$id",
   "name" : "$name",
   "zauthor" : 15,
   "zmin" : 10,
   "zmax" : 16,
   "geometry" : [ [ [ @{[$lon-$d]}, @{[$lat-$d]} ],
                    [ @{[$lon+$d]}, @{[$lat-$d]} ],
                    [ @{[$lon+$d]}, @{[$lat+$d]} ],
                    [ @{[$lon-$d]}, @{[$lat+$d]} ] ] ],
   "subregions" : []
}
EOJ
}

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/sets_temp";


#---------------------------------------------
# the folders make themselves
#---------------------------------------------

print "=== an empty data dir ===\n";

my $n = loadSets();
ok($n == 0,"an empty data dir has no sets (got $n)");
ok(-d "$ROOT/sources","sources/ was created");
ok(-d "$ROOT/region_sets","region_sets/ was created");
ok(getActiveSet() eq '',"no sets means no active set, not an error");

# A region cannot be saved with nowhere to put it, and that must be a
# clean refusal rather than a file written to a path built from ''.

my $made = newRegion('Nowhere',15,10,16,'Nowhere');
ok(!defined($made),"newRegion refuses when there is no active set");


#---------------------------------------------
# the files present are the set
#---------------------------------------------

print "\n=== a set is a folder ===\n";

ok(newSet('Panama'),"newSet('Panama')");
ok(setExists('Panama'),"the set exists after being made");
ok(getActiveSet() eq 'Panama',"a new set becomes the active one");

ok(!newSet('Bad Name'),"a set name with a space is refused");
ok(!newSet('Panama'),"a duplicate set name is refused");

# Copied in from outside, exactly as somebody would drop in a region a
# friend sent them.  Nothing is told about it; the scan is the whole of it.

putFile("$ROOT/region_sets/Panama/Bocas.region",
	regionJson('Bocas','Bocas del Toro',9.33,-82.24));
putFile("$ROOT/region_sets/Panama/PortBelo.region",
	regionJson('PortBelo','Portobelo',9.55,-79.65));

my $found = rescanRegions();
ok($found == 2,"two region files scanned into the set (got $found)");
ok(scalar(my @a = getRegionIds()) == 2,"getRegionIds sees both");
ok(getRegion('Bocas') && getRegion('Bocas')->{name} eq 'Bocas del Toro',
	"a region loaded by being present");

# The id is compared case insensitively because it is a Windows filename.

ok(getRegion('bocas'),"ids fold for lookup");


#---------------------------------------------
# ids are unique PER SET
#---------------------------------------------

print "\n=== two sets, the same id ===\n";

ok(newSet('Caribbean'),"newSet('Caribbean')");
ok(getActiveSet() eq 'Caribbean',"the new set is active");
my @b = getRegionIds();
ok(scalar(@b) == 0,"the new set is empty (got ".scalar(@b).")");

putFile("$ROOT/region_sets/Caribbean/Bocas.region",
	regionJson('Bocas','A DIFFERENT Bocas',9.40,-82.30));
rescanRegions();

my $other = getRegion('Bocas');
ok($other && $other->{name} eq 'A DIFFERENT Bocas',
	"the same id in another set is another region");

setActiveSet('Panama');
my $orig = getRegion('Bocas');
ok($orig && $orig->{name} eq 'Bocas del Toro',
	"switching back gives the first one again");


#---------------------------------------------
# switching sets is noticed without being told
#---------------------------------------------

print "\n=== the active set drives the model ===\n";

setActiveSet('Caribbean');
my @c = getRegionIds();
ok(scalar(@c) == 1,
	"changing the active set reloads the regions (got ".scalar(@c).")");
setActiveSet('Panama');
my @d = getRegionIds();
ok(scalar(@d) == 2,"and back again (got ".scalar(@d).")");


#---------------------------------------------
# checked is a view, and it is per set
#---------------------------------------------

print "\n=== checked ===\n";

ok(isChecked('Bocas'),"a region is shown by default");
my @e = getWorkingSet();
ok(scalar(@e) == 2,"both are shown (got ".scalar(@e).")");

setChecked('Bocas',0);
ok(!isChecked('Bocas'),"unchecking hides it");
my @f = getWorkingSet();
ok(scalar(@f) == 1,"the working set shrinks (got ".scalar(@f).")");
my @g = getRegionIds();
ok(scalar(@g) == 2,
	"but the SET is unchanged - hiding is not removing (got ".scalar(@g).")");
my @h = getUncheckedIds();
ok(scalar(@h) == 1,"getUncheckedIds reports it");

# The same id in the other set must not have been hidden too.

setActiveSet('Caribbean');
ok(isChecked('Bocas'),"the same id in another set is NOT hidden");
setActiveSet('Panama');
ok(!isChecked('Bocas'),"and the first one is still hidden");

setChecked('Bocas',1);
ok(isChecked('Bocas'),"checking shows it again");


#---------------------------------------------
# selection degrades rather than failing
#---------------------------------------------

print "\n=== a dangling selection ===\n";

setActiveSet('Nonesuch');
ok(getActiveSet() eq 'Caribbean',
	"a set that does not exist falls through to the first in tree order ".
	"(got '".getActiveSet()."')");

setActiveSet('Panama');
rmTree("$ROOT/region_sets/Panama");
rescanSets();
ok(getActiveSet() eq 'Caribbean',
	"deleting the active set's folder falls through (got '".getActiveSet()."')");
my @i = getRegionIds();
ok(scalar(@i) == 1,
	"and the model follows without being told (got ".scalar(@i).")");


#---------------------------------------------
# the source selection degrades the same way
#---------------------------------------------

print "\n=== the default source ===\n";

loadSources();
ok(getDefaultSource() eq '',"no sources means no default source");

my $TSD = <<'EOJ';
{
  "tsd_version": 1,
  "id": "ID_HERE",
  "name": "a test source",
  "kind": "remote_xyz",
  "url": "https://example.com/{z}/{x}/{y}.jpeg",
  "tile_format": "jpeg",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 12 },
  "attribution": "nobody",
  "license": "test",
  "redistributable": "no",
  "uses": ["display","build"]
}
EOJ

my $alpha = $TSD; $alpha =~ s/ID_HERE/aaa_first/;
my $weld  = $TSD; $weld  =~ s/ID_HERE/$DEFAULT_SOURCE_ID/;

putFile("$ROOT/sources/aaa.tsd",$alpha);
rescanSources();
ok(getDefaultSource() eq 'aaa_first',
	"with no official default present, the first in tree order wins ".
	"(got '".getDefaultSource()."')");

putFile("$ROOT/sources/weld.tsd",$weld);
rescanSources();
ok(getDefaultSource() eq $DEFAULT_SOURCE_ID,
	"the official default wins when it is there (got '".getDefaultSource()."')");

setDefaultSource('aaa_first');
ok(getDefaultSource() eq 'aaa_first',"an explicit choice beats both");

unlink("$ROOT/sources/aaa.tsd");
rescanSources();
ok(getDefaultSource() eq $DEFAULT_SOURCE_ID,
	"deleting the chosen source falls back rather than blanking the map");

setDefaultSource('never_existed');
ok(getDefaultSource() eq $DEFAULT_SOURCE_ID,
	"a remembered id that names nothing resolves to the default");


#---------------------------------------------
# writes land in the active set
#---------------------------------------------

print "\n=== writing ===\n";

my $new = newRegion('Made Here',15,10,16,'MadeHere');
ok($new,"newRegion in an active set");
ok(-f "$ROOT/region_sets/Caribbean/MadeHere.region",
	"the file was written INTO the active set's folder");
ok(!-f "$ROOT/MadeHere.region","and not into the data dir");

setRegionId('MadeHere','Renamed');
ok(-f "$ROOT/region_sets/Caribbean/Renamed.region","a rename writes the new leaf");
ok(!-f "$ROOT/region_sets/Caribbean/MadeHere.region","and removes the old one");

# Hiding must follow a rename, or a region reappears for no visible reason.

setChecked('Renamed',0);
setRegionId('Renamed','RenamedAgain');
ok(!isChecked('RenamedAgain'),"hidden survives a rename");

deleteRegion('RenamedAgain');
ok(!-f "$ROOT/region_sets/Caribbean/RenamedAgain.region","delete removes the file");
ok(!defined(getRegion('RenamedAgain')),"and the region is gone from the model");


print "\n".($fails ? "$fails TEST(S) FAILED" : "ALL PASSED")."\n";
exit($fails ? 1 : 0);
