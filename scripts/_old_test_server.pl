#!/usr/bin/perl
#---------------------------------------------
# t_server.pl -- headless test of the applet protocol
#---------------------------------------------
# Starts em_server in this process on a private port, then calls its own
# endpoints.  Everything dies with the process; nothing outlives it.

use strict;
use warnings;
use Time::HiRes qw( sleep );
use LWP::UserAgent;
use JSON::PP;
use URI::Escape;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use Pub::Prefs;
use cm_defs;
use cm_prefs;
use dm_source;
use dm_region;
use em_server;

my $TMP  = 'C:/_temp/dat-openCPN-chartMaker';
my $PORT = 9899;

$Pub::Utils::data_dir = "$TMP/tsd_good";
$Pub::Utils::temp_dir = "$TMP/fetch";

my $fails = 0;
sub ok
	# NOTE THE ARITY CHECK.  ok($x =~ /re/, 'what') puts the match in
	# LIST context, and a failed match there returns an empty list rather
	# than false -- so the description slides into the condition slot and
	# a failing test reports PASS with no description.  Requiring exactly
	# two arguments turns that silent lie into a loud death.
{
	die "ok() needs exactly 2 args, got ".scalar(@_).
		" - wrap any regex match in scalar()\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

Pub::Prefs::initPrefs("$TMP/test.prefs",{});
setPref($PREF_HTTP_PORT,$PORT);

# Rebuild the region fixtures from the KML every run.  This test MUTATES
# regions -- that is the point of it -- so leaving the results behind
# means the next run asserts against whatever the last one happened to
# leave, which is no assertion at all.  It cost a confusing failure once
# already.

unlink glob("$TMP/tsd_good/*.region");
unlink "$TMP/tsd_good/workspace.json";
rescanRegions();
importKmlFile('C:/dat/openCPN/chartMaker_old/masks/coverage.kml',15);
rescanRegions();
addSubregion('BocasDelToro','Popa00',9.334083,-82.242050,0.5,18);
setChecked($_,1) for getRegionIds();

loadSources();
em_server::startServer();

my $ua = LWP::UserAgent->new( timeout => 10 );
my $base = "http://localhost:$PORT";

# wait for the listener rather than guessing at a delay
my $up = 0;
for my $try (1..50)
{
	my $r = $ua->get("$base/state");
	if ($r->is_success) { $up = 1; last }
	sleep(0.2);
}
ok($up,"server answered on port $PORT");
exit(1) if !$up;


print "\n=== /state ===\n";
my $state = decode_json($ua->get("$base/state")->content());
ok(ref($state->{sources}) eq 'ARRAY' && @{$state->{sources}} == 3,
	"3 sources reported");
ok($state->{active_source} eq 'gibs_weld_annual',
	"active_source is the build-capable one (got '$state->{active_source}')");

my ($gibs) = grep { $_->{id} eq 'gibs_weld_annual' } @{$state->{sources}};
ok($gibs->{zoom_max} == 12,"zoom_max reported as 12");
ok(scalar($gibs->{attribution} =~ /NASA/),"attribution reported");
ok(!exists($gibs->{url}),"THE URL IS NOT IN /state");
my $raw = $ua->get("$base/state")->content();
ok($raw !~ /earthdata|https?:/i,"no endpoint string anywhere in the payload");

# JSON TYPES.  Perl does not distinguish 8 from "8", JSON does, and
# JavaScript's + operator makes the difference catastrophic: a zoom sent
# as "8" turns Leaflet's z+2 into "82" and hangs the browser recursing
# down a quadtree.  Regexes in the validator are what stringify these,
# so this asserts on the RAW text rather than the decoded structure --
# decoding would hide exactly what is being tested.

ok(scalar($raw =~ /"zoom_max":\s*\d/),  'zoom_max is a JSON number, not a string');
ok(scalar($raw =~ /"zoom_min":\s*\d/),  'zoom_min is a JSON number, not a string');
ok(scalar($raw =~ /"tile_size":\s*\d/), 'tile_size is a JSON number, not a string');
ok(scalar($raw =~ /"version":\s*\d/),   'version is a JSON number, not a string');
ok(scalar($raw !~ /"(zoom_max|zoom_min|tile_size|version)":\s*"/),
	'no numeric field is quoted anywhere in the payload');


print "\n=== regions in /state ===\n";
ok(ref($state->{regions}) eq 'ARRAY',"/state carries a regions array");
ok(scalar(@{$state->{regions}}) == 5,
	"5 checked regions sent (got ".scalar(@{$state->{regions}}).")");

my ($sb) = grep { $_->{id} eq 'BocasDelToro' } @{$state->{regions}};
ok(defined($sb),"BocasDelToro is among them");
ok($sb && scalar(@{$sb->{polygons}}) == 2,"it carries both of its polygons");
ok($sb && scalar(@{$sb->{subregions}}) == 1,"and its Popa00 subregion");
ok($sb && $sb->{subregions}[0]{zmax} == 18,"the subregion reaches z18");
ok($sb && $sb->{zauthor} == 15 && $sb->{zmin} == 10 && $sb->{zmax} == 16,
	"the region carries zauthor, zmin and zmax");
ok($sb && !exists($sb->{subregions}[0]{zauthor}),
	"and the subregion is sent WITHOUT a zauthor it does not have");

# Coordinates must be NUMBERS.  A [lon,lat] pair arriving as strings would
# be concatenated the first time Leaflet did arithmetic on it.
ok($raw !~ /\[\s*"-?\d/ ? 1 : 0,"no coordinate is a quoted string");
ok($raw =~ /"zauthor":\s*\d/ ? 1 : 0,"zauthor is a number");

my $pt = $sb->{polygons}[0][0];
ok(ref($pt) eq 'ARRAY' && @$pt == 2,"a point is a [lon,lat] pair");
ok($pt->[0] < -80 && $pt->[1] > 8 && $pt->[1] < 10,
	"and it is in Panama, lon first (got $pt->[0], $pt->[1])");


print "\n=== /coverage ===\n";
my $c10 = decode_json($ua->get(
	"$base/coverage?z=10&w=-82.5&s=9.0&e=-81.5&n=9.6")->content());
ok($c10->{zoom} == 10,"the zoom comes back as a number");
ok(ref($c10->{tiles}) eq 'ARRAY' && scalar(@{$c10->{tiles}}) > 0 ? 1 : 0,
	"z10 over Bocas returns ".scalar(@{$c10->{tiles}})." tiles of $c10->{total}");
ok($c10->{total} >= scalar(@{$c10->{tiles}}),
	"the view is a subset of the whole set");

my $c17 = decode_json($ua->get(
	"$base/coverage?z=17&w=-82.30&s=9.30&e=-82.18&n=9.38")->content());
ok($c17->{total} == 49,
	"z17 has exactly 49 tiles - Popa00 and nothing else (got $c17->{total})");

my $empty = decode_json($ua->get(
	"$base/coverage?z=15&w=-40&s=-40&e=-39&n=-39")->content());
ok(scalar(@{$empty->{tiles}}) == 0,"a view in the South Atlantic returns none");

my $raw10 = $ua->get("$base/coverage?z=10&w=-82.5&s=9.0&e=-81.5&n=9.6")->content();
ok($raw10 !~ /\[\s*"/ ? 1 : 0,"tile coordinates are numbers, not strings");


print "\n=== /tile ===\n";
my $t = $ua->get("$base/tile/gibs_weld_annual/10/278/485");
ok($t->code() == 200,"a cached tile returns 200 (got ".$t->code().")");
ok($t->header('content-type') eq 'image/jpeg',
	"content-type is image/jpeg (got ".($t->header('content-type')//'-').")");
ok(length($t->content()) == 13005,
	"13005 bytes, byte for byte what the source sent (got ".length($t->content()).")");

my $absent = $ua->get("$base/tile/gibs_weld_annual/10/1023/1");
ok($absent->code() == 404,"a known absence returns 404 (got ".$absent->code().")");

my $range = $ua->get("$base/tile/gibs_weld_annual/13/1/1");
ok($range->code() == 404,"outside the declared zoom range returns 404 (got ".$range->code().")");

my $nosuch = $ua->get("$base/tile/not_a_source/10/1/1");
ok($nosuch->code() == 404,"an unknown source returns 404 (got ".$nosuch->code().")");


print "\n=== /api still works ===\n";
my $cmd = decode_json($ua->get("$base/api/command?cmd=sources")->content());
ok($cmd->{ok},"/api/command dispatched 'sources'");
my $log = decode_json($ua->get("$base/api/log?tail=20")->content());
ok(ref($log->{lines}) eq 'ARRAY',"/api/log returns an array of entries");
ok(scalar(grep { ($_->{text}//'') =~ /gibs_weld_annual/ } @{$log->{lines}}) > 0,
	"/api/log shows the command's output");

print "\n=== a mutation must reach EVERY server thread ===\n";
# The server runs 4 threads and each holds its own copy of the model.  A
# write updates one thread's copy and the file; without a bump of the
# shared generation counter the others serve stale data forever.  Hitting
# /state repeatedly is what exposes it - one request could land on the
# thread that did the write and look fine.

$ua->get("$base/api/command?cmd=".uri_escape("region zmax BocasDelToro 19 Popa00"));
my ($fresh,$stale) = (0,0);
for (1..12)
{
	my $s = decode_json($ua->get("$base/state")->content());
	my ($b) = grep { $_->{id} eq 'BocasDelToro' } @{$s->{regions}};
	my $z = $b && $b->{subregions}[0] ? $b->{subregions}[0]{zmax} : 0;
	$z == 19 ? $fresh++ : $stale++;
}
ok($stale == 0,"12 of 12 /state requests saw the change ($fresh fresh, $stale stale)");

$ua->get("$base/api/command?cmd=".uri_escape("region rename BocasDelToro Renamed Bay"));
my $seen_new = 0;
for (1..12)
{
	my $s = decode_json($ua->get("$base/state")->content());
	my ($b) = grep { $_->{id} eq 'BocasDelToro' } @{$s->{regions}};
	$seen_new++ if $b && $b->{name} eq 'Renamed Bay';
}
ok($seen_new == 12,"a rename reached every thread too ($seen_new of 12)");

# put it back
$ua->get("$base/api/command?cmd=".uri_escape("region zmax BocasDelToro 18 Popa00"));
$ua->get("$base/api/command?cmd=".uri_escape("region rename BocasDelToro Bocas del Toro"));


print "\n=== /poll and the version counter ===\n";
my $poll = decode_json($ua->get("$base/poll")->content());
ok(defined($poll->{version}) && $poll->{version} >= 1,
	"/poll returns a version (got ".($poll->{version}//'undef').")");

my $st = decode_json($ua->get("$base/state")->content());
ok($st->{version} == $poll->{version},
	"/state carries the same version as /poll");

my $before = $poll->{version};
$ua->get("$base/api/command?cmd=".uri_escape("source use quad_test"));
my $after = decode_json($ua->get("$base/poll")->content());
ok($after->{version} > $before,
	"changing the active source bumped the version ($before -> $after->{version})");

$st = decode_json($ua->get("$base/state")->content());
ok($st->{active_source} eq 'quad_test',
	"/state now names quad_test (got '$st->{active_source}')");

my $same = decode_json($ua->get("$base/poll")->content());
ok($same->{version} == $after->{version},
	"polling again does not bump anything");

$ua->get("$base/api/command?cmd=".uri_escape("source use quad_test"));
my $noop = decode_json($ua->get("$base/poll")->content());
ok($noop->{version} == $after->{version},
	"re-selecting the same source is not a change");

$ua->get("$base/api/command?cmd=".uri_escape("source rescan"));
my $rescanned = decode_json($ua->get("$base/poll")->content());
ok($rescanned->{version} > $after->{version},
	"a rescan bumped the version ($after->{version} -> $rescanned->{version})");

$ua->get("$base/api/command?cmd=".uri_escape("source use no_such_source"));
my $bad = decode_json($ua->get("$base/poll")->content());
ok($bad->{version} == $rescanned->{version},
	"selecting a source that does not exist changes nothing");
$st = decode_json($ua->get("$base/state")->content());
ok($st->{active_source} eq 'quad_test',"and leaves the active source alone");


print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
exit(0);
