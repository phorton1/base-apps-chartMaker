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
	};
	return $class->SUPER::new($params);
}


sub handle_request
{
	my ($this,$client,$request) = @_;
	my $uri = $request->{uri} || '';

	display($dbg_request+1,0,"request method=$request->{method} uri=$uri");

	if ($uri eq '/api/command')
	{
		return $this->api_command($request)
	}
	elsif ($uri eq '/api/log')
	{
		return $this->api_log($request)
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


1;
