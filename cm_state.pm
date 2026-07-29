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
# read by em_server, and will be bumped by dm_ modules as well.  Only
# the foundational layer is below all of them.
#
# NOT PERSISTED YET.  The active source is view state and belongs in
# $temp_dir with the rest of it, but the workspace that will hold it
# does not exist.  Until it does, this resets at startup.

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
		getActiveSource
		setActiveSource
	);
}


our $dbg_state:shared = 0;
	# 0 = every bump, with what caused it


my $state_seq:shared		= 1;
my $active_source:shared	= '';


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


sub getActiveSource
	# The source the map is displaying, or '' if nothing has chosen one.
	# The fallback for '' belongs to whoever knows what sources exist,
	# which is not this module.
{
	return $active_source;
}


sub setActiveSource
{
	my ($id) = @_;
	$id //= '';
	return if $id eq $active_source;
	$active_source = $id;
	bumpState("active source is now '$id'");
}


1;
