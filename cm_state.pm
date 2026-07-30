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

		getSelection
		setSelection

		getEditState
		setEditState
		clearEditState
		editLocks

		$EDIT_BROWSE
		$EDIT_SHAPE
		$EDIT_DRAW
	);
}


our $dbg_state:shared = 0;
	# 0 = every bump, with what caused it


my $state_seq:shared		= 1;


#---------------------------------------------
# the selection
#---------------------------------------------
# ONE OBJECT AT A TIME, SHARED BY EVERY SURFACE.  The tree and the map
# cannot agree about what 'delete' means if each has its own idea of what
# is selected, so the selection is application state rather than a wx
# detail or a browser variable.
#
# Held as two ids: the ROOT region, and optionally a subregion beneath
# it.  Not a reference to a region hash - that is replaced wholesale on
# every rescan, and a stale reference is the classic way to edit a
# region that no longer exists.

my $sel_region:shared	= '';
my $sel_sub:shared		= '';


sub getSelection
	# ($region_id,$sub_id).  Either may be ''.
{
	return ($sel_region,$sel_sub);
}


sub setSelection
{
	my ($region_id,$sub_id) = @_;
	$region_id //= '';
	$sub_id    //= '';
	return 0 if $region_id eq $sel_region && $sub_id eq $sel_sub;

	$sel_region = $region_id;
	$sel_sub    = $sub_id;
	bumpState("selection is '".($sub_id || $region_id || 'none')."'");
	return 1;
}


#---------------------------------------------
# the edit state
#---------------------------------------------
# WHAT A CLICK ON THE MAP DOES, plus which object it does it to, plus
# whether that object has uncommitted changes.  See
# docs/design/editing.md.
#
# Published rather than kept in the browser, because THE OTHER SURFACE
# CAN DESTROY WHAT IS BEING EDITED - deleting a region in the tree while
# the map is drawing it is otherwise one click away.  So this is a
# constraint on every surface, not an announcement by one of them.
#
# DIRTY IS NOT A MODE.  A polygon can be selected with its handles up and
# nothing moved (clean SHAPE), or renamed but not saved (dirty BROWSE).
# Conflating the two leaves nowhere to put vertex editing.

our $EDIT_BROWSE	= 'browse';
our $EDIT_SHAPE		= 'shape';
our $EDIT_DRAW		= 'draw';

my $edit_mode:shared	= 'browse';
my $edit_region:shared	= '';
my $edit_sub:shared		= '';
my $edit_dirty:shared	= 0;


sub getEditState
{
	return {
		mode	=> $edit_mode,
		region	=> $edit_region,
		sub		=> $edit_sub,
		dirty	=> $edit_dirty ? 1 : 0,
	};
}


sub setEditState
{
	my ($mode,$region_id,$sub_id,$dirty) = @_;
	$mode      = $EDIT_BROWSE if !defined($mode) || !length($mode);
	$region_id //= '';
	$sub_id    //= '';
	$dirty     = $dirty ? 1 : 0;

	return 0 if $mode eq $edit_mode && $region_id eq $edit_region &&
				$sub_id eq $edit_sub && $dirty == $edit_dirty;

	$edit_mode   = $mode;
	$edit_region = $region_id;
	$edit_sub    = $sub_id;
	$edit_dirty  = $dirty;

	bumpState("edit: $mode".($region_id ? " '".($sub_id || $region_id)."'" : '').
		($dirty ? ' DIRTY' : ''));
	return 1;
}


sub clearEditState
{
	return setEditState($EDIT_BROWSE,'','',0);
}


sub editLocks
	# The one question every other surface asks: is something in a state
	# that forbids what I am about to do?  Returns a description of the
	# obstacle, or '' if there is none.
	#
	# DIRTY IS WHAT CONSTRAINS, NOT THE MODE - a clean SHAPE is as free as
	# BROWSE, because handles being visible has never put anything at
	# risk.  DRAW is the exception: it holds an unfinished ring that any
	# other action would strand.
{
	return "'".($edit_sub || $edit_region)."' has unsaved changes"
		if $edit_dirty && ($edit_region || $edit_sub);
	return "a polygon is being drawn"
		if $edit_mode eq $EDIT_DRAW;
	return '';
}


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
