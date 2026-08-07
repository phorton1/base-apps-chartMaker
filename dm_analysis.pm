#!/usr/bin/perl
#---------------------------------------------
# dm_analysis.pm
#---------------------------------------------
# WHAT WILL THIS COST, asked before anything is committed to.
#
# One question: for these regions, how many tiles are already here, how
# many must be fetched, and roughly how long will that take.  Nobody
# should be asked to commit to a possibly multi-hour process without it.
#
# ONE readdir PER (SOURCE, ZOOM), NOT THREE stat PER TILE.  Measured on
# the real five-region Panama set, 25,500 tiles across a 36,000 file
# cache:
#
#	probing each tile the way cacheGet does   2.213s cold  2.185s warm
#	reading each cache directory once         0.127s cold  0.126s warm
#
# Seventeen times, and the naive version is no faster warm because it is
# syscall bound rather than disk bound - it would not improve on a faster
# drive either.  A single region indexes in about 0.12s, which is what
# makes a preflight dialog able to appear immediately rather than after a
# pause with a spinner in it.
#
# EVERYTHING IS GROUPED BY SOURCE, and that is structural rather than
# presentational.  A region set may legitimately use several sources - a
# subregion may name its own - and each has its own cache directory, its
# own declared rate limit and its own achieved speed.  A single blended
# number could not be computed correctly and would not say which source is
# the long pole even if it could.

package dm_analysis;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON;
use Time::HiRes qw( time );
use Pub::Utils;
use cm_defs;
use cm_config;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_observe;
use dm_rct;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		analyseFetch
		analysisLines
	);
}


our $dbg_analysis:shared = 1;
	# 1 = quiet
	# 0 = one line per region
	# -1 = one line per (source,zoom) directory read


#---------------------------------------------
# the cache index
#---------------------------------------------

sub _zoomIndex
	# One (source, zoom) cache directory read once into a hash, and kept
	# for the rest of this analysis because the same pair recurs constantly
	# across regions and nodes.
{
	my ($cache,$src,$z) = @_;
	my $key = "$src->{cache_key}/$z";
	return $cache->{$key} if $cache->{$key};

	my %have;
	my $dir = cacheDir()."/$src->{cache_key}/$z";
	if (opendir(my $dh,$dir))
	{
		while (defined(my $f = readdir($dh)))
		{
			next if $f !~ /^(\d+)_(\d+)\.(\w+)$/;
			$have{"$1_$2"} = ($3 eq 'none') ? 'none' : 'tile';
		}
		closedir $dh;
		display($dbg_analysis+1,1,"indexed $key (".scalar(keys %have)." entries)");
	}

	$cache->{$key} = \%have;
	return \%have;
}


#---------------------------------------------
# the analysis
#---------------------------------------------

sub analyseFetch
	# What these regions would cost.  Reads nothing but directories and
	# .rct headers, writes nothing, and never touches the network.
	#
	# opts: zmax     a cap applied exactly as a build applies one
	#       purpose  'build' (the default) or 'display' - which coherence
	#                question the faults are collected against
	#       config   the build configuration (for advisory rates)
	#       out_dir  a folder to survey for what is already in it
	#       format   which output this is for; only 'rct' has a chartset
	#
	# IT ANALYSES WHAT WOULD HAPPEN, INCLUDING NOTHING.  An incoherent tree
	# contributes no tiles and no time, and the reason is in {faults} for
	# whoever is going to show this.  It does not refuse - refusing is the
	# act's job and this is a pure read - but a preflight built on it can,
	# and does.
{
	my ($ids,$opts) = @_;
	$opts ||= {};
	my $t0 = time();

	my $cfg     = $opts->{config} || buildConfig();
	my $purpose = $opts->{purpose} || 'build';

	my $out = {
		regions		=> [],		# in the order given
		sources		=> {},		# id => counts and timing
		source_order=> [],
		totals		=> { total => 0, cached => 0, absent => 0, need => 0 },
		bytes		=> 0,
		secs_est	=> 0,
		est_known	=> 1,		# 0 if any source has no basis for an estimate
		# EVERY WAY A NODE FAILS TO RESOLVE, from dm_region::regionFaults,
		# reported against the nodes that named their own source.  This
		# replaced {missing_src}, which held only "an id that is not
		# installed" - one of the four - and could never be reached by the
		# commonest of them, a region that has chosen nothing, because the
		# fallback silently answered for those before this could see them.

		faults		=> [],
		displaced	=> [],		# sources that declare a displacement
		zagree		=> undef,	# set when the build would disagree with itself
		source_conflicts => undef,	# tiles two nodes would build from two sources
		geometry	=> [],		# regions whose polygons break a geometry rule
		overwrite	=> [],		# files in out_dir this build would replace
		foreign		=> [],		# files in out_dir NOT part of this build
		elapsed		=> 0,
	};

	my %index;					# the (source,zoom) directories read
	my %seen_src;

	# ACROSS THE WHOLE BUILD, not per region, because the case that matters
	# most is two REGIONS - they share their coarse parents by construction
	# and a mismatch there covers far more ground than one inside a region.

	my %tile_source;			# "z/x_y" => [ node path, source id ]
	my %source_conflict;		# "path + path" => { tiles, levels, sources }

	for my $id (@$ids)
	{
		my $reg = getRegion($id) or next;
		push @{$out->{faults}},@{regionFaults($reg,$purpose)};

		# THE GEOMETRY IT WAS NEVER ASKED ABOUT.  These rules are enforced
		# at the moment of an edit; a file that arrived from somewhere else
		# or predates a rule has never been through that door, and the load
		# path deliberately does not ask.  So the build does, once.

		my $geom = regionGeometryFault($reg);
		push @{$out->{geometry}},{ id => $id, why => $geom } if $geom;

		my $srcs = regionSourceMap($reg);
		my ($cov,$nodes) = regionCoverageNodes($reg,
			defined $opts->{zmax} ? { zmax => $opts->{zmax} } : {});

		my $rc = { id => $id, total => 0, cached => 0, absent => 0, need => 0,
				   zauthor => $reg->{zauthor}, zmin => $reg->{zmin},
				   sources => {} };

		for my $node (@$nodes)
		{
			# NO FALLBACK, AND NOTHING THAT WOULD BE REFUSED IS COUNTED.
			#
			# '' is a node that has chosen nothing and contributes no tiles,
			# because nothing would be fetched for it.  Neither does a node
			# whose source is installed but may not be BUILT from - and
			# that one is the trap: getSource() succeeds for a display-only
			# source, so testing only for installation put a refused
			# region's tiles into the totals directly underneath the line
			# saying it was not counted.
			#
			# The same predicate the faults were collected with, so the two
			# cannot disagree about which nodes are in.

			my $sid = $srcs->{$node->{path}};
			next if sourceState($sid,$purpose) ne $SRC_OK;
			my $src = getSource($sid);

			# WHICH TILES TWO NODES WOULD BUILD FROM TWO DIFFERENT SOURCES.
			#
			# Two nodes sharing a tile is ordinary and mostly harmless - a
			# tile is a square that two polygons can both clip without
			# touching each other, and adjacent regions share their coarse
			# parents BY CONSTRUCTION, which is what lets one .rct stand
			# alone on a card.  The whole fused design rests on those copies
			# being the same picture.
			#
			# WHEN THEY ARE NOT, NOBODY IS TOLD.  The E-Series takes the
			# first block that holds the tile, and the block array is filled
			# in the order the files sit in the card's directory; OpenCPN
			# picks by its own quilting rules.  So the imagery shown is
			# decided by something the author cannot see and did not choose,
			# and at coarse zoom the shared parents of two neighbouring
			# regions can be a wide band of ground rather than a seam.
			#
			# ASKED HERE because this loop has already resolved which source
			# every node would really be built from, including the ones a
			# fault excludes - so the answer costs a hash walk and no
			# geometry, and it is the same walk the totals come from.

			for my $z (keys %{$node->{levels}})
			{
				for my $key (keys %{$node->{levels}{$z}})
				{
					my $had = $tile_source{"$z/$key"};
					if (!$had) { $tile_source{"$z/$key"} = [$node->{path},$sid]; next }
					next if $had->[1] eq $sid;
					my $pair = join(' + ',sort($had->[0],$node->{path}));
					my $c = ($source_conflict{$pair} ||= { tiles => 0,
							 levels => {}, sources => {} });
					$c->{tiles}++;
					$c->{levels}{$z}++;
					$c->{sources}{$_} = 1 for ($had->[1],$sid);
				}
			}

			if (!$seen_src{$sid}++)
			{
				push @{$out->{source_order}},$sid;

				# DISPLACEMENT REACHES PREFLIGHT.  The source list shows it
				# to whoever goes looking; this carries it to the one moment
				# somebody is certainly looking, which is the dialog that
				# starts the run.  Collected here because this is where the
				# sources a build will actually use are resolved.

				push @{$out->{displaced}},
					{ id => $sid, name => $src->{name},
					  displacement => $src->{displacement} }
					if defined $src->{displacement};

				$out->{sources}{$sid} = {
					id => $sid, name => $src->{name},
					total => 0, cached => 0, absent => 0, need => 0,
					interval => effectiveInterval($src,$cfg),

					# BY cache_key, NOT BY SOURCE ID.  The observation
					# record shares the cache's key so that a user
					# has one name per source rather than two, which means
					# the source hash rather than the id is what identifies
					# it here.

					measured => obsMsPerTile($src),
					zooms => {},
				};
			}
			my $ss = $out->{sources}{$sid};

			for my $z (keys %{$node->{levels}})
			{
				my $have = _zoomIndex(\%index,$src,$z);
				my $zc = $ss->{zooms}{$z} ||=
					{ cached => 0, absent => 0, need => 0, keys => [] };

				for my $key (keys %{$node->{levels}{$z}})
				{
					my $st = $have->{$key};
					my $bucket = !defined($st) ? 'need' :
								 $st eq 'none' ? 'absent' : 'cached';
					$rc->{$_}++ for ('total',$bucket);
					$ss->{$_}++ for ('total',$bucket);
					$zc->{$bucket}++;
					$rc->{sources}{$sid}++;

					# THE SIZE SAMPLE COMES FROM THIS REGION'S OWN TILES.
					# Sampling the cache DIRECTORY instead was measurably
					# wrong - it holds every region's tiles at that zoom,
					# so a build was predicted at 165.8 MB and came out at
					# 67.7 MB.  These are the tiles actually being counted.
					push @{$zc->{keys}},$key if $bucket eq 'cached';
				}
			}
		}

		push @{$out->{regions}},$rc;
		$out->{totals}{$_} += $rc->{$_} for qw( total cached absent need );
		display($dbg_analysis,0,sprintf("%-14s %6d tiles  %6d to fetch",
			$id,$rc->{total},$rc->{need}));
	}

	# ---- the time estimate, per source and then summed
	#
	# A PACED SOURCE NEEDS NO MEASUREMENT.  Its declared interval is a
	# floor it will be held to, so the arithmetic is exact whether or not
	# this machine has ever talked to it.  An unpaced one is round trip
	# time and nothing else, which is unknowable until observed - and a
	# fabricated figure is worse than none, because people plan around it.

	for my $sid (@{$out->{source_order}})
	{
		my $ss = $out->{sources}{$sid};
		my $per = $ss->{interval} > $ss->{measured} ?
				  $ss->{interval} : $ss->{measured};

		if (!$per && $ss->{need})
		{
			$ss->{secs_est} = 0;
			$ss->{est_known} = 0;
			$out->{est_known} = 0;
			next;
		}
		$ss->{est_known} = 1;
		$ss->{secs_est}  = $ss->{need} * $per / 1000;
		$out->{secs_est} += $ss->{secs_est};
	}

	# ---- bytes, from what the cache has actually been holding

	$out->{bytes} = _estimateBytes($out,\%index);

	# ---- the build's own consistency, and what is already in the folder
	#
	# BOTH OF THESE ARE ABOUT .rct, and neither means anything about any
	# other output.  Agreement exists because the E-Series fuses every .rct
	# present into ONE pyramid and cuts the reveal aperture at the coarsest
	# zauthor among them; the folder survey reads .rct headers to find out
	# what else is in that folder.  An output whose files are independent
	# charts has no chartset to disagree with and no headers to read, so
	# asking would produce a warning about nothing - which is how a real
	# warning gets trained out of being read.

	# THE SOURCE CONFLICT IS NOT AN .rct QUESTION and sits outside the test
	# below for that reason.  Both formats put the same tile in two places
	# and neither can express a preference between them: the E-Series takes
	# the first block holding it, OpenCPN quilts by its own rules.  What
	# differs is only who does the arbitrating.

	$out->{source_conflicts} = %source_conflict ? \%source_conflict : undef;

	if (($opts->{format} || 'rct') eq 'rct')
	{
		$out->{zagree}    = _checkAgreement($out->{regions},$opts->{out_dir},$ids);
		($out->{overwrite},$out->{foreign}) =
			_surveyFolder($opts->{out_dir},$ids);
	}

	$out->{elapsed} = time() - $t0;
	return $out;
}


my $BYTES_SAMPLE = 40;
	# How many tiles to weigh per zoom.  Twenty is far more than enough for
	# a figure quoted to one decimal place in megabytes.

my $BYTES_GUESS = 18000;
	# What a tile weighs when there is not one cached to look at.


sub _estimateBytes
	# Total output size, from tiles actually on disk.
	#
	# BY SAMPLING, NOT BY WEIGHING THE WHOLE CACHE.  The obvious
	# implementation calls cacheStats, which walks every zoom of a source
	# and stats every file in it -- 36,000 syscalls on the real cache, and
	# MEASURED AT 3.5 SECONDS, which is thirty times the cost of the
	# analysis it was decorating.  A preflight that takes four seconds is a
	# preflight with a spinner in it, and the whole argument for reading
	# directories rather than probing tiles was that it need not be.
	#
	# PER ZOOM, because that is where the variation is: an ocean tile at
	# z10 and a detail tile at z18 differ by an order of magnitude, so one
	# blended average over a pyramid would be dominated by whichever level
	# happens to have the most files.
{
	my ($out,$index) = @_;
	my $bytes = 0;
	my %per_zoom;			# "cache_key/z" => average bytes

	for my $sid (@{$out->{source_order}})
	{
		my $ss = $out->{sources}{$sid};
		my $src = getSource($sid) or next;
		$ss->{bytes} = 0;

		for my $z (sort { $a <=> $b } keys %{$ss->{zooms} || {}})
		{
			my $zc = $ss->{zooms}{$z};
			my $want = ($zc->{cached} || 0) + ($zc->{need} || 0);
			next if !$want;

			my $key = "$src->{cache_key}/$z";
			if (!defined $per_zoom{$key})
			{
				# STRIDED ACROSS THE REGION'S OWN TILES, sorted first.
				#
				# Sorted for determinism: Perl's hash order is randomised
				# per process, so an unsorted sample makes the quoted
				# megabytes wobble between runs, which reads as a bug in a
				# number somebody is using to decide a zmax.
				#
				# Strided rather than taking the first N, because "x_y"
				# sorts by column: the first N are all the westernmost
				# strip of the region, which at a coast is all water and at
				# an island is all land.  A stride walks the whole extent.

				my @k = sort @{$zc->{keys}};
				my $dir = cacheDir()."/$src->{cache_key}/$z";
				my $step = int(scalar(@k) / $BYTES_SAMPLE) || 1;

				my ($n,$sum) = (0,0);
				for (my $i = 0; $i < @k && $n < $BYTES_SAMPLE; $i += $step)
				{
					my $sz = -s "$dir/$k[$i].$src->{tile_format}";
					$sz = -s "$dir/$k[$i].jpeg" if !$sz;
					$sz = -s "$dir/$k[$i].png"  if !$sz;
					next if !$sz;
					$sum += $sz;
					$n++;
				}
				$per_zoom{$key} = $n ? $sum / $n : 0;
			}

			my $per = $per_zoom{$key} || $BYTES_GUESS;
			$ss->{bytes} += int($per * $want);
		}

		$bytes += $ss->{bytes};
	}
	return $bytes;
}


sub _checkAgreement
	# EVERY .rct BUILT TOGETHER MUST AGREE on zauthor and zmin - the firmware
	# holds both on the CHARTSET, not per file: it fuses every .rct on the
	# them into one pyramid and indexes it as zdir[z - zmin].  The reveal
	# aperture is cut at the coarsest zauthor present, so a file whose zmin
	# is finer than that contributes no outline at all and its imagery is
	# drawn and permanently invisible.
	#
	# A WARNING RATHER THAN A REFUSAL, deliberately.  Trying a new zauthor
	# on one region before converting a whole chartset is a legitimate
	# thing to want, and a hard refusal makes it impossible.  So this
	# reports and the user decides.
	#
	# IT ASKS THE FOLDER AS WELL AS THE SET, which is the part a check
	# across the build alone would miss: building one region into a folder
	# of files built earlier is exactly when the disagreement appears, and
	# the regions being built may agree perfectly with each other.
{
	my ($regions,$out_dir,$ids) = @_;

	my (%zauthor,%zmin);
	for my $rc (@$regions)
	{
		push @{$zauthor{$rc->{zauthor}}},$rc->{id};
		push @{$zmin{$rc->{zmin}}},$rc->{id};
	}

	if ($out_dir)
	{
		my %building = map { lc($_) => 1 } @$ids;
		my $have = rctScanFolder($out_dir);
		for my $stem (sort keys %$have)
		{
			next if $building{$stem};		# about to be replaced
			my $info = $have->{$stem};
			push @{$zauthor{$info->{zauthor}}},"$info->{leaf} (on disk)";
			push @{$zmin{$info->{zoom_min}}},"$info->{leaf} (on disk)";
		}
	}

	return undef if keys(%zauthor) <= 1 && keys(%zmin) <= 1;

	return {
		zauthor => (keys(%zauthor) > 1 ? \%zauthor : undef),
		zmin	=> (keys(%zmin)    > 1 ? \%zmin    : undef),
	};
}


sub _surveyFolder
	# What is already in the output folder: the files this build would
	# REPLACE, and the files that would remain beside it without being
	# part of it.
	#
	# The second list is the one nobody asks for and it is the more
	# dangerous: a file left from an earlier set or a renamed region is
	# still read by the plotter, still contributes to the pyramid, and is
	# invisible in every other view.
{
	my ($out_dir,$ids) = @_;
	return ([],[]) if !$out_dir || !-d $out_dir;

	my %building = map { lc($_) => 1 } @$ids;
	my $have = rctScanFolder($out_dir);

	my (@over,@foreign);
	for my $stem (sort keys %$have)
	{
		push @{ $building{$stem} ? \@over : \@foreign },$have->{$stem};
	}
	return (\@over,\@foreign);
}


#---------------------------------------------
# rendering
#---------------------------------------------

sub analysisLines
	# The analysis as text, formatted once for the console and the dialog,
	# for the same reason the build report is.
{
	my ($an,$what) = @_;
	$what ||= 'build';
	my @out;

	push @out,sprintf("%d region(s), %s tiles",
		scalar(@{$an->{regions}}),_num($an->{totals}{total}));
	push @out,'';

	# WHAT IS NOT COUNTED, IN ONE LINE.  A zero against a region whose
	# source is not settled reads as "already cached" unless something says
	# otherwise, so the fact belongs here - but the FAULTS THEMSELVES DO
	# NOT.  They are a refusal, both surfaces already show one, and putting
	# them in the cost table as well printed the whole list twice in the
	# preflight dialog, one panel above the other.

	if (my $n = scalar(@{$an->{faults} || []}))
	{
		push @out,sprintf("%d region(s) cannot be built and are NOT counted below.",$n);
		push @out,'';
	}

	push @out,sprintf("  %-22s %9s %9s %9s","source","to fetch","cached","absent");
	for my $sid (@{$an->{source_order}})
	{
		my $ss = $an->{sources}{$sid};
		push @out,sprintf("  %-22s %9s %9s %9s",
			substr($sid,0,22),_num($ss->{need}),_num($ss->{cached}),
			_num($ss->{absent}));
	}

	push @out,'';
	push @out,sprintf("  %-22s %9s %9s %9s",'TOTAL',
		_num($an->{totals}{need}),_num($an->{totals}{cached}),
		_num($an->{totals}{absent}));

	push @out,'';
	if (!$an->{totals}{total} && @{$an->{faults} || []})
	{
		# NOTHING TO COUNT IS NOT THE SAME AS NOTHING TO DO.  A zero here
		# because every region was refused would otherwise read as
		# "everything is already cached", which is the most reassuring
		# possible way to report a set that cannot be built at all.

		push @out,"Nothing can be fetched until the regions below are settled.";
	}
	elsif (!$an->{totals}{need})
	{
		push @out,"Everything is already cached - nothing will be fetched.";
	}
	elsif ($an->{est_known})
	{
		push @out,sprintf("About %s to fetch %s tile(s).",
			_hms($an->{secs_est}),_num($an->{totals}{need}));
	}
	else
	{
		# NO FABRICATED NUMBER.  An estimate that is wrong by a factor of
		# three is worse than none, because it is planned around.

		push @out,sprintf("%s tile(s) to fetch. No time estimate yet - the ".
			"speed of",_num($an->{totals}{need}));
		push @out,"this source has not been measured on this machine. It ".
			"will be after this run.";
	}

	push @out,sprintf("The .rct file would be about %.1f MB.",$an->{bytes}/1048576)
		if $what eq 'build' && $an->{bytes};
	push @out,sprintf("The charts would be about %.1f MB.",$an->{bytes}/1048576)
		if $what eq 'mbtiles' && $an->{bytes};

	return \@out;
}


sub _num
{
	my ($n) = @_;
	$n = int($n || 0);
	1 while $n =~ s/^(\d+)(\d{3})/$1,$2/;
	return $n;
}


sub _hms
{
	my ($secs) = @_;
	$secs = int($secs + 0.5);
	return "${secs}s" if $secs < 60;
	return sprintf("%dm",int($secs/60)) if $secs < 3600;
	return sprintf("%dh %02dm",int($secs/3600),int(($secs%3600)/60));
}


1;
