#!/usr/bin/perl
#---------------------------------------------
# em_command.pm
#---------------------------------------------
# The chartMaker command vocabulary and dispatcher.
#
# This module sits BENEATH both front doors.  em_console.pm reads a line
# from the console and em_server.pm reads an /api/command request, and
# both hand this dispatcher the same verb.  One vocabulary, two
# transports -- which is also the test surface: anything the console can
# do, an HTTP client can do.
#
# Command output goes to display(), which lands in the Pub::Utils output
# ring, which is what /api/log returns.

package em_command;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use cm_defs;
use cm_prefs;
use cm_state;
use cm_utils;
use dm_set;
use dm_source;
use dm_cache;
use dm_fetch;
use dm_region;
use dm_coverage;
use dm_rct;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		dispatchCommand
		getMarkSeq
	);
}


my $mark_seq:shared = 0;

my $cmd_failed = 0;
	# WHETHER THE VERB JUST DISPATCHED REFUSED.  Not shared: it is reset at
	# the top of every dispatch and read at the bottom of the same call, on
	# the same thread.
	#
	# It exists because /edit has to tell the applet whether its commit was
	# ACCEPTED.  The applet drops its local copy of a polygon on commit, so
	# a refusal reported as success means the next poll quietly restores the
	# old geometry and the user's work disappears with no explanation.
	#
	# A flag rather than a return value from every branch: the vocabulary is
	# eighty branches deep and only the mutating ones can fail in a way the
	# caller can act on.  A verb that never sets it reports success, which
	# is what it did before this existed.


sub _fail
	# Report and mark.  Every refusal that a caller might need to know
	# about goes through here rather than calling error() directly.
{
	my ($msg) = @_;
	error($msg) if defined $msg;
	$cmd_failed = 1;
	return 0;
}


sub getMarkSeq
	# The sequence number stamped by the last 'mark' command.
	# em_server's /api/log?since=mark reads this.
{
	return $mark_seq;
}


sub commandHelp
{
	return [
		[ '?|help',				'show this help'											],
		[ 'mark',				'stamp the output ring for /api/log?since=mark'				],
		[ 'version',			'show the application name and its standard directories'	],
		[ 'prefs',				'list the current preferences'								],
		[ 'map',				'open the Leaflet map in a browser'							],
		[ 'dbg [name] [value]',	'list, show, or set a $dbg_xxx debug level at runtime'		],
		[ 'sources',			'list the tile source definitions found in sources/'		],
		[ 'source <id>',		'show one source in full'									],
		[ 'source rescan',		're-read the .tsd files from sources/'						],
		[ 'source use <id>',	'make one source the one the map displays'					],
		[ 'tile <id> <z> <x> <y>',	'fetch one tile and report what came back'				],
		[ 'cache [id]',			'what the tile cache holds, by zoom'						],
		[ 'set',				'list the region sets, marking the active one'				],
		[ 'set use <name>',		'make one region set active'								],
		[ 'set new <name>',		'create an empty region set'								],
		[ 'regions',			'list the regions in the active set'						],
		[ 'region <id>',		'show one region and its subregions'						],
		[ 'region rescan',		're-read the .region files from the active set'				],
		[ 'region new <name> [z]',		'create an empty region'							],
		[ 'region rename <id> <name>',	'change a region\'s name (free text, no structural role)'],
		[ 'region id <id> <new id>',	'change a region\'s id, its file and every set naming it'],
		[ 'region zauthor <id> <z>',	'set the level the polygon is authored at'			],
		[ 'region zmin <id> <z>',		'set the overview floor'							],
		[ 'region zmax <id> <z> [sub]',	'set how deep a region or subregion goes'			],
		[ 'region count [id|all] [zmax]','how many tiles a region would build, by zoom'		],
		[ 'select <id|none>',	'select a region or subregion, on every surface at once'	],
		[ 'edit [mode] [id] [dirty]','what the map is doing: browse, shape, draw, end'	],
		[ 'region geometry <id> [sub]',	'replace polygons - /edit only, the map supplies them'],
		[ 'region delete <id>',			'delete a region and its file'						],
		[ 'region import <file> [z]',	'import each KML folder as a region'				],
		[ 'subregion new <parent> <zmax> <name>',
										'add an empty detail area - draw it on the map'		],
		[ 'subregion delete <region> <id>',	'remove a detail area'							],
		[ 'build rct <id|set> [zmax]',	'export region(s) as .rct card files'				],
		[ 'check <id>',			'show a region on the map'									],
		[ 'uncheck <id>',		'hide it from the map (it is still on the card)'			],
	];
}


sub findDebugVars
	# Walk the symbol table for package scalars named dbg_*, which is
	# possible only because they are declared 'our'.  Returns a hash of
	# fully qualified name => scalar ref.  A var that was never given a
	# value is skipped, so this finds declarations rather than typos.
{
	my ($pkg,$depth,$seen,$found) = @_;
	$pkg   ||= 'main::';
	$depth ||= 0;
	$seen  ||= {};
	$found ||= {};
	return $found if $depth > 6;

	no strict 'refs';
	for my $key (keys %{$pkg})
	{
		if ($key =~ /::$/)
		{
			my $child = $pkg eq 'main::' ? $key : $pkg.$key;
			next if $child eq 'main::';
			next if $seen->{$child}++;
			findDebugVars($child,$depth+1,$seen,$found);
		}
		elsif ($key =~ /^dbg_/)
		{
			my $full = ($pkg eq 'main::' ? '' : $pkg).$key;
			my $ref  = \${$full};
			$found->{$full} = $ref if defined($$ref);
		}
	}
	return $found;
}


sub _dbgCommand
	# dbg                  - list every $dbg_xxx and its current value
	# dbg <name>           - show one (bare name matches any package)
	# dbg <name> <value>   - set one
{
	my ($rpart) = @_;
	my ($name,$value) = split(/\s+/,$rpart,2);
	my $vars = findDebugVars();

	if (!defined($name) || $name eq '')
	{
		display(0,0,"debug variables");
		for my $full (sort keys %$vars)
		{
			display(0,1,sprintf("%-44s = %s",$full,${$vars->{$full}}));
		}
		return;
	}

	my @matches = $name =~ /::/ ?
		grep { $_ eq $name } keys %$vars :
		grep { /(?:^|::)\Q$name\E$/ } keys %$vars;

	if (!@matches)
	{
		warning(0,0,"dbg: no debug variable matching '$name'");
	}
	elsif (@matches > 1 && defined($value) && $value ne '')
	{
		warning(0,0,"dbg: '$name' is ambiguous - ".join(', ',sort @matches));
	}
	else
	{
		for my $full (sort @matches)
		{
			${$vars->{$full}} = int($value)
				if defined($value) && $value ne '';
			display(0,0,"dbg: $full = ".${$vars->{$full}});
		}
	}
}


sub _sourcesCommand
{
	my @ids = getSourceIds();
	if (!@ids)
	{
		display(0,0,"no sources in ".sourcesDir());
		display(0,1,"a source is a .tsd file - see docs/design/tsd.md");
		return;
	}
	display(0,0,"sources");
	for my $id (@ids)
	{
		my $src = getSource($id);
		display(0,1,sprintf("%-20s %-14s z%-2d-%-2d  %s",
			$id,
			join(',',@{$src->{uses}}),
			$src->{zoom}{min},
			$src->{zoom}{max},
			$src->{name}));
	}
}


sub _sourceCommand
{
	my ($rpart) = @_;
	my ($id) = split(/\s+/,$rpart,2);

	if (!defined($id) || $id eq '')
	{
		warning(0,0,"source: which one?  (try 'sources')");
		return;
	}
	if ($id eq 'rescan')
	{
		my $found = rescanSources();
		display(0,0,"source rescan: $found source".($found == 1 ? '' : 's'));

		# The bump belongs here rather than in dm_source: reloading files
		# from disk is a data operation, and deciding that the map should
		# hear about it is control flow.

		bumpState("sources rescanned");
		return;
	}
	if ($id eq 'use')
	{
		my (undef,$which) = split(/\s+/,$rpart,2);
		$which =~ s/\s+$// if defined $which;
		if (!defined($which) || $which eq '')
		{
			display(0,0,"the map is showing '".(getDefaultSource() || '(none)')."'");
			return;
		}
		if (!getSource($which))
		{
			warning(0,0,"source use: no source with id '$which'");
			return;
		}
		setDefaultSource($which);
		display(0,0,"source use: the map is now showing '$which'");
		return;
	}

	my $src = getSource($id);
	if (!$src)
	{
		warning(0,0,"source: no source with id '$id'");
		return;
	}

	display(0,0,"source $id");
	for my $key (qw( name file cache_key kind url subdomains tile_format
					 tile_size crs redistributable license terms_url notes ))
	{
		my $val = $src->{$key};
		next if !defined $val;
		$val = join(',',@$val) if ref($val) eq 'ARRAY';
		display(0,1,sprintf("%-16s %s",$key,$val));
	}
	display(0,1,sprintf("%-16s %s",'uses',join(',',@{$src->{uses}})));
	display(0,1,sprintf("%-16s %d-%d",'zoom',$src->{zoom}{min},$src->{zoom}{max}));
	display(0,1,sprintf("%-16s %s",'attribution',$src->{attribution}));
	if ($src->{credentials})
	{
		display(0,1,sprintf("%-16s %s",'credentials',
			join(',',map { $_->{slot} } @{$src->{credentials}})));
	}
}


sub _tileCommand
{
	my ($rpart) = @_;
	my ($id,$z,$x,$y) = split(/\s+/,$rpart);

	if (!defined($y))
	{
		warning(0,0,"tile: usage is 'tile <id> <z> <x> <y>'");
		return;
	}
	my $src = getSource($id);
	if (!$src)
	{
		warning(0,0,"tile: no source with id '$id'");
		return;
	}

	my $url = sourceTileUrl($src,$z,$x,$y);
	display(0,0,"tile $id $z/$x/$y");
	display(0,1,"url    ".($url // '(none - outside the declared zoom range)'));

	my $result = getTile($src,$z,$x,$y);
	display(0,1,"status ".$result->{status}.
		($result->{cached} ? ' (from cache)' : ''));
	display(0,1,"http   ".$result->{http})		if defined $result->{http};
	display(0,1,"time   $result->{ms} ms")		if defined $result->{ms};
	display(0,1,"reason ".$result->{reason})	if defined $result->{reason};
	if ($result->{status} eq 'ok')
	{
		display(0,1,"format ".$result->{format});
		display(0,1,"bytes  ".length(${$result->{bytes}}));
	}
}


sub _cacheCommand
{
	my ($rpart) = @_;
	my ($id) = split(/\s+/,$rpart,2);
	my @ids = (defined($id) && $id ne '') ? ($id) : getSourceIds();

	for my $one (@ids)
	{
		my $src = getSource($one);
		if (!$src)
		{
			warning(0,0,"cache: no source with id '$one'");
			next;
		}
		my $stats = cacheStats($src);
		display(0,0,"cache $one  (".$src->{cache_key}.")");
		if (!$stats->{total_tiles} && !$stats->{total_misses})
		{
			display(0,1,"empty");
			next;
		}
		for my $z (sort { $a <=> $b } keys %{$stats->{zooms}})
		{
			my $zs = $stats->{zooms}{$z};
			display(0,1,sprintf("z%-2d  %6d tiles  %6d absent  %9d bytes",
				$z,$zs->{tiles},$zs->{misses},$zs->{bytes}));
		}
		display(0,1,sprintf("     %6d tiles  %6d absent  %9d bytes  TOTAL",
			$stats->{total_tiles},$stats->{total_misses},$stats->{total_bytes}));
	}
}


sub _showSubregions
{
	my ($reg,$level) = @_;
	for my $sub (@{$reg->{subregions}})
	{
		display(0,$level,sprintf("%-16s to z%-2d  %d polygon(s)  %s",
			$sub->{id},$sub->{zmax},
			scalar(@{$sub->{geometry}}),$sub->{name}));
		_showSubregions($sub,$level+1);
	}
}


sub _buildCommand
	# build rct <id|set|all> [zmax]
	#
	# 'set' MEANS THE WHOLE ACTIVE SET, not the checked part of it.  The
	# set is a folder and every region file in it is part of the card,
	# because THE SET OF FILES PRESENT IS THE SET OF REGIONS - on the card
	# there is no manifest, and there is none here either.  Checking a
	# region hides it from the map while you work; it has never been a
	# statement about what belongs on the card, and 'all' is now the same
	# thing said twice.
{
	my ($rest) = @_;
	my ($what,$which,$zmax) = split(/\s+/,$rest || '');

	if (!defined($what) || $what ne 'rct')
	{
		warning(0,0,"build: usage is 'build rct <id|set|all> [zmax]'");
		return;
	}
	$which = 'set' if !defined($which) || $which !~ /\S/;

	my $set = getActiveSet();
	if (!$set)
	{
		warning(0,0,"build rct: there is no active region set");
		return;
	}

	my @ids = ($which eq 'all' || $which eq 'set') ?
		getRegionIds() : ($which);
	if (!@ids)
	{
		warning(0,0,"build rct: nothing to build");
		return;
	}

	# The source you are LOOKING at is the one you build from - display
	# and build share one cache, so previewing a region is what fills the
	# cache the build reads.  Falling back to the remembered default keeps
	# a fresh start working before anything has been selected.
	#
	# Once a region carries its own source this becomes the fallback
	# rather than the answer.

	my $src_id = getDefaultSource();
	my $src    = $src_id ? getSource($src_id) : undef;
	if (!$src)
	{
		warning(0,0,"build rct: no active source - try 'source use <id>'");
		return;
	}
	display(0,1,"source '$src_id'");

	# ONE OUTPUT FOLDER PER SET, and it is the folder you copy to the card.
	# \RASTER\ on the CF card is the CONSUMER's contract - a single outer
	# folder holding exactly one region set - so the producer side needs
	# one folder per set for the copy to be a copy rather than a decision.

	if (!-d $RASTER_DIR)
	{
		warning(0,0,"build rct: $RASTER_DIR does not exist");
		return;
	}
	my $out_dir = "$RASTER_DIR/$set";
	if (!-d $out_dir && !mkdir($out_dir))
	{
		error("build rct: could not create $out_dir: $!");
		return;
	}

	# ALL RCTs ON ONE CARD MUST AGREE on zauthor and zmin - the firmware
	# holds both on the chartset, not per file.  A disagreement is the one
	# authoring error the format cannot absorb: whichever file is finer
	# than the chosen outline level contributes no outline at all and its
	# imagery is drawn but permanently invisible.

	my (%zauthor,%zmin);
	for my $id (@ids)
	{
		my $reg = getRegion($id) or next;
		push @{$zauthor{$reg->{zauthor}}},$id;
		push @{$zmin{$reg->{zmin}}},$id;
	}
	for my $pair ([\%zauthor,'zauthor'],[\%zmin,'zmin'])
	{
		my ($h,$name) = @$pair;
		next if scalar(keys %$h) <= 1;
		error("build rct: the regions disagree on $name, and every file on ".
			"one card must carry the same value:");
		display(0,1,"$name $_ : ".join(', ',@{$h->{$_}})) for sort keys %$h;
		return;
	}

	display(0,0,"build rct -> $out_dir".(defined $zmax ? "   cap zmax=$zmax" : ''));
	my $total = 0;
	my $short = 0;

	for my $id (@ids)
	{
		my $reg = getRegion($id);
		if (!$reg)
		{
			warning(0,0,"build rct: no region with id '$id'");
			next;
		}
		my $name = rctCardName($reg->{id});
		if (!$name)
		{
			error("build rct: '$reg->{id}' is not a usable 8.3 stem");
			next;
		}

		my $st = writeRct($reg,$src,"$out_dir/$name",
			{ defined $zmax ? (zmax => int($zmax)) : () });
		next if !$st;

		$total += $st->{tiles};
		$short += $st->{absent};
		display(0,1,sprintf("%-12s z%d-%-2d %7d tiles %5d absent %2d blk %8.1f MB",
			$st->{name},$st->{zoom_min},$st->{zoom_max},
			$st->{tiles},$st->{absent},$st->{blocks},$st->{size}/1048576));
	}

	display(0,1,sprintf("%-12s %19d tiles %5d absent",'TOTAL',$total,$short));
	warning(0,1,"$short tile(s) were not in the cache and are ABSENT from the ".
		"card - the plotter will overzoom a coarser tile there") if $short;
}


sub _regionsCommand
{
	my $set = getActiveSet();
	if (!$set)
	{
		display(0,0,"there is no active region set");
		display(0,1,"try 'set new <name>'");
		return;
	}

	my @ids = getRegionIds();
	if (!@ids)
	{
		display(0,0,"no regions in set '$set'");
		display(0,1,"try 'region import <file.kml>' or 'region new <name>'");
		return;
	}
	display(0,0,"regions in set '$set'");
	for my $id (@ids)
	{
		my $reg = getRegion($id);
		display(0,1,sprintf("%s %-16s z%d-%d/%-2d %d poly %4d pts %s %s",
			isChecked($id) ? '[x]' : '[ ]',
			$id,$reg->{zmin},$reg->{zmax},$reg->{zauthor},
			scalar(@{$reg->{geometry}}),
			regionPointCount($reg),
			scalar(@{$reg->{subregions}}) ?
				sprintf("%d sub",scalar(@{$reg->{subregions}})) : "     ",
			$reg->{name}));
	}
	my @working = getWorkingSet();
	display(0,1,scalar(@working)." of ".scalar(@ids).
		" shown on the map - ALL ".scalar(@ids)." are on the card");
}


sub _regionGeometry
	# region geometry <id> [subregion id]   + data = [ polygon, ... ]
	#
	# THE ONLY VERB THAT REQUIRES STRUCTURED DATA, and the only one the
	# console therefore cannot invoke on its own.  That asymmetry is the
	# point rather than a wart: drawing is a thing the map does, and this
	# is where what it drew enters the model through the same door
	# everything else uses.
	#
	# The geometry REPLACES what was there.  An edit session is a whole
	# polygon list handed over on commit, not a stream of vertex deltas -
	# there is no partial state on this side to get out of step, and a
	# lost or duplicated message cannot leave a half-moved shape behind.
	#
	# Validation is dm_region's, not this module's.  saveRegion validates
	# what will actually be written and refuses the whole save, so a
	# polygon with two points or a latitude outside Web Mercator never
	# reaches the file.
{
	my ($rest,$data) = @_;
	my ($id,$sub_id) = split(/\s+/,$rest || '');

	return _fail("region geometry: which region?")
		if !defined($id) || $id !~ /\S/;
	return _fail("region geometry: needs a polygon list, which only the map ".
		"can supply - there is no way to type one")
		if ref($data) ne 'ARRAY';

	my ($reg,$target) = findAnywhere($id);
	return _fail("region geometry: nothing with id '$id'") if !$reg;

	if (defined($sub_id) && $sub_id =~ /\S/)
	{
		($target) = findSubregion($reg,$sub_id);
		return _fail("region geometry: '$id' has no subregion '$sub_id'")
			if !$target;
	}

	my $was = scalar(@{$target->{geometry} || []});
	my $old = $target->{geometry};
	$target->{geometry} = $data;

	# The whole REGION is saved, because a subregion is not a file - it
	# lives inside its root's.  The old geometry is put back on refusal, so
	# that a rejected commit leaves the model exactly as it was rather than
	# holding a shape the validator would not accept.

	if (!saveRegion($reg))
	{
		$target->{geometry} = $old;
		$cmd_failed = 1;
		return;
	}

	my $now = scalar(@{$target->{geometry}});
	display(0,0,"region geometry: '$target->{id}' $was -> $now polygon(s), ".
		regionPointCount($target)." point(s)");
	bumpState("'$target->{id}' geometry");
}


sub _selectCommand
	# select <id> | none
	#
	# The id may name a region or a subregion at any depth; the selection
	# stores both the root and the node, because everything that writes
	# needs the root and everything that displays wants the node.
{
	my ($rpart) = @_;
	my ($id) = split(/\s+/,$rpart || '');
	$id = '' if !defined $id;

	if ($id eq '' || lc($id) eq 'none')
	{
		setSelection('','');
		display(0,0,"select: nothing selected");
		return;
	}

	my $lock = editLocks();
	return _fail("select: $lock - Save or Revert first") if $lock;

	my ($root,$node) = findAnywhere($id);
	return _fail("select: nothing with id '$id'") if !$root;

	my $sub = ($node != $root) ? $node->{id} : '';
	setSelection($root->{id},$sub);
	display(0,0,"select: '".($sub || $root->{id})."'".
		($sub ? " (subregion of $root->{id})" : ''));
}


sub _editCommand
	# edit <browse|shape|draw> [<id>] [dirty]
	# edit end
	#
	# How the map tells the application what it is doing, so that the tree
	# can refuse to delete what is under the user's hand and so that
	# nobody renders an object from the model while it is being dragged.
{
	my ($rpart) = @_;
	my ($mode,$id,$flag) = split(/\s+/,$rpart || '');
	$mode = lc($mode // '');

	if ($mode eq '' )
	{
		my $st = getEditState();
		display(0,0,"edit: $st->{mode}".
			($st->{region} ? " '".($st->{sub} || $st->{region})."'" : '').
			($st->{dirty} ? " DIRTY" : ''));
		return;
	}
	if ($mode eq 'end')
	{
		clearEditState();
		display(0,0,"edit: browse");
		return;
	}
	return _fail("edit: expected browse, shape, draw or end")
		if $mode ne $EDIT_BROWSE && $mode ne $EDIT_SHAPE && $mode ne $EDIT_DRAW;

	my ($root,$node) = (undef,undef);
	if (defined($id) && $id =~ /\S/)
	{
		($root,$node) = findAnywhere($id);
		return _fail("edit: nothing with id '$id'") if !$root;
	}

	my $sub = ($root && $node != $root) ? $node->{id} : '';
	setEditState($mode,$root ? $root->{id} : '',$sub,
		(defined($flag) && lc($flag) eq 'dirty') ? 1 : 0);

	my $st = getEditState();
	display(0,0,"edit: $st->{mode}".
		($st->{region} ? " '".($st->{sub} || $st->{region})."'" : '').
		($st->{dirty} ? " DIRTY" : ''));
}


sub _regionCommand
{
	my ($rpart,$data) = @_;
	my ($verb,$rest) = split(/\s+/,$rpart,2);
	$verb //= '';
	$rest //= '';

	if ($verb eq '')
	{
		warning(0,0,"region: which one?  (try 'regions')");
		return;
	}

	if ($verb eq 'rescan')
	{
		my $found = rescanRegions();
		display(0,0,"region rescan: $found region".($found == 1 ? '' : 's'));
		bumpState("regions rescanned");
		return;
	}
	if ($verb eq 'new')
	{
		# TWO FORMS, because two callers want different things.  A person
		# typing wants to name a region and get sensible zooms; an interface
		# that has already asked for all five fields wants to state them:
		#
		#	region new <name...> [zauthor]
		#	region new <id> <zauthor> <zmin> <zmax> <name...>
		#
		# The long form is recognised by its shape - an id followed by three
		# integers - which nothing in the short form can look like, because a
		# name ending in three numbers is not a name anybody types.

		my ($name,$zoom,$id,$zmin,$zmax);
		if ($rest =~ /^([A-Za-z0-9]+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S.*)$/)
		{
			($id,$zoom,$zmin,$zmax,$name) = ($1,$2,$3,$4,$5);
			$name =~ s/\s+$//;
		}
		else
		{
			($name,$zoom) = $rest =~ /^(.*?)\s+(\d+)\s*$/ ? ($1,$2) : ($rest,15);
		}
		return _fail("region new: a name is required") if $name !~ /\S/;

		my $reg = newRegion($name,$zoom,$zmin,$zmax,$id);
		if (!$reg)
		{
			$cmd_failed = 1;
			return;
		}
		display(0,0,"region new: created '$reg->{id}' ".
			"z$reg->{zmin}-$reg->{zmax} authored at z$reg->{zauthor}");
		display(0,1,"no geometry yet - draw it on the map");
		bumpState("region '$reg->{id}' created");
		return;
	}
	if ($verb eq 'id')
	{
		my ($id,$new_id) = split(/\s+/,$rest);
		return _fail("region id: usage is 'region id <id> <new id>'")
			if !defined($new_id) || $new_id !~ /\S/;

		if (setRegionId($id,$new_id))
		{
			display(0,0,"region id: '$id' is now '$new_id'");
			bumpState("region '$id' is now '$new_id'");
		}
		else
		{
			$cmd_failed = 1;
		}
		return;
	}
	if ($verb eq 'rename')
	{
		my ($id,$name) = split(/\s+/,$rest,2);
		return _fail("region rename: usage is 'region rename <id> <new name>'")
			if !defined($name) || $name !~ /\S/;

		$name =~ s/\s+$//;
		if (renameRegion($id,$name))
		{
			display(0,0,"region rename: '$id' is now called '$name'");
			bumpState("region '$id' renamed");
		}
		else
		{
			$cmd_failed = 1;
		}
		return;
	}
	if ($verb eq 'count')
	{
		# The region carries its own levels now, so the only thing left to
		# pass is the build's cap -- which is what 'build <id> --zmax 16'
		# will hand it, and the reason this is still a parameter at all.

		my ($id,$zmax) = split(/\s+/,$rest);
		my @ids = (defined($id) && $id ne '' && $id ne 'all') ?
			($id) : getRegionIds();

		display(0,0,"region count".(defined $zmax ? "   cap zmax=$zmax" : ''));
		my %grand;
		my $total = 0;
		for my $one (@ids)
		{
			my $reg = getRegion($one);
			if (!$reg)
			{
				warning(0,0,"region count: no region with id '$one'");
				next;
			}
			my $cov = regionCoverage($reg,{ zmax => $zmax });
			my $counts = coverageCounts($cov);
			my $sum = 0;
			$sum += $counts->{$_} for keys %$counts;
			$grand{$_} += $counts->{$_} for keys %$counts;
			$total += $sum;
			display(0,1,sprintf("%-16s %7d   %s",$one,$sum,
				join('  ',map { "z$_=$counts->{$_}" }
					sort { $a <=> $b } keys %$counts)));
		}
		if (@ids > 1)
		{
			display(0,1,sprintf("%-16s %7d   %s",'TOTAL',$total,
				join('  ',map { "z$_=$grand{$_}" }
					sort { $a <=> $b } keys %grand)));
		}
		return;
	}
	if ($verb eq 'zauthor' || $verb eq 'zmin' || $verb eq 'zmax')
	{
		my ($id,$zoom,$sub_id) = split(/\s+/,$rest);
		return _fail("region $verb: usage is 'region $verb <id> <zoom> [subregion]'")
			if !defined($zoom) || $zoom !~ /^\d+$/;

		my $reg = getRegion($id);
		return _fail("region $verb: no region with id '$id'") if !$reg;

		my $target = $reg;
		if (defined $sub_id)
		{
			($target) = findSubregion($reg,$sub_id);
			if (!$target)
			{
				return _fail("region $verb: '$id' has no subregion '$sub_id'");
			}

			# A subregion has one level and it is zmax.  Accepting an
			# authored level here would be inventing a field the model
			# does not have and the exporter could not use.

			if ($verb ne 'zmax')
			{
				return _fail("region $verb: a subregion has zmax only - ".
					"it never cuts a reveal contour");
			}
		}
		my $was = $target->{$verb};
		$target->{$verb} = int($zoom);
		if (!saveRegion($reg))
		{
			$target->{$verb} = $was;
			$cmd_failed = 1;
			return;
		}
		display(0,0,"region $verb: '$target->{id}' $verb = $zoom");
		bumpState("'$target->{id}' $verb $zoom");
		return;
	}
	if ($verb eq 'geometry')
	{
		return _regionGeometry($rest,$data);
	}
	if ($verb eq 'delete')
	{
		my ($id) = split(/\s+/,$rest,2);
		if (deleteRegion($id))
		{
			display(0,0,"region delete: '$id' is gone");
			bumpState("region '$id' deleted");
		}
		else
		{
			$cmd_failed = 1;
		}
		return;
	}
	if ($verb eq 'import')
	{
		my ($path,$zoom) = $rest =~ /^(.*?)\s+(\d+)\s*$/ ? ($1,$2) : ($rest,15);
		if (!-f $path)
		{
			warning(0,0,"region import: no such file '$path'");
			return;
		}
		my @made = importKmlFile($path,$zoom);
		if (!@made)
		{
			warning(0,0,"region import: nothing usable in '$path'");
			return;
		}
		display(0,0,"region import: ".scalar(@made)." region(s) at z$zoom");
		display(0,1,$_) for @made;
		bumpState(scalar(@made)." region(s) imported");
		return;
	}

	# not a verb, so it is an id

	my $reg = getRegion($verb);
	if (!$reg)
	{
		warning(0,0,"region: no region with id '$verb'");
		return;
	}
	display(0,0,"region $reg->{id}");
	display(0,1,sprintf("%-16s %s",'name',$reg->{name}));
	display(0,1,sprintf("%-16s %s",'file',$reg->{file}));
	display(0,1,sprintf("%-16s %d",'zauthor',$reg->{zauthor}));
	display(0,1,sprintf("%-16s %d",'zmin',$reg->{zmin}));
	display(0,1,sprintf("%-16s %d",'zmax',$reg->{zmax}));
	display(0,1,sprintf("%-16s %s",'checked',isChecked($verb) ? 'yes' : 'no'));
	display(0,1,sprintf("%-16s %s",'notes',$reg->{notes})) if $reg->{notes};

	my $n = 0;
	for my $poly (@{$reg->{geometry}})
	{
		my @lon = sort { $a <=> $b } map { $_->[0] } @$poly;
		my @lat = sort { $a <=> $b } map { $_->[1] } @$poly;
		display(0,1,sprintf("polygon %d      %3d points  lon %.4f..%.4f  lat %.4f..%.4f",
			$n++,scalar(@$poly),$lon[0],$lon[-1],$lat[0],$lat[-1]));
	}
	if (@{$reg->{subregions}})
	{
		display(0,1,"subregions");
		_showSubregions($reg,2);
	}
}


sub _subregionCommand
{
	my ($rpart) = @_;
	my ($verb,$rest) = split(/\s+/,$rpart,2);
	$verb //= '';
	$rest //= '';

	if ($verb eq 'new')
	{
		# CREATED NAMED AND EMPTY.  The geometry comes from the map through
		# 'region geometry', like every other polygon - see
		# docs/design/editing.md on why nothing invents a shape here.

		my ($parent,$zoom,$name) = split(/\s+/,$rest,3);
		if (!defined($name) || $name !~ /\S/)
		{
			warning(0,0,"subregion new: usage is ".
				"'subregion new <parent> <zmax> <name...>'");
			$cmd_failed = 1;
			return;
		}
		$name =~ s/\s+$//;
		my $sub = addSubregion($parent,$name,$zoom);
		if (!$sub)
		{
			$cmd_failed = 1;
			return;
		}
		display(0,0,"subregion new: '$sub->{id}' under '$parent' to z$zoom");
		display(0,1,"no geometry yet - draw it on the map");
		bumpState("subregion '$sub->{id}' added");
		return;
	}
	if ($verb eq 'delete')
	{
		my ($parent,$id) = split(/\s+/,$rest);
		if (!defined($id))
		{
			warning(0,0,"subregion delete: usage is 'subregion delete <region> <id>'");
			return;
		}
		if (deleteSubregion($parent,$id))
		{
			display(0,0,"subregion delete: '$id' removed from '$parent'");
			bumpState("subregion '$id' deleted");
		}
		else
		{
			$cmd_failed = 1;
		}
		return;
	}
	warning(0,0,"subregion: expected 'new' or 'delete'");
}


sub _checkCommand
{
	my ($id,$on) = @_;
	$id =~ s/\s+$// if defined $id;
	if (!defined($id) || $id eq '')
	{
		warning(0,0,($on ? 'check' : 'uncheck').": which region?");
		return;
	}
	return if !setChecked($id,$on);
	display(0,0,($on ? 'check' : 'uncheck').": '$id' is ".
		($on ? 'shown on' : 'hidden from')." the map");
	bumpState("'$id' ".($on ? 'checked' : 'unchecked'));
}


sub _setCommand
	# set                 - list the sets, marking the active one
	# set use <name>      - make one active
	# set new <name>      - create one
	#
	# There is deliberately no 'set delete'.  A set is a folder of the
	# user's own region files, and deleting it is File Explorer's job -
	# which is the same reason there is no 'set add' or 'set remove': the
	# files present ARE the set, so moving a .region file in or out of the
	# folder is the whole of the operation.
{
	my ($rpart) = @_;
	my ($verb,$name) = split(/\s+/,$rpart || '',2);
	$verb //= '';
	$name =~ s/\s+$// if defined $name;

	if ($verb eq '')
	{
		my @names = getSetNames();
		if (!@names)
		{
			display(0,0,"there are no region sets in ".regionSetsDir());
			display(0,1,"try 'set new <name>'");
			return;
		}
		my $active = getActiveSet();
		display(0,0,"region sets");
		for my $n (@names)
		{
			my $dir = setDir($n);
			my @regions = glob("$dir/*.region");
			display(0,1,sprintf("%s %-16s %d region(s)",
				$n eq $active ? '->' : '  ',$n,scalar(@regions)));
		}
		return;
	}

	if ($verb eq 'use')
	{
		if (!defined($name) || $name !~ /\S/)
		{
			warning(0,0,"set use: which set?");
			return;
		}
		if (!setExists($name))
		{
			error("set use: there is no set named '$name'");
			return;
		}
		setActiveSet($name);
		display(0,0,"active set is '".getActiveSet()."'");
		bumpState("active set is '$name'");
		return;
	}

	if ($verb eq 'new')
	{
		if (!defined($name) || $name !~ /\S/)
		{
			warning(0,0,"set new: what name?");
			return;
		}
		return if !newSet($name);
		display(0,0,"created set '$name', now active");
		bumpState("set '$name' created");
		return;
	}

	warning(0,0,"set: expected 'use' or 'new'");
}


sub dispatchCommand
	# THE THIRD ARGUMENT IS OPTIONAL STRUCTURED DATA, and only the map ever
	# passes it -- a polygon does not fit in a command line, and pretending
	# it could would mean encoding coordinates into text and parsing them
	# back out on the far side.  The console and /api/command pass none,
	# which is exactly what makes the vocabulary one vocabulary: a verb
	# that needs geometry simply refuses when it arrives without any.
{
	my ($lpart,$rpart,$data) = @_;
	$lpart = lc($lpart // '');
	$rpart //= '';
	return 0 if !length($lpart);

	$cmd_failed = 0;

	if ($lpart eq 'mark')
	{
		$mark_seq = getOutputRingSeq();
		display(0,0,"mark: $mark_seq");
	}
	elsif ($lpart eq 'version')
	{
		display(0,0,"$appName");
		display(0,1,"app_dir      = $app_dir");
		display(0,1,"data_dir     = $data_dir");
		display(0,1,"temp_dir     = $temp_dir");
		display(0,1,"resource_dir = $resource_dir");
		display(0,1,"packaged     = ".($Cava::Packager::PACKAGED ? 1 : 0));
	}
	elsif ($lpart eq 'prefs')
	{
		my $prefs = getAllPrefs();
		display(0,0,"prefs");
		for my $key (sort keys %$prefs)
		{
			display(0,1,"$key = '$prefs->{$key}'");
		}
	}
	elsif ($lpart eq 'map')
	{
		openMapBrowser();
	}
	elsif ($lpart eq 'dbg')
	{
		_dbgCommand($rpart);
	}
	elsif ($lpart eq 'sources')
	{
		_sourcesCommand();
	}
	elsif ($lpart eq 'source')
	{
		_sourceCommand($rpart);
	}
	elsif ($lpart eq 'tile')
	{
		_tileCommand($rpart);
	}
	elsif ($lpart eq 'cache')
	{
		_cacheCommand($rpart);
	}
	elsif ($lpart eq 'set')
	{
		_setCommand($rpart);
	}
	elsif ($lpart eq 'select')
	{
		_selectCommand($rpart);
	}
	elsif ($lpart eq 'edit')
	{
		_editCommand($rpart);
	}
	elsif ($lpart eq 'regions')
	{
		_regionsCommand();
	}
	elsif ($lpart eq 'region')
	{
		_regionCommand($rpart,$data);
	}
	elsif ($lpart eq 'subregion')
	{
		_subregionCommand($rpart);
	}
	elsif ($lpart eq 'build')
	{
		_buildCommand($rpart);
	}
	elsif ($lpart eq 'check')
	{
		_checkCommand($rpart,1);
	}
	elsif ($lpart eq 'uncheck')
	{
		_checkCommand($rpart,0);
	}
	elsif ($lpart eq '?' || $lpart eq 'help')
	{
		my $entries = commandHelp();
		my $max_sig = 0;
		for my $e (@$entries)
		{
			my $len = length($e->[0]);
			$max_sig = $len if $len > $max_sig;
		}
		display(0,0,"Commands:");
		for my $e (@$entries)
		{
			display(0,1,sprintf("%-*s  %s",$max_sig,$e->[0],$e->[1]));
		}
	}
	else
	{
		warning(0,0,"unknown command '$lpart'  (try ? for help)");
		$cmd_failed = 1;
	}

	return $cmd_failed ? 0 : 1;
}


1;
