#!/usr/bin/perl
#---------------------------------------------
# t_fetch.pl -- headless test of dm_fetch + dm_cache
#---------------------------------------------
# Hits the real NASA GIBS endpoint.  This is the test that decides
# whether the shipped TSD's url template is actually right.

use strict;
use warnings;
use POSIX qw( floor );
use LWP::UserAgent;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_cache;
use dm_observe;
use dm_fetch;

my $TMP = 'C:/_temp/base-apps-chartMaker';

$Pub::Utils::data_dir = "$TMP/tsd_good";
$Pub::Utils::temp_dir = "$TMP/fetch";

my $fails = 0;

sub ok
{
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

sub tileOf
	# lat/lon to tile x,y at zoom z -- web mercator, the fixed grid
{
	my ($lat,$lon,$z) = @_;
	my $n   = 2 ** $z;
	my $rad = $lat * 3.14159265358979 / 180;
	my $x   = floor(($lon + 180) / 360 * $n);
	my $y   = floor((1 - log(sin($rad)/cos($rad) + 1/cos($rad)) / 3.14159265358979) / 2 * $n);
	return ($x,$y);
}


rescanSources();
my $gibs = getSource('gibs_weld_annual');
die "no gibs source\n" if !$gibs;

# Bocas del Toro
my ($x,$y) = tileOf(9.33,-82.24,10);

# Start cold.  These assertions distinguish a network fetch from a cache
# hit, so leaving the previous run's entries in place makes the test pass
# or fail depending on whether it has been run before.

unlink(cacheDir()."/weld_annual/10/${x}_${y}.jpeg");
unlink(cacheDir()."/weld_annual/10/1023_1.none");

print "=== GIBS live fetch: Bocas del Toro at z10 = $x/$y ===\n";

my $r = getTile($gibs,10,$x,$y);
ok($r->{status} eq 'ok',
	"status is ok (got '$r->{status}'".
	(defined($r->{http}) ? ", http $r->{http}" : '').
	(defined($r->{reason}) ? ", $r->{reason}" : '').")");

if ($r->{status} eq 'ok')
{
	ok($r->{format} eq 'jpeg',"detected format is jpeg (got $r->{format})");
	ok(length(${$r->{bytes}}) > 1000,
		"tile is ".length(${$r->{bytes}})." bytes");
	ok(!$r->{cached},"first call was a network fetch");
	ok(defined($r->{ms}),"took $r->{ms} ms");

	my $path = cacheDir()."/weld_annual/10/${x}_${y}.jpeg";
	ok(-f $path,"written to the cache at cache/weld_annual/10/${x}_${y}.jpeg");

	my $again = getTile($gibs,10,$x,$y);
	ok($again->{status} eq 'ok' && $again->{cached},"second call is a cache hit");
	ok(length(${$again->{bytes}}) == length(${$r->{bytes}}),
		"cached bytes are the same length");
}


print "\n=== outside the declared protocol range ===\n";
my $deep = getTile($gibs,13,$x,$y);
ok($deep->{status} eq 'absent',"z13 is absent (declared zoom.max is 12)");
ok(!defined($deep->{http}),"no http request was made");
ok(!-f cacheDir()."/weld_annual/13/${x}_${y}.none",
	"a range-derived absence is NOT written to the cache");


print "\n=== a real absence, if the source gives one ===\n";
my $off = getTile($gibs,10,1023,1);
print "  z10/1023/1 -> $off->{status}".
	(defined($off->{http}) ? " (http $off->{http})" : '').
	(defined($off->{reason}) ? " - $off->{reason}" : '')."\n";
if ($off->{status} eq 'absent' && defined($off->{http}))
{
	ok(-f cacheDir()."/weld_annual/10/1023_1.none",
		"a source-asserted absence IS written to the cache");
	my $again = getTile($gibs,10,1023,1);
	ok($again->{cached},"the absence is served from the cache next time");
}


print "\n=== cache stats ===\n";
my $stats = cacheStats($gibs);
print "  tiles=$stats->{total_tiles} misses=$stats->{total_misses} bytes=$stats->{total_bytes}\n";
print "  z$_: tiles=$stats->{zooms}{$_}{tiles} misses=$stats->{zooms}{$_}{misses}\n"
	for sort { $a <=> $b } keys %{$stats->{zooms}};
ok($stats->{total_tiles} >= 1,"cacheStats sees at least one tile");


#---------------------------------------------
# absent_headers, against the stub
#---------------------------------------------
# NO REAL SERVICE CAN BE ASKED FOR THIS.  The one documented source of an
# 'absence in a header' is Virtual Earth, which needs a key, and even with
# one there is no coordinate that reliably produces it.  So the rule is
# tested against tool_stub_source.pl, which does it on demand.
#
# THE CONTROLS ARE THE POINT.  Three sources fetch THE SAME BYTES from the
# SAME url; they differ only in what their TSD declares.  That is what
# makes this a test of the declaration rather than of the stub: if the
# undeclared one also came back absent, something other than the rule
# would be deciding.

print "\n=== absent_headers (stub server) ===\n";

my $STUB_PORT = 9899;
my $stub_url  = "http://127.0.0.1:$STUB_PORT";

sub stubTsd
{
	my ($id,$path,$extra) = @_;
	$extra = defined($extra) ? ",\n  $extra" : '';
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "stub $id",
  "url": "$stub_url/$path/{z}/{x}/{y}.jpg",
  "zoom": { "min": 0, "max": 20 },
  "attribution": "stub",
  "uses": ["display","build"]$extra
}
EOJ
}

my $stub_dir = "$TMP/tsd_stub";
mkdir $stub_dir if !-d $stub_dir;
mkdir "$stub_dir/sources" if !-d "$stub_dir/sources";

my %stub_files = (
	'ok.tsd'        => stubTsd('stub_ok','ok'),
	'notile.tsd'    => stubTsd('stub_notile','notile',
		'"absent_headers": [ { "name": "X-VE-Tile-Info", "value": "no-tile" } ]'),
	'undecl.tsd'    => stubTsd('stub_undecl','notile'),
	'wrongval.tsd'  => stubTsd('stub_wrongval','notile',
		'"absent_headers": [ { "name": "X-VE-Tile-Info", "value": "no-tile-here" } ]'),
	'wrongname.tsd' => stubTsd('stub_wrongname','notile',
		'"absent_headers": [ { "name": "X-Other-Thing", "value": "no-tile" } ]'),
	'upcase.tsd'    => stubTsd('stub_upcase','notile',
		'"absent_headers": [ { "name": "x-VE-tILE-iNFO", "value": "no-tile" } ]'),
	'garbage.tsd'   => stubTsd('stub_garbage','garbage'),
);

for my $leaf (sort keys %stub_files)
{
	open(my $fh,'>',"$stub_dir/sources/$leaf")
		or die "cannot write $stub_dir/sources/$leaf: $!";
	print $fh $stub_files{$leaf};
	close $fh;
}

# A FRESH CACHE, because half of what is asserted below is whether an
# absence reached disk, and a previous run's .none files would answer
# that before the fetch did.

my $stub_cache = "$stub_dir/cache";
if (-d $stub_cache)
{
	for my $sub (glob("$stub_cache/*"))
	{
		unlink glob("$sub/*/*");
		rmdir $_ for glob("$sub/*");
		rmdir $sub;
	}
}

# The stub is started by the test and told to quit at the end, so this
# file needs no setup outside itself and leaves no process behind.

my $ua = LWP::UserAgent->new( timeout => 2 );

# A LEFTOVER STUB FROM A RUN THAT DIED BEFORE IT COULD SAY /quit answers
# exactly like a fresh one, and a new stub started beside it fails to bind
# and dies silently.  So anything already on this port is retired first.

$ua->get("$stub_url/quit");
select(undef,undef,undef,0.3);

my $stub_pid = system(1,"\"$^X\" \"$FindBin::Bin/tool_stub_source.pl\" $STUB_PORT");
my $up = 0;
for (1..50)
{
	my $probe = $ua->get("$stub_url/stats");
	if ($probe->is_success()) { $up = 1; last }
	select(undef,undef,undef,0.1);
}
ok($up,"stub server answered on port $STUB_PORT");

if ($up)
{
	$Pub::Utils::data_dir = $stub_dir;
	rescanSources();

	my $s_ok    = getSource('stub_ok');
	my $s_no    = getSource('stub_notile');
	my $s_un    = getSource('stub_undecl');
	my $s_wv    = getSource('stub_wrongval');
	my $s_wn    = getSource('stub_wrongname');
	my $s_up    = getSource('stub_upcase');
	my $s_junk  = getSource('stub_garbage');
	ok($s_ok && $s_no && $s_un && $s_wv && $s_wn && $s_up && $s_junk,
		"7 stub sources loaded");

	my $a = getTile($s_ok,5,1,1);
	ok($a->{status} eq 'ok',"a plain 200 jpeg is ok (got '$a->{status}')");

	# THE RULE ITSELF.

	my $b = getTile($s_no,5,1,1);
	ok($b->{status} eq 'absent',
		"a declared absent header makes a 200 an ABSENCE (got '$b->{status}')");
	ok($b->{status} eq 'absent' && ($b->{http} // 0) == 200,
		"and it is recorded as having come from an http 200");
	ok(-f "$stub_cache/notile/5/1_1.none",
		"the absence IS written to the cache");

	my $b2 = getTile($s_no,5,1,1);
	ok($b2->{status} eq 'absent' && $b2->{cached},
		"and is served from the cache next time, with no second request");

	# THE CONTROLS.  Same url, same bytes, same header on the wire.

	my $c = getTile($s_un,5,1,1);
	ok($c->{status} eq 'ok',
		"the SAME response with nothing declared is ordinary imagery ".
		"(got '$c->{status}')");

	my $d = getTile($s_wv,5,1,1);
	ok($d->{status} eq 'ok',
		"a declared value that does not match exactly does NOT absent it ".
		"(got '$d->{status}')");

	my $e = getTile($s_wn,5,1,1);
	ok($e->{status} eq 'ok',
		"a declared header the server did not send does NOT absent it ".
		"(got '$e->{status}')");

	# Header lookup is case insensitive and the validator folds the name,
	# so a file that shouts the header still matches.

	my $f = getTile($s_up,5,1,1);
	ok($f->{status} eq 'absent',
		"the header name matches whatever case the file used ".
		"(got '$f->{status}')");

	# A 200 that is not an image at all is still an ERROR, not an absence.
	# The two are easy to conflate and have opposite consequences: an
	# error is retried, an absence is cached forever.

	my $g = getTile($s_junk,5,1,1);
	ok($g->{status} eq 'error',
		"a 200 carrying an error page is an ERROR, not an absence ".
		"(got '$g->{status}')");
	ok(!-f "$stub_cache/garbage/5/1_1.none",
		"and an error is NOT cached");


	#---------------------------------------------
	# what a fetch LEARNS about a service
	#---------------------------------------------
	# A SERVICE ANSWERING 'NOTHING HERE' WITH A 200 AND A PICTURE is the
	# failure that looks like success, and the only tell is that the SAME
	# picture comes back at unrelated coordinates.  It is learned HERE,
	# in the one doorway every tile passes through, because anywhere else
	# it becomes a question of which surfaces remembered to ask - and a
	# user who never ran the optional one exports a card full of grey.
	#
	# THE STUB SERVES ONE BODY FOR EVERY TILE, which is exactly what a
	# service with a fill does.

	print "\n=== a fetch learns what a service serves instead of a tile ===\n";

	# A SOURCE NOTHING HAS FETCHED YET, because everything above has been
	# hammering stub_ok and its body is already known.  The first sighting
	# is the assertion, so it has to actually be the first.

	open(my $lfh,'>',"$stub_dir/sources/learn.tsd") or die $!;
	print $lfh stubTsd('stub_learn','ok');
	close $lfh;
	rescanSources();

	obsLoad();
	my $learn = getSource('stub_learn');

	fetchTile($learn,5,10,10);
	my @none = obsCandidates($learn);
	ok(!scalar(@none),
		"one sighting of a body is a tile, and nothing is recorded (got ".
		scalar(@none).")");

	fetchTile($learn,7,33,44);
	my @cand = obsCandidates($learn);
	ok(scalar(@cand) == 1,
		"the SAME body at a second, unrelated coordinate is a candidate ".
		"(got ".scalar(@cand).")");
	ok($cand[0]{count} == 2,"counted twice (got ".($cand[0]{count} // 0).")");
	ok($cand[0]{z} == 5 && $cand[0]{x} == 10 && $cand[0]{y} == 10,
		"and it carries the coordinate of the FIRST sighting, so the tile ".
		"can be found without keeping a copy of it");

	# THE COUNT IS EXACT WHERE IT IS READ.  Reporting on powers of two
	# keeps the record's lock out of a ten thousand tile run without
	# understating the small numbers a person actually looks at - a column
	# with three suspect levels in it must not say two.

	fetchTile($learn,9,99,99);
	ok((obsCandidates($learn))[0]{count} == 3,
		"three sightings read as three - a column with three suspect ".
		"levels must not say two (got ".
		((obsCandidates($learn))[0]{count} // 0).")");

	fetchTile($learn,11,7,7);
	ok((obsCandidates($learn))[0]{count} == 4,
		"and four as four (got ".
		((obsCandidates($learn))[0]{count} // 0).")");

	# ALREADY DECLARED IS NOT A CANDIDATE.  A fingerprint in the file is
	# the question already answered, and re-offering it on every fetch
	# would make the record argue with the source.

	my $declared = stubTsd('stub_known','ok');
	$declared =~ s/"attribution"/"absent_fingerprints": [ { "bytes": $cand[0]{bytes}, "md5": "$cand[0]{md5}" } ],\n  "attribution"/;
	open(my $dfh,'>',"$stub_dir/sources/known.tsd") or die $!;
	print $dfh $declared;
	close $dfh;
	rescanSources();

	my $s_known = getSource('stub_known');
	ok($s_known && @{$s_known->{absent_fingerprints} || []} == 1,
		"a source declaring that body loads");

	fetchTile($s_known,5,10,10);
	fetchTile($s_known,7,33,44);
	fetchTile($s_known,9,99,99);
	ok(!scalar(obsCandidates($s_known)),
		"and its OWN fetches record no candidate, because the file has ".
		"already answered that question");

	$ua->get("$stub_url/quit");
}

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
