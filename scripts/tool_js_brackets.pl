#!/usr/bin/perl
#---------------------------------------------
# tool_js_brackets.pl
#---------------------------------------------
# THE ONLY VERIFICATION THE APPLET CAN GET HERE.  There is no JavaScript
# engine on this machine, so _res/site/*.js cannot be run, linted or
# syntax-checked before it is handed to a browser.  What CAN be checked
# mechanically is that the brackets balance, which catches the one mistake
# an editing pass actually makes: a block left half closed.
#
# IT PROVES ALMOST NOTHING and should not be mistaken for a lint.  Balanced
# brackets say the file is not obviously truncated.  They say nothing about
# whether it runs.
#
# THE HARD PART IS NOT THE BRACKETS, it is knowing which ones are CODE.
# A first version stripped comments and then each kind of string in turn,
# and reported two errors in files nobody had touched:
#
#   map.js      "' "            a single quote inside a double-quoted string
#   cmProbe.js  /[&<>"]/g       a double quote inside a regex literal
#
# Both were the checker mangling the file, which is the worst failure a
# checking tool can have - it sends somebody hunting a bug that is not
# there. So this makes ONE left-to-right pass over the source, so that
# whichever quote opens first wins, and it recognises regex literals.
#
# Regex-versus-division is genuinely ambiguous in JavaScript without
# parsing it, so this uses the standard heuristic: a '/' is a regex only
# where a value cannot already have ended - after '(', ',', '=', ':', '[',
# '!', '&', '|', '?', '{', '}', ';', 'return', or the start of the file.
# That is right for everything this applet contains, and a case it got
# wrong would show up as a bracket error rather than as silence.
#
# Run from the repo root:
#   /c/Perl/bin/perl.exe scripts/tool_js_brackets.pl _res/site/*.js

use strict;
use warnings;

my @files = @ARGV;
@files = glob('_res/site/*.js') if !@files;
die "no files\n" if !@files;

my $bad = 0;

for my $file (@files)
{
	$bad++ if !checkFile($file);
}

print "\n";
print $bad ? "$bad file(s) with problems\n" : "all balanced\n";
exit($bad ? 1 : 0);


sub stripNonCode
	# Replace every comment, string and regex literal with whitespace,
	# preserving newlines so reported line numbers stay true.  ONE PASS,
	# left to right - see the header.
{
	my ($s) = @_;
	my $out = '';
	my $prev = '';			# last significant code character seen

	while (length $s)
	{
		# a comment
		if ($s =~ s{^(/\*.*?\*/)}{}s || $s =~ s{^(//[^\n]*)}{})
		{
			$out .= blankOut($1);
			next;
		}

		# a string, in any of the three quotes
		if ($s =~ s{^('(?:\\.|[^'\\])*')}{}s ||
			$s =~ s{^("(?:\\.|[^"\\])*")}{}s ||
			$s =~ s{^(`(?:\\.|[^`\\])*`)}{}s)
		{
			$out .= blankOut($1);
			$prev = 'x';	# a string IS a value, so a '/' after it divides
			next;
		}

		# a regex literal, but only where a value cannot already have ended
		if ($s =~ m{^/} && $prev =~ /^[(,=:\[!&|?{};]?$/)
		{
			if ($s =~ s{^(/(?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\\n])+/[gimsuy]*)}{})
			{
				$out .= blankOut($1);
				$prev = 'x';
				next;
			}
		}

		my $c = substr($s,0,1,'');
		$out .= $c;
		$prev = $c if $c =~ /\S/;
	}
	return $out;
}


sub blankOut
	# The same text as whitespace, keeping its newlines.
{
	my ($t) = @_;
	$t =~ s/[^\n]/ /g;
	return $t;
}


sub checkFile
{
	my ($file) = @_;

	my $fh;
	if (!open($fh,'<',$file))
	{
		print "$file\n  CANNOT READ: $!\n";
		return 0;
	}
	binmode $fh;
	local $/ = undef;
	my $raw = <$fh>;
	close $fh;

	print "$file\n";

	my $ok = 1;
	if ($raw =~ /[^\x00-\x7F]/)
	{
		# The repo is ascii-only everywhere, applet included.
		print "  non-ascii: PRESENT - fix\n";
		$ok = 0;
	}

	my $code = stripNonCode($raw);

	my %open  = ( '(' => ')', '{' => '}', '[' => ']' );
	my %close = reverse %open;

	my @stack;
	my $line = 1;
	my $err  = '';

	for my $c (split //,$code)
	{
		$line++ if $c eq "\n";
		if ($open{$c})
		{
			push @stack,[$c,$line];
		}
		elsif ($close{$c})
		{
			my $top = pop @stack;
			if (!$top)
			{
				$err = "unmatched '$c' at line $line";
				last;
			}
			if ($open{$top->[0]} ne $c)
			{
				$err = "expected '$open{$top->[0]}' opened at line ".
					   "$top->[1], got '$c' at line $line";
				last;
			}
		}
	}
	$err = "unclosed '$stack[-1][0]' opened at line $stack[-1][1]"
		if !$err && @stack;

	if ($err)
	{
		print "  brackets:  ERROR - $err\n";
		$ok = 0;
	}
	else
	{
		print "  brackets:  balanced\n";
	}
	return $ok;
}


1;
