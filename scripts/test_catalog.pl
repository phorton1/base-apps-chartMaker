#!/usr/bin/perl
#---------------------------------------------
# test_catalog.pl -- headless test of dm_catalog.pm
#---------------------------------------------
# THE CATALOG IS PRESUMED COHERENT WITH THE CODE, and this is what makes
# the presumption true rather than hopeful.  It ships with the
# application, so nothing a user does can break it and nothing a user does
# can reveal that it is broken either: the only place that can happen is
# here.
#
# THE ONE TEST THAT MATTERS MOST is that every entry, turned into a field
# hash, is a hash dm_source would LOAD.  An entry that produced a refused
# file would put a red line in the source list with the reason in a log,
# and the person who clicked Create would have no way to know it was not
# their fault.
#
# dm_source IS USED HERE AND NOT IN dm_catalog.  The module produces field
# hashes and knows no TSD rules; the test asks the module that owns those
# rules whether the hashes pass.  That is the whole seam, exercised.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_source;
use dm_catalog;

setStandardResourceDir("$app_dir/_res");

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}


sub says
	# DOES THE PANEL SAY THIS, regardless of where it broke the line.
	#
	# A per-line grep for a phrase is a test of the WRAPPER rather than of
	# the text, and it fails the moment a column changes - which is exactly
	# what happened when the panel learned to wrap.  What these assertions
	# are about is what a person reads, so they read it the way a person
	# does: as one run of words.
{
	my ($lines,$re) = @_;
	my $t = join(' ',@$lines);
	$t =~ s/\s+/ /g;
	return $t =~ $re ? 1 : 0;
}


#---------------------------------------------
# it loads
#---------------------------------------------

print "\n--- the catalog loads ---\n";

my $err = loadCatalog();
ok(!$err,"catalog loads: ".($err || 'no error'));
die "cannot continue without a catalog\n" if $err;

my $root    = catalogRoot();
my $entries = catalogEntries();

ok(scalar(@$root) >= 5,scalar(@$root)." providers at the top level");
ok(scalar(@$entries) >= 8,scalar(@$entries)." entries in all");
ok(!scalar(grep { /surveyed/i && /\d{4}-\d{2}-\d{2}/ } catalogLines($root->[0])),
	"the catalog states no date - the release dates it");


#---------------------------------------------
# every entry would load as a source
#---------------------------------------------

print "\n--- every entry is a source dm_source would accept ---\n";

for my $e (@$entries)
{
	my $leaf = catalogLeaf($e);
	my $tsd  = catalogTsd($e);
	my $why  = checkSource($leaf,$tsd);
	ok(!$why,"$e->{id} -> $leaf".($why ? " : $why" : ''));
}

print "\n--- names, files and identity ---\n";

for my $e (@$entries)
{
	my $tsd = catalogTsd($e);
	ok($tsd->{id} eq $e->{id},"$e->{id} writes its own id");
	ok(catalogLeaf($e) =~ /^[a-z0-9_-]+\.tsd$/,
		"$e->{id} suggests a usable file name: ".catalogLeaf($e));
}

my %seen_leaf;
my $dup = 0;
for my $e (@$entries)
{
	$dup++ if $seen_leaf{lc catalogLeaf($e)}++;
}
ok(!$dup,"no two entries suggest the same file name");

my %seen_key;
my $dupkey = 0;
for my $e (@$entries)
{
	my $ck = catalogTsd($e)->{cache_key};
	next if !defined $ck;
	$dupkey++ if $seen_key{$ck}++;
}
ok(!$dupkey,"no two entries claim the same cache_key");


#---------------------------------------------
# inheritance
#---------------------------------------------

print "\n--- what a child inherits, and what it does not ---\n";

my $bm = catalogEntry('gibs_bluemarble');
ok($bm,'gibs_bluemarble is an entry');
ok($bm->{region} eq 'global','it inherited region from NASA GIBS');
ok(catalogTsd($bm)->{license} =~ /US Government work/,
	'it inherited the licence from NASA GIBS');
ok(catalogTsd($bm)->{redistributable} eq 'yes',
	'it inherited redistributable from NASA GIBS');

my $clarity = catalogEntry('esri_world_imagery_clarity');
ok($clarity,'esri_world_imagery_clarity is an entry');
ok(catalogTsd($clarity)->{attribution} =~ /Esri/,
	'Clarity inherited the Esri attribution');
ok(catalogTsd($clarity)->{uses}[0] eq 'display' &&
	scalar(@{catalogTsd($clarity)->{uses}}) == 1,
	'Clarity inherited display-only uses');
ok(catalogTsd($clarity)->{cache_key} ne
   catalogTsd(catalogEntry('esri_world_imagery'))->{cache_key},
	'Clarity did NOT inherit its parent sibling cache_key');
ok(catalogTsd($clarity)->{url} ne
   catalogTsd(catalogEntry('esri_world_imagery'))->{url},
	'Clarity has its own url');

ok(catalogTsd($bm)->{name} eq
	'NASA GIBS - Blue Marble shaded relief and bathymetry',
	'an entry that states its own tsd name keeps it');
ok($bm->{path} eq 'NASA GIBS / Blue Marble shaded relief and bathymetry',
	'the tree path reads as provider then entry');


#---------------------------------------------
# the shipped .tsd files and the catalog agree
#---------------------------------------------
# THE THREE FILES THAT SHIP ARE ALSO CATALOG ENTRIES, which is two hand
# maintained statements of one thing.  They will drift unless something
# compares them, and the place a drift bites is a user who installs the
# app, then opens the catalog and is offered what they already have under
# a url that no longer matches.

print "\n--- the shipped .tsd files agree with the catalog ---\n";

for my $pair ( [ 'bluemarble.tsd','gibs_bluemarble' ],
			   [ 'weld_annual.tsd','gibs_weld_annual' ],
			   [ 'esri.tsd','esri_world_imagery' ] )
{
	my ($leaf,$id) = @$pair;
	my $path = "$app_dir/_res/user_data/$leaf";
	my $node = catalogEntry($id);
	if (!-f $path || !$node)
	{
		ok(0,"$leaf and catalog entry $id both exist");
		next;
	}

	open(my $fh,'<',$path);
	binmode $fh;
	local $/ = undef;
	my $text = <$fh>;
	close $fh;
	my $file = eval { JSON::PP::decode_json($text) };

	my $tsd = catalogTsd($node);
	ok($file && $file->{url} eq $tsd->{url},"$leaf url matches entry $id");
	ok($file && $file->{id} eq $tsd->{id},"$leaf id matches entry $id");
	ok($file && ($file->{cache_key} // '') eq ($tsd->{cache_key} // ''),
		"$leaf cache_key matches entry $id");
	ok($file && $file->{zoom}{max} == $tsd->{zoom}{max},
		"$leaf zoom.max matches entry $id");
}

# GOOGLE SHIPS AND IS DELIBERATELY NOT CATALOGUED.  Shipping a definition
# somebody can read and delete is one act; offering it from a list is
# another, and this is the decision recorded where it can be broken by
# accident.

ok(-f "$app_dir/_res/user_data/google.tsd",'google.tsd still ships');
ok(!catalogEntry('google_satellite'),
	'google is deliberately NOT a catalog entry');


#---------------------------------------------
# coherence with the published catalog document
#---------------------------------------------
# THE JOIN COLUMN, ASSERTED.  A fact about a service enters at the survey,
# is distilled into docs/notes/source_catalog.md and is codified here, and
# the moniker is what makes one end checkable against the other.  Until it
# existed the three files were three retellings: a hostname invented in
# the middle one reached this one with a confident sentence attached and
# nothing could have caught it.
#
# It asserts the direction that can be asserted.  Every service the
# application SHIPS must be documented; the document holds far more
# services than ship, which is what a survey is for, so the reverse is not
# a rule.

print "\n--- every shipped moniker is documented ---\n";

my $doc = "$app_dir/docs/notes/source_catalog.md";
if (open(my $fh,'<',$doc))
{
	local $/ = undef;
	my $text = <$fh>;
	close $fh;

	my %said;
	$said{$1}++ while $text =~ /`([a-z0-9_]+)`/g;

	my %want;
	for my $e (@$entries)
	{
		ok($e->{moniker},"$e->{id} names a moniker");
		$want{$e->{moniker}}++ if $e->{moniker};
	}
	for my $m (sort keys %want)
	{
		ok($said{$m},"moniker '$m' appears in source_catalog.md");
	}
}
else
{
	ok(0,"$doc is readable");
}


#---------------------------------------------
# the plan
#---------------------------------------------
# EVERY BRANCH OF IT, with no sources folder anywhere - which is the point
# of catalogPlan being told what is installed rather than asking.

print "\n--- what Create would do ---\n";

my $none = { ids => {}, leaves => {}, keys => {} };
my $plan = catalogPlan($entries,$none);
ok(scalar(@$plan) == scalar(@$entries),'a plan has one row per entry');
ok(scalar(grep { $_->{action} eq 'create' } @$plan) == scalar(@$entries),
	'with nothing installed, every entry is a create');

my $esri = catalogEntry('esri_world_imagery');

my $have_id = { ids => { esri_world_imagery => 'mine.tsd' },
				leaves => { 'mine.tsd' => 1 }, keys => {} };
$plan = catalogPlan([$esri],$have_id);
ok($plan->[0]{action} eq 'skip','an installed id is skipped');
ok($plan->[0]{why} =~ /already installed as mine\.tsd/,
	'and it says where it is installed');

my $have_leaf = { ids => {}, leaves => { 'esri.tsd' => 1 }, keys => {} };
$plan = catalogPlan([$esri],$have_leaf);
ok($plan->[0]{action} eq 'create','a taken file name is not a refusal');
ok($plan->[0]{leaf} eq 'esri-2.tsd','the file name is the thing that moves');
ok($plan->[0]{why} =~ /renamed/,'and the rename is stated');

my $have_key = { ids => {}, leaves => {},
	keys => { esri => { leaf => 'other.tsd',
					    url => 'https://example.com/{z}/{x}/{y}' } } };
$plan = catalogPlan([$esri],$have_key);
ok($plan->[0]{action} eq 'skip',
	'a cache_key held against a DIFFERENT url is skipped, never renamed');
ok($plan->[0]{why} =~ /other\.tsd/,'and it names the file holding it');

my $same_key = { ids => {}, leaves => {},
	keys => { esri => { leaf => 'other.tsd',
					    url => catalogTsd($esri)->{url} } } };
$plan = catalogPlan([$esri],$same_key);
ok($plan->[0]{action} eq 'create',
	'a cache_key held against the SAME url is not a collision');

# TWO ENTRIES IN ONE PLAN MUST NOT COLLIDE WITH EACH OTHER.  A plan that
# only checked what was on disk would happily schedule two writes to one
# name and report both as creations.

$plan = catalogPlan([$esri,$esri],$none);
ok($plan->[0]{action} eq 'create' && $plan->[1]{action} eq 'skip',
	'the same entry twice in one plan is created once');

my $lines = catalogPlanLines(catalogPlan($entries,$none));
ok(scalar(@$lines) > 5,'the plan renders as lines a person can read');


#---------------------------------------------
# the detail panel
#---------------------------------------------

print "\n--- the detail panel ---\n";

my $l = catalogLines($esri);
ok(scalar(grep { /^url / } @$l),'the panel shows the url');
ok(says($l,qr/surveyed by a person/),
	'the panel says who judged it');
ok(!says($l,qr/\d{4}-\d{2}-\d{2}/),
	'and states no date, which is source_catalog.md\'s job');
ok(says($l,qr/starting point for checking/),
	'and does not claim to be current');

my $linz = catalogEntry('linz_aerial');
ok($linz,'linz_aerial is an entry');
$l = catalogLines($linz);
ok(scalar(grep { /key\s+linz_api_key/ } @$l),
	'a keyed entry names the key_name it needs');
ok(says($l,qr/NOT SET/) || says($l,qr/key linz_api_key - set/),
	'and says whether anything is bound to it');
ok(says($l,qr/basemaps\.linz\.govt\.nz/),
	'and where to get one, which is the whole point of obtain_url');
ok(!checkSource(catalogLeaf($linz),catalogTsd($linz)),
	'a keyed entry still produces a file dm_source would load');

# AND THE EDITOR MUST AGREE WITH THE LOADER ABOUT IT.  The Edit exit hands
# this hash straight to w_source, which colours and gates Save from the
# per-FIELD check.  When that check did not know about declared key_names
# it refused a url the loader accepts, so a keyed entry could be created
# and then never saved.

my $ltsd = catalogTsd($linz);
ok(!checkSourceField('url',$ltsd->{url},$ltsd->{keys}),
	'and the per-field check accepts its url given the declared key_names');
ok(checkSourceField('url',$ltsd->{url}),
	'while the same url with nothing declared is still refused');

$l = catalogLines($root->[0]);
ok(says($l,qr/entries below this|entry below this/),
	'a group says how many entries are under it');


#---------------------------------------------
# the panel wraps
#---------------------------------------------
# EVERY LINE FITS THE PANEL EXCEPT THE ONES THAT CANNOT.  A url is one
# unbreakable word and stays whole on purpose - broken across lines it
# could not be copied - so the check is that anything over the column
# contains no space to have broken at.

print "\n--- the panel wraps ---\n";

my $WRAP = 72;
my $LVAL = 16;

my ($long,$badwrap,$badcont) = (0,0,0);
for my $node (@$entries,@$root)
{
	for my $line (@{catalogLines($node)})
	{
		next if length($line) <= $WRAP;

		# THE VALUE REGION IS WHAT IS JUDGED, and it begins at the label
		# column whether the line carries a label or is a continuation of
		# one.  Everything past there must be a single token: if it has a
		# space in it, the wrapper had somewhere to break and did not.

		my $tail = length($line) > $LVAL + 1 ?
			substr($line,$LVAL + 1) : $line;
		$long++;
		$badwrap++ if $tail =~ /\s/;
	}
}
ok(!$badwrap,
	"no line overflows that had a space to wrap at ($long long, ".
	"all unbreakable)");

# A WRAPPED VALUE LINES UP UNDER ITS VALUE, not back at the margin.

my $esri_lines = catalogLines($esri);
my $found_cont = 0;
for my $i (1 .. $#$esri_lines)
{
	my $prev = $esri_lines->[$i-1];
	my $line = $esri_lines->[$i];
	next if $line !~ /^\s{$LVAL}\s\S/;
	next if $prev !~ /^\S/;
	$found_cont++;
}
ok($found_cont,
	"a long labelled value continues at the value column ($found_cont found)");

# AND A PARAGRAPH WRAPS BACK TO THE MARGIN.

my $note_wrapped = 0;
for my $line (@{catalogLines($esri)})
{
	$note_wrapped++ if $line =~ /^\S/ && length($line) > 40 &&
					   length($line) <= $WRAP;
}
ok($note_wrapped > 1,
	"a paragraph wraps back to the left margin ($note_wrapped lines)");

ok(scalar(grep { /^url\s+\S+$/ } @{catalogLines($esri)}) == 1,
	'the url is one line and was not broken');


#---------------------------------------------
# expanding a provider
#---------------------------------------------
# ENTIRELY OFFLINE.  Reading a capabilities document is dm_meta's job and
# is tested against the live service there; what is tested here is what
# this module does with the answer, which must not need a network to
# check.

#---------------------------------------------
# the canonical point
#---------------------------------------------
# WHERE TO ASK A SERVICE ABOUT ITSELF, and the reason it is curated rather
# than derived.  Measured against the live services: one labelled 'Japan'
# serves real imagery over Panama at z3 and z8, one labelled 'France'
# serves Bocas del Toro at z12, and 'Spain' answers outside Spain with a
# 200 carrying a blank JPEG.  Region prose predicts nothing, and neither
# does the middle of a bounding box.

print "\n--- every service says where to ask it ---\n";

my ($no_where,$no_why,$off_earth) = (0,0,0);
for my $svc (@$root)
{
	my $c = $svc->{canonical};
	if (!$c) { $no_where++; $no_why++; next; }
	$no_where++ if !defined $c->{where} || $c->{where} !~ /\S/;
	$no_why++   if !defined $c->{why}   || $c->{why}   !~ /\S/;
	next if !$c->{at};
	my ($lat,$lon) = @{$c->{at}};
	$off_earth++ if $lat < -85 || $lat > 85 || $lon < -180 || $lon > 180;
}
ok(!$no_where,"every shipped service names a place ($no_where without)");
ok(!$no_why,"and says why there ($no_why without)");
ok(!$off_earth,"and every point is on the earth ($off_earth not)");

# INHERITED, BECAUSE WHERE A SERVICE HAS IMAGERY IS A FACT ABOUT THE
# SERVICE.  Every layer GIBS publishes covers the same ground, so asking
# each of them to name its own place would be a thousand copies of one
# answer, free to disagree.

my ($gibs_svc) = grep { $_->{id} eq 'gibs' } @$root;
my $bm = catalogEntry('gibs_bluemarble');

# ASSERTED AGAINST THE SERVICE AND NOT AGAINST A CITY.  Which point is the
# right one is a judgement that will move; that a layer carries its
# service's is the rule, and naming the place here would make every future
# change of mind break a test that is not about the place at all.

ok($bm && $bm->{canonical} && $gibs_svc->{canonical} &&
   $bm->{canonical}{where} eq $gibs_svc->{canonical}{where},
	'a layer inherits the canonical point of its service');

my $expect = sprintf("ask it at %s %.4f, %.4f",
	$gibs_svc->{canonical}{where},@{$gibs_svc->{canonical}{at}});
ok(says(catalogLines($bm),qr/\Q$expect\E/),
	'the panel names the place and the position');
ok(says(catalogLines($bm),qr/why there \S/),
	'and gives the reason, which is the whole point of the point');


print "\n--- expanding a provider ---\n";

my $gibs = undef;
for my $n (@$root) { $gibs = $n if $n->{id} eq 'gibs' }
ok($gibs,'NASA GIBS is a group');
ok(catalogExpander($gibs),'and it declares an expander');
ok(catalogExpander($gibs)->{kind} eq 'wmts','of kind wmts');
ok(catalogExpander($gibs)->{url} =~ /WMTSCapabilities/,
	'naming a capabilities document rather than a tile url');
ok(!catalogExpander($esri),
	'Esri declares none - one MapServer publishes one layer, so there is '.
	'no list to fetch');

my $before = scalar(@{$gibs->{kids}});
my ($added,$known) = catalogAttach($gibs,[
	{ id => 'MODIS_Terra_X', name => 'MODIS Terra thing',
	  url => 'https://gibs.earthdata.nasa.gov/x/{z}/{y}/{x}.jpeg',
	  zmin => 0, zmax => 9, tile_format => 'jpeg',
	  tms => 'GoogleMapsCompatible_Level9', notes => 'read from the service' },
	{ id => 'Another_Layer', name => 'Another layer',
	  url => 'https://gibs.earthdata.nasa.gov/y/{z}/{y}/{x}.png',
	  zmin => 0, zmax => 6, tile_format => 'png',
	  tms => 'GoogleMapsCompatible_Level6', notes => 'read from the service' },
]);
ok($added == 2,"two fetched layers attached (got $added)");

# BOTH KINDS ARRIVED, SO THE PNG ONE IS FOLDED.  The service gains the jpeg
# layer and ONE group holding the rest, and that group is an ordinary group
# - which is the whole of the fold.  The tree, the filter and the big-group
# rule all understand it already and were not told about it.

ok(scalar(@{$gibs->{kids}}) == $before + 2,
	'the jpeg layer and one fold group hang under the service');

my ($fold) = grep { !$_->{is_entry} && $_->{id} eq 'gibs_png_only' }
	@{$gibs->{kids}};
ok($fold,'a fold group was made');
ok(scalar(@{$fold->{kids}}) == 1 &&
   $fold->{kids}[0]{id} eq 'gibs_another_layer',
	'and the png layer is inside it');

# A FOLDED LAYER IS NOT A LESSER ONE.  It is addressable, it inherits the
# provider's terms from the SERVICE rather than from the fold, and it
# creates a file exactly like an unfolded one.  A fold that changed what a
# layer WAS would be a filter wearing a disguise.

my $folded = catalogEntry('gibs_another_layer');
ok($folded,'a folded layer is addressable by id like any other');
ok(catalogTsd($folded)->{license} =~ /US Government work/,
	'and inherits the provider licence through the fold');
ok($folded->{canonical} &&
   $folded->{canonical}{where} eq $gibs_svc->{canonical}{where},
	'and the canonical point too, so a fetched layer knows where to be asked');
ok(!checkSource(catalogLeaf($folded),catalogTsd($folded)),
	'and still produces a file dm_source would load');
ok($folded->{path} =~ /published only as PNG/,
	'its path says which group it is in');

# ONE KIND ONLY MEANS NO FOLD.  Esri Wayback's 195 releases are all jpeg,
# and folding a list like that would hide everything while separating
# nothing.  Tested on IGN France, which is expandable and is not the node
# a later test needs to find empty.

my $one = undef;
for my $n (@$root) { $one = $n if $n->{id} eq 'ign_fr' }
ok($one,'IGN France is an expandable group');

my $one_before = scalar(@{$one->{kids}});
catalogAttach($one,[
	{ id => 'Ortho_A', name => 'ortho A',
	  url => 'https://data.geopf.fr/a/{z}/{y}/{x}.jpeg',
	  zmin => 0, zmax => 19, tile_format => 'jpeg',
	  tms => 'PM', notes => '' },
	{ id => 'Ortho_B', name => 'ortho B',
	  url => 'https://data.geopf.fr/b/{z}/{y}/{x}.jpeg',
	  zmin => 0, zmax => 19, tile_format => 'jpeg',
	  tms => 'PM', notes => '' },
]);
ok(scalar(@{$one->{kids}}) == $one_before + 2,
	'both layers hang directly under it');
ok(!(grep { !$_->{is_entry} } @{$one->{kids}}),
	'and no fold group was invented for a service publishing one kind');

my $fetched = catalogEntry('gibs_modis_terra_x');
ok($fetched,'a fetched layer is addressable by its derived id');
ok($fetched->{fetched},'and is marked as fetched rather than shipped');
ok($fetched->{is_entry},'and behaves as an ordinary entry');

# THE POINT OF THE WHOLE EXERCISE: what the service published has to be
# writable as a source, by exactly the path a shipped entry uses.

my $ftsd = catalogTsd($fetched);
ok(!checkSource(catalogLeaf($fetched),$ftsd),
	'a fetched layer produces a file dm_source would load');
ok($ftsd->{license} =~ /US Government work/,
	'it inherited the provider licence a capabilities document does not carry');
ok($ftsd->{zoom}{max} == 9,'and kept the ceiling the service stated');
ok($ftsd->{cache_key} eq 'gibs_modis_terra_x',
	'its cache_key is its own, not the provider group is');

my $flines = catalogLines($fetched);
ok(says($flines,qr/read from the service just now/),
	'the panel says where it came from');
ok(!(grep { /surveyed 2026/ } @$flines),
	'and does NOT claim a survey date it was never part of');
ok(says($flines,qr/judged by nobody/),
	'and says plainly that nothing has judged it');

# A SHIPPED ENTRY WINS.  The curated one carries a measured depth and a
# sentence about what it is worth; the machine's version carries neither.

my ($again,$dup) = catalogAttach($gibs,[
	{ id => 'MODIS_Terra_X', name => 'MODIS Terra thing again',
	  url => 'https://gibs.earthdata.nasa.gov/z/{z}/{y}/{x}.jpeg',
	  zmin => 0, zmax => 9, tile_format => 'jpeg',
	  tms => 'GoogleMapsCompatible_Level9', notes => '' },
]);
ok($again == 0 && $dup == 1,'a layer already known is skipped, not doubled');

# AND A FETCHED ENTRY GOES THROUGH THE SAME CREATE PLAN, with no special
# case anywhere - which is the whole reason it was built as a node rather
# than as a second kind of thing.

my $fplan = catalogPlan([$fetched],$none);
ok($fplan->[0]{action} eq 'create','a fetched entry plans as an ordinary create');
ok($fplan->[0]{leaf} eq 'gibs_modis_terra_x.tsd','with its own file name');


#---------------------------------------------
# a group that fills itself
#---------------------------------------------

print "\n--- an empty group is legal only if it can fill itself ---\n";

my $way = catalogEntry('esri_wayback');
ok(!$way,'esri_wayback is not an entry - it ships nothing');

my $wnode;
my $walk;
$walk = sub {
	for my $n (@{$_[0]})
	{
		$wnode = $n if $n->{id} eq 'esri_wayback';
		$walk->($n->{kids}) if @{$n->{kids}};
	}
};
$walk->($root);
ok($wnode,'but it is a group in the tree');
ok($wnode && !@{$wnode->{kids}},'with nothing under it');
ok($wnode && catalogExpander($wnode),
	'because everything it offers is what the service publishes live');


#---------------------------------------------
# the catalog validates itself
#---------------------------------------------
# A FAULT HERE IS A BUG IN THE SHIPPED FILE, so the only place it can be
# caught is a test.  These point $resource_dir at fixtures and put it back.

print "\n--- a broken catalog is refused, with a reason ---\n";

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $keep = $Pub::Utils::resource_dir;

sub badCatalog
{
	my ($name,$json) = @_;
	my $dir = "$TMP/cat_$name";
	mkdir $TMP  if !-d $TMP;
	mkdir $dir  if !-d $dir;
	open(my $fh,'>',"$dir/catalog.json") or die "cannot write: $!";
	print $fh $json;
	close $fh;
	$Pub::Utils::resource_dir = $dir;
	return dm_catalog::loadCatalog(1);
}

ok(badCatalog('empty','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "X", "nodes": [] } ] }') =~ /declares no expander/,
	'an empty group with no expander is refused');

my $ENT = '"tsd": { "url": "http://a/{z}/{x}/{y}", '.
		  '"zoom": {"min":0,"max":1}, "attribution": "a" }';

ok(badCatalog('can_obj','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "X", "canonical": "Tokyo", '.$ENT.' } ] }')
		=~ /canonical.*not an object/,
	'a canonical that is not an object is refused');

ok(badCatalog('can_why','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "X", "canonical": { "where": "Tokyo" }, '.$ENT.
	' } ] }') =~ /needs a 'where' and a 'why'/,
	'a canonical place with no reason is refused - the reason IS the point');

ok(badCatalog('can_lat','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "X", "canonical": { "where": "Tokyo", '.
	'"why": "because", "at": [ 95.0, 139.0 ] }, '.$ENT.' } ] }')
		=~ /latitude.*between -85 and 85/,
	'and a latitude off the mercator grid is refused where it was written');

ok(badCatalog('kind','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "X", "expander": { "kind": "soap", "url": "u" }, '.
	'"nodes": [] } ] }') =~ /cannot read/,
	'an expander of an unknown kind is refused');

ok(badCatalog('dup','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "A", "tsd": { "url": "http://a/{z}/{x}/{y}", '.
	'"zoom": {"min":0,"max":1}, "attribution": "a" } }, '.
	'{ "id": "x", "name": "B", "tsd": { "url": "http://b/{z}/{x}/{y}", '.
	'"zoom": {"min":0,"max":1}, "attribution": "b" } } ] }')
	=~ /appears twice/,
	'two nodes claiming one id are refused');

ok(badCatalog('ver','{ "catalog_version": 99, "nodes": [] }')
	=~ /newer than this application/,
	'a catalog from the future is refused rather than half read');

ok(badCatalog('neither','{ "catalog_version": 1, "nodes": [ '.
	'{ "id": "x", "name": "X" } ] }')
	=~ /neither a group nor an entry/,
	'a node that is neither a group nor an entry is refused');

$Pub::Utils::resource_dir = $keep;
ok(!dm_catalog::loadCatalog(1),'and the shipped catalog still loads after');


#---------------------------------------------
# displacement
#---------------------------------------------
# THE FIELD THE SURVEY SINGLED OUT.  Where imagery is known to be
# misregistered, the moment somebody creates a source from an entry is the
# moment to say so - and the panel used to drop the field silently.

print "\n--- a displaced source says so ---\n";

my $disp = {
	id => 'x', name => 'X', is_entry => 1, path => 'X', kids => [],
	tsd => { id => 'x', name => 'X', url => 'http://a/{z}/{x}/{y}',
			 zoom => { min => 0, max => 1 }, uses => ['display'],
			 attribution => 'a', displacement => 'GCJ-02' } };
my $dl = catalogLines($disp);
ok(scalar(grep { /^displacement\s+GCJ-02/ } @$dl),'the panel names the datum');
ok(says($dl,qr/does NOT correct it/),
	'and says in the same breath that nothing acts on it');


#---------------------------------------------

print "\n".($fails ? "$fails FAILURE".($fails == 1 ? '' : 'S')
				   : "ALL PASSED")."\n\n";
exit($fails ? 1 : 0);
