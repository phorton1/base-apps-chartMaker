#!/usr/bin/perl
#---------------------------------------------
# w_clean.pm
#---------------------------------------------
# CLEAN UP CACHES.  The dialog over dm_clean.  See docs/design/cleanup.md.
#
# THE SURVEY HAS ALREADY RUN WHEN THIS APPEARS, and that is the whole
# shape of it.  The question somebody opening this actually has is not
# "which of these should I delete" but "which of these forty did I ever
# use", and a table that already knows answers it.  Ticking is then just
# acting on what the columns said.
#
# TWO COLUMNS, INDEPENDENT ON PURPOSE.  Deleting a cache is only ever a
# cost decision - the tiles come back if they are wanted again - so it
# needs no guard.  Deleting a .tsd is the one act here that can lose
# authored work, so it is the column that carries 'used by' and the one
# that starts unticked.
#
# THE SWEEPS ARE NOT DELETIONS AND ARE NOT IN THE TABLE.  Reclassifying a
# declared blank frees bytes and keeps the finding, and trimming keeps
# every absence marker; both apply across every row rather than to one.
# So they are checkboxes above the list, with the counts the survey found.
#
# ONE ROW IS A WHOLE MODE.  Deleting a source from the tree's context menu
# is this dialog filtered to that source's cache_key: the same preflight,
# the same 'used by', the same offer of the tiles, and the same worker.  A
# second dialog saying almost the same things is a second place for them
# to stop being true.
#
# NOTHING HERE TOUCHES THE MODEL.  The survey and the act both run on a
# worker through w_progress::runWorker, and this reads their shared record.

package w_clean;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Grid;
use Wx::Event qw( EVT_BUTTON EVT_CHECKBOX EVT_SIZE EVT_GRID_CELL_LEFT_CLICK );
use Pub::Utils;
use cm_defs;
use cm_state;
use cm_utils;
use dm_source;
use dm_clean;
use w_progress;
use w_report;
use base qw(Wx::Dialog);


my $ID_GRID			= 8851;
my $ID_SWEEP_SENT	= 8852;
my $ID_SWEEP_TRIM	= 8853;
my $ID_ALL_TSD		= 8854;
my $ID_ALL_CACHE	= 8855;
my $ID_GO			= 8856;
my $ID_CANCEL		= 8857;

my $COL_TSD		= 0;
my $COL_CACHE	= 1;
my $COL_KEY		= 2;
my $COL_FILES	= 3;
my $COL_USED	= 4;
my $COL_TILES	= 5;
my $COL_ABSENT	= 6;
my $COL_SIZE	= 7;
my $NUM_COLS	= 8;

my @COL_HEAD = ('del tsd','del cache','cache_key','files','used by',
				'tiles','absent','size');

# THE WIDTHS ARE A MINIMUM, NOT A LAYOUT.  Every column but 'used by' keeps
# what is here; 'used by' takes whatever is left over, which is what makes
# the window's width worth changing - it is a list of region names and the
# only column with no natural size.  Their sum plus a scrollbar is what
# SetMinSize below is derived from, so the two must move together.

my @COL_WIDE = (54,74,120,170,140,60,60,78);

my $GREY = Wx::Colour->new(120,120,120);
my $PALE = Wx::Colour->new(245,245,245);


#---------------------------------------------
# the workers
#---------------------------------------------

sub _surveyWorker
{
	my ($prog,$ids,$opts) = @_;

	cleanSurvey({ %$opts, progress => $prog });

	# LAST, AND ON ITS OWN.  The dialog stops the moment it sees this, so
	# the rows must already be in the record - see cleanSurvey.

	$prog->{ok}       = 1;
	$prog->{finished} = 1;
}


sub _cleanWorker
{
	my ($prog,$ids,$opts) = @_;

	my $report = cleanAct($prog,$ids,$opts);

	$prog->{ok} = $report->{ok} ? 1 : 0;
	push @{$prog->{lines}},@{cleanReportLines($report)};
	$prog->{finished} = 1;
}


#---------------------------------------------
# entry
#---------------------------------------------

sub show
	# ($parent,$opts).  Survey, table, confirm, act, report.
	#
	# opts:
	#	keys		only these cache_keys      (the one-source mode)
	#	only_leaf	the tsd tick means THIS file and not the row's others
	#	title		what the frame is called
	#
	# Returns 1 if anything was actually done, so a caller with a tree on
	# screen knows whether to repopulate it.
{
	my ($class,$parent,$opts) = @_;
	$opts ||= {};

	# THE TRIM IS NOT COMPUTED FOR ONE SOURCE.  It costs the coverage of
	# every region of every set, and the one-source mode is a delete
	# confirmation rather than a sweep - it does not offer it, so it must
	# not pay for it.

	my $whole = $opts->{keys} ? 0 : 1;

	my $prog = w_progress->runWorker($parent,'Surveying the cache',
		\&_surveyWorker,[],{
			trim => $whole,
			$opts->{keys} ? ( keys => $opts->{keys} ) : (),
		});

	return 0 if $prog->{cancelled};

	# THE ROWS COME OFF THE SHARED RECORD AS PLAIN PERL, once, here.  What
	# the worker published is a shared hash of scalars, and a shared hash
	# refuses an ordinary reference put back into it - so a dialog that
	# kept working in the shared copy would die the first time it wanted to
	# remember something of its own about a row.
	#
	# Sorted so that what nothing uses is at the top, which is what
	# somebody opened this to find.

	my @rows = map { { %$_ } } @{$prog->{rows} || []};
	@rows = sort {
		(_isUnused($a) <=> _isUnused($b)) * -1 ||
		lc($a->{key}) cmp lc($b->{key})
	} @rows;

	if (!@rows)
	{
		Wx::MessageBox("There is nothing cached and no source to clean up.",
			'Clean Up',wxOK | wxICON_INFORMATION,$parent);
		return 0;
	}

	my $this = $class->_build($parent,\@rows,$opts,$whole);
	my $rc = $this->ShowModal();
	my $act = $this->{act};
	$this->Destroy();

	return 0 if $rc != wxID_OK;
	return 0 if !$act;

	my $done = w_progress->runWorker($parent,'Cleaning Up',
		\&_cleanWorker,$act->{ids},$act);

	# THE FOLDER HAS CHANGED UNDER EVERY PANE.  One rescan and one state
	# bump, which is what the source tree watches - see winSources::onTimer.

	rescanSources();
	bumpState('cleaned up');

	# ONE OUTCOME, ALWAYS.  The other three answer "does an output file
	# exist"; nothing here writes one, and what this act did or declined to
	# do is already the first thing the lines say.

	w_report->show($parent,'cleaned',[ @{$done->{lines}} ]);
	return 1;
}


#---------------------------------------------
# the table
#---------------------------------------------

sub _build
{
	my ($class,$parent,$rows,$opts,$whole) = @_;

	# RESIZABLE, AND LAID OUT BY SIZERS RATHER THAN BY COORDINATES.  Every
	# other dialog here is a fixed size and places its controls by hand,
	# which is right for a form of known shape.  This one holds a TABLE of
	# unknown length whose widest column is a list of region names, so the
	# useful width is the user's to choose and the rows they can see at
	# once is the whole ergonomics of it.

	my $title = $opts->{title} || 'Clean Up Caches';
	my $this = $class->SUPER::new($parent,-1,$title,[-1,-1],[940,560],
		wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

	$this->{rows}      = $rows;
	$this->{only_leaf} = $opts->{only_leaf} || '';
	$this->{whole}     = $whole;
	$this->{act}       = undef;

	my $main = Wx::BoxSizer->new(wxVERTICAL);

	# ---- the two sweeps, above the list, only in the whole-cache mode

	my ($sent_tiles,$sent_bytes,$trim_tiles,$trim_bytes) = (0,0,0,0);
	for my $row (@$rows)
	{
		$sent_tiles += $row->{sent_tiles};
		$sent_bytes += $row->{sent_bytes};
		$trim_tiles += $row->{trim_tiles};
		$trim_bytes += $row->{trim_bytes};
	}

	if ($whole)
	{
		$this->{sent} = Wx::CheckBox->new($this,$ID_SWEEP_SENT,
			sprintf("Reclassify cached blanks a source has since declared".
				"  (%d tiles, %s)",$sent_tiles,prettyBytes($sent_bytes)));
		$this->{sent}->Enable($sent_tiles ? 1 : 0);
		$this->{sent}->SetToolTip('The bytes go and the finding stays - '.
			'the tile becomes a recorded absence, so nothing fetches it again');

		$this->{trim} = Wx::CheckBox->new($this,$ID_SWEEP_TRIM,
			sprintf("Remove tiles outside every region of every set".
				"  (%d tiles, %s)",$trim_tiles,prettyBytes($trim_bytes)));
		$this->{trim}->Enable($trim_tiles ? 1 : 0);
		$this->{trim}->SetToolTip('Absence markers are kept: they cost a '.
			'request each to learn and they are nine bytes');

		EVT_CHECKBOX($this,$ID_SWEEP_SENT,\&_onTick);
		EVT_CHECKBOX($this,$ID_SWEEP_TRIM,\&_onTick);

		$main->Add($this->{sent},0,wxLEFT | wxRIGHT | wxTOP,16);
		$main->Add($this->{trim},0,wxLEFT | wxRIGHT | wxTOP,16);
	}
	else
	{
		# THE ONE-SOURCE MODE SAYS WHAT IT IS ABOUT.  A grid with a single
		# line in it and no sentence would be a strange way to be asked
		# whether to delete a file.

		my $leaf = $this->{only_leaf} || ($rows->[0]{leaves} || '');
		my $head = Wx::StaticText->new($this,-1,"Delete $leaf?");
		my $font = $head->GetFont();
		$font->SetWeight(wxFONTWEIGHT_BOLD);
		$head->SetFont($font);

		my @say;
		my $row = $rows->[0];
		push @say,$row->{used_by} ?
			"It is used by: $row->{used_by}" :
			"No region in any set names it.";
		push @say,"It is the source the map is drawing." if $row->{display};

		# THE SHARED cache_key, and this is the sentence the old delete
		# could not say.  Two .tsd files may address one cache, and then
		# the tiles are not this file's to take away.

		my @others = grep { $_ ne $this->{only_leaf} }
			split(/ /,$row->{leaves} || '');
		push @say,@others ?
			"The tiles are shared with ".join(' and ',@others).
				", so they are kept." :
			"Its cached tiles can go with it, or be left for another ".
				"definition to pick up.";

		my $note = Wx::StaticText->new($this,-1,join("\n",@say));
		$note->SetForegroundColour($GREY);

		$main->Add($head,0,wxLEFT | wxRIGHT | wxTOP,16);
		$main->Add($note,0,wxLEFT | wxRIGHT | wxTOP,16);
	}

	# ---- the grid, and it is the one thing that takes the slack

	my $grid = Wx::Grid->new($this,$ID_GRID);
	$grid->CreateGrid(scalar(@$rows),$NUM_COLS);
	$grid->SetRowLabelSize(0);
	$grid->EnableEditing(0);
	$grid->DisableDragRowSize();
	$grid->SetColLabelValue($_,$COL_HEAD[$_]) for (0..$NUM_COLS-1);
	$grid->SetColSize($_,$COL_WIDE[$_]) for (0..$NUM_COLS-1);

	for my $r (0..$#$rows)
	{
		$this->_fillRow($grid,$r,$rows->[$r]);
	}

	$this->{grid} = $grid;
	EVT_GRID_CELL_LEFT_CLICK($grid,sub { $this->_onClick($_[1]) });

	$main->Add($grid,1,wxEXPAND | wxALL,16);

	# ---- the totals line and the buttons

	# EXPAND, and it is not cosmetic.  This label is created empty and is
	# given a whole sentence later, so a sizer that had fitted it to its
	# contents would have fitted it to nothing and the sentence would be
	# clipped to the first character on the next layout.

	$this->{total} = Wx::StaticText->new($this,-1,'');
	$main->Add($this->{total},0,wxEXPAND | wxLEFT | wxRIGHT | wxBOTTOM,16);

	my $bar = Wx::BoxSizer->new(wxHORIZONTAL);
	if ($whole)
	{
		my $all_tsd = Wx::Button->new($this,$ID_ALL_TSD,  'Check unused sources');
		my $all_key = Wx::Button->new($this,$ID_ALL_CACHE,'Check unused caches');
		EVT_BUTTON($this,$ID_ALL_TSD,  sub { $_[0]->_checkUnused($COL_TSD) });
		EVT_BUTTON($this,$ID_ALL_CACHE,sub { $_[0]->_checkUnused($COL_CACHE) });
		$bar->Add($all_tsd,0,wxRIGHT,8);
		$bar->Add($all_key,0,wxRIGHT,8);
	}

	# THE STRETCH IS BETWEEN THE TWO GROUPS, so the sweep buttons stay at
	# the left edge and Clean Up and Cancel stay at the right one however
	# wide the window is made.

	$bar->AddStretchSpacer(1);

	$this->{go} = Wx::Button->new($this,$ID_GO,'Clean Up');
	my $cancel = Wx::Button->new($this,$ID_CANCEL,'Cancel');
	$bar->Add($this->{go},0,wxRIGHT,8);
	$bar->Add($cancel,0,0,0);

	$main->Add($bar,0,wxEXPAND | wxLEFT | wxRIGHT | wxBOTTOM,16);

	EVT_BUTTON($this,$ID_GO,\&_onGo);
	EVT_BUTTON($this,$ID_CANCEL,sub { $_[0]->EndModal(wxID_CANCEL) });

	# A MINIMUM THAT STILL SHOWS EVERY COLUMN, so shrinking the window
	# cannot produce the horizontal scrollbar this layout exists to avoid.

	$this->SetSizer($main);
	$this->SetAutoLayout(1);
	$this->SetMinSize([840,360]);
	$main->Layout();

	EVT_SIZE($this,\&_onSize);
	$this->_fitColumns();

	# In the one-source mode the file is what was asked about, so it starts
	# ticked - the user chose Delete, and a dialog that made them tick it
	# again would be asking the same question twice.

	if (!$whole && $this->{only_leaf})
	{
		$grid->SetCellValue(0,$COL_TSD,'1');
	}

	$this->_onTick();
	return $this;
}


sub _onSize
	# LAY OUT FIRST, THEN FIT THE COLUMNS.  Doing it in the other order, or
	# leaving the layout to the default handler and only calling Skip, reads
	# the grid's width BEFORE the sizer has changed it - so the columns are
	# fitted to the previous size and are one resize behind for ever.
{
	my ($this,$event) = @_;
	$this->Layout();
	$this->_fitColumns();
	$event->Skip();
}


sub _fitColumns
	# 'used by' takes the width nothing else claimed.
	#
	# THE VERTICAL SCROLLBAR IS ALWAYS SUBTRACTED, whether or not one is
	# showing.  Measuring the true client width instead would mean widening
	# the column when the bar goes away, which can bring the bar back, which
	# narrows it again: with few enough rows to sit on the boundary the grid
	# flickers between the two states for as long as the window is open.
{
	my ($this) = @_;
	my $grid = $this->{grid};
	return if !$grid;

	my $avail = $grid->GetClientSize()->GetWidth() -
		Wx::SystemSettings::GetMetric(wxSYS_VSCROLL_X) - 4;

	my $fixed = 0;
	for my $c (0..$NUM_COLS-1)
	{
		$fixed += $grid->GetColSize($c) if $c != $COL_USED;
	}

	my $rest = $avail - $fixed;
	$rest = $COL_WIDE[$COL_USED] if $rest < $COL_WIDE[$COL_USED];
	$grid->SetColSize($COL_USED,$rest)
		if $rest != $grid->GetColSize($COL_USED);
}


sub _fillRow
{
	my ($this,$grid,$r,$row) = @_;

	# WHICH FILES A TICK WOULD TAKE.  All of the row's, unless a single
	# leaf was named - see show().

	my @leaves = grep { /\S/ } split(/ /,$row->{leaves} || '');
	my @del = @leaves;
	@del = grep { $_ eq $this->{only_leaf} } @leaves if $this->{only_leaf};
	$this->{del}[$r] = \@del;

	_boolCell($grid,$r,$COL_TSD,  scalar(@del) ? 1 : 0);
	_boolCell($grid,$r,$COL_CACHE,$row->{tiles} + $row->{misses} ? 1 : 0);

	my $files = join(' ',@leaves);
	$files = '(none)' if !$files;
	$files .= '  [ships]' if $row->{shipped};

	my $used = $row->{used_by};
	$used = 'the map' if !$used && $row->{display};
	$used = '-'       if !$used;

	$grid->SetCellValue($r,$COL_KEY,$row->{key});
	$grid->SetCellValue($r,$COL_FILES,$files);
	$grid->SetCellValue($r,$COL_USED,$used);
	$grid->SetCellValue($r,$COL_TILES, _num($row->{tiles}));
	$grid->SetCellValue($r,$COL_ABSENT,_num($row->{misses}));
	$grid->SetCellValue($r,$COL_SIZE,  prettyBytes($row->{bytes}));

	$grid->SetCellAlignment($r,$_,wxALIGN_RIGHT,wxALIGN_CENTRE)
		for ($COL_TILES,$COL_ABSENT,$COL_SIZE);

	# A ROW NOTHING USES IS THE ANSWER SOMEBODY OPENED THIS FOR, so the
	#'used by' cell is where the eye is sent.  Shipped rows are paled
	# rather than marked: unused is true of every one of them on a first
	# run, so marking them would make the marking mean nothing.

	$grid->SetCellTextColour($r,$COL_USED,$GREY) if !$row->{used_by};
	if ($row->{shipped})
	{
		$grid->SetCellBackgroundColour($r,$_,$PALE) for (0..$NUM_COLS-1);
	}
}


sub _boolCell
	# A tickable cell, or a plain '-' when the tick would mean nothing.
	# An unclickable empty checkbox reads as a bug; a dash reads as "not
	# applicable", which is what it is.
{
	my ($grid,$r,$c,$on) = @_;
	if (!$on)
	{
		$grid->SetCellValue($r,$c,'-');
		$grid->SetCellAlignment($r,$c,wxALIGN_CENTRE,wxALIGN_CENTRE);
		$grid->SetCellTextColour($r,$c,$GREY);
		$grid->SetReadOnly($r,$c,1);
		return;
	}
	$grid->SetCellRenderer($r,$c,Wx::GridCellBoolRenderer->new());
	$grid->SetCellValue($r,$c,'');
}


sub _isUnused
	# The rule behind 'check all unused', in one place so the buttons and
	# the colouring cannot disagree.  Four things count as in use - see the
	# header of dm_clean.
{
	my ($row) = @_;
	return 0 if $row->{used_by};
	return 0 if $row->{display};
	return 1;
}


sub _num
{
	my ($n) = @_;
	1 while $n =~ s/^(\d+)(\d{3})/$1,$2/;
	return $n;
}


#---------------------------------------------
# ticking
#---------------------------------------------

sub _isTickable
{
	my ($this,$r,$c) = @_;
	return 0 if $c != $COL_TSD && $c != $COL_CACHE;
	return $this->{grid}->IsReadOnly($r,$c) ? 0 : 1;
}


sub _onClick
{
	my ($this,$event) = @_;
	my ($r,$c) = ($event->GetRow(),$event->GetCol());

	if (!$this->_isTickable($r,$c))
	{
		$event->Skip();
		return;
	}

	my $grid = $this->{grid};
	$grid->SetCellValue($r,$c,$grid->GetCellValue($r,$c) ? '' : '1');
	$this->_onTick();
}


sub _checkUnused
{
	my ($this,$col) = @_;
	my $grid = $this->{grid};
	my $rows = $this->{rows};
	my $hit  = 0;

	for my $r (0..$#$rows)
	{
		my $row = $rows->[$r];

		# SHIPPED SOURCES ARE SKIPPED BY THE SWEEP AND NOT BY THE TICK.
		# Every one of them is unused on a first run, and a button that
		# emptied a new install would be a button nobody presses twice.
		# Ticking one by hand still works.

		next if $row->{shipped} && $col == $COL_TSD;
		next if !_isUnused($row);
		next if !$this->_isTickable($r,$col);
		$grid->SetCellValue($r,$col,'1');
		$hit++;
	}

	error("nothing in the list is unused") if !$hit;
	$this->_onTick();
}


sub _onTick
	# THE PREFLIGHT, LIVE.  What is ticked, counted and sized, in the
	# sentence above the buttons - so the number is answered before the
	# button rather than in a dialog after it.
{
	my ($this) = @_;
	my $grid = $this->{grid};
	my $rows = $this->{rows};

	my ($files,$bytes,$tsds) = (0,0,0);

	for my $r (0..$#$rows)
	{
		my $row = $rows->[$r];
		$tsds += scalar(@{$this->{del}[$r] || []})
			if $grid->GetCellValue($r,$COL_TSD);

		next if !$grid->GetCellValue($r,$COL_CACHE);
		$files += $row->{tiles} + $row->{misses};
		$bytes += $row->{bytes};
	}

	# The sweeps only touch rows whose cache is NOT being deleted outright,
	# so their tiles are not counted twice.

	my ($sent,$trim) = (0,0);
	if ($this->{whole})
	{
		for my $r (0..$#$rows)
		{
			next if $grid->GetCellValue($r,$COL_CACHE);
			my $row = $rows->[$r];
			if ($this->{sent}->GetValue())
			{
				$sent  += $row->{sent_tiles};
				$bytes += $row->{sent_bytes};
			}
			if ($this->{trim}->GetValue() && !$row->{trim_all})
			{
				$trim  += $row->{trim_tiles};
				$files += $row->{trim_tiles};
				$bytes += $row->{trim_bytes};
			}
		}
	}

	my @say;
	push @say,"$tsds source file(s)" if $tsds;
	push @say,_num($files)." cached file(s)" if $files;
	push @say,_num($sent)." blank(s) to reclassify" if $sent;
	push @say,_num($trim)." outside every region" if $trim;

	$this->{total}->SetLabel(@say ?
		"Will remove ".join(', ',@say).", freeing ".prettyBytes($bytes) :
		"Nothing is ticked.");

	$this->{go}->Enable(@say ? 1 : 0);
}


sub _onGo
	# THE LAST QUESTION, and it is asked here rather than after the work.
	# Everything below this point is a worker thread and a progress bar.
{
	my ($this,$event) = @_;
	my $grid = $this->{grid};
	my $rows = $this->{rows};

	my %del_cache;
	my %del_tsd;
	my @ids;

	for my $r (0..$#$rows)
	{
		my $row = $rows->[$r];
		my $key = $row->{key};

		if ($grid->GetCellValue($r,$COL_TSD))
		{
			$del_tsd{$_} = 1 for @{$this->{del}[$r] || []};
		}
		if ($grid->GetCellValue($r,$COL_CACHE))
		{
			$del_cache{$key} = 1;
			push @ids,$key;
			next;
		}

		# A ROW IS VISITED BY THE SWEEPS ONLY IF IT HAS SOMETHING FOR THEM.
		# Walking a hundred thousand files to do nothing to any of them is
		# a progress bar that says the application is busy and lies.

		my $sent = $this->{whole} && $this->{sent}->GetValue() && $row->{sent_tiles};
		my $trim = $this->{whole} && $this->{trim}->GetValue() &&
				   $row->{trim_tiles} && !$row->{trim_all};
		push @ids,$key if $sent || $trim;
	}

	my $sweep_sent = $this->{whole} && $this->{sent}->GetValue() ? 1 : 0;
	my $sweep_trim = $this->{whole} && $this->{trim}->GetValue() ? 1 : 0;

	my $what = $this->{total}->GetLabel();
	$what =~ s/^Will remove/This will remove/;

	return if Wx::MessageBox("$what\n\nThis cannot be undone.",
		'Clean Up',wxYES_NO | wxICON_QUESTION,$this) != wxYES;

	$this->{act} = {
		ids			=> \@ids,
		del_cache	=> \%del_cache,
		del_tsd		=> \%del_tsd,
		sentinels	=> $sweep_sent,
		trim		=> $sweep_trim,
	};
	$this->EndModal(wxID_OK);
}


1;
