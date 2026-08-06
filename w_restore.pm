#!/usr/bin/perl
#---------------------------------------------
# w_restore.pm
#---------------------------------------------
# The Restore Shipped Sources and Examples dialog: what the application
# ships, what is on disk, and putting back whatever is asked for.
#
# THE SURVEY IS THE PREFLIGHT, exactly as it is for the cleanup.  It says
# what it found before it offers to do anything, and the counts in front of
# the button are what the act then produces, because the same walk with the
# same rules produced both.
#
# A CHANGED FILE ARRIVES UNTICKED and a missing one arrives ticked, and
# that default is dm_restore's rather than this dialog's - so the console
# and the dialog cannot disagree about a file that can lose work.
#
# NOTHING IS EVER REMOVED.  A region the reader drew lives in the same
# folder as the shipped one, and it does not appear in this list at all.
# The dialog says so, because a list of files under a button marked
# Regenerate reads like a list of files about to be replaced.
#
# A Wx::Grid RATHER THAN A ListCtrl, because wx 3.0.2 here has no
# EnableCheckBoxes and a tickable column is what this dialog is.

package w_restore;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Grid;
use Wx::Event qw(EVT_BUTTON EVT_GRID_CELL_LEFT_CLICK);
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_restore;
use dm_source;
use dm_region;

use base qw(Wx::Dialog);

my $ID_GO		= 5810;
my $ID_ALL		= 5811;
my $ID_NONE		= 5812;

my $COL_DO		= 0;
my $COL_WHAT	= 1;
my $COL_KIND	= 2;
my $COL_STATE	= 3;
my $COL_WHERE	= 4;

my @COLS = (
	[ '',			40  ],
	[ 'file',		190 ],
	[ 'kind',		80  ],
	[ 'on disk',	110 ],
	[ 'goes to',	330 ] );

my %STATE_TEXT = (
	missing	=> 'not there',
	same	=> 'identical',
	changed	=> 'CHANGED' );


sub show
{
	my ($class,$parent) = @_;
	my $this = $class->new($parent);
	$this->ShowModal();
	$this->Destroy();
}


sub new
{
	my ($class,$parent) = @_;
	my $this = $class->SUPER::new($parent,-1,'Restore Shipped Sources and Examples',
		[-1,-1],[820,480],wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

	$this->{rows} = surveyShipped();
	$this->_build();
	$this->Centre();
	return $this;
}


sub _build
{
	my ($this) = @_;
	my $rows = $this->{rows};

	my $top = Wx::BoxSizer->new(wxVERTICAL);

	# WHAT THIS IS, IN TWO SENTENCES, and the second is the one that stops
	# somebody closing the dialog rather than risking it.

	my $n_missing = scalar(grep { $_->{state} eq 'missing' } @$rows);
	my $n_changed = scalar(grep { $_->{state} eq 'changed' } @$rows);
	my $n_same    = scalar(grep { $_->{state} eq 'same'    } @$rows);

	my $head =
		"These are the tile source definitions and the example region set ".
		"that ship with $appName.\n".
		"Nothing else is touched - a region you drew yourself is not in ".
		"this list and is never removed or rewritten.";

	my $found = "$n_missing not there, $n_changed changed, $n_same identical.";

	my $t1 = Wx::StaticText->new($this,-1,$head);
	my $t2 = Wx::StaticText->new($this,-1,$found);
	my $bold = $t2->GetFont();
	$bold->SetWeight(wxFONTWEIGHT_BOLD);
	$t2->SetFont($bold);

	$top->Add($t1,0,wxALL,10);
	$top->Add($t2,0,wxLEFT|wxBOTTOM,10);

	# THE GRID

	my $grid = Wx::Grid->new($this,-1);
	$grid->CreateGrid(scalar(@$rows),scalar(@COLS));
	$grid->EnableEditing(0);
	$grid->SetRowLabelSize(0);
	$grid->DisableDragRowSize();

	for my $c (0..$#COLS)
	{
		$grid->SetColLabelValue($c,$COLS[$c][0]);
		$grid->SetColSize($c,$COLS[$c][1]);
	}

	for my $r (0..$#$rows)
	{
		$this->_fillRow($grid,$r);
	}

	$this->{grid} = $grid;
	$top->Add($grid,1,wxEXPAND|wxLEFT|wxRIGHT,10);

	# THE BUTTONS.  Regenerate is the default because the ordinary use of
	# this dialog is a virgin profile where everything is missing and
	# everything is already ticked.

	my $bs = Wx::BoxSizer->new(wxHORIZONTAL);
	$bs->Add(Wx::Button->new($this,$ID_ALL,'Tick All'),0,wxRIGHT,6);
	$bs->Add(Wx::Button->new($this,$ID_NONE,'Tick None'),0,wxRIGHT,6);
	$bs->AddStretchSpacer(1);
	my $go = Wx::Button->new($this,$ID_GO,'Regenerate');
	$go->SetDefault();
	$bs->Add($go,0,wxRIGHT,6);
	$bs->Add(Wx::Button->new($this,wxID_CANCEL,'Close'),0);
	$top->Add($bs,0,wxEXPAND|wxALL,10);

	$this->SetSizer($top);
	$this->Layout();

	EVT_BUTTON($this,$ID_GO,\&onGo);
	EVT_BUTTON($this,$ID_ALL,\&onTickAll);
	EVT_BUTTON($this,$ID_NONE,\&onTickNone);
	EVT_GRID_CELL_LEFT_CLICK($grid,sub { $this->onCellClick($_[1]) });
}


sub _fillRow
{
	my ($this,$grid,$r) = @_;
	my $row = $this->{rows}[$r];

	$grid->SetCellValue($r,$COL_DO,$row->{do} ? 'X' : '');
	$grid->SetCellAlignment($r,$COL_DO,wxALIGN_CENTRE,wxALIGN_CENTRE);

	my $leaf = $row->{rel};
	$leaf =~ s|^.*/||;
	$grid->SetCellValue($r,$COL_WHAT,$leaf);
	$grid->SetCellValue($r,$COL_KIND,
		$row->{kind} eq 'source' ? 'source' : "set $row->{set}");
	$grid->SetCellValue($r,$COL_STATE,$STATE_TEXT{$row->{state}});
	$grid->SetCellValue($r,$COL_WHERE,$row->{dst});

	# A CHANGED ROW IS THE ONLY ONE THAT CAN LOSE ANYTHING, so it is the
	# only one that is coloured.  An identical row is greyed because there
	# is nothing to decide about it.

	if ($row->{state} eq 'changed')
	{
		$grid->SetCellTextColour($r,$COL_STATE,Wx::Colour->new(160,60,0));
	}
	elsif ($row->{state} eq 'same')
	{
		$grid->SetCellTextColour($r,$_,Wx::Colour->new(140,140,140))
			for (0..$#COLS);
	}
}


sub onCellClick
	# THE WHOLE OF THE TICKING.  A left click in the first column toggles
	# the row; anywhere else selects it and does nothing.
{
	my ($this,$event) = @_;
	my $r = $event->GetRow();
	my $c = $event->GetCol();

	if ($c == $COL_DO && $r >= 0 && $r <= $#{$this->{rows}})
	{
		my $row = $this->{rows}[$r];
		$row->{do} = $row->{do} ? 0 : 1;
		$this->{grid}->SetCellValue($r,$COL_DO,$row->{do} ? 'X' : '');
	}
	$event->Skip(0);
}


sub _tick
{
	my ($this,$val) = @_;
	for my $r (0..$#{$this->{rows}})
	{
		$this->{rows}[$r]{do} = $val;
		$this->{grid}->SetCellValue($r,$COL_DO,$val ? 'X' : '');
	}
}

sub onTickAll  { $_[0]->_tick(1) }
sub onTickNone { $_[0]->_tick(0) }


sub onGo
{
	my ($this,$event) = @_;
	my $rows = $this->{rows};
	my @doing = grep { $_->{do} } @$rows;

	if (!@doing)
	{
		Wx::MessageBox('Nothing is ticked.','Restore Shipped Sources and Examples',
			wxOK | wxICON_INFORMATION,$this);
		return;
	}

	# ONLY A CHANGED FILE IS WORTH CONFIRMING.  Restoring something that is
	# not there cannot lose anything, so asking about it would train the
	# question out of being read.

	my @over = grep { $_->{state} eq 'changed' } @doing;
	if (@over)
	{
		my $list = join("\n",map { '   '.$_->{dst} } @over);
		return if Wx::MessageBox(
			scalar(@over)." file(s) on disk differ from the shipped ".
			"version and will be REPLACED:\n\n$list\n\n".
			"Anything you changed in them will be lost. Continue?",
			'Restore Shipped Sources and Examples',
			wxYES_NO | wxICON_QUESTION,$this) != wxYES;
	}

	my ($wrote,$failed,$errors) = restoreShipped($rows);

	# THE FOLDERS ARE SCANNED, SO SAY SO -- BOTH OF THEM.  Existence comes
	# from the folder, but the folder is read once and the list is held, so
	# a file that reappeared is invisible to everything until something
	# looks again.  Rescanning the sources and forgetting the SETS is
	# exactly the bug it sounds like: the example set lands on disk and
	# File - Open Set goes on offering nothing until the next restart.
	#
	# The open set is deliberately NOT reloaded - it may hold unsaved work,
	# and a dialog about shipped files is not the thing that throws that
	# away.

	rescanSources();
	rescanSets();

	my $msg = "Restored $wrote file(s).";
	$msg .= "\n$failed failed:\n".join("\n",@$errors) if $failed;
	$msg .= "\n\nUse File - Open Set to open a region set that has just ".
		"come back." if grep { $_->{kind} eq 'region' } @doing;

	Wx::MessageBox($msg,'Restore Shipped Sources and Examples',
		wxOK | ($failed ? wxICON_EXCLAMATION : wxICON_INFORMATION),$this);

	# A SECOND SURVEY, so the dialog now shows what is true rather than
	# what was true when it opened.

	$this->{rows} = surveyShipped();
	$this->_fillRow($this->{grid},$_) for (0..$#{$this->{rows}});
}


1;
