#!/usr/bin/perl
#---------------------------------------------
# sweep_catalog.pl -- ask every catalog entry whether it answers
#---------------------------------------------
# NOT PART OF THE HEADLESS SUITE, and deliberately so.  It goes to the
# network sixteen times over, so it is run when somebody wants the answer
# rather than on every change.  test_catalog.pl asks whether every entry
# would LOAD; this asks whether the service on the other end of it is
# there.
#
# THE INSTRUMENT ALREADY EXISTED and this is only the loop.  dm_fetch is
# what the application uses, so a sentinel declared by an entry is
# classified here exactly as it would be in a build -- which is the whole
# reason not to do this with curl.  The catalog dialog's Test button is
# the same act performed by hand on one entry.
#
# WHY IT EXISTS.  Sixteen entries reached _res/catalog.json on the
# strength of documents rather than measurements, and four of them named
# an address that had never been fetched.  A catalog is a set of claims
# about services, and nothing but asking settles a claim like that.
#
# Every entry is asked at ITS OWN canonical point, which is what that
# field is for: a service cannot be asked about nowhere.

use strict;
use warnings;
use POSIX qw( floor );
use FindBin;
use lib "$FindBin::Bin/..";
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_source;
use dm_cache;
use dm_observe;
use dm_fetch;
use dm_catalog;

my $TMP = 'C:/_temp/base-apps-chartMaker';

$Pub::Utils::data_dir = "$TMP/sweep";
$Pub::Utils::temp_dir = "$TMP/sweep";

setStandardResourceDir("$app_dir/_res");


sub tileOf
	# lat/lon to tile x,y at zoom z -- web mercator, the fixed grid
{
	my ($lat,$lon,$z) = @_;
	my $n   = 2 ** $z;
	my $rad = $lat * 3.14159265358979 / 180;
	my $x   = floor(($lon + 180) / 360 * $n);
	my $y   = floor((1 - log(sin($rad)/cos($rad) + 1/cos($rad)) / 3.14159265358979) / 2 * $n);
	return ($x,$y);
}


sub levelsFor
	# THREE LEVELS, NOT ONE, because one answer cannot tell a service that
	# is absent here from a service that is absent everywhere, and a
	# ceiling is where the interesting failures live.  Low, middle, and as
	# deep as the entry claims -- clamped to 16, since past that a miss is
	# a statement about the ground rather than about the endpoint.
{
	my ($zmin,$zmax) = @_;
	my $hi = $zmax > 16 ? 16 : $zmax;
	my %seen;
	my @out;
	for my $want (6,11,$hi)
	{
		# A COPY, because foreach aliases its list and a literal is
		# read-only.  Perl says so twenty lines from where it matters.

		my $z = $want;
		$z = $zmin if $z < $zmin;
		$z = $zmax if $z > $zmax;
		next if $seen{$z}++;
		push @out,$z;
	}
	return @out;
}


my $err = loadCatalog();
die "catalog will not load: $err\n" if $err;

my $entries = catalogEntries();
printf("\n%d entries\n\n",scalar(@$entries));

for my $node (@$entries)
{
	my $tsd  = catalogTsd($node);
	my $can  = $node->{canonical};
	my $id   = $node->{id};

	if (!$can || !$can->{at})
	{
		printf("%-28s NO CANONICAL POINT\n",$id);
		next;
	}

	my ($lat,$lon) = @{$can->{at}};
	printf("%-14s %-28s %s\n",$node->{moniker} || '?',$id,$can->{where});

	# A DECLARED SLOT WITH NOTHING IN IT IS NOT A FINDING ABOUT THE
	# SERVICE.  sourceTileUrl refuses one, and reporting that refusal
	# beside a 404 would put our own gap in a column about theirs.

	if ($tsd->{credentials} && @{$tsd->{credentials}})
	{
		printf("     %-40s\n",'declares a credential slot - not asked');
		next;
	}

	for my $z (levelsFor($tsd->{zoom}{min},$tsd->{zoom}{max}))
	{
		my ($x,$y) = tileOf($lat,$lon,$z);
		my $r = fetchTile($tsd,$z,$x,$y);
		printf("     z%-3d %-8s %-6s %-9s %s\n",
			$z,
			$r->{status} || '?',
			$r->{http}   || '-',
			defined($r->{bytes}) ? length(${$r->{bytes}}).'b' :
				(defined($r->{format}) ? $r->{format} : '-'),
			$r->{reason} || ($r->{format} || ''));
	}
}

print "\ndone\n";

1;
