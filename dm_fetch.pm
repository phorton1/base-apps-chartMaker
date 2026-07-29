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
use Pub::Utils;
use Pub::UA;
use cm_defs;
use dm_source;
use dm_cache;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		fetchTile
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


sub fetchTile
	# The network, and nothing else.  No cache is consulted or written.
	# Returns { status, format, bytes, http, reason, ms }.
{
	my ($source,$z,$x,$y) = @_;

	my $url = sourceTileUrl($source,$z,$x,$y);
	if (!defined $url)
	{
		# Outside the source's declared protocol range, or needing a
		# credential we cannot supply.  Either way the server would
		# refuse, so this is a definite absence and not a failure.

		return { status => 'absent', reason => 'outside the declared protocol range' };
	}

	my $started  = time();
	my $response = _ua()->get($url);
	my $ms       = int((time() - $started) * 1000);
	my $code     = $response->code();

	display($dbg_fetch+1,0,"fetchTile $source->{id} $z/$x/$y -> $code (${ms}ms) $url");

	if ($code == 200)
	{
		my $data   = $response->content();
		my $format = _detectFormat(\$data);

		if (!defined $format)
		{
			# A 200 that is not an image is the failure mode that looks
			# most like success.  It is usually an error page.

			return { status => 'error', http => $code, ms => $ms,
				reason => 'response is not a recognised image' };
		}
		if ($format ne 'jpeg' && $format ne 'png')
		{
			return { status => 'error', http => $code, ms => $ms,
				reason => "image format '$format' is not supported" };
		}

		display($dbg_fetch,0,"fetched $source->{id} $z/$x/$y ".
			"($format, ".length($data)." bytes, ${ms}ms)");

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

	return { status => 'error', http => $code, ms => $ms, reason => $reason };
}


sub getTile
	# The tile, cache first.  This is what everything actually calls --
	# the map, the preview, the evaluator and the build alike, which is
	# what makes displaying and building share one cache.
{
	my ($source,$z,$x,$y) = @_;

	my $cached = cacheGet($source,$z,$x,$y);
	if ($cached)
	{
		$cached->{cached} = 1;
		return $cached;
	}

	my $result = fetchTile($source,$z,$x,$y);
	$result->{cached} = 0;

	if ($result->{status} eq 'ok')
	{
		cachePutTile($source,$z,$x,$y,$result->{format},$result->{bytes});
	}
	elsif ($result->{status} eq 'absent' && defined($result->{http}))
	{
		# Only an absence the SOURCE asserted is recorded.  An absence
		# derived from the TSD's own declared zoom range has no http
		# code, costs nothing to recompute, and would go stale the
		# moment the TSD changed.

		cachePutMiss($source,$z,$x,$y);
	}

	return $result;
}


1;
