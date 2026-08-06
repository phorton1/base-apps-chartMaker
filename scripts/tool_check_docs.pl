#!/usr/bin/perl
#---------------------------------------------
# check_manual.pl -- links, images and ASCII over user_manual/
#---------------------------------------------
# Run from the folder to check:
#     cd user_manual && /c/Perl/bin/perl.exe -I/base C:/_temp/.../check_manual.pl
#
# Deliberately NOT in scripts/: it is a one-off check of one folder, and the
# repo already has test_doc.pl for the thing that is really a test.

use strict;
use warnings;

my @files;
sub walk
{
	my ($d) = @_;
	opendir(my $h,$d) or return;
	for my $e (sort readdir($h))
	{
		next if $e =~ /^\./;
		my $p = "$d/$e";
		if (-d $p) { walk($p) }
		elsif ($e =~ /\.md$/) { push @files,$p }
	}
	closedir($h);
}
walk(".");

my $bad = 0;
my $missing = 0;
for my $f (@files)
{
	open(my $fh,"<:raw",$f) or next;
	local $/;
	my $s = <$fh>;
	close($fh);

	my @lines = split(/\n/,$s);
	for my $i (0..$#lines)
	{
		if ($lines[$i] =~ /([^\x00-\x7F])/)
		{
			printf("NON-ASCII %s:%d\n",$f,$i+1);
			$bad++;
		}
	}
	my $base = $f;
	$base =~ s{/[^/]+$}{};

	while ($s =~ /\]\(([^)]+)\)/g)
	{
		my $t = $1;
		next if $t =~ m{^(https?:|#|mailto:)};
		my ($p) = split(/#/,$t);
		next if !length($p);
		if (!-e "$base/$p") { printf("MISSING LINK %s -> %s\n",$f,$t); $missing++; }
	}
	while ($s =~ /src="([^"]+)"/g)
	{
		my $t = $1;
		next if $t =~ m{^https?:};
		if (!-e "$base/$t") { printf("MISSING IMG  %s -> %s\n",$f,$t); $missing++; }
	}
}
printf("checked %d files, %d non-ascii line(s), %d missing target(s)\n",
	scalar(@files),$bad,$missing);
