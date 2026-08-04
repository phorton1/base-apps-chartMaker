#!/usr/bin/perl
#---------------------------------------------
# test_keys.pl -- headless test of dm_keys, the key store
#---------------------------------------------
# HERMETIC AND OFFLINE.  Not one assertion here goes to the network: every
# question this phase raises is answerable from a url template and a map of
# names to values, and a test that needed a live keyed service could only
# ever run on the machine that had the key.
#
# What it is pinning down:
#
#	a key_value never appears in a .tsd, and one that does is refused
#	a declared key_name is a legal placeholder; an undeclared {token} is not
#	an unresolved url NEVER BECOMES A REQUEST, and is never cached
#	an unresolved key is an ERROR and an out-of-range zoom is an ABSENCE
#	redaction takes a value back out of anything, wherever it ended up
#	the strip-back turns a service's baked-in key back into its {key_name}
#	the store survives a round trip through the file
#	a key_name is a property of the SOURCE, asked once, not once per tile

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_keys;
use dm_source;
use dm_cache;
use dm_observe;
use dm_fetch;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/keys_data";

$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/keys_temp";

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
# the fixture
#---------------------------------------------

rmTree($ROOT);
mkdir($ROOT)            or die "cannot make $ROOT\n";
mkdir("$ROOT/sources")  or die "cannot make sources\n";
mkdir($Pub::Utils::temp_dir) if !-d $Pub::Utils::temp_dir;

# NO init_prefs, DELIBERATELY.  prefDir resolves a folder's default on
# every read rather than writing it into the prefs hash at startup, so a
# module behaves in a headless test exactly as it does in the application.
# If that ever stops being true, this test is where it shows.

sub tsd
{
	my ($leaf,$url,$keys) = @_;
	my $k = $keys ? ",\n  \"keys\": $keys" : '';
	putFile("$ROOT/sources/$leaf.tsd",<<"EOJ");
{
  "tsd_version": 1,
  "id": "$leaf",
  "name": "$leaf",
  "url": "$url",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 18 },
  "attribution": "test",
  "uses": ["display","build"]$k
}
EOJ
}


#---------------------------------------------
# a key_value may never live in a .tsd
#---------------------------------------------

print "\n--- a .tsd declares names and never values ---\n";

tsd('keyed','https://example.com/{z}/{x}/{y}.jpg?api={test_key}',
	'[ { "key_name": "test_key", "label": "Test key", '.
	'"obtain_url": "https://example.com/get" } ]');

tsd('valued','https://example.com/{z}/{x}/{y}.jpg?api={test_key}',
	'[ { "key_name": "test_key", "key_value": "SECRET" } ]');

tsd('undeclared','https://example.com/{z}/{x}/{y}.jpg?api={no_such_key}');

tsd('plain','https://example.com/{z}/{x}/{y}.jpg');

rescanSources();

ok(getSource('keyed'),'a source declaring a key_name loads');
ok(!getSource('valued'),
	'a .tsd carrying a key_value is REFUSED - the value belongs in the store');
ok((getRefused()->{'valued.tsd'} || '') =~ /key_value belongs in the key store/,
	'and the refusal says where a value belongs');
ok(!getSource('undeclared'),
	'a {token} that is neither a placeholder nor a declared key_name is refused');
ok((getRefused()->{'undeclared.tsd'} || '') =~ /no_such_key/,
	'and the refusal names the token, which is what makes a typo findable');
ok(getSource('plain'),'a source with no keys at all is unaffected');


#---------------------------------------------
# unresolved is a property of the source
#---------------------------------------------

print "\n--- unresolved is asked of the source, not of a tile ---\n";

unlink(keysFile());
loadKeys(1);

my $keyed = getSource('keyed');
my $plain = getSource('plain');

ok(sourceUnresolved($keyed) eq 'test_key',
	'an unbound key_name is reported by name');
ok(sourceUnresolved($plain) eq '',
	'a source needing no key is never unresolved');

my $why = 'not touched';
my $url = sourceTileUrl($keyed,10,1,2,\$why);
ok(!defined($url),'no url is produced while the key is unbound');
ok($why =~ /unresolved token \{test_key\}/,
	'and the reason names the token: '.$why);

ok(!defined(sourceTileUrl($plain,19,1,2)),
	'a zoom outside the declared range still produces no url');


#---------------------------------------------
# and the two are not the same kind of answer
#---------------------------------------------

print "\n--- an unresolved key is an ERROR, an out-of-range zoom is an ABSENCE ---\n";

my $r1 = fetchTile($keyed,10,1,2);
ok($r1->{status} eq 'error',
	'an unresolved key is an error and not an absence');
ok(($r1->{class} || '') eq 'unresolved',
	"and carries the class that says it never reached the network");
ok(($r1->{local} || 0),'and is marked local, because no server was asked');
ok(!defined($r1->{http}),'there is no http code, because there was no request');

my $r2 = fetchTile($plain,19,1,2);
ok($r2->{status} eq 'absent',
	'where an out-of-range zoom IS an absence - a fact about the service');

# THE CACHE IS THE POINT.  An absence is written and an unresolved key is
# not, because caching the second would put a permanent miss over every
# tile somebody looked at before pasting their key.

ok(!defined($r1->{ms}),
	'an unresolved result carries no timing, so nothing downstream reads it as a fetch');


#---------------------------------------------
# binding a value
#---------------------------------------------

print "\n--- binding, resolving and round-tripping ---\n";

ok(setKeyValue('test_key','abc123def456') eq '','a value binds');
ok(-f keysFile(),'and the store file is written: '.keysFile());
ok(keysFile() =~ /\Q$appName\E\.keys\.json$/,
	'named for the application, because a relocated store shares its folder');

ok(sourceUnresolved($keyed) eq '','the source stops being unresolved');

$why = 'not touched';
$url = sourceTileUrl($keyed,10,1,2,\$why);
ok(defined($url),'and a url is produced');
ok(($url || '') =~ /api=abc123def456/,'with the value substituted');
ok(($url || '') !~ /[{}]/,'and no brace left anywhere in it');
ok($why eq '','with no reason set');

loadKeys(1);
ok((getKeyValue('test_key') // '') eq 'abc123def456',
	'the value survives a round trip through the file');

ok(setKeyValue('BadName','x') ne '','a key_name outside [a-z0-9_] is refused');


#---------------------------------------------
# redaction
#---------------------------------------------

print "\n--- redaction takes a value back out, wherever it ended up ---\n";

ok(keyRedact('GET https://example.com/8/1/2.jpg?api=abc123def456 -> 200')
		eq 'GET https://example.com/8/1/2.jpg?api={test_key} -> 200',
	'a value in a log line becomes its own name');
ok(keyRedact('path/abc123def456/tiles') eq 'path/{test_key}/tiles',
	'including in a PATH, which is where one service puts it');
ok(keyRedact('nothing to see') eq 'nothing to see',
	'and text with no value in it is untouched');

setKeyValue('tiny','ab');
ok(keyRedact('a cab and a taxi') eq 'a cab and a taxi',
	'a very short value is NOT redacted - it would turn every message to confetti');
deleteKeyValue('tiny');


#---------------------------------------------
# the strip-back
#---------------------------------------------

print "\n--- the strip-back, which is what makes Expand safe ---\n";

# A KEYED SERVICE HANDS BACK ITS OWN KEY.  LINZ's capabilities publishes
# ResourceURL templates with the live key baked in, so what comes off the
# wire has to have every known value turned back into its {key_name} before
# anything is written.

my $from_service =
	'https://basemaps.linz.govt.nz/v1/tiles/aerial/WebMercatorQuad/'.
	'{TileMatrix}/{TileCol}/{TileRow}.jpeg?api=abc123def456';
my $stripped = keyRedact($from_service);

ok($stripped =~ /api=\{test_key\}/,
	'a live key in a service-supplied template becomes a placeholder');
ok($stripped !~ /abc123def456/,
	'and the value is gone, which is the whole guarantee');


#---------------------------------------------
# clearing
#---------------------------------------------

print "\n--- clearing, and what an empty binding means ---\n";

ok(setKeyValue('test_key','') eq '','a value may be cleared to empty');
ok(sourceUnresolved($keyed) eq 'test_key',
	'an EMPTY binding is unresolved - a blank key is not a key');

ok(deleteKeyValue('test_key') eq '','a binding may be deleted');
ok(!defined(getKeyValue('test_key')),
	'and is then undef, which is different from empty: nobody has answered');

my @left = getKeyNames();
ok(@left == 0,'the store is empty again');


#---------------------------------------------

print "\n";
print $fails ? "$fails FAILURES\n" : "ALL PASSED\n";
exit($fails ? 1 : 0);
