#!/usr/bin/perl
#---------------------------------------------
# dm_clean.pm
#---------------------------------------------
# THE CACHE CLEANUP.  See docs/design/cleanup.md.
#
# A survey of what is on disk against what anything still wants, and the
# acts that follow from it.  Nothing here decides on its own that a tile
# should go: it reports, a person ticks, and then it does exactly what was
# ticked and says what it did.
#
# THE ROW IS THE cache_key, NOT THE TSD.  Tiles are keyed by cache_key and
# more than one .tsd may address the same one, so a table keyed by file
# would offer the same gigabytes twice and would have no row at all for a
# cache whose file is already gone.  A row therefore carries the FILES that
# address it, which may be none.
#
# FOUR THINGS ARE 'IN USE' AND ONLY THE FIRST IS OBVIOUS:
#
#	a region in any set names the source          - it will be built
#	a region in a set that is NOT open names it   - other sets count too
#	it is the default source                      - it is drawing the map
#	it ships with the application                 - a new install has it
#
# The second is the one a naive implementation gets wrong, because the
# model only ever holds the regions of the OPEN set; the third is the one
# that would otherwise offer to delete the imagery on screen.
#
# A SENTINEL SWEEP IS NOT A DELETE.  A source that answers "nothing here"
# with a 200 and a picture saying so gets that picture fingerprinted in its
# .tsd, and from then on dm_fetch records it as the absence it is.  Tiles
# cached BEFORE the fingerprint existed are still sitting there as imagery.
# Converting one to a '.none' marker frees the bytes and KEEPS the finding;
# deleting it would make the tile unknown again and the next pass would
# fetch it back.  dm_fetch already does this lazily on the way out of the
# cache - this is the same rule applied to a whole tree at once, through
# the same fetchDeclaredAbsent, because two implementations of "are these
# bytes a tile" is a bug this application has already had.
#
# A TRIM KEEPS THE MARKERS.  Removing images outside every region is the
# rendering cache going away, which is fine - it is a browse, and browsing
# it again refetches it.  The '.none' markers are not that: they are the
# accumulated knowledge of where a service has nothing, they cost a request
# each to learn, and they are nine bytes.  Trimming them would spend real
# bandwidth to free nothing.
#
# AND A TRIM REFUSES AN EMPTY KEEP SET.  If no region anywhere uses a
# source, everything in its cache is "outside every region" and the trim
# becomes a silent delete-all wearing the wrong name.  That is a legitimate
# thing to want and it is what the cache column is for, so this says so
# rather than doing it.
#
# THREADS.  cleanAct runs on a worker with the shared progress record and
# obeys {cancelled}; the survey can run there too and publishes its rows
# into the record as flat shared hashes - see cleanSurvey.  No wx anywhere.

package dm_clean;
use strict;
use warnings;
use threads;
use threads::shared;
use Digest::MD5 qw( md5_hex );
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_set;
use dm_source;
use dm_region;
use dm_coverage;
use dm_cache;
use dm_fetch;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		cleanShippedLeaves
		cleanSourceUsage
		cleanSurvey
		cleanSurveyLines
		cleanAct
		cleanReportLines
	);
}


our $dbg_clean:shared = 0;
	#  0 = the survey summary and each act
	# -1 = one line per row
	# -2 = one line per file removed


my $CANCEL_EVERY = 256;
	# How often the walk asks whether it has been cancelled.  A shared read
	# per file over a hundred thousand files is a cost for nothing; a
	# quarter of a second of delay before a Cancel takes hold is not.


#---------------------------------------------
# what is in use
#---------------------------------------------

sub cleanShippedLeaves
	# The .tsd files that ship with the application, by leaf.
	#
	# READ FROM _res/user_data RATHER THAN LISTED HERE, because the
	# installer copies that folder into the user's data dir and a list in
	# code would be a second answer to "what ships" that nobody would think
	# to update when a fifth source was added.
	#
	# A shipped source is not protected - it is a normal file the user may
	# delete - but it is never swept up by "check all unused", because a
	# first run has used none of them and the sweep would empty a new
	# install in one click.
{
	my %shipped;
	my $dir = "$app_dir/_res/user_data";
	my $dh;
	return \%shipped if !-d $dir || !opendir($dh,$dir);
	$shipped{$_} = 1 for grep { /\.tsd$/i } readdir($dh);
	closedir $dh;
	return \%shipped;
}


sub _setRegions
	# The regions of one set: from the MODEL if that set is the open
	# document, and from the folder otherwise.
	#
	# THE OPEN SET IS READ FROM MEMORY ON PURPOSE.  A region drawn and not
	# yet saved is a region the user can see, and answering "nothing needs
	# these tiles" from a file that predates it would delete the tiles for
	# the thing on screen.  What you can see is what is kept.
{
	my ($set) = @_;

	if (setIsOpen() && lc(openSetName()) eq lc($set))
	{
		my @regs = grep { $_ } map { getRegion($_) } getRegionIds();
		return \@regs;
	}

	my $dir = setDir($set);
	my $dh;
	return [] if !$dir || !-d $dir || !opendir($dh,$dir);
	my @leaves = sort grep { /\.region$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	my @regs = grep { $_ } map { readRegionFile("$dir/$_",$_) } @leaves;
	return \@regs;
}


sub cleanSourceUsage
	# source id => [ 'Set/Region', 'Set/Region/Subregion', ... ]
	#
	# EVERY SET, not the open one, and the paths carry the set name because
	# two sets may each hold a region called Bocas and they are not the same
	# region.
{
	my $fallback = getDefaultSource();
	my %usage;

	for my $set (getSetNames())
	{
		for my $reg (@{_setRegions($set)})
		{
			# regionSourceMap follows 'inherited' downward and terminates at
			# $fallback, so one pass answers for every node.  It lives on the
			# model because the filler and the preview read the same answer;
			# this is the third caller and must not be a fourth rulebook.

			my $map = regionSourceMap($reg,$fallback);
			for my $path (sort keys %$map)
			{
				push @{$usage{$map->{$path}}},"$set/$path";
			}
		}
	}

	display($dbg_clean,0,"cleanSourceUsage() ".scalar(keys %usage).
		" source(s) in use across ".scalar(getSetNames())." set(s)");
	return \%usage;
}


sub _keepSets
	# cache_key => { "z/x_y" => 1 } for every tile some region wants.
	#
	# BY SET AND THEN FOLDED, never merged across sets.  mergedCoverageSources
	# resolves innermost-wins WITHIN a working set, which is the rule for
	# overlapping regions of one chartset; run across two sets at once it
	# would let one set's source claim a tile the other set builds from a
	# different source, and the loser's tiles would then look unwanted.
	#
	# The merged map for a set is dropped as soon as it has been folded in,
	# so what is held at the peak is the answer plus one set - not every
	# set at once.
{
	my ($want) = @_;			# { cache_key => 1 } - only these are asked about
	my $fallback = getDefaultSource();

	my %id2key;
	for my $id (getSourceIds())
	{
		my $src = getSource($id);
		$id2key{$id} = $src->{cache_key} if $src;
	}

	my %keep;
	for my $set (getSetNames())
	{
		my $regs = _setRegions($set);
		next if !@$regs;

		my $merged = mergedCoverageSources($regs,$fallback);
		for my $z (keys %$merged)
		{
			my $level = $merged->{$z};
			for my $xy (keys %$level)
			{
				my $key = $id2key{$level->{$xy}};
				next if !defined($key) || !$want->{$key};
				$keep{$key}{"$z/$xy"} = 1;
			}
		}
		undef $merged;
	}

	for my $key (sort keys %keep)
	{
		display($dbg_clean+1,1,"keep ".scalar(keys %{$keep{$key}})." tile(s) for '$key'");
	}
	return \%keep;
}


#---------------------------------------------
# the survey
#---------------------------------------------

sub _rows
	# One row per cache_key, from the .tsd files and from the disk, before
	# anything has been counted.
{
	my %by_file;
	for my $id (getSourceIds())
	{
		my $src = getSource($id);
		$by_file{$src->{file}} = $src if $src && $src->{file};
	}

	my $shipped = cleanShippedLeaves();
	my $usage   = cleanSourceUsage();
	my $default = getDefaultSource() // '';

	my %rows;
	my $order = 0;

	for my $leaf (getSourceFiles())
	{
		# A REFUSED FILE STILL GETS A ROW, and it is the one most likely to
		# want deleting - it is broken, and until it is fixed or gone the
		# id it declares resolves to nothing.  Its cache_key comes from the
		# raw JSON, falling back to the same leaf-stem default dm_source
		# applies, so a refused file lands on the row holding its tiles.

		my $src = $by_file{$leaf};
		my ($key,$id,$refused);

		if ($src)
		{
			$key = $src->{cache_key};
			$id  = $src->{id};
		}
		else
		{
			$refused = 1;
			my $raw = readSourceFile($leaf) || {};
			$id  = $raw->{id};
			$id  = '' if !defined($id) || ref($id);
			$key = $raw->{cache_key};
			if (!defined($key) || ref($key) || $key !~ /^[a-z0-9_-]+$/)
			{
				$key = lc($leaf);
				$key =~ s/\.tsd$//i;
			}
		}

		my $row = $rows{$key} ||= _newRow($key,$order++);
		push @{$row->{leaves}},$leaf;
		push @{$row->{ids}},$id if defined($id) && $id ne '';

		$row->{refused}++		if $refused;
		$row->{shipped} = 1		if $shipped->{$leaf};
		$row->{display} = 1		if defined($id) && $id ne '' && $id eq $default;
		push @{$row->{used_by}},@{$usage->{$id} || []} if defined($id) && $id ne '';
	}

	# AND THE ORPHANS, which are the point of asking the disk at all: a
	# folder of tiles that no .tsd addresses any more.  Renaming a
	# cache_key makes one, and so does deleting a source the way this
	# application has always deleted one.

	for my $key (cacheKeysOnDisk())
	{
		next if $rows{$key};
		my $row = $rows{$key} = _newRow($key,$order++);
		$row->{orphan} = 1;
	}

	return [ sort { $a->{order} <=> $b->{order} } values %rows ];
}


sub _newRow
{
	my ($key,$order) = @_;
	return {
		key			=> $key,
		order		=> $order,
		leaves		=> [],
		ids			=> [],
		used_by		=> [],
		orphan		=> 0,
		refused		=> 0,
		shipped		=> 0,
		display		=> 0,
		tiles		=> 0,
		misses		=> 0,
		bytes		=> 0,
		sent_tiles	=> 0,
		sent_bytes	=> 0,
		trim_tiles	=> 0,
		trim_bytes	=> 0,
		trim_all	=> 0,
	};
}


sub _fingerprintSizes
	# The byte lengths this source declares, as a hash.  LENGTH FIRST is
	# the whole reason a sweep over a big cache is affordable: a digest is
	# computed only for a file whose size already matches, which for most
	# sources is no files at all.
{
	my ($src) = @_;
	my %sizes;
	return \%sizes if !$src || !$src->{absent_fingerprints};
	$sizes{$_->{bytes}} = 1 for @{$src->{absent_fingerprints}};
	return \%sizes;
}


sub _readBytes
{
	my ($path) = @_;
	my $fh;
	return undef if !open($fh,'<',$path);
	binmode $fh;
	local $/;
	my $data = <$fh>;
	close $fh;
	return \$data;
}


sub cleanSurvey
	# What is on disk, per cache_key, and what of it nothing wants.
	#
	# opts:
	#	progress	the shared record - counters, {cancelled}, and {rows}
	#	trim		compute the outside-every-region counts (the costly half)
	#	keys		only these cache_keys (the one-row case)
	#
	# Returns the rows as ordinary perl.  When a progress record is given
	# they are ALSO published into it as flat shared hashes, because that
	# is the only way a survey run on a worker can reach the dialog that
	# asked for it.  Flat is what makes that safe and honest: every value
	# is a scalar, the lists are joined, and there is no nested structure
	# being quietly re-represented.
{
	my ($opts) = @_;
	$opts ||= {};
	my $prog = $opts->{progress};

	my $rows = _rows();
	if ($opts->{keys})
	{
		my %want = map { $_ => 1 } @{$opts->{keys}};
		$rows = [ grep { $want{$_->{key}} } @$rows ];
	}

	# The keep sets are computed ONCE for every row about to be walked, not
	# per row, because a set's coverage answers for every source at once.

	my $keep = {};
	if ($opts->{trim})
	{
		if ($prog)
		{
			$prog->{phase} = 'Reading the regions of every set';
			$prog->{label} = '';
		}
		$keep = _keepSets({ map { $_->{key} => 1 } @$rows });
	}

	if ($prog)
	{
		$prog->{phase} = 'Surveying the cache';
		$prog->{total} = scalar(@$rows);
		$prog->{done}  = 0;
	}

	my $n = 0;
	for my $row (@$rows)
	{
		last if progressCancelled($prog);

		my $key = $row->{key};
		my $src = _rowSource($row);
		my $sizes = _fingerprintSizes($src);
		my $mine  = $keep->{$key};

		# A KEEP SET THAT IS EMPTY IS RECORDED, NOT ACTED ON.  Everything
		# here would be 'outside every region' and the trim would become a
		# delete-all; the row says so and the act refuses it.

		$row->{trim_all} = ($opts->{trim} && !$mine) ? 1 : 0;

		if ($prog)
		{
			$prog->{label}     = $key;
			$prog->{sub_done}  = 0;
			$prog->{sub_total} = cacheCount($key);
			$prog->{sub_label} = '';
		}

		my $seen = 0;
		cacheWalk($key,sub {
			my ($z,$x,$y,$ext,$path,$size) = @_;

			$seen++;
			if ($prog && !($seen % 64))
			{
				$prog->{sub_done} = $seen;
			}

			if ($ext eq 'none')
			{
				$row->{misses}++;
				return;
			}

			$row->{tiles}++;
			$row->{bytes} += $size;

			# A DECLARED BLANK IS CLASSIFIED FIRST and is then not also
			# counted as trimmable, because the two acts do different
			# things to it and only one of them will happen.

			if ($sizes->{$size})
			{
				my $bytes = _readBytes($path);
				if ($bytes && fetchDeclaredAbsent($src,$bytes))
				{
					$row->{sent_tiles}++;
					$row->{sent_bytes} += $size;
					return;
				}
			}

			if ($mine && !$mine->{"$z/${x}_${y}"})
			{
				$row->{trim_tiles}++;
				$row->{trim_bytes} += $size;
			}
		});

		$n++;
		if ($prog)
		{
			$prog->{sub_done} = $seen;
			$prog->{done}     = $n;
		}

		display($dbg_clean+1,1,sprintf("%-20s %6d tiles %6d absent %10s",
			$key,$row->{tiles},$row->{misses},prettyBytes($row->{bytes})));
	}

	display($dbg_clean,0,"cleanSurvey() ".scalar(@$rows)." row(s)");

	_publishRows($prog,$rows) if $prog;
	return $rows;
}


sub _rowSource
	# The loaded source a row's tiles are fetched through, or undef for an
	# orphan or a row whose only files are refused.  Any of the row's
	# sources will do: they share a cache_key, which dm_source only permits
	# when their urls are identical.
{
	my ($row) = @_;
	for my $id (@{$row->{ids}})
	{
		my $src = getSource($id);
		return $src if $src;
	}
	return undef;
}


sub _publishRows
	# The rows into the shared record, flattened.  See cleanSurvey.
{
	my ($prog,$rows) = @_;
	my $out = &threads::shared::share([]);

	for my $row (@$rows)
	{
		my $rec = &threads::shared::share({});
		$rec->{$_} = $row->{$_} + 0 for qw(
			orphan refused shipped display tiles misses bytes
			sent_tiles sent_bytes trim_tiles trim_bytes trim_all );
		$rec->{key}     = $row->{key};
		$rec->{leaves}  = join(' ',@{$row->{leaves}});
		$rec->{ids}     = join(' ',@{$row->{ids}});
		$rec->{used_by} = join(', ',@{$row->{used_by}});
		push @$out,$rec;
	}

	$prog->{rows} = $out;
}


sub cleanSurveyLines
	# The survey as text, for the console and for anything that wants to
	# read a survey without a dialog.
{
	my ($rows) = @_;
	my @lines;

	push @lines,sprintf("%-20s %-28s %7s %7s %10s  %s",
		'cache_key','files','tiles','absent','size','used by');

	my ($tiles,$bytes) = (0,0);
	for my $row (@$rows)
	{
		my $files = join(' ',@{$row->{leaves}});
		$files = '(none)' if !$files;
		$files .= ' [default]' if $row->{shipped};

		push @lines,sprintf("%-20s %-28s %7d %7d %10s  %s",
			$row->{key},$files,$row->{tiles},$row->{misses},
			prettyBytes($row->{bytes}),
			join(', ',@{$row->{used_by}}) || ($row->{display} ? 'the map' : '-'));

		$tiles += $row->{tiles};
		$bytes += $row->{bytes};

		push @lines,sprintf("%-20s   %d blank(s) to reclassify, %s",
			'',$row->{sent_tiles},prettyBytes($row->{sent_bytes}))
			if $row->{sent_tiles};
		push @lines,sprintf("%-20s   %d tile(s) outside every region, %s",
			'',$row->{trim_tiles},prettyBytes($row->{trim_tiles} ? $row->{trim_bytes} : 0))
			if $row->{trim_tiles};
	}

	push @lines,'';
	push @lines,sprintf("%d row(s), %d tiles, %s",
		scalar(@$rows),$tiles,prettyBytes($bytes));
	return \@lines;
}


#---------------------------------------------
# the act
#---------------------------------------------

sub _newReport
{
	return {
		ok			=> 1,
		cancelled	=> 0,
		errors		=> 0,
		keys_removed	=> 0,
		files_removed	=> 0,
		bytes_removed	=> 0,
		sent_tiles	=> 0,
		sent_bytes	=> 0,
		trim_tiles	=> 0,
		trim_bytes	=> 0,
		none_asked	=> 0,
		none_cleared	=> 0,
		none_kept	=> 0,
		none_lost	=> 0,
		tsds		=> [],
		refused		=> [],
	};
}


sub cleanAct
	# Do exactly what was ticked.  Runs on a worker; obeys {cancelled}.
	#
	# $ids  the cache_keys to visit, in the order the table listed them
	# opts:
	#	sentinels	reclassify declared blanks in every key visited
	#	trim		remove images outside every region
	#	del_cache	{ cache_key => 1 } - the whole tree goes
	#	del_tsd		{ leaf => 1 }      - the definition goes
	#
	# THE CACHE FIRST AND THE FILES LAST.  Reclassifying a blank needs the
	# source that declares the fingerprint, so deleting the .tsd first
	# would silently turn a sweep into a no-op on exactly the sources being
	# tidied up.
{
	my ($prog,$ids,$opts) = @_;
	$opts ||= {};
	my $report = _newReport();

	my $del_cache = $opts->{del_cache} || {};
	my $del_tsd   = $opts->{del_tsd}   || {};

	# The keep sets, once, and only if a trim was asked for.  Rows whose
	# cache is about to be deleted outright are not asked about.

	my $keep = {};
	if ($opts->{trim})
	{
		if ($prog)
		{
			$prog->{phase} = 'Reading the regions of every set';
			$prog->{label} = '';
		}
		$keep = _keepSets({ map { $_ => 1 } grep { !$del_cache->{$_} } @$ids });
	}

	if ($prog)
	{
		$prog->{phase} = 'Cleaning';
		$prog->{total} = scalar(@$ids);
		$prog->{done}  = 0;
	}

	my $n = 0;
	for my $key (@$ids)
	{
		if (progressCancelled($prog))
		{
			$report->{cancelled} = 1;
			last;
		}

		if ($prog)
		{
			$prog->{label}     = $key;
			$prog->{sub_done}  = 0;
			$prog->{sub_total} = 0;
			$prog->{sub_label} = '';
		}

		if ($del_cache->{$key})
		{
			$prog->{sub_label} = "removing every tile of '$key'" if $prog;
			my ($files,$bytes,$errors) = cacheRemoveKey($key);
			$report->{files_removed} += $files;
			$report->{bytes_removed} += $bytes;
			$report->{errors}        += $errors;
			$report->{keys_removed}++;
		}
		else
		{
			# RE-AFFIRM FIRST.  It removes markers and may cache tiles, so
			# running it after the blank sweep would re-ask every marker that
			# sweep had just written - two requests to arrive back where the
			# tick started.

			_reaffirmKey($prog,$report,$key,_keySource($key))
				if $opts->{reaffirm};

			_sweepKey($prog,$report,$key,$keep->{$key},$opts);
		}

		$n++;
		$prog->{done} = $n if $prog;
	}

	# THE DEFINITIONS, LAST.  A cancel stops the tile work and still does
	# these: they are one unlink each, the user asked for them, and leaving
	# a half-answered dialog behind is worse than finishing the cheap half.

	for my $leaf (sort keys %$del_tsd)
	{
		my $err = deleteSourceFile($leaf);
		if ($err)
		{
			push @{$report->{refused}},$err;
			$report->{errors}++;
			next;
		}
		push @{$report->{tsds}},$leaf;
	}
	rescanSources() if @{$report->{tsds}};

	$report->{ok} = $report->{errors} ? 0 : 1;
	display($dbg_clean,0,"cleanAct() removed $report->{files_removed} file(s), ".
		"reclassified $report->{sent_tiles}, trimmed $report->{trim_tiles}, ".
		"re-asked $report->{none_asked} absence(s) - ".
		"$report->{none_cleared} were wrong, $report->{none_kept} confirmed, ".
		"$report->{none_lost} unreachable");
	return $report;
}


sub _keySource
	# The loaded source that addresses one cache_key, or undef.  Any of them
	# will do: dm_source only permits two files to share a cache_key when
	# their urls are identical.
{
	my ($key) = @_;
	for my $id (getSourceIds())
	{
		my $s = getSource($id);
		return $s if $s && $s->{cache_key} eq $key;
	}
	return undef;
}


sub _reaffirmKey
	# RE-ASK EVERY RECORDED ABSENCE FOR ONE SOURCE, and keep whatever comes
	# back.  The only act in this file that touches the network.
	#
	# IT EXISTS BECAUSE AN ABSENCE IS CACHED AND NOTHING EXPIRES IT.  A
	# service that refused once - a blink, a shed load under a burst of
	# viewport requests - leaves a hole that no later look ever asks about
	# again.  Measured on IGN France: 3 of 64 markers were false.
	#
	# AND IT IS NOT 'FORGET THE ABSENCES', which was the other way to fix
	# the same 3.  The other 61 were true, they cost a request each to
	# learn, and throwing them away would buy them again on the next look.
	# Re-asking keeps what was right and corrects what was wrong.
	#
	# THE MARKER IS REMOVED AND THE TILE IS THEN ASKED FOR NORMALLY, rather
	# than through a private path that would re-decide what an absence
	# means.  getTile is cache-first, so the marker has to go before
	# anything will look; after that every rule in the fetcher applies
	# unchanged - the engine's pacing, the confirm-retry on a refusal, the
	# declared fingerprints, and the cache write.  A tile that is still
	# missing gets its new marker from the same code that wrote the first.
	#
	# AN ERROR LEAVES NOTHING BEHIND, and that is the honest outcome rather
	# than a hole: the source could not be reached, so what we knew is now
	# unknown rather than wrong, and the next look asks again.
	#
	# EVERY COORDINATE IS COLLECTED BEFORE ANY OF THEM IS ASKED, because the
	# walk is over the very directories this is about to write into.
{
	my ($prog,$report,$key,$src) = @_;

	if (!$src)
	{
		push @{$report->{refused}},
			"'$key' - no loaded source addresses this cache, so its ".
			"recorded absences cannot be re-asked";
		return;
	}

	my @marks;
	cacheWalk($key,sub {
		my ($z,$x,$y,$ext,$path,$size) = @_;
		push @marks,[$z,$x,$y,$path] if $ext eq 'none';
	});
	return if !@marks;

	if ($prog)
	{
		$prog->{sub_total} = scalar(@marks);
		$prog->{sub_done}  = 0;
	}

	my $n = 0;
	for my $mark (@marks)
	{
		my ($z,$x,$y,$path) = @$mark;

		if (progressCancelled($prog))
		{
			$report->{cancelled} = 1;
			last;
		}

		$prog->{sub_label} = "re-asking $z/$x/$y" if $prog;

		next if !cacheRemoveFile($path);

		my $result = getTile($src,$z,$x,$y,{ priority => 'bulk' });
		$report->{none_asked}++;

		if    ($result->{status} eq 'ok')     { $report->{none_cleared}++ }
		elsif ($result->{status} eq 'absent') { $report->{none_kept}++    }
		else                                  { $report->{none_lost}++    }

		$n++;
		$prog->{sub_done} = $n if $prog;
	}
}


sub _sweepKey
	# The two per-tile acts, in ONE walk of the tree.
{
	my ($prog,$report,$key,$mine,$opts) = @_;

	my $do_sent = $opts->{sentinels} ? 1 : 0;
	my $do_trim = $opts->{trim}      ? 1 : 0;
	return if !$do_sent && !$do_trim;

	# THE REFUSAL, and it is the whole reason a trim can be offered at all.
	# No keep set means no region anywhere uses this source, so every tile
	# is 'outside every region' and the trim would empty the folder under a
	# name that does not say so.

	if ($do_trim && !$mine)
	{
		push @{$report->{refused}},
			"'$key' - no region in any set uses it, so a trim would remove ".
			"all of it; delete the cache instead if that is what you mean";
		$do_trim = 0;
	}

	my $src   = _keySource($key);
	my $sizes = _fingerprintSizes($src);
	$do_sent = 0 if !$src || !keys %$sizes;
	return if !$do_sent && !$do_trim;

	$prog->{sub_total} = cacheCount($key) if $prog;

	my $seen      = 0;
	my $cancelled = 0;

	cacheWalk($key,sub {
		my ($z,$x,$y,$ext,$path,$size) = @_;
		return if $cancelled;
		return if $ext eq 'none';

		$seen++;
		if ($prog && !($seen % 64))
		{
			$prog->{sub_done} = $seen;
		}
		if (!($seen % $CANCEL_EVERY) && progressCancelled($prog))
		{
			$cancelled = 1;
			$report->{cancelled} = 1;
			return;
		}

		if ($do_sent && $sizes->{$size})
		{
			my $bytes = _readBytes($path);
			if ($bytes && fetchDeclaredAbsent($src,$bytes))
			{
				# THE ONE WRITER OF A MARKER, and it removes the image
				# itself - a .none beside a .jpeg is a file nothing would
				# ever read.  See dm_cache::cachePutMiss.

				if (cachePutMiss($src,$z,$x,$y,1))
				{
					$report->{sent_tiles}++;
					$report->{sent_bytes} += $size;
				}
				else
				{
					$report->{errors}++;
				}
				return;
			}
		}

		if ($do_trim && !$mine->{"$z/${x}_${y}"})
		{
			if (cacheRemoveFile($path))
			{
				$report->{trim_tiles}++;
				$report->{trim_bytes} += $size;
				$report->{files_removed}++;
				$report->{bytes_removed} += $size;
			}
			else
			{
				$report->{errors}++;
			}
		}
	});

	$prog->{sub_done} = $seen if $prog;
}


sub cleanReportLines
	# What it did, in the shape w_report and the console both read.
{
	my ($report) = @_;
	my @lines;

	push @lines,$report->{cancelled} ? 'Stopped.' : 'Finished.';
	push @lines,'';

	push @lines,sprintf("  %-26s %d",'caches removed',$report->{keys_removed})
		if $report->{keys_removed};
	push @lines,sprintf("  %-26s %d",'blanks reclassified',$report->{sent_tiles})
		if $report->{sent_tiles};
	push @lines,sprintf("  %-26s %d",'tiles trimmed',$report->{trim_tiles})
		if $report->{trim_tiles};

	# THE RE-ASK IS THREE NUMBERS, NOT ONE, because they mean different
	# things to the person reading them.  'Cleared' is what was wrong and is
	# now fixed; 'confirmed' is what was right and cost a request to prove;
	# 'unreachable' is what is now unknown rather than either, and will be
	# asked again by whoever looks next.

	if ($report->{none_asked})
	{
		push @lines,sprintf("  %-26s %d",'absences re-asked',$report->{none_asked});
		push @lines,sprintf("  %-26s %d",'  were wrong, now cleared',
			$report->{none_cleared});
		push @lines,sprintf("  %-26s %d",'  confirmed still missing',
			$report->{none_kept});
		push @lines,sprintf("  %-26s %d",'  could not be reached',
			$report->{none_lost})
			if $report->{none_lost};
	}
	push @lines,sprintf("  %-26s %d",'files removed',$report->{files_removed});
	push @lines,sprintf("  %-26s %s",'space freed',
		prettyBytes($report->{bytes_removed} + $report->{sent_bytes}));

	if (@{$report->{tsds}})
	{
		push @lines,'';
		push @lines,"Sources deleted:";
		push @lines,"  $_" for @{$report->{tsds}};
	}

	# WHAT IT DECLINED TO DO, and never silently.  A cleanup that reported
	# only what it removed would read as complete when it had refused half
	# of what was ticked.

	if (@{$report->{refused}})
	{
		push @lines,'';
		push @lines,"Not done:";
		push @lines,"  $_" for @{$report->{refused}};
	}

	if ($report->{errors})
	{
		push @lines,'';
		push @lines,"$report->{errors} file(s) could not be removed - see the log.";
	}

	# THE MARKERS ARE STILL THERE, and saying so is the difference between
	# a number that looks wrong and one that is explained.  Somebody who
	# trimmed a cache and then saw thousands of files left in the folder
	# would reasonably conclude the trim had failed.

	push @lines,'';
	push @lines,"Absence markers were kept: they are what stops a rebuild",
		"asking a service for ground it has already said it does not have."
		if $report->{trim_tiles};

	return \@lines;
}


1;
