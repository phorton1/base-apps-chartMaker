#!/usr/bin/perl
# Where do the old card and the new one actually differ?
use strict;
use warnings;

my %f;
for my $p (['old','C:/dat/openCPN/OLD_RASTER/BOCAS.RCT'],
		   ['new','C:/dat/openCPN/RASTER/Bocas.rct'])
{
	open(my $fh,'<',$p->[1]) or die "$p->[1]: $!\n";
	binmode $fh; local $/; $f{$p->[0]} = <$fh>; close $fh;
}
printf("old %d bytes, new %d bytes\n\n",length($f{old}),length($f{new}));

# regions: header, zoom directory, block descriptors, then everything else
my ($zmin,$zmax) = unpack('C C',substr($f{new},0x0c,2));
my $nz     = $zmax - $zmin + 1;
my $zd_off = 128;
my $zd_end = 128 + $nz*32;

# blocks follow the zoom directory contiguously in both writers
my (undef,undef,undef,$first_boff) = unpack('C a3 V V',substr($f{new},$zd_off,12));
my $nblocks = 0;
for my $i (0..$nz-1)
{
	my (undef,undef,$cnt) = unpack('C a3 V',substr($f{new},$zd_off+$i*32,8));
	$nblocks += $cnt;
}
my $blk_end = $first_boff + $nblocks*48;

my @regions = (
	[ 'header',            0,        128      ],
	[ 'zoom directory',    $zd_off,  $zd_end  ],
	[ 'block descriptors', $first_boff, $blk_end ],
	[ 'index+bitmap+tiles',$blk_end, length($f{new}) ],
);

for my $r (@regions)
{
	my ($name,$from,$to) = @$r;
	my $a = substr($f{old},$from,$to-$from);
	my $b = substr($f{new},$from,$to-$from);
	my $ndiff = 0;
	for my $i (0..length($a)-1)
	{
		$ndiff++ if substr($a,$i,1) ne substr($b,$i,1);
	}
	printf("%-20s 0x%06x..0x%06x  %8d bytes  %s\n",
		$name,$from,$to,$to-$from,
		$ndiff ? "$ndiff byte(s) differ" : "IDENTICAL");
}

print "\n=== the header, field by field ===\n";
printf("%-18s %-28s %s\n",'field','old','new');
my @fields = (
	[ 'magic',        0x00, 4, 'a4' ],
	[ 'format_version',0x04,2, 'v'  ],
	[ 'header_bytes', 0x06, 2, 'v'  ],
	[ 'tile_size_px', 0x08, 2, 'v'  ],
	[ '0x0a (zoom_author)',0x0a,1,'C'],
	[ 'zoom_min',     0x0c, 1, 'C'  ],
	[ 'zoom_max',     0x0d, 1, 'C'  ],
	[ 'projection',   0x10, 4, 'V'  ],
);
for my $fl (@fields)
{
	my ($n,$o,$l,$fmt) = @$fl;
	my $a = unpack($fmt,substr($f{old},$o,$l));
	my $b = unpack($fmt,substr($f{new},$o,$l));
	printf("%-18s %-28s %-28s %s\n",$n,$a,$b,$a eq $b ? '' : '<-- differs');
}
my $obytes = unpack('H*',substr($f{old},0x18,40));
my $nbytes = unpack('H*',substr($f{new},0x18,40));
print "\n0x18..0x3f (was bounds+region_code, now reserved):\n";
print "  old $obytes\n  new $nbytes\n";
printf("\nregion_name  old='%s'  new='%s'\n",
	unpack('Z48',substr($f{old},0x40,48)),
	unpack('Z48',substr($f{new},0x40,48)));
