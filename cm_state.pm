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
# A SECOND COUNTER SAYS WHETHER THE MODEL MOVED, and it is not published
# to anybody.  Selecting an object and entering an edit both change what
# the display should show, so both bump the poll counter -- but neither
# changes a polygon or a zoom, and anything derived from the geometry is
# still valid across them.  Coverage costs about a second for a set, so
# a cache keyed on the poll counter is thrown away by every click in the
# tree.  bumpView() is the poll counter alone; bumpState() is both.
#
# THE DEFAULT IS THE SAFE ONE.  A new mutation that forgets to say what
# it is invalidates the caches, which is merely slow; the opposite
# default would serve a stale answer, which is wrong.  So the two calls
# that are known not to touch the model name themselves, and everything
# else stays as it was.
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
use Time::HiRes;
use Pub::Utils;
use cm_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		bumpState
		bumpView
		getStateSeq
		getModelSeq

		getSelection
		setSelection

		getEditState
		setEditState
		clearEditState
		editLocks
		editInProgress

		notePoll
		mapIsOpen

		probeSetMode
		probeIsOn
		probeAddUnit
		probeReset
		probeBeginSource
		probeEndSource
		probeSources
		probeSeq
		probeRequestStop
		probeClearStop
		probeStopRequested
		probeRunning
		probeSetRunning
		probeMarkList
		probeTableLines
		probeOverlay

		$EDIT_BROWSE
		$EDIT_SHAPE
		$EDIT_DRAW
	);
}


our $dbg_state:shared = 0;
	# 0 = every bump, with what caused it


my $state_seq:shared		= 1;
my $model_seq:shared		= 1;


#---------------------------------------------
# the probe result set
#---------------------------------------------
# A MODE THAT HOLDS ACCUMULATED RESULTS, not a run that finishes.  A run
# happens inside it, the results stay, the user may add to them, and it
# ends only when it is cancelled or a different scope is probed.  That is
# a longer life than a build has, and it is the point: nobody sets a zmax
# from a number that vanished.
#
# NOTHING HERE OUTLIVES THE MODE.  There is no file and no spatial index.
# A placed finding has no home in the observation record by that record's
# own rule, and re-running is cheap because the tiles a run fetched are in
# the cache -- so the checkpoint already exists and does not need writing
# twice.
#
# IT CROSSES THREADS AS FLAT STRINGS.  A nest of hashes cannot cross as a
# reference and shipping a copy back would be a second representation free
# to drift from the first, which is the same argument the build report
# already settles.  Two shared arrays do it and neither needs nested
# shared memory, which is the awkward part of Perl ithreads:
#
#	marks   'z/x/y/outcome', for the browser to parse into dots
#	lines   rendered table rows, for the wx window
#
# ITS OWN SEQUENCE, NOT THE STATE COUNTER.  A run publishes a unit every
# few seconds and the whole /state document would be refetched for each
# one; worse, the marks are the one part of the display that legitimately
# lags, since a dot arriving a poll late is invisible.  So /state carries
# the number and /probe carries the payload, which is the arrangement
# preview already uses for the same reason.

# KEYED BY SOURCE, because comparing two services over the same ground is
# the whole point of the mode.  A run ADDS a source rather than replacing
# what is there, so Esri's marks and Google's marks sit on the map at once
# and the palette turns each on and off.
#
# The marks carry their source in the string for the same reason everything
# else here is a flat string: a hash of arrays cannot cross a thread
# boundary, and a parallel structure keyed the same way twice is two things
# free to disagree.  'source z/x/y/outcome' parses in one split.

my $probe_on:shared		= 0;
my $probe_seq:shared	= 0;
my $probe_stop:shared	= 0;
my @probe_marks:shared;		# "source z/x/y/outcome"
my @probe_lines:shared;		# "source <rendered row>"
my @probe_sources:shared;	# ids, in the order they were first probed
my %probe_status:shared;	# id => one line of prose for the palette

# BOUNDED BY CONSTRUCTION, AND THE OVERLAY SAYS WHEN IT BINDS.  'All marks
# persist' is the design and this does not contradict it: a mode left open
# for a day across dozens of runs would otherwise grow without limit, and
# silent truncation is the thing actually worth refusing.  At the cap the
# oldest go and the count is reported, so a reader is never told they are
# looking at everything when they are not.

my $MAX_MARKS = 100000;


sub probeSetMode
{
	my ($on) = @_;
	$on = $on ? 1 : 0;
	return 0 if $on == $probe_on;
	$probe_on = $on;
	probeReset() if !$on;
	bumpView("probe mode ".($on ? 'on' : 'off'));
	return 1;
}

sub probeIsOn		{ return $probe_on }
sub probeSeq		{ return $probe_seq }


# STOP IS A PROPERTY OF THE MODE, NOT OF ONE RUN'S PROGRESS RECORD.
#
# A run started from the console has a progress record the console owns,
# and a wx window that opened afterwards has never seen it - so a Stop
# button that could only reach into a record it was handed would be inert
# for exactly the runs somebody most wants to stop, and the application
# would hold a mode that nothing could leave.
#
# So the flag lives beside the mode.  Every run checks it whoever started
# it, and every surface can set it without knowing who did.

# CLEARED WHERE A RUN BEGINS, never inferred from the result set.  An
# amending point probe starts with rows already on screen, so any rule
# along the lines of "clear it when the table is empty" would leave a
# stale stop in place and kill the one kind of run that is supposed to be
# instant.

sub probeRequestStop	{ $probe_stop = 1; return 1 }
sub probeClearStop		{ $probe_stop = 0; return 1 }
sub probeStopRequested	{ return $probe_stop }


# ONE RUN AT A TIME, ASKED ACROSS THREADS.  Two samplers publish into one
# result set, so the table would read as a single run with every row twice
# and the marks would be drawn from two scopes at once.  The flag lives
# here rather than in the window because the menu, the console and the map
# can all start one and none of them can see the others.

my $probe_running:shared = 0;

sub probeRunning		{ return $probe_running }
sub probeSetRunning		{ $probe_running = $_[0] ? 1 : 0; return 1 }


sub probeReset
	# EVERYTHING, every source.  THE ONLY THING THAT REMOVES ANYTHING - Clear
	# and leaving the mode are the two ways here, and every run adds.
{
	lock(@probe_marks);
	@probe_marks   = ();
	@probe_lines   = ();
	@probe_sources = ();
	%probe_status  = ();
	$probe_seq++;
	return 1;
}


sub probeBeginSource
	# NOTHING IS DROPPED HERE.  Every run adds to the set, including a
	# re-run of a source already in it, and only Clear or leaving the mode
	# takes anything away.
	#
	# A re-probe USED to replace its own results, on the reasoning that two
	# runs of one service would double every row.  That was wrong about what
	# the marks are for.  Selection draws different points every time, so a
	# second run of the same source over the same ground is not a repeat of
	# the first - it is more of the same sample, and running it again is how
	# a spread of a few dozen dots becomes a picture dense enough to read.
	# Throwing the first run away was throwing away exactly the accumulation
	# that made it worth running twice.
	#
	# It also made the two cases behave differently for no reason a user
	# could see: probing a second source added, probing the same one wiped,
	# and nothing on screen said which was about to happen.
{
	my ($id) = @_;
	lock(@probe_marks);
	push @probe_sources,$id if !grep { $_ eq $id } @probe_sources;
	$probe_status{$id} = 'running';
	$probe_seq++;
	return 1;
}


sub probeEndSource
{
	my ($id,$text) = @_;
	lock(@probe_marks);
	$probe_status{$id} = $text // '';
	$probe_seq++;
	return 1;
}


sub probeAddUnit
	# ONE (SOURCE, LEVEL) AT A TIME, which is the unit the report rows use
	# and the batch the map is handed.  Per tile would be too chatty for a
	# poll and per run too slow to watch, so finishing one level publishes
	# its marks and its row together.
{
	my ($id,$line,$marks) = @_;
	lock(@probe_marks);

	push @probe_lines,"$id $line" if defined $line;
	push @probe_marks,map { "$id $_" } @$marks if $marks && @$marks;

	splice(@probe_marks,0,scalar(@probe_marks) - $MAX_MARKS)
		if @probe_marks > $MAX_MARKS;

	$probe_seq++;
	return 1;
}


sub probeMarkList
	# A COPY, because the caller is another thread and the array is going
	# to keep changing under it.  Bounded above, so the copy is bounded.
{
	lock(@probe_marks);
	return [ @probe_marks ];
}

sub probeTableLines
{
	lock(@probe_marks);
	return [ @probe_lines ];
}

sub probeSources
	# In the order first probed, with what each one is doing or found.
	# This is what the palette draws a row from.
{
	lock(@probe_marks);
	return [ map { { id => $_, status => ($probe_status{$_} // '') } }
			 @probe_sources ];
}

sub probeOverlay
{
	lock(@probe_marks);
	return { marks  => scalar(@probe_marks),
			 capped => (scalar(@probe_marks) >= $MAX_MARKS ? 1 : 0) };
}


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
	bumpView("selection is '".($sub_id || $region_id || 'none')."'");
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

	bumpView("edit: $mode".($region_id ? " '".($sub_id || $region_id)."'" : '').
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
	#
	# A MAP THAT IS NOT THERE HOLDS NOTHING.  The edit state is a fact
	# about a browser, and a browser that has stopped polling has taken
	# whatever it was holding with it - so an obstacle nobody can clear is
	# not reported as one.
{
	return '' if !mapIsOpen();
	return "'".($edit_sub || $edit_region)."' has unsaved changes"
		if $edit_dirty && ($edit_region || $edit_sub);
	return "a polygon is being drawn"
		if $edit_mode eq $EDIT_DRAW;
	return '';
}


sub editInProgress
	# What the map is holding that is not in the model, said in words, or
	# '' when it is holding nothing.  Every path that would throw it away
	# asks this - which is a different question from editLocks(), because
	# this one is not asking permission, it is telling the user what they
	# are about to lose.
{
	return '' if !mapIsOpen();
	return '' if $edit_mode eq $EDIT_BROWSE && !$edit_dirty;

	my $what = $edit_sub || $edit_region;
	return "a polygon is being drawn on the map"		if $edit_mode eq $EDIT_DRAW;
	return "'$what' has uncommitted changes on the map"	if $edit_dirty;
	return "'$what' is being edited on the map"			if $what;
	return "the map is in the middle of an edit";
}


#---------------------------------------------
# is the map open at all
#---------------------------------------------
# ONE TIMESTAMP, NOT A SESSION.  The server has no notion of a connected
# browser and gains none here: /poll records WHEN it was last asked, which
# is a fact about the recent past rather than a relationship being
# maintained.  Closing and reopening the page stays the non-event it has
# always been, and nothing needs cleaning up when a window disappears.
#
# It answers two questions that both used to have no answer: whether to
# offer to open a map, and whether an edit somebody started still exists.

my $poll_ms:shared	= 0;
my $POLL_GRACE_MS	= 5000;
	# Three polls' worth.  Long enough that a slow page or a paused
	# machine is not mistaken for a closed one, short enough that a
	# stranded edit clears while the user is still wondering about it.


sub notePoll
{
	$poll_ms = int(Time::HiRes::time() * 1000);
}


sub mapIsOpen
{
	return 0 if !$poll_ms;
	return (int(Time::HiRes::time() * 1000) - $poll_ms) < $POLL_GRACE_MS ? 1 : 0;
}


sub getStateSeq
{
	return $state_seq;
}


sub getModelSeq
	# What anything derived from the geometry may cache against.  It moves
	# only when a polygon, a zoom, or the set of objects moves.
{
	return $model_seq;
}


sub bumpState
	# Every caller says why, because "the version changed and the map
	# redrew" is otherwise the least debuggable kind of event.
{
	my ($why) = @_;
	$model_seq++;
	return bumpView($why);
}


sub bumpView
	# The display changed and the model did not.
{
	my ($why) = @_;
	$state_seq++;
	display($dbg_state,0,"state $state_seq model $model_seq: ".($why // 'changed'));
	return $state_seq;
}


1;
