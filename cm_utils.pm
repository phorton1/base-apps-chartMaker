#!/usr/bin/perl
#---------------------------------------------
# cm_utils.pm
#---------------------------------------------
# chartMaker foundational utilities.  No wx, no threads of its own.
#
# Two things happen at load time, both of which must happen before
# anything else in the application runs.

package cm_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use cm_defs;
use cm_prefs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		openMapBrowser
		newProgress
		progressCancelled
	);
}


# The Cava resource root: dev = the in-repo _res folder, packaged = the
# bundled resource dir.  The Leaflet applet is served from $resource_dir/site.

setStandardResourceDir("$app_dir/_res");


# The console output ring buffer is what /api/log reads.  It is off by
# default in Pub::Utils and must be switched on once at startup; navMate
# gets this from Pub::Ray::NET::a_utils, which chartMaker does not use.

enableOutputRing(2000);


#---------------------------------------------
# the two-level progress record
#---------------------------------------------
# A build runs on a worker thread and is watched by a wx dialog on the
# main one.  THE RECORD IS THE ONLY THING THAT CROSSES, and it crosses in
# one direction each way: the worker writes the counters and reads
# {cancelled}, the dialog writes {cancelled} and reads the counters.  No
# wx call is ever made from the worker and no model call is ever made from
# the dialog, which is the same rule that made cm_visibility unnecessary.
#
# It lives HERE, below both, so that dm_build can be driven headlessly by
# the console and by a test with no wx anywhere in the process -- a build
# that could only be run from a dialog would be a build that could not be
# tested.  w_progress reads these keys and creates none of them.
#
# TWO LEVELS BECAUSE THE WAIT HAS TWO SHAPES.  The outer is regions, which
# is a number the user chose and can predict.  The inner is tiles within
# one region, which is thousands and is where the hour actually goes.  One
# bar for the whole build would sit at 20% for fifteen minutes and tell
# nobody whether anything was happening.

sub newProgress
{
	my ($total,$label) = @_;
	my $p = &threads::shared::share({});

	$p->{active}	= 0;
	$p->{cancelled}	= 0;
	$p->{error}		= '';
	$p->{phase}		= '';

	$p->{total}		= ($total || 0) + 0;	# regions
	$p->{done}		= 0;
	$p->{label}		= $label // '';

	$p->{sub_total}	= 0;					# tiles in the current region
	$p->{sub_done}	= 0;
	$p->{sub_label}	= '';

	# THE RESULT COMES BACK AS TEXT, and that is not a shortcut.  A report
	# is a nest of hashes and arrays that cannot cross a thread boundary
	# as a reference, and shared_clone'ing the whole thing back would be a
	# second representation of it -- one for the console and one for the
	# dialog, free to drift.  So the worker renders it with the SAME
	# buildReportLines() the console calls and puts the lines here.  There
	# is one rendering, and both surfaces read it.

	$p->{finished}	= 0;
	$p->{ok}		= 0;
	$p->{guard}		= '';
	$p->{lines}		= &threads::shared::share([]);

	return $p;
}


sub progressCancelled
	# The one question the worker asks, and it must tolerate having no
	# record at all -- the console drives a build with no dialog and
	# nothing to cancel from.
{
	my ($p) = @_;
	return 0 if !$p;
	return $p->{cancelled} ? 1 : 0;
}


sub openMapBrowser
	# Open the Leaflet map in a browser.  The MAP_BROWSER pref (if set)
	# precedes the URL -- e.g. 'firefox --new-window' to force a separate
	# window; empty means the system default browser.
{
	# 127.0.0.1, NOT localhost.  On Windows 'localhost' resolves to ::1
	# first, the server listens on IPv4 only, and every request pays for
	# the failed IPv6 attempt before falling back -- measured at 220ms
	# per request against 3.5ms by address.  It went unnoticed until the
	# map started drawing its tiles through this application, at which
	# point every tile paid it instead of just the page.  map.js uses
	# relative urls, so the whole applet inherits whatever is used here.

	my $browser = getPref($PREF_MAP_BROWSER) // '';
	my $url     = 'http://127.0.0.1:'.getPref($PREF_HTTP_PORT).'/map.html';
	display(0,0,"openMapBrowser($url)");
	if (is_win())
	{
		my $cmd = $browser ? "start $browser $url" : "start \"\" $url";
		system(1, "cmd /c $cmd");
	}
	else
	{
		my $cmd = $browser ? "$browser $url" : "xdg-open $url";
		system("$cmd &");
	}
}


1;
