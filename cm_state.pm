#!/usr/bin/perl
#---------------------------------------------
# cm_state.pm
#---------------------------------------------
# The version counter the map polls, and the view state it publishes.
#
# ONE COUNTER, ONE DOCUMENT.  Anything that changes what the map should
# be showing calls bumpState().  The browser polls /poll, sees a number
# it has not rendered, and refetches /state -- the whole of it, not a
# delta.  There is deliberately no second channel: every later addition
# (regions, evaluator results, build progress) arrives in the same
# document behind the same counter, so no two parts of the display can
# be out of step with one another.
#
# WHY THIS IS A cm_ MODULE.  The counter is bumped from em_command and
# read by em_server, and is bumped by dm_ modules as well.  Only the
# foundational layer is below all of them.
#
# THE ACTIVE SOURCE USED TO LIVE HERE, as unpersisted view state waiting
# for somewhere to be remembered.  It now lives in dm_source, which owns
# the selection AND resolves it against what the folder actually holds,
# and it is remembered in the ini across a session.  There is one
# selection rather than a session one and a stored one: what you last
# picked is what you want next time, which is all a radio button ever
# meant.

package cm_state;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		bumpState
		getStateSeq
	);
}


our $dbg_state:shared = 0;
	# 0 = every bump, with what caused it


my $state_seq:shared		= 1;


sub getStateSeq
{
	return $state_seq;
}


sub bumpState
	# Every caller says why, because "the version changed and the map
	# redrew" is otherwise the least debuggable kind of event.
{
	my ($why) = @_;
	$state_seq++;
	display($dbg_state,0,"state $state_seq: ".($why // 'changed'));
	return $state_seq;
}


1;
