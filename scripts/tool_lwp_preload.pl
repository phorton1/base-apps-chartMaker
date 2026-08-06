#!/usr/bin/perl
#---------------------------------------------
# tool_lwp_preload.pl
#---------------------------------------------
# WHAT LWP LOADS LAZILY ON chartMaker's FETCH PATH, discovered rather than
# guessed.
#
# WHY THIS EXISTS.  The engine pool is spawned before anything has made an
# http request, so its workers are cloned from an interpreter that has
# never used LWP.  The first map load then has four threads reaching the
# same lazy 'require' at the same instant, and Cava's packed loader hands
# concurrent readers garbage - observed as a packaged build reporting
# syntax errors inside module POD, and permanently poisoning %INC in three
# of four workers for the rest of the session.
#
# The fix is to load those modules at COMPILE time in dm_fetch, so the
# workers inherit them.  The fix is only as good as the LIST, and the list
# cannot be read off the source: LWP defers a dozen modules from a dozen
# places, and which ones this application reaches depends on which calls it
# makes.  Guessing produced two rounds of whack-a-mole.
#
# So this measures it: snapshot %INC, make one real request through the
# same _ua() the engine uses, and print what appeared.  Everything it lists
# is something a worker would otherwise have to require for itself.
#
# IT NEEDS THE NETWORK and fetches exactly one tile.
#
# Run from the repo root:
#   /c/Perl/bin/perl.exe -I/base scripts/tool_lwp_preload.pl > out.txt 2>&1

use strict;
use warnings;
use lib '/base/apps/chartMaker';
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_fetch;

# One tile of Esri World Imagery over north Ibiza - the same z/x/y the map
# asks for on a first run, and the request that was failing.

my $URL = 'https://services.arcgisonline.com/ArcGIS/rest/services/'.
	'World_Imagery/MapServer/tile/11/782/1032';

my %before = %INC;

my $ua = dm_fetch::_ua();
my $response = $ua->get($URL);

my %after = %INC;

# .pm ONLY.  %INC also picks up autosplit indexes (.ix) and .al bodies,
# which are loaded by the module that owns them and are not something
# anything can require by name.

my @loaded = sort grep { !$before{$_} && /\.pm$/ } keys %after;

print "\n";
print "request: ".$response->code." (".length($response->content || '')." bytes)\n";
print "modules in %INC before: ".scalar(keys %before)."\n";
print "modules in %INC after:  ".scalar(keys %after)."\n";
print "\n";
print "LOADED LAZILY BY THE FETCH PATH (".scalar(@loaded)."):\n";
for my $m (@loaded)
{
	(my $pkg = $m) =~ s/\.pm$//;
	$pkg =~ s{/}{::}g;
	printf("  %-34s  %s\n",$pkg,$m);
}
print "\n";
# EMITTED AS 'require' AND NOT 'use', which matters for at least one of
# them: 'use utf8' tells Perl the SOURCE FILE is utf8 and would change how
# dm_fetch itself is parsed.  require loads without calling import, which
# is exactly what LWP does with these anyway - it calls them fully
# qualified - so nothing needs importing and nothing can be changed by
# accident.

print "As preload lines for dm_fetch.pm:\n";
for my $m (@loaded)
{
	(my $pkg = $m) =~ s/\.pm$//;
	$pkg =~ s{/}{::}g;
	print "require $pkg;\n";
}
print "\n";
print "AN EMPTY LIST IS THE PASSING RESULT once dm_fetch preloads them.\n";
print "Anything still here is a module a worker would have to require for\n";
print "itself, on a thread, at the same moment as three others.\n\n";

1;
