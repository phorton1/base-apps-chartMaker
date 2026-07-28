#!/usr/bin/perl
#---------------------------------------------
# em_console.pm
#---------------------------------------------
# Console keyboard input handler.
#
# Reads Win32 console events in a detached thread and dispatches complete
# command lines to the caller-supplied handler.  Windows only -- the
# application runs without it elsewhere, it simply has no console input.
#
# Modelled on Pub::Ray::NET::s_serial.pm, which chartMaker cannot use
# because it does not depend on Pub::Ray.

package em_console;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep);
use Pub::Utils;
use Win32::Console;


my $command_handler;
my $console_in;
my $buffer:shared = '';


sub new
{
	my ($class,$handler) = @_;
	$command_handler = $handler;
	display(0,0,"em_console new()");

	my $this = shared_clone({});
	bless $this,$class;

	$console_in = Win32::Console->new(STD_INPUT_HANDLE);
	$console_in->Mode(ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT) if $console_in;
	error("could not open Win32::Console") if !$console_in;
	display(0,1,"Win32::Console opened");

	return $this;
}


sub start
{
	display(0,0,"em_console start()");
	my $console_thread = threads->create(\&consoleThread);
	$console_thread->detach();
}


sub isEventCtrlC
	# my ($type,$key_down,$repeat_count,$key_code,$scan_code,$char,$key_state) = @event;
{
	my (@event) = @_;
	if ($event[0] &&
		$event[0] == 1 &&		# key event
		$event[5] == 3)			# char = 0x03
	{
		warning(0,0,"ctrl-C pressed ...");
		return 1;
	}
	return 0;
}


sub getChar
{
	my (@event) = @_;
	if ($event[0] &&
		$event[0] == 1 &&		# key event
		$event[1] == 1 &&		# key down
		$event[5])				# char
	{
		return chr($event[5]);
	}
	return undef;
}


sub handleCommandLine
{
	my $lpart = $buffer;
	my $rpart = '';
	($lpart,$rpart) = ($1,$2) if $buffer =~ /^(.*?) (.*)$/;
	$lpart = lc($lpart);
	$lpart =~ s/^\s+|\s+$//g;
	$rpart =~ s/^\s+|\s+$//g;
	&{$command_handler}($lpart,$rpart);
	$buffer = '';
}


sub consoleThread
{
	display(0,0,"consoleThread() started");
	while (1)
	{
		if ($console_in->GetEvents())
		{
			my @event = $console_in->Input();
			if (@event && isEventCtrlC(@event))
			{
				warning(0,0,"EXITING PROGRAM from consoleThread()");
				kill 6,$$;
			}
			my $char = getChar(@event);
			if (defined($char))
			{
				if (ord($char) == 4)			# CTRL-D
				{
					clearConsole();
					next;
				}

				$CONSOLE->Write($char);
				if (ord($char) == 0x0d)			# return
				{
					$CONSOLE->Write("\n");
					$buffer =~ s/^\s+|\s$//g;
					handleCommandLine() if length($buffer);
				}
				elsif (ord($char) == 0x08)		# backspace
				{
					my $len = length($buffer);
					if ($len)
					{
						$buffer = substr($buffer,0,$len-1);
						$CONSOLE->Write(' '.$char);
					}
				}
				else
				{
					$buffer .= $char;
				}
			}
		}
		else
		{
			sleep(0.1);
		}

	}	# while (1)
}	# consoleThread()


1;
