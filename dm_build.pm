#!/usr/bin/perl
#---------------------------------------------
# dm_build.pm
#---------------------------------------------
# THE BUILD ACT.  One region set in, one folder of output out.
#
# It owns the sequencing, the guards and the ledger.  It owns neither the
# fetch loop nor the exporter -- dm_fill, dm_rct and dm_mbtiles are called
# from here and know nothing about each other.
#
#	VALIDATE   fast, before anything expensive      -> may refuse
#	FILL       ask for every tile in coverage       -> builds the LEDGER
#	--------   the refusal point   ------------------
#	EXPORT     per region, temp + rename            -> short
#
# ONE ACT, SEVERAL FORMATS.  What an output format changes is four guards
# and the write call, and those are declared in %FORMATS below rather than
# branched on at each site -- see the note there.  The expensive middle is
# format-blind, which is why a set already built to one format builds to
# the other for nothing.
#
# THE ORDER IS THE POINT.  Everything that can refuse a build refuses
# before the long phase, except the one thing that cannot be known until
# the long phase has run -- whether any tile failed.  A build that dies
# four regions in on something knowable at the start has already spent the
# expensive part.
#
# FETCH IS PART OF BUILD, and that is what makes the refusal honest.  The
# fill walks the same enumerator the exporter walks and asks getTile for
# every tile in it, cache first.  So a tile that is still missing at
# export time was never merely un-asked-for: it was asked for and the
# request failed.  Previously browsed tiles make this FASTER and are never
# what makes it CORRECT -- a build does not depend on anybody having
# looked at the region first.
#
# WHY IT IS NOT A LONGER _buildCommand.  A long-running act with state, a
# cancel flag and two drivers -- the menu and the console -- is not a
# command-table entry.  em_command is a vocabulary; this is a thing that
# happens.  Keeping it here is also what lets the whole build be tested
# with no wx anywhere in the process.
#
# THE FORMAT TOLERATES A HOLE BECAUSE IT MUST; that is not a quality
# standard.  An .rct sets a miss bit for any tile it lacks and the plotter
# magnifies an ancestor, so a file with holes reports success, looks soft
# rather than broken, and is discovered offshore.  The exporter cannot
# refuse this -- absence is how the format expresses a legitimate edge of
# coverage.  The build can, because the build holds the ledger.

package dm_build;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( time );
use Pub::Utils;
use cm_defs;
use cm_utils;
use cm_prefs;
use dm_source;
use dm_set;
use dm_region;
use dm_coverage;
use dm_fill;
use dm_rct;
use dm_mbtiles;
use dm_image;
use dm_observe;
use dm_analysis;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		buildRct
		buildMbtiles
		buildOutput
		buildFormats
		buildReportLines
	);
}


our $dbg_build:shared = 0;
	# 0  = the phases and one line per region
	# -1 = the guards as they pass


#---------------------------------------------
# the output formats
#---------------------------------------------
# WHAT DIFFERS BETWEEN EXPORTERS, AND NOTHING ELSE.  The act is one act:
# validate, fill, refuse or export.  Which container the tiles land in
# changes four of the guards and the write call, and if that had been said
# with an if-statement at each of those five places then adding a third
# output would mean finding all five again -- and the one that got missed
# would be a guard silently not running.
#
# So each format states its own answers here and the act reads them.  A
# format that cannot answer one of these questions has no business being
# an output of this build.
#
# EVERY FIELD EARNS ITS PLACE by a real difference:
#
#   carry / formats  RCT is JPEG only; MBTiles holds JPEG or PNG.
#   can_convert      what an output can TAKE IN but not hold.  An RCT
#                    re-encodes a png on the way in; an mbtiles never
#                    converts anything, because it holds both already and
#                    its metadata names one format for the whole file.
#   last_error       why the last write failed.  An exporter answers with
#                    undef, and undef is not something a person can read.
#   uniform          the E80 fuses every .rct on a card into ONE pyramid
#                    and cuts the reveal aperture at the coarsest zauthor
#                    present, so the files must agree.  MBTiles files are
#                    independent charts and there is nothing to agree on.
#   check_name       an .rct stem is 8.3; an mbtiles path is not.
#   base_dir         they are different folders, and mixing a tree of
#                    region folders in among the .rct files would make the
#                    output directory something a user has to read
#                    carefully rather than copy wholesale.
#   write / discard  one writes a file, the other a folder of them, so
#                    "take that back" is not the same call either.

my %FORMATS;

sub _initFormats
{
	%FORMATS = (
	rct => {
		id			=> 'rct',
		label		=> 'an RCT',
		holds		=> 'RCT holds',
		noun		=> '.rct file',
		unit		=> 'blk',
		blank		=> 'the file would be structurally valid and blank '.
					   'on the plotter',
		uniform		=> 1,
		formats		=> \&rctFormats,
		can_carry	=> \&rctCanCarry,
		can_convert	=> \&rctCanConvert,
		last_error	=> \&rctLastError,
		check_name	=> \&rctFileName,
		name_help	=> 'at most 8 characters, letters and digits only',
		base_dir	=> \&rasterDir,
		base_help	=> 'set RASTER_DIR in Preferences, or create it',
		write		=> sub {
			my ($reg,$srcs,$out_dir,$opts) = @_;
			return writeRct($reg,$srcs,
				"$out_dir/".rctFileName($reg->{id}),$opts);
		},
		discard		=> sub {
			my ($st) = @_;
			unlink($st->{path});
		},
	},
	mbtiles => {
		id			=> 'mbtiles',
		label		=> 'an mbtiles',
		holds		=> 'MBTiles holds',
		noun		=> 'chart folder',
		unit		=> 'file',
		blank		=> 'the metadata would describe the tiles wrongly',
		uniform		=> 0,
		formats		=> \&mbtilesFormats,
		can_carry	=> \&mbtilesCanCarry,
		can_convert	=> sub { return 0 },
		last_error	=> \&mbtilesLastError,
		check_name	=> \&mbtilesNodeName,
		name_help	=> 'letters and digits only',
		base_dir	=> \&mbtilesDir,
		base_help	=> 'set MBTILES_DIR in Preferences, or create it',
		write		=> sub {
			my ($reg,$srcs,$out_dir,$opts) = @_;
			return writeMbtiles($reg,$srcs,"$out_dir/$reg->{id}",$opts);
		},
		discard		=> sub {
			my ($st) = @_;

			# The FILES, not the folder.  Removing what this build just
			# wrote is taking back its own work; removing a directory is
			# not something this application does.

			unlink($_->{path}) for @{$st->{files} || []};
		},
	},
	);
}


sub buildFormats
	# The ids a build can be asked for, for whoever has to offer them.
{
	_initFormats() if !%FORMATS;
	return sort keys %FORMATS;
}


#---------------------------------------------
# the report
#---------------------------------------------
# ONE STRUCTURE, TWO CONSUMERS.  The console prints it and the dialog
# shows it, and neither may learn anything the other cannot -- otherwise
# "run it from the console to see what really happened" stops being true.
# So nothing here is a formatted string except the detail lines, which are
# formatted once by buildReportLines() for both.

sub _newReport
{
	return {
		ok			=> 0,
		guard		=> '',		# which guard refused, '' if none
		refused		=> '',		# why, in one sentence
		detail		=> [],		# the lines under it
		cancelled	=> 0,
		partial		=> 0,		# files were written before it stopped
		out_dir		=> '',
		regions		=> [],
		totals		=> { tiles => 0, absent => 0, failed => 0, converted => 0,
						 bytes => 0 },
		fill		=> undef,
		secs		=> 0,
		warned		=> 0,		# it went ahead, but something is worth saying
		warnings	=> [],
	};
}


sub _firstN
	# The first n of a list, and NEVER a slice.  @list[0..4] on a list of
	# two yields two values and three undefs, which reach a message as
	# blank lines and a warning -- and the list is short exactly when
	# something has gone wrong, so the naive version fails only in the
	# case it exists to serve.
{
	my ($list,$n) = @_;
	return () if !$list || !@$list;
	$n = scalar(@$list) if scalar(@$list) < $n;
	return @$list[0..$n-1];
}


sub _refuse
{
	my ($report,$guard,$msg,@detail) = @_;
	$report->{ok}		= 0;
	$report->{guard}	= $guard;
	$report->{refused}	= $msg;
	push @{$report->{detail}},@detail;
	error("build: $msg");
	display(0,1,$_) for @detail;
	return $report;
}


#---------------------------------------------
# VALIDATE
#---------------------------------------------

sub _validateSources
	# Every source any node in any region resolves to, checked once each.
	#
	# PER RESOLVED SOURCE ACROSS THE WHOLE TREE, not once per region.  A
	# subregion may legitimately name a different source than its parent --
	# that is the entire point of the field being on both -- so a check
	# that ran per region would pass a region whose detail box is built
	# from something the file cannot carry.
	#
	# Returns ($ok,$by_region) where $by_region is { id => source map },
	# the same maps the exporter is handed, so the thing that was
	# validated is the thing that gets used.
{
	my ($ids,$fallback,$report,$fmt) = @_;

	my %by_region;
	my %seen;			# source id => [ the nodes that named it ]

	for my $id (@$ids)
	{
		my $reg = getRegion($id) or next;
		my $map = regionSourceMap($reg,$fallback);
		$by_region{$id} = $map;

		# THE KEY IS ALREADY THE ANSWER.  A node's key is its path -
		# 'Bocas', 'Bocas/Popa00' - which is exactly how a node should be
		# named to somebody being told which one to go and fix.

		push @{$seen{$map->{$_}}},$_ for sort keys %$map;
	}

	my %build_ok = map { $_ => 1 } getBuildSourceIds();
	my %objects;

	for my $src_id (sort keys %seen)
	{
		my $who = join(', ',@{$seen{$src_id}});

		# 1 - INSTALLED.  Named against the node that names it, because
		# "which one do I fix" is the only useful part of this message.

		my $src = getSource($src_id);
		if (!$src)
		{
			_refuse($report,'source',
				"source '$src_id' is not installed",
				"named by: $who",
				"install the .tsd, or change the source on those regions");
			return (0,undef);
		}

		# 2 - MAY BUILD.  'uses' is the author's statement of what a
		# source is FOR.  It is consulted where a source is chosen and was
		# never consulted where one is used, so a set carried from another
		# machine could name a display-only basemap and fail at the only
		# moment it mattered.

		if (!$build_ok{$src_id})
		{
			_refuse($report,'uses',
				"source '$src_id' does not declare 'build' in its uses",
				"named by: $who",
				"it declares: ".join(', ',@{$src->{uses} || []}),
				"a display-only basemap cannot be a build source");
			return (0,undef);
		}

		# 3 - CARRIABLE OR CONVERTIBLE, and WHICH FORMAT ASKS depends on the
		# output.  RCT holds JPEG alone but re-encodes a png on the way in,
		# so the question here is no longer "what does the container hold"
		# but "can this machine get the tiles in at all".
		#
		# THE DECLARATION IS A HINT AND THIS IS THE ONLY PLACE IT IS ASKED
		# TO PREDICT ANYTHING.  tile_format is what a .tsd EXPECTS, and the
		# truth arrives per tile from the bytes -- so a refusal here can
		# only ever be an early warning, and it is worth having precisely
		# because the alternative is failing at tile four thousand of a run
		# that has already spent an hour.  It refuses only the case that no
		# outcome can rescue: a source that says png on a machine with no
		# decoder to convert one.  It no longer refuses a png-declaring
		# source that this machine can perfectly well convert, which it did
		# for as long as converting was not possible.
		#
		# The per-tile truth is still checked where it always was, in the
		# exporter, against the format the cache detected.

		if (!$fmt->{can_carry}->($src->{tile_format}) &&
			!$fmt->{can_convert}->($src->{tile_format}))
		{
			_refuse($report,'format',
				"source '$src_id' serves $src->{tile_format}, which ".
					"$fmt->{label} cannot carry",
				"named by: $who",
				"$fmt->{holds} ".join(', ',$fmt->{formats}->())." only",
				(imageCan() ? () :
					("no image decoder is installed, so it cannot be ".
					 "converted either")),
				$fmt->{blank});
			return (0,undef);
		}

		# 4 - USABLE AT ALL.  A url with a key_name nothing is bound to
		# cannot be substituted at any coordinate, so this is the last
		# moment it can be said cheaply.  The alternative is finding out at
		# tile four thousand, from a source that looks perfectly healthy in
		# every other line of every other panel.
		#
		# It is a REFUSAL rather than a warning because there is no partial
		# outcome available: not one tile of this source can be fetched.

		if (my $bad = sourceUnresolved($src))
		{
			_refuse($report,'key',
				"source '$src_id' needs a value for {$bad}",
				"named by: $who",
				"nothing in the key store is bound to that name",
				"set it in Edit > Key Store, or this source cannot ".
					"fetch a single tile");
			return (0,undef);
		}

		$objects{$src_id} = $src;
		display($dbg_build-1,1,"source '$src_id' ok ($src->{tile_format})");
	}

	# Resolve each region's map from ids to objects, once.  The exporter
	# takes objects because whether a source is installed, may build and
	# can be carried are three questions THIS function answers -- dm_rct
	# does not know how to ask them and must not learn.

	for my $id (keys %by_region)
	{
		$by_region{$id} = { map { $_ => $objects{$by_region{$id}{$_}} }
							keys %{$by_region{$id}} };
	}

	return (1,\%by_region);
}


sub _validate
{
	my ($ids,$opts,$report,$fmt) = @_;

	my $set = getActiveSet();
	if (!$set)
	{
		_refuse($report,'set',"there is no active region set");
		return (0,undef);
	}
	if (!@$ids)
	{
		_refuse($report,'set',"there is nothing in '$set' to build");
		return (0,undef);
	}

	# 0 - THE MODEL MUST BE ON DISK.  A file built from unsaved edits is
	# not reproducible from the set that is supposed to define it, and the
	# whole claim of a region set is that it IS the recipe.  Specified in
	# docs/design/editing.md and enforced nowhere until now.

	if (isSetDirty() && !$opts->{allow_dirty})
	{
		_refuse($report,'dirty',
			"'$set' has unsaved changes",
			"unsaved: ".join(', ',dirtyRegionIds()),
			"save the set first - a file built from edits that are not on ".
				"disk cannot be rebuilt from it");
		return (0,undef);
	}

	# 1..3 - the sources, per resolved source across every tree.

	my ($ok,$by_region) = _validateSources($ids,$opts->{fallback},$report,$fmt);
	return (0,undef) if !$ok;

	# 4 - EVERY REGION BUILT TOGETHER MUST AGREE on zauthor and zmin, and this
	# is a WARNING RATHER THAN A REFUSAL.
	#
	# IT IS ALSO ONLY TRUE OF .rct.  The check exists because the E80
	# fuses every .rct present into one pyramid; an output whose files are
	# independent charts has nothing to agree about, and warning there
	# would be teaching the user to ignore a real warning.
	#
	# What it is about: the firmware holds both on the CHARTSET, not per
	# file - it fuses every .rct it is given into one pyramid and indexes
	# it as zdir[z - zmin].  The reveal aperture is cut at the coarsest
	# zauthor present, so a file whose zmin is finer than that contributes
	# no outline at all and its imagery sits there fully built and
	# permanently invisible.
	#
	# Why it does not refuse: trying a new zauthor on ONE region before
	# converting a whole chartset is a legitimate thing to want, and a hard
	# refusal makes it impossible.  The preflight says so prominently and
	# the author decides - which is the same position the application takes
	# about imagery depth, and for the same reason.
	#
	# The FULL check, against the output folder as well as against the
	# regions being built, is dm_analysis::analyseFetch's - it is the
	# preflight that can see what is already on disk.  This one covers the
	# console, where there is no preflight.

	my (%zauthor,%zmin);
	if ($fmt->{uniform})
	{
		for my $id (@$ids)
		{
			my $reg = getRegion($id) or next;
			push @{$zauthor{$reg->{zauthor}}},$id;
			push @{$zmin{$reg->{zmin}}},$id;
		}
	}
	for my $pair ([\%zauthor,'zauthor'],[\%zmin,'zmin'])
	{
		my ($h,$name) = @$pair;
		next if scalar(keys %$h) <= 1;
		$report->{warned} = 1;
		push @{$report->{warnings}},
			"the regions disagree on $name - every .rct built from one set should ".
				"carry the same value, or the odd one out may be built and ".
				"permanently invisible",
			(map { "  $name $_ : ".join(', ',@{$h->{$_}}) } sort keys %$h);
		warning(0,0,"build: the regions disagree on $name");
		display(0,1,"$name $_ : ".join(', ',@{$h->{$_}})) for sort keys %$h;
	}

	# 5 - EVERY NAME MUST BE ONE THE FORMAT CAN USE, checked for the whole
	# set here rather than discovered when region five fails after an hour.

	my @bad = grep { !$fmt->{check_name}->($_) } @$ids;
	if (@bad)
	{
		_refuse($report,'name',
			"these region ids cannot name $fmt->{label} output: ".
				join(', ',@bad),
			$fmt->{name_help});
		return (0,undef);
	}

	# 6 - THE OUTPUT FOLDER.
	#
	# THE DEFAULT IS CREATED AS NEEDED; A CHOSEN ONE MUST ALREADY EXIST.
	# That asymmetry is the application's standing rule - it creates only
	# the folders it chose the location of - and it is not arbitrary: a
	# nominated path that is not there is far more likely to be a typo, an
	# unmounted drive, or a configuration copied from another machine than
	# an instruction to build a tree somewhere unexpected, and building it
	# would look like success while hiding the real problem.  The user
	# creates their own folder in the browser that picks it.

	my $out_dir = $opts->{out_dir};

	if ($out_dir)
	{
		if (!-d $out_dir)
		{
			_refuse($report,'out',
				"the output folder does not exist: $out_dir",
				"chartMaker creates only the folder it chose itself - ".
					"create this one, or Reset the output folder to the default");
			return (0,undef);
		}
	}
	else
	{
		my $base = $fmt->{base_dir}->();
		if (!-d $base)
		{
			_refuse($report,'out',
				"the output folder does not exist: $base",
				$fmt->{base_help});
			return (0,undef);
		}

		$out_dir = "$base/$set";
		if (!-d $out_dir && !mkdir($out_dir))
		{
			_refuse($report,'out',"could not create $out_dir: $!");
			return (0,undef);
		}
	}
	$report->{out_dir} = $out_dir;

	display($dbg_build,1,"validated ".scalar(@$ids)." region(s) -> $out_dir");
	return (1,$by_region);
}


#---------------------------------------------
# the act
#---------------------------------------------

sub buildRct
	# One folder of .rct files, for the E-Series.
{
	my ($ids,$opts) = @_;
	return buildOutput($ids,$opts,'rct');
}


sub buildMbtiles
	# One folder of region folders, each holding one .mbtiles per node.
{
	my ($ids,$opts) = @_;
	return buildOutput($ids,$opts,'mbtiles');
}


sub buildOutput
	# Build these region ids into one folder, in the named format.
	#
	# opts: zmax         a hard cap applied to both the fill and the export
	#       fallback     the source a region that inherits resolves to
	#       progress     a shared record from newProgress()
	#       config       the build configuration (advisory rates)
	#       out_dir      where the output goes; '' or absent = the default
	#       allow_dirty  build anyway from unsaved edits
	#       allow_failed export anyway with tiles that never arrived
	#
	# Returns a report.  Never dies, never prompts, and writes nothing
	# outside the set's own output folder.
	#
	# THE FILL IS FORMAT-BLIND, and that is worth noticing rather than
	# arranging: it asks the coverage enumerator for every tile and the
	# cache is keyed by source, so building a set to mbtiles after building
	# it to RCT fetches nothing at all.  The two outputs are peers over the
	# cache, so the second one is nearly free.
{
	my ($ids,$opts,$fmt_id) = @_;
	$opts ||= {};

	_initFormats() if !%FORMATS;
	my $fmt = $FORMATS{$fmt_id || 'rct'};

	my $report = _newReport();
	if (!$fmt)
	{
		return _refuse($report,'format',
			"there is no output format called '".($fmt_id // '')."'",
			"this build knows: ".join(', ',sort keys %FORMATS));
	}
	$report->{format} = $fmt->{id};
	$report->{unit}   = $fmt->{unit};
	$report->{noun}   = $fmt->{noun};

	my $started = time();
	my $prog = $opts->{progress};

	$ids = [ @$ids ];
	$opts->{fallback} ||= getDefaultSource();

	# WHAT A CONVERTED TILE IS WRITTEN AT, resolved ONCE here and carried in
	# $opts, so an exporter is handed a number instead of learning about the
	# preferences system.  A caller that passed one keeps it, which is what
	# lets a test pin the quality without touching anybody's settings.

	$opts->{quality} = prefVal($PREF_JPEG_QUALITY)
		if !defined $opts->{quality};
	$report->{quality} = $opts->{quality};

	$prog->{phase} = 'Validating' if $prog;
	display($dbg_build,0,"build $fmt->{id}: validating");

	my ($ok,$by_region) = _validate($ids,$opts,$report,$fmt);
	if (!$ok)
	{
		$report->{secs} = time() - $started;
		return $report;
	}

	# ---- FILL.  The long phase, and the only one with a progress bar.

	$prog->{phase} = 'Fetching' if $prog;
	display($dbg_build,0,"build $fmt->{id}: filling the cache for ".
		scalar(@$ids)." region(s)");

	my $fill = fillCoverage($ids,{
		fallback => $opts->{fallback},
		progress => $prog,
		config   => $opts->{config},
		defined $opts->{zmax} ? ( zmax => $opts->{zmax} ) : (),
	});
	$report->{fill} = $fill;

	# WHAT THAT SOURCE ACTUALLY MANAGED, recorded even if the run then
	# fails or is refused - the observation is just as true, and it is what
	# lets the NEXT preflight offer a time instead of admitting it has no
	# basis for one.  Only tiles that really went out are counted.

	for my $sid (keys %{$fill->{by_source} || {}})
	{
		my $by = $fill->{by_source}{$sid};
		next if !$by->{fetched};
		my $src = getSource($sid) or next;
		obsRecordRate($src,$by->{ms} / $by->{fetched});
	}

	# A BUILD IS A BOUNDED ACT, so the record is checkpointed here rather
	# than left to the clock.  Everything a fill learned - rates, round
	# trips, error classes, any 429 - reaches disk at the moment the run
	# that learned it ends.

	obsFlushAll();

	if ($fill->{cancelled})
	{
		$report->{cancelled} = 1;
		$report->{refused}   = "cancelled while fetching";
		$report->{secs}      = time() - $started;
		warning(0,0,"build $fmt->{id}: cancelled - nothing was written");
		return $report;
	}

	# A DEAD SOURCE IS NOT A FILE WITH HOLES.  fillCoverage gives up after
	# a run of consecutive failures rather than aiming thousands of
	# pointless requests at somebody's server; that is a stopped run, not
	# a result, and there is nothing to export from it.

	if ($fill->{aborted})
	{
		$report->{secs} = time() - $started;
		return _refuse($report,'source',
			"the fill gave up - the source stopped answering",
			"nothing was cached as missing, so fixing the source and ".
				"building again resumes where this stopped",
			_firstN($fill->{failed_tiles},3));
	}

	# ---- THE REFUSAL POINT.
	#
	# Scattered failures never trip the consecutive-error abort, so a fill
	# with three bad tiles out of nine thousand finishes "successfully".
	# The ledger is what catches those.  An error is never cached, so
	# there is nothing on disk afterwards to find them by -- this is the
	# only moment they are known.

	if ($fill->{error} && !$opts->{allow_failed})
	{
		$report->{secs} = time() - $started;
		return _refuse($report,'failed',
			"$fill->{error} tile(s) never arrived - the file would have ".
				"holes the plotter hides by overzooming",
			_firstN($fill->{failed_tiles},10),
			($fill->{error} > 10 ?
				"... and ".($fill->{error} - 10)." more" : ()),
			"building again retries them - errors are never cached");
	}

	# ---- EXPORT.  Short, and by now nothing here should be able to fail.

	$prog->{phase} = 'Writing' if $prog;
	if ($prog)
	{
		$prog->{done}      = 0;
		$prog->{total}     = scalar(@$ids);
		$prog->{sub_total} = 0;
		$prog->{sub_done}  = 0;
		$prog->{sub_label} = '';
	}
	display($dbg_build,0,"build $fmt->{id} -> $report->{out_dir}");

	for my $id (@$ids)
	{
		my $reg = getRegion($id) or next;

		# CANCEL IS CHECKED HERE TOO, between files rather than during one.
		# Writing a file is short next to fetching one, but a set of five
		# is not, and a Cancel button that does nothing for a minute reads
		# as a hang.  Between files is also the only safe place: a file is
		# written through a temp name and renamed, so stopping here leaves
		# no fragment - only whole files, and the report says how many.

		if (progressCancelled($prog))
		{
			$report->{cancelled} = 1;
			$report->{partial}   = scalar(@{$report->{regions}}) ? 1 : 0;
			$report->{refused}   = "cancelled while writing";
			$report->{secs}      = time() - $started;
			warning(0,0,"build $fmt->{id}: cancelled after ".
				scalar(@{$report->{regions}})." $fmt->{noun}(s)");
			return $report;
		}

		# {done} MEANS COMPLETED, in this phase exactly as in the fill.
		# The dialog shows the ordinal as done+1 and the bar as done/total,
		# so a phase that counted the one in hand as finished would run the
		# bar a whole region ahead of the truth.

		$prog->{label} = $id if $prog;

		# WHAT THE EXPORTER IS TOLD, and it is built here rather than passed
		# through, so an exporter never sees the build's own options.  Every
		# key in it is a deliberate handover.

		my $st = $fmt->{write}->($reg,$by_region->{$id},$report->{out_dir},
			{ quality => $opts->{quality},
			  defined $opts->{zmax} ? ( zmax => int($opts->{zmax}) ) : () });

		if (!$st)
		{
			$report->{partial} = scalar(@{$report->{regions}}) ? 1 : 0;
			$report->{secs} = time() - $started;
			# THE EXPORTER'S OWN SENTENCE FIRST.  "could not be written" is
			# true of every failure here and useful for none of them; the
			# reason names the source, the tile and what was wrong with it.

			my $why = $fmt->{last_error} ? $fmt->{last_error}->() : '';

			return _refuse($report,'export',
				"'$id' could not be written",
				($why ? ($why) : ()),
				$report->{partial} ?
					"already written for: ".join(', ',
						map { $_->{id} } @{$report->{regions}}) : ());
		}

		# BELT AND BRACES, and it should never fire: the fill just asked
		# for every one of these tiles and reported no errors.  If the
		# exporter still found one missing, something moved underneath us
		# -- a cache pruned mid-build, a source key that does not match --
		# and the output in hand is wrong.  Take it away rather than leave
		# a plausible file behind.

		if ($st->{failed} && !$opts->{allow_failed})
		{
			$fmt->{discard}->($st);
			$report->{partial} = scalar(@{$report->{regions}}) ? 1 : 0;
			$report->{secs} = time() - $started;
			return _refuse($report,'failed',
				"'$id' was missing $st->{failed} tile(s) at export, after a ".
					"fill that reported none - the cache changed underneath ".
					"the build",
				_firstN($st->{failed_tiles},5),
				"$st->{path} has been removed");
		}

		push @{$report->{regions}},{
			id			=> $id,
			name		=> $st->{name},
			tiles		=> $st->{tiles},
			absent		=> $st->{absent},
			failed		=> $st->{failed},
			converted	=> $st->{converted} || 0,
			blocks		=> $st->{blocks},
			bytes		=> $st->{size},
			zoom_min	=> $st->{zoom_min},
			zoom_max	=> $st->{zoom_max},
			path		=> $st->{path},
		};

		$report->{totals}{tiles}     += $st->{tiles};
		$report->{totals}{absent}    += $st->{absent};
		$report->{totals}{failed}    += $st->{failed};
		$report->{totals}{converted} += $st->{converted} || 0;
		$report->{totals}{bytes}     += $st->{size};

		$prog->{done}++ if $prog;

		display($dbg_build,1,sprintf("%-12s z%d-%-2d %7d tiles %5d absent ".
			"%2d blk %8.1f MB",$st->{name},$st->{zoom_min},$st->{zoom_max},
			$st->{tiles},$st->{absent},$st->{blocks},$st->{size}/1048576));
	}

	$report->{ok}   = 1;
	$report->{secs} = time() - $started;
	$prog->{phase}  = 'Done' if $prog;
	return $report;
}


#---------------------------------------------
# reporting
#---------------------------------------------

sub buildReportLines
	# The report as text, formatted ONCE for both the console and the
	# dialog.  Two renderings would drift, and the console is the surface
	# a user is told to fall back to when the windowed build looks wrong.
{
	my ($report) = @_;
	my @out;

	# A report that never reached a format still has to render - a refusal
	# on the format name itself is exactly that case.

	my $noun = $report->{noun} || 'file';
	my $unit = $report->{unit} || 'blk';

	if ($report->{cancelled})
	{
		# A CANCEL DURING THE WRITE IS NOT THE SAME AS ONE DURING THE
		# FETCH, and saying "nothing was written" when whole files are
		# sitting in the folder would be a lie the user finds later.

		if ($report->{partial})
		{
			push @out,"CANCELLED after writing ".
				scalar(@{$report->{regions}})." $noun(s).";
			push @out,$report->{out_dir};
			push @out,'';
			push @out,"  $_->{name}" for @{$report->{regions}};
			push @out,'';
			push @out,"Those are complete and the rest were not written,";
			push @out,"so the folder is INCOMPLETE.  Build again to";
			push @out,"finish it - the tiles are cached, so it will be quick.";
			return \@out;
		}

		push @out,"CANCELLED - nothing was written.";
		push @out,"Errors are never cached, so building again resumes ".
			"where this stopped.";
		return \@out;
	}

	if (!$report->{ok})
	{
		push @out,"REFUSED - $report->{refused}";
		push @out,'';
		push @out,@{$report->{detail}};
		push @out,'',"What was written before this was left in place."
			if $report->{partial};
		return \@out;
	}

	push @out,sprintf("Built %d %s(s) in %s",
		scalar(@{$report->{regions}}),$noun,_hms($report->{secs}));
	push @out,$report->{out_dir};

	# A WARNING SURVIVES INTO THE REPORT.  It was shown in the preflight
	# and accepted there, and it is still true of the file that now exists
	# - a success message that quietly drops it would leave the only
	# record of the decision in a dialog that has been closed.

	if ($report->{warned})
	{
		push @out,'';
		push @out,"WARNING";
		push @out,"  $_" for @{$report->{warnings}};
	}

	push @out,'';

	for my $r (@{$report->{regions}})
	{
		push @out,sprintf("  %-12s z%2d-%-2d %7d tiles %5d absent %3d %-5s %8.1f MB",
			$r->{name},$r->{zoom_min},$r->{zoom_max},$r->{tiles},
			$r->{absent},$r->{blocks},$unit,$r->{bytes}/1048576);
	}

	push @out,'';
	push @out,sprintf("  %-12s %14d tiles %5d absent %12.1f MB",
		'TOTAL',$report->{totals}{tiles},$report->{totals}{absent},
		$report->{totals}{bytes}/1048576);

	# ABSENT IS INFORMATION, NOT A WARNING.  A tile the source asserted it
	# does not have is a fact about the ground, it is correct to ship, and
	# retrying will never change it.  Saying "warning" about the normal
	# edge of a source's coverage teaches the user to ignore warnings.

	if ($report->{totals}{absent})
	{
		push @out,'';
		push @out,"$report->{totals}{absent} tile(s) are absent because the ".
			"source has no imagery there.";
		push @out,"The reader will magnify a coarser tile over those areas.";
	}

	# CONVERSION IS INFORMATION TOO, and it is said because a build that
	# quietly re-encoded half its bytes should not look identical to one
	# that copied them.  It names the quality, since that is the setting
	# somebody would go looking for after reading this line.

	if ($report->{totals}{converted})
	{
		push @out,'';
		push @out,"$report->{totals}{converted} tile(s) did not arrive as ".
			"JPEG and were re-encoded at quality ".
			($report->{quality} // prefVal($PREF_JPEG_QUALITY)).".";
		push @out,"An .rct holds JPEG only. Set the quality in Preferences.";
	}

	if ($report->{fill})
	{
		my $f = $report->{fill};
		push @out,'';
		push @out,sprintf("Fetched %d, already cached %d, in %s",
			$f->{tiles} - $f->{cached},$f->{cached},_hms($f->{secs}));
	}

	return \@out;
}


sub _hms
{
	my ($secs) = @_;
	$secs = int($secs + 0.5);
	return sprintf("%dm %02ds",int($secs/60),$secs % 60) if $secs >= 60;
	return "${secs}s";
}


1;
