#!/usr/bin/perl
#---------------------------------------------
# test_edit.pl -- the EDIT backend, headless
#---------------------------------------------
# HERMETIC.  Builds its own data dir under C:/_temp and never touches
# Patrick's.  What it pins down:
#
#	containment is ENFORCED, not reported     a subregion cannot leave its parent
#	a subregion is created named and EMPTY    nothing invents a shape
#	nesting works at any depth                findAnywhere, addSubregion
#	dispatchCommand RETURNS a status          /edit's whole reason to exist
#	a refused commit changes nothing          the model is left as it was
#	selection and edit state are shared       and dirty refuses a selection change

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_state;
use dm_set;
use dm_region;
use dm_coverage;
use em_command;

my $TMP  = 'C:/_temp/dat-openCPN-chartMaker';
my $ROOT = "$TMP/edit_data";

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

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/edit_temp";

# A one-degree square, so 'inside' and 'outside' are obvious by eye.
my $BOX  = [[ [-82.0,9.0],[-81.0,9.0],[-81.0,10.0],[-82.0,10.0] ]];
my $IN   = [[ [-81.8,9.2],[-81.6,9.2],[-81.6,9.4],[-81.8,9.4] ]];
my $OUT  = [[ [-80.8,9.2],[-80.6,9.2],[-80.6,9.4],[-80.8,9.4] ]];
my $HALF = [[ [-81.2,9.2],[-80.8,9.2],[-80.8,9.4],[-81.2,9.4] ]];


#---------------------------------------------
# the geometry primitive
#---------------------------------------------

print "=== polygon containment ===\n";

ok(polygonsContainPoint($BOX,-81.5,9.5),"a point inside is inside");
ok(!polygonsContainPoint($BOX,-80.5,9.5),"a point outside is outside");

my @out = outsideVertices($BOX,$IN);
ok(scalar(@out) == 0,"a contained polygon has no outside vertices");

@out = outsideVertices($BOX,$OUT);
ok(scalar(@out) == 4,"a wholly outside polygon has all 4 out (got ".scalar(@out).")");

@out = outsideVertices($BOX,$HALF);
ok(scalar(@out) == 2,"a straddling polygon has 2 out (got ".scalar(@out).")");


#---------------------------------------------
# containment is enforced by the model
#---------------------------------------------

print "\n=== containment is enforced ===\n";

loadSets();
newSet('Edit') or die "cannot make set\n";
openSet('Edit');

my $reg = newRegion('Parent',15,10,16,'Parent') or die "cannot make region\n";
$reg->{geometry} = $BOX;
ok(stageRegion($reg),"a region with geometry is accepted");

# An empty parent contains nothing, and must not reject its subregions -
# creating a parent and drawing it are two separate steps.

my $sub = addSubregion('Parent','Inside',18);
ok($sub,"addSubregion returns a subregion");
ok(scalar(@{$sub->{geometry}}) == 0,"it is created EMPTY - nothing invented a shape");
ok(!defined($sub->{zauthor}),"and carries no zauthor of its own");

$reg = getRegion('Parent');
my ($found) = findSubregion($reg,'Inside');
$found->{geometry} = $IN;
ok(stageRegion($reg),"a contained subregion is accepted");
ok(saveSet(),"and the set can be written");

$reg = getRegion('Parent');
($found) = findSubregion($reg,'Inside');
$found->{geometry} = $OUT;
ok(!stageRegion($reg),"a subregion OUTSIDE its parent is REFUSED");

# The refusal must leave neither the document nor the file holding
# geometry the validator will not accept.

revertSet();
$reg = getRegion('Parent');
($found) = findSubregion($reg,'Inside');
ok($found && abs($found->{geometry}[0][0][0] - (-81.8)) < 1e-9,
	"the file on disk still holds the contained geometry");

$reg = getRegion('Parent');
($found) = findSubregion($reg,'Inside');
$found->{geometry} = $HALF;
ok(!stageRegion($reg),"a subregion straddling the boundary is REFUSED too");


#---------------------------------------------
# nesting at depth
#---------------------------------------------

print "\n=== nesting ===\n";

my ($root,$node) = findAnywhere('Inside');
ok($root && $root->{id} eq 'Parent',"findAnywhere finds a subregion's root");
ok($node && $node->{id} eq 'Inside',"and the node itself");

($root,$node) = findAnywhere('Parent');
ok($root == $node,"for a region, root and node are the same thing");

ok(!defined((findAnywhere('Nonesuch'))[0]),"and nothing for an unknown id");

my $deep = addSubregion('Inside','Deeper',20);
ok($deep,"a subregion can be added to a SUBREGION");
($root,$node) = findAnywhere('Deeper');
ok($root && $root->{id} eq 'Parent',"its root is still the region");


#---------------------------------------------
# the dispatcher returns a status
#---------------------------------------------

print "\n=== dispatchCommand status ===\n";

ok(dispatchCommand('regions','') ? 1 : 0,"a good command returns true");
ok(!dispatchCommand('notaverb',''),"an unknown command returns FALSE");
ok(!dispatchCommand('select','Nonesuch'),"a refused verb returns FALSE");

# The commit path, with structured data, exactly as /edit calls it.

my $NEW = [[ [-81.9,9.1],[-81.1,9.1],[-81.1,9.9],[-81.9,9.9] ]];
ok(dispatchCommand('region','geometry Parent',$NEW),
	"region geometry with a polygon list returns true");
ok(saveSet(),"and the set writes");
revertSet();
ok(abs(getRegion('Parent')->{geometry}[0][0][0] - (-81.9)) < 1e-9,
	"the new geometry is what comes back off the disk");

ok(!dispatchCommand('region','geometry Parent'),
	"region geometry with NO data returns false");
ok(!dispatchCommand('region','geometry Nonesuch',$NEW),
	"region geometry on an unknown id returns false");

# A two-point polygon is invalid.  The refusal must leave the model alone.

ok(!dispatchCommand('region','geometry Parent',[[ [-81.5,9.5],[-81.4,9.5] ]]),
	"a two-point polygon is refused");
revertSet();
ok(abs(getRegion('Parent')->{geometry}[0][0][0] - (-81.9)) < 1e-9,
	"and the good geometry SURVIVED the refusal");

# Containment through the dispatcher, not just through saveRegion.

ok(!dispatchCommand('region','geometry Inside',$OUT),
	"a subregion pushed outside its parent is refused through the dispatcher");


#---------------------------------------------
# the verbs the map's dialogs emit
#---------------------------------------------

print "\n=== region new, both forms ===\n";

# The short form, as a person types it.
ok(dispatchCommand('region','new Short Name 14'),"region new <name> <z>");
my $short = getRegion('ShortName');
ok($short && $short->{zauthor} == 14,"the trailing integer is the zauthor");
ok($short && scalar(@{$short->{geometry}}) == 0,"created with NO geometry");

# The long form, as the map's dialog sends it: id, three zooms, then a name
# that may contain spaces.
ok(dispatchCommand('region','new Longer 15 10 17 A Longer Name'),
	"region new <id> <zauthor> <zmin> <zmax> <name...>");
my $long = getRegion('Longer');
ok($long,"the region exists under the id it was given");
ok($long && $long->{zauthor} == 15 && $long->{zmin} == 10 && $long->{zmax} == 17,
	"all three zooms landed where they belong");
ok($long && $long->{name} eq 'A Longer Name',"the name kept its spaces");

ok(!dispatchCommand('region','new Longer 15 10 17 Duplicate'),
	"a duplicate id is refused");
ok(!dispatchCommand('region','new'),"with no name at all it is refused");

print "\n=== subregion new ===\n";

ok(dispatchCommand('region','geometry Longer',$BOX),"give the parent geometry");
ok(dispatchCommand('subregion','new Longer 19 Deep Anchorage'),
	"subregion new <parent> <zmax> <name...>");
my ($lroot,$lnode) = findAnywhere('DeepAnchorage');
ok($lnode && $lnode->{zmax} == 19,"the zmax landed (got ".
	($lnode ? $lnode->{zmax} : 'none').")");
ok($lnode && $lnode->{name} eq 'Deep Anchorage',"and the name kept its spaces");
ok($lnode && scalar(@{$lnode->{geometry}}) == 0,"created with NO geometry");

ok(!dispatchCommand('subregion','new Longer 19'),"with no name it is refused");
ok(!dispatchCommand('subregion','new Nonesuch 19 Whatever'),
	"under an unknown parent it is refused");

# An empty subregion is vacuously contained, so the parent still saves.
ok(dispatchCommand('region','geometry Longer',$BOX),
	"a parent with an EMPTY subregion still saves");

# And once drawn inside, it is checked.
ok(dispatchCommand('region','geometry Longer DeepAnchorage',$IN),
	"a subregion drawn inside its parent commits");
ok(!dispatchCommand('region','geometry Longer DeepAnchorage',$OUT),
	"drawn outside, it is refused");

print "\n=== deleting ===\n";

ok(dispatchCommand('subregion','delete Longer DeepAnchorage'),"subregion delete");
ok(!defined((findAnywhere('DeepAnchorage'))[0]),"and it is gone from the model");

ok(dispatchCommand('region','delete ShortName'),"region delete");
revertSet();
ok(!defined(getRegion('ShortName')),"and its file is gone");
ok(!dispatchCommand('region','delete ShortName'),"deleting it twice is refused");


#---------------------------------------------
# selection and edit state
#---------------------------------------------

print "\n=== selection ===\n";

ok(dispatchCommand('select','Parent'),"select a region");
my ($sr,$ss) = getSelection();
ok($sr eq 'Parent' && $ss eq '',"the selection is the region, with no subregion");

ok(dispatchCommand('select','Inside'),"select a subregion");
($sr,$ss) = getSelection();
ok($sr eq 'Parent' && $ss eq 'Inside',"the selection carries BOTH ids");

ok(dispatchCommand('select','none'),"select none");
($sr,$ss) = getSelection();
ok($sr eq '' && $ss eq '',"and nothing is selected");

print "\n=== edit state ===\n";

# AN EDIT BELONGS TO A BROWSER.  editLocks() reports nothing when no map has
# polled recently, because an obstacle nobody can clear is not one - so a
# headless test asserting the locks has to say a map is there.  Anything
# below that takes longer than the grace period must call this again.

notePoll();

ok(getEditState()->{mode} eq $EDIT_BROWSE,"it starts in browse");
ok(editLocks() eq '',"and locks nothing");

ok(mapIsOpen(),"a poll just arrived, so the map counts as open");

ok(dispatchCommand('edit','shape Parent'),"enter shape on a region");
my $st = getEditState();
ok($st->{mode} eq $EDIT_SHAPE && $st->{region} eq 'Parent',"the state says so");
ok(!$st->{dirty},"and it is CLEAN");
ok(editLocks() eq '',"a clean shape locks nothing - handles are not a risk");

ok(dispatchCommand('edit','shape Parent dirty'),"make it dirty");
ok(getEditState()->{dirty},"the dirty flag is set");
ok(editLocks() ne '',"a dirty object LOCKS: ".editLocks());
ok(!dispatchCommand('select','Inside'),
	"and selecting something else is REFUSED while dirty");

ok(dispatchCommand('edit','draw Parent'),"enter draw");
ok(editLocks() ne '',"draw locks even when clean: ".editLocks());

ok(dispatchCommand('edit','end'),"edit end");
ok(getEditState()->{mode} eq $EDIT_BROWSE,"back to browse");
ok(editLocks() eq '',"and nothing is locked");
ok(dispatchCommand('select','Inside'),"selection works again");


#---------------------------------------------
# the tile-edge epsilon
#---------------------------------------------

print "\n=== the tile-edge epsilon ===\n";

my $Z = 15;
my ($w,$s,$e,$n) = tileBounds($Z,9130,15370);

# A polygon whose southern edge sits EXACTLY on this tile's northern edge
# must not claim this tile.  Without the epsilon, float noise decides.

my $above = [[ [$w+0.001,$n],[$e-0.001,$n],[$e-0.001,$n+0.01],[$w+0.001,$n+0.01] ]];
my $cov = regionCoverage({
	id => 'Eps', zauthor => $Z, zmin => $Z, zmax => $Z,
	geometry => $above, subregions => [] });
ok(!coverageHas($cov,$Z,9130,15370),
	"a polygon resting ON a tile's edge does not claim that tile");
ok(coverageHas($cov,$Z,9130,15369),
	"it does claim the tile it is actually inside");


print "\n".($fails ? "$fails TEST(S) FAILED" : "ALL PASSED")."\n";
exit($fails ? 1 : 0);
