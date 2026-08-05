#!/usr/bin/perl
#---------------------------------------------
# dm_image.pm
#---------------------------------------------
# THE ONE PLACE THIS APPLICATION LOOKS AT PIXELS.
#
# A NARROW SEAM WITH TWO CONSUMERS.  The probe asks whether a tile carries
# any detail its ancestor did not; the exporter will one day need a png
# turned into a jpeg for an RCT.  Both are "decode one tile, look at it or
# re-encode it".  Neither resamples the OUTPUT, reprojects, or composites,
# which is the image-processing stack this application refuses and goes on
# refusing.  Magnifying a parent to compare against its child happens
# inside an analysis that writes no file, and no pixel it produces reaches
# a card.
#
# OPTIONAL, AND THE APPLICATION IS WHOLE WITHOUT IT.  If no decoder is
# installed, imageCan() is false, every question here answers 'unknown',
# and a probe still reports samples, found and absent - which for a source
# that refuses what it does not have is the entire answer anyway.  That is
# deliberate: it puts the packaging risk on ONE optional feature instead of
# on the release.
#
# GD RATHER THAN Image::Magick, and the reason is packaging.  GD is a
# single 1 MB GD.dll importing nothing but KERNEL32, MSVCRT and perl512 -
# libjpeg and libpng are statically inside it - and it ships in the core
# ActivePerl tree.  Image::Magick is 155 files and 11 MB: fourteen core
# libraries, dozens of format coders discovered by FILENAME at runtime, a
# bundled X11.dll, and ten XML configuration files it locates by registry
# or environment.  One of those is a file to copy; the other is an
# installation to reproduce.
#
# MSVCRT MATTERS MORE THAN IT LOOKS.  GD.dll and perl512.dll import the
# same MSVCRT.dll, which is an operating system component present on every
# Windows rather than a Visual Studio redistributable needing a
# side-by-side manifest.  So they share one heap, and memory allocated by
# one and freed by the other - the classic mixed-runtime crash - cannot
# happen here.

package dm_image;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		imageCan
		imageWhyNot
		imageCost
		imageToJpeg
		imageIsFlat
		imageDetailRatio
		imageIsBlowup
		imageDescribe
		$DETAIL_RATIO
	);
}


our $dbg_image:shared = 1;
	# 1 = quiet
	# 0 = one line per comparison


my $have;			# undef = not asked yet
my $why = '';


sub imageCan
	# Resolved ONCE per thread and remembered.  A missing decoder is a
	# normal state, not an error, so this never warns and never dies.
{
	return $have if defined $have;
	if (eval { require GD; 1 })
	{
		$have = 1;
		$why  = '';
	}
	else
	{
		$have = 0;
		$why  = 'no image decoder is installed (GD)';
	}
	display($dbg_image,0,"imageCan = $have".($why ? " ($why)" : ''));
	return $have;
}


sub imageWhyNot
{
	imageCan();
	return $why || 'no parent tile was available to compare against';
}


sub imageCost
	# ROUGHLY WHAT ONE DEPTH-MEASURED SAMPLE COSTS IN CPU, so a dialog can
	# say it rather than leaving the user to find out over a long run.
	# Measured at 0.12s on this machine over 96 samples of the real cache;
	# it is a constant because it does not vary with the imagery, only with
	# the fixed number of resamples and encodes per sample.
{
	return 0.12;
}


sub _decode
	# SNIFFED RATHER THAN TRIED, and the difference is thousands of lines of
	# console output.  Handing png bytes to newFromJpegData does return
	# undef, but libjpeg writes "Not a JPEG file" to stderr on its way there
	# -- once per tile, which across a card being converted buries every
	# real message the build had to say.  The magic bytes settle it in three
	# characters without asking a codec anything.
	#
	# The formats named here are exactly the two dm_fetch allows into the
	# cache, so anything else arriving is already a bug somewhere earlier
	# and undef is the right answer to it.
{
	my ($bytes) = @_;
	return undef if !imageCan() || !$bytes;

	my $img;
	if ($$bytes =~ /^\xFF\xD8\xFF/)
	{
		$img = eval { GD::Image->newFromJpegData($$bytes,1) };
	}
	elsif ($$bytes =~ /^\x89PNG\r\n\x1A\n/)
	{
		$img = eval { GD::Image->newFromPngData($$bytes,1) };
	}
	return $img;
}


#---------------------------------------------
# re-encoding, for an exporter
#---------------------------------------------

# WHAT THE QUALITY MEANS, and it is worth stating because the number looks
# more absolute than it is.  GD cannot read a jpeg's quantisation tables,
# so what a service itself encoded at is not knowable -- but byte length
# is, and that is the only handle there has ever been here.
#
# MEASURED over 25 tiles of Waitemata Harbour at z16, fetched from LINZ
# TWICE - once as .jpeg and once as .png, which that service answers at the
# same address.  So both sides are real: the divisor is the jpeg LINZ chose
# to send, and the dividend is what this code makes of the png it sent for
# the same ground.
#
#	   q60   q70   q75   q80   q85   q90   q95  q100
#	  0.69  0.82  0.90  1.03  1.19  1.47  2.00  3.50
#
# So q90 writes a card about half again the size a natively-jpeg source
# would produce, and BYTE-FOR-BYTE PARITY WITH THE SERVICE IS NEAR q80.
# 90 is still the default, because Esri publishes its own imagery at q90
# and matching the most generous service shipped is the defensible place
# to sit -- but a card lives on a CF card, so the trade belongs to the
# user and this is a preference rather than a constant.
#
# THE SAME CURVE MEASURED AGAINST PNGS MADE FROM CACHED JPEGS read parity
# at q70 instead, because such a fixture carries a generation of jpeg
# artifacts and re-compresses more easily than real imagery.  The 1.47 at
# q90 came out the same either way; the parity point did not.  Which is
# the reason these numbers are from the service and not from a fixture.

my $DEFAULT_QUALITY = 90;
my $MIN_QUALITY     = 30;
my $MAX_QUALITY     = 100;


sub imageToJpeg
	# ONE TILE, DECODED AND WRITTEN BACK OUT AS JPEG.  Returns a reference
	# to the new bytes, or undef when there is no decoder or the body will
	# not decode.  A caller that gets undef must say so and stop: the whole
	# reason it asked is that it cannot carry what it already had, so
	# passing the original through would write exactly the card this
	# application most needs not to produce.
	#
	# THE OTHER HALF OF THE SEAM, and not a new capability.  It resamples
	# nothing, reprojects nothing and composites nothing: 256 pixels in and
	# the same 256 pixels out, in a container an .rct can hold.  The
	# image-processing stack this application refuses is still refused.
	#
	# MEASURED AT 4 ms PER TILE on this machine over real LINZ png, which is
	# about two and a half minutes across a 35,000 tile card and nothing at
	# all beside the hours those tiles took to fetch.  That is why nothing
	# here is cached, pooled or threaded.
	#
	# ALPHA IS LOST, because jpeg has nowhere to put it.  Every imagery
	# tile this application fetches is opaque, so today that costs nothing.
	# A transparent overlay would flatten, and that is a fact about jpeg
	# rather than a defect here.
{
	my ($bytes,$quality) = @_;
	my $img = _decode($bytes) or return undef;

	$quality = $DEFAULT_QUALITY if !defined($quality) || $quality !~ /^\d+$/;
	$quality = $MIN_QUALITY if $quality < $MIN_QUALITY;
	$quality = $MAX_QUALITY if $quality > $MAX_QUALITY;

	my $out = eval { $img->jpeg($quality) };
	return undef if !$out || !length($out);
	return \$out;
}


#---------------------------------------------
# flat
#---------------------------------------------

sub imageIsFlat
	# EVERY PIXEL THE SAME COLOUR.  Exact, no threshold, and it is worth
	# its own answer because such a tile is neither an absence nor imagery:
	# the service returned something, and there is nothing in it.
	#
	# Sampled on a grid rather than read whole - a tile with any variation
	# at all fails within the first few pixels, and a genuinely flat one is
	# flat everywhere by definition.
{
	my ($bytes) = @_;
	my $img = _decode($bytes) or return 0;

	my $first;
	for (my $y = 0; $y < 256; $y += 4)
	{
		for (my $x = 0; $x < 256; $x += 4)
		{
			my $p = $img->getPixel($x,$y);
			$first = $p if !defined $first;
			return 0 if $p != $first;
		}
	}
	return 1;
}


#---------------------------------------------
# does depth buy anything
#---------------------------------------------

# THE CONTROL IS A TILE, NOT A NUMBER, and that is the whole of what took
# three attempts to arrive at.
#
# TWO MEASURES DIED BEFORE THIS ONE, both for the same reason one layer
# apart, and neither is worth deriving again:
#
#   BYTES PER PIXEL.  A magnified tile is smooth and compresses small - but
#   so does open water.  Low entropy has two causes and a compression ratio
#   cannot tell them apart.  Measured over Bocas it read a FLAT 45% at every
#   level z10-z18, which was the region's water fraction and not a ceiling.
#
#   HIGH FREQUENCY AGAINST THE MAGNIFIED PARENT.  Mean absolute laplacian of
#   the child over the same measure on its parent magnified here.  Against
#   fixtures drawn by GD it separated them cleanly.  Against Esri over Bocas
#   it went the WRONG WAY: z19 scored 1.31-1.75 and z17 scored 0.77-0.91, so
#   the level believed blown up ranked ABOVE the levels that are real.  The
#   cause is that a service magnifies and then JPEG-encodes, and the encoder
#   puts ringing back as new high-frequency content that a parent freshly
#   magnified in memory has none of.  It measured the encoder.
#
# RE-ENCODING THE MAGNIFIED PARENT DOES NOT FIX THAT, and this was measured
# rather than assumed.  Encoding the magnified parent at q50 through q90, and
# at the quality matching the child's own byte length, moved every number and
# changed no ordering: Esri z19 stayed above z17 and z18 at all of them.
#
# WHAT WORKS IS TO MANUFACTURE THE FALSE ANSWER AND COMPARE AGAINST IT.  For
# every sample the parent's own quadrant is magnified and encoded to the
# child's byte length - which is exactly the tile the service WOULD have sent
# had it held nothing at this level: same ground, same parent, same encoder,
# same amount of compression.  Then the question is no longer "how much
# detail is this" against some absolute, but "how much more than that", and
# everything that defeated the first two measures is present on both sides
# of the division and cancels.
#
# MEASURED, over the real cache, thirty samples a level:
#
#	         z15   z16   z17   z18   z19   z20   z21   z22
#	esri    3.34  3.29  2.33  2.16  3.39
#	google              5.10  4.38  3.19  2.36  1.51  1.71
#
# and a KNOWN magnification fed in as the child reads 1.00 at every level,
# to two decimals, which is the test the second measure would have failed.
# Every one of 30 real tiles beat its own manufactured fake at z15-z20; at
# google z21, where Patrick can see the blotching, 6 of 30 fell under 1.3.
#
# WHAT IT STILL CANNOT DO, said plainly because the number looks more
# confident than it is: a service that magnifies and SHARPENS has invented
# fine detail, and invented fine detail is fine detail.  This reports high
# for that and no pixel measure can do otherwise.  It catches the naive
# magnification - which is the case that costs 64x the storage for nothing -
# and it is a guide for a person choosing a zmax, not a verdict.

my $WINDOW = 128;		# a centred full-resolution window, not a shrink


# WHERE THE LINE SITS, and it is drawn from the measurement rather than
# tuned to a symptom.  A manufactured magnification reads 1.00 exactly.  The
# lowest real tile in the whole run read 0.89, at google z21, and 8 of 471
# real tiles across every source and level fell below 1.3.  So 1.25 catches
# a service handing back its own parent and almost never accuses a real one.

our $DETAIL_RATIO = 1.25;


sub _grey
	# The centred window as one flat greyscale array.  Centred rather than
	# whole because this is the expensive part - one getPixel per pixel
	# through Perl - and a quarter of a tile is a large sample of it.
{
	my ($img) = @_;
	my $o = (256 - $WINDOW) / 2;
	my @g;
	for my $y (0 .. $WINDOW-1)
	{
		for my $x (0 .. $WINDOW-1)
		{
			my ($r,$gg,$b) = $img->rgb($img->getPixel($o+$x,$o+$y));
			$g[$y*$WINDOW+$x] = ($r*77 + $gg*151 + $b*28) >> 8;
		}
	}
	return \@g;
}


sub _fineFraction
	# HOW MUCH OF THIS TILE LIVES AT ITS FINEST SCALE.
	#
	# Halve it and double it back.  Everything the tile holds at scales
	# coarser than a pixel survives that round trip; everything at the
	# finest scale cannot.  So the difference between the tile and its own
	# reconstruction IS its finest-scale content - and a tile that is itself
	# a 2x magnification has almost none by construction, whatever the
	# ground below it looks like.
	#
	# DIVIDED BY THE TILE'S OWN VARIATION, which is what makes it a fraction
	# rather than a quantity of light.  A dark tile and a bright tile of the
	# same scene must answer the same, and an absolute quantity does not.
	#
	# Returns (fraction,variation).  A caller needs the second to know
	# whether the first meant anything: on ground with no variation at all
	# the division is noise over noise.
{
	my ($img) = @_;

	my $half = GD::Image->new(128,128,1);
	$half->copyResampled($img,0,0,0,0,128,128,256,256);
	my $back = GD::Image->new(256,256,1);
	$back->copyResampled($half,0,0,0,0,256,256,128,128);

	my $a = _grey($img);
	my $b = _grey($back);

	my $mean = 0;
	$mean += $_ for @$a;
	$mean /= scalar(@$a);

	my ($res,$var) = (0,0);
	for my $i (0 .. $#$a)
	{
		$res += abs($a->[$i] - $b->[$i]);
		$var += abs($a->[$i] - $mean);
	}
	my $n = scalar(@$a);
	$res /= $n;
	$var /= $n;

	return ($var > 1.0 ? $res/$var : -1,$var);
}


my @QUALITIES = (40,50,60,70,75,80,85,90,95);

sub _manufacture
	# THE TILE THE SERVICE WOULD HAVE SENT had it held nothing here: the
	# child's own quadrant of its own parent, magnified, and encoded to
	# about the number of bytes the child actually arrived in.
	#
	# THE BYTE LENGTH IS THE ONLY HANDLE ON QUALITY THERE IS.  GD cannot
	# read a JPEG's quantisation tables, so the encoder settings a service
	# used are not knowable - but the size of what it sent is, and encoding
	# to the same size is the nearest available statement of "as hard as
	# they compressed it".  Measured, it matters: on the same tiles the
	# answer moves from 1.63 at q60 to 2.09 at q85, and the search lands
	# near q85 for a service that compresses lightly.  Nine encodes of a
	# 256x256 costs about a tenth of what the measurement around it does.
{
	my ($p,$qx,$qy,$len) = @_;

	my $mag = GD::Image->new(256,256,1);
	$mag->copyResampled($p,0,0,($qx?128:0),($qy?128:0),256,256,128,128);

	my ($best,$dist);
	for my $q (@QUALITIES)
	{
		my $data = $mag->jpeg($q);
		my $d = abs(length($data) - $len);
		($best,$dist) = ($data,$d) if !defined($dist) || $d < $dist;
	}
	return undef if !defined $best;
	return GD::Image->newFromJpegData($best,1);
}


sub imageDetailRatio
	# HOW MUCH MORE FINE DETAIL THIS CHILD HOLDS THAN A MAGNIFICATION OF ITS
	# OWN PARENT.  Returns undef when the question has no answer here - no
	# decoder, an undecodable body, or ground so uniform that both sides are
	# measuring noise.
	#
	# 1.0 means indistinguishable from that magnification.  Real imagery
	# measured over the cache runs 1.5 to 5.
{
	my ($pbytes,$cbytes,$qx,$qy) = @_;
	return undef if !imageCan();

	my $p = _decode($pbytes) or return undef;
	my $c = _decode($cbytes) or return undef;
	return undef if $c->width != 256 || $p->width != 256;

	my $fake = _manufacture($p,$qx,$qy,length($$cbytes)) or return undef;

	my ($cf,$cv) = _fineFraction($c);
	my ($ff,$fv) = _fineFraction($fake);
	return undef if $cf < 0 || $ff <= 0.001;

	my $ratio = $cf / $ff;
	display($dbg_image,0,sprintf(
		"detail: child %.3f manufactured %.3f ratio %.2f -> %s",
		$cf,$ff,$ratio,$ratio < $DETAIL_RATIO ? 'NO NEW DETAIL' : 'real'));
	return $ratio;
}


sub imageIsBlowup
	# Does this child carry any detail its parent did not?
	#
	# THE PROBE NO LONGER CALLS THIS, and putting it back on that path is the
	# mistake to avoid rather than the obvious improvement it looks like.
	# Measured on real ground the threshold went both ways wrong: it fired on
	# open water at z11 and stayed silent on google z21/z22 where the
	# enlargement is visible to the naked eye.  What survived is the RATIO,
	# read per level as a column - because "how much detail is here" is a
	# property of a level and not of any single tile.  This is kept as a
	# library answer with a test behind it, not as a verdict anything acts on.
	#
	# It answers "would fetching this level buy me anything HERE", which is
	# the question a zmax is the answer to - and it deliberately does not
	# distinguish "the service invented these pixels" from "the ground has
	# no detail at this scale".  For deciding what to build those are the
	# same answer, and the second is not knowable anyway.
	#
	# UNMEASURABLE IS NOT A BLOW-UP.  With no decoder, or over ground with
	# no variation to speak of, this answers 0 - because 1 is an accusation
	# and 0 is only a failure to make one.  imageIsFlat has already spoken
	# for the genuinely featureless tile, by a different and exact test.
{
	my ($pbytes,$cbytes,$qx,$qy) = @_;
	my $ratio = imageDetailRatio($pbytes,$cbytes,$qx,$qy);
	return 0 if !defined $ratio;
	return $ratio < $DETAIL_RATIO ? 1 : 0;
}


#---------------------------------------------
# NO EXEMPLAR IS KEPT, AND THAT IS THE DESIGN
#---------------------------------------------
# imageKeepExemplar used to write a second copy of every candidate body
# beside the observation record, so that a person could open it.  It is
# gone, and what replaced it is a COORDINATE.
#
# The tile is already in the cache.  A copy meant writing every candidate
# twice, needed a reaper as the candidate list churned - which it never
# had, so the folder grew forever - and put the picture furthest from the
# moment it is most useful, which is when a cleanup is about to delete the
# real one.  A candidate now carries z/x/y and whoever wants to look reads
# the cache, or refetches that one tile.

sub imageDescribe
	# What a candidate body LOOKS like, in words, so a list of them can be
	# ranked before anybody opens one.
	#
	# Patrick's rule of thumb, mechanised: a repeated fill that is blue,
	# white or green is plausibly real ground - ocean, snow, canopy - and a
	# repeated fill that is anything else, grey and black above all, is
	# suspect.  It ranks candidates; it decides nothing.
{
	my ($bytes) = @_;
	my $img = _decode($bytes) or return 'undecodable';

	my ($rs,$gs,$bs,$n) = (0,0,0,0);
	for (my $y = 0; $y < 256; $y += 8)
	{
		for (my $x = 0; $x < 256; $x += 8)
		{
			my ($r,$g,$b) = $img->rgb($img->getPixel($x,$y));
			$rs+=$r; $gs+=$g; $bs+=$b; $n++;
		}
	}
	my ($r,$g,$b) = (int($rs/$n),int($gs/$n),int($bs/$n));

	my $max = $r; $max = $g if $g > $max; $max = $b if $b > $max;
	my $min = $r; $min = $g if $g < $min; $min = $b if $b < $min;

	my $name =
		($max - $min) < 12 ? ($max > 200 ? 'white' :
							  $max <  60 ? 'black' : 'grey') :
		$b == $max ? 'blue' :
		$g == $max ? 'green' : 'brown';

	# SUSPECT is not a verdict, it is an ordering.  Ocean and icecap are
	# the legitimate flat cases and they are blue and white.
	my $suspect = ($name eq 'grey' || $name eq 'black') ? ' SUSPECT' : '';

	return sprintf("rgb(%d,%d,%d) %s%s",$r,$g,$b,$name,$suspect);
}


1;
