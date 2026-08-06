#!/usr/bin/perl
#---------------------------------------------
# test_restore.pl -- headless test of dm_restore.pm
#---------------------------------------------
# HERMETIC.  It builds its whole data dir from nothing under C:/_temp and
# never reads anything of Patrick's, which is what lets it assert exact
# counts.  The one thing it does read is the REAL shipped tree in
# _res/user_data, because that is the thing under test.
#
# What it is actually pinning down:
#
#	the shipped tree is found         - four sources and the example set
#	missing is ticked, changed is not - the default that can lose work
#	a changed file is detected        - by content, not by timestamp
#	A FILE THE USER ADDED IS NEVER TOUCHED - the load bearing one: the
#	                                    reader's own region lives in the
#	                                    same folder as the shipped one
#	a deleted shipped file comes back

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_prefs;
use cm_utils;
use dm_set;
use dm_restore;

my $TMP = 'C:/_temp/base-apps-chartMaker/restore_data';

sub nuke { my ($d) = @_; return if !-d $d;
	opendir(my $h,$d); my @e = grep { !/^\.\.?$/ } readdir($h); closedir $h;
	for (@e) { -d "$d/$_" ? nuke("$d/$_") : unlink("$d/$_") } rmdir $d; }

nuke($TMP);
$data_dir = $TMP;
my_mkdir($data_dir);
init_prefs();

my $fails = 0;
sub ok { my ($cond,$what) = @_;
	print(($cond ? "  ok   " : "  FAIL ").$what."\n"); $fails++ if !$cond; }

print "shipped dir: ".shippedDir()."\n";

# 1 - a virgin data dir: everything missing and everything ticked

my $rows = surveyShipped();
print "found ".scalar(@$rows)." shipped leaves\n";
print "   $_->{rel}  ->  $_->{state}\n" for @$rows;

ok(scalar(@$rows) >= 5,'the bundle has the four sources and the example set');
ok((grep { $_->{rel} eq 'sources/esri.tsd' } @$rows) == 1,'esri.tsd is in the bundle');
ok((grep { $_->{kind} eq 'region' } @$rows) >= 1,'a region file is in the bundle');
ok((grep { $_->{state} ne 'missing' } @$rows) == 0,'all missing in a virgin dir');
ok((grep { !$_->{do} } @$rows) == 0,'all ticked when all missing');

my ($wrote,$failed,$errs) = restoreShipped($rows);
print "restored $wrote, failed $failed\n";
print "   ERROR $_\n" for @$errs;
ok($failed == 0,'nothing failed');
ok($wrote == scalar(@$rows),'every leaf was written');
ok(-f sourcesDir().'/esri.tsd','esri.tsd landed in the sources folder');
ok(-f regionSetsDir().'/Example/Ibiza.region','Ibiza landed in the Spain set');

# 2 - a second survey: everything identical, nothing to do

$rows = surveyShipped();
ok((grep { $_->{state} ne 'same' } @$rows) == 0,'all identical on a re-survey');
ok((grep { $_->{do} } @$rows) == 0,'nothing ticked when nothing differs');

# 3 - an EDITED file is 'changed' and arrives UNTICKED

open(my $fh,'>>',sourcesDir().'/esri.tsd'); print $fh "\n"; close $fh;
$rows = surveyShipped();
my ($esri) = grep { $_->{rel} eq 'sources/esri.tsd' } @$rows;
ok($esri->{state} eq 'changed','an edited source reads as changed');
ok(!$esri->{do},'a changed file is NOT ticked by default');

# 4 - A FILE THE USER ADDED IS NEVER TOUCHED.  This is the one that
#     matters: the reader's own region lives beside the shipped one.

my $mine = regionSetsDir().'/Example/Formenta.region';
open($fh,'>',$mine); print $fh 'MINE'; close $fh;

$rows = surveyShipped();
ok((grep { $_->{dst} eq $mine } @$rows) == 0,'a user file is not in the survey');

# restore everything that is missing (nothing) plus the changed esri
$_->{do} = 1 for @$rows;
restoreShipped($rows);

open($fh,'<',$mine); my $still = <$fh>; close $fh;
ok(-f $mine,'the user file still exists after a restore');
ok($still eq 'MINE','the user file was not rewritten');

$rows = surveyShipped();
($esri) = grep { $_->{rel} eq 'sources/esri.tsd' } @$rows;
ok($esri->{state} eq 'same','the changed source was restored when ticked');

# 5 - a DELETED shipped file comes back

unlink(regionSetsDir().'/Example/Ibiza.region');
$rows = surveyShipped();
my ($ib) = grep { $_->{rel} =~ /Ibiza/ } @$rows;
ok($ib->{state} eq 'missing','a deleted region reads as missing');
ok($ib->{do},'and it is ticked');
restoreShipped($rows);
ok(-f regionSetsDir().'/Example/Ibiza.region','and it comes back');

print $fails ? "\n$fails FAILURE(S)\n" : "\nall passed\n";
1;
