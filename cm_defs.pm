#!/usr/bin/perl
#---------------------------------------------
# cm_defs.pm
#---------------------------------------------
# chartMaker foundational constants.  Depends on nothing but Pub::.
#
# $appName lives HERE rather than in w_resources.pm (where navMate keeps
# its equivalent) because chartMaker.pm needs it to establish the standard
# directories before any wx module has been compiled.

package cm_defs;
use strict;
use warnings;
use threads;
use threads::shared;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appName
		$appVersion
		$app_dir

		$WIN_REGIONS
		$WIN_SOURCES
		$COMMAND_OPEN_MAP
	);
}


our $appName = 'chartMaker';

# Identifies the application to tile servers in dm_fetch's User-Agent.
# A client that fetches systematically should say who it is.

our $appVersion = '0.1';

our $app_dir = $^O eq 'MSWin32' ?
	'C:\dat\openCPN\chartMaker' :
	'/dat/openCPN/chartMaker';


#---------------------------------------------
# command and window ids
#---------------------------------------------
# Pub::WX reserves everything below 200 for system use.
# chartMaker uses the 10000 range, as navMate does.

# Panes are 10001..10019, plain commands from 10020.

our $WIN_REGIONS		= 10001;
our $WIN_SOURCES		= 10002;

our $COMMAND_OPEN_MAP	= 10021;


1;
