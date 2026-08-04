#!/usr/bin/perl
#---------------------------------------------
# test_verify.pl -- verifying a source against its service
#---------------------------------------------
# THE OFFLINE HALF IS THE RULES and runs against constructed findings: the
# verdict, the rendering, the run-collapsing of a column, and where a
# canonical point is found.  Those are this module's own logic and deserve
# a test that touches no network at all.
#
# THE LIVE HALF ASKS TWO REAL SERVICES, for the reason the probe's test
# does: a verifier whose whole purpose is to find out what a service does
# today cannot be proved against a recording of what it did once.  What is
# asserted is the SHAPE of the answer - that a working service verifies at
# its canonical point, that a broken url produces problems and not a
# crash - and never a byte count, which would be Esri's bug when it moved.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_state;
use dm_source;
use dm_fetch;
use dm_observe;
use dm_catalog;
use dm_meta;
use dm_verify;

my $TMP = 'C:/_temp/base-apps-chartMaker';
$Pub::Utils::data_dir = "$TMP/verify";
$Pub::Utils::temp_dir = "$TMP/verify/temp";
mkdir $TMP           if !-d $TMP;
mkdir "$TMP/verify"  if !-d "$TMP/verify";

setStandardResourceDir("$app_dir/_res");

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub says
{
	my ($lines,$re) = @_;
	my $t = join(' ',@$lines);
	$t =~ s/\s+/ /g;
	return $t =~ $re ? 1 : 0;
}


#---------------------------------------------
# what the verdict is
#---------------------------------------------
# THREE OUTCOMES AND NOT TWO, and the middle one is the reason this is
# tested at all: a service that publishes no metadata and has no canonical
# point cannot be said to work, and saying so is not the same as failing.

print "\n--- three outcomes, and only one of them is a pass ---\n";

sub finding
{
	my (%o) = @_;
	return {
		id => 'x', name => 'X',
		malformed => $o{malformed} || [],
		refuted   => $o{refuted}   || [],
		notes     => $o{notes}     || [],
		columns   => $o{columns}   || [],
		facts     => [],
	};
}

sub column
{
	my ($kind,@states) = @_;
	my @lev;
	my $z = 0;
	for my $s (@states)
	{
		push @lev,{ z => $z, state => $s, tile => "$z/0/0",
			($s eq 'tile' ? ( bytes => 20000, format => 'jpeg',
							  md5 => 'deadbeef' ) : ( why => 'because' )) };
		$z++;
	}
	return { kind => $kind, where => 'Somewhere', at => [ 1.0,2.0 ],
		why => 'a reason', zmin => 0, zmax => $z-1, levels => \@lev };
}

ok(dm_verify::_verdict(finding(refuted => [{field=>'url',why=>'no'}]))
		eq 'problems',
	'a refuted field is a problem whatever any column said');

ok(dm_verify::_verdict(finding(malformed => [{field=>'id',why=>'no'}]))
		eq 'problems',
	'and so is a field that is malformed before anybody asked');

ok(dm_verify::_verdict(finding(columns => [ column('canonical','tile','tile') ]))
		eq 'verified',
	'a tile at the canonical point is the one thing that verifies');

ok(dm_verify::_verdict(finding(columns => [ column('canonical','none','none') ]))
		eq 'problems',
	'nothing at any level of the canonical column IS a problem');

ok(dm_verify::_verdict(finding(columns => [ column('here','none','none') ]))
		eq 'unrefuted',
	'but nothing at YOUR point is not - a service may hold nothing there');

ok(dm_verify::_verdict(finding(columns => [ column('here','tile') ]))
		eq 'unrefuted',
	'and a tile at your point does not verify either, having nothing to '.
	'be compared against');

ok(dm_verify::_verdict(finding()) eq 'unrefuted',
	'with nowhere asked at all, nothing is refuted and nothing is proved');

ok(dm_verify::_verdict(finding(columns => [ column('canonical','refused') ]))
		eq 'problems',
	'a refusal is a problem');

ok(dm_verify::_verdict(finding(columns => [ column('canonical','garbage') ]))
		eq 'problems',
	'and so is a 200 carrying something that is not an image');


#---------------------------------------------
# the column as a phrase
#---------------------------------------------
# A COLUMN IS NOT MONOTONIC, measured: Japan GSI over Panama answers z3 to
# z8 and nothing above or below.  The phrase has to be able to say that.

print "\n--- a column says which levels held a tile ---\n";

ok(dm_verify::_span(column('canonical','none','none','tile','tile','none'))
		eq 'z2-z3',
	'a run of levels collapses to a range');

ok(dm_verify::_span(column('canonical','tile','none','tile'))
		eq 'z0, z2',
	'and two separated levels stay separate');

ok(dm_verify::_span(column('canonical','none','none')) eq '',
	'a column with no tile in it has no range, and the phrasing is left '.
	'to whoever is saying it');


#---------------------------------------------
# a blank the file does not declare
#---------------------------------------------
# THE COLUMN IS THE ONLY BASELINE, and it gives two signals of very
# different strength.

print "\n--- a 200 that is not imagery, where nothing declared it ---\n";

sub sized
{
	# levels of (bytes,md5) pairs, as a column of tiles
	my (@pairs) = @_;
	my $col = column('canonical',map { 'tile' } @pairs);
	my $z = 0;
	for my $p (@pairs)
	{
		$col->{levels}[$z]{bytes} = $p->[0];
		$col->{levels}[$z]{md5}   = $p->[1];
		$z++;
	}
	return $col;
}

# NOTHING IS COMPUTED HERE ANY MORE.  Repeated bodies are learned in
# dm_fetch, where every tile passes, so this module reads the observation
# record and marks what it already knows.  A second rule here would be a
# second opinion about the same evidence, free to disagree with it on the
# one screen somebody is reading in order to decide.

my $vsrc = { id => 'vfy_marks', cache_key => 'vfy_marks',
			 tile_format => 'jpeg' };

obsCandidateFingerprint($vsrc,2521,'z' x 32,20,3,4,9);

my $marked = sized([20000,'a' x 32],[19000,'b' x 32],
					[2521,'z' x 32],[2521,'z' x 32]);
dm_verify::_suspect($vsrc,$marked);

ok(($marked->{levels}[2]{flag} // '') eq 'poss sentinel',
	'a level whose body the record knows is marked poss sentinel');
ok($marked->{levels}[2]{offer} &&
   $marked->{levels}[2]{offer}{count} == 9,
	"and carries the record's own count, which is a fact about the ".
	'service rather than about this run');
ok(!$marked->{levels}[0]{flag},
	'a body the record has never seen is marked nothing at all');

# SIZE ALONE MARKS NOTHING.  Measured: Esri at Bocas del Toro answers z14
# to z18 with 865 to 1089 byte tiles against a column middle of 8259, and
# every one of them is real imagery of the sea.

my $small = sized([20000,'a' x 32],[19000,'b' x 32],
					[18000,'c' x 32],[929,'d' x 32]);
dm_verify::_suspect($vsrc,$small);
ok(!$small->{levels}[3]{flag},
	'a small tile the record does not know is NOT marked - a blank and '.
	'open water weigh the same');

# AND A CANDIDATE SEEN ONCE IS NOT SHOWN.  One sighting of a body is a
# tile; twice is the beginning of evidence.

my $vonce = { id => 'vfy_once', cache_key => 'vfy_once', tile_format => 'jpeg' };
obsCandidateFingerprint($vonce,2521,'y' x 32,20,3,4,1);
my $once = sized([20000,'a' x 32],[2521,'y' x 32]);
dm_verify::_suspect($vonce,$once);
ok(!$once->{levels}[1]{flag},
	'a candidate the record has seen once is not marked');

# THREE THINGS DISQUALIFY A CANDIDATE, and an offer point in a build report
# has to apply all three or it becomes a nag.

my $vq = { id => 'vfy_q', cache_key => 'vfy_q', tile_format => 'jpeg' };
obsCandidateFingerprint($vq,2521,'a' x 32,20,1,1,9);   # offerable
obsCandidateFingerprint($vq,900, 'b' x 32,20,1,1,1);   # seen once
obsCandidateFingerprint($vq,700, 'c' x 32,20,1,1,9);   # will be declared
obsCandidateFingerprint($vq,600, 'd' x 32,20,1,1,9);   # will be declined

$vq->{absent_fingerprints} = [ { bytes => 700, md5 => 'c' x 32 } ];
obsDeclineFingerprint($vq,'d' x 32);

my @new = verifyNewCandidates($vq);
ok(scalar(@new) == 1 && $new[0]{md5} eq 'a' x 32,
	'only the one that is repeated, undeclared and not yet declined is '.
	'offered (got '.scalar(@new).')');

obsDeclineFingerprint($vq,'a' x 32);
ok(!scalar(verifyNewCandidates($vq)),
	'and saying no to it stops it being asked again');


#---------------------------------------------
# accepting one with no editor open
#---------------------------------------------
# THE OTHER HALF OF THE CONTRACT.  With an editor open the pair goes into
# its visible row and Save writes it; at the end of a build or a probe
# there is no editor, nothing to race, and the file is written here.
#
# THE FILE IS READ AND REWRITTEN, never the loaded source hash - which
# carries fields the loader added and the file does not have.

print "\n--- accepting a fingerprint with no editor open ---\n";

require w_blank;

my $SDIR = "$TMP/verify/sources";
mkdir $SDIR if !-d $SDIR;
open(my $sfh,'>',"$SDIR/wtest.tsd") or die $!;
print $sfh <<'EOJ';
{
  "tsd_version": 1,
  "id": "wtest",
  "cache_key": "wtest",
  "name": "write test",
  "url": "https://w.example.com/{z}/{x}/{y}.jpg",
  "zoom": { "min": 0, "max": 19 },
  "attribution": "test",
  "uses": ["display"]
}
EOJ
close $sfh;
rescanSources();

my $wsrc = getSource('wtest');
ok($wsrc && !$wsrc->{absent_fingerprints},
	'a source with no fingerprints loads');

my $cand = { bytes => 2521, md5 => 'e' x 32, z => 20, x => 1, y => 2,
			 count => 4 };
ok(w_blank::_writeInto($wsrc,$cand),'accepting one writes the file');

rescanSources();
my $after = getSource('wtest');
ok($after && @{$after->{absent_fingerprints} || []} == 1 &&
   $after->{absent_fingerprints}[0]{bytes} == 2521 &&
   $after->{absent_fingerprints}[0]{md5} eq 'e' x 32,
	'and the file still LOADS, with the pair in it');

# ACCEPTING THE SAME ONE TWICE IS A NO-OP.  Two identical entries would
# never match anything the loader normalises, and the second is not an
# error - somebody may simply have been asked again.

ok(!w_blank::_writeInto($after,$cand),'accepting it again writes nothing');
rescanSources();
ok(@{getSource('wtest')->{absent_fingerprints}} == 1,
	'and does not double the entry');

# AND IT IS NO LONGER OFFERED, because the file has answered the question.

obsCandidateFingerprint(getSource('wtest'),2521,'e' x 32,20,1,2,9);
ok(!scalar(verifyNewCandidates(getSource('wtest'))),
	'a declared fingerprint stops being a candidate anywhere');


#---------------------------------------------
# what a person reads
#---------------------------------------------

print "\n--- the report says what it knows and what it does not ---\n";

my $lines = verifyLines(finding(
	refuted => [ { field => 'zoom.max', why => 'the service answers to z12' } ],
	columns => [ column('canonical','tile','tile') ]));

ok(says($lines,qr/DISPROVED BY THE SERVICE/),
	'a refuted field is named under a heading that says who refuted it');
ok(says($lines,qr/zoom\.max - the service answers to z12/),
	'with the field and the reason');
ok(says($lines,qr/shown in the source editor/),
	'and says where it can be fixed, because the catalog has no fields to paint');
ok(says($lines,qr/Nothing was written, here or on disk/),
	'and every report ends by saying nothing was written');

my $mine = verifyLines(finding(columns => [ column('here','none','none') ]));
ok(says($mine,qr/Nothing here is a fault in the source/),
	'an empty column at YOUR point says in words that it is not a failure');

my $none = verifyLines(finding());
ok(says($none,qr/NOWHERE TO ASK/),
	'and with no place at all the report says that rather than implying a pass');

# A UNIFORM COLUMN KEEPS ALL ITS LINES AND GAINS ONE SENTENCE.  The shape
# of a column is what a person reads it for; what twenty identical lines
# fail to supply is the reason, and the reason is what the server said.

my $uniform = column('canonical','garbage','garbage','garbage');
$_->{said} = '{"error":{"code":499,"message":"Token Required"}}'
	for @{$uniform->{levels}};
my $ulines = verifyLines(finding(columns => [ $uniform ]));

ok(scalar(grep { /^   z\d/ } @$ulines) == 3,
	'every level is still printed, because the shape is what is read');
ok(says($ulines,qr/every one of the 3 levels answered the same way/),
	'and a column that answered the same way throughout says so once');
ok(says($ulines,qr/the service said: .*Token Required/),
	'with the words the server actually sent, which is the whole reason '.
	'the column was uniform');

my $mixed = column('canonical','tile','none','tile');
ok(!says(verifyLines(finding(columns => [ $mixed ])),
		qr/answered the same way/),
	'a column that varies claims no such thing');

ok(verifyHeadline(finding(columns => [ column('canonical','tile') ]))
		=~ /works/,
	'the headline is a sentence, not a code');


#---------------------------------------------
# where it would ask
#---------------------------------------------
# THE POINT COMES FROM THE CATALOG OR FROM THE USER AND FROM NOWHERE ELSE.

print "\n--- where a source would be asked ---\n";

loadCatalog();
my $esri = catalogEntry('esri_world_imagery');
ok($esri,'the shipped catalog has Esri World Imagery');

my @places = verifyPlaces(catalogTsd($esri));
ok(scalar(@places) == 1,'a source matching a catalog url gets one place');
ok($places[0]{kind} eq 'canonical','and it is the canonical one');
ok($places[0]{where} eq $esri->{canonical}{where},
	'which is the point the catalog names, whatever that point currently is');

my @nowhere = verifyPlaces({ url => 'https://nobody.example/{z}/{x}/{y}.png',
	cache_key => 'nothing_like_this' });
ok(scalar(@nowhere) == 0,
	'a source in no catalog and no open map has nowhere to be asked, and '.
	'no place is invented for it');

# A SELECTED NODE CONTRIBUTES A POSITION, from the box around what it
# covers.  A box centre can fall outside an L shaped polygon, which is
# tolerable only because this column is descriptive and names the place it
# asked.

my $L = { geometry => [
	[ [ -82.4,9.2 ],[ -82.0,9.2 ],[ -82.0,9.4 ],[ -82.4,9.4 ] ],
	[ [ -82.4,9.4 ],[ -82.3,9.4 ],[ -82.3,9.6 ],[ -82.4,9.6 ] ] ] };
my ($clat,$clon) = dm_verify::_centreOf($L);
ok(abs($clat - 9.4) < 0.001 && abs($clon - (-82.2)) < 0.001,
	"a node's point is the centre of the box around everything it covers ".
	"(got $clat, $clon)");

ok(!defined((dm_verify::_centreOf({ geometry => [] }))[0]),
	'and a node that covers nothing supplies no point rather than 0,0');

# THE CATALOG HANDS ITS OWN POINT OVER, because an entry that has never
# been written to disk cannot be found by matching a url against the
# catalog it is already in.

my $qld = catalogEntry('qld_imagery');
my @given = verifyPlaces({ url => 'https://elsewhere.example/{z}/{x}/{y}' },
	$qld->{canonical});
ok(scalar(@given) == 1 && $given[0]{where} =~ /Moreton Bay/,
	'a caller may supply the point, which is how the catalog tests an entry');


#---------------------------------------------
# against the real thing
#---------------------------------------------

print "\n--- live: a service that works ---\n";

my $good = catalogTsd(catalogEntry('esri_world_imagery'));
$good->{id} = 'esri_live';
my @gplaces = verifyPlaces($good);
my $out = verifySource($good,\@gplaces,undef,'esri.tsd');

ok($out->{verdict} eq 'verified',
	"Esri World Imagery verifies at its canonical point (got $out->{verdict})");
ok(scalar(@{$out->{columns}}) == 1,'one column was walked');
ok(scalar(@{$out->{columns}[0]{levels}}) ==
	$good->{zoom}{max} - $good->{zoom}{min} + 1,
	'every declared level was asked, and none was skipped');
ok(!@{$out->{malformed}},'the shipped entry is well formed');

# THE DECLARED BLANK IS NOT A TILE, and this is the case that proves the
# whole design: Esri declares z23, and at Singapore it answers z20 upward
# with the 2521 byte JPEG this entry declares as an absent_fingerprint.
# A verifier reading the status code would have called all four imagery.

my @blank = grep { $_->{state} eq 'blank' } @{$out->{columns}[0]{levels}};
ok(scalar(@blank),
	'the levels answered with a declared blank are counted as blank and '.
	'not as imagery (got '.scalar(@blank).')');
ok(dm_verify::_span($out->{columns}[0]) !~ /z23/,
	'so the reported ceiling is where the imagery stops, not where the '.
	'file says it does');

print "\n--- live: a url that is wrong ---\n";

my $bad = catalogTsd(catalogEntry('esri_world_imagery'));
$bad->{id}  = 'esri_broken';
$bad->{url} = 'https://services.arcgisonline.com/ArcGIS/rest/services/'.
	'No_Such_Service/MapServer/tile/{z}/{y}/{x}';
$bad->{zoom} = { min => 0, max => 3 };

my $bout = verifySource($bad,[ { kind => 'canonical',
	where => 'Singapore Strait', at => [ 1.26,103.83 ],
	why => 'the catalog names it' } ],undef,'broken.tsd');

ok($bout->{verdict} eq 'problems',
	"a url naming no service is a problem (got $bout->{verdict})");
ok(!(grep { $_->{state} eq 'tile' } @{$bout->{columns}[0]{levels}}),
	'and not one level of its column held a tile');

my $blines = verifyLines($bout);
ok(says($blines,qr/AT Singapore Strait/),
	'the report names where it asked, because a column about nowhere is a '.
	'table of numbers');


#---------------------------------------------

print "\n".($fails ? "$fails FAILURES\n" : "ALL PASSED\n");
exit($fails ? 1 : 0);
