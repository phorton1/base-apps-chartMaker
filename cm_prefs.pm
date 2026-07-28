#!/usr/bin/perl
#---------------------------------------------
# cm_prefs.pm
#---------------------------------------------
# chartMaker preferences.
#
# No prefs file is written by default.  The changeable prefs are placed
# into the prefs hash as in-hash non-defaults: they ARE the discoverable
# list, and a hand-made chartMaker.prefs in $data_dir overrides any of
# them.  set-only-if-absent never clobbers a user's file value.
#
# Defaults live in code at their natural site -- HTTP_PORT's default is in
# em_server.pm's new(), because that is the module that knows what a port
# is for.

package cm_prefs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		init_prefs
		$PREF_HTTP_PORT
		$PREF_MAP_BROWSER
	);
	push @EXPORT, grep { $_ ne 'initPrefs' } @Pub::Prefs::EXPORT;
}


our $PREF_HTTP_PORT		= 'HTTP_PORT';
our $PREF_MAP_BROWSER	= 'MAP_BROWSER';


sub init_prefs
{
	Pub::Prefs::initPrefs("$data_dir/$appName.prefs", {});

	setPref($PREF_MAP_BROWSER,'')
		if !defined getPref($PREF_MAP_BROWSER);
}


1;
