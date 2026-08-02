# hold_port.pl -- occupy a tcp port and sit on it
#
# Deliberately uses NOTHING from /base - no Pub::Utils, no Win32::Console -
# so it cannot emit anything that corrupts a terminal.  Plain IO::Socket
# and a sleep loop.
#
# Binds WITHOUT Reuse, which is what ServerBase now does on windows too,
# so this is the same contention a second chartMaker would create.
#
#   perl hold_port.pl [port]
#
# Runs until killed.

use strict;
use warnings;
use IO::Socket::INET;

$| = 1;

my $port = shift(@ARGV) || 9884;

# NO LocalAddr, DELIBERATELY - the WILDCARD, because that is what
# ServerBase binds.  Binding 127.0.0.1 specifically does NOT collide with
# a wildcard bind: both succeed, the server comes up perfectly happy, and
# windows then routes incoming connections to the MOST SPECIFIC listener -
# so the only symptom is that a browser talks to the holder instead, and
# nothing that looks like a port conflict is reported anywhere.
# Reproduced exactly that, and spent a test on it.

my $sock = IO::Socket::INET->new(
	Proto     => 'tcp',
	LocalPort => $port,
	Listen    => 5 );

if (!$sock)
{
	print "FAILED to bind $port - $!\n";
	exit 1;
}

print "HOLDING port $port as pid $$\n";
print "chartMaker started now will not be able to open its server.\n";

# Never accept.  Just keep the listening socket alive.
while (1) { sleep(5) }
