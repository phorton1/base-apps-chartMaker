#!/usr/bin/perl
#---------------------------------------------
# em_command.pm
#---------------------------------------------
# The chartMaker command vocabulary and dispatcher.
#
# This module sits BENEATH both front doors.  em_console.pm reads a line
# from the console and em_server.pm reads an /api/command request, and
# both hand this dispatcher the same verb.  One vocabulary, two
# transports -- which is also the test surface: anything the console can
# do, an HTTP client can do.
#
# Command output goes to display(), which lands in the Pub::Utils output
# ring, which is what /api/log returns.

package em_command;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;
use cm_defs;
use cm_prefs;
use cm_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		dispatchCommand
		getMarkSeq
	);
}


my $mark_seq:shared = 0;


sub getMarkSeq
	# The sequence number stamped by the last 'mark' command.
	# em_server's /api/log?since=mark reads this.
{
	return $mark_seq;
}


sub commandHelp
{
	return [
		[ '?|help',				'show this help'											],
		[ 'mark',				'stamp the output ring for /api/log?since=mark'				],
		[ 'version',			'show the application name and its standard directories'	],
		[ 'prefs',				'list the current preferences'								],
		[ 'map',				'open the Leaflet map in a browser'							],
		[ 'dbg [name] [value]',	'list, show, or set a $dbg_xxx debug level at runtime'		],
	];
}


sub findDebugVars
	# Walk the symbol table for package scalars named dbg_*, which is
	# possible only because they are declared 'our'.  Returns a hash of
	# fully qualified name => scalar ref.  A var that was never given a
	# value is skipped, so this finds declarations rather than typos.
{
	my ($pkg,$depth,$seen,$found) = @_;
	$pkg   ||= 'main::';
	$depth ||= 0;
	$seen  ||= {};
	$found ||= {};
	return $found if $depth > 6;

	no strict 'refs';
	for my $key (keys %{$pkg})
	{
		if ($key =~ /::$/)
		{
			my $child = $pkg eq 'main::' ? $key : $pkg.$key;
			next if $child eq 'main::';
			next if $seen->{$child}++;
			findDebugVars($child,$depth+1,$seen,$found);
		}
		elsif ($key =~ /^dbg_/)
		{
			my $full = ($pkg eq 'main::' ? '' : $pkg).$key;
			my $ref  = \${$full};
			$found->{$full} = $ref if defined($$ref);
		}
	}
	return $found;
}


sub _dbgCommand
	# dbg                  - list every $dbg_xxx and its current value
	# dbg <name>           - show one (bare name matches any package)
	# dbg <name> <value>   - set one
{
	my ($rpart) = @_;
	my ($name,$value) = split(/\s+/,$rpart,2);
	my $vars = findDebugVars();

	if (!defined($name) || $name eq '')
	{
		display(0,0,"debug variables");
		for my $full (sort keys %$vars)
		{
			display(0,1,sprintf("%-44s = %s",$full,${$vars->{$full}}));
		}
		return;
	}

	my @matches = $name =~ /::/ ?
		grep { $_ eq $name } keys %$vars :
		grep { /(?:^|::)\Q$name\E$/ } keys %$vars;

	if (!@matches)
	{
		warning(0,0,"dbg: no debug variable matching '$name'");
	}
	elsif (@matches > 1 && defined($value) && $value ne '')
	{
		warning(0,0,"dbg: '$name' is ambiguous - ".join(', ',sort @matches));
	}
	else
	{
		for my $full (sort @matches)
		{
			${$vars->{$full}} = int($value)
				if defined($value) && $value ne '';
			display(0,0,"dbg: $full = ".${$vars->{$full}});
		}
	}
}


sub dispatchCommand
{
	my ($lpart,$rpart) = @_;
	$lpart = lc($lpart // '');
	$rpart //= '';
	return if !length($lpart);

	if ($lpart eq 'mark')
	{
		$mark_seq = getOutputRingSeq();
		display(0,0,"mark: $mark_seq");
	}
	elsif ($lpart eq 'version')
	{
		display(0,0,"$appName");
		display(0,1,"app_dir      = $app_dir");
		display(0,1,"data_dir     = $data_dir");
		display(0,1,"temp_dir     = $temp_dir");
		display(0,1,"resource_dir = $resource_dir");
		display(0,1,"packaged     = ".($Cava::Packager::PACKAGED ? 1 : 0));
	}
	elsif ($lpart eq 'prefs')
	{
		my $prefs = getAllPrefs();
		display(0,0,"prefs");
		for my $key (sort keys %$prefs)
		{
			display(0,1,"$key = '$prefs->{$key}'");
		}
	}
	elsif ($lpart eq 'map')
	{
		openMapBrowser();
	}
	elsif ($lpart eq 'dbg')
	{
		_dbgCommand($rpart);
	}
	elsif ($lpart eq '?' || $lpart eq 'help')
	{
		my $entries = commandHelp();
		my $max_sig = 0;
		for my $e (@$entries)
		{
			my $len = length($e->[0]);
			$max_sig = $len if $len > $max_sig;
		}
		display(0,0,"Commands:");
		for my $e (@$entries)
		{
			display(0,1,sprintf("%-*s  %s",$max_sig,$e->[0],$e->[1]));
		}
	}
	else
	{
		warning(0,0,"unknown command '$lpart'  (try ? for help)");
	}
}


1;
