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
	);
}


# The Cava resource root: dev = the in-repo _res folder, packaged = the
# bundled resource dir.  The Leaflet applet is served from $resource_dir/site.

setStandardResourceDir("$app_dir/_res");


# The console output ring buffer is what /api/log reads.  It is off by
# default in Pub::Utils and must be switched on once at startup; navMate
# gets this from Pub::Ray::NET::a_utils, which chartMaker does not use.

enableOutputRing(2000);


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
