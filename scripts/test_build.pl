#!/usr/bin/perl
#---------------------------------------------
# test_build.pl -- headless test of dm_build.pm, the build act
#---------------------------------------------
# HERMETIC AND OFFLINE on every path that is supposed to succeed.  It
# builds its whole data dir under C:/_temp and plants the cache itself, so
# a passing build never touches a network.  The paths that are supposed to
# FAIL point at .invalid hosts (RFC 2606), which cannot resolve anywhere,
# ever.
#
# THE ASSERTION THAT MATTERS MOST IS "AND NOTHING WAS WRITTEN".  Every
# guard is checked twice -- that it refused, and that the output folder is
# still empty afterwards -- because a build that reports a refusal and
# leaves a card behind is worse than one that never refused at all: the
# folder looks finished and the card is wrong.
#
# What it is pinning down:
#
#	the whole act runs with no wx anywhere in the process
#	each guard refuses, names what to fix, and writes nothing
#	the guards run BEFORE the fetch, not after it
#	a scattered failure refuses at the ledger, which no abort catches
#	--failed is a real override and not a second code path
#	each node exports from the source it names, not the region's
#	a cancel stops the act and leaves nothing behind

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_fill;
use dm_image;
use dm_rct;
use dm_build;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/build_data";

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

sub dirCount
	# How many files are in the output folder.  Used after every refusal.
{
	my ($dir) = @_;
	return 0 if !-d $dir;
	opendir(my $dh,$dir) or return 0;
	my @f = grep { !/^\.\.?$/ } readdir($dh);
	closedir $dh;
	return scalar(@f);
}

sub tsd
{
	my ($id,$url,$fmt,$uses) = @_;
	$fmt  ||= 'jpeg';
	$uses ||= '"display","build"';
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "test source $id",
  "url": "$url",
  "tile_format": "$fmt",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "test",
  "uses": [$uses],
  "policy": { "max_concurrency": 1, "min_interval_ms": 0 }
}
EOJ
}

sub regionJson
	# One region with one subregion, so that per-node sources are exercised
	# by every build rather than by a special case.  Tiny on purpose: this
	# is about which source and which guard, and a big polygon would only
	# make it slower to say the same thing.
{
	my ($id,$src,$sub_src,$zauthor,$zmin) = @_;
	$zauthor ||= 12;
	$zmin    ||= 10;
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
   "zmin" : $zmin,
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
$Pub::Utils::temp_dir = "$TMP/build_temp";

loadSets();
putFile("$ROOT/sources/bld_a.tsd",   tsd('bld_a','https://a.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/bld_b.tsd",   tsd('bld_b','https://b.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/bld_png.tsd", tsd('bld_png','https://p.example.com/{z}/{x}/{y}.png','png'));
putFile("$ROOT/sources/bld_disp.tsd",tsd('bld_disp','https://d.example.com/{z}/{x}/{y}.jpg','jpeg','"display"'));
putFile("$ROOT/sources/bld_abs.tsd", tsd('bld_abs','https://x.example.com/{z}/{x}/{y}.jpg'));
putFile("$ROOT/sources/bld_dead.tsd",tsd('bld_dead','https://nothing.invalid/{z}/{x}/{y}.jpg'));
dm_source::rescanSources();

my $OUT = "$ROOT/raster/Build";


#---------------------------------------------
# planting
#---------------------------------------------
# A real SOI marker, because getTile checks the bytes it hands back and the
# exporter now checks the format the cache recorded.

my $JPEG = "\xFF\xD8\xFF".('x' x 64);
my $PNG  = "\x89PNG\r\n\x1a\n".('x' x 64);

sub plant
	# Every tile of one node into the cache under one source.  $skip is a
	# list of ordinal positions to LEAVE OUT, which is how a scattered
	# failure is manufactured without a network.
	#
	# Returns the [z,x,y] of the ones left out, so a caller can then say
	# something else about exactly those tiles -- which is how the absent
	# case is set up, and it has to be the SAME tiles or the planted image
	# would be found first and the marker never consulted.
{
	my ($node,$src_id,$fmt,$skip) = @_;
	my $src = getSource($src_id) or die "no source '$src_id'\n";
	my $bytes = ($fmt || 'jpeg') eq 'png' ? \$PNG : \$JPEG;
	my %skip = map { $_ => 1 } @{$skip || []};
	my ($n,$i) = (0,0);
	my @left_out;

	for my $z (sort { $a <=> $b } keys %{$node->{levels}})
	{
		for my $key (sort keys %{$node->{levels}{$z}})
		{
			my ($x,$y) = split(/_/,$key);
			$i++;
			if ($skip{$i})
			{
				push @left_out,[$z,$x,$y];
				next;
			}
			cachePutTile($src,$z,$x,$y,($fmt || 'jpeg'),$bytes);
			$n++;
		}
	}
	return ($n,\@left_out);
}

sub plantRegion
{
	my ($id,$src,$sub_src,$fmt,$skip) = @_;
	my (undef,$nodes) = regionCoverageNodes(getRegion($id),{});
	my ($n,$left) = plant($nodes->[0],$src,$fmt,$skip);
	if ($nodes->[1])
	{
		my ($n2) = plant($nodes->[1],$sub_src,$fmt);
		$n += $n2;
	}
	return ($n,$left);
}


#---------------------------------------------
# the happy path
#---------------------------------------------

print "=== a clean build ===\n";

newSet('Build');
putFile("$ROOT/region_sets/Build/Alpha.region",regionJson('Alpha','bld_a','bld_b'));
openSet('Build');
plantRegion('Alpha','bld_a','bld_b');

my $r = buildRct(['Alpha'],{ fallback => 'bld_a' });
ok($r->{ok},"a fully cached region builds ($r->{refused})");
ok(!$r->{cancelled},"and was not cancelled");
ok(-f "$OUT/Alpha.rct","the card exists at $OUT/Alpha.rct");
ok(!-e "$OUT/Alpha.rct.tmp","and no temp file was left behind");
ok($r->{totals}{failed} == 0,"nothing failed");

# THE FILL RAN AND WAS A COMPLETE CACHE HIT.  Both halves matter: that the
# build fetches at all, and that it asked for exactly what was planted.

ok($r->{fill} && $r->{fill}{tiles} > 0,
	"the build ran a fill of its own (".($r->{fill}{tiles} // 0)." tiles)");
ok($r->{fill}{cached} == $r->{fill}{tiles},
	"every tile was already cached, so each node used the source it names ".
	"($r->{fill}{cached} of $r->{fill}{tiles})");

open(my $fh,'<',"$OUT/Alpha.rct") or die "cannot reread the card: $!\n";
binmode $fh;
read($fh,my $magic,4);
close $fh;
ok($magic eq 'RCT1',"and it really is an RCT ('$magic')");

my $clean_tiles = $r->{totals}{tiles};
ok($clean_tiles > 0,"$clean_tiles tiles are on the card");


#---------------------------------------------
# each node exports from the source it NAMES
#---------------------------------------------
# The subregion is planted under bld_b and the region under bld_a.  If the
# exporter used one source for the whole tree -- the region's, or the
# fallback -- the subregion's own band would be missing from the card.
# This is the Phase H change, and it is the reason the count above is the
# full count rather than the region's alone.

print "\n=== per-node sources reach the exporter ===\n";

my (undef,$nodes_a) = regionCoverageNodes(getRegion('Alpha'),{});
my $sub_own = 0;
for my $z (keys %{$nodes_a->[1]{levels}})
{
	$sub_own += scalar(keys %{$nodes_a->[1]{levels}{$z}})
		if !$nodes_a->[0]{levels}{$z};
}
ok($sub_own > 0,"the subregion has $sub_own tiles at levels the region never reaches");

# Those tiles exist ONLY under bld_b.  They are on the card, so the block
# that holds them was read from bld_b.

my (undef,$cov_nodes) = regionCoverageNodes(getRegion('Alpha'),{});
my $deep_z = (sort { $b <=> $a } keys %{$cov_nodes->[1]{levels}})[0];
my ($deep_key) = sort keys %{$cov_nodes->[1]{levels}{$deep_z}};
my ($dx,$dy) = split(/_/,$deep_key);
ok(!cacheGet(getSource('bld_a'),$deep_z,$dx,$dy),
	"the deepest tile is NOT in bld_a's cache at all");
ok(cacheGet(getSource('bld_b'),$deep_z,$dx,$dy),
	"it is in bld_b's, and the build above carried it onto the card");


#---------------------------------------------
# the output folder, and the asymmetry
#---------------------------------------------
# THE DEFAULT IS CREATED AS NEEDED; A CHOSEN ONE MUST ALREADY EXIST.
#
# This section exists because the GUI got it wrong in exactly the way no
# test was watching: w_frame resolved the default into a concrete path and
# passed it as out_dir, dm_build saw a non-empty out_dir and treated it as
# a NOMINATED folder, and every default-folder build refused the first
# time - on the one path a user is most likely to take.  buildRct itself
# was right the whole time, which is why calling it directly never showed
# it.  So: both branches, explicitly.

print "\n=== the default folder is created, a chosen one is not ===\n";

closeSet() if setIsOpen();
newSet('GOut');
putFile("$ROOT/region_sets/GOut/Alpha.region",regionJson('Alpha','bld_a','bld_b'));
openSet('GOut');
plantRegion('Alpha','bld_a','bld_b');

ok(!-d "$ROOT/raster/GOut","the default folder does not exist yet");

my $ro1 = buildRct(['Alpha'],{ fallback => 'bld_a' });
ok($ro1->{ok},"a build with NO out_dir creates it and succeeds ($ro1->{refused})");
ok(-d "$ROOT/raster/GOut","   and the folder is now there");

# The same thing said the other way: an EMPTY out_dir is still 'default',
# because that is what the configuration stores when nothing was chosen.

rmTree("$ROOT/raster/GOut");
my $ro2 = buildRct(['Alpha'],{ fallback => 'bld_a', out_dir => '' });
ok($ro2->{ok},"an EMPTY out_dir means the default too, and is created");
ok(-d "$ROOT/raster/GOut","   and the folder is back");

# A NOMINATED folder that is not there is refused rather than made - far
# more likely a typo, an unmounted drive, or a config from another machine
# than an instruction to build a tree somewhere unexpected.

my $ro3 = buildRct(['Alpha'],
	{ fallback => 'bld_a', out_dir => "$ROOT/no_such_folder" });
ok(!$ro3->{ok} && $ro3->{guard} eq 'out',
	"a CHOSEN folder that does not exist is refused as '$ro3->{guard}'");
ok(!-d "$ROOT/no_such_folder","   and was NOT created");

mkdir "$ROOT/chosen";
my $ro4 = buildRct(['Alpha'],{ fallback => 'bld_a', out_dir => "$ROOT/chosen" });
ok($ro4->{ok},"a chosen folder that EXISTS is built into");
ok(-f "$ROOT/chosen/Alpha.rct","   and the card is there, not in the default");


#---------------------------------------------
# the guards
#---------------------------------------------
# Each one refuses, says which thing to fix, and WRITES NOTHING.

print "\n=== the guards refuse before the fetch, and write nothing ===\n";

sub guardTest
	# Put a region in a set of its own, build it, and assert the refusal.
	# A fresh set each time so that one bad region cannot be masked by a
	# good one that happens to sort first.
{
	my ($set,$json,$guard,$what,$opts) = @_;

	closeSet() if setIsOpen();
	newSet($set);
	putFile("$ROOT/region_sets/$set/".($opts->{id} || 'Alpha').".region",$json);
	openSet($set);

	my $out = "$ROOT/raster/$set";
	my $rep = buildRct([getRegionIds()],{ fallback => 'bld_a', %{$opts->{build} || {}} });

	# A LEADING '!' MEANS "ANY GUARD BUT THIS ONE", which is not a
	# weakening.  Where a guard used to fire and no longer does, what
	# matters is that THAT gate opened - what stops the build afterwards
	# is a property of the fixture (these sources answer at example.com)
	# and asserting it would pin the test to an accident.

	my $got = $rep->{guard} // '';
	if ($guard =~ /^!(.*)$/)
	{
		ok(!$rep->{ok} && $got ne $1,
			"$what -> got past the '$1' gate (stopped at '$got')");
	}
	else
	{
		ok(!$rep->{ok} && $got eq $guard,
			"$what -> refused as '$got' ($rep->{refused})");
	}
	ok(dirCount($out) == 0,"   and wrote nothing");
	return $rep;
}

guardTest('GNoSrc',regionJson('Alpha','no_such_source','inherited'),'source',
	"a source that is not installed",{});

guardTest('GUses',regionJson('Alpha','bld_disp','inherited'),'uses',
	"a source that does not declare 'build'",{});

# THE FORMAT GUARD MOVED WHEN CONVERSION ARRIVED, and it moved for a
# reason worth stating here rather than only in the code: tile_format in a
# .tsd is an EXPECTATION, so refusing a whole build on it was refusing a
# prediction.  An .rct re-encodes a png on the way in now, so there is
# nothing left to refuse up front - unless this machine has no decoder at
# all, in which case the refusal is still exactly right and still saves an
# hour of fetching.
#
# BOTH ANSWERS ARE CORRECT and which one applies is a property of the
# installation, so the test asks the installation rather than assuming.

my $png_gate = imageCan() ? '!format' : 'format';
my $png_says = imageCan() ?
	"a png source, which an RCT converts rather than refuses" :
	"a png source with no decoder installed to convert it";

guardTest('GFmt',regionJson('Alpha','bld_png','inherited'),$png_gate,
	$png_says,{});

# A SUBREGION'S source is checked too.  This is the case a per-region check
# would pass: the region is fine and the detail box is not.

guardTest('GSubFmt',regionJson('Alpha','bld_a','bld_png'),$png_gate,
	"$png_says, on the SUBREGION only",{});

# THE ID RULES ARE NOT THE SAME RULE.  A region id may be any length of
# [A-Za-z0-9]; a card stem may be at most eight characters.  So the only
# way to reach this guard is a perfectly valid region whose name is too
# long -- an id with a hyphen in it never gets past the region loader and
# would have tested nothing.

guardTest('GName',regionJson('VeryLongRegion','bld_a','inherited'),'name',
	"a valid region id that is too long for an 8.3 card stem",
	{ id => 'VeryLongRegion' });


#---------------------------------------------
# the set must agree with itself
#---------------------------------------------

print "\n=== disagreement WARNS, and builds anyway ===\n";

# NOT A REFUSAL, deliberately.  Trying a new zauthor on one region before
# converting a whole chartset is a legitimate thing to want, and a hard
# refusal makes it impossible.  What must survive is that the build SAYS
# so - loudly, and in the report of the card that now exists, not only in
# a preflight dialog that has since been closed.

closeSet() if setIsOpen();
newSet('GAgree');
# BOTH REGIONS MUST BE VALID ON THEIR OWN, or the one that fails to load
# leaves the folder out of step with the model and the set reads as dirty
# -- which refuses first and this guard is never reached.  zmin <= zauthor
# <= zmax holds for both; they simply disagree with each other.

putFile("$ROOT/region_sets/GAgree/Alpha.region",regionJson('Alpha','bld_a','inherited',12,10));
putFile("$ROOT/region_sets/GAgree/Beta.region", regionJson('Beta', 'bld_a','inherited',11,10));
openSet('GAgree');
plantRegion('Alpha','bld_a','bld_a');
plantRegion('Beta','bld_a','bld_a');

my $rg = buildRct([sort(getRegionIds())],{ fallback => 'bld_a' });
ok($rg->{ok},"two regions with different zauthor still BUILD ($rg->{refused})");
ok($rg->{warned},"   but the build is flagged as warned");
ok(scalar(grep { /disagree on zauthor/ } @{$rg->{warnings}}),
	"   and the warning names zauthor");
ok(dirCount("$ROOT/raster/GAgree") == 2,"   two cards were written");

my $wl = buildReportLines($rg);
ok(scalar(grep { /^WARNING/ } @$wl),
	"   the REPORT still carries the warning, not just the preflight");


#---------------------------------------------
# unsaved edits
#---------------------------------------------

print "\n=== a card is not built from a model that is not on disk ===\n";

closeSet() if setIsOpen();
newSet('GDirty');
putFile("$ROOT/region_sets/GDirty/Alpha.region",regionJson('Alpha','bld_a','bld_b'));
openSet('GDirty');
plantRegion('Alpha','bld_a','bld_b');

my $reg = getRegion('Alpha');
$reg->{name} = 'edited but not saved';
stageRegion($reg);
ok(isSetDirty(),"the set is dirty after an unsaved edit");

my $rd = buildRct(['Alpha'],{ fallback => 'bld_a' });
ok(!$rd->{ok} && $rd->{guard} eq 'dirty',
	"a dirty set -> refused as '$rd->{guard}'");
ok(dirCount("$ROOT/raster/GDirty") == 0,"   and wrote nothing");

my $rd2 = buildRct(['Alpha'],{ fallback => 'bld_a', allow_dirty => 1 });
ok($rd2->{ok},"--dirty is a real override and builds it anyway");
ok(-f "$ROOT/raster/GDirty/Alpha.rct","   and the card is there");


#---------------------------------------------
# THE REFUSAL POINT
#---------------------------------------------
# The one guard that cannot run before the fetch, because until the fetch
# has run there is nothing to know.  A handful of failures scattered
# through a walk never trips the consecutive-error abort, so the fill
# reports success and the ledger is the only thing that catches them.

print "\n=== a scattered failure refuses AFTER the fill ===\n";

closeSet() if setIsOpen();
newSet('GHoles');
putFile("$ROOT/region_sets/GHoles/Alpha.region",regionJson('Alpha','bld_dead','bld_dead'));
openSet('GHoles');

# Everything planted except three tiles, spread far enough apart that no
# ten failures are ever consecutive.  The source is a .invalid host, so
# exactly those three go to the network and exactly those three fail.
#
# The ordinals are into the REGION's own node, which has 30 of the 50
# tiles -- an ordinal past its end would simply not skip anything and the
# test would silently assert less than it claims.

my (undef,$holes) = plantRegion('Alpha','bld_dead','bld_dead','jpeg',[3,17,29]);
ok(scalar(@$holes) == 3,"three tiles were deliberately left unplanted");

my $rh = buildRct(['Alpha'],{ fallback => 'bld_dead' });
ok(!$rh->{ok} && $rh->{guard} eq 'failed',
	"three tiles that never arrived -> refused as '$rh->{guard}'");
ok(!$rh->{fill}{aborted},
	"   and the fill did NOT abort - nothing else would have caught this");
ok($rh->{fill}{error} == 3,"   exactly three failures ($rh->{fill}{error})");
ok(scalar(@{$rh->{detail}}) >= 3,"   and the refusal NAMES them");
ok(dirCount("$ROOT/raster/GHoles") == 0,"   and wrote nothing");

# THE OVERRIDE IS A DECISION, NOT A DIFFERENT BUILD.  Same act, same
# ledger, one flag -- so what it ships is exactly what it refused to ship.

my $rh2 = buildRct(['Alpha'],{ fallback => 'bld_dead', allow_failed => 1 });
ok($rh2->{ok},"--failed exports it anyway");
ok($rh2->{totals}{failed} == 3,
	"   and the card is honest about the three holes ($rh2->{totals}{failed})");
ok(-f "$ROOT/raster/GHoles/Alpha.rct","   the card is there");


#---------------------------------------------
# absent is not failed
#---------------------------------------------
# A tile the source ASSERTED it does not have is a fact about the ground.
# It is correct to ship, retrying will never change it, and it must not be
# confused with a tile that never arrived.

print "\n=== an asserted absence is shipped, not refused ===\n";

closeSet() if setIsOpen();
newSet('GAbsent');
putFile("$ROOT/region_sets/GAbsent/Alpha.region",regionJson('Alpha','bld_abs','bld_abs'));
openSet('GAbsent');

# A SOURCE OF ITS OWN, and that is not tidiness.  THE CACHE IS KEYED BY
# SOURCE AND NOTHING ELSE - not by set - and every region in this file has
# the same geometry, so the happy-path build at the top already planted
# these exact tiles under bld_a.  Marking them absent there would mark
# tiles that are also present, cacheGet would find the image first, and
# the marker would never be consulted.

# LEAVE THREE UNPLANTED, THEN MARK EXACTLY THOSE THREE as known-absent.
# It has to be the same three, for the same reason.

my (undef,$gaps) = plantRegion('Alpha','bld_abs','bld_abs','jpeg',[3,17,29]);
cachePutMiss(getSource('bld_abs'),@$_) for @$gaps;
ok(scalar(@$gaps) == 3,"marked three tiles as known-absent");

my $ra = buildRct(['Alpha'],{ fallback => 'bld_a' });
ok($ra->{ok},"the build is NOT refused over them");
ok($ra->{totals}{absent} == 3,"and reports them as absent ($ra->{totals}{absent})");
ok($ra->{totals}{failed} == 0,"with nothing failed");


#---------------------------------------------
# cancel
#---------------------------------------------

print "\n=== cancel stops it and leaves nothing ===\n";

closeSet() if setIsOpen();
newSet('GCancel');
putFile("$ROOT/region_sets/GCancel/Alpha.region",regionJson('Alpha','bld_a','bld_b'));
openSet('GCancel');
plantRegion('Alpha','bld_a','bld_b');

my $prog = newProgress(1,'test');
$prog->{cancelled} = 1;

my $rc = buildRct(['Alpha'],{ fallback => 'bld_a', progress => $prog });
ok($rc->{cancelled},"a cancelled record stops the act");
ok(!$rc->{ok},"which is not a success");
ok(dirCount("$ROOT/raster/GCancel") == 0,"and wrote nothing");


#---------------------------------------------
# a cancel during the WRITE says something different
#---------------------------------------------
# The export loop polls the same flag between files, so a cancel there
# leaves WHOLE CARDS on disk - and a report that said "nothing was
# written" would be a lie the user finds later.
#
# THE TIMING IS NOT ASSERTED HERE, deliberately.  Landing a cancel between
# two file writes needs either a hook in dm_build or a watcher thread
# racing an export that takes milliseconds, and the first puts test
# scaffolding in the product while the second fails intermittently for
# reasons that have nothing to do with the code.  What IS deterministic
# is the reporting, so that is what is checked - plus that the export
# phase publishes itself, which is what a watcher would key on.

print "\n=== a cancel during the write reports the PARTIAL set ===\n";

closeSet() if setIsOpen();
newSet('GCanWrite');
putFile("$ROOT/region_sets/GCanWrite/Alpha.region",regionJson('Alpha','bld_a','bld_b'));
putFile("$ROOT/region_sets/GCanWrite/Beta.region", regionJson('Beta', 'bld_a','bld_b'));
openSet('GCanWrite');
plantRegion('Alpha','bld_a','bld_b');
plantRegion('Beta','bld_a','bld_b');

my $prog2 = newProgress(2,'');
my $rcw = buildRct([sort(getRegionIds())],
	{ fallback => 'bld_a', progress => $prog2 });

ok($rcw->{ok},"two regions build");
ok($prog2->{phase} eq 'Done',"the phase ends at 'Done' (got '$prog2->{phase}')");
ok($prog2->{done} == 2,"and counts both as completed ($prog2->{done})");
ok(dirCount("$ROOT/raster/GCanWrite") == 2,"two cards, no fragments");

# The partial-cancel REPORT, over a report shaped exactly as the export
# loop shapes one when it stops early.

my $partial = {
	cancelled => 1, partial => 1, ok => 0,
	out_dir => "$ROOT/raster/GCanWrite",
	regions => [ { name => 'Alpha.rct' } ],
	totals => { tiles => 0, absent => 0, failed => 0, bytes => 0 },
	detail => [], secs => 1,
};
my $pl = buildReportLines($partial);
ok(scalar(grep { /folder is INCOMPLETE/ } @$pl),
	"a partial cancel reports PARTIAL, not 'nothing was written'");
ok(!scalar(grep { /nothing was written/ } @$pl),
	"   and does not also claim nothing was written");
ok(scalar(grep { /Alpha\.rct/ } @$pl),"   naming the cards that ARE complete");


#---------------------------------------------
# the report renders for both surfaces
#---------------------------------------------

print "\n=== the report is text once, for both surfaces ===\n";

my $lines = buildReportLines($r);

# scalar(@$lines), not @$lines: '&&' yields its RIGHT operand, and in an
# argument list that operand flattens - the description would slide into
# the condition slot and a failing test would print PASS.

ok(ref($lines) eq 'ARRAY' && scalar(@$lines),
	"a successful build renders ".scalar(@$lines)." lines");
ok(!scalar(grep { !defined } @$lines),"with no undefined lines");
ok(scalar(grep { /Built 1 .rct file/ } @$lines),"saying what it built");

my $flines = buildReportLines($rh);
ok(scalar(grep { /^REFUSED/ } @$flines),"a refusal leads with REFUSED");
ok(!scalar(grep { !defined } @$flines),"and has no undefined lines either");

my $clines = buildReportLines($rc);
ok(scalar(grep { /CANCELLED/ } @$clines),"a cancel says CANCELLED");


#---------------------------------------------

print "\n".($fails ? "$fails FAILED\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
