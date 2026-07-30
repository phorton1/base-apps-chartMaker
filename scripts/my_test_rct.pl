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

my $OUT = 'C:/_temp/dat-openCPN-chartMaker/out';
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

print "=== build ===\n";
my $path = "$OUT/".rctCardName($reg->{id});
my $st = writeRct($reg,$src,$path);
ok(defined($st),"writeRct returned stats");
exit(1) if !$st;

printf("  %s  z%d-%d  %d tiles  %d absent  %d blocks  %.1f MB\n",
	$st->{name},$st->{zoom_min},$st->{zoom_max},
	$st->{tiles},$st->{absent},$st->{blocks},$st->{size}/1048576);

ok($st->{absent} == 0,"nothing was absent - the cache had every tile ($st->{absent})");
ok($st->{tiles} == 9931,"9931 tiles, matching the coverage count (got $st->{tiles})");

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
ok($zauthor == 15,"zoom_author 15 - the region's zauthor (got $zauthor)");
ok($zmin == 10 && $zmax == 18,"zoom_min 10, zoom_max 18 (got $zmin,$zmax)");
ok($proj == 3857,"projection 3857");
ok($r1 == 0 && $r2 == 0 && $flags == 0,"reserved and flags are zero");

my $code = substr($raw,0x38,8);
ok($code eq "\0" x 8,"0x38 is 8 reserved zero bytes - no coded region field");
my $rname = unpack('Z48',substr($raw,0x40,48));
ok($rname eq 'Bocas del Toro',"region_name is '$rname'");

print "\n=== zoom directory ===\n";
my $nz = $zmax - $zmin + 1;
my @zdir;
for my $i (0..$nz-1)
{
	my ($z,undef,$cnt,$boff) = unpack('C a3 V V',substr($raw,128 + $i*32,12));
	push @zdir,{ z => $z, count => $cnt, off => $boff };
}
ok(scalar(@zdir) == 9,"9 entries for z10-18");
ok((join(',',map { $_->{z} } @zdir) eq join(',',10..18)),
	"contiguous and ascending: ".join(',',map { $_->{z} } @zdir));
ok((join(',',map { $_->{count} } @zdir) eq '1,1,1,1,1,1,1,1,1'),
	"one block per zoom: ".join(',',map { $_->{count} } @zdir));

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
ok($present == 9931,"9931 present cells (got $present)");
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
