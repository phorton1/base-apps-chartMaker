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
use dm_engine;
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


sub serverState
	# 'ok', or 'failed: <reason>'.
	#
	# THE BIND HAPPENS ON THE SERVER THREAD, AFTER start() RETURNS, so
	# there is nothing for startServer to hand back and nothing the thread
	# can do about it either - it may run before any frame exists, and a
	# worker thread must not touch wx in any case.  ServerBase records the
	# outcome against the port and this waits for it to resolve.
	#
	# Wrapped here so that nothing in the application reaches into
	# Pub::HTTP::ServerBase's internals to ask a question about OUR server.
{
	return 'failed: the server was never started' if !$cm_server;
	return Pub::HTTP::ServerBase::waitServerState(
		getPref($PREF_HTTP_PORT),5);
}


sub serverOk
{
	return serverState() eq 'ok' ? 1 : 0;
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
		HTTP_GET_EXT_RE			=> 'html|js|css|png|jpg|jpeg',
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

	# THE BROWSER ASKS FOR /favicon.ico UNBIDDEN, on every map load, and
	# with nothing there that is a 404 apiece for the life of the session.
	#
	# IT IS ANSWERED WITH A PNG RATHER THAN AN .ICO.  An icon file is what
	# the two EXECUTABLES need and it is a packaging input, kept with the
	# rest of the packaging material; a browser will take a png perfectly
	# well, and taking one keeps an image type nothing else here uses out
	# of the static extension whitelist above.

	$request->{uri} = $uri = '/favicon.png' if $uri eq '/favicon.ico';

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

		# THE PROBE'S OWN SEQUENCE RIDES HERE, and this is the right place
		# for it rather than a second channel: /poll exists to answer "has
		# anything changed" as cheaply as possible, and a running probe is
		# a thing that changes.  Carried separately from the state version
		# because a published unit changes nothing in the /state document -
		# so the applet goes straight to /probe without refetching a
		# document that did not move.

		# AND WHERE IT IS LOOKING, WHICH RIDES HERE FOR THE SAME REASON.
		# This program has no notion of 'here' and a leaflet map has one,
		# so the poll that says the map is alive carries the centre it is
		# alive at.  Nothing acts on it until somebody asks a service
		# about somewhere - see dm_verify.

		# AND WHERE IT IS BEING SENT, which is the same channel in the
		# other direction.  'view' is a console verb because a place is
		# the one thing this application's own windows cannot name, and
		# the applet acts on the SEQUENCE rather than the coordinates -
		# see cm_state.

		notePoll();
		my $pp = $request->{params} || {};
		noteView($pp->{lat},$pp->{lon},$pp->{z})
			if defined $pp->{lat} && defined $pp->{lon} && defined $pp->{z};

		my ($want_seq,$want_lat,$want_lon,$want_z) = getViewRequest();

		return $this->api_json_response($request,{
			version		=> 0 + getStateSeq(),
			probe_seq	=> 0 + probeSeq(),
			probe_on	=> probeIsOn() ? 1 : 0,
			view_seq	=> 0 + $want_seq,
			view_lat	=> 0 + $want_lat,
			view_lon	=> 0 + $want_lon,
			view_z		=> 0 + $want_z,
		})
	}
	elsif ($uri eq '/state')
	{
		return $this->applet_state($request)
	}
	elsif ($uri eq '/coverage')
	{
		return $this->applet_coverage($request)
	}
	elsif ($uri eq '/preview')
	{
		return $this->applet_preview($request)
	}
	elsif ($uri eq '/probe')
	{
		return $this->applet_probe($request)
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

	# AN EDIT IS PROOF OF LIFE, and a better one than a poll.  The grace
	# period exists to answer "is that map still there", and /poll used to
	# be the only thing that answered it - so a browser that was actively
	# posting edits could still be declared gone, and the edit it was in
	# the middle of thrown away underneath it.  Observed: two /edit posts
	# on two server threads, and the main thread clearing the edit state
	# between them.
	#
	# A poll says the page is running.  An edit says somebody is WORKING in
	# it, which is exactly the case the grace must never fire during.

	notePoll();

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

		# HOW FAR THE MAP MAY ZOOM is a preference of this process, not a
		# property of any source: a source declares only how deep it goes
		# natively.  It arrives here because the page is a static file and
		# cannot read a preference any other way.

		map_max_zoom	=> int(prefVal($PREF_MAP_MAX_ZOOM) // 22),

		active_set		=> openSetName(),
		set_dirty		=> isSetDirty() ? 1 : 0,
		regions			=> _regionsForState(),
		selection		=> { region => $sel_region, sub => $sel_sub },
		edit			=> getEditState(),

		# THE NUMBER, NOT THE MARKS.  Coverage mode accumulates thousands
		# of them across a long-lived mode and they do not belong in a
		# document refetched on every selection change.  The applet
		# compares this and asks /probe only when it moves.

		# The probe's preferences travel with the state for the same reason
		# map_max_zoom does: the page is a static file and cannot read one.
		# Without them the map's own probe dialog opened at whatever the
		# SOURCE declared, which is exactly the number a probe exists not to
		# trust, and disagreed with the application's dialog beside it.

		probe			=> { on   => probeIsOn() ? 1 : 0,
							 seq  => 0 + probeSeq(),
							 zmin => int(prefVal($PREF_PROBE_ZMIN) // 10),
							 zmax => int(prefVal($PREF_PROBE_ZMAX) // 22) },
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

	# EACH TILE IS VALUED BY THE SOURCE IT WOULD BE BUILT FROM rather than
	# by 1.  Preview needs it and everything else here only ever asks
	# whether a key is present, so carrying it costs nothing and means
	# there is one merged coverage rather than two that could drift.
	#
	# AND THAT VALUE IS '' FOR A NODE THAT HAS NOT CHOSEN, which is the
	# point.  This passed getDefaultSource() as a fallback, so an unsourced
	# node's tiles were valued at whatever the map was displaying and
	# preview PAINTED them - in the same response that listed the node
	# under 'unsourced'.  The applet has said the right thing about this
	# all along; see the note above cmShowUnsourced in cmPreview.js.

	%cov_cache = ();		# only the current one is ever worth keeping
	my $merged = mergedCoverageSources(
		[ map { getRegion($_) } getWorkingSet() ]);

	$cov_cache{$seq} = $merged;
	return $merged;
}


sub _unsourcedNodes
	# The paths of every node in the working set that resolves to no build
	# source, sorted.  Empty in the ordinary case.
	#
	# THE PATH IS THE ANSWER, as it is everywhere else that reports a node -
	# 'Bocas', 'Bocas/Popa00' - because the user's next act is to go and
	# find that one in the tree.
{
	my @out;
	for my $id (getWorkingSet())
	{
		my $reg = getRegion($id) or next;

		# There is no fallback to pass any more - the map answers '' for a
		# node that has not chosen, full stop.  This passed '' explicitly
		# while every other caller passed the display source, which is why
		# this endpoint could name the unsourced nodes and paint their
		# tiles in the same breath.

		my $map = regionSourceMap($reg);
		push @out,grep { !$map->{$_} } sort keys %$map;
	}
	return [ sort @out ];
}


sub applet_preview
	# GET /preview?z=<zoom>&w=&s=&e=&n=
	#
	# What the chartset would show over the view, tile by tile.  The
	# browser draws it; this decides it, for the reason the design gives:
	# if the applet worked coverage out for itself, preview would be an
	# illustration of the build rather than a test of it, and the two would
	# disagree exactly at the seams where disagreement is most expensive.
{
	my ($this,$request) = @_;
	my $p = $request->{params} || {};
	my $z = defined($p->{z}) ? int($p->{z}) : 15;

	my ($x0,$y0) = lonLatToTile($p->{w},$p->{n},$z);
	my ($x1,$y1) = lonLatToTile($p->{e},$p->{s},$z);
	($x0,$x1) = ($x1,$x0) if $x0 > $x1;
	($y0,$y1) = ($y1,$y0) if $y0 > $y1;

	# WHAT CANNOT BE PREVIEWED, AND WHY, travels with the answer.
	#
	# previewTiles omits a tile whose source resolves to nothing, which is
	# truthful - there is no imagery to show - but on its own it is silent,
	# and silence here is indistinguishable from "outside coverage". The
	# tile footprint draws those same tiles, so the user sees outlines with
	# nothing in them and no reason given.
	#
	# So the nodes are named. A preview is the surface where somebody is
	# deciding whether their set is right, and "these have not chosen their
	# imagery yet" is the most useful thing this endpoint can say.

	return $this->api_json_response($request,{
		zoom		=> 0 + $z,
		unsourced	=> _unsourcedNodes(),
		tiles	=> previewTiles(_workingCoverage(),$z,$x0,$y0,$x1,$y1),
	});
}


sub applet_probe
	# GET /probe
	#
	# The whole accumulated result set: every mark, and the overlay.  Not
	# clipped to the view and not filtered by zoom, because coverage mode
	# draws ALL LEVELS AT ONCE - a tile at z+1 is a quadrant of its parent,
	# so centres never coincide and no two levels can occlude each other.
	# Marks are self-scaling at their true footprint, which is what gives
	# the level with no legend.
	#
	# THE APPLICATION COUNTED THIS AND THE BROWSER RENDERS IT.  The map
	# picks no sample points, fetches nothing and counts nothing; if it
	# decided any of it the marks would illustrate the analysis rather than
	# be it, which is the same reason preview does not decide coverage for
	# itself.
	#
	# ASKED FOR ONLY WHEN THE SEQUENCE MOVES.  /state carries probe_seq and
	# the applet compares it, so a mode holding twenty thousand marks costs
	# one poll of a small document rather than a refetch of all of them.
	#
	# EVERY SOURCE PROBED, not just the last one.  Comparing two services
	# over the same ground is what the mode is for, so the marks carry
	# their source and the palette turns each on and off.
{
	my ($this,$request) = @_;

	return $this->api_json_response($request,{
		seq		=> 0 + probeSeq(),
		on		=> probeIsOn() ? 1 : 0,
		marks	=> probeMarkList(),
		sources	=> probeSources(),
		overlay	=> probeOverlay(),
	});
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


my $no_data_jpeg;
	# Read once, and once per server thread, which is four small reads in
	# the life of a run.

sub _noDataTile
	# THE PICTURE FOR 'THIS SOURCE HAS NOTHING HERE'.
	#
	# It is the same file the applet used to name in errorTileUrl, served
	# from the same place - so nothing about what a user sees changed, only
	# WHEN they see it.
{
	return $no_data_jpeg if defined $no_data_jpeg;

	my $path = "$resource_dir/site/images/no_data.jpg";
	if (open(my $fh,'<',$path))
	{
		binmode $fh;
		local $/;
		$no_data_jpeg = <$fh>;
		close $fh;
	}
	else
	{
		# SAID ONCE, AND THEN AN ABSENCE SIMPLY DRAWS AS NOTHING.  A missing
		# resource file must not turn every absence into a broken tile
		# request, and it must not be silent either.
		error("could not read $path - absences will draw as nothing");
		$no_data_jpeg = '';
	}
	return $no_data_jpeg;
}


sub applet_tile
	# GET /tile/<source>/<z>/<x>/<y> - the tile proxy.
	#
	# Every tile the application displays comes through here, and it is
	# the same path the build will use.
	#
	# AN ABSENCE IS A PICTURE AND NOT A FAILURE, and that distinction is the
	# whole of what this does.
	#
	# It used to answer 404, on the reasoning that a 404 is what a tile
	# client expects, and the applet turned that into the no_data picture
	# with Leaflet's errorTileUrl.  But an <img> load failure carries NO
	# STATUS CODE, so that one picture also covered the 502 'we could not
	# ask' and - far more often - a request the BROWSER ABORTED because the
	# user panned.  Rapid panning therefore branded good tiles as missing;
	# and Leaflet keeps a tile once it has drawn it, so a transient abort
	# persisted as a permanent looking lie.  On the surface somebody uses to
	# judge a service's coverage by eye, which is the worst possible place
	# for it: measured over Ibiza with a cache holding not one recorded
	# absence for that source.
	#
	# Served as a 200 the picture is deterministic.  It appears when, and
	# only when, the source said it has nothing.  A real failure now loads
	# no image at all, which Leaflet leaves alone and re-requests on the
	# next pan - the correct treatment of an answer that never arrived.
	#
	# THE STATUS NO LONGER SAYS WHICH, so a header does, for whoever is
	# reading a network log rather than the application's own output.
{
	my ($this,$request,$id,$z,$x,$y) = @_;

	my $source = getSource($id);
	return Pub::HTTP::Response->new($request,"no such source '$id'",404,'text/plain')
		if !$source;

	# INTERACTIVE, WHICH IS THE ONE PLACE IN THE APPLICATION THAT IS.  There
	# is a person waiting on this request and the tile is about to be drawn
	# on a map they are looking at, so it goes to the HEAD of the engine's
	# queue rather than behind however many thousand tiles a fill has in
	# flight.  It does not preempt: the wait is bounded by the shortest
	# request already out, not by the backlog, which is the property that
	# actually matters and is much cheaper to provide.

	my $result = getTile($source,$z,$x,$y,
		{ priority => $PRIORITY_INTERACTIVE });

	return Pub::HTTP::Response->new($request,
			${$result->{bytes}},200,"image/$result->{format}")
		if $result->{status} eq 'ok';

	return Pub::HTTP::Response->new($request,_noDataTile(),200,'image/jpeg',
			{ 'x-chartmaker-tile' => 'absent' })
		if $result->{status} eq 'absent';

	# A FAILURE SAYS WHOSE IT WAS.  Every one of these used to be a 502,
	# which specifically asserts that an upstream server answered badly -
	# and the failure that actually shipped in the first packaged build had
	# contacted nobody at all.  It was this program breaking, announced in
	# the vocabulary of somebody else's outage, which is the wrong machine
	# to go and look at.
	#
	# The classification already exists and is made once, in dm_fetch,
	# where the evidence is; this only translates it, so there is no second
	# opinion about what went wrong:
	#
	#	internal      500 - our bug.  Nothing was asked of anyone.
	#	rate_limited  503 - a real answer, and 'come back later' is
	#	                    exactly what 503 means
	#	everything    502 - we asked and could not get a usable answer,
	#	  else              which is what a gateway error is for
	#
	# THE HEADER IS THE PART ANYONE WILL ACTUALLY SEE.  An <img> failure
	# carries no status code into the page (see the note above), so the
	# code alone only reaches curl or a network log, and it identifies the
	# application while it is there - the absent reply above already does.
	#
	# 503 COMES OUT WITH AN EMPTY REASON PHRASE, which is valid HTTP and
	# looks odd in a log: Pub::HTTP::Response knows the text for 200, 302,
	# 401, 404, 500 and 502 and has no entry for it.  Adding one is a line
	# in Pub, which is shared with applications that are working as they
	# are, so the right code is used here and the cosmetic gap is left
	# where it belongs rather than worked around by sending a wrong one.

	my $class = $result->{class} || '';
	my $code  = $class eq 'internal'     ? 500 :
				$class eq 'rate_limited' ? 503 : 502;

	return Pub::HTTP::Response->new($request,
		$result->{reason} // 'fetch failed',$code,'text/plain',
		{ 'x-chartmaker-tile'  => 'error',
		  'x-chartmaker-class' => $class || 'unknown' });
}


1;
