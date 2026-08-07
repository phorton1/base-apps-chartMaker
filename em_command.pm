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
use dm_keys;
use dm_cache;
use dm_fetch;
use dm_observe;
use dm_engine;
use dm_meta;
use dm_region;
use dm_coverage;
use cm_config;
use dm_fill;
use dm_rct;
use dm_analysis;
use dm_build;
use dm_sample;


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
		[ 'set',				'list the region sets, marking the open one'				],
		[ 'set open <name>',	'open a region set as the document'							],
		[ 'set new <name>',		'create an empty region set and open it'					],
		[ 'set save',			'write the open set - the ONLY thing that writes a region'	],
		[ 'set saveas <name>',	'write it to a new set and continue there'					],
		[ 'set revert [force]',	'every region back to what is on disk'					],
		[ 'set close',			'close it (refuses while dirty)'							],
		[ 'set discard',		'close it, throwing unsaved changes away'					],
		[ 'set dirty',			'what is unsaved, and why'									],
		[ 'regions',			'list the regions in the open set'							],
		[ 'region <id>',		'show one region and its subregions'						],
		[ 'region commit <id>',	'write one region now'										],
		[ 'region revert <id>',	'one region back to what is on disk'						],
		[ 'region new <name> [z]',		'create an empty region'							],
		[ 'region rename <id> <name>',	'change a region\'s name (free text, no structural role)'],
		[ 'region id <id> <new id>',	'change a region\'s id, its file and every set naming it'],
		[ 'region zauthor <id> <z>',	'set the level the polygon is authored at'			],
		[ 'region zmin <id> <z>',		'set the overview floor'							],
		[ 'region zmax <id> <z> [sub]',	'set how deep a region or subregion goes'			],
		[ 'region source <id> <src|none|inherited> [sub]',
										'name the imagery it is BUILT from'					],
		[ 'region count [id|all] [zmax]','how many tiles a region would build, by zoom'		],
		[ 'select <id|none>',	'select a region or subregion, on every surface at once'	],
		[ 'view [<lat> <lon> [z]]','move the open map to a place, or say where it is'	],
		[ 'edit [mode] [id] [dirty]','what the map is doing: browse, shape, draw, end'	],
		[ 'region geometry <id> [sub]',	'replace polygons - /edit only, the map supplies them'],
		[ 'region delete <id>',			'delete a region from the document'						],
		[ 'subregion new <parent> <zmax> <name>',
										'add an empty detail area - draw it on the map'		],
		[ 'subregion delete <region> <id>',	'remove a detail area'							],
		[ 'config',				'the build configuration: what, where, how fast'	],
		[ 'config regions <id,id|all>',	'which regions get fetched and built'		],
		[ 'config out <path|default>',	'where the .rct files go'					],
		[ 'config rate <src> <ms>',		'go no faster than this (on top of the TSD)'],
		[ 'config reset',		'back to defaults, removing build.json'				],
		[ 'analyse [id|set|all]','what a fetch/build would cost - reads nothing else'],
		[ 'meta <id>',			'what a service says about ITSELF - one request, no imagery'],
		[ 'meta <id> <z> <x> <y> [n]',
										'which tiles an n x n block holds, in one request'],
		[ 'sample <tsd> <region>[/<sub>] [zmin zmax] [nodepth]',
										'probe ONE service over an area - is it worth using?'],
		[ 'fetch <id|set|all> [zmax]',	'fill the cache with every tile the build will read'],
		[ 'build rct <id|set> [zmax]',	'fetch, then export region(s) as .rct files'	],
		[ 'build mbtiles <id|set> [zmax]',
										'the same, as one .mbtiles per node'				],
		[ '  --dirty',					'build anyway from unsaved edits'					],
		[ '  --failed',					'export anyway with tiles that never arrived'		],
		[ 'check <id>',			'show a region on the map'									],
		[ 'uncheck <id>',		'hide it from the map (it is still built)'			],
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
	for my $key (qw( name file cache_key url subdomains tile_format
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
	if ($src->{keys})
	{
		display(0,1,sprintf("%-16s %s",'keys',
			join(',',map { $_->{key_name} } @{$src->{keys}})));
	}
}


sub _engineCommand
	# 'engine'          what the pool has been doing
	# 'engine <id>'     and what it would do for one source right now
	#
	# WORTH HAVING BECAUSE THE ENGINE IS OTHERWISE INVISIBLE.  Everything it
	# does is a thing that does NOT happen - a request that waited, a retry
	# that was not made, a source that is backed off - and there is no
	# screen anywhere that a delay shows up on.
{
	my ($rpart) = @_;
	my $stats = engineStats();

	display(0,0,"engine");
	display(0,1,sprintf("%-16s %s",'pool',$stats->{pool} ?
		"$stats->{pool} workers" :
		'not running - fetches happen on the calling thread'));
	display(0,1,sprintf("%-16s %d",'queued',$stats->{queued} || 0));
	display(0,1,sprintf("%-16s %d",$_,$stats->{$_} || 0))
		for grep { defined $stats->{$_} }
			qw( requests retries unretried unpoisoned backoffs
				interactive bulk );
	display(0,1,sprintf("%-16s %s",'backed off',
		$stats->{backed_off} || 'nothing'));

	my ($id) = split(/\s+/,$rpart || '');
	return if !defined($id) || !length($id);

	my $src = getSource($id);
	if (!$src)
	{
		warning(0,0,"engine: no source with id '$id'");
		return;
	}

	# WHAT IT WOULD DO RIGHT NOW, which is not a stored value: it is the
	# composition of the TSD, the two preferences and any live backoff,
	# recomputed on the spot.  That is the number to check against when a
	# fill seems slower or faster than expected.

	display(0,1,'');
	display(0,1,"for '$id'");
	display(0,2,sprintf("%-16s %d ms",'interval',engineInterval($src,0)));
	display(0,2,sprintf("%-16s %d",'concurrency',engineConcurrency($src,0)));

	my $rec = obsRecord($src);
	display(0,2,sprintf("%-16s %d ms",'measured rtt',$rec->{rtt_ms} || 0));
	display(0,2,sprintf("%-16s %d ms",'ms per tile',$rec->{ms_per_tile} || 0));
	display(0,2,sprintf("%-16s %s",'ceiling',$rec->{ceiling} || 'unknown'));
	display(0,2,sprintf("%-16s %s",'seen a 429',$rec->{saw_429} ?
		"yes, at $rec->{saw_429_interval} ms and ".
		"$rec->{saw_429_concurrency} concurrent" : 'no'));
}


sub _metaCommand
	# 'meta <id>'             what the service says about itself
	# 'meta <id> <z> <x> <y> [n]'    which tiles an n x n block holds
	#
	# THE SAME RENDERING THE PANE READS.  metaLines is called here and by
	# winSources, so the console and the window cannot drift -- the same
	# discipline the build report and the analysis already follow.
{
	my ($rpart) = @_;
	my ($id,$z,$x,$y,$n) = split(/\s+/,$rpart);

	if (!defined($id) || !length($id))
	{
		warning(0,0,"meta: usage is 'meta <id>' or ".
			"'meta <id> <z> <x> <y> [block]'");
		return;
	}
	my $src = getSource($id);
	if (!$src)
	{
		warning(0,0,"meta: no source with id '$id'");
		return;
	}

	# THE PLACED FORM IS A DIFFERENT ACT and is only offered where the
	# family supports it, which is why it refuses rather than falling back
	# to fetching the tiles one at a time.

	if (defined $y)
	{
		$n ||= 8;
		my $tm = metaTilemap($src,$z,$x,$y,$n,$n);
		if (!$tm->{ok})
		{
			warning(0,0,"meta: $tm->{reason}");
			return;
		}
		display(0,0,"meta $id tilemap $z/$x/$y ${n}x${n}");
		display(0,1,"$tm->{count_present} of $tm->{count_total} present ".
			"in $tm->{ms} ms, one request");

		# The block drawn as it lies on the ground: row major, north at
		# the top, which is the only reading of a coverage answer that is
		# worth having in a console.

		for my $r (0..$n-1)
		{
			my @row = @{$tm->{present}}[$r*$n .. $r*$n+$n-1];
			display(0,2,join('',map { $_ ? '#' : '.' } @row));
		}
		return;
	}

	display(0,1,$_) for @{metaLines(metaSource($src))};
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

	# REDACTED, because this is a console a person is reading and may well
	# be pasting into a bug report.  And the two reasons a url can be
	# missing are told apart, since one of them is fixable in the key store
	# and the other is a fact about the service.

	my $why;
	my $url = sourceTileUrl($src,$z,$x,$y,\$why);
	display(0,0,"tile $id $z/$x/$y");
	display(0,1,"url    ".(defined($url) ? keyRedact($url) :
		($why || '(none - outside the declared zoom range)')));

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


sub _fetchCommand
	# fetch <id|set|all> [zmax]
	#
	# The cache filler.  It exists because dm_rct fetches nothing: a build
	# over ground that has never been displayed writes a file full of
	# absences that the plotter papers over by overzooming, which looks
	# soft rather than broken and is therefore not noticed until somebody
	# is out there relying on it.
	#
	# 'set' and 'all' mean the same thing they mean to build - every region
	# file in the open set, because the files present ARE the set.
{
	my ($rest) = @_;
	my ($which,$zmax) = split(/\s+/,$rest || '');
	$which = 'set' if !defined($which) || $which !~ /\S/;

	if (defined($zmax) && ($zmax !~ /^\d+$/ || $zmax > 22))
	{
		warning(0,0,"fetch: '$zmax' is not a zoom level");
		return;
	}

	my $set = openSetName();
	if (!$set)
	{
		warning(0,0,"fetch: there is no region set open");
		return;
	}

	my $cfg = buildConfig();
	my @ids =
		$which eq 'all' ? getRegionIds() :
		$which eq 'set' ? configSelectedIds($cfg) : ($which);

	if (!@ids)
	{
		warning(0,0,"fetch: nothing to fetch");
		return;
	}

	# NO SOURCE IS NAMED HERE.  A region names the source it is built from
	# and a subregion may name its own, and that is the whole of the
	# answer.  This used to refuse unless a source was SELECTED FOR DISPLAY
	# and then pass it down as the fallback for anything that had not
	# chosen - so a set in which nothing had chosen fetched thousands of
	# tiles from the viewer's basemap.  fillCoverage refuses instead, and
	# says which nodes.

	display(0,0,"fetch ".join(', ',@ids).
		(defined $zmax ? " capped at z$zmax" : ''));

	my $stats = fillCoverage(\@ids,{
		config   => $cfg,
		defined $zmax ? ( zmax => $zmax ) : (),
	});

	return if $stats->{refused};		# fillCoverage has said why

	display(0,0,sprintf("%s%d tiles in %.1fs - %d fetched, %d already cached, ".
		"%d absent, %d errors",
		$stats->{aborted} ? 'ABORTED after ' : '',
		$stats->{tiles},$stats->{secs},
		$stats->{tiles} - $stats->{cached},$stats->{cached},
		$stats->{absent},$stats->{error}));
}


sub _sampleCommand
	# sample <tsd> <region>[/<sub>] [zmin zmax]
	#
	# THE SUBJECT IS THE TSD AND THE REGION IS ONLY WHERE TO LOOK.  Nothing
	# of the region's own levels or assigned source is used: once a region
	# names those, the BUILD answers coverage exactly within them, and
	# sampling would re-derive a thing already known precisely.
	#
	# 'sample' IS THE VERB AND PROBE IS THE FEATURE.  Asking a service what
	# it says about ITSELF is 'meta' - placeless, one request, no imagery.
	# This is the placed question, it costs hundreds of requests, and it is
	# what a person means by probing.  The two were both called probe once,
	# which made every sentence about either of them ambiguous.
	#
	# THE CONSOLE FACE OF PROBE MODE, because the vocabulary rule says
	# nothing may be reachable only from a dialog - and because it makes
	# the sampler drivable with no wx at all, which is what lets the marks
	# be checked without anybody looking at a map.
{
	my ($rest) = @_;
	$rest = '' if !defined $rest;

	# 'nodepth' IS TAKEN OFF THE LINE BEFORE ANYTHING IS PARSED, so it can
	# be written anywhere after the source and never has to be defended
	# against by the zoom validator below.

	my $depth = 1;
	$depth = 0 if $rest =~ s/\s*\bnodepth\b\s*/ /;

	my ($tsd,$where,$zmin,$zmax) = split(/\s+/,$rest);

	# STOP AND END ARE VERBS OF THE MODE, not of a source, so they take no
	# area and no range.  They exist because the map has no other way to
	# halt a run or leave the mode: its palette is the probe's only
	# furniture there, and a mode nothing can leave from the surface it is
	# drawn on is the same hole the console version had.

	if (defined($tsd) && $tsd eq 'stop')
	{
		probeRequestStop();
		display(0,0,"probe halted - the marks stay");
		return;
	}
	if (defined($tsd) && ($tsd eq 'end' || $tsd eq 'off'))
	{
		probeRequestStop();
		probeSetMode(0);
		display(0,0,"probe mode ended");
		return;
	}

	if (!$tsd || !$where)
	{
		_fail("sample: 'sample <tsd> <region>[/<sub>] [zmin zmax]'");
		display(0,1,"installed sources: ".join(', ',getSourceIds()));
		return;
	}
	if (!getSource($tsd))
	{
		_fail("sample: no source with id '$tsd'");
		return;
	}
	for my $z ($zmin,$zmax)
	{
		next if !defined $z;
		if ($z !~ /^\d+$/ || $z > 24)
		{
			_fail("sample: '$z' is not a zoom level");
			return;
		}
	}
	if (!openSetName())
	{
		_fail("sample: there is no region set open");
		return;
	}

	# ONE RUN AT A TIME, from every door.  Two samplers publishing into one
	# result set would double every row of whichever source they shared.

	if (probeRunning())
	{
		_fail("sample: a probe is already running - stop it first");
		return;
	}

	my ($region,$sub) = split(m{/},$where,2);
	my $scope = { region => $region, $sub ? ( sub => $where ) : () };
	my ($polys,$label) = sampleScope($scope);
	if (!$polys)
	{
		_fail("sample: '$where' is not a region or subregion here");
		return;
	}

	probeSetMode(1);
	display(0,0,"sample $tsd over $label".
		(defined $zmin ? " z$zmin-".($zmax // '?') : ''));

	my $prog = newProgress(1,'');
	$prog->{active} = 1;

	# DEPTH IS ON, and the dialog agrees.  It was off because the measure
	# behind it was unvalidated and would have filled a column with a
	# confident wrong number; the measure is a different one now and it has
	# a fixed point - a manufactured magnification reads 1.00.  What it
	# costs is a second fetch per sample and about a tenth of a second of
	# cpu, which is a price and not a doubt, so 'nodepth' turns it off.

	threads->create(\&dm_sample::sampleWorker,$prog,[$tsd,$scope],{
		report	=> 1,
		depth	=> $depth,
		defined $zmin ? ( zmin => $zmin ) : (),
		defined $zmax ? ( zmax => $zmax ) : () })->detach();
}


sub _configCommand
	# config                        show it
	# config regions <id,id|all>    what gets fetched and built
	# config out <path|default>     where the .rct files go
	# config rate <source> <ms>     go no faster than this, on top of the TSD
	# config reset                  back to defaults, removing the file
	#
	# THE CONSOLE FACE OF THE PREFLIGHT'S FIRST DIALOG.  It exists so that
	# the configuration is not a thing only a dialog can reach - the whole
	# vocabulary rule of this application - and so that a test can set one
	# up without wx.
{
	my ($rest) = @_;
	my ($verb,@args) = split(/\s+/,$rest || '');
	$verb = '' if !defined $verb;

	if (!openSetName())
	{
		warning(0,0,"config: there is no region set open");
		return;
	}

	my $cfg = buildConfig();

	if ($verb eq '')
	{
		my @sel = configSelectedIds($cfg);
		display(0,0,"build configuration for '".openSetName()."'");
		display(0,1,"regions   : ".(defined $cfg->{regions} ?
			join(', ',@sel) : 'ALL ('.join(', ',@sel).')'));
		display(0,1,"out_dir   : ".($cfg->{out_dir} ||
			defaultOutDir().'   (the default)'));
		display(0,1,"exists    : ".(-d ($cfg->{out_dir} || defaultOutDir()) ?
			'yes' : 'NO'));
		for my $sid (sort keys %{$cfg->{rates}})
		{
			display(0,1,"rate      : $sid $cfg->{rates}{$sid} ms");
		}
		display(0,1,"(all default - no build.json is written)")
			if configIsDefault($cfg);
		return;
	}

	if ($verb eq 'regions')
	{
		my $spec = join(',',@args);
		if ($spec !~ /\S/)
		{
			warning(0,0,"config regions: usage 'config regions <id,id|all>'");
			return;
		}

		if (lc($spec) eq 'all')
		{
			$cfg->{regions} = undef;
		}
		else
		{
			my @want = grep { /\S/ } split(/,/,$spec);
			my %known = map { lc($_) => $_ } getRegionIds();
			my @bad = grep { !$known{lc($_)} } @want;
			if (@bad)
			{
				warning(0,0,"config regions: no such region(s): ".
					join(', ',@bad));
				return;
			}
			$cfg->{regions} = [ map { $known{lc($_)} } @want ];
		}
	}
	elsif ($verb eq 'out')
	{
		my $path = join(' ',@args);
		if ($path !~ /\S/)
		{
			warning(0,0,"config out: usage 'config out <path|default>'");
			return;
		}
		if (lc($path) eq 'default')
		{
			$cfg->{out_dir} = '';
		}
		else
		{
			$path =~ s{\\}{/}g;
			$path =~ s{/+$}{};

			# A CHOSEN FOLDER MUST ALREADY EXIST.  The application creates
			# only the folder it chose the location of - see dm_build.

			if (!-d $path)
			{
				warning(0,0,"config out: '$path' does not exist - ".
					"chartMaker creates only the folder it chose itself");
				return;
			}
			$cfg->{out_dir} = ($path eq defaultOutDir()) ? '' : $path;
		}
	}
	elsif ($verb eq 'rate')
	{
		my ($sid,$ms) = @args;
		if (!defined($sid) || !defined($ms) || $ms !~ /^\d+$/)
		{
			warning(0,0,"config rate: usage 'config rate <source> <ms>'");
			return;
		}
		if (!getSource($sid))
		{
			warning(0,0,"config rate: no source '$sid'");
			return;
		}
		$ms ? ($cfg->{rates}{$sid} = int($ms)) : delete($cfg->{rates}{$sid});
	}
	elsif ($verb eq 'reset')
	{
		$cfg = { regions => undef, out_dir => '', rates => {} };
	}
	else
	{
		warning(0,0,"config: unknown '$verb' - regions, out, rate, reset");
		return;
	}

	saveBuildConfig($cfg);
	_configCommand('');
}


sub _analyseCommand
	# analyse [id|set|all] [zmax]
	#
	# The console face of the preflight's SECOND dialog.  Reads
	# directories and .rct headers, touches no network, writes nothing.
{
	my ($rest) = @_;
	my ($which,$zmax) = split(/\s+/,$rest || '');
	$which = 'set' if !defined($which) || $which !~ /\S/;

	if (!openSetName())
	{
		warning(0,0,"analyse: there is no region set open");
		return;
	}

	my $cfg = buildConfig();
	my @ids =
		$which eq 'all' ? getRegionIds() :
		$which eq 'set' ? configSelectedIds($cfg) : ($which);
	if (!@ids)
	{
		warning(0,0,"analyse: nothing to analyse");
		return;
	}

	my $out_dir = $cfg->{out_dir} || defaultOutDir();
	my $an = analyseFetch(\@ids,{
		config   => $cfg,
		out_dir  => $out_dir,
		defined($zmax) && $zmax =~ /^\d+$/ ? ( zmax => int($zmax) ) : (),
	});

	display(0,0,$_) for @{analysisLines($an,'build')};
	display(0,0,sprintf("(analysed in %.3fs)",$an->{elapsed}));

	# THE FAULTS BESIDE THE COUNTS, not inside them, which is exactly what
	# the preflight dialog does with the same two structures.  An analysis
	# says what a run would cost; a refusal is a different kind of
	# statement and reads as one.

	if (@{$an->{faults} || []})
	{
		warning(0,0,"this cannot be built as it stands:");
		display(0,1,$_) for faultLines($an->{faults});
	}

	if ($an->{zagree})
	{
		warning(0,0,"these .rct files would NOT agree with each other:");
		for my $field (qw( zauthor zmin ))
		{
			my $h = $an->{zagree}{$field} or next;
			display(0,1,"$field $_ : ".join(', ',@{$h->{$_}})) for sort keys %$h;
		}
	}
	if (@{$an->{geometry} || []})
	{
		warning(0,0,"these break a containment rule and would build ground ".
			"the plotter can never reveal:");
		display(0,1,"$_->{id}: $_->{why}") for @{$an->{geometry}};
	}

	if ($an->{source_conflicts})
	{
		warning(0,0,"these would be built from different sources over the ".
			"same ground:");
		my $c = $an->{source_conflicts};
		for my $pair (sort keys %$c)
		{
			my $it = $c->{$pair};
			my @z  = sort { $a <=> $b } keys %{$it->{levels}};
			display(0,1,sprintf("%s : %d tile(s) at z%s, from %s",
				$pair,$it->{tiles},
				(@z > 1 ? $z[0].'-'.$z[-1] : $z[0]),
				join(' and ',sort keys %{$it->{sources}})));
		}
		display(0,1,"the plotter shows one of them and which one is not ".
			"predictable");
	}

	display(0,1,"will REPLACE : $_->{leaf}") for @{$an->{overwrite}};
	display(0,1,"NOT in build : $_->{leaf}") for @{$an->{foreign}};
}


sub _buildCommand
	# build <rct|mbtiles> <id|set|all> [zmax]
	#
	# 'set' MEANS THE WHOLE ACTIVE SET, not the checked part of it.  The
	# set is a folder and every region file in it is part of the build,
	# because THE SET OF FILES PRESENT IS THE SET OF REGIONS - in the output
	# there is no manifest, and there is none here either.  Checking a
	# region hides it from the map while you work; it has never been a
	# statement about what belongs in it, and 'all' is now the same
	# thing said twice.
{
	my ($rest) = @_;
	$rest = '' if !defined($rest);

	# The overrides come out FIRST, or '--dirty' lands in the zmax slot
	# and is reported as not being a zoom level.

	my $allow_dirty  = $rest =~ s/\s*--dirty\b//  ? 1 : 0;
	my $allow_failed = $rest =~ s/\s*--failed\b// ? 1 : 0;

	my ($what,$which,$zmax) = split(/\s+/,$rest);

	# THE FORMAT IS A WORD IN THE COMMAND, not a flag, because it is what
	# the command IS.  dm_build knows which ones exist; this asks it rather
	# than carrying a second list that could fall behind.

	my %known = map { $_ => 1 } buildFormats();
	if (!defined($what) || !$known{$what})
	{
		warning(0,0,"build: usage is 'build <".join('|',buildFormats()).
			"> <id|set|all> [zmax] [--dirty] [--failed]'");
		return;
	}
	$which = 'set' if !defined($which) || $which !~ /\S/;

	my $set = openSetName();
	if (!$set)
	{
		warning(0,0,"build $what: there is no region set open");
		return;
	}

	# 'set' MEANS THE CONFIGURED SELECTION, 'all' MEANS EVERY REGION.  They
	# used to be the same word twice; now they are the two useful answers.
	# A configuration that selects nothing in particular makes them
	# identical again, which is the common case and is why 'set' is the
	# default.

	my $cfg = buildConfig();
	my @ids =
		$which eq 'all' ? getRegionIds() :
		$which eq 'set' ? configSelectedIds($cfg) : ($which);

	if (!@ids)
	{
		warning(0,0,"build $what: nothing to build");
		return;
	}

	if (defined($zmax) && ($zmax !~ /^\d+$/ || $zmax > 22))
	{
		warning(0,0,"build $what: '$zmax' is not a zoom level");
		return;
	}

	# NO SOURCE IS NAMED HERE, for the reason 'fetch' gives: what a region
	# is built from is on the region, and what the map is showing has
	# nothing to do with it.  dm_build refuses a tree that has not decided,
	# and names the nodes.

	# THE CONSOLE DRIVES THE SAME ACT THE MENU DOES, with no dialog and no
	# thread.  Everything that decides anything is in dm_build, so "run it
	# from the console to see what really happened" stays true rather than
	# being a second implementation that can disagree.
	#
	# --dirty and --failed are the overrides, spelled out rather than
	# offered as buttons, because on this surface there is nobody to ask.

	# THE CONFIGURED OUTPUT FOLDER BELONGS TO THE .rct BUILD, and only to it.
	# It is where the files an E-Series card will carry get assembled,
	# chosen once and
	# remembered per set; an mbtiles build has no business landing a tree
	# of region folders in the middle of it.  So mbtiles takes its own
	# default and the configuration is left saying what it has always said.

	my $report = buildOutput(\@ids,{
		config       => $cfg,
		out_dir      => ($what eq 'rct' ? $cfg->{out_dir} : ''),
		allow_dirty  => $allow_dirty,
		allow_failed => $allow_failed,
		defined $zmax ? ( zmax => int($zmax) ) : (),
	},$what);

	display(0,0,$_) for @{buildReportLines($report)};

	$cmd_failed = 1 if !$report->{ok};
}


sub _regionsCommand
{
	my $set = openSetName();
	if (!$set)
	{
		display(0,0,"there is no region set open");
		display(0,1,"try 'set new <name>'");
		return;
	}

	my @ids = getRegionIds();
	if (!@ids)
	{
		display(0,0,"no regions in set '$set'");
		display(0,1,"try 'region new <name>'");
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
		" shown on the map - ALL ".scalar(@ids)." are built");
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
	# Validation is dm_region's, not this module's.  stageRegion validates
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

	if (!stageRegion($reg))
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


sub _viewCommand
	# view [<lat> <lon> [<zoom>]]
	#
	# THE ONE THING THE CONSOLE COULD NOT SAY.  Every other verb names an
	# object, and a place is not an object - so the only way to get the map
	# somewhere was to drag it there, which is no way to reach a coordinate
	# read off a chart or a pilot book.
	#
	# THE ZOOM IS OPTIONAL AND DEFAULTS TO WHERE THE MAP ALREADY IS, because
	# "go here" and "go here at this scale" are different requests and the
	# first one is the common one.
	#
	# IT REFUSES WHEN NO MAP IS OPEN rather than holding the request for one.
	# See cm_state: a place is the one thing in this application that must
	# not be delivered stale.
	#
	# WITH NO ARGUMENTS IT REPORTS INSTEAD OF MOVING, which is the same verb
	# rather than a second one because it is the same question in the two
	# directions a place can travel.  The map is the only thing here that
	# knows where it is, and anybody who cannot see the screen - a console
	# session, a script, somebody being shown something - otherwise has no
	# way at all to ask.
{
	my ($rpart) = @_;
	my @args = grep { $_ ne '' } split(/\s+/,$rpart || '');
	my ($lat,$lon,$z) = @args;

	return _fail("view: the map is not open")
		if !mapIsOpen();

	if (!@args)
	{
		my ($at_lat,$at_lon,$at_z) = getMapView();
		return _fail("view: the map has not said where it is yet")
			if !defined($at_z);
		display(0,0,"view: at $at_lat,$at_lon z$at_z");
		return;
	}

	return _fail("view: usage - view [<lat> <lon> [z]]")
		if @args < 2 || @args > 3;

	# 85 is the mercator limit and is the same bound noteView applies to
	# what comes back the other way; 22 is the applet's MAP_MAX_ZOOM.

	return _fail("view: '$lat' is not a latitude")
		if $lat !~ /^-?\d+(\.\d+)?$/ || $lat < -85 || $lat > 85;
	return _fail("view: '$lon' is not a longitude")
		if $lon !~ /^-?\d+(\.\d+)?$/ || $lon < -180 || $lon > 180;
	return _fail("view: '$z' is not a zoom level")
		if defined($z) && ($z !~ /^\d+$/ || $z > 22);

	if (!defined($z))
	{
		my (undef,undef,$at_z) = getMapView();
		return _fail("view: the map has not said where it is yet")
			if !defined($at_z);
		$z = $at_z;
	}

	requestView($lat,$lon,$z);
	display(0,0,"view: $lat,$lon at z$z");
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

	if ($verb eq 'commit')
	{
		my ($id) = split(/\s+/,$rest,2);
		return _fail("region commit: which region?") if !$id;
		return $cmd_failed = 1 if !commitRegion($id);
		display(0,0,"region commit: '$id' written");
		bumpState("region '$id' committed");
		return;
	}
	if ($verb eq 'revert')
	{
		my ($id) = split(/\s+/,$rest,2);
		return _fail("region revert: which region?") if !$id;

		my $what = revertRegion($id);
		return $cmd_failed = 1 if !$what;
		display(0,0,"region revert: '$id' ".($what eq 'removed' ?
			"had never been saved - it is gone" : "is back to what is on disk"));
		bumpState("region '$id' reverted");
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
		if (!stageRegion($reg))
		{
			$target->{$verb} = $was;
			$cmd_failed = 1;
			return;
		}
		display(0,0,"region $verb: '$target->{id}' $verb = $zoom");
		bumpState("'$target->{id}' $verb $zoom");
		return;
	}
	if ($verb eq 'source')
	{
		# region source <id> <source|none|inherited> [<subregion>]
		#
		# THE ONE FIELD THE CONSOLE COULD NOT SET.  Every other property of
		# a region had a verb and this did not, so the single act the whole
		# model now insists on - naming the imagery a region is built from -
		# could only be performed by clicking a combo box in one pane.  A
		# vocabulary that cannot express the mandatory step is not the same
		# vocabulary the interface has.
		#
		# 'none' RATHER THAN AN EMPTY ARGUMENT, because a trailing space is
		# not a statement.  Clearing a source is a deliberate act - it puts
		# the region back to undecided - and it has to look like one.

		my ($id,$src_id,$sub_id) = split(/\s+/,$rest);
		return _fail("region source: usage is 'region source <id> ".
			"<source|none|inherited> [<subregion>]'")
			if !defined($src_id) || $src_id !~ /\S/;

		my $reg = getRegion($id);
		return _fail("region source: no region with id '$id'") if !$reg;

		my $target = $reg;
		if (defined($sub_id) && $sub_id =~ /\S/)
		{
			(undef,$target) = findAnywhere($sub_id);
			return _fail("region source: '$id' has no subregion '$sub_id'")
				if !$target || $target == $reg;
		}

		$src_id = ''					if lc($src_id) eq 'none';
		$src_id = $SOURCE_INHERITED		if lc($src_id) eq $SOURCE_INHERITED;

		return _fail("region source: only a subregion may inherit - a ".
			"region names one outright or names none")
			if $src_id eq $SOURCE_INHERITED && $target == $reg;

		# REFUSED HERE, WITH THE REASON, rather than accepted and refused by
		# the next build.  A dangling id is legitimate on a region that
		# ARRIVED that way - see dm_region - but naming one deliberately,
		# now, on this machine, is a typo every time.

		if ($src_id ne '' && $src_id ne $SOURCE_INHERITED)
		{
			my $state = sourceState($src_id,'build');
			return _fail("region source: ".sourceStateText($src_id,$state))
				if $state ne $SRC_OK;
		}

		my $was      = $target->{source};
		my $was_name = $target->{source_name};
		$target->{source} = $src_id;
		$target->{source_name} = ($src_id eq '' ||
								  $src_id eq $SOURCE_INHERITED) ? '' :
								 (getSource($src_id)->{name} // '');

		if (!stageRegion($reg))
		{
			$target->{source}      = $was;
			$target->{source_name} = $was_name;
			$cmd_failed = 1;
			return;
		}
		display(0,0,"region source: '$target->{id}' is built from ".
			($src_id eq '' ? '(none)' : "'$src_id'"));
		bumpState("'$target->{id}' source ".($src_id || 'none'));
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

	# THE SOURCE, AND WHETHER IT RESOLVES.  An id naming nothing installed
	# is the normal condition of a set that arrived from somebody else, so
	# it is reported rather than treated as damage - and the remembered
	# name is all such a set has left to say where its tiles came from.

	my $src = getSource($reg->{source});
	display(0,1,sprintf("%-16s %s%s",'source',$reg->{source},
		$src ? "  ($src->{name})" :
			"  *** NOT INSTALLED ***".
			(($reg->{source_name} // '') =~ /\S/ ?
				" - was called '$reg->{source_name}'" : '')));

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
	# set                   - list the sets, marking the open one
	# set open <name>       - close what is open and open that one
	# set new <name>        - create one and open it
	# set save              - write the open set
	# set saveas <name>     - write it to a new set and continue there
	# set close             - close it
	# set dirty             - what is unsaved, and why
	# set discard           - close or open WITHOUT saving
	#
	# A SET IS A DOCUMENT and these are its File menu, in the vocabulary
	# rather than only on a menu bar, so a test can drive the whole cycle.
	#
	# NOTHING HERE DISCARDS WORK SILENTLY.  open and close refuse while the
	# document is dirty and say so; 'set discard' is the way to say it was
	# meant, and it is a separate word because a refusal that can be
	# cleared by repeating the command is not a refusal.
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
		my $open = openSetName();
		display(0,0,"region sets");
		for my $n (@names)
		{
			my $dir = setDir($n);
			my @regions = glob("$dir/*.region");
			display(0,1,sprintf("%s %-16s %d region(s)",
				$n eq $open ? '->' : '  ',$n,scalar(@regions)));
		}
		display(0,1,"nothing is open") if !$open;
		return;
	}

	if ($verb eq 'dirty')
	{
		if (!setIsOpen())
		{
			display(0,0,"no set is open");
			return;
		}
		if (!isSetDirty())
		{
			display(0,0,"'".openSetName()."' has no unsaved changes");
			return;
		}
		my @ids = dirtyRegionIds();
		display(0,0,"'".openSetName()."' has unsaved changes");
		display(0,1,"$_ - edited") for @ids;
		display(0,1,"regions have been created, deleted or renamed")
			if !@ids;
		return;
	}

	if ($verb eq 'revert')
	{
		# EVERY REGION BACK TO THE FOLDER, in one step - the set-level
		# partner of 'region revert'.  Re-reading the files and reverting
		# are the same act now that the document is what is edited, so
		# there is one verb for it rather than a rescan that happens to
		# have that effect.

		return _fail("set revert: no set is open") if !setIsOpen();
		return _fail("set revert: this throws away unsaved changes to '".
			openSetName()."' - 'set save' first, or 'set revert force'")
			if isSetDirty() && ($name || '') !~ /^\s*force\s*$/i;

		my $found = revertSet();
		display(0,0,"reverted '".openSetName()."' - $found region".
			($found == 1 ? '' : 's')." re-read from disk");
		bumpState("set reverted");
		return;
	}

	if ($verb eq 'save')
	{
		return _fail("set save: no set is open") if !setIsOpen();
		return if !saveSet();
		display(0,0,"saved '".openSetName()."'");
		bumpState("set '".openSetName()."' saved");
		return;
	}

	if ($verb eq 'saveas')
	{
		return _fail("set saveas: no set is open") if !setIsOpen();
		return _fail("set saveas: what name?")
			if !defined($name) || $name !~ /\S/;
		return if !saveSetAs($name);
		display(0,0,"saved as '$name', which is now open");
		bumpState("set saved as '$name'");
		return;
	}

	if ($verb eq 'close' || $verb eq 'discard')
	{
		return _fail("set close: no set is open") if !setIsOpen();
		return _fail("set close: '".openSetName()."' has unsaved changes - ".
			"'set save' first, or 'set discard' to throw them away")
			if $verb eq 'close' && isSetDirty();

		my $was = openSetName();
		closeSet();
		display(0,0,"closed '$was'");
		bumpState("set '$was' closed");
		return;
	}

	if ($verb eq 'open')
	{
		return _fail("set open: which set?") if !defined($name) || $name !~ /\S/;
		return _fail("set open: there is no set named '$name'")
			if !setExists($name);
		return _fail("set open: '".openSetName()."' has unsaved changes - ".
			"'set save' first, or 'set discard' to throw them away")
			if setIsOpen() && isSetDirty();

		openSet($name);
		display(0,0,"opened '".openSetName()."'");
		bumpState("set '$name' opened");
		return;
	}

	if ($verb eq 'new')
	{
		return _fail("set new: what name?") if !defined($name) || $name !~ /\S/;
		return _fail("set new: '".openSetName()."' has unsaved changes - ".
			"'set save' first, or 'set discard' to throw them away")
			if setIsOpen() && isSetDirty();

		return if !newSet($name);
		openSet($name);
		display(0,0,"created set '$name', now open");
		bumpState("set '$name' created");
		return;
	}

	warning(0,0,"set: expected open, new, save, saveas, revert, close, discard or dirty");
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

	# A VERB THAT ACTS ON THE DOCUMENT REFUSES WHEN THERE IS NO DOCUMENT,
	# and it refuses HERE, once, from a list.
	#
	# These used to refuse from the bottom of the model or not at all.
	# 'region new' with nothing open reached dm_region::stageRegion and
	# came back with "stageRegion: no region set is open" - the name of an
	# internal function, and a sentence about the mechanism rather than
	# about what the user had just tried to do.  The map's own Create
	# Region ran into exactly that.
	#
	# ONE TABLE RATHER THAN A GUARD IN EACH, because they were not in each:
	# 'set' had one, 'fetch' and 'analyse' and 'build' had one against the
	# wrong thing, and 'region', 'subregion', 'select', 'check' and
	# 'uncheck' had none at all.  Scattered, the answer was different in
	# five places and absent in five more.
	#
	# 'set' IS NOT IN THE LIST, and neither is 'view' or 'edit'.  set open
	# and set new are how you get a document in the first place; view is
	# about the map; edit is the applet reporting what IT is doing, which
	# it may legitimately do while the document is being closed underneath
	# it.

	my %needs_set = map { $_ => 1 } qw(
		regions region subregion select check uncheck
		config analyse fetch build sample );

	if ($needs_set{$lpart} && !setIsOpen())
	{
		return _fail("$lpart: there is no region set open - ".
			"'set open <name>' or 'set new <name>' first");
	}

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
	elsif ($lpart eq 'meta')
	{
		_metaCommand($rpart);
	}
	elsif ($lpart eq 'engine')
	{
		_engineCommand($rpart);
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
	elsif ($lpart eq 'view')
	{
		_viewCommand($rpart);
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
	elsif ($lpart eq 'fetch')
	{
		_fetchCommand($rpart);
	}
	elsif ($lpart eq 'sample')
	{
		_sampleCommand($rpart);
	}
	elsif ($lpart eq 'config')
	{
		_configCommand($rpart);
	}
	elsif ($lpart eq 'analyse' || $lpart eq 'analyze')
	{
		_analyseCommand($rpart);
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
