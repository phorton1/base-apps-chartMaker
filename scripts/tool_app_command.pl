#!/usr/bin/perl
#---------------------------------------------
# drive.pl -- run a command in the live chartMaker and show its output
#---------------------------------------------
# usage:  perl drive.pl "<command>" [more commands...]
#
# Marks the output ring, dispatches each command, then reads back only
# what those commands produced.

use strict;
use warnings;
use LWP::UserAgent;
use JSON::PP;
use URI::Escape;

# 127.0.0.1, NEVER localhost.  On Windows 'localhost' resolves to ::1
# first, the server listens on IPv4 only, and every request pays for the
# failed IPv6 attempt before falling back -- when it falls back at all.
# This tool had it wrong and timed out against a perfectly healthy server.

my $BASE = 'http://127.0.0.1:9884';
my $ua   = LWP::UserAgent->new( timeout => 60 );

sub api
{
	my ($path) = @_;
	my $r = $ua->get("$BASE$path");
	die "chartMaker is not answering on $BASE ($path): ".$r->status_line()."\n"
		if !$r->is_success;
	return decode_json($r->content());
}

api('/api/command?cmd=mark');

for my $cmd (@ARGV)
{
	api('/api/command?cmd='.uri_escape($cmd));
}

my $log = api('/api/log?since=mark');
for my $line (@{$log->{lines}})
{
	my $text = $line->{text};
	$text =~ s/^\(\d+,\d+\)\s*\S+\[\d+\]\s*//;
	next if $text =~ /ServerBase|^mark:/;
	print "$text\n";
}
