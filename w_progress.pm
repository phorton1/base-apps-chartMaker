#!/usr/bin/perl
#---------------------------------------------
# w_progress.pm
#---------------------------------------------
# A TWO-LEVEL PROGRESS DIALOG over a worker thread.
#
# Written here as a Pub:: CANDIDATE, the same standing as w_prefs.
# Pub::WX::Dialogs::ProgressDialog has exactly the right CONTRACT and one
# gauge; Pub::Ray::NET::winMultiProgress has two levels and is shaped for
# recursive file copies and lives in Ray.  So this copies the contract,
# which is the part worth having, and adds the second level.
#
# THE CONTRACT, and it is the whole reason this is safe:
#
#	the worker thread WRITES the counters and READS {cancelled}
#	the dialog READS the counters and WRITES {cancelled}
#	nothing else crosses, in either direction
#
# No wx call is ever made from the worker and no model call is ever made
# from here.  That is the same rule that made cm_visibility unnecessary:
# a callback firing on another thread must not touch a wx widget, so
# nothing calls back and the dialog asks instead.
#
# A TIMER RATHER THAN EVT_IDLE.  Pub::WX::Dialogs polls its record on idle,
# and idle events are not a schedule -- they fire when the queue empties
# and, on some platforms, once only until the next real event arrives.  A
# dialog watching a worker that generates NO events is exactly the case
# that starves.  w_frame already drives both panes from a wx timer, so a
# timer is also the idiom this application already uses.
#
# TWO LEVELS BECAUSE THE WAIT HAS TWO SHAPES.  The outer bar is regions -
# a number the user chose and can predict.  The inner is tiles within one
# region, which is thousands and is where the hour actually goes.  One bar
# for the whole build would sit at 20% for fifteen minutes and tell nobody
# whether anything was still happening.

package w_progress;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON EVT_TIMER EVT_CLOSE );
use Pub::Utils;
use cm_defs;
use base qw(Wx::Dialog);


my $ID_CANCEL	= 8801;
my $ID_TIMER	= 8802;

my $POLL_MS		= 150;
	# Fast enough that the inner bar moves smoothly next to a tile fetch of
	# roughly 100ms, cheap enough that it is free.

my $GAUGE_MAX	= 1000;
	# THE GAUGES RUN 0..1000 AND THE COUNTS ARE SCALED INTO THEM.  A
	# Wx::Gauge range is a C int, and setting a range from a live count
	# means SetRange on every region change; scaling once here means the
	# widget never changes shape and a zero total is one branch rather
	# than a division by zero deep in an event handler.


sub new
{
	my ($class,$parent,$title,$progress) = @_;

	my $this = $class->SUPER::new($parent,-1,$title,[-1,-1],[460,230]);

	$this->{parent}		= $parent;
	$this->{progress}	= $progress;
	$this->{ended}		= 0;

	# Remembered so that a label is only pushed into a control when it has
	# actually changed.  SetLabel repaints, and repainting a static text
	# seven times a second under a build is visible flicker.

	$this->{last} = { phase => '', label => '', sub_label => '',
					  outer => -1, inner => -1 };

	$this->{phase_ctrl} = Wx::StaticText->new($this,-1,'',[20,12],[420,18]);

	$this->{label_ctrl} = Wx::StaticText->new($this,-1,'',[20,40],[420,18]);
	$this->{outer}		= Wx::Gauge->new($this,-1,$GAUGE_MAX,[20,60],[420,16]);

	$this->{sub_ctrl}	= Wx::StaticText->new($this,-1,'',[20,92],[420,18]);
	$this->{inner}		= Wx::Gauge->new($this,-1,$GAUGE_MAX,[20,112],[420,16]);

	$this->{cancel_btn} = Wx::Button->new($this,$ID_CANCEL,'Cancel',[180,155],[100,24]);

	EVT_BUTTON($this,$ID_CANCEL,\&onCancel);
	EVT_CLOSE($this,\&onClose);

	# MODAL, and that is a correctness requirement rather than a style.
	# The build reads the model and the frame can edit it, so a live frame
	# would let a region be reshaped underneath a walk that is halfway
	# through it.  wx disables the parent for us; the timer still runs
	# inside the modal loop, which is the whole reason this works.

	$this->{timer} = Wx::Timer->new($this,$ID_TIMER);
	EVT_TIMER($this,$ID_TIMER,\&onTimer);
	$this->{timer}->Start($POLL_MS);

	return $this;
}


sub run
	# Show it and do not come back until the worker says it is finished or
	# the user has cancelled AND the worker has noticed.  Returns nothing:
	# everything the caller wants is in the shared record.
{
	my ($this) = @_;
	$this->ShowModal();
	$this->{timer}->Stop() if $this->{timer};
	$this->Destroy();
}


sub onTimer
	# The only thing that reads the shared record.  Every branch here is a
	# read of a scalar the worker wrote; nothing calls into the model and
	# nothing waits.
{
	my ($this,$event) = @_;
	my $p = $this->{progress};
	return if !$p || $this->{ended};

	my $last = $this->{last};

	if (($p->{phase} // '') ne $last->{phase})
	{
		$last->{phase} = $p->{phase} // '';
		$this->{phase_ctrl}->SetLabel($last->{phase});
	}

	# ---- outer: regions

	# THE ORDINAL IS THE ONE BEING WORKED ON, THE BAR IS WHAT IS FINISHED,
	# and they are deliberately different numbers.  {done} counts regions
	# COMPLETED and {label} names the one in hand, so pairing them raw
	# reads "Region2 (1 of 4)" - which looks like an off-by-one and is
	# read as one.  The bar keeps the honest fraction; the text says which
	# of the four you are watching.

	my $total = $p->{total} || 0;
	my $done  = $p->{done}  || 0;
	my $at    = $done + 1;
	$at = $total if $at > $total;

	my $text  = $total ?
		sprintf("%s   (%d of %d)",$p->{label} // '',$at,$total) :
		($p->{label} // '');

	if ($text ne $last->{label})
	{
		$last->{label} = $text;
		$this->{label_ctrl}->SetLabel($text);
	}

	my $outer = $total ? int($GAUGE_MAX * $done / $total) : 0;
	if ($outer != $last->{outer})
	{
		$last->{outer} = $outer;
		$this->{outer}->SetValue($outer);
	}

	# ---- inner: tiles within the region

	my $sub_total = $p->{sub_total} || 0;
	my $sub_done  = $p->{sub_done}  || 0;
	my $inner = $sub_total ? int($GAUGE_MAX * $sub_done / $sub_total) : 0;
	$inner = $GAUGE_MAX if $inner > $GAUGE_MAX;

	if ($inner != $last->{inner})
	{
		$last->{inner} = $inner;
		$this->{inner}->SetValue($inner);
	}

	my $sub = $p->{sub_label} // '';
	$sub = sprintf("%d of %d tiles",$sub_done,$sub_total)
		if $sub !~ /\S/ && $sub_total;
	if ($sub ne $last->{sub_label})
	{
		$last->{sub_label} = $sub;
		$this->{sub_ctrl}->SetLabel($sub);
	}

	# ---- done?

	$this->endModal() if $p->{finished};
}


sub onCancel
	# THE FLAG, AND NOTHING ELSE.  The worker is between tiles somewhere
	# and will notice within one request; killing it here would leave a
	# half-written file and a cache mid-write.  So the dialog says so and
	# waits, and says that it is waiting - a Cancel button that stays
	# enabled and does nothing visible reads as a hang.
{
	my ($this,$event) = @_;
	my $p = $this->{progress};
	return if !$p;

	$p->{cancelled} = 1;
	$this->{cancel_btn}->Enable(0);
	$this->{cancel_btn}->SetLabel('Cancelling');
	$this->{phase_ctrl}->SetLabel('Cancelling - finishing the current tile');
	$this->{last}{phase} = 'Cancelling - finishing the current tile';
}


sub onClose
	# The window's own X.  Same thing as Cancel, and deliberately NOT a
	# way to abandon the worker: it goes on writing whether anybody is
	# watching or not, so leaving it running with the dialog gone would be
	# a build nobody can see or stop.
{
	my ($this,$event) = @_;
	return $this->onCancel($event) if !$this->{progress}{finished};
	$this->endModal();
}


sub endModal
	# EndModal ONLY.  Destroying a dialog from inside its own modal loop
	# is how a wx application crashes on the way out of one -- the loop
	# returns into an object that is already gone.  run() destroys it,
	# after ShowModal has returned.
{
	my ($this) = @_;
	return if $this->{ended};
	$this->{ended} = 1;
	$this->{timer}->Stop() if $this->{timer};
	$this->EndModal(wxID_OK);
}


1;
