#!/usr/bin/perl
#---------------------------------------------
# test_image.pl -- headless test of dm_image.pm, the codec seam
#---------------------------------------------
# ENTIRELY OFFLINE, and it makes its own imagery rather than shipping any.
# GD both writes and reads here, so the fixtures are exact: a tile that is
# flat is flat because it was drawn flat, and a tile that is a magnification
# of another is one because GD magnified it.
#
# WHY IT MATTERS THAT THE FIXTURES ARE SYNTHETIC.  The question the seam
# answers is "does this child carry detail its parent did not", and the only
# way to test that honestly is to construct both answers - a child that is
# genuinely a blow-up of its parent, and a child of the same scene that is
# not - and check they are told apart.  Real tiles cannot do that, because
# nobody knows the truth about them.
#
# IT SKIPS ITSELF WHEN THERE IS NO DECODER, which is not a cop-out: the
# application is designed to run without one, and a suite that failed in
# that configuration would be asserting the opposite of the design.
#
# What it is pinning down:
#
#	imageCan is honest, and everything degrades rather than dying
#	a flat tile is detected exactly, with no threshold
#	a noisy tile is not called flat
#	a genuine magnification is called a blow-up
#	real detail at the finer level is NOT called a blow-up
#	the measure has a FIXED POINT: a magnification of the parent reads 1.0
#	an unmeasurable pair yields no number rather than an accusation
#	an exemplar is kept once and is a real, openable image file

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_image;

my $TMP = 'C:/_temp/base-apps-chartMaker';
$Pub::Utils::temp_dir = "$TMP/image_temp";

my $fails = 0;
sub ok
{
	die "ok() needs exactly 2 args, got ".scalar(@_)."\n" if @_ != 2;
	my ($cond,$what) = @_;
	print(($cond ? "  PASS  " : "  FAIL  ").$what."\n");
	$fails++ if !$cond;
}


print "=== is there a decoder ===\n";
my $can = imageCan();
ok(defined $can,"imageCan answers rather than dying (got ".($can?1:0).")");

if (!$can)
{
	# THE WHOLE POINT OF THE SEAM.  No decoder is a supported state, and
	# every question must answer 'no' rather than blow up.
	ok(imageWhyNot() ne '',"and says why not: ".imageWhyNot());
	my $junk = "not an image";
	ok(!imageIsFlat(\$junk),"imageIsFlat is false with no decoder");
	ok(!imageIsBlowup(\$junk,\$junk,0,0),"imageIsBlowup is false with no decoder");
	ok(!defined imageDetailRatio(\$junk,\$junk,0,0),
		"and imageDetailRatio has no number rather than a zero");
	print "\nSKIPPED the rest - no decoder installed, which is a supported\n";
	print "configuration and not a failure.\n";
	print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
	exit 0;
}

require GD;

sub jpegOf
{
	my ($img) = @_;
	my $data = $img->jpeg(90);
	return \$data;
}

# ---- the fixtures --------------------------------------------------

# FLAT: one colour, every pixel.
my $flat = GD::Image->new(256,256,1);
$flat->filledRectangle(0,0,255,255,$flat->colorAllocate(8,38,49));

# NOISY: detail at the finest scale, which is what a real photograph has.
# Seeded by position rather than by rand() so the fixture is the same on
# every run - a test that draws different pixels each time cannot be
# debugged when it fails.
my $fine = GD::Image->new(256,256,1);
for my $y (0..255)
{
	for my $x (0..255)
	{
		my $v = (($x * 37 + $y * 53) % 97) * 2 + 40;
		$fine->setPixel($x,$y,$fine->colorAllocate($v,$v,$v));
	}
}

# A PARENT of that scene: the same pattern at half the spatial frequency,
# which is what the level above holds in a real pyramid.  Drawn rather than
# resampled from the child, so the fixture states the relationship exactly
# instead of inheriting whatever GD's filter happens to do.
my $parent = GD::Image->new(256,256,1);
for my $y (0..255)
{
	for my $x (0..255)
	{
		my $v = ((int($x/2) * 37 + int($y/2) * 53) % 97) * 2 + 40;
		$parent->setPixel($x,$y,$parent->colorAllocate($v,$v,$v));
	}
}

# THE BLOW-UP: quadrant 0,0 of the parent, magnified to full size. This is
# exactly what a service does past its native resolution, and it is the
# thing that must be recognised.
my $blowup = GD::Image->new(256,256,1);
$blowup->copyResampled($parent,0,0,0,0,256,256,128,128);


print "\n=== flat ===\n";
ok(imageIsFlat(jpegOf($flat)),"a single-colour tile is flat");
ok(!imageIsFlat(jpegOf($fine)),"a tile with detail is not flat");
ok(!imageIsFlat(jpegOf($blowup)),"nor is a smooth-but-varying blow-up");

my $junk = "not an image at all";
ok(!imageIsFlat(\$junk),"an undecodable body is not called flat");


print "\n=== does depth buy anything ===\n";

# The child IS the magnified parent, so it carries nothing new.
ok(imageIsBlowup(jpegOf($parent),jpegOf($blowup),0,0),
	"a magnified parent is recognised as carrying no new detail");

# The child is the same scene at genuinely finer resolution.
ok(!imageIsBlowup(jpegOf($parent),jpegOf($fine),0,0),
	"real detail at the finer level is NOT called a blow-up");

# THE ASSERTION THAT WOULD HAVE KILLED THE LAST MEASURE.
#
# The two attempts before this one both passed against fixtures drawn here
# and both failed against a real service, so passing here is worth very
# little on its own.  What IS worth something is that the measure be
# calibrated: a child that is EXACTLY a magnification of its parent must
# read 1.0, because the thing it is divided by is a magnification of that
# same parent manufactured the same way.
#
# The previous measure had no such fixed point.  It compared a service's
# re-encoded output against a freshly magnified parent, so it read whatever
# the encoders happened to differ by - which is precisely why it ranked a
# blown-up level above a real one and why nothing here caught it.

my $r = imageDetailRatio(jpegOf($parent),jpegOf($blowup),0,0);
ok(defined $r,"the ratio is a number for a measurable pair (got ".
	(defined $r ? sprintf('%.2f',$r) : 'undef').")");
ok(defined $r && abs($r - 1.0) < 0.25,
	"a magnification of the parent reads 1.0, which is the fixed point");

my $rr = imageDetailRatio(jpegOf($parent),jpegOf($fine),0,0);
ok(defined $rr && $rr > $DETAIL_RATIO,
	"real detail reads well above the threshold (".
	(defined $rr ? sprintf('%.2f',$rr) : 'undef').")");

# UNMEASURABLE IS NOT AN ACCUSATION.  Flat ground has nothing to divide by,
# so the honest answer is 'no number', not 'blown up' - imageIsFlat has
# already spoken for that tile by an exact test.
ok(!defined imageDetailRatio(jpegOf($flat),jpegOf($flat),0,0),
	"flat ground yields no ratio rather than a made-up one");
ok(!imageIsBlowup(jpegOf($flat),jpegOf($flat),0,0),
	"and is not accused of being a blow-up on the strength of it");

my $junk2 = "not an image";
ok(!defined imageDetailRatio(\$junk2,jpegOf($fine),0,0),
	"an undecodable parent yields no ratio");


print "\n=== describing a candidate ===\n";

# NO EXEMPLAR IS KEPT ANY MORE.  A candidate carries z/x/y and the tile is
# read from the cache, so there is no second copy to test.  What remains is
# the RANKING, which is what a person reads before deciding to look.

my $bytes = jpegOf($flat);
ok(imageDescribe($bytes) =~ /blue/,
	"imageDescribe names the colour: ".imageDescribe($bytes));

my $grey = GD::Image->new(256,256,1);
$grey->filledRectangle(0,0,255,255,$grey->colorAllocate(128,128,128));
ok(imageDescribe(jpegOf($grey)) =~ /SUSPECT/,
	"and a grey fill is ranked suspect: ".imageDescribe(jpegOf($grey)));

print "\n".($fails ? "$fails FAILURE(S)\n" : "ALL PASSED\n");
