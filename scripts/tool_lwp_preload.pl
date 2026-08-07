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

# EVERYTHING, and the .pm filter that used to be here was a real blind
# spot rather than tidiness.  utf8_heavy.pl is required BY NAME out of
# utf8.pm's AUTOLOAD, and the unicore/*.pl character tables are required
# by name out of that - and a packaged build lost three of four workers
# on exactly those files while this tool reported nothing to add.
#
# Autosplit indexes (.ix) and .al bodies are separated out rather than
# dropped: they are loaded by the module that owns them and cannot be
# required by name, so they are something to know about and not something
# to paste into a preload list.

my @all     = sort grep { !$before{$_} } keys %after;
my @loaded  = grep { !/\.(ix|al)$/ } @all;
my @autosplit = grep {  /\.(ix|al)$/ } @all;

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
	printf("  %-34s  %s\n",($m =~ /\.pm$/ ? $pkg : '(not a module)'),$m);
}
print "\n";
if (@autosplit)
{
	print "AUTOSPLIT BODIES, which cannot be preloaded by name (".
		scalar(@autosplit)."):\n";
	print "  $_\n" for @autosplit;
	print "\n";
}
# EMITTED AS 'require' AND NOT 'use', which matters for at least one of
# them: 'use utf8' tells Perl the SOURCE FILE is utf8 and would change how
# dm_fetch itself is parsed.  require loads without calling import, which
# is exactly what LWP does with these anyway - it calls them fully
# qualified - so nothing needs importing and nothing can be changed by
# accident.

print "As preload lines for dm_fetch.pm:\n";
for my $m (@loaded)
{
	if ($m !~ /\.pm$/)
	{
		# A .pl IS REQUIRED BY NAME AND CANNOT BE NAMED AS A PACKAGE.
		# It is also the kind that a preload usually cannot fix on its
		# own: utf8_heavy.pl loads a further table per character class,
		# so what has to be preloaded is the USE and not the file.

		print "require '$m';\t\t# by name, and check what IT loads lazily\n";
		next;
	}
	(my $pkg = $m) =~ s/\.pm$//;
	$pkg =~ s{/}{::}g;
	print "require $pkg;\n";
}
print "\n";
print "AN EMPTY LIST IS THE PASSING RESULT once dm_fetch preloads them.\n";
print "Anything still here is a module a worker would have to require for\n";
print "itself, on a thread, at the same moment as three others.\n\n";
print "AND AN EMPTY LIST IS NOT A CLEAN BILL OF HEALTH.  This measures ONE\n";
print "SUCCESSFUL FETCH, so nothing on an error path, nothing behind a TLS\n";
print "reconnect and nothing a later phase of a build reaches is in it.\n";
print "dm_engine unpoisons %INC and retries for exactly that reason.\n\n";

1;
