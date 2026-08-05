#!/usr/bin/perl
#---------------------------------------------
# dm_fetch.pm
#---------------------------------------------
# One tile, from one source.
#
# This module holds no control flow of its own.  It does not queue, rate
# limit, retry, resume, or decide when anything should happen -- all of
# that belongs above it.  It answers exactly one question: what does this
# source have at this coordinate?
#
# Every answer is one of three things, and the distinction matters more
# than it looks:
#
#	ok      the source returned an image
#	absent  the source definitely does not have this tile
#	error   the question could not be answered
#
# ABSENT IS A RESULT; ERROR IS NOT.  An absence is cached, because it is
# a fact about the source that will still be true tomorrow and is what
# accumulates a coverage picture for free.  An error is never cached: a
# timeout, a 500 or a rate limit says nothing about whether the tile
# exists, and writing a miss marker for one would poison the cache with
# a hole that no rebuild would ever revisit.
#
# THE APPLICATION IDENTIFIES ITSELF.  Pub::UA's default agent string
# imitates a browser, which is the wrong thing for a client that fetches
# systematically.  A provider who wants to talk to us should be able to
# tell who we are, and one of the sources chartMaker ships asks exactly
# that of anyone fetching in bulk.

package dm_fetch;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw( time );
use Digest::MD5 qw( md5_hex );
use HTTP::Message;
use Pub::Utils;
use Pub::UA;
use cm_defs;
use dm_source;
use dm_cache;
use dm_observe;
use dm_engine;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		fetchTile
		fetchStore
		fetchCacheHit
		fetchDeclaredAbsent
		fetchUrl
		getTile
	);
}


our $dbg_fetch:shared = 0;
	# 0  = one line per network fetch
	# -1 = the url and the response code


my $ua;		# one per thread; LWP is not shared between them


sub _ua
	# TLS.  This Perl's Net::SSLeay is linked against OpenSSL 1.0.1h from
	# 2014, whose default cipher list still leads with suites that current
	# servers refuse outright -- the handshake dies with "SSL wants a read
	# first" before anything useful happens.  Naming TLS 1.2 and a modern
	# cipher list fixes it.  Verified: without these, gibs.earthdata.nasa.gov
	# and tile.openstreetmap.org both fail while example.com succeeds, which
	# is what makes it look like a per-host problem rather than a stack one.
	#
	# Set here rather than in Pub::UA because Pub is shared by applications
	# that are working as they are.
{
	if (!$ua)
	{
		$ua = Pub::UA->new( timeout => 20 );
		$ua->agent("$appName/$appVersion");
		$ua->ssl_opts( SSL_version     => 'TLSv1_2' );
		$ua->ssl_opts( SSL_cipher_list => 'HIGH:!aNULL:!eNULL' );
	}
	return $ua;
}


sub fetchUrl
	# ONE GET, NO TILE SEMANTICS.  A metadata document is not a tile: it
	# has no coordinate, is never cached, is not an image, and an absence
	# of it means the service does not offer one rather than that a place
	# is empty.  So it does not go through fetchTile and produces no
	# observation of its own.
	#
	# IT LIVES HERE ANYWAY, because _ua is the only thing in the
	# application that knows this Perl's TLS needs naming explicitly.  A
	# second user agent built anywhere else would work against every host
	# that was already easy and fail against exactly the ones this
	# workaround exists for -- and it would fail as an HTTP 500, which
	# sends whoever debugs it to the wrong machine.
{
	my ($url,$timeout) = @_;

	my $ua = _ua();
	my $was = $ua->timeout();
	$ua->timeout($timeout) if $timeout;

	# ASK FOR IT COMPRESSED, WHICH IS ONLY EVER WORTH IT HERE.  A tile is
	# already a compressed image and gzipping one gains nothing; a
	# capabilities document is XML and gains enormously.  NASA GIBS was
	# measured at 5,592,197 bytes plain and 199,393 gzipped, twenty-eight
	# to one, and the header was in its response all along - LWP simply
	# does not ask unless told to.
	#
	# HTTP::Message::decodable() NAMES WHAT THIS PERL CAN ACTUALLY UNDO
	# rather than what the protocol defines, so a machine without a codec
	# asks for nothing it cannot read and the request still works.

	my $started  = time();
	my $response = $ua->get($url,
		'Accept-Encoding' => HTTP::Message::decodable());
	my $ms       = int((time() - $started) * 1000);

	$ua->timeout($was) if $timeout;

	# charset => 'none' UNDOES THE TRANSFER ENCODING AND NOTHING ELSE.
	# The plain decoded_content would also decode the charset and hand back
	# wide characters, which is a different kind of string from the bytes
	# every caller here already parses - and JSON::decode_json in
	# particular expects bytes.

	my $body = $response->decoded_content(charset => 'none',
		raise_error => 0);
	$body = $response->content() if !defined $body;

	my $code = $response->code();
	my $enc  = $response->header('Content-Encoding') || '';
	display($dbg_fetch,0,"fetchUrl -> $code (${ms}ms, ".
		length($body // '')." bytes".
		($enc ? ", $enc ".length($response->content() // '')." on the wire"
			  : '').") $url");

	if (($response->header('Client-Warning') || '') eq 'Internal response')
	{
		my $why = $body || $response->message();
		$why =~ s/\s+/ /g;
		return { ok => 0, ms => $ms, reason => substr($why,0,160) };
	}
	return { ok => 0, code => $code, ms => $ms,
		reason => $response->message() || "http $code" }
		if $code != 200;

	return { ok => 1, code => $code, ms => $ms,
		content => $body,
		type    => $response->header('Content-Type') || '' };
}


sub _detectFormat
	# The actual format, from the image's own magic bytes.  tile_format
	# in a TSD is an expectation: servers mix formats within one source,
	# and at least one output format accepts only one of them.
{
	my ($dataref) = @_;
	return 'jpeg' if $$dataref =~ /^\xFF\xD8\xFF/;
	return 'png'  if $$dataref =~ /^\x89PNG\r\n\x1A\n/;
	return 'gif'  if $$dataref =~ /^GIF8[79]a/;
	return 'webp' if $$dataref =~ /^RIFF.{4}WEBP/s;
	return undef;
}


sub _declaredAbsentHeader
	# Whether the response carries a header the source declared as its way
	# of saying "nothing here".  Returns the header name that matched, so
	# the caller can say which one it was, or '' for no match.
	#
	# NAME FIRST, exactly as _isDeclaredAbsent measures length first.  A
	# source with no declared headers - which is nearly all of them - pays
	# one array test per tile, and one that has them pays a hash lookup
	# per declaration rather than a string comparison against every header
	# the server sent.
{
	my ($source,$response) = @_;
	my $hdrs = $source->{absent_headers};
	return '' if !$hdrs || !@$hdrs;

	for my $hdr (@$hdrs)
	{
		my $got = $response->header($hdr->{name});
		next if !defined $got;
		$got =~ s/^\s+|\s+$//g;
		return $hdr->{name} if $got eq $hdr->{value};
	}
	return '';
}


#---------------------------------------------
# learning what a service serves instead of a tile
#---------------------------------------------
# A SERVICE THAT ANSWERS 'NOTHING HERE' WITH A 200 AND A PICTURE IS THE
# FAILURE THAT LOOKS LIKE SUCCESS, and the only thing that gives it away is
# that the SAME picture comes back at unrelated places.  Zooming or panning
# changes what a tile holds, always, so one identical body answering many
# coordinates is not imagery at any of them.
#
# IT IS LEARNED HERE BECAUSE THIS IS THE ONE DOORWAY.  Every tile this
# application ever receives passes through fetchTile - a build, a fill, a
# sample, a verify, the map proxy - so learning here is a property of
# FETCHING rather than of anybody's reason for fetching.  Put anywhere else
# it becomes a question of which surfaces remembered to ask, and a user who
# never ran the optional one exports a file full of grey.
#
# THREE THINGS MAKE IT FREE.
#
#	SIZE GATES IT.  A fill is a few hundred bytes to a couple of KB; a
#	photograph is not.  Nothing above the gate is ever hashed, so the
#	hashed stream is a fraction of the fetched one.
#
#	THE TABLE IS BOUNDED AND PER THREAD.  Misra-Gries: on a miss with the
#	table full, every counter is decremented and the exhausted ones are
#	dropped.  With k counters anything occupying more than 1/(k+1) of the
#	stream survives to the end IN ANY ORDER - it is a guarantee rather
#	than a hope, and it is what stops a thousand one-off oddities from
#	evicting a real fill between its first and second sighting.  Per
#	thread because a fill repeats within any one worker's own stream, so
#	nothing needs sharing until there is something to report.
#
#	REPORTING IS RATE LIMITED.  A solid run of ten thousand identical
#	tiles must not take the observation record's lock ten thousand times,
#	so the count is carried locally and handed over in batches.
#
# NOTHING HERE DECIDES ANYTHING.  A candidate is a number and a coordinate
# in the observation record.  A person looks at the picture and puts it in
# the file, or does not.

my $FILL_MAX_BYTES = 8192;
	# ABOVE THIS A BODY IS A PHOTOGRAPH.  Measured: Esri's 'Map data not
	# yet available' tile is 2521 bytes and carries rendered TEXT, which is
	# expensive, so the gate has to be well clear of a flat colour.  Real
	# imagery lands under it too - open water at 865 bytes - which is why
	# size only decides what is HASHED and never what is suspicious.

my $MG_SLOTS = 256;
	# About 12 KB per source, and a guarantee that anything over roughly
	# 0.4 percent of the hashed stream survives.

my $REPORT_AT = 2;
	# Twice is the least that means anything.  One sighting is a tile.
	#
	# EXACT WHILE THE NUMBER IS SMALL, then on powers of two.  A solid run
	# of ten thousand identical tiles must not take the observation
	# record's lock ten thousand times - but the counts a person actually
	# reads are the small ones, and a verify column with three suspect
	# levels in it saying "seen 2 times" is wrong in the one place it is
	# being read.  So the first few are reported as they happen and the
	# rest double: about twenty writes for those ten thousand, and never
	# an understatement where it would be noticed.

my $REPORT_EXACT_TO = 16;
	# Below this every sighting is reported, so a column a person is
	# reading never understates itself.

my %mg;		# PER THREAD, not shared: cache_key => { md5 => \%slot }


sub _learn
	# One body, counted.  Called only for a 200 that decoded as an image.
{
	my ($source,$z,$x,$y,$dataref) = @_;

	my $len = length($$dataref);
	return if $len > $FILL_MAX_BYTES;

	# ALREADY DECLARED IS NOT A CANDIDATE.  A fingerprint in the file is
	# the question already answered, and re-offering it every fetch would
	# make the record argue with the source.

	return if _isDeclaredAbsent($source,$dataref);

	my $key = $source->{cache_key} || $source->{id} or return;
	my $md5 = md5_hex($$dataref);
	my $tbl = $mg{$key} ||= {};

	if (my $slot = $tbl->{$md5})
	{
		my $n = ++$slot->{n};
		return if $n < $REPORT_AT;
		return if $n > $REPORT_EXACT_TO && ($n & ($n - 1));

		obsCandidateFingerprint($source,$len,$md5,
			$slot->{z},$slot->{x},$slot->{y},$slot->{n} - $slot->{told});
		$slot->{told} = $slot->{n};
		return;
	}

	if (scalar(keys %$tbl) < $MG_SLOTS)
	{
		$tbl->{$md5} = { n => 1, told => 0, z => $z, x => $x, y => $y };
		return;
	}

	# THE TABLE IS FULL: every counter pays one, and the exhausted leave.
	# The arriving body is NOT inserted, which is what bounds the work.

	for my $m (keys %$tbl)
	{
		delete $tbl->{$m} if --$tbl->{$m}{n} < 1;
	}
}


sub _said
	# WHAT THE SERVER SAID, WHEN WHAT IT SENT WAS NOT AN IMAGE.
	#
	# A 200 CARRYING TEXT IS THE ONE FAILURE THAT EXPLAINS ITSELF, and
	# discarding it was costing exactly the sentence somebody needs:
	# Queensland answers a tile request with 200 and
	# {"error":{"code":499,"message":"Token Required"}}, which says in four
	# words what 'not a recognised image' cannot say at all.
	#
	# MARKUP OUT, ONE LINE, AND SHORT.  An ArcGIS error is a whole HTML
	# page whose useful part is its title, and a reason that pasted a page
	# into a log would be worse than one that said nothing.
{
	my ($dataref) = @_;
	my $t = substr($$dataref,0,4000);

	$t =~ s{<script.*?</script>}{ }gsi;
	$t =~ s{<style.*?</style>}{ }gsi;
	$t =~ s{<[^>]*>}{ }gs;
	$t =~ s/[^\x20-\x7E]/ /g;
	$t =~ s/\s+/ /g;
	$t =~ s/^\s+|\s+$//g;

	return '' if $t !~ /\S/;
	return length($t) > 150 ? substr($t,0,147).'...' : $t;
}


sub fetchTile
	# The network, and nothing else.  No cache is consulted or written.
	# Returns { status, format, bytes, http, reason, ms }.
{
	my ($source,$z,$x,$y) = @_;

	my $why;
	my $url = sourceTileUrl($source,$z,$x,$y,\$why);
	if (!defined $url)
	{
		# TWO REASONS, AND THEY ARE NOT THE SAME KIND OF THING.
		#
		# Outside the declared protocol range is a fact about the SERVICE:
		# it would refuse, so this is a definite absence, and an absence is
		# cached because it will still be true tomorrow.
		#
		# An unresolved key_name is a fact about the USER'S OWN
		# CONFIGURATION.  Caching it would write a permanent miss for a
		# tile that exists, over everywhere they happened to look before
		# pasting a key, and nothing would ever ask again.  It is an error,
		# errors are never cached, and no request was made.

		return { status => 'error', class => 'unresolved', local => 1,
			reason => $why }
			if $why;

		return { status => 'absent', reason => 'outside the declared protocol range' };
	}

	my $started  = time();
	my $response = _ua()->get($url);
	my $ms       = int((time() - $started) * 1000);
	my $code     = $response->code();

	display($dbg_fetch+1,0,"fetchTile $source->{id} $z/$x/$y -> $code (${ms}ms) $url");

	if ($code == 200)
	{
		# THE SOURCE SAID NO IN A HEADER.  Checked before the body is
		# looked at, because a declared absent header is the server's own
		# statement and outranks whatever it chose to send alongside it --
		# which for the known case is a perfectly valid image.
		#
		# Ahead of _detectFormat for a second reason: a source that
		# answers an absence with an error PAGE would otherwise be
		# reported as 'not a recognised image', an error, and errors are
		# retried forever.  An absence is a result and is cached.

		my $said = _declaredAbsentHeader($source,$response);
		if ($said)
		{
			display($dbg_fetch,0,"$source->{id} $z/$x/$y - the source's ".
				"'$said' header says it has no tile here");
			return { status => 'absent', http => $code, ms => $ms,
				reason => "the source's '$said' header says it has no tile here" };
		}

		my $data   = $response->content();
		my $format = _detectFormat(\$data);

		if (!defined $format)
		{
			# A 200 that is not an image is the failure mode that looks
			# most like success.  It is usually an error page.

			my $said = _said(\$data);
			return { status => 'error', http => $code, ms => $ms,
				class => 'garbage',
				reason => 'response is not a recognised image',
				($said ? ( said => $said ) : ()) };
		}
		if ($format ne 'jpeg' && $format ne 'png')
		{
			return { status => 'error', http => $code, ms => $ms,
				class => 'garbage',
				reason => "image format '$format' is not supported" };
		}

		display($dbg_fetch,0,"fetched $source->{id} $z/$x/$y ".
			"($format, ".length($data)." bytes, ${ms}ms)");

		# WHAT THIS TILE TEACHES ABOUT THE SERVICE, before it is handed to
		# whoever asked.  See the note above _learn: this is the one place
		# every tile passes through, so it is the only place that can learn
		# without depending on why somebody was fetching.

		_learn($source,$z,$x,$y,\$data);

		return { status => 'ok', format => $format, bytes => \$data,
			http => $code, ms => $ms };
	}

	return { status => 'absent', http => $code, ms => $ms,
		reason => 'the source does not have this tile' }
		if $code == 404 || $code == 204;

	# LWP reports its OWN failures -- a refused connection, a TLS
	# handshake that died, a timeout -- as a 500 carrying a
	# Client-Warning header.  Calling that a server error sends anyone
	# debugging it to the wrong machine, so it is reported as what it is.

	if (($response->header('Client-Warning') || '') eq 'Internal response')
	{
		my $why = $response->content() || $response->message();
		$why =~ s/\s+/ /g;
		$why = substr($why,0,160);
		display($dbg_fetch,0,"fetch FAILED $source->{id} $z/$x/$y - local: $why");
		return { status => 'error', ms => $ms, local => 1,
			class => 'transport',
			reason => "could not reach the source - $why" };
	}

	my %why = (
		401 => 'unauthorized - the source needs a credential',
		403 => 'forbidden - the source refused this request',
		429 => 'rate limited',
		500 => 'server error',
		502 => 'bad gateway',
		503 => 'service unavailable',
	);

	my $reason = $why{$code} || $response->message() || "http $code";
	display($dbg_fetch,0,"fetch FAILED $source->{id} $z/$x/$y - $reason");

	# THE CLASS BESIDE THE PROSE, and the reason there are two.  The
	# sentence is for a person reading a log; the class is the only part
	# with a policy consequence, and each of these has exactly one:
	#
	#	rate_limited  back off this source, and obey Retry-After if given
	#	auth          stop and tell the user; retrying cannot help
	#	transport     retry a few times
	#	server        retry a few times
	#	garbage       do not retry
	#
	# A 503 CARRYING Retry-After IS RATE LIMITING wearing a different
	# number.  A service under real load and a service telling you to slow
	# down are indistinguishable from here, and the header is the tell:
	# nobody attaches a wait to an outage they did not schedule.

	my $retry_after = $response->header('Retry-After');
	my $class =
		$code == 429                                 ? 'rate_limited' :
		$code == 503 && defined($retry_after)        ? 'rate_limited' :
		($code == 401 || $code == 403)               ? 'auth'         :
		$code >= 500                                 ? 'server'       :
		                                               'server';

	# AND WHAT IT SAID, FOR THE SAME REASON AS ABOVE.  A 400 from an ArcGIS
	# endpoint is an HTML page whose title is 'Error: Invalid URL', which
	# is the difference between a malformed url and a service that is down.
	# Not gathered for a 404: that is a definite absence and its body
	# cannot tell a missing tile from a wrong path, which is a question the
	# column answers by shape instead.

	my $said = _said(\(my $body = $response->content() // ''));

	return { status => 'error', http => $code, ms => $ms,
		class => $class, reason => $reason,
		($said ? ( said => $said ) : ()),
		defined($retry_after) ? ( retry_after => $retry_after ) : () };
}


sub _isDeclaredAbsent
	# Whether these bytes are the source's way of saying "nothing here".
	#
	# LENGTH FIRST.  The digest is only computed when a length matches
	# exactly, so a source with no fingerprints - which is most of them -
	# pays nothing, and one with fingerprints pays an integer comparison
	# per tile.  See the note in dm_source's validator.
{
	my ($source,$dataref) = @_;
	my $fps = $source->{absent_fingerprints};
	return 0 if !$fps || !@$fps || !$dataref;

	my $len = length($$dataref);
	my $md5;
	for my $fp (@$fps)
	{
		next if $fp->{bytes} != $len;
		$md5 = md5_hex($$dataref) if !defined $md5;
		return 1 if $md5 eq $fp->{md5};
	}
	return 0;
}


sub fetchDeclaredAbsent
	# THE PUBLIC NAME FOR THE RULE ABOVE, and the reason there is one: the
	# fingerprint test having two implementations is not a hypothetical
	# fault, it is a bug this application has already had.  A reader that
	# rolled its own would be free to disagree with the fetcher about
	# whether the same bytes are a tile.
{
	my ($source,$dataref) = @_;
	return _isDeclaredAbsent($source,$dataref);
}


sub fetchCacheHit
	# WHAT A CACHE HIT MEANS, IN ONE PLACE, because there is more than one
	# reader of the cache and they must not disagree about the same file.
	#
	# getTile is the usual one.  The PROBE is the other: it checks the cache
	# on its own thread before submitting anything, deliberately, so that a
	# tile already on disk costs a file read rather than a queue handoff.
	# That made it the one reader that never applied the rule below - a
	# sentinel cached as imagery before anybody fingerprinted it was
	# reported by the probe as FOUND, which is the exact opposite of the
	# finding, and on the one surface whose whole job is to make it.
	#
	# A PLACEHOLDER MAY HAVE BEEN CACHED BEFORE ANYBODY KNEW IT WAS ONE.
	# Checking on the way out as well as on the way in means declaring a
	# fingerprint reclassifies what is already on disk, so a probe's
	# findings take effect without clearing the cache.
{
	my ($source,$z,$x,$y,$cached) = @_;
	return $cached if !$cached;

	if ($cached->{status} eq 'ok' &&
		_isDeclaredAbsent($source,$cached->{bytes}))
	{
		display($dbg_fetch,0,"declared-absent tile in cache ".
			"$source->{cache_key} $z/$x/$y - recording the absence");
		cachePutMiss($source,$z,$x,$y,1);
		return { status => 'absent', cached => 1, sentinel => 1,
				 reason => "the source's declared 'no data' tile" };
	}

	$cached->{cached} = 1;
	return $cached;
}


sub getTile
	# The tile, cache first.  This is what everything actually calls --
	# the map, the preview, the evaluator and the build alike, which is
	# what makes displaying and building share one cache.
	#
	# THE ENGINE IS BELOW THIS, NOT ABOVE IT.  Everything that wants a tile
	# still calls getTile and still blocks until it has one; what changed is
	# that the request now goes out through a paced, bounded queue instead
	# of straight at somebody's server.  That is why the proxy became paced
	# without em_server changing at all.
	#
	# THE CACHE CHECK STAYS ON THE CALLING THREAD, deliberately.  A cache
	# hit is a local file read of a few milliseconds and it is the common
	# case by a wide margin; sending it through a queue would add a thread
	# handoff to the cheapest thing this application does, and would let a
	# saturated pool make cached panning feel slow.
	#
	# opts: priority  interactive or bulk; interactive queues ahead
	#       advisory  a per-run interval floor from a build configuration
{
	my ($source,$z,$x,$y,$opts) = @_;
	$opts ||= {};

	my $cached = cacheGet($source,$z,$x,$y);
	return fetchCacheHit($source,$z,$x,$y,$cached) if $cached;

	my $result = engineFetch($source,$z,$x,$y,
		$opts->{priority},$opts->{advisory});
	$result->{cached} = 0;

	# THE OBSERVATION RECORD IS WRITTEN BY THE ENGINE, NOT HERE.  It used to
	# be recorded at this point, which was correct only while getTile was
	# the sole route to the network.  It stopped being that the moment
	# dm_fill became a client of the engine and started calling
	# engineSubmit directly: a fill is the largest source of traffic in the
	# whole application, and it recorded nothing at all - no round trip, no
	# error classes, and a clean-request counter that never advanced, so a
	# ceiling could never be learned as honest.
	#
	# The recording belongs where every request actually leaves, which is
	# the same argument that put the ENGINE below getTile's callers rather
	# than above dm_fill.  See _doFetch in dm_engine.

	# THE SENTINEL AND THE CACHE WRITE ARE THE ENGINE'S TOO, for exactly the
	# reason above and by the same argument.  They used to be here, which
	# was correct only while getTile was the sole route to the network.
	#
	# See fetchStore, and dm_engine::_doFetch which calls it.

	return $result;
}


sub fetchStore
	# WHAT A RESPONSE MEANS, AND WHAT TO KEEP OF IT.  Called at the ONE
	# place a request actually lands - dm_engine::_doFetch - so that every
	# route to the network gets it: the map proxy, a fill, a build's fill
	# phase and a probe alike.
	#
	# IT WAS IN getTile AND THAT WAS A REAL BUG, not a tidiness question.
	# When dm_fill stopped calling getTile and became a client of the engine
	# it stopped caching ANYTHING it fetched and stopped recognising a
	# sentinel - so Fetch Tiles wrote nothing, a build's fill phase handed
	# the exporter an empty cache, and a source's 'no data' tile was counted
	# as imagery. Measured: a fill of three tiles left zero files behind.
	#
	# The observation record was moved down here for precisely this reason
	# and these two were left behind, which is the shape of the mistake:
	# when the one-and-only route becomes one of several, everything hanging
	# off it has to move, not just the part somebody was looking at.
{
	my ($source,$z,$x,$y,$result) = @_;
	return $result if !$result;

	# A 200 THAT MEANS 404.  Recorded as the absence it is, so it is never
	# asked for again and never reaches an output file.
	#
	# AND RECORDED AS THE KIND OF ABSENCE IT IS.  Everything downstream of a
	# build treats this exactly as a 404 and should - there is no tile
	# either way.  But it is NOT the same finding about the SERVICE, and a
	# probe is a judgement of the service: a 404 is a server saying it has
	# nothing, and this is a server declining to say so, which nobody would
	# know at all had somebody not fingerprinted the body.  So the marker
	# says which, here, while the bytes are still in hand.

	if ($result->{status} eq 'ok' &&
		_isDeclaredAbsent($source,$result->{bytes}))
	{
		display($dbg_fetch,0,"$source->{cache_key} $z/$x/$y is the source's ".
			"'no data' tile - recording an absence");
		cachePutMiss($source,$z,$x,$y,1);
		return { status => 'absent', cached => 0, ms => $result->{ms},
				 sentinel => 1,
				 reason => "the source's declared 'no data' tile" };
	}

	if ($result->{status} eq 'ok')
	{
		cachePutTile($source,$z,$x,$y,$result->{format},$result->{bytes});
	}
	elsif ($result->{status} eq 'absent' && defined($result->{http}))
	{
		# Only an absence the SOURCE asserted is recorded.  An absence
		# derived from the TSD's own declared zoom range has no http code,
		# costs nothing to recompute, and would go stale the moment the TSD
		# changed.

		cachePutMiss($source,$z,$x,$y);
	}

	return $result;
}


1;
