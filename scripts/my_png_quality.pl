#!/usr/bin/perl
#---------------------------------------------
# my_png_quality.pl -- what converting a png costs, against a real service
#---------------------------------------------
# WHERE THE NUMBERS IN dm_image.pm CAME FROM, and how to get them again if
# the default quality is ever argued about.  It fetches the same ground
# from LINZ TWICE - once as .jpeg and once as .png, which that service
# answers at the same address - so both sides of the ratio are real: the
# divisor is the jpeg LINZ chose to send, and the dividend is what
# imageToJpeg makes of the png it sent for the same tile.
#
# IT EXISTS BECAUSE A FIXTURE GOT IT WRONG.  The curve was first measured
# against pngs MADE FROM CACHED JPEGS, which carry a generation of jpeg
# artifacts a genuine png does not and re-compress too easily.  That
# fixture put byte-for-byte parity at q70; the real png puts it at q80.
# The 1.47x at q90 came out the same either way - so the error was
# invisible in the number anybody would have checked.
#
# 'my_' BECAUSE IT NEEDS A LINZ KEY, from Patrick's key store.  See
# my_test_png.pl on the 90-day expiry.
#
# IT WRITES NOTHING ANYWHERE.  fetchTile is the network and nothing else -
# no cache is consulted or written - and the two sources are loaded from
# .tsd files under C:/_temp rather than installed.  Patrick's data dir is
# read for exactly two things: the key store, and the preferences that say
# where it is.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Time::HiRes qw( time );
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_keys;
use dm_source;
use dm_fetch;
use dm_image;

my $TMP = 'C:/_temp/base-apps-chartMaker';

$Pub::Utils::data_dir = '/base_data/data/chartMaker';
$Pub::Utils::temp_dir = "$TMP/linz_temp";
init_prefs();
loadKeys();

my $LAYER = 'aerial';
my $BASE  = 'https://basemaps.linz.govt.nz/v1/tiles/'.$LAYER.
			'/WebMercatorQuad/{z}/{x}/{y}';


sub tsd
{
	my ($id,$fmt) = @_;
	return <<"EOJ";
{
  "tsd_version": 1,
  "id": "$id",
  "cache_key": "$id",
  "name": "LINZ $LAYER as $fmt",
  "url": "$BASE.$fmt?api={linz_api_key}",
  "tile_format": "$fmt",
  "tile_size": 256,
  "crs": "EPSG:3857",
  "zoom": { "min": 0, "max": 22 },
  "attribution": "Sourced from the LINZ Data Service and licensed for reuse under CC BY 4.0",
  "keys": [ { "key_name": "linz_api_key",
              "label": "LINZ Basemaps API key",
              "obtain_url": "https://basemaps.linz.govt.nz/" } ],
  "uses": ["display","build"],
  "policy": { "max_concurrency": 1, "min_interval_ms": 60 }
}
EOJ
}

# THE LOADER'S RETURN VALUE, NOT getSource().  Every read through getSource
# goes via _current(), which rescans Patrick's sources folder and drops
# anything not in it - these two deliberately are not.  _loadFile hands the
# validated object straight back, which is the whole of what is wanted here.

sub loadTsd
{
	my ($id,$fmt) = @_;
	my $path = "$TMP/$id.tsd";
	open(my $fh,'>',$path) or die "cannot write $path: $!";
	print $fh tsd($id,$fmt);
	close $fh;
	my $src = dm_source::_loadFile($path,"$id.tsd");
	die "could not load $id - see the log above\n" if !$src;
	return $src;
}

my $SRC_J = loadTsd('linzpng_j','jpeg');
my $SRC_P = loadTsd('linzpng_p','png');

print "=== the key ===\n";
my $bad = sourceUnresolved($SRC_J);
if ($bad)
{
	print "FAIL: nothing in the key store is bound to '$bad'\n";
	exit 1;
}
print "linz_api_key resolves\n\n";


#---------------------------------------------
# where to look
#---------------------------------------------
# WAITEMATA HARBOUR, which is the ground the survey fetched over and where
# LINZ holds real detail rather than upsampled satellite.

my $LAT  = -36.843;
my $LON  = 174.760;
my $Z    = 16;
my $SPAN = 5;			# SPAN x SPAN tiles

my $n  = 2 ** $Z;
my $x0 = int(($LON + 180) / 360 * $n);
my $rad = $LAT * 3.14159265358979 / 180;
my $y0 = int((1 - log((sin($rad)/cos($rad)) +
			(1/cos($rad))) / 3.14159265358979) / 2 * $n);

printf("z%d around %.3f,%.3f -> x %d..%d  y %d..%d\n\n",
	$Z,$LAT,$LON,$x0,$x0+$SPAN-1,$y0,$y0+$SPAN-1);


#---------------------------------------------
# fetch each tile twice
#---------------------------------------------

print "=== fetching ===\n";
my (@jpegs,@pngs);
my $failed = 0;

for my $dx (0 .. $SPAN-1)
{
	for my $dy (0 .. $SPAN-1)
	{
		my ($x,$y) = ($x0+$dx,$y0+$dy);

		my $j = fetchTile($SRC_J,$Z,$x,$y);
		my $p = fetchTile($SRC_P,$Z,$x,$y);

		if (($j->{status} // '') ne 'ok' || ($p->{status} // '') ne 'ok')
		{
			$failed++;
			printf("  %d/%d/%d  jpeg=%s png=%s\n",$Z,$x,$y,
				$j->{status} // '?',$p->{status} // '?');
			next;
		}

		# THE FORMAT IS DETECTED, NOT ASSUMED, which is the whole subject
		# of this exercise.  If LINZ answered the .png address with jpeg
		# the measurement below would be meaningless and this says so.

		if ($j->{format} ne 'jpeg' || $p->{format} ne 'png')
		{
			printf("  %d/%d/%d  UNEXPECTED formats: .jpeg gave %s, ".
				".png gave %s\n",$Z,$x,$y,$j->{format},$p->{format});
			$failed++;
			next;
		}

		push @jpegs,${$j->{bytes}};
		push @pngs, ${$p->{bytes}};
	}
}

printf("got %d tile pairs (%d unusable)\n\n",scalar(@jpegs),$failed);
if (!@jpegs)
{
	print "nothing to measure\n";
	exit 1;
}

my ($jb,$pb) = (0,0);
$jb += length($_) for @jpegs;
$pb += length($_) for @pngs;
my $mean_j = $jb / scalar(@jpegs);
my $mean_p = $pb / scalar(@pngs);

print "=== on the wire ===\n";
printf("LINZ jpeg   %8.0f bytes mean\n",$mean_j);
printf("LINZ png    %8.0f bytes mean  (%.1fx the jpeg)\n",
	$mean_p,$mean_p/$mean_j);
print "\n";


#---------------------------------------------
# the curve, against a genuine png this time
#---------------------------------------------

print "=== converting the REAL png ===\n";
printf("%-6s %12s %12s\n",'q','mean bytes','vs LINZ jpeg');

for my $q (60,70,75,80,85,90,95,100)
{
	my $sum = 0;
	my $cnt = 0;
	for my $p (@pngs)
	{
		my $out = imageToJpeg(\$p,$q) or next;
		$sum += length($$out);
		$cnt++;
	}
	next if !$cnt;
	printf("q%-5d %12.0f %11.2fx\n",$q,$sum/$cnt,($sum/$cnt)/$mean_j);
}

print "\n=== cost ===\n";
my $t0 = time();
my $did = 0;
for my $p (@pngs)
{
	imageToJpeg(\$p,90) or next;
	$did++;
}
my $el = time() - $t0;
printf("%d real png tiles converted in %.3f s -> %.2f ms each\n",
	$did,$el,1000*$el/$did);

print "\ndone\n";
