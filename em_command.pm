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
use dm_source;
use dm_cache;
use dm_fetch;
use dm_region;
use dm_coverage;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		dispatchCommand
		getMarkSeq
	);
}


my $mark_seq:shared = 0;


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
		[ 'sources',			'list the tile source definitions found in the data dir'	],
		[ 'source <id>',		'show one source in full'									],
		[ 'source rescan',		're-read the .tsd files from the data dir'					],
		[ 'source use <id>',	'make one source the one the map displays'					],
		[ 'tile <id> <z> <x> <y>',	'fetch one tile and report what came back'				],
		[ 'cache [id]',			'what the tile cache holds, by zoom'						],
		[ 'regions',			'list the regions found in the data dir'					],
		[ 'region <id>',		'show one region and its subregions'						],
		[ 'region rescan',		're-read the .region files from the data dir'				],
		[ 'region new <name> [z]',		'create an empty region'							],
		[ 'region rename <id> <name>',	'change a region\'s name (its id never changes)'		],
		[ 'region zoom <id> <z> [sub]',	'set a region or subregion\'s canonical zoom'		],
		[ 'region count [id|all]',		'how many tiles a region would build, by zoom'		],
		[ 'region delete <id>',			'delete a region and its file'						],
		[ 'region import <file> [z]',	'import each KML folder as a region'				],
		[ 'subregion new <region> <name> <lat> <lon> <half_nm> <z>',
										'add a detail area by centre and half extent'		],
		[ 'subregion delete <region> <id>',	'remove a detail area'							],
		[ 'check <id>',			'add a region to the working set (show it on the map)'		],
		[ 'uncheck <id>',		'remove it from the working set'							],
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
		display(0,0,"no sources in $data_dir");
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
			display(0,0,"active source is '".(getActiveSource() || '(default)')."'");
			return;
		}
		if (!getSource($which))
		{
			warning(0,0,"source use: no source with id '$which'");
			return;
		}
		setActiveSource($which);
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
		display(0,$level,sprintf("%-16s z%-2d  %d polygon(s)  %s",
			$sub->{id},$sub->{canonical_zoom},
			scalar(@{$sub->{geometry}}),$sub->{name}));
		_showSubregions($sub,$level+1);
	}
}


sub _regionsCommand
{
	my @ids = getRegionIds();
	if (!@ids)
	{
		display(0,0,"no regions in $data_dir");
		display(0,1,"try 'region import <file.kml>' or 'region new <name>'");
		return;
	}
	display(0,0,"regions");
	for my $id (@ids)
	{
		my $reg = getRegion($id);
		display(0,1,sprintf("%s %-16s z%-2d %d poly %4d pts %s %s",
			isChecked($id) ? '[x]' : '[ ]',
			$id,$reg->{canonical_zoom},
			scalar(@{$reg->{geometry}}),
			regionPointCount($reg),
			scalar(@{$reg->{subregions}}) ?
				sprintf("%d sub",scalar(@{$reg->{subregions}})) : "     ",
			$reg->{name}));
	}
	my @working = getWorkingSet();
	display(0,1,scalar(@working)." of ".scalar(@ids)." in the working set");
}


sub _regionCommand
{
	my ($rpart) = @_;
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
		my ($name,$zoom) = $rest =~ /^(.*?)\s+(\d+)\s*$/ ? ($1,$2) : ($rest,15);
		if ($name !~ /\S/)
		{
			warning(0,0,"region new: a name is required");
			return;
		}
		my $reg = newRegion($name,$zoom);
		if ($reg)
		{
			display(0,0,"region new: created '$reg->{id}' at z$reg->{canonical_zoom}");
			bumpState("region '$reg->{id}' created");
		}
		return;
	}
	if ($verb eq 'rename')
	{
		my ($id,$name) = split(/\s+/,$rest,2);
		if (!defined($name) || $name !~ /\S/)
		{
			warning(0,0,"region rename: usage is 'region rename <id> <new name>'");
			return;
		}
		if (renameRegion($id,$name))
		{
			display(0,0,"region rename: '$id' is now called '$name'");
			bumpState("region '$id' renamed");
		}
		return;
	}
	if ($verb eq 'count')
	{
		my ($id,$zmin,$fill,$zmax) = split(/\s+/,$rest);
		my @ids = (defined($id) && $id ne '' && $id ne 'all') ?
			($id) : getRegionIds();
		$zmin = 10 if !defined $zmin;
		$fill = 1  if !defined $fill;

		display(0,0,"region count   zmin=$zmin fill=$fill".
			(defined $zmax ? " zmax=$zmax" : ''));
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
			my $cov = regionCoverage($reg,
				{ zmin => $zmin, fill => $fill, zmax => $zmax });
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
	if ($verb eq 'zoom')
	{
		my ($id,$zoom,$sub_id) = split(/\s+/,$rest);
		if (!defined($zoom) || $zoom !~ /^\d+$/)
		{
			warning(0,0,"region zoom: usage is 'region zoom <id> <zoom> [subregion]'");
			return;
		}
		my $reg = getRegion($id);
		if (!$reg)
		{
			warning(0,0,"region zoom: no region with id '$id'");
			return;
		}
		my $target = $reg;
		if (defined $sub_id)
		{
			($target) = findSubregion($reg,$sub_id);
			if (!$target)
			{
				warning(0,0,"region zoom: '$id' has no subregion '$sub_id'");
				return;
			}
		}
		$target->{canonical_zoom} = int($zoom);
		return if !saveRegion($reg);
		display(0,0,"region zoom: '$target->{id}' canonical_zoom = $zoom");
		bumpState("'$target->{id}' zoom $zoom");
		return;
	}
	if ($verb eq 'delete')
	{
		my ($id) = split(/\s+/,$rest,2);
		if (deleteRegion($id))
		{
			display(0,0,"region delete: '$id' is gone");
			bumpState("region '$id' deleted");
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
	display(0,0,"region $verb");
	display(0,1,sprintf("%-16s %s",'name',$reg->{name}));
	display(0,1,sprintf("%-16s %s",'file',$reg->{file}));
	display(0,1,sprintf("%-16s %d",'canonical_zoom',$reg->{canonical_zoom}));
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
		my ($parent,$name,$lat,$lon,$half,$zoom) = split(/\s+/,$rest);
		if (!defined($zoom))
		{
			warning(0,0,"subregion new: usage is ".
				"'subregion new <region> <name> <lat> <lon> <half_nm> <zoom>'");
			return;
		}
		my $sub = addSubregion($parent,$name,$lat,$lon,$half,$zoom);
		if ($sub)
		{
			display(0,0,"subregion new: '$sub->{id}' under '$parent' at z$zoom");
			display(0,1,sprintf("a %.1f nm square centred on %.6f %.6f",
				$half*2,$lat,$lon));
			bumpState("subregion '$sub->{id}' added");
		}
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
		($on ? 'in' : 'out of')." the working set");
	bumpState("'$id' ".($on ? 'checked' : 'unchecked'));
}


sub dispatchCommand
{
	my ($lpart,$rpart) = @_;
	$lpart = lc($lpart // '');
	$rpart //= '';
	return if !length($lpart);

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
	elsif ($lpart eq 'regions')
	{
		_regionsCommand();
	}
	elsif ($lpart eq 'region')
	{
		_regionCommand($rpart);
	}
	elsif ($lpart eq 'subregion')
	{
		_subregionCommand($rpart);
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
	}
}


1;
