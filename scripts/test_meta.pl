#!/usr/bin/perl
#---------------------------------------------
# test_meta.pl -- the metadata reader, against real services
#---------------------------------------------
# HITS THE LIVE ArcGIS AND GIBS ENDPOINTS, deliberately.  A reader whose
# whole purpose is to find out what a service actually says cannot be
# tested against a fixture of what it said once: the fixture would keep
# passing after the service changed, which is the single failure this
# feature exists to catch.
#
# THIS IS NOT THE PROBE.  dm_meta reads a description and fetches no
# imagery at all; the probe is dm_sample, which sweeps real tiles over an
# area and is tested in test_sample.pl.  Both were called probe once, and
# that is why every sentence about either of them used to be ambiguous.
#
# What is asserted is therefore the SHAPE of the answer and the rules
# applied to it, not the values.  'ArcGIS declares a ceiling' is a claim
# about this module; 'ArcGIS declares z23' is a claim about Esri, and would
# be someone else's bug when it broke.
#
# The offline half - family detection, the maxScale rule, tilemap decoding
# and the disagreement list - runs against constructed inputs at the end,
# because those are this module's own logic and deserve a test that does
# not depend on a network at all.

use strict;
use warnings;
use LWP::UserAgent;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_source;
use dm_fetch;
use dm_observe;
use dm_meta;

my $TMP = 'C:/_temp/base-apps-chartMaker';
$Pub::Utils::data_dir = "$TMP/probe";
$Pub::Utils::temp_dir = "$TMP/probe/temp";

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub putSource
{
	my ($leaf,$json) = @_;
	mkdir "$TMP/probe"          if !-d "$TMP/probe";
	mkdir "$TMP/probe/sources"  if !-d "$TMP/probe/sources";
	open(my $fh,'>',"$TMP/probe/sources/$leaf") or die $!;
	print $fh $json;
	close $fh;
}


#---------------------------------------------
# fixtures -- the two shipped sources, copied
#---------------------------------------------

unlink glob("$TMP/probe/sources/*.tsd");

putSource('esri.tsd',<<'EOJ');
{
  "tsd_version": 1,
  "id": "esri_world_imagery",
  "name": "Esri - ArcGIS World Imagery",
  "url": "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",
  "tile_format": "jpeg",
  "zoom": { "min": 0, "max": 23 },
  "attribution": "Esri",
  "uses": ["display","build"]
}
EOJ

putSource('weld_annual.tsd',<<'EOJ');
{
  "tsd_version": 1,
  "id": "gibs_weld_annual",
  "name": "NASA GIBS - Landsat WELD True Colour",
  "url": "https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/Landsat_WELD_CorrectedReflectance_TrueColor_Global_Annual/default/2000-12-01/GoogleMapsCompatible_Level12/{z}/{y}/{x}.jpeg",
  "tile_format": "jpeg",
  "zoom": { "min": 0, "max": 12 },
  "attribution": "NASA",
  "uses": ["display","build"]
}
EOJ

# THE ROW ORDER MISTAKE, ON PURPOSE.  Same service, same everything, one
# character different: {z}/{x}/{y} where Esri wants {z}/{y}/{x}.  Every
# tile would arrive and the map would be scrambled, which is the failure
# a probe earns its keep by catching.

putSource('esri_wrong.tsd',<<'EOJ');
{
  "tsd_version": 1,
  "id": "esri_scrambled",
  "name": "Esri, addressed column-before-row on purpose",
  "url": "https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{x}/{y}",
  "tile_format": "png",
  "zoom": { "min": 0, "max": 24 },
  "attribution": "Esri",
  "uses": ["display"]
}
EOJ

putSource('plain.tsd',<<'EOJ');
{
  "tsd_version": 1,
  "id": "plain_xyz",
  "name": "An ordinary xyz service with no metadata endpoint",
  "url": "https://tile.example.com/{z}/{x}/{y}.png",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "nobody",
  "uses": ["display"]
}
EOJ

rescanSources();
obsLoad();


#---------------------------------------------
# ArcGIS
#---------------------------------------------

print "=== ArcGIS MapServer, live ===\n";

my $esri = getSource('esri_world_imagery') or die "no esri source\n";
my $p = metaSource($esri);

ok($p->{family} eq 'arcgis',"family detected as arcgis (got '$p->{family}')");
ok($p->{ok},"the MapServer answered".($p->{ok} ? '' : " - $p->{reason}"));

if ($p->{ok})
{
	ok(defined($p->{zmax}) && $p->{zmax} > 0,
		"a ceiling was derived (z$p->{zmax})");
	ok($p->{format} eq 'jpeg',"format read as '$p->{format}'");
	ok($p->{wkid} == 3857,"spatial reference read as wkid $p->{wkid}");
	ok($p->{tile_size} == 256,"tile size read as $p->{tile_size}");
	ok($p->{row_order} eq 'row-before-column',
		"the family's row order is known");
	ok(scalar(@{$p->{facts}}) >= 6,
		scalar(@{$p->{facts}})." facts reported without fetching a tile");
	ok($p->{bytes} > 0,"the metadata document was ".$p->{bytes}." bytes");

	# THE maxScale RULE.  Esri publishes maxScale 0, which declares
	# nothing, so the ceiling must have come from the LODs instead.  The
	# assertion is that the rule FIRED, not what Esri happens to publish.

	my ($ms_fact) = grep { $_->[0] eq 'maxScale' } @{$p->{facts}};
	ok($ms_fact,"maxScale was examined and reported: '$ms_fact->[1]'");

	# A CORRECT FILE SHOULD DISAGREE ABOUT NOTHING STRUCTURAL.
	ok(!grep({ /scrambled/ } @{$p->{disagree}}),
		"a correctly addressed file raises no row-order disagreement");
}

print "\n=== the same service, addressed wrongly ===\n";

my $bad = getSource('esri_scrambled') or die "no scrambled source\n";
my $pb = metaSource($bad);
ok($pb->{ok},"the probe still succeeds - the FILE is wrong, not the service");

if ($pb->{ok})
{
	ok(scalar(grep { /scrambled/ } @{$pb->{disagree}}),
		"the row order disagreement is reported");
	ok(scalar(grep { /format/ } @{$pb->{disagree}}),
		"and so is the format the file expects");
	ok(scalar(grep { /zoom\.max/ } @{$pb->{disagree}}),
		"and a zoom.max above what the service answers to");

	print "  --- what a person would read ---\n";
	print "  $_\n" for @{metaLines($pb)};
}


#---------------------------------------------
# WMTS
#---------------------------------------------

print "\n=== WMTS GetCapabilities, live ===\n";

my $gibs = getSource('gibs_weld_annual') or die "no gibs source\n";
my $pw = metaSource($gibs);

ok($pw->{family} eq 'wmts',"family detected as wmts (got '$pw->{family}')");
ok($pw->{ok},"GetCapabilities answered".($pw->{ok} ? '' : " - $pw->{reason}"));

if ($pw->{ok})
{
	ok(defined($pw->{zmax}),"a ceiling was derived (z$pw->{zmax})");
	ok($pw->{tms},"the tile matrix set was named ($pw->{tms})");
	ok($pw->{row_order} eq 'row-before-column',
		"the row order came from the service's OWN published template");
	ok($pw->{format} eq 'jpeg',"format read as '$pw->{format}'");
	ok(!@{$pw->{disagree}},
		"the shipped file agrees with the service (".
		scalar(@{$pw->{disagree}})." disagreement(s))");
	print "  --- what a person would read ---\n";
	print "  $_\n" for @{metaLines($pw)};
}


#---------------------------------------------
# a service with nothing to ask
#---------------------------------------------

print "\n=== no metadata endpoint ===\n";

my $plain = getSource('plain_xyz') or die "no plain source\n";
my $pp = metaSource($plain);
ok($pp->{family} eq 'unknown',"family is unknown");
ok(!$pp->{ok},"and the probe reports that rather than failing at it");
ok($pp->{reason} =~ /no metadata endpoint/,
	"with a reason a person can act on");

# NOT AN ERROR, AND THE RENDERING MUST NOT LOOK LIKE ONE.
my $lines = metaLines($pp);
ok(scalar(grep { /only ever reports/ } @$lines),
	"and the text says plainly that nothing was changed");


#---------------------------------------------
# tilemap -- the placed one
#---------------------------------------------

print "\n=== tilemap, the cheap coverage answer ===\n";

if ($p->{ok} && $p->{has_tilemap})
{
	ok(1,"the service's capabilities advertise Tilemap");

	# Bocas del Toro at z10, where there is certainly imagery.
	my $tm = metaTilemap($esri,10,278,485,4,4);
	ok($tm->{ok},"a 4x4 block answered".($tm->{ok} ? '' : " - $tm->{reason}"));
	ok($tm->{ok} && $tm->{count_total} == 16,
		"16 tiles answered by ONE request");
	ok($tm->{ok} && $tm->{count_present} == 16,
		"and all 16 are present over Bocas at z10 ".
		"($tm->{count_present}/$tm->{count_total})");

	# The same place at z19, deeper than Esri's real imagery there.  This
	# is the answer the sampler would otherwise pay 64 fetches for.

	my $deep = metaTilemap($esri,19,142559,248534,8,8);
	ok($deep->{ok},"a 8x8 block at z19 answered");
	ok($deep->{ok} && $deep->{count_total} == 64,
		"64 tiles answered by ONE request");
	print "  z19 over Bocas: $deep->{count_present} of $deep->{count_total} present\n"
		if $deep->{ok};
}
else
{
	ok(0,"the service did not advertise Tilemap - cannot test it");
}

my $none = metaTilemap($plain,10,1,1,4,4);
ok(!$none->{ok},"tilemap refuses a non-ArcGIS source rather than guessing");


#---------------------------------------------
# what reached the observation record
#---------------------------------------------

print "\n=== the findings are remembered, not applied ===\n";

my $rec = obsRecord($esri);
ok($rec->{meta_family} eq 'arcgis',"the family reached the observation record");
ok($rec->{meta_zmax} > 0,"and the ceiling (z$rec->{meta_zmax})");
ok($rec->{meta_probed_at} > 0,"and when it was probed");
ok(-f obsDir()."/esri.json","and it reached disk, keyed by cache_key");

# THE POINT OF THE WHOLE MODULE.  A probe that edited the file would make
# every TSD a cache of a server's current mood.

my $before = do { open(my $fh,'<',"$TMP/probe/sources/esri_wrong.tsd"); local $/; <$fh> };
metaSource($bad);
my $after = do { open(my $fh,'<',"$TMP/probe/sources/esri_wrong.tsd"); local $/; <$fh> };
ok($before eq $after,"probing a file with ".scalar(@{$pb->{disagree}}).
	" disagreements does not touch it");


#---------------------------------------------
# against the stub -- the branches a real service will not produce
#---------------------------------------------
# TWO THINGS THE LIVE SERVICES CANNOT TEST, and both are branches that
# fail silently rather than loudly if they are wrong.
#
# Esri publishes maxScale 0, so the live probe only ever reaches the
# 'declares nothing' half of the maxScale rule.  And Esri answers a fully
# covered tilemap block with an explicit array of ones, so the COMPRESSED
# form - 'valid' with no data array at all - never arrives.  That one
# reads as an EMPTY block to anyone who did not handle it, which is the
# worst possible way to be wrong about coverage.

print "\n=== the branches a real service will not produce (stub) ===\n";

my $STUB_PORT = 9899;
my $STUB      = "http://127.0.0.1:$STUB_PORT";

putSource('stub_arcgis.tsd',<<"EOJ");
{
  "tsd_version": 1,
  "id": "stub_arcgis",
  "name": "A stub shaped like an ArcGIS MapServer",
  "url": "$STUB/ArcGIS/rest/services/Stub/MapServer/tile/{z}/{y}/{x}",
  "tile_format": "jpeg",
  "zoom": { "min": 0, "max": 20 },
  "attribution": "stub",
  "uses": ["display"]
}
EOJ

my $ua = LWP::UserAgent->new( timeout => 2 );

# A LEFTOVER STUB FROM A RUN THAT DIED BEFORE IT COULD SAY /quit answers
# exactly like a fresh one, and a new stub started beside it fails to bind
# and dies silently.  So anything already on this port is retired first.

$ua->get("$STUB/quit");
select(undef,undef,undef,0.3);

my $stub_pid = system(1,"\"$^X\" \"$FindBin::Bin/tool_stub_source.pl\" $STUB_PORT");
my $up = 0;
for (1..50)
{
	if ($ua->get("$STUB/stats")->is_success()) { $up = 1; last }
	select(undef,undef,undef,0.1);
}
ok($up,"stub server answered on port $STUB_PORT");

if ($up)
{
	rescanSources();
	my $st = getSource('stub_arcgis') or die "no stub source\n";
	my $ps = metaSource($st);

	ok($ps->{family} eq 'arcgis',
		"the metadata url was DERIVED from the tile url, not configured");
	ok($ps->{ok},"the stub MapServer answered".($ps->{ok} ? '' : " - $ps->{reason}"));

	# THE OTHER HALF OF THE maxScale RULE.  The stub's cache goes to level
	# 20 and its maxScale names level 17, so a probe that applies the rule
	# must report 17 - the service's own statement - rather than 20.

	ok($ps->{ok} && $ps->{zmax} == 17,
		"a REAL maxScale is read as the ceiling: z".($ps->{zmax} // '?').
		", not the z20 the cache reaches");

	my ($ms) = grep { $_->[0] eq 'maxScale' } @{$ps->{facts}};
	ok($ms && $ms->[1] =~ /a real limit/,
		"and it is reported as a real limit: '".($ms ? $ms->[1] : '-')."'");

	ok(scalar(grep { /zoom\.max z20, below/ } @{$ps->{disagree}}) == 0,
		"the file's zoom.max 20 is ABOVE the declared 17, so it is ".
		"reported as the dangerous direction");
	ok(scalar(grep { /will be refused/ } @{$ps->{disagree}}),
		"and says fetches above it will be refused");

	# THE COMPRESSED TILEMAP.  z1 on the stub answers 'valid' with no data
	# array, meaning every tile in the block is present.

	my $c = metaTilemap($st,1,10,20,8,8);
	ok($c->{ok},"a compressed tilemap block decoded");
	ok($c->{ok} && $c->{count_total} == 64,
		"as 64 tiles (got ".($c->{count_total} // 0).")");
	ok($c->{ok} && $c->{count_present} == 64,
		"ALL PRESENT - not the empty block a naive decode would report ".
		"(got ".($c->{count_present} // 0).")");

	my $z = metaTilemap($st,2,10,20,8,8);
	ok($z->{ok} && $z->{count_present} == 0,
		"an explicit array of zeros is 0 of $z->{count_total} present");

	my $m = metaTilemap($st,3,10,20,8,8);
	ok($m->{ok} && $m->{count_present} == 32,
		"and a mixed block is counted correctly ".
		"($m->{count_present} of $m->{count_total})");

	$ua->get("$STUB/quit");
}


#---------------------------------------------
# what a service publishes
#---------------------------------------------
# AGAINST THE LIVE SERVICE, for the reason the rest of this file is: a
# fixture would keep passing after GIBS changed its document, and a reader
# of somebody else's XML failing quietly when they revise it is exactly
# the failure this exists to catch.
#
# THE ASSERTIONS ARE SHAPE, NOT CONTENT.  How many layers GIBS publishes
# is not this application's business and will be a different number next
# month; that the answer is large, that the urls are addressable, and that
# the ceilings come back as numbers, are properties of the READER.

print "\n=== serviceLayers - live GIBS ===\n";

{
	my $r = serviceLayers('wmts',
		'https://gibs.earthdata.nasa.gov/wmts/epsg3857/best/1.0.0/'.
		'WMTSCapabilities.xml');

	ok($r->{ok},"GIBS answered: ".($r->{reason} // 'ok'));

	if ($r->{ok})
	{
		my $kept = scalar(@{$r->{layers}});
		ok($r->{total} > 100,
			"the document describes many layers (got $r->{total})");
		ok($kept > 50,"and $kept of them are readable by this application");
		ok($kept < $r->{total},
			"while some are not - ".($r->{total} - $kept)." hidden, ".
			"with a reason for each");

		# EVERY URL IS THE SERVICE'S OWN.  This is the whole point of
		# reading the document rather than typing an entry: no part of the
		# address below was guessed.

		my $bad_url = 0;
		my $bad_zoom = 0;
		my $bad_fmt = 0;
		my $left_over = 0;
		for my $l (@{$r->{layers}})
		{
			$bad_url++  if $l->{url} !~ /\{z\}/ || $l->{url} !~ /\{x\}/ ||
						   $l->{url} !~ /\{y\}/;
			$left_over++ if $l->{url} =~ /\{(?!z\}|x\}|y\})/;
			$bad_zoom++ if $l->{zmax} !~ /^\d+$/ || $l->{zmax} < 1 ||
						   $l->{zmax} > 24;
			$bad_fmt++  if ($l->{tile_format} // '') !~ /^(jpeg|png)$/;
		}
		ok(!$bad_url,"every url addresses a tile with {z} {x} {y}");
		ok(!$left_over,
			"and none carries a placeholder this reader did not resolve");
		ok(!$bad_zoom,"every ceiling is a whole number in 1..24");
		ok(!$bad_fmt,"every format is jpeg or png");

		# DEEPEST FIRST.  Guidance and not a verdict: the shallow layers
		# are all still there, at the bottom.

		my $desc = 1;
		for my $i (1 .. $#{$r->{layers}})
		{
			$desc = 0 if $r->{layers}[$i]{zmax} > $r->{layers}[$i-1]{zmax};
		}
		ok($desc,"the list is ordered deepest first");

		# WHERE DEPTH TIES THE SERVICE'S ORDER STANDS, and the case that
		# proves it is a service whose layers ALL tie.  Esri Wayback
		# publishes 195 releases at one depth, newest first; any sort with
		# a name tiebreak silently reverses that.

		my $wb = serviceLayers('wmts',
			'https://wayback.maptiles.arcgis.com/arcgis/rest/services/'.
			'World_Imagery/WMTS/1.0.0/WMTSCapabilities.xml');
		ok($wb->{ok},"Esri Wayback answered: ".($wb->{reason} // 'ok'));
		if ($wb->{ok})
		{
			my $n = scalar(@{$wb->{layers}});
			ok($n > 100,"it publishes $n archived releases");
			ok($n == $wb->{total},
				"and every one of them is readable - none hidden");

			# ITS MATRIX SET IS NAMED WITHOUT A LEVEL, and its definition
			# opens with a Title rather than an Identifier, which is the
			# shape that used to void all 195 at once.

			ok($wb->{layers}[0]{tms} eq 'GoogleMapsCompatible',
				"on a matrix set naming no level: $wb->{layers}[0]{tms}");
			ok($wb->{layers}[0]{zmax} > 0,
				"whose range was still counted: z$wb->{layers}[0]{zmin}".
				"-$wb->{layers}[0]{zmax}");

			my $first = $wb->{layers}[0]{name};
			my $last  = $wb->{layers}[-1]{name};
			my ($fy) = $first =~ /(\d{4})-\d{2}-\d{2}/;
			my ($ly) = $last  =~ /(\d{4})-\d{2}-\d{2}/;
			ok($fy && $ly && $fy > $ly,
				"newest first, as the service published them ".
				"($fy then ... then $ly)");

			# EACH RELEASE CARRIES ITS OWN RELEASE NUMBER, which is the
			# identifier no catalog entry could have invented.
			my %rel;
			for my $l (@{$wb->{layers}})
			{
				$rel{$1}++ if $l->{url} =~ m{/MapServer/tile/(\d+)/};
			}
			ok(scalar(keys %rel) == $n,
				"each release addresses its own pinned id (".
				scalar(keys %rel)." distinct)");
		}

		# AND WHAT COMES BACK MUST BE WRITABLE AS A SOURCE.  A reader that
		# produced layers no TSD could hold would be a reader that produced
		# nothing.

		my $deepest = $r->{layers}[0];
		my $tsd = {
			tsd_version => 1, tile_size => 256, crs => 'EPSG:3857',
			id => 'live_probe_check', name => $deepest->{name},
			url => $deepest->{url}, tile_format => $deepest->{tile_format},
			zoom => { min => $deepest->{zmin}, max => $deepest->{zmax} },
			uses => ['display'], attribution => 'NASA GIBS',
		};
		my $why = checkSource('live.tsd',$tsd);
		ok(!$why,"the deepest layer is a source dm_source would load".
			($why ? " : $why" : " ($deepest->{id}, z$deepest->{zmax})"));
	}
}


print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
