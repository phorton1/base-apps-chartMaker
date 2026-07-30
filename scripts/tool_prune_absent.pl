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
# This walks a source's cache and converts them.
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
#	perl tool_prune_absent.pl [source_id] [--go]
#
# Without --go it reports and touches nothing.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Digest::MD5 qw( md5_hex );
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_set;
use dm_source;

my $go = grep { $_ eq '--go' } @ARGV;
my $id = (grep { !/^--/ } @ARGV)[0] || $DEFAULT_SOURCE_ID;

setStandardDataDir($appName);
setStandardTempDir($appName);
init_prefs();
loadSources();

my $src = getSource($id);
die "no source '$id' - try one of: ".join(', ',getSourceIds())."\n" if !$src;

my $fps = $src->{absent_fingerprints} || [];
die "'$id' declares no absent_fingerprints - nothing to match\n" if !@$fps;

my %want = map { $_->{bytes} => $_->{md5} } @$fps;
my $root = cacheDir()."/$src->{cache_key}";
die "no cache at $root\n" if !-d $root;

print "source     $id\n";
print "cache      $root\n";
print "matching   ",join(", ",map { "$_->{bytes}b $_->{md5}" } @$fps),"\n";
print $go ? "MODE       ACTING\n" : "MODE       dry run (pass --go to act)\n";
print "\n";

opendir(my $rh,$root) or die "cannot read $root: $!\n";
my @zooms = sort { $a <=> $b } grep { /^\d+$/ && -d "$root/$_" } readdir($rh);
closedir $rh;

my ($total,$hit,$done) = (0,0,0);

for my $z (@zooms)
{
	my $dir = "$root/$z";
	opendir(my $dh,$dir) or next;
	my @files = grep { !/^\.\.?$/ && !/\.none$/ } readdir($dh);
	closedir $dh;

	my $zhit = 0;
	for my $leaf (@files)
	{
		my $path = "$dir/$leaf";
		$total++;
		my $len = -s $path;
		next if !defined($len) || !$want{$len};

		open(my $fh,'<',$path) or next;
		binmode $fh;
		local $/;
		my $data = <$fh>;
		close $fh;
		next if md5_hex($data) ne $want{$len};

		$zhit++;
		$hit++;
		next if !$go;

		# The marker first, then the image.  Dying between the two leaves
		# a recorded absence with a stale image beside it, which cacheGet
		# resolves in favour of the image - recoverable.  The other order
		# would leave the tile unknown, which is a refetch.

		(my $stem = $leaf) =~ s/\.[^.]+$//;
		my $none = "$dir/$stem.none";
		open(my $nh,'>',$none) or do { warn "cannot write $none: $!\n"; next };
		close $nh;
		unlink($path) or warn "cannot remove $path: $!\n";
		$done++;
	}
	printf("  z%-2d  %5d files  %5d are the placeholder\n",$z,scalar(@files),$zhit)
		if @files;
}

print "\n";
printf("%d tiles examined, %d matched%s\n",$total,$hit,
	$go ? ", $done converted to recorded absences" : " (nothing changed)");
