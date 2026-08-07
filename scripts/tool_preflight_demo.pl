#!/usr/bin/perl
#---------------------------------------------
# tool_preflight_demo.pl -- the two preflight dialogs over a FIXTURE SET
#---------------------------------------------
# w_buildcfg and w_preflight, against a region set built from nothing under
# C:/_temp - four regions, one per way of being coherent or not:
#
#	Bocas     names a source that can build      builds
#	Forment   names none at all                  $SRC_NONE
#	Gone      names a source that is not there   $SRC_MISSING
#	Viewer    names a display-only source        $SRC_NOT_BUILD
#
#	perl -I/base tool_preflight_demo.pl          dialog one - what and where
#	perl -I/base tool_preflight_demo.pl pre      dialog two - what it costs
#	perl -I/base tool_preflight_demo.pl ok       dialog two with NOTHING wrong
#
# WHY THIS EXISTS AS A TOOL RATHER THAN A TEST.  What these two dialogs
# have to get right is what they SHOW, and no headless assertion can look
# at a dialog.  The rules underneath them are pinned by test_coherence.pl;
# this is the half that has to be looked at, and looking at it used to mean
# authoring a broken region set inside real data and running the whole
# application to reach a dialog four clicks in.
#
# It found two real defects the moment it was first run, which is the
# argument for keeping it: the faults were rendered TWICE, once by
# analysisLines into the cost panel and once by _notes into the note panel;
# and the remedy sentences were long enough to be cut off by a panel that
# does not wrap.  Neither is visible from any test.
#
# HERMETIC.  Its own $data_dir, its own sources, its own set.  It reads
# nothing of yours and the ordinary application may be running while it is.
#
# THE DIALOG IS SHOWN FROM A TIMER, not from OnInit - a modal dialog is an
# event loop and there is no loop for it to nest inside until MainLoop is
# running.  Same reason, same shape, as tool_progress_demo.pl.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::Resources;
use cm_defs;
use cm_prefs;
use cm_config;
use cm_utils;
use dm_set;
use dm_source;
use dm_region;
use dm_analysis;
use w_resources;
use w_buildcfg;
use w_preflight;

use base 'Wx::App';

$| = 1;
	# Redirected stdout is block buffered and this script is normally killed
	# with a modal dialog still up - without this, everything it said is
	# discarded at exactly the moment it is wanted.

setStandardTempDir('chartMaker');

my $ROOT = 'C:/_temp/base-apps-chartMaker/preflight_demo';
my $WHICH = $ARGV[0] || 'cfg';


sub rmTree
{
	my ($dir) = @_;
	return if !-d $dir;
	opendir(my $dh,$dir) or return;
	for my $leaf (grep { !/^\.\.?$/ } readdir($dh))
	{
		my $p = "$dir/$leaf";
		-d $p ? rmTree($p) : unlink($p);
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
	my ($id,$uses) = @_;
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "$id fixture",
  "url": "https://example.com/{z}/{x}/{y}.jpeg",
  "tile_format": "jpeg",
  "tile_size": 256,
  "zoom": { "min": 0, "max": 18 },
  "attribution": "fixture",
  "uses": [ $uses ]
}
EOJ
}

sub regionJson
{
	my ($id,$src) = @_;

	# A DIFFERENT BOX PER REGION, so the tile counts differ and the cost
	# table has something to say.  All of it is open water off Bocas.

	my ($lat,$lon) = (9.33,-82.24);
	my $d = 0.05;
	my $ring = "[ [ @{[$lon-$d]}, @{[$lat-$d]} ], [ @{[$lon+$d]}, @{[$lat-$d]} ], ".
			   "[ @{[$lon+$d]}, @{[$lat+$d]} ], [ @{[$lon-$d]}, @{[$lat+$d]} ] ]";
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
   "subregions" : []
}
EOJ
}


#---------------------------------------------
# the fixture
#---------------------------------------------

rmTree($ROOT);
mkdir $ROOT or die "cannot create $ROOT: $!\n";
$Pub::Utils::data_dir = $ROOT;

loadSets();
mkdir "$ROOT/sources" if !-d "$ROOT/sources";
putFile("$ROOT/sources/demo_good.tsd",tsd('demo_good','"display","build"'));
putFile("$ROOT/sources/demo_view.tsd",tsd('demo_view','"display"'));
loadSources();

newSet('Demo');
putFile("$ROOT/region_sets/Demo/Bocas.region",  regionJson('Bocas','demo_good'));
if ($WHICH ne 'ok')
{
	putFile("$ROOT/region_sets/Demo/Forment.region",regionJson('Forment',''));
	putFile("$ROOT/region_sets/Demo/Gone.region",   regionJson('Gone','demo_absent'));
	putFile("$ROOT/region_sets/Demo/Viewer.region", regionJson('Viewer','demo_view'));
}
openSet('Demo');

print "fixture: ".scalar(getRegionIds())." region(s) in 'Demo'\n";
print "showing: ".($WHICH eq 'cfg' ? 'dialog one' : 'dialog two').
	  ($WHICH eq 'ok' ? ' (nothing wrong)' : '')."\n";


#---------------------------------------------
# the dialog
#---------------------------------------------

sub OnInit
{
	my ($this) = @_;

	# WELL TO THE RIGHT, for the reason tool_progress_demo gives: the
	# dialogs centre on this frame, and at 300,200 they come up underneath
	# whatever terminal launched the script - which reads as "no window
	# appeared".

	my $frame = Wx::Frame->new(undef,-1,'preflight demo',[1500,120],[420,200]);
	$frame->Show(1);
	$frame->Raise();

	my $timer = Wx::Timer->new($frame,7799);
	Wx::Event::EVT_TIMER($frame,7799,sub { showIt($frame) });
	$timer->Start(400,1);
	$this->{timer} = $timer;
	return 1;
}


sub showIt
{
	my ($frame) = @_;

	if ($WHICH eq 'cfg')
	{
		my $dlg = w_buildcfg->new($frame,'build');
		my $rslt = $dlg->ShowModal();
		my $got  = $dlg->result();
		$dlg->Destroy();

		# EVERY COMPARISON AGAINST A wxID_ IS PARENTHESISED, and it has to
		# be: those are imported SUBS, and this Perl reads the ? after a
		# bare one as the start of a ?PATTERN? match - so the whole line
		# stops making sense and the error is reported twenty lines away.

		print "  result: ".(($rslt == wxID_OK) ? 'OK' : 'cancelled')."\n";
		print "  ids   : ".join(', ',@{$got->{ids}})."\n" if $got;

		# WHAT WAS STORED, because the whole point of the suppression is
		# that it is NOT stored.  undef here means 'the whole set' and is
		# the answer even when a region was greyed out and left unticked.

		print "  cfg regions: ".((defined $got->{cfg}{regions}) ?
			join(', ',@{$got->{cfg}{regions}}) : 'undef (= ALL)')."\n" if $got;
	}
	else
	{
		my @ids = getRegionIds();
		my $an  = analyseFetch(\@ids,{ format => 'rct' });
		print "  faults: ".scalar(@{$an->{faults}})."\n";

		my $dlg = w_preflight->new($frame,'build',$an,"$ROOT/raster/Demo",
			{ dirty => 0 });
		my $rslt = $dlg->ShowModal();
		$dlg->Destroy();
		print "  result: ".(($rslt == wxID_OK) ? 'START' :
							($rslt == wxID_BACKWARD) ? 'BACK' : 'cancelled')."\n";
	}
	$frame->Destroy();
}


# main->new(), not tool_preflight_demo->new() - see the note at the foot of
# tool_progress_demo.pl.

my $app = main->new();
$app->MainLoop();
print "ALL DONE\n";
