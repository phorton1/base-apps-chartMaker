#!/usr/bin/perl
# Pre-flight: run the FIRMWARE'S OWN arithmetic over the card we are
# about to ship, because two of its failure modes are silent.
#
#   step_e = (merc_e_e - merc_e_w) / grid_w      integer division
#   step_n = (merc_n_s - merc_n_n) / grid_h
#
# A zero step in either axis makes aerial.c skip the block EVERYWHERE -
# it will not draw, will not contribute a coverage outline, and will not
# say anything.  Also counts the reveal-mask rectangles at zoom_author
# against MASK_MAX_RECTS, since overflow silently reveals the whole plane.
use strict;
use warnings;

my $CARD = shift || 'C:/dat/openCPN/RASTER/Bocas.rct';
my $MASK_MAX_RECTS = 128;

open(my $fh,'<',$CARD) or die "$CARD: $!\n";
binmode $fh; local $/; my $raw = <$fh>; close $fh;

sub s32 { my $v = shift; return $v >= 2147483648 ? $v - 4294967296 : $v }

my $zauthor = unpack('C',substr($raw,0x0a,1));
my ($zmin,$zmax) = unpack('C C',substr($raw,0x0c,2));
printf("%s\n  zoom_author=%d  zoom_min=%d  zoom_max=%d\n\n",
	$CARD,$zauthor,$zmin,$zmax);

my $bad = 0;
printf("%-5s %-8s %-8s %-14s %-14s\n",'zoom','grid_w','grid_h','step_e','step_n');
for my $i (0..$zmax-$zmin)
{
	my ($z,undef,$cnt,$boff) = unpack('C a3 V V',substr($raw,128+$i*32,12));
	for my $b (0..$cnt-1)
	{
		my @be = unpack('V12',substr($raw,$boff+$b*48,48));
		my ($gw,$gh) = ($be[4],$be[5]);
		my $step_e = int((s32($be[9])  - s32($be[8]))  / $gw);
		my $step_n = int((s32($be[11]) - s32($be[10])) / $gh);
		printf("z%-4d %-8d %-8d %-14d %-14d %s\n",$z,$gw,$gh,$step_e,$step_n,
			($step_e && $step_n) ? '' : '<-- ZERO STEP: SILENTLY SKIPPED');
		$bad++ if !$step_e || !$step_n;
	}
}
print $bad ? "\n$bad BLOCK(S) WOULD BE INVISIBLE\n"
		   : "\nevery block has a non-zero step in both axes\n";

# ---- reveal-mask rectangles at zoom_author, the firmware's own decomposition:
# maximal horizontal runs of present cells, closed at block edges too.
my $runs = 0;
for my $i (0..$zmax-$zmin)
{
	my ($z,undef,$cnt,$boff) = unpack('C a3 V V',substr($raw,128+$i*32,12));
	next if $z != $zauthor;
	for my $b (0..$cnt-1)
	{
		my @be = unpack('V12',substr($raw,$boff+$b*48,48));
		my ($gw,$gh,$bm) = ($be[4],$be[5],$be[7]);
		my $bits = substr($raw,$bm,int(($gw*$gh+7)/8));
		for my $row (0..$gh-1)
		{
			my $in = 0;
			for my $col (0..$gw-1)
			{
				my $present = !vec($bits,$row*$gw+$col,1);
				$runs++ if $present && !$in;
				$in = $present;
			}
		}
	}
}
printf("\nreveal-mask rectangles at z%d (whole region in view): %d of %d\n",
	$zauthor,$runs,$MASK_MAX_RECTS);
print $runs > $MASK_MAX_RECTS
	? "  OVER BUDGET - mask_full, the whole plane is revealed at wide views\n"
	: "  within budget\n";
print "  NOTE: this is ONE region. The budget is shared across every file\n".
	  "  on the card, so a view holding two regions sums their runs.\n";
