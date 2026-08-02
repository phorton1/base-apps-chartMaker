#!/usr/bin/perl
#---------------------------------------------
# tool_stub_source.pl -- a tile server that misbehaves on purpose
#---------------------------------------------
# The failures that matter most to a fetch engine are the ones no real
# service will produce on demand.  Nobody can ask Esri for a 429, and a
# source that answers an absence in a header is rare enough that the one
# known example may not be reachable at all.  So the classification, the
# backoff and the pacing are tested against a server that does exactly
# what it is told.
#
# THE PATH IS THE INSTRUCTION.  There is no configuration file and no
# control channel: a request says what it wants the server to do, which
# means a test fixture is a url template and nothing else, and a TSD
# pointed at this server is an ordinary TSD.
#
#	/ok/{z}/{x}/{y}.jpg            200, a small valid jpeg
#	/png/{z}/{x}/{y}.png           200, a small valid png
#	/notile/{z}/{x}/{y}.jpg        200 and a valid jpeg, plus
#	                               'X-VE-Tile-Info: no-tile'
#	/blank/{z}/{x}/{y}.jpg         200, the same bytes every time --
#	                               an absent_fingerprint candidate
#	/404/{z}/{x}/{y}.jpg           404
#	/204/{z}/{x}/{y}.jpg           204
#	/401 /403 /500 /502            that code, no body worth reading
#	/429/{z}/{x}/{y}.jpg           429 with 'Retry-After: 2'
#	/429nra/{z}/{x}/{y}.jpg        429 with no Retry-After
#	/503ra/{z}/{x}/{y}.jpg         503 with 'Retry-After: 1'
#	/garbage/{z}/{x}/{y}.jpg       200 text/html -- the 200 that means
#	                               an error page
#	/truncated/{z}/{x}/{y}.jpg     200 claiming a jpeg, sending 3 bytes
#	/slow/{ms}/{z}/{x}/{y}.jpg     200 after {ms} milliseconds
#	/flaky/{n}/{z}/{x}/{y}.jpg     500 for the first {n} requests to that
#	                               exact coordinate, then 200 -- which is
#	                               what a retry policy has to survive
#	/hang/{z}/{x}/{y}.jpg          accepts and never answers, for timeouts
#
#	/stats                         JSON: every request this server has
#	                               seen, with arrival times in ms since
#	                               it started
#	/reset                         forget them, and forget flaky counts
#	/quit                          exit 0
#
# ONE PROCESS, NO FORK AND NO THREADS.  Windows perl's fork is emulated
# and this Perl's ithreads clone the interpreter, and neither is a thing
# to introduce into a test fixture whose whole job is to be boring.  The
# loop is IO::Select over non-blocking sockets with a deadline queue, so
# /slow and /hang delay one client without stalling any other -- which is
# the property the concurrency tests actually need.
#
# WHAT MAKES IT USEFUL BEYOND CLASSIFICATION is /stats.  Arrival times
# are the only direct evidence that a pacing gate paced anything: the
# engine's own numbers are what is being tested, so they cannot be the
# measurement.

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw( time sleep );

$| = 1;

my $port = shift(@ARGV) || 9899;

my $started = time();
my @log;			# one entry per request, in arrival order
my %flaky;			# path => how many times it has been asked


#---------------------------------------------
# the canned bodies
#---------------------------------------------

sub _jpeg
	# A jpeg only has to be recognisable: dm_fetch reads three bytes of
	# magic and the rest is length.  The tail marker is there so that
	# anything downstream that looks for a real end of image finds one.
{
	my ($len) = @_;
	$len ||= 64;
	my $body = "\xFF\xD8\xFF\xE0" . ("\x20" x ($len - 6)) . "\xFF\xD9";
	return $body;
}

sub _png
{
	return "\x89PNG\r\n\x1A\n" . ("\x00" x 56);
}


sub _mapServerJson
	# A MINIMAL BUT HONEST MapServer description.  Cut down from the real
	# World_Imagery answer, keeping every field dm_probe reads and nothing
	# else -- so a field the probe starts depending on shows up here as a
	# missing value rather than as a silently correct default.
	#
	# maxScale IS SET HERE, deliberately and unlike Esri's.  Esri publishes
	# 0, so the real service can only ever exercise the 'declares nothing'
	# branch of the maxScale rule; the interesting branch is the other one,
	# and this is the only place it can be reached.  4513.99 is the scale
	# of level 17 in the standard web mercator LOD table, so a probe that
	# applies the rule correctly must report a ceiling of 17 rather than
	# the 20 the cache goes to.
{
	my @lods;
	my @scales = (
		591657527.6,295828763.8,147914381.9,73957190.9,36978595.5,
		18489297.7,9244648.9,4622324.4,2311162.2,1155581.1,577790.6,
		288895.3,144447.6,72223.8,36111.9,18056.0,9028.0,4514.0,
		2257.0,1128.5,564.2 );
	for my $z (0..20)
	{
		push @lods,sprintf('{"level":%d,"resolution":%.9f,"scale":%.4f}',
			$z,156543.03392800014 / (2 ** $z),$scales[$z]);
	}

	return '{'.
		'"mapName":"Layers",'.
		'"serviceDescription":"a stub that misbehaves on purpose",'.
		'"copyrightText":"nobody owns this",'.
		'"capabilities":"Map,Query,Data,Tilemap",'.
		'"exportTilesAllowed":true,'.
		'"minScale":0,'.
		'"maxScale":4514.0,'.
		'"spatialReference":{"wkid":102100,"latestWkid":3857},'.
		'"tileInfo":{'.
			'"rows":256,"cols":256,"format":"JPEG",'.
			'"spatialReference":{"wkid":102100,"latestWkid":3857},'.
			'"lods":['.join(',',@lods).']'.
		'}'.
	'}';
}


#---------------------------------------------
# responses
#---------------------------------------------

sub _response
	# code, headers hashref, body -> the bytes to put on the wire.
{
	my ($code,$hdrs,$body) = @_;
	$body = '' if !defined $body;
	my %msg = (
		200 => 'OK',            204 => 'No Content',
		401 => 'Unauthorized',  403 => 'Forbidden',
		404 => 'Not Found',     429 => 'Too Many Requests',
		500 => 'Internal Server Error',
		502 => 'Bad Gateway',   503 => 'Service Unavailable',
	);
	my $text = "HTTP/1.1 $code ".($msg{$code} || 'Unknown')."\r\n";
	$text .= "Content-Length: ".length($body)."\r\n";
	$text .= "Connection: close\r\n";
	$text .= "$_: $hdrs->{$_}\r\n" for sort keys %$hdrs;
	$text .= "\r\n";
	return $text.$body;
}


sub _statsJson
	# Hand rolled rather than JSON::PP, so this fixture depends on
	# nothing the application depends on.  If a stats reader breaks, it
	# should be because the stub is wrong, not because a module moved.
{
	my $out = "{\n  \"started_ms\": 0,\n  \"count\": ".scalar(@log).",\n";
	$out .= "  \"requests\": [\n";
	for my $i (0..$#log)
	{
		my $e = $log[$i];
		my $path = $e->{path};
		$path =~ s/(["\\])/\\$1/g;
		$out .= sprintf("    { \"ms\": %d, \"path\": \"%s\", \"code\": %d }%s\n",
			$e->{ms},$path,$e->{code},$i == $#log ? '' : ',');
	}
	$out .= "  ]\n}\n";
	return $out;
}


sub handle
	# What this path asks the server to do.  Returns (delay_seconds,
	# response_bytes); an undef response means never answer at all.
{
	my ($path) = @_;

	return (0,_response(200,{ 'Content-Type' => 'application/json' },_statsJson()))
		if $path eq '/stats';

	if ($path eq '/reset')
	{
		@log = ();
		%flaky = ();
		return (0,_response(200,{ 'Content-Type' => 'text/plain' },"reset\n"));
	}

	if ($path eq '/quit')
	{
		print "quit requested\n";
		# Answered before exiting, so the caller sees a clean close
		# rather than a refused connection it has to interpret.
		return (0,_response(200,{ 'Content-Type' => 'text/plain' },"bye\n"),1);
	}

	# ---- the ArcGIS shapes, so the metadata probe has something to read
	#
	# THE PATH IS SHAPED LIKE A REAL MapServer because dm_probe derives the
	# metadata url from the tile url by pattern, exactly as it must for a
	# real TSD.  A stub that answered on some private path would test the
	# parser and skip the derivation, which is the part that breaks.

	if ($path =~ m{/MapServer\?f=json})
	{
		return (0,_response(200,{ 'Content-Type' => 'application/json' },
			_mapServerJson()));
	}

	# A TILEMAP WITH BOTH ENCODINGS ON DEMAND.  A real service answers a
	# fully covered block by omitting the data array entirely and saying
	# only 'valid' -- a compression that reads as an EMPTY block to anyone
	# who did not know, which is the worst possible way to be wrong about
	# coverage.  Esri would not produce one to order, so the level selects:
	#
	#	z1  the compressed form: valid, and no data array at all
	#	z2  an explicit array of zeros
	#	z3  a mixed array, half present
	#	otherwise  an explicit array of ones

	if ($path =~ m{/MapServer/tilemap/(\d+)/(\d+)/(\d+)/(\d+)/(\d+)})
	{
		my ($z,$row,$col,$rows,$cols) = ($1,$2,$3,$4,$5);
		my $n = $rows * $cols;
		my $loc = "\"location\":{\"height\":$rows,\"left\":$col,".
			"\"top\":$row,\"width\":$cols}";

		return (0,_response(200,{ 'Content-Type' => 'application/json' },
			"{$loc,\"valid\":true}"))
			if $z == 1;

		my @data =
			$z == 2 ? ((0) x $n) :
			$z == 3 ? (map { $_ % 2 } (1..$n)) :
					  ((1) x $n);

		return (0,_response(200,{ 'Content-Type' => 'application/json' },
			"{\"data\":[".join(',',@data)."],$loc,\"valid\":true}"));
	}

	my $jpg = { 'Content-Type' => 'image/jpeg' };

	return (0,_response(200,$jpg,_jpeg(64)))
		if $path =~ m{^/ok/} || $path =~ m{/MapServer/tile/};
	return (0,_response(200,{ 'Content-Type' => 'image/png' },_png()))
		if $path =~ m{^/png/};

	# THE HEADER ABSENCE.  A perfectly good jpeg, and a header saying it
	# is not imagery.  Nothing about the bytes could tell you.

	return (0,_response(200,{ %$jpg, 'X-VE-Tile-Info' => 'no-tile' },_jpeg(64)))
		if $path =~ m{^/notile/};

	# The same bytes every time, so a caller can measure them once and
	# declare them as an absent_fingerprint.

	return (0,_response(200,$jpg,_jpeg(128)))
		if $path =~ m{^/blank/};

	return (0,_response(404,{},''))  if $path =~ m{^/404/};
	return (0,_response(204,{},''))  if $path =~ m{^/204/};
	return (0,_response(401,{},''))  if $path =~ m{^/401/};
	return (0,_response(403,{},''))  if $path =~ m{^/403/};
	return (0,_response(500,{},''))  if $path =~ m{^/500/};
	return (0,_response(502,{},''))  if $path =~ m{^/502/};

	return (0,_response(429,{ 'Retry-After' => 2 },''))
		if $path =~ m{^/429/};
	return (0,_response(429,{},''))
		if $path =~ m{^/429nra/};
	return (0,_response(503,{ 'Retry-After' => 1 },''))
		if $path =~ m{^/503ra/};

	return (0,_response(200,{ 'Content-Type' => 'text/html' },
		"<html><body>quota exceeded</body></html>\n"))
		if $path =~ m{^/garbage/};

	# A CONTENT-LENGTH THAT LIES.  The client is told 64 bytes and given
	# 3, which is how a body arrives cut off in practice.

	if ($path =~ m{^/truncated/})
	{
		my $text = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\n".
			"Content-Length: 64\r\nConnection: close\r\n\r\n";
		return (0,$text."\xFF\xD8\xFF");
	}

	return ($1 / 1000,_response(200,$jpg,_jpeg(64)))
		if $path =~ m{^/slow/(\d+)/};

	if ($path =~ m{^/flaky/(\d+)/(.*)$})
	{
		my ($n,$rest) = ($1,$2);
		my $seen = ++$flaky{"flaky/$rest"};
		return (0,_response(500,{},'')) if $seen <= $n;
		return (0,_response(200,$jpg,_jpeg(64)));
	}

	return (0,undef) if $path =~ m{^/hang/};

	return (0,_response(404,{ 'Content-Type' => 'text/plain' },
		"no stub rule for $path\n"));
}


#---------------------------------------------
# the loop
#---------------------------------------------

my $listen = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => $port,
	Proto     => 'tcp',
	Listen    => 64,
	ReuseAddr => 1,
	Blocking  => 0 )
	or die "tool_stub_source: cannot listen on 127.0.0.1:$port - $!\n";

print "tool_stub_source listening on 127.0.0.1:$port\n";

my $select  = IO::Select->new($listen);
my %pending;	# socket => { buf, deadline, out, quit }
my $quit_at;

while (1)
{
	# The timeout is what keeps a deadline honest: with nothing to read
	# the loop still has to wake up in time to answer a /slow.
	#
	# IT IS ALSO THE RESOLUTION OF THE MEASUREMENT, which is the reason it
	# is this small.  Arrival times are stamped when the loop READS a
	# request, so a 20 ms timeout meant several requests genuinely sent 25
	# ms apart could be read in one pass and stamped nearly identically -
	# reported as a pacing gate leaking badly, when what was leaking was
	# the instrument.  2 ms is comfortably finer than any interval worth
	# asserting on, and an idle loop at this rate costs nothing measurable.

	my @ready = $select->can_read(0.002);

	for my $sock (@ready)
	{
		if ($sock == $listen)
		{
			while (my $client = $listen->accept())
			{
				$client->blocking(0);
				$select->add($client);
				$pending{$client} = { buf => '' };
			}
			next;
		}

		my $buf = '';
		my $got = sysread($sock,$buf,8192);
		if (!defined($got) || $got == 0)
		{
			# EWOULDBLOCK looks the same as end of file here; a socket
			# with a request already parsed is left alone to be answered
			# by the deadline pass below.

			next if !defined($got) && $!{EWOULDBLOCK};
			if (!$pending{$sock} || !$pending{$sock}{out})
			{
				$select->remove($sock);
				close $sock;
				delete $pending{$sock};
			}
			next;
		}

		my $p = $pending{$sock} ||= { buf => '' };
		$p->{buf} .= $buf;
		next if $p->{buf} !~ /\r\n\r\n/;		# headers not complete
		next if $p->{out} || $p->{answered};	# already dealt with

		my ($path) = $p->{buf} =~ m{^\S+\s+(\S+)};
		$path = '/' if !defined $path;

		my ($delay,$out,$quit) = handle($path);

		# THE CONTROL ENDPOINTS ARE NOT TRAFFIC AND MUST NOT BE LOGGED.
		# /reset in particular clears the log and would then record itself,
		# leaving one entry behind at the moment a caller believes it has
		# an empty log -- which shows up as one extra request and as an
		# impossibly small gap before the first real one.  A measurement
		# that counts the act of starting the measurement is worse than no
		# measurement, because it looks right.

		if ($path !~ m{^/(stats|reset|quit)\b})
		{
			my $code = 0;
			($code) = $out =~ m{^HTTP/1\.1 (\d+)} if defined $out;
			push @log, {
				ms   => int((time() - $started) * 1000),
				path => $path,
				code => $code };
		}

		$p->{answered} = 1;
		$quit_at = 1 if $quit;

		if (!defined $out)
		{
			# /hang.  The socket is kept open and never written to,
			# which is what a client timeout needs to see.
			$p->{hang} = 1;
			next;
		}

		$p->{out} = $out;
		$p->{deadline} = time() + $delay;
	}

	# Deadlines, including the zero ones, which is what makes every
	# response go out through one path rather than two.

	for my $sock ($select->handles())
	{
		next if $sock == $listen;
		my $p = $pending{$sock} or next;
		next if !$p->{out} || time() < ($p->{deadline} // 0);

		syswrite($sock,$p->{out});
		$select->remove($sock);
		close $sock;
		delete $pending{$sock};
	}

	if ($quit_at && !grep { $pending{$_}{out} } keys %pending)
	{
		exit 0;
	}
}
