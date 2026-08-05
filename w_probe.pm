#!/usr/bin/perl
#---------------------------------------------
# w_probe.pm
#---------------------------------------------
# THE FULL TABLE, while it is being filled.
#
# A PANE, AND THAT IS THE POINT.  It was a modeless frame, which was wrong in
# the ordinary way a floating window is wrong: it came up behind the
# application, and the only cure for that is "always on top", which is
# obnoxious.  A pane is dragged where the user wants it - docked beside the
# tree, torn off onto the second monitor, or shut - and every one of those is
# the user's decision rather than a thing this file has to guess at, code
# around, and remember in a preference.
#
# Docking is also the arrangement that was actually wanted.  The whole reason
# to look at the table is to compare it with the map, and a pane docked on the
# left of a maximised application does that with nothing overlapping anything.
#
# THE TABLE IS THE REPORT BEING BUILT IN FRONT OF YOU, not a second
# artefact.  Every line here is one dm_sample::sampleRowLine rendered, under
# dm_sample::sampleHeader, which are the same two calls the written report
# and the console use -- so what is watched and what is written can never
# disagree about the same numbers or label them differently.
#
# REFRESHED ON A TIMER, WHICH IS A POLL.  Nothing calls into this window; it
# reads the shared arrays on its own timer, exactly as the other panes read
# the model.  A worker thread touching a wx control is the one thing that
# reliably takes the whole application down.
#
# IT OUTLIVES THE RUN.  A run finishing is not the mode finishing: the rows
# are the product and they become useful when they stop changing.  Closing
# this pane ends probe mode and clears the set, which is the only thing that
# does - so the mode always has an exit on the surface that shows it.
#
# IT IS NOT RESTORED AT STARTUP, which is why saveThisPane says no.  Every
# other pane is a view of something that is still there next time; this one
# is a view of a mode that is not.  Restoring it would open an empty table
# over a mode nothing had entered.

package w_probe;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON EVT_TIMER EVT_SIZE EVT_CLOSE );
use Pub::Utils;
use Pub::WX::Window;
use cm_defs;
use cm_state;
use dm_source;
use dm_sample;
use w_blank;
use base qw(Wx::Panel Pub::WX::Window);


my $ID_HALT		= 8841;
my $ID_CLEAR	= 8842;

my $TIMER_MS	= 500;


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	$this->MyWindow($frame,$book,$id,'Probe',$data);

	my $mono = Wx::Font->new(9,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL);

	# THREE SUMMARY LINES ABOVE THE SCROLL, not inside it.  Everything that
	# describes the run as a whole belongs where it is always visible: a
	# total buried at the bottom of a scrolling control is a number nobody
	# reads, and it was also being said twice.

	$this->{scope} = Wx::StaticText->new($this,-1,'');
	$this->{point} = Wx::StaticText->new($this,-1,'');
	$this->{count} = Wx::StaticText->new($this,-1,'');

	# THE COLUMN HEADING IS FIXED AND THE ROWS SCROLL UNDER IT.  It used to
	# be the first line INSIDE the control, which meant it scrolled away
	# after fifteen rows - and a probe of one source over twenty-three
	# levels is twenty-three rows before a second source is added, so it was
	# off screen essentially always.  A table whose heading cannot be seen
	# is eight columns of unlabelled integers.

	my ($head,$rule) = sampleHeader();
	$this->{head} = Wx::StaticText->new($this,-1,$head);
	$this->{head}->SetFont($mono);
	$this->{rule} = Wx::StaticText->new($this,-1,$rule);
	$this->{rule}->SetFont($mono);

	$this->{text} = Wx::TextCtrl->new($this,-1,'',
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{text}->SetFont($mono);

	# NAMED FOR WHAT THEY DO TO THE RESULTS.  'Stop' and 'Close' read as two
	# words for the same thing, and the second one quietly discarded the
	# marks - which are the product.
	#
	# THERE IS NO 'Close' BUTTON ANY MORE, and there should not be: a pane
	# has one, on its own tab, in the place every other pane keeps it.  A
	# second one inside the pane would be a second vocabulary for the act
	# the tab already performs.

	$this->{halt}  = Wx::Button->new($this,$ID_HALT,'Halt run');
	$this->{clear} = Wx::Button->new($this,$ID_CLEAR,'Clear all');
	$this->{halt}->SetToolTip('stop sampling, keep the marks');
	$this->{clear}->SetToolTip('discard every source\'s results, stay in probe mode');

	my $row = Wx::BoxSizer->new(wxHORIZONTAL);
	$row->Add($this->{halt},0,0,0);
	$row->AddSpacer(8);
	$row->Add($this->{clear},0,0,0);

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(6);
	$sizer->Add($this->{scope},0,wxLEFT|wxRIGHT|wxEXPAND,8);
	$sizer->Add($this->{point},0,wxLEFT|wxRIGHT|wxEXPAND,8);
	$sizer->Add($this->{count},0,wxLEFT|wxRIGHT|wxEXPAND,8);
	$sizer->AddSpacer(6);
	$sizer->Add($this->{head},0,wxLEFT|wxRIGHT,8);
	$sizer->Add($this->{rule},0,wxLEFT|wxRIGHT,8);
	$sizer->Add($this->{text},1,wxEXPAND|wxALL,6);
	$sizer->Add($row,0,wxLEFT|wxBOTTOM,8);

	# A SIZER IS NOT ENOUGH ON ITS OWN HERE, and this is the one thing that
	# is different about being a pane rather than a frame.
	#
	# The other two panes are wxSplitterWindows, which resize their children
	# themselves and never needed to say any of this.  This one is a plain
	# wxPanel handed straight to the notebook as a page, and a page is
	# resized by the notebook without anything re-running the sizer - so it
	# came up laid out at the size it was constructed at, a small rectangle
	# in the top left corner of an otherwise empty pane, and stayed there
	# through every drag and dock.
	#
	# SetAutoLayout is what makes the size event reach the sizer; the
	# Layout() after it is for the first paint, before any size event has
	# happened at all.

	$this->SetSizer($sizer);
	$this->SetAutoLayout(1);
	$this->Layout();

	EVT_BUTTON($this,$ID_HALT,\&onHalt);
	EVT_BUTTON($this,$ID_CLEAR,\&onClear);
	EVT_SIZE($this,\&onSize);
	EVT_CLOSE($this,\&onClose);

	$this->{seen} = -1;
	$this->{timer} = Wx::Timer->new($this,-1);
	EVT_TIMER($this,-1,\&onTimer);
	$this->{timer}->Start($TIMER_MS);

	$this->{built} = 1;
	$this->onTimer();
	return $this;
}


sub recommendedSize
	# What it needs when it is torn off into a floating frame: eight columns
	# of monospace, and enough rows that one source over a dozen levels does
	# not scroll before it has finished.
{
	return [700,480];
}


sub saveThisPane
	# NO.  See the header: this is the view of a MODE, and the mode does not
	# survive the session.  Restoring it would open an empty table over
	# nothing, with a Halt button for a run that never started.
{
	return 0;
}


sub setProgress
	# The shared record of the run in flight, so Halt has something to
	# set.  There may be none: a mode holding the results of a finished
	# run is the normal state, and Halt is simply inert then.
{
	my ($this,$prog) = @_;
	$this->{progress} = $prog;
	return 1;
}


sub runInFlight
	# Whether a run this pane was handed is still going.  A run started
	# from the console has no record here and reports 0, which is right:
	# what this gates is starting a SECOND run from the menu, and the mode
	# flag is what stops either kind.
{
	my ($this) = @_;
	return 0 if !$this->{progress};
	return $this->{progress}{finished} ? 0 : 1;
}


sub offerBlanks
	# WHAT THE RUN TAUGHT, once it has stopped.
	#
	# A probe fetches hundreds of real tiles, so it is the richest source of
	# this evidence in the application - and it is exactly the act somebody
	# runs when they are already asking whether a service is any good, which
	# makes it the right moment to be asked back.
	#
	# THE SOURCES THIS MODE HOLDS, not every installed one.  The probe pane
	# is about a comparison somebody set up, and widening it here would put
	# a question about an unrelated service on the end of it.
{
	my ($this) = @_;
	my @srcs = map { getSource($_->{id}) } @{ probeSources() || [] };
	w_blank->offerFor($this,[ grep { $_ } @srcs ]);
}


sub onTimer
	# THE ONLY THING THAT READS THE SHARED ARRAYS, and it reads them by
	# sequence rather than by content: rebuilding a 400 line control on
	# every tick would flicker and would fight the scrollbar under the
	# user's hand.
{
	my ($this,$event) = @_;

	# NOT UNTIL THE PANE EXISTS.  MyWindow() puts the page into the
	# notebook, which makes it the current one, which the frame turns into
	# an activation -- and all of that happens BEFORE the widgets below it
	# are created.  The same trap winSources::onTimer documents.

	return if !$this->{built};

	# THE END OF A RUN IS A LANDING POINT, and it is checked BEFORE the
	# sequence gate below.  A run finishing does not publish a unit, so the
	# sequence need not move at the moment it ends, and gating on it would
	# mean the offer arrived on the next run or never.
	#
	# THE MODE'S FLAG, NOT THIS PANE'S PROGRESS RECORD, for the reason
	# cm_state gives about Stop: a run started from the console or the map
	# has a progress record this pane has never seen, so an edge detected
	# from runInFlight() is an edge that only the menu can produce.
	#
	# IT GATED THE OFFER ON WHO STARTED THE RUN, and that was wrong in the
	# one case it mattered.  A console 'sample' over Guadeloupe learned two
	# fingerprints -- IGN's white fill and its navy sea fill, 159 and 168
	# sightings -- put both in the observation record, and then asked
	# nobody, because the pane that offers had never been handed a progress
	# record.  The evidence was gathered and thrown away at the one moment
	# somebody was looking at it.
	#
	# NOBODY IS ASKED A QUESTION THEY DID NOT ASK FOR, which is what the old
	# gate was really protecting.  This pane exists only inside probe mode,
	# and w_frame's idle handler opens it for a console run precisely so the
	# mode has a surface -- so if this is ticking at all, somebody entered
	# probe mode and is looking at the table a run just filled in.

	my $running = probeRunning();
	if ($this->{was_running} && !$running)
	{
		$this->{was_running} = 0;
		$this->offerBlanks();
	}
	$this->{was_running} = 1 if $running;

	my $seq = probeSeq();
	return if $seq == $this->{seen};
	$this->{seen} = $seq;

	my $over = probeOverlay();
	my $srcs = probeSources();

	# ONE LINE PER SOURCE PROBED, in the order they were first run.  The
	# mode holds several so two services can be compared over the same
	# ground, and the header says which are in the table below.

	$this->{scope}->SetLabel(!@$srcs ? 'Nothing probed yet.' :
		scalar(@$srcs)." source(s): ".join(', ',map { $_->{id} } @$srcs));
	$this->{point}->SetLabel(!@$srcs ? '' : ($srcs->[-1]{status} // ''));

	# THE MARK COUNT IS A FACT ABOUT THE RUN, so it sits with the other two
	# rather than at the bottom of the scroll where it was both invisible
	# and a second statement of what the line above already says.

	$this->{count}->SetLabel(!$over->{marks} ? '' :
		$over->{marks}." mark(s) on the map".
		($over->{capped} ? "  -  AT THE LIMIT, the oldest are being dropped" : ''));

	# THE CONTROL HOLDS ROWS AND NOTHING ELSE.  Its heading is a fixed
	# label above it, so it cannot scroll away.

	my $lines = probeTableLines();
	my $body = @$lines ?
		join("\n",map { my $l = $_; $l =~ s/^\S+\s//; $l } @$lines) :
		"Nothing sampled yet.";

	$this->{text}->SetValue($body);
	$this->{text}->ShowPosition(length($body));

	# HALT IS DEAD WHEN NOTHING IS RUNNING, so it cannot read as an offer to
	# undo a run that has already finished.  The map's palette says the same
	# thing the same way.

	$this->{halt}->Enable(probeRunning() ? 1 : 0);
}


sub onSize
	# EXPLICIT, rather than trusting SetAutoLayout alone.  Docking, floating
	# and dragging a splitter all arrive here, and the cost of laying out
	# eight widgets is nothing next to being wrong about which of those
	# wxWidgets handles for a page.  Skip() so the default sizing still runs.
{
	my ($this,$event) = @_;
	$this->Layout() if $this->{built};
	$event->Skip();
}


sub onActivate
	# Pub::WX::Frame calls this as the pane becomes the current one, which
	# is where a pane that sat out a change catches up.
{
	my ($this) = @_;
	$this->onTimer();
}


sub onHalt
	# STOPS THE RUN, NOT THE MODE.  A halt leaves a smaller sample rather
	# than a broken one, and what is on screen stays there - which is the
	# whole difference between this and a progress dialog.
{
	my ($this,$event) = @_;
	$this->{progress}{cancelled} = 1 if $this->{progress};
	probeRequestStop();
}


sub onClear
	# EVERY SOURCE'S RESULTS, and the mode stays on.  Closing the pane is
	# what leaves the mode; this is for starting a comparison over.
{
	my ($this,$event) = @_;
	probeReset();
}


sub closeOK
	# The framework asks before closing, and there is nothing to save or
	# refuse - only the timer, which must not fire into a dying pane.
{
	my ($this,$more_dirty) = @_;
	$this->{timer}->Stop() if $this->{timer};
	return 1;
}


sub onClose
	# CLOSING THE PANE ENDS THE MODE.  Leaving probe mode on with nothing
	# showing it would leave dots on the map that nothing explains and
	# nothing can clear - a state with no exit, which is what the frame's
	# own timer exists to rescue the application from.
{
	my ($this,$event) = @_;

	$this->{timer}->Stop() if $this->{timer};
	$this->{progress}{cancelled} = 1 if $this->{progress};
	probeRequestStop();
	probeSetMode(0);

	# THE BASE CLASS TAKES IT OUT OF THE FRAME'S LIST and skips the event so
	# that whoever is closing it can finish - see Pub::WX::Window::onClose.
	# Doing that by hand here is how a pane ends up closed and still in
	# {panes}, which makes findPane hand out a destroyed window.

	$this->SUPER::onClose($event);
}


1;
