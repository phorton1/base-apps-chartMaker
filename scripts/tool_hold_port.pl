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

# 127.0.0.1 DELIBERATELY, because that is the address chartMaker's server
# binds - em_server passes HTTP_HOST, so ServerBase gives IO::Socket a
# LocalAddr instead of the wildcard.  The holder has to bind the SAME
# address to contend for the port at all.  MEASURED, all four orderings,
# Reuse off: two loopback binds collide and two wildcard binds collide,
# but a wildcard and a loopback bind on one port BOTH SUCCEED in either
# order.  A mismatched holder therefore reports nothing that looks like a
# conflict - the server comes up perfectly happy, windows routes incoming
# connections to the most specific listener, and the only symptom is a
# browser talking to the wrong process.

my $sock = IO::Socket::INET->new(
	Proto     => 'tcp',
	LocalAddr => '127.0.0.1',
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
