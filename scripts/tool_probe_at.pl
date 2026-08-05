#!/usr/bin/perl
#---------------------------------------------
# tool_probe_at.pl -- probe a service over a box of ground, headless
#---------------------------------------------
#   perl -I/base tool_probe_at.pl <source_id> <lat> <lon> <zmin> <zmax>
#                                 [--half N] [--samples N] [--depth]
#
# A PROBE NEEDS A REGION, AND A SURVEY QUESTION DOES NOT HAVE ONE.  The
# application's probe samples a region or a subregion, which is right: it is
# asked from a map or a tree, by pointing at something.  A survey question is
# the other shape - "what does this service do HERE" about ground nobody has
# drawn - and answering it by making Patrick draw a region first would put an
# edit to his working set in front of every measurement.
#
# So this builds a whole disposable data dir under C:/_temp, plants one box
# region in it, and runs the REAL dm_sample::sampleService over that.  It is
# not a second probe; it is the same one, handed geometry from the command
# line.  Nothing in $data_dir is read or written and the running application
# is not touched.
#
# THE SOURCE FILE IS COPIED FROM THE INSTALLED ONE, so the url, the declared
# range and the rate policy under measurement are the ones that ship rather
# than a stand-in written here.
#
# WHAT IT IS FOR: feeding private/survey_tile_services.md.  The candidate
# fingerprints it prints at the end are the reason it exists - a repeated
# body is how a service says "nothing here" without saying it, and the only
# way to tell that from a flat patch of ocean is to run this in two places
# that have nothing to do with each other and compare the md5s.

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
use dm_fetch;
use dm_observe;
use dm_sample;

my ($src_id,$lat,$lon,$zmin,$zmax);
my $half    = 0.02;
my $samples = 12;
my $depth   = 0;

my @pos;
for (my $i = 0; $i <= $#ARGV; $i++)
{
	my $a = $ARGV[$i];
	if    ($a eq '--depth')   { $depth = 1 }
	elsif ($a eq '--half')    { $half    = $ARGV[++$i] }
	elsif ($a eq '--samples') { $samples = $ARGV[++$i] }
	else                      { push @pos,$a }
}
($src_id,$lat,$lon,$zmin,$zmax) = @pos;

die "usage: tool_probe_at.pl <source_id> <lat> <lon> <zmin> <zmax> ".
	"[--half N] [--samples N] [--depth]\n"
	if !defined $zmax;

my $ROOT = 'C:/_temp/base-apps-chartMaker/probe_at';

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

# THE INSTALLED FILE, BEFORE $data_dir IS MOVED.  Read first, because the
# next few lines point the whole application at a temp tree.

my $installed = sourcesDir()."/$src_id.tsd";
$installed = "$app_dir/_res/user_data/$src_id.tsd" if !-f $installed;
die "no .tsd for '$src_id' - looked in the sources folder and _res/user_data\n"
	if !-f $installed;
open(my $sh,'<',$installed) or die "cannot read $installed: $!";
my $tsd = do { local $/; <$sh> };
close $sh;

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$ROOT/temp";
setStandardResourceDir("$app_dir/_res");

loadSets();
putFile("$ROOT/sources/$src_id.tsd",$tsd);
dm_source::rescanSources();

# EVERY ZOOM NUMBER IN THE REGION IS A TRAP THE PROBE MUST IGNORE.  It takes
# the polygons and the range it is HANDED, which is what makes this legal.

my $dlon = $half / cos($lat * 3.14159265358979 / 180);
my $ring = sprintf(
	"[ [ %.6f, %.6f ], [ %.6f, %.6f ], [ %.6f, %.6f ], [ %.6f, %.6f ] ]",
	$lon-$dlon,$lat-$half, $lon+$dlon,$lat-$half,
	$lon+$dlon,$lat+$half, $lon-$dlon,$lat+$half);

newSet('ProbeAt');
putFile("$ROOT/region_sets/ProbeAt/Here.region",<<"EOJ");
{
   "region_version" : 1,
   "id" : "Here",
   "name" : "Here",
   "zauthor" : 15,
   "zmin" : 10,
   "zmax" : 16,
   "source" : "$src_id",
   "geometry" : [ $ring ],
   "subregions" : []
}
EOJ
openSet('ProbeAt');

my $pool = engineStart(2);
printf("probe %s at %.5f,%.5f  z%d-%d  half %.3f deg  %d/level%s  (%d worker)\n\n",
	$src_id,$lat,$lon,$zmin,$zmax,$half,$samples,
	($depth ? '  with depth' : ''),$pool);

my $out = sampleService($src_id,{ region => 'Here' },{
	zmin   => $zmin,
	zmax   => $zmax,
	depth  => $depth,
	counts => sampleCounts("*:$samples") });

print "$_\n" for @{sampleLines($out)};

print "\n","-" x 70,"\nCANDIDATE FINGERPRINTS\n","-" x 70,"\n";
my @cand = obsCandidates(getSource($src_id));
if (!@cand)
{
	print "none - no body repeated at two or more coordinates\n";
}
else
{
	printf("  %6d bytes  %s  seen %4d  first at z%d/%d/%d\n",
		$_->{bytes},$_->{md5},$_->{count},$_->{z},$_->{x},$_->{y})
		for @cand;
	print "\nCompare these md5s against a run somewhere unrelated.  Identical\n";
	print "across ground with nothing in common is a sentinel; identical only\n";
	print "within one patch is that patch's average colour.\n";
}

obsFlushAll();
engineStop();
print "\ntiles under $ROOT/cache\n";
