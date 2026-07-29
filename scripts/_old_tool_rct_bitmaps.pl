#!/usr/bin/perl
# The block descriptors are identical, so both files agree on where every
# bitmap lives.  If the bitmaps also match, the two cards carry the SAME
# TILES and the remaining difference is only the order the blobs were
# written in -- which is invisible to the renderer, because it reaches
# every tile through the index.
use strict;
use warnings;

my %f;
for my $p (['old','C:/dat/openCPN/OLD_RASTER/BOCAS.RCT'],
		   ['new','C:/dat/openCPN/RASTER/Bocas.rct'])
{
	open(my $fh,'<',$p->[1]) or die "$p->[1]: $!\n";
	binmode $fh; local $/; $f{$p->[0]} = <$fh>; close $fh;
}

my ($zmin,$zmax) = unpack('C C',substr($f{new},0x0c,2));
my $nz = $zmax - $zmin + 1;

my $same = 1;
my $tiles_old = 0;
my $tiles_new = 0;

printf("%-5s %-10s %-10s %s\n",'zoom','old tiles','new tiles','bitmap');
for my $i (0..$nz-1)
{
	my ($z,undef,$cnt,$boff) = unpack('C a3 V V',substr($f{new},128+$i*32,12));
	for my $b (0..$cnt-1)
	{
		my ($x0,$x1,$y0,$y1,$gw,$gh,$ioff,$bmoff) =
			unpack('V8',substr($f{new},$boff+$b*48,32));
		my $cells = $gw*$gh;
		my $nb    = int(($cells+7)/8);

		my $bo = substr($f{old},$bmoff,$nb);
		my $bn = substr($f{new},$bmoff,$nb);

		my ($co,$cn) = (0,0);
		for my $p (0..$cells-1)
		{
			$co++ if !vec($bo,$p,1);
			$cn++ if !vec($bn,$p,1);
		}
		$tiles_old += $co;
		$tiles_new += $cn;
		my $eq = ($bo eq $bn);
		$same = 0 if !$eq;
		printf("z%-4d %-10d %-10d %s\n",$z,$co,$cn,$eq ? 'identical' : 'DIFFERS');
	}
}
printf("\ntotal   old %d   new %d\n",$tiles_old,$tiles_new);
print $same
	? "\nEVERY PRESENCE BITMAP IS IDENTICAL - the two cards carry the same tiles.\n"
	: "\nbitmaps differ - the cards carry different tiles.\n";
