#!/usr/bin/perl
#---------------------------------------------
# test_clean.pl -- headless test of dm_clean.pm
#---------------------------------------------
# HERMETIC, the way test_set.pl is: a whole data dir built from nothing
# under C:/_temp, with its own sources, region sets and CACHE.  Nothing
# here can reach a real tile - which matters more for this test than for
# any other in the suite, because everything it exercises deletes things.
#
# What it is actually pinning down:
#
#	usage is answered across EVERY set        - not just the open one
#	inheritance is followed                   - a subregion's tiles count
#	the map's own source counts as in use     - and the shipped ones
#	one cache_key, two .tsd files, one row    - and a tick that says so
#	a cache no .tsd names is found            - the orphan case
#	a declared blank is RECLASSIFIED          - not deleted, and idempotent
#	a trim keeps the .none markers            - and the in-coverage tiles
#	a trim with an empty keep set REFUSES     - rather than emptying a cache
#	the preflight is true                     - the survey's count is the act's

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Digest::MD5 qw( md5_hex );
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_clean;

my $TMP  = 'C:/_temp/base-apps-chartMaker';
my $ROOT = "$TMP/clean_data";

my $fails = 0;
sub ok
	# TWO ARGS, ALWAYS, and it dies rather than tolerating three.  An
	# array or a grep in the condition is evaluated in LIST context here
	# and flattens into the arguments, so the message becomes the third
	# one and the test silently asserts something else.  Wrap those in
	# scalar() - that is what the die is telling you.
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
	my $dir = $path;
	$dir =~ s{/[^/]+$}{};
	mkTree($dir);
	open(my $fh,'>',$path) or die "cannot write $path: $!";
	binmode $fh;
	print $fh $text;
	close $fh;
}

sub mkTree
{
	my ($dir) = @_;
	return if -d $dir;
	my $up = $dir;
	$up =~ s{/[^/]+$}{};
	mkTree($up) if $up ne $dir && $up =~ m{/};
	mkdir $dir;
}

sub has
	# Whether a list holds a value, as a plain 0 or 1.  See ok(): a grep
	# handed straight to it would flatten into its arguments.
{
	my ($list,$want) = @_;
	return 0 if !$list;
	return scalar(grep { $_ eq $want } @$list) ? 1 : 0;
}

sub slurp
{
	my ($path) = @_;
	open(my $fh,'<',$path) or return undef;
	binmode $fh;
	local $/;
	my $data = <$fh>;
	close $fh;
	return $data;
}


# THE BLANK, and it is a real one: the bytes a service would answer with,
# fingerprinted in the .tsd by their length and digest exactly as a person
# would after seeing one.  Everything about the sentinel sweep is measured
# against these bytes.

my $BLANK  = "NOT-A-TILE-".("x" x 200);
my $BLEN   = length($BLANK);
my $BMD5   = md5_hex($BLANK);
my $IMAGE  = "PRETEND-JPEG-".("y" x 500);
my $ILEN   = length($IMAGE);


sub tsdJson
{
	my ($id,$key,$extra) = @_;
	$extra = '' if !defined $extra;
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "name": "test source $id",
  "cache_key": "$key",
  "url": "https://example.com/$key/{z}/{x}/{y}.jpeg",
  "tile_format": "jpeg",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 16 },
  "attribution": "nobody",
  "license": "test",
  "redistributable": "no",
  "uses": ["display","build"]$extra
}
EOJ
}

sub regionJson
{
	my ($id,$name,$lat,$lon,$source,$subs) = @_;
	my $d = 0.04;
	$subs = '' if !defined $subs;
	return <<"EOJ";
{
   "region_version" : 1,
   "id" : "$id",
   "name" : "$name",
   "source" : "$source",
   "zauthor" : 12,
   "zmin" : 11,
   "zmax" : 13,
   "geometry" : [ [ [ @{[$lon-$d]}, @{[$lat-$d]} ],
                    [ @{[$lon+$d]}, @{[$lat-$d]} ],
                    [ @{[$lon+$d]}, @{[$lat+$d]} ],
                    [ @{[$lon-$d]}, @{[$lat+$d]} ] ] ],
   "subregions" : [ $subs ]
}
EOJ
}

sub subJson
{
	my ($id,$name,$lat,$lon,$source) = @_;
	my $d = 0.01;
	return <<"EOJ";
{
   "id" : "$id",
   "name" : "$name",
   "source" : "$source",
   "zmax" : 14,
   "geometry" : [ [ [ @{[$lon-$d]}, @{[$lat-$d]} ],
                    [ @{[$lon+$d]}, @{[$lat-$d]} ],
                    [ @{[$lon+$d]}, @{[$lat+$d]} ],
                    [ @{[$lon-$d]}, @{[$lat+$d]} ] ] ],
   "subregions" : []
}
EOJ
}


rmTree($ROOT);
mkTree($ROOT);
$Pub::Utils::data_dir = $ROOT;
$Pub::Utils::temp_dir = "$TMP/clean_temp";
mkTree("$TMP/clean_temp");

loadSets();

# ---- the sources

my $FP = ",\n  \"absent_fingerprints\": [ { \"bytes\": $BLEN, \"md5\": \"$BMD5\" } ]";

putFile("$ROOT/sources/main.tsd",   tsdJson('main_test','mainkey',$FP));
putFile("$ROOT/sources/other.tsd",  tsdJson('other_test','otherkey'));
putFile("$ROOT/sources/mapper.tsd", tsdJson('mapper_test','mapperkey'));

# TWO FILES, ONE cache_key.  dm_source permits it only when the urls are
# identical - which is exactly the case the delete dialog has to be able
# to talk about, so the fixture builds it properly rather than by accident.

putFile("$ROOT/sources/twin1.tsd",  tsdJson('twin_one','twinkey'));
putFile("$ROOT/sources/twin2.tsd",  tsdJson('twin_two','twinkey'));

rescanSources();
setDefaultSource('mapper_test');

# ---- two sets, and only one of them will ever be open

newSet('Panama');
newSet('Elsewhere');

putFile("$ROOT/region_sets/Panama/Bocas.region",
	regionJson('Bocas','Bocas del Toro',9.33,-82.24,'main_test',
		subJson('Popa','Popa Island',9.33,-82.24,'inherited')));
putFile("$ROOT/region_sets/Elsewhere/Far.region",
	regionJson('Far','Far Away',30.10,-90.10,'other_test'));

setActiveSet('Panama');
openSet('Panama');


#---------------------------------------------
# what is in use
#---------------------------------------------

print "=== usage ===\n";

my $usage = cleanSourceUsage();

ok(has($usage->{main_test},'Panama/Bocas'),
	"the open set's region names its source");

# THE ONE A NAIVE IMPLEMENTATION GETS WRONG.  The model only ever holds the
# regions of the OPEN set, so a source used only by another set looks
# unused unless the other set was read from its folder.

ok(has($usage->{other_test},'Elsewhere/Far'),
	"a region in a set that is NOT open counts too");

ok(has($usage->{main_test},'Panama/Bocas/Popa'),
	"a subregion that inherits counts against its parent's source");

ok(!$usage->{mapper_test},"nothing names the map's source");
ok(!$usage->{twin_one} && !$usage->{twin_two},"and nothing names the twins");


#---------------------------------------------
# a cache to clean
#---------------------------------------------

print "\n=== the fixture cache ===\n";

my $cov = regionCoverage(getRegion('Bocas'));
my @in12 = sort keys %{$cov->{12} || {}};
ok(scalar(@in12) >= 2,"the fixture region covers at least two z12 tiles ".
	"(got ".scalar(@in12).")");

my $CACHE = cacheDir();

# Two tiles a region wants, one it does not, one blank that predates the
# fingerprint, and an absence marker outside coverage.

for my $xy (@in12[0..1])
{
	my ($x,$y) = split(/_/,$xy);
	putFile("$CACHE/mainkey/12/${x}_${y}.jpeg",$IMAGE);
}
putFile("$CACHE/mainkey/12/0_0.jpeg",$IMAGE);
putFile("$CACHE/mainkey/12/1_1.jpeg",$BLANK);
putFile("$CACHE/mainkey/12/2_2.none",'');

putFile("$CACHE/twinkey/9/5_5.jpeg",$IMAGE);
putFile("$CACHE/orphankey/9/7_7.jpeg",$IMAGE);

my @keys = cacheKeysOnDisk();
ok(scalar(@keys) == 3,"three cache_keys on disk (got ".scalar(@keys).")");


#---------------------------------------------
# the survey
#---------------------------------------------

print "\n=== the survey ===\n";

my $rows = cleanSurvey({ trim => 1 });
my %by_key = map { $_->{key} => $_ } @$rows;

ok($by_key{mainkey},   "a row for mainkey");
ok($by_key{orphankey}, "a row for the orphan cache");
ok($by_key{orphankey} && $by_key{orphankey}{orphan},"and it is marked as one");
ok($by_key{mapperkey} && !$by_key{mapperkey}{tiles},
	"a source with no cache still gets a row");

my $twin = $by_key{twinkey};
ok($twin && scalar(@{$twin->{leaves}}) == 2,
	"two .tsd files sharing a cache_key make ONE row carrying both");

ok($by_key{mainkey}{tiles} == 4,
	"mainkey holds four tiles (got $by_key{mainkey}{tiles})");
ok($by_key{mainkey}{misses} == 1,
	"and one absence marker (got $by_key{mainkey}{misses})");

ok($by_key{mainkey}{sent_tiles} == 1,
	"one cached tile is the declared blank (got $by_key{mainkey}{sent_tiles})");
ok($by_key{mainkey}{sent_bytes} == $BLEN,
	"and its size is what would be freed");

# THE BLANK IS NOT ALSO COUNTED AS TRIMMABLE.  It is outside the coverage
# too, and counting it twice would make the preflight promise more than
# the act can deliver.

ok($by_key{mainkey}{trim_tiles} == 1,
	"one tile is outside every region (got $by_key{mainkey}{trim_tiles})");

ok($by_key{mainkey}{display} == 0,"mainkey is not the map's source");
ok($by_key{mapperkey}{display} == 1,"mapperkey is");
ok(scalar(@{$by_key{mainkey}{used_by}}) == 2,
	"mainkey is used, by the region and by its subregion");
ok($twin && !@{$twin->{used_by}},"the twins are used by nothing");

# A CACHE NO REGION USES CANNOT BE TRIMMED, and the survey says so rather
# than reporting every tile in it as removable.

ok($twin->{trim_all},"a cache no region uses is flagged, not counted");
ok($twin->{trim_tiles} == 0,"and none of its tiles are offered for trimming");


#---------------------------------------------
# the sentinel sweep
#---------------------------------------------

print "\n=== reclassifying a declared blank ===\n";

my $report = cleanAct(undef,[ 'mainkey' ],{ sentinels => 1 });

ok($report->{sent_tiles} == 1,
	"the act converted exactly what the survey counted (got $report->{sent_tiles})");
ok($report->{sent_bytes} == $BLEN,"and freed what it said it would");
ok(!-f "$CACHE/mainkey/12/1_1.jpeg","the blank image is gone");
ok(-f "$CACHE/mainkey/12/1_1.none","and a marker is in its place");

# WHICH KIND OF NOTHING.  An empty marker is a plain absence; this one has
# to say it was the service's own placeholder, or the finding is lost and
# the probe has nothing to report.

my $body = slurp("$CACHE/mainkey/12/1_1.none");
ok(defined($body) && $body =~ /sentinel/,
	"and the marker says it was a sentinel, not a plain absence");

ok($report->{trim_tiles} == 0,"a sentinel sweep trims nothing");
ok(-f "$CACHE/mainkey/12/0_0.jpeg","so the out-of-coverage tile is untouched");

my $again = cleanAct(undef,[ 'mainkey' ],{ sentinels => 1 });
ok($again->{sent_tiles} == 0,"running it again converts nothing");


#---------------------------------------------
# the trim
#---------------------------------------------

print "\n=== trimming what no region wants ===\n";

my $before = cleanSurvey({ trim => 1, keys => [ 'mainkey' ] })->[0];
ok($before->{trim_tiles} == 1,
	"one tile left to trim (got $before->{trim_tiles})");

my $trim = cleanAct(undef,[ 'mainkey' ],{ trim => 1 });
ok($trim->{trim_tiles} == 1,"the act trimmed exactly that one");
ok(!-f "$CACHE/mainkey/12/0_0.jpeg","the tile outside every region is gone");

my ($x0,$y0) = split(/_/,$in12[0]);
ok(-f "$CACHE/mainkey/12/${x0}_${y0}.jpeg","a tile inside a region survives");

# THE MARKERS ARE KNOWLEDGE.  They cost a request each to learn and they
# are nine bytes; trimming them would spend bandwidth to free nothing.

ok(-f "$CACHE/mainkey/12/2_2.none","an absence marker outside coverage survives");
ok(-f "$CACHE/mainkey/12/1_1.none","and so does the one just written");


#---------------------------------------------
# the refusal
#---------------------------------------------

print "\n=== a trim with nothing to keep ===\n";

my $refused = cleanAct(undef,[ 'twinkey' ],{ trim => 1 });
ok(-f "$CACHE/twinkey/9/5_5.jpeg",
	"a cache no region uses is NOT emptied by a trim");
ok($refused->{trim_tiles} == 0,"nothing was trimmed");
ok(scalar(@{$refused->{refused}}) == 1,"and the report says why");

my $lines = join("\n",@{cleanReportLines($refused)});
ok($lines =~ /Not done/,"which reaches the report the user reads");


#---------------------------------------------
# deleting
#---------------------------------------------

print "\n=== deleting caches and definitions ===\n";

my $del = cleanAct(undef,[ 'orphankey' ],{ del_cache => { orphankey => 1 } });
ok($del->{keys_removed} == 1,"the orphan cache was removed");
ok(!-d "$CACHE/orphankey","and its folder is gone");
ok($del->{files_removed} == 1,"one file removed (got $del->{files_removed})");

# ONE OF TWO FILES SHARING A CACHE.  Deleting twin1 must not take twin2's
# definition with it, and the tiles are nobody's to remove here.

my $one = cleanAct(undef,[],{ del_tsd => { 'twin1.tsd' => 1 } });
ok(scalar(@{$one->{tsds}}) == 1,"one definition deleted");
ok(!-f "$ROOT/sources/twin1.tsd","the file is gone");
ok(-f "$ROOT/sources/twin2.tsd","the one sharing its cache_key is not");
ok(-f "$CACHE/twinkey/9/5_5.jpeg","and the shared tiles are still there");

# BOTH AT ONCE, which is what the dialog does when a row has its cache and
# its file ticked together.

my $both = cleanAct(undef,[ 'twinkey' ],{
	del_cache => { twinkey => 1 },
	del_tsd   => { 'twin2.tsd' => 1 } });
ok(!-f "$ROOT/sources/twin2.tsd","the last definition is gone");
ok(!-d "$CACHE/twinkey","and so is the cache it named");
ok($both->{ok},"and the act reports no errors");


#---------------------------------------------
# the preflight is true
#---------------------------------------------

print "\n=== survey against act ===\n";

# THE CLAIM THE WHOLE DIALOG RESTS ON: the number in front of the button
# is the number the act produces.  It holds because both come from the
# same walk with the same rules - not because they were written to agree.

putFile("$CACHE/mainkey/13/9_9.jpeg",$IMAGE);
putFile("$CACHE/mainkey/13/8_8.jpeg",$BLANK);

my $pre = cleanSurvey({ trim => 1, keys => [ 'mainkey' ] })->[0];
my $act = cleanAct(undef,[ 'mainkey' ],{ trim => 1, sentinels => 1 });

ok($pre->{sent_tiles} == $act->{sent_tiles},
	"the survey's blank count is the act's ($pre->{sent_tiles} = $act->{sent_tiles})");
ok($pre->{trim_tiles} == $act->{trim_tiles},
	"the survey's trim count is the act's ($pre->{trim_tiles} = $act->{trim_tiles})");
ok($pre->{sent_bytes} + $pre->{trim_bytes} ==
   $act->{sent_bytes} + $act->{trim_bytes},
	"and so is the number of bytes it promised to free");


print "\n=== cacheStats is remembered until something changes ===\n";

# TOTALLING ONE SOURCE'S CACHE STATS EVERY FILE IN IT - 3.6 seconds on a
# real Esri cache, on whichever thread asked, which for the Sources pane is
# the one drawing the window.  So the answer is memoised against a counter
# the cache bumps on every write and every removal.
#
# THE RULE IS THAT THE COUNTER MOVES WHEN THE ANSWER WOULD, AND ONLY THEN.
# Both halves matter: never moving makes the pane lie after a fetch, and
# moving when nothing happened puts the three seconds back.

my $vsrc = getSource('main_test') or die "no main_test source\n";
my $v0   = dm_cache::cacheVersion($vsrc->{cache_key});

my $s1 = cacheStats($vsrc);
my $s2 = cacheStats($vsrc);
ok($s1 == $s2,
	"asking twice with nothing changed returns the very same structure");
ok(dm_cache::cacheVersion($vsrc->{cache_key}) == $v0,
	"and reading does not move the counter");

my $blob = $IMAGE;
cachePutTile($vsrc,7,3,3,'jpeg',\$blob);
my $v1 = dm_cache::cacheVersion($vsrc->{cache_key});
ok($v1 != $v0,"a written tile moves it");

my $s3 = cacheStats($vsrc);
ok($s3 != $s1,"so the answer is computed again");
ok($s3->{total_tiles} == $s1->{total_tiles} + 1,
	"and it counts the new tile ($s1->{total_tiles} -> $s3->{total_tiles})");

cachePutMiss($vsrc,7,4,4,0);
ok(dm_cache::cacheVersion($vsrc->{cache_key}) != $v1,
	"a recorded absence moves it too");
ok(cacheStats($vsrc)->{total_misses} == $s3->{total_misses} + 1,
	"and is counted as an absence rather than a tile");

# REMOVAL IS THE HALF THAT IS EASY TO FORGET, because a cleanup is the one
# operation certain to change the number the pane is showing.

my $v2 = dm_cache::cacheVersion($vsrc->{cache_key});
ok(cacheRemoveFile(cacheDir()."/mainkey/7/3_3.jpeg"),"the tile is removed");
ok(dm_cache::cacheVersion($vsrc->{cache_key}) != $v2,"which moves it as well");
ok(cacheStats($vsrc)->{total_tiles} == $s1->{total_tiles},
	"and the count comes back to where it started");


print "\n".($fails ? "$fails TEST(S) FAILED" : "ALL PASSED")."\n";
exit($fails ? 1 : 0);
