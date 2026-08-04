#!/usr/bin/perl
#---------------------------------------------
# dm_sample.pm
#---------------------------------------------
# IS THIS SERVICE ANY GOOD, AND HOW DEEP DOES IT HOLD UP.
#
# THE SUBJECT IS A TSD.  A region contributes its polygons and NOTHING
# else -- not zmin, not zmax, not zauthor, and above all not the source it
# is assigned.  The zoom range is asked for, not derived.
#
# WHY IT CANNOT BE ABOUT A REGION.  Once a region names its source and its
# levels, the BUILD already answers coverage exactly within those
# constraints; sampling it re-derives a thing already known precisely.  The
# expensive question is the other one: with twenty-five candidate services,
# which are worth specifying at all?  That is a question about a service,
# and the geometry is only where you stand to look at it.
#
# FOUR THINGS A PROBE ANSWERS, in falling order of certainty:
#
#	does it ANSWER here          a refusal; free, and exact
#	does it ADMIT it has nothing a declared no-data body; free, and exact
#	is what it returns IMAGERY   flat fills are neither absent nor imagery
#	does DEPTH buy anything      the expensive one, and optional
#
# A REFUSAL AND A SENTINEL ARE NOT ONE FINDING.  A 404 is a service saying
# "I have nothing here".  A 200 carrying a known no-data image is a service
# DECLINING to say so - you only know because somebody fingerprinted the
# body, and until they did, every one of those counted as imagery.  That is
# a worse property of a service than an honest refusal and it is exactly
# what a candidate evaluation exists to surface, so they are counted and
# drawn separately rather than folded into one 'absent'.
#
# THE FIRST ONE IS OFTEN THE WHOLE ANSWER.  Esri over Bocas refuses 74% of
# z19 and 100% of z20 outright, so its real ceiling is visible with no
# pixels examined at all.  Google never refuses anything at any level, so
# for that class the depth test is the only instrument there is.  Both
# regimes are real and the probe reports which one it is looking at.
#
# THE DEPTH ANSWER IS A NUMBER PER LEVEL, NOT A VERDICT PER TILE.  What is
# reported is the median of what each sample carried over a magnification of
# its own parent, manufactured on the spot from that parent - see dm_image
# for how, and for the two measures that died before it.  1.0 means the
# level is indistinguishable from the one above blown up.  Measured over the
# real cache, google runs 5.1 at z17 down to 1.5 at z21, which is where
# Patrick can see the blotching; the FALL is the finding, not the value.
#
# CACHING A BLOWN-UP TILE IS WORSE THAN NOT HAVING IT.  A z18 magnified
# from z15 costs 64 times the storage and 64 times the fetches of its
# ancestor, and the plotter would have overzoomed a pixel-identical result
# from that ancestor for nothing - which is exactly what the RCT format is
# built to do.  That is what makes the depth answer worth money.
#
# NOTHING PLACED IS EVER REMEMBERED.  Coverage findings live for as long as
# the probe mode does and then they are gone; the user internalises them.
# The only things that persist are PLACELESS facts about the server, which
# is the observation record's own standing rule: rate statistics, and
# candidate fingerprints for a human to look at and promote by hand.

package dm_sample;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;
use cm_prefs;
use cm_state;
use cm_utils;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_fetch;
use dm_engine;
use dm_observe;
use dm_image;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		sampleService
		sampleScope
		sampleBand
		sampleLines
		sampleRowLine
		sampleHeader
		sampleCounts
		sampleWorker
	);
}


our $dbg_sample:shared = 0;
	# 0  = one line per (source,level)
	# -1 = one line per sample


# WHERE THE DESCENT STARTS.  Quantising a polygon directly at z19 walks its
# whole bounding box in z19 tiles, which is the blowup this exists to
# avoid.  Starting coarse and descending arithmetically reaches enough
# cells within log2(want) levels whatever depth is being asked about.

my $COARSE_START = 6;


#---------------------------------------------
# how many, per level
#---------------------------------------------

sub sampleCounts
	# The NUM_SAMPLES table, parsed.  '*:24,19:40' is twenty-four
	# everywhere and forty at z19.
	#
	# ASKED FOR, NOT REQUIRED.  A headless test and the console run with no
	# ini at all, and a survey that could only be run by an application
	# with a preferences file would be a survey that could not be tested.
{
	my ($text) = @_;
	$text = eval { getPref($PREF_NUM_SAMPLES) } if !defined $text;
	$text = '' if !defined $text;

	my %out;
	for my $pair (split(/\s*,\s*/,$text))
	{
		next if $pair !~ /^\s*(\*|\d+)\s*:\s*(\d+)\s*$/;
		$out{$1} = $2 + 0;
	}
	$out{'*'} = 24 if !$out{'*'};
	return \%out;
}


sub _wantAt
{
	my ($counts,$z) = @_;
	return $counts->{$z} || $counts->{'*'} || 24;
}


#---------------------------------------------
# what area is being probed
#---------------------------------------------

sub sampleScope
	# Resolve a scope to ($polygons,$label).  A region, or a subregion by
	# its path - because probing a detail area alone gives a much more
	# intimate answer than probing the whole region around it.
	#
	# THE POLYGONS ARE ALL THAT COMES OUT.  Whatever levels or source the
	# node carries are deliberately left behind.
{
	my ($spec) = @_;
	$spec = { region => $spec } if !ref($spec);

	my $reg = getRegion($spec->{region}) or return (undef,'');
	my $polys = $reg->{geometry};
	my $label = $reg->{id};

	if ($spec->{sub})
	{
		# A PATH OR A BARE ID, because the two surfaces have different
		# things to hand.  The map knows the full 'Region/Sub/Sub' path it
		# walked; the tree carries only the node's own id.  An id is unique
		# within a whole region by validation - not merely among siblings -
		# so searching for one is unambiguous, and refusing the tree's
		# gesture for want of a string it never had would be arbitrary.

		my $node = _findNode($reg,$spec->{sub});
		return (undef,'') if !$node;
		$polys = $node->{geometry};
		$label = $spec->{sub};
	}

	return ($polys,$label);
}


sub _findNode
{
	my ($reg,$want) = @_;
	my ($node) = _findNodeAndParent($reg,$want);
	return $node;
}


sub _findNodeAndParent
	# ($node,$parent).  The parent comes back because a subregion's BAND is
	# defined against it - it starts where the parent's zmax leaves off - and
	# a node cannot say that about itself.  For the root the parent is undef.
{
	my ($reg,$want) = @_;

	my @parts = grep { length } split(m{/},$want);
	shift @parts if @parts && $parts[0] eq $reg->{id};
	return ($reg,undef) if !@parts;

	if (@parts > 1)
	{
		my $node = $reg;
		my $parent;
		for my $id (@parts)
		{
			my ($next) = grep { $_->{id} eq $id } @{$node->{subregions} || []};
			return (undef,undef) if !$next;
			$parent = $node;
			$node = $next;
		}
		return ($node,$parent);
	}

	# One name: walk the whole tree for it, carrying the parent down.
	my $id = $parts[0];
	my @stack = map { [ $_,$reg ] } @{$reg->{subregions} || []};
	while (@stack)
	{
		my ($n,$p) = @{shift @stack};
		return ($n,$p) if $n->{id} eq $id;
		push @stack,map { [ $_,$n ] } @{$n->{subregions} || []};
	}
	return (undef,undef);
}


sub sampleBand
	# THE LEVELS THIS NODE WILL ACTUALLY BE BUILT AT, which is what a probe
	# of it should open on.  Returns ($lo,$hi), or nothing if the node is not
	# there.
	#
	# A REGION IS ITS OWN zmin..zmax.  A SUBREGION IS ITS PARENT'S zmax + 1
	# UP TO ITS OWN - that is the band the region model defines for it, and
	# the reason a subregion carries only a zmax: everything below it is
	# already painted by the thing it sits inside.
	#
	# THIS IS NOT THE PROBE CONSULTING THE REGION.  A probe still samples the
	# range it is HANDED and clamps to nothing; this only decides what the
	# dialog opens showing.  A default is a guess at what you meant, and the
	# levels the node is going to be built at is a better guess than a
	# preference somebody set once - it is, after all, the range you are
	# about to ask a source to satisfy.
{
	my ($spec) = @_;
	$spec = { region => $spec } if !ref($spec);

	my $reg = getRegion($spec->{region}) or return ();
	return ($reg->{zmin},$reg->{zmax}) if !$spec->{sub};

	my ($node,$parent) = _findNodeAndParent($reg,$spec->{sub});
	return () if !$node;
	return ($reg->{zmin},$reg->{zmax}) if $node == $reg || !$parent;

	# A band with nothing in it is a subregion that adds no levels, which
	# dm_region already warns about.  Showing an inverted range would be a
	# second complaint in a worse place, so it falls back to the region's.
	my $lo = $parent->{zmax} + 1;
	return $lo > $node->{zmax} ?
		($reg->{zmin},$reg->{zmax}) : ($lo,$node->{zmax});
}


#---------------------------------------------
# choosing the points
#---------------------------------------------

sub _strataFor
	# Cells to draw from for level $z, and the level they sit at: the
	# COARSEST level that holds enough of them, quantised against the
	# polygon at each step.
	#
	# RE-QUANTISED, NOT DESCENDED, and the difference is not subtle.  The
	# children of a covering tile include every child that lies inside the
	# tile and outside the polygon, so descending from a coarse level over
	# a small area produces a set that is mostly nowhere near it - a 0.15
	# degree box descended from z6 to z9 yields 64 cells of which 2 are on
	# the ground being asked about, and the other 62 are thrown away after
	# being drawn from.  Quantising directly costs the polygon's bounding
	# box in tiles AT THAT LEVEL, and the loop stops the moment there are
	# enough, so the last and most expensive call is bounded by the sample
	# count rather than by the depth being probed.
	#
	# It also self-balances.  A large area has enough cells while they are
	# still coarse, and a coarse cell of a large area is mostly interior,
	# so a descendant drawn inside it is almost always on the ground.  A
	# small area keeps going until the cells are small relative to it, with
	# the same result.
{
	my ($polys,$z,$want) = @_;

	my $az  = $z < $COARSE_START ? $z : $COARSE_START;
	my $set = coverageQuantise($polys,$az);

	while ($az < $z && scalar(keys %$set) < $want)
	{
		$az++;
		$set = coverageQuantise($polys,$az);
	}
	return ($set,$az);
}


sub _pickCells
	# $want of them, or all of them if there are fewer.  Partial
	# Fisher-Yates, so choosing 24 out of 200,000 costs 24 swaps.
{
	my ($set,$want) = @_;
	my @cells = keys %$set;
	return \@cells if @cells <= $want;

	for my $i (0..$want-1)
	{
		my $j = $i + int(rand(scalar(@cells) - $i));
		@cells[$i,$j] = @cells[$j,$i];
	}
	return [ @cells[0..$want-1] ];
}


sub _markAt
	# THE EXACT CENTRE OF THE SAMPLED TILE, and nothing is allowed to move
	# it.
	#
	# THE GRID IS THE WHOLE REASON.  A tile centre at level z is
	# (2x+1)/2^(z+1) of the world, an odd numerator over a power of two, so
	# no two levels can ever produce the same point and every one of them is
	# a vertex of every finer grid.  That is what lets a level's samples read
	# as ITS OWN LATTICE, distinct from every other level's, once enough of
	# them accumulate on the same ground.
	#
	# IT WAS CLIPPED TO THE AREA'S BOUNDING BOX and that destroyed exactly
	# that.  The argument for it was that a z0 tile's centre is a point in
	# the Atlantic - true, and about levels nobody probes.  What it actually
	# did was move every EDGE tile at every level, which over a small polygon
	# is most of them, so the lattice never emerged and a small disjoint
	# polygon had its coarse marks collapsed onto nearly one point.
	#
	# A mark is a claim about a TILE.  A tile that overlaps the region does
	# extend into open water, and drawing it there is the truth.
{
	my ($z,$x,$y) = @_;
	my ($tw,$ts,$te,$tn) = tileBounds($z,$x,$y);
	return (($ts+$tn)/2,($tw+$te)/2);
}


sub _mark
	# 'z/x/y/outcome/lat/lon'.
	#
	# THE POSITION IS STILL CARRIED rather than left for the browser to
	# derive.  It is the same point either way now, but the projection that
	# turns z/x/y into a latitude lives here, next to the geometry the walk
	# uses, and a second implementation of it in javascript is a second
	# chance to disagree.
{
	my ($z,$x,$y,$outcome) = @_;
	my ($lat,$lon) = _markAt($z,$x,$y);
	return sprintf("%d/%d/%d/%s/%.6f/%.6f",$z,$x,$y,$outcome,$lat,$lon);
}


sub _tilesFor
	# The tiles to ask about at level $z, and whether that is ALL of them
	# or a SAMPLE.
	#
	# min(num_samples, level size) is the whole rule.  A level holding
	# fewer tiles than the sample count is enumerated exhaustively and its
	# row reports what is there rather than a projection of it.
{
	my ($polys,$z,$want) = @_;

	my ($set,$az) = _strataFor($polys,$z,$want);
	return ([],1) if !$set || !%$set;

	# AT THE SAMPLE LEVEL THE CELLS ARE THE ANSWER.  coverageQuantise has
	# already applied the geometry, so filtering them again would only be a
	# chance to disagree with it - and a cheaper test would disagree, since
	# at a coarse level a tile can contain the whole area without its
	# centre being inside it.

	if ($az == $z)
	{
		my @all  = keys %$set;
		my $full = scalar(@all) <= $want ? 1 : 0;
		my $pick = $full ? \@all : _pickCells($set,$want);
		return ([ map { [ split(/_/,$_) ] } @$pick ],$full);
	}

	# Below it, one random descendant per cell.  A descendant may lie
	# inside its cell and outside the area, so it is judged by the same
	# geometry the walk uses, with a few attempts before a cell is given
	# up on.

	my $span = 2 ** ($z - $az);
	my @tiles;
	for my $cell (@{_pickCells($set,$want)})
	{
		my ($cx,$cy) = split(/_/,$cell);
		for my $try (1..6)
		{
			my $x = $cx * $span + int(rand($span));
			my $y = $cy * $span + int(rand($span));
			next if !coverageTileHits($polys,$z,$x,$y);
			push @tiles,[$x,$y];
			last;
		}
	}
	return (\@tiles,0);
}


#---------------------------------------------
# one (source, level)
#---------------------------------------------

sub _sampleUnit
{
	my ($src,$polys,$z,$want,$opts) = @_;

	my ($tiles,$exhaustive) = _tilesFor($polys,$z,$want);
	my $row = {
		source		=> $src->{id},
		z			=> $z,
		samples		=> scalar(@$tiles),
		found		=> 0,
		absent		=> 0,
		sentinel	=> 0,
		flat		=> 0,
		failed		=> 0,
		exhaustive	=> $exhaustive,
		graded		=> 0,		# how many got a depth verdict at all
		ratios		=> [],		# every detail ratio measured at this level
		detail		=> undef,	# their median, which is what the row prints
	};
	my @marks;
	return ($row,\@marks) if !@$tiles;

	# CACHE FIRST ON THIS THREAD, submit the rest.  Selection above never
	# consulted the cache, which is what stops a survey becoming a survey
	# of the user's own browsing; resolution does, because asking the
	# engine for a tile already on disk puts a thread handoff in front of a
	# file read.
	#
	# THE PARENT RIDES ALONG.  A sample without its ancestor cannot answer
	# the depth question at all, and fetching it here is what keeps every
	# level's draws statistically independent while still yielding pairs.

	my $want_depth = $opts->{depth} && imageCan() && $z > $src->{zoom}{min};

	my @jobs;
	for my $t (@$tiles)
	{
		my ($x,$y) = @$t;
		my $j = { x => $x, y => $y };
		# THROUGH fetchCacheHit, NOT STRAIGHT OFF cacheGet.  A cache hit
		# MEANS something, and what it means is dm_fetch's to say: a tile
		# stored before its fingerprint was declared is an absence now.
		# Reading the file without asking made this the one reader that
		# called such a tile 'found' - on the surface whose entire job is
		# to notice exactly that.

		my $hit = fetchCacheHit($src,$z,$x,$y,cacheGet($src,$z,$x,$y));
		if ($hit) { $j->{result} = $hit }
		else
		{
			$j->{job} = engineSubmit($src,$z,$x,$y,
				$opts->{priority} || $PRIORITY_BULK,$opts->{advisory});
		}

		if ($want_depth)
		{
			my ($px,$py) = (int($x/2),int($y/2));
			$j->{px} = $px; $j->{py} = $py;
			my $ph = fetchCacheHit($src,$z-1,$px,$py,
				cacheGet($src,$z-1,$px,$py));
			if ($ph) { $j->{presult} = $ph }
			else
			{
				$j->{pjob} = engineSubmit($src,$z-1,$px,$py,
					$opts->{priority} || $PRIORITY_BULK,$opts->{advisory});
			}
		}
		push @jobs,$j;
	}

	for my $j (@jobs)
	{
		my $r = $j->{result} || engineCollect($j->{job});
		my $p = $want_depth ? ($j->{presult} || engineCollect($j->{pjob})) : undef;
		next if !$r;

		if ($r->{status} eq 'absent')
		{
			# THE TWO KINDS ARE COUNTED APART.  dm_fetch decided which this
			# is while it still had the bytes, and the cache remembers it, so
			# nothing here re-examines anything - it reads a flag and puts the
			# sample in the right column.
			#
			# An absence derived from the source's own declared zoom range is
			# neither: it carries no http code and no sentinel flag, and it
			# lands in 'absent' where a refusal does.  A probe widens the
			# range before it asks precisely so that one cannot happen.

			my $kind = $r->{sentinel} ? 'sentinel' : 'absent';
			$row->{$kind}++;
			push @marks,_mark($z,$j->{x},$j->{y},$kind);
			display($dbg_sample,-1,"$src->{id} $z/$j->{x}/$j->{y} $kind");
			next;
		}
		if ($r->{status} ne 'ok')
		{
			# A NETWORK FAILURE IS NOT AN OUTCOME and never enters the
			# ratio.  A timeout says nothing about whether the tile exists,
			# so counting it as an absence would report a bad connection as
			# missing imagery.

			$row->{failed}++;
			$row->{samples}--;
			display($dbg_sample,1,"$src->{id} $z/$j->{x}/$j->{y} failed - ".
				($r->{reason} || 'no reason given'));
			next;
		}

		$row->{found}++;

		# A REPEATED BODY IS A CANDIDATE FINGERPRINT, AND THIS MODULE NO
		# LONGER LOOKS FOR ONE.  It is learned in dm_fetch, where every tile
		# this application ever receives passes, so a sample contributes to
		# the same record a build and a verify do rather than being one of
		# several detectors that could disagree.  A probe still SEES its
		# candidates - by reading the record like everybody else.

		# NO DECODE UNLESS ASKED, and 'flat' is a decode like any other.
		#
		# It used to run on every found tile whenever a decoder existed,
		# which meant a plain probe pushed hundreds of tiles through
		# libjpeg - including sentinels and blank fills it objects to.
		# libgd and libjpeg write their complaints with fprintf(stderr)
		# from C: they never pass through Perl, never reach Pub::Utils, and
		# nothing here can sanitise or serialise them.  A console left in a
		# substituted character set after a probe is the shape of exactly
		# that, and no threaded display() has ever done it.
		#
		# So the decoder is reached only when the user has asked for
		# measurement.  That also makes the default probe - found, absent,
		# fingerprints - free of the one new native dependency, which is
		# where the packaging risk lives anyway.

		my $outcome = 'found';
		if ($opts->{depth} && imageCan())
		{
			my $flat = imageIsFlat($r->{bytes});
			if ($flat)
			{
				$row->{flat}++;
				$row->{graded}++;
				$outcome = 'flat';
			}
			elsif ($want_depth && $p && $p->{status} eq 'ok')
			{
				# THE RATIO IS KEPT AND NO VERDICT IS DRAWN FROM IT.
				#
				# There used to be a per-tile 'nodetail' outcome here,
				# thresholded at 1.25, and it was wrong in both directions on
				# real ground: it fired on open water at z11, where a blow-up
				# costs a handful of tiles and nobody would decide
				# differently, and it did NOT fire on google z21/z22 over a
				# property where the upsampling is visible to the eye.
				#
				# The threshold was the broken part, not the measurement.  The
				# LEVEL MEDIAN did land the boundary - google fell 3.19, 2.36,
				# 1.51 across z19-z21 and the real imagery stops at z20 - so
				# what is kept is the number, and the reading is where it
				# FALLS.  A tile is either found or it is not; how much detail
				# a LEVEL holds is not a property any single tile has.

				my $ratio = imageDetailRatio($p->{bytes},$r->{bytes},
					$j->{x} & 1,$j->{y} & 1);
				if (defined $ratio)
				{
					$row->{graded}++;
					push @{$row->{ratios}},$ratio;
				}
			}
		}

		push @marks,_mark($z,$j->{x},$j->{y},$outcome);
		display($dbg_sample,-1,"$src->{id} $z/$j->{x}/$j->{y} $outcome");
	}

	# THE MEDIAN, NOT THE MEAN.  One tile of open water among twenty-four
	# drags a mean a long way and says nothing about the level; a median is
	# the typical sample, which is the thing being reported.

	$row->{detail} = _median($row->{ratios});

	display($dbg_sample,0,sprintf("%-16s z%-2d %s %d found, %d absent%s%s%s",
		$src->{id},$z,$row->{exhaustive} ? 'all   ' : 'sample',
		$row->{found},$row->{absent},
		$row->{sentinel} ? ", $row->{sentinel} no-data" : '',
		$row->{flat} ? ", $row->{flat} flat" : '',
		$row->{failed} ? ", $row->{failed} FAILED" : ''));

	return ($row,\@marks);
}


sub _median
{
	my ($list) = @_;
	return undef if !$list || !@$list;
	my @s = sort { $a <=> $b } @$list;
	return $s[int(@s/2)];
}


#---------------------------------------------
# the run
#---------------------------------------------

sub sampleService
	# Probe ONE source over one area across an explicit zoom range.
	#
	# opts: zmin, zmax   the range, asked for rather than derived
	#       depth        compare each sample against its parent
	#       counts       override the NUM_SAMPLES table
	#       progress     a shared record from newProgress()
	#       publish      sub($row,$marks) as each level finishes
{
	my ($src_id,$scope,$opts) = @_;
	$opts ||= {};

	my $started = time();
	my $src = getSource($src_id);
	my ($polys,$label) = sampleScope($scope);

	my $out = {
		scope		=> 'service',
		source		=> $src_id,
		name		=> $src ? $src->{name} : '',
		label		=> $label,
		rows		=> [],
		marks		=> [],
		totals		=> { samples => 0, found => 0, absent => 0, sentinel => 0,
						 flat => 0, failed => 0, graded => 0 },
		note		=> '',
		cancelled	=> 0,
		elapsed		=> 0,
	};

	if (!$src)		{ $out->{note} = "no source '$src_id' is installed"; return $out }
	if (!$polys || !@$polys)
					{ $out->{note} = "that area has no polygons"; return $out }

	my $counts = $opts->{counts} || sampleCounts();

	# NOT CLAMPED TO WHAT THE FILE DECLARES, AND THAT IS THE POINT.
	#
	# A probe exists because a .tsd can LIE in both directions: it can
	# promise more than the service delivers, and it can fail to reveal
	# depth the service actually has.  Clamping to zoom.max answers the
	# file, not the server, and a source declaring z0-8 would report a
	# ceiling of 8 no matter what it really held - which is the one answer
	# nobody needs, since it is already written in the file.
	#
	# The protocol guard in dm_source refuses a request outside the
	# declared range, so the probe asks with a WIDENED COPY of the source.
	# Everything that identifies it is unchanged - the id the engine gates
	# on, the cache_key the cache and the observation record use - so this
	# widens exactly one thing and nothing downstream can tell the
	# difference.  It edits no file: 'declared, not detected' governs what
	# is WRITTEN, and a person still promotes a finding by hand.

	my $lo = defined $opts->{zmin} ? $opts->{zmin} : $src->{zoom}{min};
	my $hi = defined $opts->{zmax} ? $opts->{zmax} : $src->{zoom}{max};
	($lo,$hi) = ($hi,$lo) if $lo > $hi;
	$lo = 0  if $lo < 0;
	$hi = 24 if $hi > 24;

	my $declared = $src->{zoom};
	if ($lo < $declared->{min} || $hi > $declared->{max})
	{
		$src = { %$src, zoom => { min => 0, max => 24 } };
		$out->{note} = sprintf(
			"asked past the file's declared z%d-%d - what comes back is the ".
			"service's answer, not the file's",
			$declared->{min},$declared->{max});
	}

	for my $z ($lo .. $hi)
	{
		if (progressCancelled($opts->{progress}) || probeStopRequested())
		{
			# A HALT LEAVES A SMALLER SAMPLE, NOT A BROKEN ONE.  Everything
			# counted is still true of the points it was counted from.
			$out->{cancelled} = 1;
			last;
		}

		my ($row,$marks) = _sampleUnit($src,$polys,$z,_wantAt($counts,$z),$opts);
		next if !$row->{samples} && !$row->{failed};

		push @{$out->{rows}},$row;
		push @{$out->{marks}},@$marks;
		$out->{totals}{$_} += $row->{$_}
			for qw( samples found absent sentinel flat failed graded );

		$opts->{publish}->($row,$marks) if $opts->{publish};
	}

	$out->{elapsed} = time() - $started;
	return $out;
}


sub sampleWorker
	# On a worker thread, publishing into the shared result set as it goes.
	#
	# IT ONLY EVER AMENDS.  The mode holds results from every probe run
	# inside it - several services over the same ground, and the same
	# service run more than once.  Nothing a run does removes anything, and
	# Clear is the only thing that does.
{
	my ($prog,$args,$opts) = @_;
	$opts ||= {};
	my ($src_id,$scope) = @$args;

	probeClearStop();
	probeSetRunning(1);
	probeBeginSource($src_id);

	my $out = sampleService($src_id,$scope,
		{ %$opts, progress => $prog, publish => _publisher($src_id) });

	probeEndSource($src_id,sprintf("%s over %s - %d found, %d absent%s%s%s",
		$src_id,$out->{label} // '?',
		$out->{totals}{found},$out->{totals}{absent},
		$out->{totals}{sentinel} ? ", $out->{totals}{sentinel} no-data" : '',
		$out->{totals}{flat} ? ", $out->{totals}{flat} flat" : '',
		$out->{cancelled} ? ' (halted)' : ''));
	probeSetRunning(0);

	$prog->{ok} = $out->{cancelled} ? 0 : 1;
	push @{$prog->{lines}},@{sampleLines($out)};
	if ($opts->{report})
	{
		display(0,0,$_) for @{$prog->{lines}};
	}
	$prog->{finished} = 1;
}


sub _publisher
{
	my ($src_id) = @_;
	return sub {
		my ($row,$marks) = @_;
		probeAddUnit($src_id,sampleRowLine($row),$marks);
	};
}


#---------------------------------------------
# rendering
#---------------------------------------------

sub sampleRowLine
	# ONE ROW, RENDERED ONCE.  The table being watched and the report being
	# written are the same rows, so they are the same rendering.
	#
	# THE DEPTH COLUMNS ARE BLANK RATHER THAN ZERO when nothing graded
	# them.  A zero would read as 'none of these were blowups', which is a
	# claim; blank reads as 'not measured', which is the truth when there
	# is no decoder or no parent to compare against.
{
	# 'no-data' IS ITS OWN COLUMN AND NOT A NOTE UNDER THE TABLE.  It is a
	# free, exact finding about the service, in the same class as 'absent'
	# and measured the same way, so it belongs beside it - and a service
	# that answers 200 with a blank rather than refusing is the one thing a
	# reader most needs to see WHILE reading the absent column, since
	# without the fingerprint those samples would all have said 'found'.

	# 'detail' IS A NUMBER AND NOT A COUNT, which is the change that made
	# the column worth printing again.  It is the median of what each
	# sample carried over a magnification of its own parent: 1.0 is
	# indistinguishable from that magnification, and real imagery runs 1.5
	# to 5.  A count of tiles crossing a threshold hides the finding that
	# actually decides a zmax, which is a level falling from 3.2 to 1.5
	# while no single tile crosses anything.

	my ($r) = @_;
	return sprintf("%-16s z%-3d %8d %8d %8d %8d %8s %8s   %s",
		substr($r->{source},0,16),$r->{z},
		$r->{samples},$r->{found},$r->{absent},$r->{sentinel},
		($r->{graded} ? $r->{flat} : ''),
		(defined $r->{detail} ? sprintf("%.2f",$r->{detail}) : ''),
		($r->{exhaustive} ? 'all' : 'sampled').
		($r->{failed} ? "  $r->{failed} FAILED" : ''));
}


sub sampleHeader
	# THE HEADING, ONCE.  The written report and the pane both print it, and
	# a heading kept in two places is a table whose columns drift apart from
	# their names the first time one is added.  ($head,$rule).
{
	return (sprintf("%-16s %-4s %8s %8s %8s %8s %8s %8s   %s",
			'source','z','samples','found','absent','no-data','flat',
			'detail',''),
		'-' x 85);
}


sub sampleLines
{
	my ($out) = @_;
	my @lines;

	my $t = $out->{totals};
	my $asked = $t->{samples} + $t->{failed};

	push @lines,$out->{cancelled} ?
		"HALTED - a smaller sample, not a broken one." :
		!$asked ? "NOTHING WAS SAMPLED." : "SAMPLED $asked tile(s).";
	push @lines,'';
	push @lines,sprintf("%s over %s",
		($out->{name} || $out->{source}),($out->{label} // '?'));
	push @lines,$out->{note} if $out->{note};
	push @lines,'';

	if (@{$out->{rows}})
	{
		push @lines,sampleHeader();
		push @lines,sampleRowLine($_) for @{$out->{rows}};
		push @lines,'';
	}

	push @lines,sprintf("%d found, %d absent, %d no-data",
		$t->{found},$t->{absent},$t->{sentinel});

	# WHICH REGIME THIS SERVICE IS IN, said in words, because it decides
	# whether the absent column or the depth columns carry the answer.
	#
	# THREE REGIMES, NOT TWO.  A service that refuses declares its own
	# ceiling; a service that never refuses declares nothing; and a service
	# that answers 200 with a blank is in the third, which reads like the
	# first ONLY because this file happens to name that blank.  Saying so is
	# the difference between "its ceiling is z18" and "its ceiling is z18 as
	# long as somebody keeps the fingerprint up to date".

	if ($asked && !$t->{absent} && !$t->{sentinel})
	{
		push @lines,"This source NEVER refused a tile, so its ceiling ".
			"cannot be read";
		push @lines,"from absences alone.";
	}
	elsif ($t->{absent})
	{
		push @lines,"It refuses tiles it does not have, so the absent ".
			"column is the answer.";
	}

	if ($t->{sentinel})
	{
		push @lines,"It also answers $t->{sentinel} time(s) with its ".
			"declared 'no data' image";
		push @lines,"instead of refusing.  Those read as absences only ".
			"because the .tsd";
		push @lines,"names that body - undeclared, every one of them ".
			"would have counted";
		push @lines,"as imagery.";
	}
	elsif ($asked && !$t->{absent})
	{
		# NOT EVEN A BLANK.  Worth saying explicitly, because 'no-data 0'
		# and 'no-data not looked for' are different, and this source has
		# no fingerprint that could have fired.
		push @lines,"It sent no declared 'no data' body either, so nothing ".
			"here bounds it.";
	}

	push @lines,sprintf("%d request(s) FAILED and are not counted above",
		$t->{failed}) if $t->{failed};

	# WHAT THE DETAIL COLUMN MEANS, said once, beside the table it belongs
	# to, and said in ordinary words.  A bare column of numbers between 1 and
	# 5 explains itself to nobody, and it is the one thing in this report a
	# reader could act on wrongly and spend real money doing it.
	#
	# IT SAYS HOW LITTLE IS KNOWN, and that is not modesty.  The measure has
	# ONE case checked against a human eye.  Anything that read as a verdict
	# would be claiming a confidence that a single confirmed instance does
	# not support, and a number believed too readily is worse than a blank
	# column - which is the mistake the per-tile version made.

	if ($t->{graded})
	{
		push @lines,'';
		push @lines,"DETAIL compares each tile against a blown-up copy of the ".
			"tile above it.";
		push @lines,"1.0 means they are indistinguishable, so that level ".
			"added nothing.";
		push @lines,"Real imagery reads about 1.5 to 5.";
		push @lines,'';
		push @lines,"READ THE COLUMN, NOT THE NUMBER.  Where it falls sharply ".
			"is where the";
		push @lines,"source stops holding real detail and starts enlarging ".
			"what it already";
		push @lines,"had.  The value on its own means little: it drifts with ".
			"the ground, and";
		push @lines,"a source that enlarges AND sharpens scores high while ".
			"having invented";
		push @lines,"every pixel.";
		push @lines,'';
		push @lines,"This has been checked against a human eye in ONE place, ".
			"where a fall";
		push @lines,"from 2.4 to 1.5 was the real ceiling.  Treat it as a ".
			"hint, not an answer.";
	}
	else
	{
		push @lines,"depth was not measured - ".imageWhyNot() if $asked;
	}

	push @lines,sprintf("in %d second(s)",$out->{elapsed} || 0);
	return \@lines;
}


1;
