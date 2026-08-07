#!/usr/bin/perl
#---------------------------------------------
# test_coherence.pl -- CAN THIS NODE BE BUILT, and if not, WHY NOT
#---------------------------------------------
# HERMETIC.  It builds its whole data dir from nothing under C:/_temp and
# never reads anything of Patrick's, in the style of test_set.pl.
#
# THE QUESTION THIS PINS DOWN was answered in four different places and
# three different ways: dm_build refused it, dm_fill warned about one third
# of it, dm_analysis reported another third under a different name, and the
# Regions pane said something else again.  Worse, the commonest answer of
# all - a region that has chosen nothing - was unreachable from any of
# them, because every caller resolved '' through a fallback to whatever
# source the map happened to be displaying.
#
# So there is now one predicate and one tree walk, and this is what they
# have to say:
#
#	FIVE STATES, NOT A BOOLEAN.  'not chosen', 'not installed', 'display
#	only' and 'needs a key' are four different situations with four
#	different next acts, and telling somebody the wrong one sends them
#	looking for a fault that is not there
#
#	'' IS AN ANSWER.  A region with no source resolves to nothing, and
#	nothing is never quietly replaced by the displayed source
#
#	ONE FAULT PER NODE THAT SPOKE.  A region with five inheriting
#	subregions is ONE fault, against the region.  The subregions said
#	"whatever my parent says", which was a perfectly good answer to a
#	question their parent got wrong
#
#	DISPLAY AND BUILD ASK DIFFERENT QUESTIONS.  Painting a tile needs a
#	source installed and nothing more; building from one needs its author's
#	permission and this machine's key store

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_region;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/coh_data";

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


#---------------------------------------------
# fixtures
#---------------------------------------------
# FOUR SOURCES, ONE PER WAY OF FAILING plus the one that works.  Written
# inline rather than borrowed from the shipped set, so that a change to
# what chartMaker ships cannot quietly change what this asserts.

sub tsd
{
	my ($id,$uses,$url,$keys) = @_;
	$url ||= "https://example.com/{z}/{x}/{y}.jpeg";

	# A key_name has to be DECLARED as well as used, or the file is refused
	# at load and would arrive here as 'not installed' - which would make
	# the NO_KEY assertion below pass for the wrong reason.

	my $kd = $keys ? ",\n  \"keys\": [ { \"key_name\": \"$keys\" } ]" : '';
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "$id fixture",
  "url": "$url",
  "tile_format": "jpeg",
  "tile_size": 256,
  "zoom": { "min": 0, "max": 18 },
  "attribution": "test",
  "uses": [ $uses ]$kd
}
EOJ
}

sub regionJson
{
	my ($id,$src,$sub_src) = @_;
	my ($lat,$lon) = (9.33,-82.24);
	my $d = 0.05;
	my $ring = "[ [ @{[$lon-$d]}, @{[$lat-$d]} ], [ @{[$lon+$d]}, @{[$lat-$d]} ], ".
			   "[ @{[$lon+$d]}, @{[$lat+$d]} ], [ @{[$lon-$d]}, @{[$lat+$d]} ] ]";
	my $inner = "[ [ @{[$lon-$d/2]}, @{[$lat-$d/2]} ], [ @{[$lon+$d/2]}, @{[$lat-$d/2]} ], ".
				"[ @{[$lon+$d/2]}, @{[$lat+$d/2]} ], [ @{[$lon-$d/2]}, @{[$lat+$d/2]} ] ]";
	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "$id",
   "zauthor" : 15,
   "zmin" : 10,
   "zmax" : 16,
   "source" : "$src",
   "geometry" : [ $ring ],
   "subregions" : [
      {
         "id" : "Deep",
         "name" : "deep bit",
         "zmax" : 17,
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
$Pub::Utils::temp_dir = "$TMP/coh_temp";

loadSets();
mkdir "$ROOT/sources" if !-d "$ROOT/sources";

putFile("$ROOT/sources/coh_good.tsd",tsd('coh_good','"display","build"'));
putFile("$ROOT/sources/coh_view.tsd",tsd('coh_view','"display"'));
putFile("$ROOT/sources/coh_key.tsd", tsd('coh_key','"display","build"',
	'https://example.com/{z}/{x}/{y}.jpeg?key={coh_secret}','coh_secret'));
loadSources();

ok(getSource('coh_key'),
	"the keyed fixture LOADED - if it had been refused, the NO_KEY ".
	"assertions below would pass as MISSING instead");


#---------------------------------------------
# the predicate, on an id alone
#---------------------------------------------

print "=== sourceState ===\n";

ok(sourceState('coh_good','build') eq $SRC_OK,
	"an installed buildable source with no keys is OK");
ok(sourceState('','build') eq $SRC_NONE,
	"the empty string is NOT CHOSEN, which is its own answer");
ok(sourceState(undef,'build') eq $SRC_NONE,
	"and so is undef - a caller must not have to normalise first");
ok(sourceState('coh_nosuch','build') eq $SRC_MISSING,
	"an id nothing is installed under is NOT INSTALLED");
ok(sourceState('coh_view','build') eq $SRC_NOT_BUILD,
	"a source whose author says display only is DISPLAY ONLY");
ok(sourceState('coh_key','build') eq $SRC_NO_KEY,
	"a source with an unbound key_name NEEDS A KEY");

# THE FOUR ARE DISTINCT VALUES, which is the whole point of them.  A test
# that only asserted 'not OK' would pass with all four collapsed to one.

my %seen = map { sourceState($_->[0],'build') => 1 }
	(['coh_good'],[''],['coh_nosuch'],['coh_view'],['coh_key']);
ok(scalar(keys %seen) == 5,"five ids, five distinct answers (".
	scalar(keys %seen).")");


print "\n=== display asks less than build ===\n";

ok(sourceState('coh_view','display') eq $SRC_OK,
	"a display-only source is fine FOR DISPLAY");
ok(sourceState('coh_key','display') eq $SRC_OK,
	"and so is one with no key - painting needs no credential");
ok(sourceState('coh_nosuch','display') eq $SRC_MISSING,
	"but not installed is not installed, whatever it is for");
ok(sourceState('','display') eq $SRC_NONE,
	"and nothing chosen is still nothing chosen");


#---------------------------------------------
# the tree walk
#---------------------------------------------

print "\n=== regionFaults ===\n";

newSet('Coh');
putFile("$ROOT/region_sets/Coh/Good.region",
	regionJson('Good','coh_good',$SOURCE_INHERITED));
putFile("$ROOT/region_sets/Coh/Unset.region",
	regionJson('Unset','',$SOURCE_INHERITED));
putFile("$ROOT/region_sets/Coh/Gone.region",
	regionJson('Gone','coh_nosuch',$SOURCE_INHERITED));
putFile("$ROOT/region_sets/Coh/View.region",
	regionJson('View','coh_view',$SOURCE_INHERITED));
putFile("$ROOT/region_sets/Coh/SubBad.region",
	regionJson('SubBad','coh_good','coh_view'));
openSet('Coh');

ok(scalar(@{regionFaults(getRegion('Good'),'build')}) == 0,
	"a coherent tree has no faults");

# ONE FAULT, NOT TWO.  'Unset/Deep' inherits and therefore resolves to
# nothing as well - but it did not decide that, its parent did, and it is
# the parent that has to be changed.

my $f_unset = regionFaults(getRegion('Unset'),'build');
ok(scalar(@$f_unset) == 1,
	"a region that chose nothing is ONE fault, not one per node (".
	scalar(@$f_unset).")");
ok($f_unset->[0]{path} eq 'Unset',
	"reported against the region, which is what has to choose ".
	"($f_unset->[0]{path})");
ok($f_unset->[0]{state} eq $SRC_NONE,"and the state is NOT CHOSEN");

my $f_gone = regionFaults(getRegion('Gone'),'build');
ok(scalar(@$f_gone) == 1 && $f_gone->[0]{state} eq $SRC_MISSING,
	"a dangling id is one fault, NOT INSTALLED");
ok($f_gone->[0]{source} eq 'coh_nosuch',
	"and it carries the id, because that is what is wrong ".
	"($f_gone->[0]{source})");

my $f_view = regionFaults(getRegion('View'),'build');
ok(scalar(@$f_view) == 1 && $f_view->[0]{state} eq $SRC_NOT_BUILD,
	"a display-only source is one fault, DISPLAY ONLY");
ok(scalar(@{regionFaults(getRegion('View'),'display')}) == 0,
	"and the SAME tree has no faults at all for display");

# A SUBREGION THAT SPOKE FOR ITSELF ANSWERS FOR ITSELF.  Its region is
# perfectly good; the decision that is wrong was made separately and has to
# be unmade separately.

my $f_sub = regionFaults(getRegion('SubBad'),'build');
ok(scalar(@$f_sub) == 1,"a subregion naming its own bad source is one fault");
ok($f_sub->[0]{path} eq 'SubBad/Deep',
	"named by PATH, so the tree can be navigated to it ".
	"($f_sub->[0]{path})");


print "\n=== regionsFaults, across the ids an act works on ===\n";

my $all = regionsFaults([sort(getRegionIds())],'build');
ok(scalar(@$all) == 4,
	"four of the five regions cannot be built (".scalar(@$all).")");
ok(scalar(@{regionsFaults(['Good'],'build')}) == 0,
	"and asking about only the good one gives nothing");
ok(scalar(@{regionsFaults(['Nosuch'],'build')}) == 0,
	"an id that names no region contributes no fault rather than dying");


print "\n=== faultLines groups by state, unchosen first ===\n";

my @lines = faultLines($all);
ok(scalar(@lines) > 0,"there are lines to show");
ok($lines[0] =~ /has been chosen/,
	"the first thing said is about the unchosen ones ('$lines[0]')");

# EVERY STATE PRESENT IS MENTIONED, and the remedy travels with it.  A
# report that named the nodes without saying what to do about them would
# send the reader back to the documentation.

ok(scalar(grep { /not installed/ } @lines),"not-installed is reported");
ok(scalar(grep { /display-only/ }  @lines),"display-only is reported");
ok(scalar(grep { /Regions pane/ }  @lines),"and the remedy is in the lines");

ok(scalar(faultLines([])) == 0,"no faults means no lines at all");


#---------------------------------------------
# the map itself never invents a source
#---------------------------------------------

print "\n=== regionSourceMap answers '' and means it ===\n";

my $map = regionSourceMap(getRegion('Unset'));
ok($map->{Unset} eq '',"a region that chose nothing maps to ''");
ok($map->{'Unset/Deep'} eq '',
	"and so does everything inheriting from it - the chain terminates at ".
	"nothing rather than at a fallback");

my $map2 = regionSourceMap(getRegion('Good'));
ok($map2->{Good} eq 'coh_good',"a region that chose maps to its choice");
ok($map2->{'Good/Deep'} eq 'coh_good',
	"and its subregion inherits that, not anything else");

# THE SIGNATURE ITSELF IS THE GUARD.  There is no second argument to pass a
# display source through any more, which is what makes the old bug
# unwritable rather than merely fixed.

ok(scalar(keys %{regionSourceMap(getRegion('Good'))}) == 2,
	"the map takes the region and nothing else");


print "\nall done - $fails failure(s)\n";
exit($fails ? 1 : 0);
