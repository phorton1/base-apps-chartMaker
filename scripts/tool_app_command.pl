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

my $BASE = 'http://localhost:9884';
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
