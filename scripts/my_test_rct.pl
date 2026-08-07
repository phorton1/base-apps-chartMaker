#!/usr/bin/perl
#---------------------------------------------
# t_rct.pl -- build Bocas as an .rct and verify the bytes
#---------------------------------------------
# Writes to a temp path, never to the card folder.  Everything here is
# read back FROM THE FILE rather than from the structures that wrote it,
# because the only thing the E80 will ever see is the bytes.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_cache;
use dm_region;
use dm_coverage;
use dm_rct;

setStandardTempDir('chartMaker');
setStandardDataDir('chartMaker');

my $OUT = 'C:/_temp/base-apps-chartMaker/out';
mkdir $OUT if !-d $OUT;

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_)."\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

$dm_rct::dbg_rct = 0;

loadSources();
openSet(getActiveSet());
my $src = getSource('esri_world_imagery') or die "no esri source\n";
my $reg = getRegion('Bocas') or die "no Bocas\n";

# The exporter takes the tree's RESOLVED source map, not a source -- one
# block is one node, so a subregion may be built from its own source.  The
# build does the resolving and validating; here esri is simply the answer
# for every node, which is what Bocas actually says.

my $ids  = regionSourceMap($reg);
my $srcs = { map { $_ => getSource($ids->{$_}) } keys %$ids };

# WHAT THE MODEL SAYS THIS CARD SHOULD BE.  Derived, never hardcoded:
# Bocas is Patrick's own region and he authors it - subregions appear, zmax
# moves, and a test asserting "9931 tiles, z10-18" then fails on a change
# that is not a defect.  What must hold is that the CARD MATCHES THE
# MODEL, at whatever the model currently says.

my ($want_cov) = regionCoverageNodes($reg,{});
my $want_tiles = coverageTotal($want_cov);
my @want_zooms = sort { $a <=> $b } keys %$want_cov;
my ($want_zmin,$want_zmax) = ($want_zooms[0],$want_zooms[-1]);

printf("model: %s  z%d-%d  %d tiles  zauthor %d\n",
	$reg->{id},$want_zmin,$want_zmax,$want_tiles,$reg->{zauthor});

print "=== build ===\n";
my $path = "$OUT/".rctFileName($reg->{id});
my $st = writeRct($reg,$srcs,$path);
ok(defined($st),"writeRct returned stats");
exit(1) if !$st;

printf("  %s  z%d-%d  %d tiles  %d absent  %d blocks  %.1f MB\n",
	$st->{name},$st->{zoom_min},$st->{zoom_max},
	$st->{tiles},$st->{absent},$st->{blocks},$st->{size}/1048576);

ok($st->{absent} == 0,"nothing was absent - the cache had every tile ($st->{absent})");
ok($st->{failed} == 0,"nothing FAILED - no tile was merely not on disk ($st->{failed})");
ok($st->{tiles} == $want_tiles,
	"the card carries every tile the model covers ($st->{tiles} of $want_tiles)");

# The card is written through a temp file and renamed, so no .tmp may
# survive a build that succeeded.

ok(!-e "$path.tmp","the temp file was renamed away, not left behind");

# ---- read it back as bytes, knowing nothing about how it was made

open(my $fh,'<',$path) or die "cannot reread $path: $!\n";
binmode $fh;
local $/;
my $raw = <$fh>;
close $fh;

print "\n=== header ===\n";
my ($magic,$ver,$hbytes,$tsize,$zauthor,$r1,$zmin,$zmax,$r2,$proj,$flags)
	= unpack('a4 v v v C C C C v V V',substr($raw,0,24));
ok($magic eq 'RCT1',"magic 'RCT1'");
ok($ver == 1,"format_version 1");
ok($hbytes == 128,"header_bytes 128");
ok($tsize == 256,"tile_size_px 256");
ok($zauthor == $reg->{zauthor},
	"zoom_author is the region's zauthor ($zauthor)");
ok($zmin == $want_zmin && $zmax == $want_zmax,
	"the zoom range matches the model (z$zmin-$zmax)");
ok($proj == 3857,"projection 3857");
ok($r1 == 0 && $r2 == 0 && $flags == 0,"reserved and flags are zero");

my ($aoff,$alen) = unpack('V V',substr($raw,0x38,8));
my $rname = unpack('Z48',substr($raw,0x40,48));
ok($rname eq 'Bocas del Toro',"region_name is '$rname'");

print "\n=== attribution blob ===\n";

# 0x38/0x3C USED TO BE RESERVED-ZERO and now locate the credit text.  That
# is deliberately not a version bump: a card written before the field
# existed reads as 0/0, which is exactly "no attribution".

ok($aoff > 0 && $alen > 0,"attrib_offset/length are set ($aoff, $alen)");
ok($aoff + $alen == length($raw),
	"the blob is LAST in the file - offset+length is exactly the file size");

my $attrib = substr($raw,$aoff,$alen);
ok($attrib !~ /[^\x20-\x7E\n]/,
	"every byte is 7-bit ASCII 0x20-0x7E or LF");
ok($attrib !~ /\r/ && $attrib !~ /\0/ && $attrib !~ /\t/,
	"no CR, no NUL, no tabs");
ok(substr($attrib,-1) ne "\0","it is not NUL terminated");
ok($attrib =~ /Esri/,"and it credits the source it was built from");
print "  [$attrib]\n";

# The blob must not have disturbed anything that points into the file.

ok($aoff > 128,"it starts past the header, after the tile data");

print "\n=== zoom directory ===\n";
my $nz = $zmax - $zmin + 1;
my @zdir;
for my $i (0..$nz-1)
{
	my ($z,undef,$cnt,$boff) = unpack('C a3 V V',substr($raw,128 + $i*32,12));
	push @zdir,{ z => $z, count => $cnt, off => $boff };
}
ok(scalar(@zdir) == $want_zmax - $want_zmin + 1,
	"one zoom directory entry per level (".scalar(@zdir).")");
ok((join(',',map { $_->{z} } @zdir) eq join(',',$want_zmin..$want_zmax)),
	"contiguous and ascending: ".join(',',map { $_->{z} } @zdir));

# NOT "one block per zoom" any more, and that was never the invariant.  A
# zoom carries one block PER NODE that reaches it, so a region with detail
# areas has several at the deep levels - which is the format working as
# designed.  What must hold is that every level has at least one and that
# they add up to what the exporter reported.

my $blk_total = 0;
$blk_total += $_->{count} for @zdir;
ok(!scalar(grep { !$_->{count} } @zdir),
	"every level has at least one block: ".join(',',map { $_->{count} } @zdir));
ok($blk_total == $st->{blocks},
	"the zoom directory accounts for every block the exporter wrote ($blk_total)");

print "\n=== blocks, index and bitmap ===\n";
my $present = 0;
my $absent  = 0;
my $bad_off = 0;
my $bad_jpg = 0;
my $mismatch = 0;
my %by_z;

for my $e (@zdir)
{
	for my $b (0..$e->{count}-1)
	{
		my ($x0,$x1,$y0,$y1,$gw,$gh,$ioff,$boff,@merc)
			= unpack('V8 V4',substr($raw,$e->{off} + $b*48,48));

		ok($gw == $x1-$x0+1 && $gh == $y1-$y0+1,
			"z$e->{z} grid_w/h agree with the bounds ($gw x $gh)")
			if $e->{z} == 15 || $e->{z} == 18;

		my $cells = $gw * $gh;
		for my $row (0..$gh-1)
		{
			for my $col (0..$gw-1)
			{
				my $p = $row * $gw + $col;
				my ($o,$l) = unpack('V V',substr($raw,$ioff + $p*8,8));
				my $miss = vec(substr($raw,$boff,int(($cells+7)/8)),$p,1);

				if ($o == 0 && $l == 0)
				{
					$absent++;
					$mismatch++ if !$miss;		# absent cell MUST have bit 1
					next;
				}
				$present++;
				$mismatch++ if $miss;			# present cell MUST have bit 0
				$by_z{$e->{z}}++;

				if ($o + $l > length($raw)) { $bad_off++; next }
				$bad_jpg++ if substr($raw,$o,2) ne "\xFF\xD8";
			}
		}
	}
}

ok($mismatch == 0,"the presence bitmap agrees with the dense index everywhere ".
	"($mismatch disagreement(s)) - bit 1 = ABSENT");
ok($bad_off == 0,"every present tile's offset+length lands inside the file");
ok($bad_jpg == 0,"every present tile starts with the JPEG SOI marker");
ok($present == $want_tiles,
	"every covered tile is present in the file ($present of $want_tiles)");
printf("  present %d   absent-in-rectangle %d   fill %.1f%%\n",
	$present,$absent,100*$present/($present+$absent));

print "\n=== nested coverage: overzoom can never fall through ===\n";
# Every present tile must have a present parent, unbroken to zoom_min.
# Rebuild the present sets from the FILE, then check parentage.
my %set;
for my $e (@zdir)
{
	for my $b (0..$e->{count}-1)
	{
		my ($x0,$x1,$y0,$y1,$gw,$gh,$ioff,$boff) =
			unpack('V8',substr($raw,$e->{off} + $b*48,32));
		for my $row (0..$gh-1)
		{
			for my $col (0..$gw-1)
			{
				my $p = $row*$gw + $col;
				my ($o,$l) = unpack('V V',substr($raw,$ioff + $p*8,8));
				next if $o == 0 && $l == 0;
				$set{$e->{z}}{($x0+$col)."_".($y0+$row)} = 1;
			}
		}
	}
}
my $orphans = 0;
my $orphan_eg = '';
for my $z (sort { $a <=> $b } keys %set)
{
	next if $z == $zmin;
	for my $k (keys %{$set{$z}})
	{
		my ($x,$y) = split(/_/,$k);
		my $pk = int($x/2)."_".int($y/2);
		if (!$set{$z-1}{$pk})
		{
			$orphans++;
			$orphan_eg ||= "z$z $k has no parent z".($z-1)." $pk";
		}
	}
}
ok($orphans == 0,"every present tile has a present parent ($orphans orphan(s)".
	($orphans ? " e.g. $orphan_eg" : "").")");

printf("\n  tiles by zoom: %s\n",
	join('  ',map { "z$_=$by_z{$_}" } sort { $a <=> $b } keys %by_z));

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
