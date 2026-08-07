#!/usr/bin/perl
#---------------------------------------------
# winRegions.pm
#---------------------------------------------
# The region tree: what exists, what is checked, and what one of them is.
#
# A splitter -- the hierarchy on top, the properties of whatever is
# selected below.  Geometry is NOT edited here.  Lists, names, structure
# and status are the native side's business; geometry and imagery belong
# to the map, and nothing is editable in two places.
#
# HOW IT LEARNS THAT SOMETHING CHANGED
#
# By polling cm_state's version counter on a timer, exactly as the map
# applet does over HTTP.  That looks like a lazy substitute for an
# observer and is in fact the only correct choice: a region can be
# changed from an HTTP thread, and a callback firing there must not touch
# a wx widget.  Polling moves the work onto the main thread by
# construction, where wx is safe, and it costs one integer comparison
# twice a second.
#
# The counter is also what keeps this pane and the browser agreeing --
# they are two views of one document, refreshed from one number.

package winRegions;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw( EVT_TREE_SEL_CHANGED EVT_TREE_ITEM_ACTIVATED
				  EVT_LEFT_DOWN EVT_RIGHT_DOWN
				  EVT_TIMER EVT_MENU
				  EVT_TEXT EVT_TEXT_ENTER EVT_SPINCTRL EVT_CHECKBOX
				  EVT_COMBOBOX EVT_BUTTON );
use Pub::Utils;
use Pub::WX::Window;
use cm_defs;
use cm_state;
use cm_utils;
use dm_set;
use dm_region;
use dm_source;
use dm_sample;
use w_probe;
use w_probecfg;
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);


our $dbg_win:shared = 1;

# WHAT AN UNCHOSEN SOURCE IS CALLED ON SCREEN.  The model stores the empty
# string; a combo cannot usefully show that, and a blank row in a read-only
# control reads as a rendering fault rather than as a state.
#
# It is safe as a list entry because a source id is [a-z0-9_-] and this is
# not, so it can never collide with a real one - and _saveFields translates
# it back to '' at the single place the control is read.

my $NO_SOURCE = '(none)';
	# 1 = quiet
	# 0 = rebuilds and checkbox clicks


my $TIMER_MS = 500;

# Menu ids, in this pane's own range.  Pub::WX reserves everything below
# 200; cm_defs uses the 10000s for panes and commands, so these sit clear
# of both.

my $MENU_COMMIT		= 10501;
my $MENU_REVERT		= 10502;
my $MENU_NEW_REGION	= 10503;
my $MENU_NEW_SUB	= 10504;
my $MENU_DELETE		= 10505;
my $MENU_EXPLORE	= 10506;
my $MENU_RESCAN		= 10507;
my $MENU_PROBE		= 10508;


sub _makeCheckBitmap
	# Drawn rather than loaded, so the pane carries no image files.  A
	# 13x13 box, with a tick when checked.
{
	my ($state) = @_;
	my $bmp = Wx::Bitmap->new(13,13);
	my $dc  = Wx::MemoryDC->new();
	$dc->SelectObject($bmp);
	$dc->SetBackground(Wx::Brush->new(Wx::Colour->new(255,255,255),wxSOLID));
	$dc->Clear();
	$dc->SetPen(Wx::Pen->new(Wx::Colour->new(100,100,100),1,wxSOLID));
	$dc->SetBrush(Wx::Brush->new(Wx::Colour->new(255,255,255),wxSOLID));
	$dc->DrawRectangle(1,1,11,11);
	if ($state)
	{
		$dc->SetPen(Wx::Pen->new(Wx::Colour->new(0,0,180),2,wxSOLID));
		$dc->DrawLine(2,6,5,10);
		$dc->DrawLine(5,10,11,2);
	}
	$dc->SelectObject(wxNullBitmap);
	return $bmp;
}


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	$this->MyWindow($frame,$book,$id,'Regions',$data);

	# THE LEFT SIDE IS A TITLED PANEL, not the tree alone.  The set is the
	# document, and a document says what it is at the top of its window
	# rather than by being a node inside itself.

	my $left = Wx::Panel->new($this,-1);
	$this->{left} = $left;

	$this->{ctl_set} = Wx::StaticText->new($left,-1,'');
	$this->{ctl_set}->SetFont(Wx::Font->new(9,wxFONTFAMILY_SWISS,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD));

	# NO LINES AT THE ROOT.  The root is hidden, and the stub wxWidgets
	# draws to it says the regions hang off something - which they did when
	# the set was a node above them, and no longer do.

	my $tree_style = (wxTR_DEFAULT_STYLE() & ~wxTR_LINES_AT_ROOT()) |
		wxTR_HIDE_ROOT();
	$this->{tree} = Wx::TreeCtrl->new($left,-1,wxDefaultPosition,wxDefaultSize,
		$tree_style);

	my $left_sizer = Wx::BoxSizer->new(wxVERTICAL);
	$left_sizer->Add($this->{ctl_set},0,wxEXPAND|wxALL,4);
	$left_sizer->Add($this->{tree},1,wxEXPAND,0);
	$left->SetSizer($left_sizer);

	# MONOSPACED, so the zoom numbers form a column that can be scanned.
	# A proportional font puts them at a different x on every row, which
	# defeats the entire reason for having them in the label.

	$this->{tree}->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $imgs = Wx::ImageList->new(13,13);
	$imgs->Add(_makeCheckBitmap(0));
	$imgs->Add(_makeCheckBitmap(1));
	$this->{tree}->SetStateImageList($imgs);
	$this->{_imgs} = $imgs;

	# The right side is one panel: the properties you may change at the
	# top, and a debugging-level dump of everything filling the rest.
	# No inner splitter, which is how the navMate panes are built.

	my $right = Wx::Panel->new($this,-1);
	$right->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$this->{right} = $right;

	my $CV  = wxALIGN_CENTER_VERTICAL;

	# THREE COLUMNS, AND EVERY FIELD STARTS ON THE THIRD.  The buttons and
	# the row words are on the left; the labels that name a field are in the
	# middle; the fields themselves - Id, Name and the zoom spinners - all
	# begin at $COL + $LBL, so they form one vertical line down the panel.
	#
	# $LBL is wide enough for 'Author:', which is the longest of them, so
	# nothing is clipped and nothing has to be measured by eye.
	#
	# The button is only as wide as the word it surrounds, and the labels
	# are inset by $PAD so it starts slightly LEFT of them - a button
	# reads as a button rather than as a third label.

	my $BTN = 50;		# the Save button
	my $PAD = 6;		# the labels' inset from the button's left edge
	my $COL = 64;		# where the label column starts
	my $LBL = 48;		# the label column's width - 'Author:' sets it

	# REVERT SITS UNDER SAVE, in the left column, because the two are one
	# pair: an object is dirty or it is not, and these are the only two
	# ways out of dirty.  Revert is what makes refusing a selection change
	# while dirty a reasonable behaviour rather than a trap - see
	# docs/design/editing.md.

	$this->{ctl_name} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,[220,-1],wxTE_PROCESS_ENTER);
	$this->{ctl_id} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,[110,-1],wxTE_PROCESS_ENTER);
	$this->{ctl_zauthor} = Wx::SpinCtrl->new($right,-1,'',
		wxDefaultPosition,[60,-1],wxSP_ARROW_KEYS,0,24,15);
	$this->{ctl_zmin} = Wx::SpinCtrl->new($right,-1,'',
		wxDefaultPosition,[60,-1],wxSP_ARROW_KEYS,0,24,10);
	$this->{ctl_zmax} = Wx::SpinCtrl->new($right,-1,'',
		wxDefaultPosition,[60,-1],wxSP_ARROW_KEYS,0,24,16);

	# The subregion's own Max spinner, and the text that says where its
	# band starts.  A separate control rather than the region's, because
	# the two live in different rows and a wx control belongs to one.

	$this->{ctl_submax} = Wx::SpinCtrl->new($right,-1,'',
		wxDefaultPosition,[60,-1],wxSP_ARROW_KEYS,0,24,16);
	$this->{txt_submin} = Wx::StaticText->new($right,-1,'',
		wxDefaultPosition,[90,-1]);

	# THE SOURCE IS ONE ROW FOR BOTH KINDS, unlike the zoom levels: a
	# region and a subregion answer this question identically, so there is
	# nothing to swap and one set of controls serves both.
	#
	# THE PULLDOWN CARRIES THE ID, THE TEXT CARRIES THE NAME.  Ids are
	# short and names are not - 'gibs_weld_annual' against 'NASA GIBS -
	# Landsat WELD True Colour (global annual)' - so a combined entry would
	# be a dropdown wider than the pane to show a field that is usually
	# one word.  The text is last in the row and unsized, so a long name
	# runs off the right rather than pushing anything.
	#
	# It is also where the failure is said.  An id that resolves to nothing
	# - the normal condition of a set that arrived from somebody else -
	# shows the REMEMBERED name in red, which is the only moment the
	# souvenir is worth more than the live answer.

	$this->{ctl_source} = Wx::ComboBox->new($right,-1,'',
		wxDefaultPosition,[150,-1],[],wxCB_READONLY);
	$this->{txt_source} = Wx::StaticText->new($right,-1,'');

	$this->{ctl_show} = Wx::CheckBox->new($right,-1,'show on map');
	$this->{ctl_save} = Wx::Button->new($right,-1,'Save',
		wxDefaultPosition,[$BTN,-1]);
	$this->{ctl_save}->Enable(0);
	$this->{ctl_revert} = Wx::Button->new($right,-1,'Revert',
		wxDefaultPosition,[$BTN,-1]);
	$this->{ctl_revert}->Enable(0);

	# ROW 1 -- Save, the id, and the map checkbox.  The ID IS STRUCTURAL
	# -- the file name, the key every set references, and the stem of the
	# exported file -- which is why it leads rather than the name,
	# and why it has a field of its own: SanBlasE is not a slug of 'San
	# Blas East', it is a decision.

	my $id_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$id_row->Add($this->{ctl_save},0,$CV,0);
	$id_row->AddSpacer($COL - $BTN);
	$id_row->Add(Wx::StaticText->new($right,-1,'Id:',
		wxDefaultPosition,[$LBL,-1]),0,$CV,0);
	$id_row->Add($this->{ctl_id},0,$CV,0);
	$id_row->AddSpacer(20);
	$id_row->Add($this->{ctl_show},0,$CV,0);

	# ROW 2 -- the name.  Free text, and the only field here with no
	# structural role at all.

	my $name_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$name_row->Add($this->{ctl_revert},0,$CV,0);
	$name_row->AddSpacer($COL - $BTN);
	$name_row->Add(Wx::StaticText->new($right,-1,'Name',
		wxDefaultPosition,[$LBL,-1]),0,$CV,0);
	$name_row->Add($this->{ctl_name},0,$CV,0);

	# ROW 3 -- the levels.  THERE ARE TWO OF THESE AND EXACTLY ONE IS
	# EVER SHOWN, because a region and a subregion do not have the same
	# fields.  A region has all three.  A SUBREGION HAS ONLY MAX: its
	# floor is its parent's zmax + 1 and its authored level is the
	# region's, neither of which it can be asked about -- so they are
	# said as text rather than offered as disabled spinners, which read
	# as settings that happen to be locked.  Its Max sits in the field
	# column with Id and Name, because it is the one thing being edited.

	my $zoom_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$zoom_row->AddSpacer($PAD);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Zoom',
		wxDefaultPosition,[$COL - $PAD,-1]),0,$CV,0);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Author:',
		wxDefaultPosition,[$LBL,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zauthor},0,$CV,0);
	$zoom_row->AddSpacer(14);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Min:',
		wxDefaultPosition,[30,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zmin},0,$CV,0);
	$zoom_row->AddSpacer(14);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Max:',
		wxDefaultPosition,[32,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zmax},0,$CV,0);

	my $sub_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$sub_row->AddSpacer($PAD);
	$sub_row->Add(Wx::StaticText->new($right,-1,'Zoom',
		wxDefaultPosition,[$COL - $PAD,-1]),0,$CV,0);
	$sub_row->Add(Wx::StaticText->new($right,-1,'Max:',
		wxDefaultPosition,[$LBL,-1]),0,$CV,0);
	$sub_row->Add($this->{ctl_submax},0,$CV,0);
	$sub_row->AddSpacer(14);
	$sub_row->Add($this->{txt_submin},0,$CV,0);

	# ROW 4 -- the source.  IT LINES UP WITH THE ZOOM ROW, NOT WITH THE
	# FIELDS: 'Source:' sits where 'Zoom' does and the pulldown where
	# 'Author:' does, one column to the LEFT of the id, name and spinners.
	# The row says one thing rather than three, and starting it early
	# leaves the width for the name that follows it.

	my $src_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$src_row->AddSpacer($PAD);
	$src_row->Add(Wx::StaticText->new($right,-1,'Source:',
		wxDefaultPosition,[$COL - $PAD,-1]),0,$CV,0);
	$src_row->Add($this->{ctl_source},0,$CV,0);
	$src_row->AddSpacer(8);
	$src_row->Add($this->{txt_source},0,$CV,0);

	$this->{zoom_row} = $zoom_row;
	$this->{sub_row}  = $sub_row;

	$this->{props} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{props}->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(8);
	$sizer->Add($id_row,0,wxLEFT|wxRIGHT,8);
	$sizer->AddSpacer(6);
	$sizer->Add($name_row,0,wxLEFT|wxRIGHT,8);
	$sizer->AddSpacer(6);
	$sizer->Add($zoom_row,0,wxLEFT|wxRIGHT,8);
	$sizer->Add($sub_row,0,wxLEFT|wxRIGHT,8);
	$sizer->Show($sub_row,0);
	$sizer->AddSpacer(6);
	$sizer->Add($src_row,0,wxLEFT|wxRIGHT,8);
	$sizer->AddSpacer(8);
	$sizer->Add($this->{props},1,wxEXPAND|wxALL,4);
	$right->SetSizer($sizer);

	$this->SplitVertically($left,$right,320);
	$this->SetMinimumPaneSize(160);

	EVT_TREE_SEL_CHANGED($this,$this->{tree},\&onSelect);
	EVT_TREE_ITEM_ACTIVATED($this,$this->{tree},\&onTreeActivated);
	EVT_LEFT_DOWN($this->{tree},sub { $this->onTreeLeftDown($_[1]) });
	EVT_RIGHT_DOWN($this->{tree},sub { $this->onTreeRightDown($_[1]) });
	EVT_MENU($this,$_,\&onTreeMenu) for ($MENU_COMMIT, $MENU_REVERT,
		$MENU_NEW_REGION, $MENU_NEW_SUB, $MENU_DELETE, $MENU_EXPLORE,
		$MENU_RESCAN, $MENU_PROBE);
	# Name and zoom are STAGED and committed by Save.  Applying them as
	# they were typed meant saving the file on every spinner tick, and
	# each save rebuilt the tree, which destroyed the very item being
	# edited.  'show on the map' stays immediate - it is not an edit to
	# the region, it is what you are looking at.

	EVT_TEXT($this,$this->{ctl_name},\&onEdited);
	EVT_TEXT_ENTER($this,$this->{ctl_name},\&onSave);
	EVT_TEXT($this,$this->{ctl_id},\&onEdited);
	EVT_TEXT_ENTER($this,$this->{ctl_id},\&onSave);
	EVT_SPINCTRL($this,$this->{ctl_zauthor},\&onEdited);
	EVT_SPINCTRL($this,$this->{ctl_zmin},\&onEdited);
	EVT_SPINCTRL($this,$this->{ctl_zmax},\&onEdited);
	EVT_SPINCTRL($this,$this->{ctl_submax},\&onEdited);
	EVT_COMBOBOX($this,$this->{ctl_source},\&onSourcePicked);
	EVT_BUTTON($this,$this->{ctl_save},\&onSave);
	EVT_BUTTON($this,$this->{ctl_revert},\&onRevert);
	EVT_CHECKBOX($this,$this->{ctl_show},\&onShowToggled);

	# Set while the controls are being filled from the selection, so
	# loading a region does not look like the user editing one.

	$this->{loading} = 0;

	$this->{seen_seq} = -1;
	$this->{timer} = Wx::Timer->new($this,-1);
	EVT_TIMER($this,-1,\&onTimer);
	$this->{timer}->Start($TIMER_MS);

	$this->{built} = 1;
	$this->populate();
	return $this;
}


sub closeOK
	# Pub::WX::Window's close hook, and the only place a window can refuse
	# to go away.
	#
	# THIS WINDOW IS THE DOCUMENT'S VIEW, so closing it closes the set -
	# which means it is also the last chance to save.  The question is
	# asked by the frame, because quitting the application asks exactly the
	# same one and the two must not drift apart.
	#
	# The timer MUST be stopped here: it fires into populate(), and
	# populate() touches a tree that is about to be destroyed.
{
	my ($this) = @_;
	return 0 if !$this->{frame}->okToDiscard('closing the Regions window');

	$this->{timer}->Stop() if $this->{timer};
	$this->{frame}->closeDocument() if setIsOpen();
	return 1;
}


sub _confirm
	# A yes or no, asked in the application's own name.
{
	my ($this,$text,$title) = @_;
	my $dlg = Wx::MessageDialog->new($this,$text,$title,
		wxYES_NO | wxICON_EXCLAMATION);
	my $answer = $dlg->ShowModal();
	$dlg->Destroy();
	return ($answer == wxID_YES) ? 1 : 0;
}


#---------------------------------------------
# the tree
#---------------------------------------------

sub _addNode
	# One region or subregion, then its children.  The node data is the
	# ids needed to find it again -- never the region hash itself, which
	# is replaced wholesale on every rescan.
{
	my ($this,$parent_item,$root_id,$reg,$is_root) = @_;

	my $item = $this->{tree}->AppendItem($parent_item,
		_nodeLabel($reg,$is_root));

	$this->{tree}->SetItemData($item,Wx::TreeItemData->new({
		kind	=> 'region',
		root_id	=> $root_id,
		id		=> $reg->{id},
		is_root	=> $is_root ? 1 : 0,
	}));

	# Remember the item that matches what was selected before a rebuild.
	# Matching on BOTH ids is what makes this work for a subregion --
	# matching only the region would silently drop the selection every
	# time the tree was rebuilt with a subregion selected.

	# Folded, because the shared selection may spell an id in whatever case
	# the other surface had, and a case mismatch would silently drop the
	# selection on every rebuild.

	my $was = $this->{_restore};
	$this->{_restore_item} = $item
		if $was && ($was->{kind} || '') ne 'set' &&
			lc($was->{root_id} // '') eq lc($root_id) &&
			lc($was->{id} // '') eq lc($reg->{id});

	# Only a whole region can be checked.  A subregion travels with its
	# parent -- it is part of what that region IS, not a thing to show
	# or hide on its own.

	$this->{tree}->SetItemState($item,isChecked($root_id) ? 1 : 0)
		if $is_root;

	# EXPANDED AFTER THE TREE IS BUILT, NOT DURING.  Expanding while items
	# are still being appended leaves the control's count of its own
	# visible rows ahead of the list it actually holds, and it fills the
	# difference by painting the tail of the list a second time - the
	# ghost rows below the real ones.  The item is remembered instead, and
	# populate() expands them all once the structure is complete.

	$this->_addNode($item,$root_id,$_,0) for @{$reg->{subregions}};
	push @{$this->{_expand}},$item if @{$reg->{subregions}};
	return $item;
}


sub populate
	# REGIONS ARE THE OUTER LEVEL.  The set is the document this window is
	# a view of, so it is named in the title above the tree rather than
	# being a node inside it - a document is not one of its own contents.
	# Which set is open is chosen from the File menu, like any other
	# document.
{
	my ($this) = @_;
	my $tree = $this->{tree};

	# NOT RE-ENTRANT, and it must not be entered again while it runs.
	# Filling a tree raises focus events, the frame turns a focus event
	# into an activation, and an activation asks for a rebuild - so a
	# populate can arrive inside a populate and never come back.  One flag
	# here is worth more than reasoning about which widget call fires
	# what, on which platform.

	return if $this->{populating};
	$this->{populating} = 1;

	# Remember what was selected so a rebuild does not move the user.
	#
	# THE SHARED SELECTION WINS over what this tree had, when the two
	# disagree - which is how a click on the map moves the tree.  A rebuild
	# is the only moment the tree can follow, and it happens on the same
	# poll that delivered the change.

	$this->{_restore}      = $this->selectedIds();
	$this->{_restore_item} = undef;

	my ($sel_region,$sel_sub) = getSelection();
	if ($sel_region)
	{
		my $want = { kind => 'region', root_id => $sel_region,
					 id => ($sel_sub || $sel_region),
					 is_root => ($sel_sub ? 0 : 1) };
		my $have = $this->{_restore};
		$this->{_restore} = $want
			if !$have ||
				lc($have->{root_id} // '') ne lc($sel_region) ||
				lc($have->{id} // '') ne lc($want->{id});
	}

	# FROZEN FOR THE WHOLE REBUILD.  Nothing is drawn until the item list
	# is finished, so the control computes its layout once, from a
	# structure that is not still changing under it.

	$tree->Freeze();

	$tree->DeleteAllItems();
	my $root = $tree->AddRoot('regions');
	my @ids  = getRegionIds();

	$this->{_expand} = [];
	$this->_addNode($root,$_,getRegion($_),1) for @ids;
	$tree->Expand($_) for @{$this->{_expand}};
	$this->{_expand} = undef;

	$tree->SelectItem($this->{_restore_item})
		if $this->{_restore_item} && $this->{_restore_item}->IsOk();
	$this->{_restore} = undef;

	$tree->Thaw();

	# The tree is no longer the splitter's child but a panel's, so the
	# panel is what has to be laid out before the tree can know how tall
	# its client area is.

	$this->{left}->Layout();
	$this->showSetTitle();

	$this->{seen_seq} = getStateSeq();
	display($dbg_win,0,"winRegions::populate() ".scalar(@ids).
		" region(s) at state ".$this->{seen_seq});
	$this->showProperties();
	$this->{populating} = 0;
}


sub showSetTitle
	# WHAT IS OPEN, AND WHETHER IT IS SAVED.  The same two facts the frame
	# title carries, said again where the work is - a pane that can be
	# floated or docked beside another window cannot rely on the title bar
	# being anywhere near it.
{
	my ($this) = @_;
	my $text = setIsOpen() ?
		openSetName().(isSetDirty() ? ' *' : '').'    '._setSummary() :
		'no region set open';
	$this->{ctl_set}->SetLabel($text)
		if $this->{ctl_set}->GetLabel() ne $text;
}


sub onTimer
{
	my ($this,$event) = @_;

	# NOT UNTIL THE PANE EXISTS - the same trap winSources::onTimer
	# describes at length.  The frame activates the page from inside
	# MyWindow(), before any of the widgets below it are made, and this
	# pane would die one line further on asking ctl_save whether it is
	# enabled.

	return if !$this->{built};
	return if getStateSeq() == $this->{seen_seq};

	# Never rebuild out from under an edit in progress.  A rebuild
	# reloads the controls from the model, which would throw away
	# whatever was half typed.  The change is picked up on the next tick
	# after Save.

	return if $this->{ctl_save}->IsEnabled();

	# A PANE THAT IS NOT ON TOP DOES NOT TOUCH ITS WIDGETS.  Filling a
	# tree that sits on a notebook page which is not showing drags the
	# notebook to that page, and which pane is in front is the user's
	# decision alone - not something a poll may take from them because
	# some other surface changed the selection.  There is also nothing to
	# see: the rebuild is for a window nobody is looking at.
	#
	# Nothing is lost by waiting.  What the tree shows is the shared
	# state, not anything of its own, so it is correct the moment it is
	# built - and it is built on the way in, by onActivate() below.

	return if !$this->IsShown();

	display($dbg_win,0,"winRegions: state changed to ".getStateSeq()." - rebuilding");
	$this->populate();
}


sub onActivate
	# THE WAY IN.  Pub::WX::Frame calls this as the pane becomes current,
	# and everything a pane skipped while it was behind is picked up here,
	# by the one path that decides whether a rebuild is wanted at all.
	#
	# NOT Pub::WX's pending_populate, which looks like it is for exactly
	# this and is a trap: setCurrentPane() clears the flag AFTER calling
	# populate(), so any focus event raised while the pane is filling
	# re-enters setCurrentPane(), finds the flag still set, and populates
	# again - without end.  It froze the application on the first tab
	# switch and took it down with a segfault.
{
	my ($this) = @_;
	$this->onTimer();
}


sub selectedIds
{
	my ($this) = @_;
	my $item = $this->{tree}->GetSelection();
	return undef if !$item || !$item->IsOk();
	my $d = $this->{tree}->GetItemData($item);
	return undef if !$d;
	return $d->GetData();
}


#---------------------------------------------
# events
#---------------------------------------------

sub onTreeLeftDown
	# A click lands on the checkbox only when it hits the state icon;
	# anything else is an ordinary selection and is passed along.
{
	my ($this,$event) = @_;
	my ($item,$flags) = $this->{tree}->HitTest($event->GetPosition());
	if ($item && $item->IsOk() && ($flags & wxTREE_HITTEST_ONITEMSTATEICON))
	{
		my $d = $this->{tree}->GetItemData($item);
		my $node = $d ? $d->GetData() : undef;

		if ($node && $node->{is_root})
		{
			my $on = isChecked($node->{root_id}) ? 0 : 1;
			display($dbg_win,0,"winRegions: ".
				($on ? 'check' : 'uncheck')." $node->{root_id}");
			if (setChecked($node->{root_id},$on))
			{
				$this->{tree}->SetItemState($item,$on);

				# The bump is what tells the map.  seen_seq is advanced
				# too, so this pane does not rebuild itself over a change
				# it just made and lose the user's place.

				bumpState("'$node->{root_id}' ".($on ? 'checked' : 'unchecked'));
				$this->{seen_seq} = getStateSeq();
			}
		}
		return;
	}
	$event->Skip();
}


sub onTreeActivated
	# DOUBLE CLICK SELECTS AND SHOWS.  wx sends the selection change
	# first, so by the time this arrives the map already knows what was
	# picked -- all the gesture adds is a window to see it in, and only
	# when there is not one already.  navMate's trees answer a double
	# click the same way, which is where it comes from.
	#
	# THE EVENT IS NOT SKIPPED, so a region with subregions does not also
	# expand out from under the pointer.  The expand button and the arrow
	# keys still do that, and one gesture that does two things at once is
	# hard to aim.
	#
	# 'Not currently open' is a browser that has stopped polling, which is
	# the only sense in which this process can know -- see cm_state.  A
	# map that is open but buried stays where it is: raising somebody
	# else's window is not this application's business.
{
	my ($this,$event) = @_;
	my $node = $this->selectedIds();
	return if !$node;
	return if mapIsOpen();
	display($dbg_win,0,"winRegions: double click on '".
		($node->{is_root} ? $node->{root_id} : $node->{id})."' opens the map");
	openMapBrowser();
}


sub onTreeRightDown
	# THE TREE IS WHERE THINGS COME INTO AND GO OUT OF EXISTENCE, and this
	# is that menu.  It deliberately does not draw: 'New region' creates the
	# object and leaves the map to offer its Draw banner, because a mode
	# must never be armed in a window the user is not looking at.
	#
	# See docs/design/editing_tree.md.
{
	my ($this,$event) = @_;
	my ($item) = $this->{tree}->HitTest($event->GetPosition());
	my $node;
	if ($item && $item->IsOk())
	{
		$this->{tree}->SelectItem($item);
		my $d = $this->{tree}->GetItemData($item);
		$node = $d ? $d->GetData() : undef;
	}

	my $menu = Wx::Menu->new();
	return if !setIsOpen();

	if (!$node)
	{
		$menu->Append($MENU_NEW_REGION,'New region...');
		$menu->AppendSeparator();
		$menu->Append($MENU_EXPLORE,'Open folder in Explorer');
		$menu->Append($MENU_RESCAN,'Revert all...');
	}
	else
	{
		# COMMIT AND REVERT ACT ON THE REGION, whichever node was clicked.
		# A subregion has no file of its own - it is part of the region
		# that holds it - and a menu that implied otherwise would be
		# offering to write something that does not exist.

		my $what = $node->{is_root} ? "region '$node->{root_id}'" :
			"subregion '$node->{id}'";
		my $dirty = isRegionDirty($node->{root_id});

		$menu->Append($MENU_NEW_SUB,'New subregion...');
		$menu->AppendSeparator();

		# PROBE IS REACHED BY POINTING AT WHAT TO PROBE, which is why it is
		# here rather than on the Build menu where it started.  A probe is
		# about a SOURCE, but it has to be told where to stand and look,
		# and a node is exactly that - so the gesture supplies the area and
		# the dialog asks only which source and how deep.

		$menu->Append($MENU_PROBE,"Probe over $what...");
		$menu->AppendSeparator();
		$menu->Append($MENU_COMMIT,"Commit '$node->{root_id}'");
		$menu->Append($MENU_REVERT,"Revert '$node->{root_id}'...");
		$menu->Enable($MENU_COMMIT,$dirty ? 1 : 0);
		$menu->Enable($MENU_REVERT,$dirty ? 1 : 0);
		$menu->AppendSeparator();
		$menu->Append($MENU_DELETE,"Delete $what...");
	}

	$this->{_menu_node} = $node;
	$this->PopupMenu($menu,$event->GetPosition());
}


sub probeDialog
	# START A PROBE OVER THE NODE THAT WAS CLICKED.
	#
	# The gesture already said WHERE, so the dialog asks only which source
	# and how deep.  A probe is about a source; the node is where to stand
	# and look, and offering a list of areas here would be a second way to
	# choose one that could disagree with the node under the pointer.
{
	my ($this,$node) = @_;
	return if !$node;

	if (probeRunning())
	{
		Wx::MessageBox("A probe is already running.\n\n".
			"Halt it in the Probe pane first - two runs publish into one ".
			"result set.",
			$$resources{app_title},wxOK | wxICON_INFORMATION,$this);
		return;
	}
	if (!getSourceIds())
	{
		Wx::MessageBox("No sources are installed.",
			$$resources{app_title},wxOK | wxICON_EXCLAMATION,$this);
		return;
	}

	my $scope = $node->{is_root} ?
		{ region => $node->{root_id} } :
		{ region => $node->{root_id}, sub => $node->{id} };
	my $label = $node->{is_root} ? $node->{root_id} :
		"$node->{root_id}/$node->{id}";

	my $frame = Pub::WX::Frame::getAppFrame();
	my $dlg = w_probecfg->new($frame,$label,$scope);
	my $go  = $dlg->ShowModal();
	my ($src_id,$opts) = $dlg->chosen();
	$dlg->Destroy();
	return if $go != wxID_OK || !$src_id;

	# THE MODE FIRST, THEN THE PANE THAT SHOWS IT.  Raised rather than
	# duplicated: two tables of one result set would be two things to keep
	# in step for no gain, which is what findPane settles.

	probeSetMode(1);
	my $pane = $frame->findPane($WIN_PROBE) || $frame->createPane($WIN_PROBE);

	my $prog = newProgress(1,'');
	$prog->{active} = 1;
	$prog->{phase}  = 'Sampling';
	$pane->setProgress($prog) if $pane;

	threads->create(\&dm_sample::sampleWorker,$prog,[$src_id,$scope],
		$opts)->detach();
}


sub newRegionDialog
	# Reached from the Edit menu and from the tree's own menu, and it is
	# the same act either way - which is why it is a method rather than a
	# branch inside one of them.
{
	my ($this) = @_;
	return if $this->_refuseIfLocked('create a region');

	my $name = Wx::GetTextFromUser(
		"The region is created with NO geometry.\n".
		"Draw its outline on the map afterwards.",
		'New region','',$this);
	return if !defined($name) || $name !~ /\S/;

	# The zooms come from the regions already here, because every file
	# built together must agree on zauthor and zmin.  Offering what already
	# works is how this stops making an unbuildable sibling.

	my ($za,$zn,$zx) = (15,10,16);
	my @ids = getRegionIds();
	if (@ids)
	{
		my $sib = getRegion($ids[0]);
		($za,$zn,$zx) = ($sib->{zauthor},$sib->{zmin},$sib->{zmax});
	}
	my $reg = newRegion($name,$za,$zn,$zx);
	return if !$reg;

	bumpState("region '$reg->{id}' created");
	setSelection($reg->{id},'');
	$this->populate();
}


sub onTreeMenu
{
	my ($this,$event) = @_;
	my $id   = $event->GetId();
	my $node = $this->{_menu_node};

	if ($id == $MENU_RESCAN)
	{
		# REVERTING EVERYTHING, which is what re-reading the folder now
		# means.  It is worth a question, because what it throws away is
		# every unsaved change in the document.

		return if $this->_refuseIfLocked('revert the set');
		return if isSetDirty() && !$this->_confirm(
			"Throw away every unsaved change to '".openSetName()."'\n".
			"and re-read the folder?",'Revert All');

		rescanSets();
		revertSet();
		bumpState('set reverted');
		$this->populate();
		return;
	}
	if ($id == $MENU_EXPLORE)
	{
		my $dir = setDir(openSetName());
		$dir =~ s|/|\\|g;
		system(1,"explorer.exe \"$dir\"") if is_win();
		return;
	}
	if ($id == $MENU_COMMIT)
	{
		commitRegion($node->{root_id});
		bumpState("region '$node->{root_id}' committed");
		$this->populate();
		return;
	}
	if ($id == $MENU_REVERT)
	{
		# A REGION THAT WAS NEVER SAVED HAS NOTHING TO GO BACK TO, and its
		# saved state is absence - so reverting it is a delete, and it is
		# asked as one.

		my $id = $node->{root_id};
		return if $this->_refuseIfLocked("revert '$id'");
		return if !$this->_confirm(
			"Throw away the unsaved changes to '$id'?\n".
			"A region that has never been saved is removed.",'Revert');

		revertRegion($id);
		bumpState("region '$id' reverted");
		$this->populate();
		return;
	}
	if ($id == $MENU_NEW_REGION)
	{
		$this->newRegionDialog();
		return;
	}
	if ($id == $MENU_PROBE)
	{
		$this->probeDialog($node);
		return;
	}
	if ($id == $MENU_NEW_SUB)
	{
		return if $this->_refuseIfLocked('create a subregion');
		my $parent = $node->{is_root} ? $node->{root_id} : $node->{id};
		my $name = Wx::GetTextFromUser(
			"A subregion adds resolution INSIDE its parent.\n".
			"It is created with no geometry - draw it on the map.",
			"New subregion of $parent",'',$this);
		return if !defined($name) || $name !~ /\S/;

		my (undef,$pnode) = findAnywhere($parent);
		my $zmax = ($pnode ? $pnode->{zmax} : 16) + 2;
		$zmax = 24 if $zmax > 24;

		my $sub = addSubregion($parent,$name,$zmax);
		return if !$sub;
		bumpState("subregion '$sub->{id}' added");
		$this->populate();
		return;
	}
	if ($id == $MENU_DELETE)
	{
		return if $this->_refuseIfLocked('delete');
		my $is_root = $node->{is_root};
		my $what = $is_root ? "region '$node->{root_id}' and its file" :
			"subregion '$node->{id}'";
		return if Wx::MessageBox("Delete $what?",'chartMaker',
			wxYES_NO | wxICON_QUESTION,$this) != wxYES;

		my $ok = $is_root ? deleteRegion($node->{root_id}) :
			deleteSubregion($node->{root_id},$node->{id});
		return if !$ok;
		bumpState('deleted');
		$this->populate();
		return;
	}
}


sub onSelect
	# ONE SELECTION, SHARED BY BOTH SURFACES.  Clicking here moves the
	# map, because the two panes cannot agree about what 'delete' means if
	# each keeps its own idea of what is selected.
	#
	# The seen_seq is advanced past our own bump, so this pane does not
	# rebuild itself over a change it just made and lose the user's place.
{
	my ($this,$event) = @_;

	# A REBUILD IS NOT A SELECTION.  Deleting and refilling the tree makes
	# the control announce a selection change for whatever item it happens
	# to land on as items disappear - five of them for five regions - and
	# each one was being published as if the user had clicked it.  What the
	# tree ends up selected on is what populate() put it on, which came
	# from the shared selection to begin with, so there is nothing here to
	# report.

	return if $this->{populating};

	# WHAT THE STATE WAS BEFORE THIS CLICK PUBLISHED ANYTHING.  Advancing
	# seen_seq past our own bump is right; advancing it past somebody
	# else's is how a change made on the map gets marked SEEN by a pane
	# that never rebuilt for it.  See the test at the bottom of this sub.

	my $before = getStateSeq();

	$this->showProperties();

	my $node = $this->selectedIds();
	if (!$node)
	{
		setSelection('','');
	}
	else
	{
		setSelection($node->{root_id},
			$node->{is_root} ? '' : $node->{id});
	}

	# ONLY IF THERE WAS NOTHING ELSE OUTSTANDING.  If this pane was
	# already behind when the click arrived - a subregion created on the
	# map a fraction of a second ago, the timer not yet ticked - then it
	# stays behind, and the next tick rebuilds as it always would have.
	# Taking the counter forward here instead would record that change as
	# shown, and nothing would redraw until something else moved the
	# state, which in practice was the next save.

	$this->{seen_seq} = getStateSeq()
		if $this->{seen_seq} == $before;
}


sub _selectedRegion
	# The region or subregion the tree is on, and its owning region.
{
	my ($this) = @_;
	my $node = $this->selectedIds();
	return (undef,undef,undef) if !$node;

	my $root = getRegion($node->{root_id});
	return (undef,undef,$node) if !$root;
	return ($root,$root,$node) if $node->{is_root};
	my ($found) = findSubregion($root,$node->{id});
	return ($found,$root,$node);
}


sub _fillSources
	# Rebuild the pulldown around the value the region actually holds.
	#
	# THE STORED ID IS ALWAYS AN ENTRY, installed or not.  A read-only
	# combo can only show what is in its list, so an id that resolves to
	# nothing would come up blank -- and the next Save would write that
	# blank over a build choice nobody touched.  A set that arrived from
	# somebody else has to be openable without being quietly rewritten.
{
	my ($this,$want,$is_root) = @_;

	# ONLY A SUBREGION IS OFFERED 'inherited'.  A region that inherited
	# its build source would build differently in somebody else's hands,
	# and a set is meant to travel - see dm_region's validator, which
	# refuses it outright rather than relying on this list.

	# A REGION IS OFFERED '(none)' AND A SUBREGION IS OFFERED 'inherited',
	# and they are not the same offer.  'inherited' is a decision - defer
	# to my parent - and always resolves.  '(none)' is the absence of one,
	# which is how every region now begins, and it resolves to nothing.
	#
	# It is in the list rather than being an empty first entry because a
	# blank row in a read-only combo reads as a rendering fault. Something
	# has to be selected and it has to say what it means.

	my @ids = ($is_root ? $NO_SOURCE : $SOURCE_INHERITED, getBuildSourceIds());
	push @ids,$want
		if defined($want) && $want ne '' && !grep { $_ eq $want } @ids;

	my $ctl = $this->{ctl_source};
	$ctl->Clear();
	$ctl->Append($_) for @ids;

	# SOMETHING IS ALWAYS SELECTED.  An empty source is a real state and
	# has its own entry, so there is no case left where the control shows
	# nothing at all.

	$ctl->SetStringSelection(
		defined($want) && $want ne '' ? $want :
		$is_root ? $NO_SOURCE : $SOURCE_INHERITED);
}


sub _showSourceName
	# The name beside the pulldown, and the one place the two copies of
	# the source's identity are allowed to disagree out loud.
{
	my ($this,$id,$remembered) = @_;
	my $txt  = $this->{txt_source};
	my $bad  = 0;
	my $show = '';

	if ($id eq '')
	{
		# NOT AN ERROR, AND DELIBERATELY NOT RED.  A region begins here,
		# and deciding the ground before the imagery is the order this
		# application means people to work in.  Red is reserved below for
		# an id that names something not installed, which IS a problem
		# somebody has to go and solve.
		#
		# It still says what it costs, because the consequence is not
		# guessable from a blank field: the region is editable, drawable
		# and countable, and it will not build.

		$show = 'no source chosen - this region cannot be built yet';
	}
	elsif ($id eq $SOURCE_INHERITED)
	{
		# Deliberately blank.  What it inherits is a fact about the build,
		# not about this region, and naming a source here would read as a
		# choice that had been made.
	}
	elsif (my $src = getSource($id))
	{
		# INSTALLED IS NOT THE SAME AS USABLE, and the other two ways it
		# can fail were invisible here.  The pulldown offers only sources
		# that declare 'build', so a display-only one can only arrive on a
		# region authored elsewhere or edited by hand - and an unresolved
		# key is not about the .tsd at all, it is about this machine.
		# Neither was said anywhere until a build refused, which is a long
		# way from the control that fixes it.
		#
		# The SAME predicate the preflight and the build use, so this pane
		# and that dialog cannot come to different conclusions about the
		# same region.  See dm_source::sourceState.

		my $state = sourceState($id,'build');
		if ($state eq $SRC_OK)
		{
			$show = $src->{name};
		}
		else
		{
			$bad  = 1;
			$show = $src->{name}.'  -- '.
				($state eq $SRC_NOT_BUILD ?
					'display only, cannot be built from' :
					'needs a value in Edit > Key Store');
		}
	}
	else
	{
		# NOT INSTALLED IS NOT CORRUPTION.  The souvenir is now the only
		# statement of where the tiles were meant to come from, so it is
		# what gets shown -- in red, because a build cannot be run from it.

		$bad  = 1;
		$show = ($remembered // '') =~ /\S/ ?
			"$remembered  -- not installed" : 'not installed';
	}

	$txt->SetForegroundColour($bad ? Wx::Colour->new(180,0,0) :
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_WINDOWTEXT));
	$txt->SetLabel($show);
	$txt->Refresh();
}


sub _zmaxCtl
	# WHICHEVER MAX SPINNER IS THE SHOWN ONE.  The region's row and the
	# subregion's row each carry their own, so every read of zmax has to
	# say which kind of thing is selected.
{
	my ($this,$is_root) = @_;
	return $is_root ? $this->{ctl_zmax} : $this->{ctl_submax};
}


sub _isDirty
{
	my ($this) = @_;
	my ($reg,undef,$node) = $this->_selectedRegion();
	return 0 if !$reg;
	my $is_root = ($node && $node->{is_root}) ? 1 : 0;
	return 1 if $this->{ctl_name}->GetValue() ne $reg->{name};
	return 1 if $this->{ctl_id}->GetValue() ne $reg->{id};
	return 1 if $this->_zmaxCtl($is_root)->GetValue() != $reg->{zmax};
	return 1 if $this->{ctl_source}->GetStringSelection() ne
		($reg->{source} // $SOURCE_INHERITED);

	# A subregion has no authored level and no floor, so there is nothing
	# on those two controls that could be dirty.

	return 0 if !$is_root;
	return 1 if $this->{ctl_zauthor}->GetValue() != $reg->{zauthor};
	return 1 if $this->{ctl_zmin}->GetValue() != $reg->{zmin};
	return 0;
}


sub onEdited
	# Nothing is written here.  The controls hold a staged edit, Save and
	# Revert light up together; that is the whole of it.
{
	my ($this,$event) = @_;
	return if $this->{loading};
	my $dirty = $this->_isDirty() ? 1 : 0;
	$this->{ctl_save}->Enable($dirty);
	$this->{ctl_revert}->Enable($dirty);
}


sub onSourcePicked
	# THE NAME BELONGS TO THE PULLDOWN, NOT TO THE SAVED REGION.  It has
	# to answer the moment the id changes: updating it only on selection
	# meant it described the source that was there before the pick, which
	# is worse than showing nothing.
	#
	# The remembered name still comes from the region, because the one id
	# that can be picked and not resolve is the one the region arrived
	# with.
{
	my ($this,$event) = @_;
	my ($reg) = $this->_selectedRegion();
	$this->_showSourceName($this->{ctl_source}->GetStringSelection(),
		$reg ? $reg->{source_name} : '');
	$this->{right}->Layout();
	$this->onEdited($event);
}


sub onRevert
	# Discard back to what is on disk.  There is nothing to undo and
	# nothing to remember: the controls are simply reloaded from the model,
	# which is the only copy that was ever authoritative.
	#
	# It exists because staged editing without it leaves no way out of a
	# half-made change except making it - and it is what lets a selection
	# change be refused while dirty instead of silently discarding work.
{
	my ($this,$event) = @_;
	my ($reg,undef,$node) = $this->_selectedRegion();
	return if !$reg;
	display($dbg_win,0,"winRegions: revert '$reg->{id}'");
	$this->showProperties();
}


sub _nodeLabel
	# A region shows the range it builds and the level it is authored at;
	# a subregion has only a depth it reaches.  One function, so the tree
	# cannot say two different things about the same node.
	#
	# THE NUMBERS ARE A COLUMN, fixed width, because a set whose regions
	# disagree about zauthor cannot be built together - and a
	# disagreement has to be visible at a glance rather than found by
	# clicking five regions and remembering what each one said.  The tree
	# is the only surface that can show it; see docs/design/editing_tree.md.
{
	my ($reg,$is_root) = @_;

	my $empty = scalar(@{$reg->{geometry} || []}) ? '' : '  (no geometry)';

	return sprintf("%-14s      to z%-2d%s",$reg->{name},$reg->{zmax},$empty)
		if !$is_root;
	return sprintf("%-14s  %2d-%-2d \@%-2d%s",$reg->{name},
		$reg->{zmin},$reg->{zmax},$reg->{zauthor},$empty);
}


sub _setSummary
	# WHAT THE SET IS, AND WHETHER IT COULD BUILD.  Every .rct built together
	# must agree on zauthor and zmin, so a set that does not agree with
	# itself is worth saying at the top of the window rather than leaving
	# to be discovered by a build.
{
	my @ids = getRegionIds();
	return 'empty' if !@ids;

	my (%za,%zn);
	for my $id (@ids)
	{
		my $reg = getRegion($id) or next;
		$za{$reg->{zauthor}}++;
		$zn{$reg->{zmin}}++;
	}

	my $n = scalar(@ids);
	my $mixed = '';
	for my $pair ([\%za,'zauthor'],[\%zn,'zmin'])
	{
		my ($h,$what) = @$pair;
		next if scalar(keys %$h) <= 1;
		$mixed = sprintf("MIXED %s - %s",$what,
			join(', ',map { "$h->{$_} at z$_" } sort { $a <=> $b } keys %$h));
		last;
	}
	return sprintf("%d region%s  %s",$n,($n == 1 ? '' : 's'),
		$mixed ? $mixed :
			sprintf("z%d \@%d",(keys %zn)[0],(keys %za)[0]));
}


sub _relabelSelected
	# Update the one tree label in place.  Rebuilding the tree here is
	# what destroyed the selection and the focus, and there is no reason
	# for it: one item changed.
{
	my ($this,$reg,$is_root) = @_;
	my $item = $this->{tree}->GetSelection();
	return if !$item || !$item->IsOk();
	$this->{tree}->SetItemText($item,_nodeLabel($reg,$is_root));
}


sub onSave
{
	my ($this,$event) = @_;
	return if $this->{loading};
	my ($reg,$root,$node) = $this->_selectedRegion();
	return if !$reg;

	# The same question onSelect asks, for the same reason - see there.

	my $before = getStateSeq();

	my $is_root = $node && $node->{is_root};
	my $name    = $this->{ctl_name}->GetValue();
	my $new_id  = $this->{ctl_id}->GetValue();
	my $zmax    = $this->_zmaxCtl($is_root)->GetValue();

	if ($name !~ /\S/)
	{
		warning(0,0,"winRegions: a name may not be empty");
		$this->{loading} = 1;
		$this->{ctl_name}->SetValue($reg->{name});
		$this->{loading} = 0;
		$this->{ctl_save}->Enable($this->_isDirty() ? 1 : 0);
		return;
	}
	if ($new_id !~ /^[A-Za-z0-9]+$/)
	{
		warning(0,0,"winRegions: an id must be [A-Za-z0-9] - ".
			"no spaces, nothing that has to be escaped in a file name");
		$this->{loading} = 1;
		$this->{ctl_id}->SetValue($reg->{id});
		$this->{loading} = 0;
		$this->{ctl_save}->Enable($this->_isDirty() ? 1 : 0);
		return;
	}

	my $old_id = $reg->{id};
	my $why    = "'$old_id'";
	$why .= " renamed to '$name'"	if $name ne $reg->{name};
	$why .= " zmax $zmax"			if $zmax != $reg->{zmax};
	$reg->{name} = $name;
	$reg->{zmax} = $zmax;

	# THE NAME IS RE-SNAPSHOT FROM THE LIVE SOURCE, except when there is
	# no live source to ask.  An id that resolves to nothing keeps the
	# name it arrived with: overwriting it with '' would destroy the only
	# record of what the author was building from, and this Save might
	# only have been a rename.

	# '(none)' IS A LABEL AND NOT AN ID.  It exists so the combo has
	# something to show for an unchosen source; what the model stores is
	# the empty string, and the translation happens here, at the only
	# place the control is read.

	my $source = $this->{ctl_source}->GetStringSelection();
	$source = '' if $source eq $NO_SOURCE;

	$why .= " source ".($source eq '' ? '(none)' : $source)
		if $source ne ($reg->{source} // $SOURCE_INHERITED);
	$reg->{source} = $source;
	if ($source eq '' || $source eq $SOURCE_INHERITED)
	{
		$reg->{source_name} = '';
	}
	elsif (my $src = getSource($source))
	{
		$reg->{source_name} = $src->{name};
	}

	if ($is_root)
	{
		my $zauthor = $this->{ctl_zauthor}->GetValue();
		my $zmin    = $this->{ctl_zmin}->GetValue();
		$why .= " zauthor $zauthor"	if $zauthor != $reg->{zauthor};
		$why .= " zmin $zmin"		if $zmin != $reg->{zmin};
		$reg->{zauthor} = $zauthor;
		$reg->{zmin}    = $zmin;
	}

	# An id change is not a field write.  For a region it moves the file
	# and every set that names it, which is setRegionId's whole job; for a
	# subregion, whose id nothing outside the file refers to, it IS just a
	# field -- but it still has to stay unique among its siblings.

	my $id_changed = $new_id ne $old_id;
	if ($id_changed)
	{
		$why .= " id '$new_id'";
		if ($is_root)
		{
			# setRegionId saves the file itself, so this is the write.

			return if !setRegionId($old_id,$new_id);
		}
		else
		{
			if ((findSubregion($root,$new_id))[0])
			{
				warning(0,0,"winRegions: '$root->{id}' already has a subregion '$new_id'");
				$this->{loading} = 1;
				$this->{ctl_id}->SetValue($old_id);
				$this->{loading} = 0;
				return;
			}
			$reg->{id} = $new_id;
			return if !stageRegion($root);
		}
	}
	elsif (!stageRegion($root))
	{
		return;
	}
	display($dbg_win,0,"winRegions: saved $why");

	bumpState($why);

	# AN ID CHANGE INVALIDATES THE TREE'S NODE DATA, which holds the ids
	# needed to find a node again.  Relabelling in place would leave every
	# item pointing at an id that no longer resolves, so the tree is
	# rebuilt -- after the selected item's data is moved to the new id, so
	# populate() can still find what was selected.

	if ($id_changed)
	{
		my $item = $this->{tree}->GetSelection();
		$this->{tree}->SetItemData($item,Wx::TreeItemData->new({
			root_id	=> $is_root ? $new_id : $root->{id},
			id		=> $new_id,
			is_root	=> $is_root ? 1 : 0,
		})) if $item && $item->IsOk();
		$this->populate();
		return;
	}

	# Otherwise move this pane's own idea of the version forward, so the
	# next timer tick does not rebuild the tree over a change made here
	# and take the selection with it - but ONLY over the bumps this save
	# made, exactly as in onSelect.  A change that arrived from elsewhere
	# while the user was typing is still owed a rebuild.

	$this->{seen_seq} = getStateSeq()
		if $this->{seen_seq} == $before;
	$this->_relabelSelected($reg,$is_root);
	$this->{ctl_save}->Enable(0);
	$this->showProperties();
}


sub onShowToggled
{
	my ($this,$event) = @_;
	return if $this->{loading};
	my $node = $this->selectedIds();
	return if !$node || !$node->{is_root};

	my $on = $this->{ctl_show}->IsChecked() ? 1 : 0;
	return if !setChecked($node->{root_id},$on);
	display($dbg_win,0,"winRegions: '$node->{root_id}' ".
		($on ? 'checked' : 'unchecked'));
	bumpState("'$node->{root_id}' ".($on ? 'checked' : 'unchecked'));
	$this->{seen_seq} = getStateSeq();

	my $item = $this->{tree}->GetSelection();
	$this->{tree}->SetItemState($item,$on) if $item && $item->IsOk();
}


#---------------------------------------------
# properties
#---------------------------------------------

sub _bounds
{
	my ($geom) = @_;
	my (@lon,@lat);
	for my $poly (@$geom)
	{
		push @lon,$_->[0] for @$poly;
		push @lat,$_->[1] for @$poly;
	}
	return undef if !@lon;
	@lon = sort { $a <=> $b } @lon;
	@lat = sort { $a <=> $b } @lat;
	return [ $lon[0],$lon[-1],$lat[0],$lat[-1] ];
}


sub _mapHolds
	# Is the map holding THIS object in a draw or an edit?  If so the
	# properties here must not offer to change it: the map has an
	# uncommitted copy, and a save from this side would be overwritten by
	# the map's commit or would overwrite it, depending purely on order.
	#
	# See docs/design/editing.md - the mode, its target and the dirty flag
	# are published precisely so that this pane can ask.
{
	my ($this,$node) = @_;
	return 0 if !$node;

	# A MAP THAT IS NOT THERE HOLDS NOTHING, which is the same sentence
	# editLocks() and editInProgress() both open with, and this was the one
	# consumer of the edit state that did not ask it.
	#
	# That omission is why the application used to CLEAR the edit state on
	# a timer: with this test unguarded, a browser closed in the middle of
	# an edit left the tree refusing to touch that object forever.  Wiping
	# the state fixed the tree and paid for it by reaching over and
	# cancelling live edits whenever a page went quiet for five seconds -
	# which browsers do to idle tabs, for their own reasons, and which no
	# grace period can reliably distinguish from a page that closed.
	#
	# Asking here instead costs one call and destroys nothing: a silent map
	# obstructs nobody, and the instant it polls again its edit is exactly
	# where it was.

	return 0 if !mapIsOpen();

	my $st = getEditState();
	return 0 if $st->{mode} eq $EDIT_BROWSE && !$st->{dirty};

	my $held = $st->{sub} || $st->{region};
	return 0 if !$held;
	my $mine = $node->{sub} || $node->{root_id};
	return lc($held) eq lc($mine // '') ? 1 : 0;
}


sub _refuseIfLocked
	# The single gate for anything structural this pane offers while the
	# map has work in flight.  Says what is in the way and the two ways
	# out, because a click that silently does nothing reads as broken.
{
	my ($this,$what) = @_;
	my $lock = editLocks();
	return 0 if !$lock;
	warning(0,0,"winRegions: cannot $what - $lock");
	warning(0,1,"Confirm or Cancel on the map first");
	return 1;
}


sub _enableControls
{
	my ($this,$on,$is_root) = @_;
	$this->{ctl_name}->Enable($on ? 1 : 0);
	$this->{ctl_id}->Enable($on ? 1 : 0);

	# THE ROW ITSELF IS THE ANSWER TO WHAT KIND OF THING IS SELECTED.  A
	# subregion has zmax alone, so its row is the one that is shown and
	# the region's three spinners are not on screen at all -- see the
	# comment where the two rows are built.  Nothing selected keeps the
	# region's row, which is the wider of the two.

	my $sizer = $this->{right}->GetSizer();
	$sizer->Show($this->{zoom_row},($on && !$is_root) ? 0 : 1);
	$sizer->Show($this->{sub_row}, ($on && !$is_root) ? 1 : 0);
	$this->{right}->Layout();

	$this->{ctl_zmax}->Enable($on ? 1 : 0);
	$this->{ctl_submax}->Enable($on ? 1 : 0);
	$this->{ctl_source}->Enable($on ? 1 : 0);
	$this->{ctl_zauthor}->Enable(($on && $is_root) ? 1 : 0);
	$this->{ctl_zmin}->Enable(($on && $is_root) ? 1 : 0);

	# Only a whole region can be shown or hidden.  A subregion travels
	# with its parent.

	$this->{ctl_show}->Enable(($on && $is_root) ? 1 : 0);

	# Save and Revert are enabled by an edit, never by a selection.
	$this->{ctl_save}->Enable(0);
	$this->{ctl_revert}->Enable(0);
}


sub _setProperties
	# THE DOCUMENT, said plainly.  The folder IS the answer to "what is on
	# built", so it is readable here rather than inferred - and what is
	# unsaved is part of that answer, because a file built now would be
	# built from the files rather than from what is on screen.
{
	my ($this) = @_;

	return "no region set open

".
		"File - Open Set, or File - New Set.
"
		if !setIsOpen();

	my $name = openSetName();
	my @ids  = getRegionIds();
	my @on   = getWorkingSet();
	my @bad  = dirtyRegionIds();

	my $text = "";
	$text .= sprintf("%-16s %s
","region set",$name);
	$text .= sprintf("%-16s %s
","folder",setDir($name));
	$text .= sprintf("%-16s %s
","unsaved",isSetDirty() ? "yes" : "no");
	$text .= sprintf("%-16s %d
","regions",scalar(@ids));
	$text .= sprintf("%-16s %d of %d
","shown",scalar(@on),scalar(@ids));
	$text .= "
";
	$text .= sprintf("    %s %s %-16s z%d-%d \@%d
",
		isChecked($_) ? "[x]" : "[ ]",
		isRegionDirty($_) ? "*" : " ",$_,
		getRegion($_)->{zmin},getRegion($_)->{zmax},
		getRegion($_)->{zauthor}) for @ids;

	$text .= "
EVERY region in a set is in what it builds.  The files
".
		"present in the folder ARE the set - there is no manifest, and
".
		"hiding a region here does not leave it out of the built file.
";
	$text .= "
Nothing is written until the set is saved.
" if isSetDirty();
	return $text;
}


sub showProperties
{
	my ($this) = @_;
	my ($reg,$root,$node) = $this->_selectedRegion();

	if (!$reg)
	{
		$this->{loading} = 1;
		$this->{ctl_name}->SetValue('');
		$this->{ctl_id}->SetValue('');
		$this->{ctl_show}->SetValue(0);
		$this->_fillSources($SOURCE_INHERITED,0);
		$this->_showSourceName($SOURCE_INHERITED,'');
		$this->_enableControls(0,0);
		$this->{loading} = 0;

		# WITH NOTHING SELECTED THE PANEL DESCRIBES THE DOCUMENT, which is
		# the only thing there is to say when no one region has been asked
		# about - and answers "what gets built" without a click.

		$this->{props}->SetValue($node ?
			"region '$node->{root_id}' is gone\n" : $this->_setProperties());
		return;
	}

	# A subregion has no zauthor and no zmin of its own.  Its floor is
	# the IMMEDIATE parent's zmax + 1, which is not the root's once
	# subregions nest, and it is said as text -- there is nothing there
	# to set.

	my $parent;
	if (!$node->{is_root})
	{
		(undef,$parent) = findSubregion($root,$reg->{id});
		$parent ||= $root;
	}

	$this->{loading} = 1;
	$this->{ctl_name}->SetValue($reg->{name});
	$this->{ctl_id}->SetValue($reg->{id});
	$this->{ctl_zauthor}->SetValue($root->{zauthor});
	$this->{ctl_zmin}->SetValue($root->{zmin});
	if ($parent)
	{
		$this->{ctl_submax}->SetValue($reg->{zmax});
		$this->{txt_submin}->SetLabel(sprintf("Min: %d",$parent->{zmax}+1));
	}
	else
	{
		$this->{ctl_zmax}->SetValue($reg->{zmax});
	}
	my $source = $reg->{source} // $SOURCE_INHERITED;
	$this->_fillSources($source,$node->{is_root});
	$this->_showSourceName($source,$reg->{source_name});
	$this->{ctl_show}->SetValue(isChecked($node->{root_id}) ? 1 : 0);

	# GREYED OUT WHILE THE MAP HOLDS IT.  Not merely advisory: an edit
	# committed from here would race the map's own commit.

	my $held = $this->_mapHolds($node);
	$this->_enableControls($held ? 0 : 1,$node->{is_root});
	$this->{right}->Layout();
	$this->{loading} = 0;

	my $text = '';
	$text .= "*** BEING EDITED ON THE MAP - Confirm or Cancel there ***\n\n"
		if $held;
	$text .= sprintf("%-16s %s\n",'name',$reg->{name});
	$text .= sprintf("%-16s %s\n",'id',$reg->{id});
	$text .= sprintf("%-16s %s\n",'kind',
		$node->{is_root} ? 'region' : "subregion of $node->{root_id}");
	$text .= sprintf("%-16s %s\n",'file',$root->{file});
	if ($node->{is_root})
	{
		$text .= sprintf("%-16s %d  (the level the polygon is drawn at)\n",
			'zauthor',$reg->{zauthor});
		$text .= sprintf("%-16s %d\n",'zmin',$reg->{zmin});
		$text .= sprintf("%-16s %d\n",'zmax',$reg->{zmax});
		$text .= sprintf("%-16s %s.rct\n",'file',$reg->{id});
	}
	else
	{
		$text .= sprintf("%-16s %d  (its band is z%d-%d)\n",'zmax',
			$reg->{zmax},$parent->{zmax}+1,$reg->{zmax});
	}
	# The souvenir is printed only when it is the last thing standing.
	# Two lines saying the same name is noise; two lines disagreeing is
	# the one case worth the space.

	if ($source eq $SOURCE_INHERITED)
	{
		$text .= sprintf("%-16s %s  (%s)\n",'source',$SOURCE_INHERITED,
			$node->{is_root} ? 'whatever the build is run with' :
				"from '$node->{root_id}'");
	}
	elsif (my $src = getSource($source))
	{
		$text .= sprintf("%-16s %s  (%s)\n",'source',$source,$src->{name});
	}
	else
	{
		$text .= sprintf("%-16s %s  *** NOT INSTALLED ***\n",'source',$source);
		$text .= sprintf("%-16s %s\n",'was called',$reg->{source_name})
			if ($reg->{source_name} // '') =~ /\S/;
	}

	$text .= sprintf("%-16s %s  (it is built either way)\n",'shown on map',
		isChecked($node->{root_id}) ? 'yes' : 'no');
	$text .= sprintf("%-16s %s\n",'notes',$reg->{notes}) if $reg->{notes};

	my $b = _bounds($reg->{geometry});
	$text .= sprintf("%-16s %.6f .. %.6f\n",'longitude',$b->[0],$b->[1]) if $b;
	$text .= sprintf("%-16s %.6f .. %.6f\n",'latitude',$b->[2],$b->[3])  if $b;
	$text .= sprintf("%-16s %d polygon(s), %d point(s)\n",'geometry',
		scalar(@{$reg->{geometry}}),regionPointCount($reg));
	$text .= "\n";

	my $n = 0;
	for my $poly (@{$reg->{geometry}})
	{
		my $pb = _bounds([$poly]);
		$text .= sprintf("polygon %d   %d points   lon %.6f..%.6f   lat %.6f..%.6f\n",
			$n++,scalar(@$poly),@$pb);

		# A debugging dump, so the actual numbers are here.  The first
		# few vertices are usually enough to see that an import or an
		# edit did what it was supposed to.

		my $max = scalar(@$poly) < 6 ? scalar(@$poly) : 6;
		$text .= sprintf("    [%2d]  %12.6f  %12.6f\n",$_,@{$poly->[$_]})
			for (0..$max-1);
		$text .= sprintf("    ... %d more\n",scalar(@$poly)-$max)
			if scalar(@$poly) > $max;
		$text .= "\n";
	}

	if (@{$reg->{subregions}})
	{
		$text .= sprintf("%-16s %d\n",'subregions',scalar(@{$reg->{subregions}}));
		for my $sub (@{$reg->{subregions}})
		{
			my $sb = _bounds($sub->{geometry});
			$text .= sprintf("    %-16s to z%-2d  %d polygon(s)",
				$sub->{id},$sub->{zmax},scalar(@{$sub->{geometry}}));
			$text .= sprintf("   lon %.6f..%.6f  lat %.6f..%.6f",@$sb) if $sb;
			$text .= "\n";
		}
	}

	$this->{props}->SetValue($text);
}


1;
