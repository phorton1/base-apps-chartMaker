#!/usr/bin/perl
#---------------------------------------------
# tool_prune_absent.pl -- declared-absent tiles become recorded absences
#---------------------------------------------
# Some sources answer a request for ground they do not hold with 200 and a
# fixed image saying so in words, rather than with 404.  A TSD records the
# bytes of such an image in absent_fingerprints, and from that moment
# dm_fetch treats a match as the absence it is - but only for tiles it
# handles AFTER the declaration.  Tiles already sitting in the cache from
# before were stored as good imagery.
#
# This converts them, for one source, from the command line.
#
# NOT A DELETE.  Deleting would make each tile unknown again and it would
# be refetched on the next pass; the '.none' marker IS the knowledge that
# the source does not have it, which is what stops the request and what
# lets the exporter express the hole natively.
#
# Ordinarily unnecessary: dm_fetch checks on the way out of the cache as
# well as the way in, so a newly declared fingerprint reclassifies tiles
# lazily as they are asked for.  This is for doing it all at once - after
# a probe, or before measuring what a build would actually cost.
#
# IT IS NOW A WRAPPER ON dm_clean, and it had to become one.  It carried
# its own copy of the fingerprint test and its own marker writer, and the
# writer had gone quietly wrong: it wrote an EMPTY .none, which reads back
# as a plain absence, so every tile it converted lost the one thing that
# made it interesting - that the service answered 200 with a picture
# saying nothing rather than saying nothing.  The GUI does this through
# dm_clean; so does this; there is one rule and one writer.
#
#	perl tool_prune_absent.pl [source_id] [--go]
#
# Without --go it reports and touches nothing.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_set;
use dm_source;
use dm_clean;

my $go = grep { $_ eq '--go' } @ARGV;
my $id = (grep { !/^--/ } @ARGV)[0] || $DEFAULT_VIEW_SOURCE_ID;

setStandardDataDir($appName);
setStandardTempDir($appName);
init_prefs();
loadSources();

my $src = getSource($id);
die "no source '$id' - try one of: ".join(', ',getSourceIds())."\n" if !$src;

my $fps = $src->{absent_fingerprints} || [];
die "'$id' declares no absent_fingerprints - nothing to match\n" if !@$fps;

my $key = $src->{cache_key};

print "source     $id\n";
print "cache      ",cacheDir(),"/$key\n";
print "matching   ",join(", ",map { "$_->{bytes}b $_->{md5}" } @$fps),"\n";
print $go ? "MODE       ACTING\n" : "MODE       dry run (pass --go to act)\n";
print "\n";

# THE DRY RUN IS THE SURVEY ITSELF, not a second pass written to resemble
# it.  What it prints is what the act would then do, because the same
# function counted it.

my $rows = cleanSurvey({ keys => [ $key ] });
my $row  = $rows->[0];
die "no cache for '$key'\n" if !$row;

printf("%d tiles examined, %d are the declared placeholder (%s)\n",
	$row->{tiles},$row->{sent_tiles},prettyBytes($row->{sent_bytes}));

exit(0) if !$go || !$row->{sent_tiles};

my $report = cleanAct(undef,[ $key ],{ sentinels => 1 });
print "\n";
print "$_\n" for @{cleanReportLines($report)};
