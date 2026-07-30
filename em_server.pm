#!/usr/bin/perl
#---------------------------------------------
# em_server.pm
#---------------------------------------------
# The chartMaker HTTP server.  Extends Pub::HTTP::ServerBase.
#
# Serves the Leaflet applet from $resource_dir/site, and the /api
# endpoints that make the running application drivable from outside:
#
#   /api/command?cmd=<command>   - dispatch through em_command
#   /api/log?tail=N              - last N output-ring entries (default 2000)
#   /api/log?since=<seq>         - entries after a sequence number
#   /api/log?since=mark          - entries after the last 'mark' command
#
# The useful loop is: cmd=mark, do something, then since=mark -- which
# returns the output of exactly that one action and nothing before it.
#
# HTTP port comes from the HTTP_PORT pref: dev 9884, packaged 9874, so a
# development and an installed chartMaker can run side by side.

package em_server;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP qw(encode_json);
use Pub::Utils;
use Pub::HTTP::ServerBase;
use Pub::HTTP::Response qw(http_ok);
use cm_defs;
use cm_prefs;
use cm_state;
use dm_set;
use dm_source;
use dm_fetch;
use dm_cache;
use dm_region;
use dm_coverage;
use em_command;
use base qw(Pub::HTTP::ServerBase);


our $dbg_request:shared = 0;	# 0=wip; -1=request header
	# 'our' so the 'dbg' command can find it in the symbol table;
	# ':shared' so a change made from an HTTP client thread is seen
	# by every other thread, including the wx main thread.

my $cm_server;


sub startServer
{
	$cm_server = em_server->new();
	display(0,0,"starting em_server on port ".getPref($PREF_HTTP_PORT));
	$cm_server->start();
	display(0,0,"em_server started");
}


sub new
{
	my ($class) = @_;

	# HTTP_PORT's default lives here and is published to the prefs hash so
	# that getPref($PREF_HTTP_PORT) is its canonical read; a prefs-file
	# HTTP_PORT wins, because set-if-absent skips it.

	setPref($PREF_HTTP_PORT, $Cava::Packager::PACKAGED ? 9874 : 9884)
		if !defined getPref($PREF_HTTP_PORT);

	my $params = {
		HTTP_PORT				=> getPref($PREF_HTTP_PORT),
		HTTP_DOCUMENT_ROOT		=> "$resource_dir/site",
		HTTP_GET_EXT_RE			=> 'html|js|css|png',
		HTTP_DEFAULT_LOCATION	=> '/map.html',
		HTTP_MAX_THREADS		=> 4,
		HTTP_KEEP_ALIVE			=> 0,

		# The applet's high-frequency traffic is bumped two debug levels
		# so it does not show.  A single map view is dozens of tile
		# requests, and logging each one would push everything worth
		# reading out of the output ring within seconds of panning.
		# /api/command and /api/log stay visible, which is the traffic
		# anyone is actually watching.

		HTTP_DEBUG_QUIET_RE		=> '^/(tile|state|poll)',
	};
	return $class->SUPER::new($params);
}


sub handle_request
{
	my ($this,$client,$request) = @_;
	my $uri = $request->{uri} || '';

	display($dbg_request+1,0,"request method=$request->{method} uri=$uri");

	# /api/... is the drive surface -- the console vocabulary over HTTP,
	# which is what tests and a developer call by hand.  Everything else
	# is the applet's own protocol, a private contract between this
	# module and _res/site, free to change whenever the applet does.

	if ($uri eq '/api/command')
	{
		return $this->api_command($request)
	}
	elsif ($uri eq '/api/log')
	{
		return $this->api_log($request)
	}
	elsif ($uri eq '/poll')
	{
		# THE ONE PLACE THE APPLICATION LEARNS THE MAP IS THERE.  Nothing
		# else is recorded and no session is created - see cm_state.

		notePoll();
		return $this->api_json_response($request,{ version => 0 + getStateSeq() })
	}
	elsif ($uri eq '/state')
	{
		return $this->applet_state($request)
	}
	elsif ($uri eq '/coverage')
	{
		return $this->applet_coverage($request)
	}
	elsif ($uri eq '/counts')
	{
		return $this->applet_counts($request)
	}
	elsif ($uri eq '/edit')
	{
		return $this->applet_edit($request)
	}
	elsif ($uri =~ m{^/tile/([a-z0-9_-]+)/(\d+)/(\d+)/(\d+)$})
	{
		return $this->applet_tile($request,$1,$2,$3,$4)
	}

	return $this->SUPER::handle_request($client,$request);
}


#---------------------------------------------
# /api/* endpoints
#---------------------------------------------

sub api_json_response
{
	my ($this,$request,$data) = @_;
	my $json     = encode_json($data);
	my $response = http_ok($request,$json);
	$response->{headers}{'content-type'} = 'application/json';
	return $response;
}


sub api_command
	# GET /api/command?cmd=<command>
	# Dispatches through em_command; poll /api/log for the output.
{
	my ($this,$request) = @_;
	my $params = $request->{params} || {};
	my $cmd    = $params->{cmd} || '';
	my $ok     = 0;
	if ($cmd)
	{
		my ($lpart,$rpart) = split(/\s+/,$cmd,2);
		$rpart //= '';
		dispatchCommand($lpart,$rpart);
		$ok = 1;
	}
	return $this->api_json_response($request,{ ok => $ok, cmd => $cmd });
}


sub api_log
	# GET /api/log?tail=N     - last N ring entries (default 2000)
	# GET /api/log?since=seq  - entries with seq > seq
	# GET /api/log?since=mark - entries since the last 'mark' command
{
	my ($this,$request) = @_;
	my $params = $request->{params} || {};
	my ($cur_seq,$entries,$overflow);
	if (defined $params->{since})
	{
		my $since = $params->{since} eq 'mark' ?
			getMarkSeq() :
			int($params->{since});
		($cur_seq,$entries,$overflow) = getOutputRingSince($since);
	}
	else
	{
		my $tail = defined($params->{tail}) ? int($params->{tail}) : 2000;
		($cur_seq,$entries,$overflow) = getOutputRingTail($tail);
	}
	return $this->api_json_response($request,{
		seq			=> $cur_seq,
		overflow	=> $overflow,
		lines		=> $entries,
	});
}


#---------------------------------------------
# the applet protocol
#---------------------------------------------

sub applet_edit
	# POST /edit  { verb, args, data }
	#
	# THE ONE MUTATION THE QUERY STRING CANNOT CARRY.  A polygon is a list
	# of hundreds of coordinate pairs; it does not fit in a url and should
	# not be made to.  So this is the only applet endpoint that takes a
	# body, and the body is JSON.
	#
	# IT DISPATCHES INTO em_command, exactly as the console and
	# /api/command do.  That is what keeps "anything one door can do, the
	# others can" true even for the operation only the map can perform:
	# the geometry arrives as a structured payload beside the verb, and
	# the console simply passes none.  A second, private mutation path
	# would have been easier and would have split the vocabulary in two.
	#
	# The RESPONSE CARRIES THE NEW VERSION, so the applet can tell its own
	# committed edit apart from somebody else's change: it sets its
	# rendered version to this one and does not redraw over the geometry
	# it already has.
{
	my ($this,$request) = @_;

	my $body = $request->{content};
	my $edit = $body ? eval { JSON::PP->new->decode($body) } : undef;
	if (!$edit || ref($edit) ne 'HASH' || !$edit->{verb})
	{
		return $this->api_json_response($request,{
			ok		=> 0,
			error	=> 'expected a JSON object with a verb',
			version	=> 0 + getStateSeq(),
		});
	}

	my $verb = $edit->{verb};
	my $args = defined($edit->{args}) ? $edit->{args} : '';
	display($dbg_request,0,"/edit $verb $args");

	# THE STATUS IS THE POINT.  The applet drops its own copy of a polygon
	# when it commits, so a refusal reported as success would let the next
	# poll quietly restore the old geometry and the user's work would vanish
	# with no explanation.  The seq is returned with it so a caller can pull
	# the reason out of /api/log?since=<seq>.

	my $seq = getOutputRingSeq();
	my $ok  = dispatchCommand($verb,$args,$edit->{data}) ? 1 : 0;

	return $this->api_json_response($request,{
		ok		=> $ok,
		verb	=> $verb,
		since	=> 0 + $seq,
		version	=> 0 + getStateSeq(),
	});
}

sub _regionShape
	# One region flattened for the browser, subregions included.
	#
	# Coordinates are [lon,lat] - GeoJSON's order, and the order the model
	# stores - so the applet flips them for Leaflet rather than this end
	# guessing which convention the far end wants.
	#
	# Every number is forced numeric here for the reason given below: a
	# coordinate arriving as a string would be concatenated rather than
	# added the first time any arithmetic touched it.
{
	my ($reg,$checked,$depth) = @_;
	$depth ||= 0;

	my $shape = {
		id			=> $reg->{id},
		name		=> $reg->{name},
		zmax		=> 0 + $reg->{zmax},
		checked		=> $checked ? JSON::PP::true : JSON::PP::false,
		polygons	=> [ map { [ map { [ 0 + $_->[0], 0 + $_->[1] ] } @$_ ] }
							@{$reg->{geometry}} ],
		subregions	=> [ map { _regionShape($_,$checked,$depth+1) }
							@{$reg->{subregions}} ],
	};

	# Only a region has an authored level and a floor.  A subregion sits
	# inside an aperture its parent opened and carries neither, so sending
	# them would be inventing values the model does not have.

	if (!$depth)
	{
		$shape->{zauthor} = 0 + $reg->{zauthor};
		$shape->{zmin}    = 0 + $reg->{zmin};
	}
	return $shape;
}


sub _regionsForState
	# Only what is checked.  The working set IS the answer to "what am I
	# looking at", so an unchecked region is simply not sent.
{
	my @out;
	for my $id (getWorkingSet())
	{
		my $reg = getRegion($id);
		push @out,_regionShape($reg,1) if $reg;
	}
	return \@out;
}


sub applet_state
	# GET /state - everything the map needs, in one document.
	#
	# NOTE WHAT IS NOT HERE.  A source's url never leaves this process.
	# The browser is told what a source is called, what it may be used
	# for and how deep it goes; it is never told where it lives, which is
	# what makes it structurally impossible for a credential to reach the
	# page or its network log.
{
	my ($this,$request) = @_;

	my @sources;
	my $fallback;
	for my $id (getSourceIds())
	{
		my $src = getSource($id);
		# NUMBERS ARE FORCED NUMERIC HERE, AT THE ENCODER, AND NOWHERE
		# ELSE.  Perl does not distinguish 8 from "8", but JSON does and
		# JavaScript's + operator makes the difference catastrophic: a
		# zoom sent as "8" makes Leaflet's z+2 evaluate to "82", and it
		# recurses seventy levels down a quadtree until the browser gives
		# up.  A scalar acquires its string flag from any regular
		# expression match or any interpolation into a message, so no
		# amount of care further down can keep one numeric -- the only
		# place the guarantee can actually hold is where it is serialised.

		push @sources, {
			id			=> $src->{id},
			name		=> $src->{name},
			attribution	=> $src->{attribution},
			tile_format	=> $src->{tile_format},
			tile_size	=> 0 + $src->{tile_size},
			zoom_min	=> 0 + $src->{zoom}{min},
			zoom_max	=> 0 + $src->{zoom}{max},
			uses		=> $src->{uses},
		};

		# A source you can only look at is a poor thing to open on, so
		# the fallback prefers one that can also be built from.

		$fallback = $src->{id}
			if !$fallback && grep { $_ eq 'build' } @{$src->{uses}};
	}
	$fallback = $sources[0]{id} if !$fallback && @sources;

	# ONE selection, resolved by dm_source against what the folder holds:
	# the remembered id, else the official default, else the first source
	# in tree order.  $fallback remains only for the case where this
	# thread's source list and dm_source's disagree, which it cannot, but
	# a blank map is a bad way to find that out.

	my $active = getDefaultSource();
	$active = $fallback				if !$active   || !getSource($active);

	# SELECTION AND EDIT STATE TRAVEL IN THE SAME DOCUMENT, behind the same
	# version counter, so no surface can be out of step with another about
	# what is selected or what is being edited.

	my ($sel_region,$sel_sub) = getSelection();

	return $this->api_json_response($request,{
		version			=> 0 + getStateSeq(),
		sources			=> \@sources,
		active_source	=> $active,
		sets			=> [ getSetNames() ],

		# THE OPEN SET, not the remembered pointer.  The browser is a view
		# of the document, and a document that has not been saved says so
		# on every surface rather than only on the one with a title bar.

		active_set		=> openSetName(),
		set_dirty		=> isSetDirty() ? 1 : 0,
		regions			=> _regionsForState(),
		selection		=> { region => $sel_region, sub => $sel_sub },
		edit			=> getEditState(),
	});
}


my %cov_cache;		# per thread: { state_seq => merged coverage }

sub _workingCoverage
	# The coverage of everything currently checked, merged into one set
	# per zoom, cached until the model changes.
	#
	# Computing it costs about a second for five regions, which is far
	# too slow to repeat on every pan.  The cache is keyed by the MODEL
	# version rather than the poll version: selecting a region and
	# entering an edit both bump the number the browser polls, and neither
	# moves a single tile, so keying on that threw a second of work away
	# on every click in the tree.
	#
	# What is left to pay after a real change is the union alone, because
	# dm_coverage keeps each region's own answer beside the signature of
	# the region that produced it - so the regions that did not change are
	# not walked again.
	#
	# Per thread, because that is where the region data lives; each
	# thread pays once.
{
	my $seq = getModelSeq();
	return $cov_cache{$seq} if $cov_cache{$seq};

	%cov_cache = ();		# only the current one is ever worth keeping
	my $merged = {};
	for my $id (getWorkingSet())
	{
		my $reg = getRegion($id);
		next if !$reg;
		my $cov = regionCoverage($reg);
		for my $z (keys %$cov)
		{
			$merged->{$z} ||= {};
			$merged->{$z}{$_} = 1 for keys %{$cov->{$z}};
		}
	}
	$cov_cache{$seq} = $merged;
	return $merged;
}


sub applet_coverage
	# GET /coverage?z=<zoom>&w=&s=&e=&n=
	#
	# The tiles in coverage at ONE zoom, clipped to the view.  The whole
	# set at z16 is tens of thousands of tiles and drawing them would be
	# pointless as well as slow: the answer only has to be true for what
	# is on the screen.
{
	my ($this,$request) = @_;
	my $p = $request->{params} || {};
	my $z = defined($p->{z}) ? int($p->{z}) : 15;

	my $cov = _workingCoverage();
	my @tiles;

	if ($cov->{$z})
	{
		# The view, as tile coordinates at this zoom.  One conversion,
		# then a range test -- far cheaper than testing every tile in
		# the set against a lat/lon box.

		my ($x0,$y0) = lonLatToTile($p->{w},$p->{n},$z);
		my ($x1,$y1) = lonLatToTile($p->{e},$p->{s},$z);
		($x0,$x1) = ($x1,$x0) if $x0 > $x1;
		($y0,$y1) = ($y1,$y0) if $y0 > $y1;

		for my $key (keys %{$cov->{$z}})
		{
			my ($x,$y) = split(/_/,$key);
			next if $x < $x0 || $x > $x1 || $y < $y0 || $y > $y1;
			push @tiles,[ 0 + $x, 0 + $y ];
		}
	}

	return $this->api_json_response($request,{
		zoom	=> 0 + $z,
		total	=> 0 + ($cov->{$z} ? scalar(keys %{$cov->{$z}}) : 0),
		tiles	=> \@tiles,
	});
}


#---------------------------------------------
# /counts
#---------------------------------------------
# WHAT IT WOULD COST, by level.  The footprint says where the tiles are;
# this says how many and how big, which is the question that decides
# whether a zmax is sensible before a build runs for an hour to answer it.
#
# ASKED, NOT WATCHED.  It is computed when somebody wants it rather than
# tracked as the model moves, and the number is stamped with the version
# it came from -- so a stale answer is visibly stale rather than quietly
# wrong.

my %stats_cache;			# per thread, like every other cache here
my $STATS_TTL = 60;

sub _cacheStats
	# cacheStats() stats every file in a source's cache -- thousands of
	# syscalls, to produce an average.  Held for a minute: the estimate
	# does not get meaningfully better by being recomputed per request,
	# and a fetch running underneath it changes it slowly.
{
	my ($src) = @_;
	return undef if !$src;

	my $have = $stats_cache{$src->{id}};
	return $have->{stats} if $have && (time() - $have->{at}) < $STATS_TTL;

	my $stats = cacheStats($src);
	$stats_cache{$src->{id}} = { at => time(), stats => $stats };
	return $stats;
}


sub _bytesPerTile
	# MEASURED, NOT ASSUMED.  What a tile costs varies by level, by source
	# and by what is in the picture - open water compresses to nothing and
	# a marina does not - so the average of what has actually been fetched
	# at that level is the honest number.  A level nothing has been fetched
	# at borrows the source's overall average, and a source with an empty
	# cache has no opinion at all: zero, reported as no answer rather than
	# as a number somebody made up.
{
	my ($stats,$z) = @_;
	return 0 if !$stats || !$stats->{total_tiles};

	my $zs = $stats->{zooms}{$z};
	return int($zs->{bytes} / $zs->{tiles}) if $zs && $zs->{tiles};
	return int($stats->{total_bytes} / $stats->{total_tiles});
}


sub _countBlock
	# One node's own levels - the band it and nothing else supplies.  The
	# blocks of a region and its subregions are therefore disjoint, and
	# they sum without anybody having to subtract.
{
	my ($id,$node,$stats) = @_;

	my @levels;
	my ($tiles,$bytes) = (0,0);
	for my $z (sort { $a <=> $b } keys %{$node->{levels}})
	{
		my $n = scalar(keys %{$node->{levels}{$z}});
		my $b = $n * _bytesPerTile($stats,$z);
		push @levels,{ z => 0 + $z, tiles => 0 + $n, bytes => 0 + $b };
		$tiles += $n;
		$bytes += $b;
	}
	return { id => $id, levels => \@levels,
			 tiles => 0 + $tiles, bytes => 0 + $bytes };
}


sub _ancestry
	# The subregions on the path from a region down to one of its
	# descendants, outermost first, including the descendant itself.
{
	my ($reg,$id) = @_;
	for my $sub (@{$reg->{subregions} || []})
	{
		return ($sub) if lc($sub->{id}) eq lc($id);
		my @deeper = _ancestry($sub,$id);
		return ($sub,@deeper) if @deeper;
	}
	return ();
}


sub applet_counts
	# GET /counts?id=<region or subregion id>
	#
	# The set is always answered, because its total is the one thing true
	# whatever is selected.  A region adds its own levels; a subregion adds
	# the band above its parent, and its region comes with it - which is
	# why the caller sends one id and gets back up to three answers.
{
	my ($this,$request) = @_;
	my $p  = $request->{params} || {};
	my $id = $p->{id} || '';

	my $stats = _cacheStats(getSource(getDefaultSource()));

	my $merged = _workingCoverage();
	my ($set_tiles,$set_bytes) = (0,0);
	for my $z (keys %$merged)
	{
		my $n = scalar(keys %{$merged->{$z}});
		$set_tiles += $n;
		$set_bytes += $n * _bytesPerTile($stats,$z);
	}

	# An id names a region or a subregion, and the caller does not have to
	# know which - the same thing is true of every other verb that takes
	# one.

	my ($root,$sub);
	if ($id)
	{
		$root = getRegion($id);
		if (!$root)
		{
			for my $rid (getRegionIds())
			{
				my $reg = getRegion($rid);
				my ($found) = findSubregion($reg,$id);
				next if !$found;
				($root,$sub) = ($reg,$found);
				last;
			}
		}
	}

	# THE CHAIN FROM THE REGION DOWN TO WHAT IS SELECTED, one block each.
	# A subregion may hold subregions of its own, and the panel shows the
	# path rather than only the two ends - which is the only way a nested
	# object's numbers can be read against what contains them.
	#
	# THE REGION COUNTS ITSELF AND EVERYTHING INSIDE IT, because "how big
	# is Bocas" means the whole of Bocas, subregions included.  Each
	# subregion block below it counts ONLY its own band, so the blocks read
	# down the panel as the parts of the total above them.

	my @chain;
	if ($root)
	{
		my ($merged,$nodes) = regionCoverageNodes($root);

		my $whole = _countBlock($root->{id},{ levels => $merged },$stats);
		$whole->{depth}   = 0;
		$whole->{zmin}    = 0 + $root->{zmin};
		$whole->{zauthor} = 0 + $root->{zauthor};
		$whole->{zmax}    = 0 + $root->{zmax};
		push @chain,$whole;

		# The ancestors of the selected subregion, outermost first, which
		# is the order the walk already produced them in.

		if ($sub)
		{
			my %want = map { lc($_->{id}) => $_ } _ancestry($root,$sub->{id});
			for my $node (@$nodes)
			{
				my $reg = $want{ lc($node->{id}) };
				next if !$reg;
				my $block = _countBlock($node->{id},$node,$stats);
				$block->{depth} = 0 + $node->{depth};
				$block->{zmax}  = 0 + $reg->{zmax};
				push @chain,$block;
			}
		}
	}

	return $this->api_json_response($request,{
		version	=> 0 + getStateSeq(),
		set		=> { name  => openSetName(),
					 tiles => 0 + $set_tiles,
					 bytes => 0 + $set_bytes },
		chain	=> \@chain,
	});
}


sub applet_tile
	# GET /tile/<source>/<z>/<x>/<y> - the tile proxy.
	#
	# Every tile the application displays comes through here, and it is
	# the same path the build will use.  An absence is a 404 because that
	# is what a tile client expects; an error is a 502, so that "the
	# source does not have it" and "we could not ask" are distinguishable
	# in the browser's network log without reading the app's output.
{
	my ($this,$request,$id,$z,$x,$y) = @_;

	my $source = getSource($id);
	return Pub::HTTP::Response->new($request,"no such source '$id'",404,'text/plain')
		if !$source;

	my $result = getTile($source,$z,$x,$y);

	return Pub::HTTP::Response->new($request,
			${$result->{bytes}},200,"image/$result->{format}")
		if $result->{status} eq 'ok';

	return Pub::HTTP::Response->new($request,'',404,'text/plain')
		if $result->{status} eq 'absent';

	return Pub::HTTP::Response->new($request,
		$result->{reason} // 'fetch failed',502,'text/plain');
}


1;
