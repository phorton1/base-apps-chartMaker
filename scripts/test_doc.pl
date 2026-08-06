#!/usr/bin/perl
#---------------------------------------------
# test_doc.pl -- headless test of the SET AS A DOCUMENT
#---------------------------------------------
# HERMETIC.  It builds its whole data dir from nothing under C:/_temp and
# never reads anything of Patrick's, in the style of test_set.pl.
#
# What it is actually pinning down:
#
#	only Save writes            - editing, creating and deleting touch no file
#	kill is a real choice       - a mutated document closed without saving
#	                              leaves the folder byte for byte identical
#	dirty is derived            - a created or deleted region makes the SET
#	                              dirty without making any region dirty
#	revert has two meanings     - back to disk, or gone if never written
#	commit is a partial save    - one file written, the rest still dirty
#	Save reconciles the folder  - a deleted region's file goes, and a file
#	                              that appeared underneath us does not

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_region;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/doc_data";

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
   "region_version" : 1,
   "id" : "$id",
   "name" : "$name",
   "zauthor" : 15,
   "zmin" : 10,
   "zmax" : 16,
   "geometry" : [ [ [ $lon, $lat ], [ @{[$lon+$d]}, $lat ],
                    [ @{[$lon+$d]}, @{[$lat+$d]} ], [ $lon, @{[$lat+$d]} ] ] ],
   "subregions" : []
}
EOJ
}

# The state of a folder, as bytes: what "the fixture was not touched"
# actually means.

sub folderState
{
	my ($dir) = @_;
	my %state;
	opendir(my $dh,$dir) or return \%state;
	for my $leaf (sort grep { /\.region$/ } readdir($dh))
	{
		open(my $fh,'<',"$dir/$leaf") or next;
		local $/;
		$state{$leaf} = <$fh>;
		close $fh;
	}
	closedir $dh;
	return \%state;
}

sub sameFolder
{
	my ($a,$b) = @_;
	return 0 if scalar(keys %$a) != scalar(keys %$b);
	for my $leaf (keys %$a)
	{
		return 0 if !defined $b->{$leaf};
		return 0 if $a->{$leaf} ne $b->{$leaf};
	}
	return 1;
}

rmTree($ROOT);
mkdir($ROOT)					or die "cannot create $ROOT";
mkdir("$ROOT/sources")			or die "cannot create sources";
mkdir("$ROOT/region_sets")		or die "cannot create region_sets";
mkdir("$ROOT/region_sets/Fix")	or die "cannot create the Fix set";

putFile("$ROOT/region_sets/Fix/Alpha.region",regionJson('Alpha','Alpha Bay',9.3,-82.2));
putFile("$ROOT/region_sets/Fix/Beta.region", regionJson('Beta', 'Beta Sound',9.5,-82.0));

$Pub::Utils::data_dir = $ROOT;
my $DIR = "$ROOT/region_sets/Fix";

loadSets();


#---------------------------------------------
# open
#---------------------------------------------

print "\n--- opening\n";

my $before = folderState($DIR);

ok(openSet('Fix') == 2,			"opening a set loads its regions");
ok(setIsOpen(),					"and the document is open");
ok(openSetName() eq 'Fix',		"under the name it was opened by");
ok(!isSetDirty(),				"a freshly opened set is clean");


#---------------------------------------------
# editing writes nothing
#---------------------------------------------

print "\n--- editing\n";

ok(renameRegion('Alpha','Renamed'),		"a region can be renamed");
ok(isRegionDirty('Alpha'),				"which makes that region dirty");
ok(isSetDirty(),						"and the set with it");
ok(!isRegionDirty('Beta'),				"the region nobody touched is not");
ok(sameFolder($before,folderState($DIR)),	"NOTHING was written to disk");

my @dirty = dirtyRegionIds();
ok(scalar(@dirty) == 1 && $dirty[0] eq 'Alpha',	"and dirty names exactly it");


#---------------------------------------------
# revert one
#---------------------------------------------

print "\n--- reverting one region\n";

ok(revertRegion('Alpha') eq 'reverted',	"reverting a saved region reverts it");
ok(getRegion('Alpha')->{name} eq 'Alpha Bay',	"back to what is on disk");
ok(!isRegionDirty('Alpha'),				"and it is clean");
ok(!isSetDirty(),						"leaving the set clean");


#---------------------------------------------
# commit one, with another dirty
#---------------------------------------------

print "\n--- committing one region\n";

renameRegion('Alpha','Committed');
renameRegion('Beta','Still Dirty');
ok(commitRegion('Alpha'),				"one region can be written on its own");
ok(!isRegionDirty('Alpha'),				"which cleans that one");
ok(isRegionDirty('Beta'),				"and leaves the other dirty");
ok(isSetDirty(),						"so the set is still dirty");

my $now = folderState($DIR);
ok($now->{'Alpha.region'} =~ /Committed/,	"the committed file has the change");
ok($now->{'Beta.region'} !~ /Still Dirty/,	"the uncommitted one does not");


#---------------------------------------------
# create and delete are set-level dirt
#---------------------------------------------

print "\n--- creating and deleting\n";

saveSet();
ok(!isSetDirty(),						"saving cleans the set");

ok(newRegion('Gamma Cove',15,10,16,'Gamma'),	"a region can be created");
ok(isRegionDirty('Gamma'),				"which is dirty - none of it is on disk");
ok(isSetDirty(),						"and the set with it");
ok(!-f "$DIR/Gamma.region",				"and nothing was written");

ok(revertRegion('Gamma') eq 'removed',	"reverting a region never saved removes it");
ok(!getRegion('Gamma'),					"so it is gone from the model");
ok(!isSetDirty(),						"and the set is clean again");

newRegion('Gamma Cove',15,10,16,'Gamma');
ok(saveSet(),							"saving writes the new region");
ok(-f "$DIR/Gamma.region",				"whose file now exists");

ok(deleteRegion('Gamma'),				"a region can be deleted");
ok(-f "$DIR/Gamma.region",				"whose file is still there");
ok(isSetDirty(),						"with the set dirty until saved");
ok(saveSet(),							"saving reconciles the folder");
ok(!-f "$DIR/Gamma.region",				"and the file is gone");


#---------------------------------------------
# a file that appeared underneath us
#---------------------------------------------

print "\n--- somebody else's file\n";

putFile("$DIR/Stranger.region",regionJson('Stranger','Not Ours',9.9,-81.5));
renameRegion('Alpha','Touched Again');
ok(saveSet(),							"saving over a folder that grew a file");
ok(-f "$DIR/Stranger.region",			"leaves the file it never opened alone");
unlink("$DIR/Stranger.region");


#---------------------------------------------
# THE POINT: closing without saving changes nothing
#---------------------------------------------

print "\n--- killing the session\n";

my $sealed = folderState($DIR);

renameRegion('Alpha','Thrown Away');
newRegion('Delta Reef',15,10,16,'Delta');
deleteRegion('Beta');
ok(isSetDirty(),						"a session's worth of changes is dirty");

closeSet();
ok(!setIsOpen(),						"closing leaves nothing open");
ok(!isSetDirty(),						"and nothing dirty");
ok(sameFolder($sealed,folderState($DIR)),
	"THE FOLDER IS BYTE FOR BYTE WHAT IT WAS - the fixture survived");

ok(openSet('Fix') == 2,					"reopening finds what was on disk");
ok(getRegion('Alpha')->{name} ne 'Thrown Away',	"without the discarded edit");
ok(!getRegion('Delta'),					"without the discarded creation");
ok(getRegion('Beta'),					"and with the region that was deleted");


#---------------------------------------------
# save as
#---------------------------------------------

print "\n--- save as\n";

renameRegion('Alpha','In The Copy');
ok(saveSetAs('Copy'),					"a set can be saved under a new name");
ok(openSetName() eq 'Copy',				"which becomes the open one");
ok(!isSetDirty(),						"clean, having just been written");
ok(-f "$ROOT/region_sets/Copy/Alpha.region",	"every region is in the new folder");
ok(-f "$ROOT/region_sets/Copy/Beta.region",		"including the ones not edited");

openSet('Fix');
ok(getRegion('Alpha')->{name} ne 'In The Copy',
	"and the set it came from was left as it was");


#---------------------------------------------
# the build source
#---------------------------------------------
# LAST, because it writes to the fixture -- every assertion about the
# folder surviving untouched has already run by here.

print "\n--- the build source\n";

# The fixtures carry no source at all, which is what a hand written file
# looks like.  A REGION MAY NOT INHERIT, so the loader has to give it one
# outright; with no sources installed in the fixture data dir that falls
# through to the shipped default.

my $alpha = getRegion('Alpha');
ok($alpha && $alpha->{source} eq $DEFAULT_BUILD_SOURCE_ID,
	"a region file with no source is given one ('".
	($alpha->{source} // 'undef')."')");
ok($alpha && $alpha->{source} ne $SOURCE_INHERITED,
	"and never '$SOURCE_INHERITED' - a set that inherits is indeterminate");
ok($alpha && $alpha->{source_name} eq '',
	"and carries no remembered name");

$alpha->{source} = $SOURCE_INHERITED;
ok(!stageRegion($alpha),	"a region may not be given '$SOURCE_INHERITED'");
$alpha = getRegion('Alpha');

# AN ID THAT NAMES NOTHING INSTALLED IS STILL VALID.  A set that arrived
# from somebody else has to open, or its recipient can never find out
# what it wants.  dm_region does not consult dm_source at all.

$alpha->{source}      = 'somebody_elses_tsd';
$alpha->{source_name} = 'Somebody Else - Imagery';
ok(stageRegion($alpha),		"a source that is not installed is accepted");

$alpha->{source} = 'Not A Source Id';
ok(!stageRegion($alpha),	"but one outside [a-z0-9_-] is refused");

my $reset = getRegion('Alpha');
ok($reset && $reset->{source} eq 'somebody_elses_tsd',
	"and the refusal put the last accepted source back");

ok(saveSet(),				"the set saves");
ok(openSet('Fix') == 2,		"and reopens");
my $back = getRegion('Alpha');
ok($back && $back->{source} eq 'somebody_elses_tsd',
	"with the source id round tripped");
ok($back && $back->{source_name} eq 'Somebody Else - Imagery',
	"and the remembered name with it");


print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
