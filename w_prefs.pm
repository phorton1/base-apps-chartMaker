#!/usr/bin/perl
#---------------------------------------------
# w_prefs.pm
#---------------------------------------------
# The Preferences dialog.
#
# TABBED BECAUSE THE TWO GROUPS ARE DIFFERENT IN KIND, not merely long.
# General is a set of small values that take effect as soon as they are
# written; Folders decides WHERE THE DOCUMENTS ARE, which is a different
# question and carries a different consequence.
#
# A FOLDER CHANGE TAKES EFFECT ON RESTART, and the dialog says so rather
# than leaving it to be discovered.  Moving REGION_SETS_DIR while a set is
# open would take the open document's whole universe out from under it --
# close it, handle whatever is unsaved, rescan, and quite possibly find
# nothing there.  A restart is one sentence a user can hold in their head,
# and these are set once per installation anyway, which is the whole point
# of them: an installed copy and a development copy differ by a prefs file
# and not by a code branch.
#
# THIS DIALOG NEVER CREATES A FOLDER.  A path that is not there is shown
# in red and Browse picks an existing one.  A missing folder is far more
# likely to be a typo, an unmounted drive, or a prefs file copied from
# another machine than an instruction to build an empty tree -- and
# building it would look like success while hiding the real one.  The
# application creates only the folders it chose the location of; see
# dm_set::_ensureDirs, which enforces the same rule from the other side.
#
# WHAT IS NOT HERE.  Nothing that changes what a build puts on a card:
# two people with the same region set must get the same card, or a set
# stops being a portable recipe.  The new-region zoom levels are here
# because they are SEEDS - they touch only regions that do not exist yet.

package w_prefs;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON );
use Pub::Utils;
use cm_defs;
use cm_prefs;
use w_ini;
	# For the remembered Browse folder only.  It is session state rather
	# than a preference, so it lives with the frame layout in the ini.
use base qw(Wx::Dialog);


my $LBL		= 120;		# the label column
my $FIELD	= 300;		# a folder text field
my $BROWSE	= 80;


sub new
{
	my ($class,$parent) = @_;
	my $this = $class->SUPER::new($parent,-1,'Preferences',
		wxDefaultPosition,[560,-1],
		wxDEFAULT_DIALOG_STYLE);

	my $book = Wx::Notebook->new($this,-1);
	$this->{book} = $book;
	$this->{ctl}  = {};

	$book->AddPage($this->_generalPage($book),'General',1);
	$book->AddPage($this->_foldersPage($book),'Folders',0);

	my $ok     = Wx::Button->new($this,wxID_OK,'OK');
	my $cancel = Wx::Button->new($this,wxID_CANCEL,'Cancel');
	$ok->SetDefault();

	my $buttons = Wx::BoxSizer->new(wxHORIZONTAL);
	$buttons->AddStretchSpacer(1);
	$buttons->Add($ok,0,wxRIGHT,6);
	$buttons->Add($cancel,0,0,0);

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->Add($book,1,wxEXPAND|wxALL,8);
	$sizer->Add($buttons,0,wxEXPAND|wxLEFT|wxRIGHT|wxBOTTOM,8);
	$this->SetSizerAndFit($sizer);

	EVT_BUTTON($this,wxID_OK,\&onOK);
	return $this;
}


#---------------------------------------------
# the pages
#---------------------------------------------

sub _row
	# One labelled control on a page.  Returns the sizer to add.
{
	my ($panel,$label,$ctl,$tail) = @_;
	my $row = Wx::BoxSizer->new(wxHORIZONTAL);
	$row->Add(Wx::StaticText->new($panel,-1,$label,
		wxDefaultPosition,[$LBL,-1]),0,wxALIGN_CENTER_VERTICAL,0);
	$row->Add($ctl,0,wxALIGN_CENTER_VERTICAL,0);
	$row->Add($tail,0,wxALIGN_CENTER_VERTICAL|wxLEFT,6) if $tail;
	return $row;
}


sub _spin
{
	my ($this,$panel,$pref,$lo,$hi) = @_;
	my $ctl = Wx::SpinCtrl->new($panel,-1,'',
		wxDefaultPosition,[70,-1],wxSP_ARROW_KEYS,$lo,$hi,
		int(prefVal($pref) // $lo));
	$this->{ctl}{$pref} = $ctl;
	return $ctl;
}


sub _text
	# A folder shows its EFFECTIVE value, default included, so the dialog
	# says where things actually are rather than showing an empty box for
	# every path nobody has overridden.
{
	my ($this,$panel,$pref,$width,$is_dir) = @_;
	my $val = $is_dir ? prefDir($pref) : prefVal($pref);
	my $ctl = Wx::TextCtrl->new($panel,-1,$val // '',
		wxDefaultPosition,[$width,-1]);
	$this->{ctl}{$pref} = $ctl;
	return $ctl;
}


sub _generalPage
{
	my ($this,$book) = @_;
	my $p = Wx::Panel->new($book,-1);

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(10);

	$sizer->Add(_row($p,'Map browser:',
		$this->_text($p,$PREF_MAP_BROWSER,$FIELD)),0,wxLEFT|wxRIGHT,10);
	$sizer->AddSpacer(4);
	$sizer->Add(Wx::StaticText->new($p,-1,
		'empty means the system default browser'.
		"  -  'firefox --new-window' forces a separate window",
		wxDefaultPosition,wxDefaultSize),0,wxLEFT,10+$LBL);

	$sizer->AddSpacer(12);
	$sizer->Add(_row($p,'Server port:',
		$this->_text($p,$PREF_HTTP_PORT,70),
		Wx::StaticText->new($p,-1,'restart to take effect')),
		0,wxLEFT|wxRIGHT,10);

	$sizer->AddSpacer(12);
	$sizer->Add(_row($p,'Map maximum zoom:',
		$this->_spin($p,$PREF_MAP_MAX_ZOOM,1,24),
		Wx::StaticText->new($p,-1,'reload the map page to take effect')),
		0,wxLEFT|wxRIGHT,10);

	# THE SEEDS, fenced off in a box so it is clear they are not the
	# levels of anything that exists.

	my $box = Wx::StaticBox->new($p,-1,'Levels a new region starts with');
	my $bs  = Wx::StaticBoxSizer->new($box,wxVERTICAL);
	$bs->AddSpacer(4);
	$bs->Add(_row($p,'Authored level:',
		$this->_spin($p,$PREF_NEW_ZAUTHOR,0,24)),0,wxLEFT,6);
	$bs->AddSpacer(4);
	$bs->Add(_row($p,'Overview floor:',
		$this->_spin($p,$PREF_NEW_ZMIN,0,24)),0,wxLEFT,6);
	$bs->AddSpacer(4);
	$bs->Add(_row($p,'Deepest level:',
		$this->_spin($p,$PREF_NEW_ZMAX,0,24)),0,wxLEFT,6);
	$bs->AddSpacer(4);
	$bs->Add(Wx::StaticText->new($p,-1,
		'Changing these never touches a region that already exists.'),
		0,wxLEFT|wxTOP,6);
	$bs->AddSpacer(4);

	$sizer->AddSpacer(14);
	$sizer->Add($bs,0,wxEXPAND|wxLEFT|wxRIGHT,10);
	$sizer->AddSpacer(10);

	$p->SetSizer($sizer);
	return $p;
}


my @FOLDER_ROWS = ();

sub _foldersPage
{
	my ($this,$book) = @_;
	my $p = Wx::Panel->new($book,-1);

	@FOLDER_ROWS = (
		[ $PREF_SOURCES_DIR,		'Sources:',		'the .tsd files'				],
		[ $PREF_REGION_SETS_DIR,	'Region sets:',	'one folder per set'			],
		[ $PREF_MBTILES_DIR,		'MBTiles out:',	'built chartsets'				],
		[ $PREF_RASTER_DIR,			'RCT out:',		'built cards, one folder per set'],
		[ $PREF_CACHE_DIR,			'Tile cache:',	'fetched tiles - not temporary'	],
	);

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(10);

	for my $spec (@FOLDER_ROWS)
	{
		my ($pref,$label,$hint) = @$spec;

		my $ctl = $this->_text($p,$pref,$FIELD,1);
		my $btn = Wx::Button->new($p,-1,'Browse...',
			wxDefaultPosition,[$BROWSE,-1]);
		EVT_BUTTON($this,$btn,sub { $this->onBrowse($pref) });

		$sizer->Add(_row($p,$label,$ctl,$btn),0,wxLEFT|wxRIGHT,10);
		$sizer->AddSpacer(2);
		$sizer->Add(Wx::StaticText->new($p,-1,$hint),0,wxLEFT,10+$LBL);
		$sizer->AddSpacer(10);
	}

	$sizer->Add(Wx::StaticText->new($p,-1,
		"A folder change takes effect when chartMaker is restarted.\n".
		"Folders are never created here - a path that does not exist is\n".
		"reported rather than made."),
		0,wxLEFT|wxRIGHT|wxTOP,10);
	$sizer->AddSpacer(10);

	$p->SetSizer($sizer);
	$this->_markBadPaths();
	return $p;
}


sub _markBadPaths
	# A path that is not there is RED, and that is the whole of the
	# feedback.  It is not refused: a user may legitimately be typing a
	# path to a drive that is not mounted yet, and the startup scan
	# reports it again anyway.
{
	my ($this) = @_;
	for my $spec (@FOLDER_ROWS)
	{
		my $ctl  = $this->{ctl}{$spec->[0]};
		next if !$ctl;
		my $path = $ctl->GetValue();
		$ctl->SetForegroundColour(
			(-d $path) ? Wx::SystemSettings::GetColour(wxSYS_COLOUR_WINDOWTEXT)
					   : Wx::Colour->new(180,0,0));
		$ctl->Refresh();
	}
}


#---------------------------------------------
# events
#---------------------------------------------

sub onBrowse
	# WHERE THE DIALOG OPENS, in order of preference:
	#
	#	1  the folder the last Browse landed in, this session or the last
	#	2  what the field currently holds, if it is a real folder
	#	3  nothing, and let the shell decide
	#
	# The remembered one wins deliberately.  The operation this serves is
	# relocating SEVERAL folders to one new home: having just chosen
	# D:/charts/sources, the next field wants to start at D:/charts, not
	# back under the data folder it still points at.  Within a single
	# edit the field value is the better guess, which is why it is
	# second rather than absent.
{
	my ($this,$pref) = @_;
	my $ctl = $this->{ctl}{$pref};
	my $was = $ctl->GetValue();

	my $start = getLastBrowseDir();
	$start = (-d $was) ? $was : '' if !$start;

	my $dlg = Wx::DirDialog->new($this,'Choose a folder',$start);
	if ($dlg->ShowModal() == wxID_OK)
	{
		my $got = $dlg->GetPath();
		$ctl->SetValue($got);
		setLastBrowseDir($got);
	}
	$dlg->Destroy();
	$this->_markBadPaths();
}


sub onOK
	# Write what changed, and say plainly when a restart is needed.
	#
	# writePrefs is what keeps the file a DIFF rather than a snapshot: a
	# value that has come back to its default is commented out rather than
	# written, so changing a default in code still reaches anybody who
	# never overrode it.
{
	my ($this,$event) = @_;

	my @moved;
	for my $spec (@FOLDER_ROWS)
	{
		my $pref = $spec->[0];
		my $now  = $this->{ctl}{$pref}->GetValue();
		$now =~ s/^\s+|\s+$//g;
		next if $now eq (prefDir($pref) // q{});
		push @moved,[$spec->[1],$now];
	}

	if (@moved)
	{
		my $text = "These folders will not change until chartMaker is ".
			"restarted:\n\n";
		$text .= "    $_->[0]  $_->[1]\n" for @moved;
		$text .= "\nSave the change?";
		if (Wx::MessageBox($text,'Preferences',
				wxYES_NO | wxICON_QUESTION,$this) != wxYES)
		{
			return;
		}
	}

	for my $pref (sort keys %{$this->{ctl}})
	{
		my $ctl = $this->{ctl}{$pref};
		my $val = $ctl->isa('Wx::SpinCtrl') ? $ctl->GetValue() : $ctl->GetValue();
		$val =~ s/^\s+|\s+$//g if !ref($val);
		setPref($pref,$val);
	}
	writePrefs();

	warning(0,0,"preferences: restart chartMaker for the folder change to ".
		"take effect") if @moved;

	$this->EndModal(wxID_OK);
}


1;
