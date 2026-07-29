#!/usr/bin/perl
#---------------------------------------------
# t_merc.pl -- the E80 semicircle math, against the shipped oracle
#---------------------------------------------
# OLD_RASTER/BOCAS.RCT was written by the old python rct_export.py and
# has been looked at on the hardware hundreds of times.  Its block
# descriptors are the same 48-byte layout as the current spec, so its
# merc corners are a byte-level oracle for the one piece of arithmetic
# that fails invisibly: get it wrong and the imagery lands in the wrong
# place while looking perfectly fine.
#
# The TILE SETS will not match -- the old build used exclusive ownership
# and a one-level fill, the new one welds boundaries and uses the band
# rule.  Only the projection is being compared, by feeding the OLD
# file's own x/y bounds through the NEW code.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_coverage;
use dm_rct;

my $OLD = 'C:/dat/openCPN/OLD_RASTER/BOCAS.RCT';

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_)."\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}

open(my $fh,'<',$OLD) or die "cannot read $OLD: $!\n";
binmode $fh;
local $/;
my $raw = <$fh>;
close $fh;

printf("oracle: %s  (%d bytes)\n\n",$OLD,length($raw));

print "=== the old file still reads as RCT1 ===\n";
my $magic = substr($raw,0,4);
ok($magic eq 'RCT1',"magic is 'RCT1' (got '$magic')");

my ($zmin,$zmax) = unpack('C C',substr($raw,0x0c,2));
ok($zmin >= 0 && $zmax > $zmin && $zmax < 32,
	"zoom_min=$zmin zoom_max=$zmax at 0x0c/0x0d");

# The zoom directory's first 12 bytes did not move between the old
# layout and the current one: zoom, 3 pad, block_count, blocks_offset.

my $nz = $zmax - $zmin + 1;
print "\n=== walking its zoom directory ===\n";
my @blocks;
for my $i (0..$nz-1)
{
	my $e = substr($raw,128 + $i*32,12);
	my ($z,undef,$cnt,$boff) = unpack('C a3 V V',$e);
	ok($z == $zmin + $i,"entry $i is z$z, ascending and contiguous");
	for my $b (0..$cnt-1)
	{
		push @blocks,[ $z, substr($raw,$boff + $b*48,48) ];
	}
}
printf("  %d block(s) across z%d-%d\n",scalar(@blocks),$zmin,$zmax);

print "\n=== every block's merc corners, recomputed ===\n";
my $checked = 0;
my $worst   = 0;
my $worst_d = '';

for my $pair (@blocks)
{
	my ($z,$bin) = @$pair;
	my ($x0,$x1,$y0,$y1,$gw,$gh,$ioff,$boff,
		$e_w,$e_e,$n_n,$n_s) = unpack('V8 V4',$bin);

	# The stored values are s32 written as a bit pattern; compare in the
	# same unsigned form the new code emits.
	my ($w,undef,undef,$north) = tileBounds($z,$x0,$y0);
	my (undef,$south,$east,undef) = tileBounds($z,$x1,$y1);

	my $mine_ew = dm_rct::_semiEasting($w);
	my $mine_ee = dm_rct::_semiEasting($east);
	my $mine_nn = dm_rct::_semiNorthing($north);
	my $mine_ns = dm_rct::_semiNorthing($south);

	for my $t ([$e_w,$mine_ew,'east_w'],[$e_e,$mine_ee,'east_e'],
			   [$n_n,$mine_nn,'north_n'],[$n_s,$mine_ns,'north_s'])
	{
		my ($old,$new,$what) = @$t;
		my $d = abs($old - $new);
		if ($d > $worst) { $worst = $d; $worst_d = "z$z $what old=$old new=$new" }
		$checked++;
	}
}

printf("  compared %d corners across %d blocks\n",$checked,scalar(@blocks));
ok($worst == 0,"every corner is EXACT (worst difference $worst".
	($worst ? " -- $worst_d" : "").")");

print "\n=== the projection is not WGS84, and that matters ===\n";
# At 9.33N the geodetic reduction is thousands of metres.  If someone
# 'simplifies' _semiNorthing by dropping C1, this catches it.
my $with    = dm_rct::_semiNorthing(9.334083);
my $without = do {
	my $rad = 9.334083 * 3.14159265358979 / 180;
	my $psi = atan2(sin($rad)/cos($rad),1);
	int(2147483648.0/3.14159265358979 *
		log(sin(3.14159265358979/4+$psi/2)/cos(3.14159265358979/4+$psi/2)) + 0.5);
};
my $semis = abs($with - $without);
my $metres = $semis * 180.0 / 2147483648.0 * 111132.0;
ok($semis > 0,sprintf("dropping C1 moves Popa00 by %d semicircles (~%.0f m) - ".
	"the reduction is load bearing",$semis,$metres));

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
