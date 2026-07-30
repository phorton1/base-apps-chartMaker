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
use Wx::Event qw( EVT_TREE_SEL_CHANGED EVT_LEFT_DOWN EVT_RIGHT_DOWN
				  EVT_TIMER EVT_MENU
				  EVT_TEXT EVT_TEXT_ENTER EVT_SPINCTRL EVT_CHECKBOX
				  EVT_BUTTON );
use Pub::Utils;
use Pub::WX::Window;
use cm_defs;
use cm_state;
use dm_set;
use dm_region;
use base qw(Wx::SplitterWindow Pub::WX::Window);


our $dbg_win:shared = 1;
	# 1 = quiet
	# 0 = rebuilds and checkbox clicks


my $TIMER_MS = 500;

# Menu ids, in this pane's own range.  Pub::WX reserves everything below
# 200; cm_defs uses the 10000s for panes and commands, so these sit clear
# of both.

my $MENU_NEW_SET	= 10501;
my $MENU_USE_SET	= 10502;
my $MENU_NEW_REGION	= 10503;
my $MENU_NEW_SUB	= 10504;
my $MENU_DELETE		= 10505;
my $MENU_EXPLORE	= 10506;
my $MENU_RESCAN		= 10507;


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

	$this->{tree} = Wx::TreeCtrl->new($this,-1,wxDefaultPosition,wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_LINES_AT_ROOT);

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

	# TWO COLUMNS.  The left one holds Save, then 'Name' and 'Zoom' under
	# it; the right one starts at $COL and holds 'Id:', the name field
	# itself, and 'Author:', all on the same edge.
	#
	# The button is only as wide as the word it surrounds, and the labels
	# are inset by $PAD so it starts slightly LEFT of them - a button
	# reads as a button rather than as a third label.

	my $BTN = 50;		# the Save button
	my $PAD = 6;		# the labels' inset from the button's left edge
	my $COL = 64;		# where the right column starts

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
	$this->{ctl_show} = Wx::CheckBox->new($right,-1,'show on map');
	$this->{ctl_save} = Wx::Button->new($right,-1,'Save',
		wxDefaultPosition,[$BTN,-1]);
	$this->{ctl_save}->Enable(0);
	$this->{ctl_revert} = Wx::Button->new($right,-1,'Revert',
		wxDefaultPosition,[$BTN,-1]);
	$this->{ctl_revert}->Enable(0);

	# ROW 1 -- Save, the id, and the map checkbox.  The ID IS STRUCTURAL
	# -- the file name, the key every set references, and the stem of the
	# exported card file -- which is why it leads rather than the name,
	# and why it has a field of its own: SanBlasE is not a slug of 'San
	# Blas East', it is a decision.

	my $id_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$id_row->Add($this->{ctl_save},0,$CV,0);
	$id_row->AddSpacer($COL - $BTN);
	$id_row->Add(Wx::StaticText->new($right,-1,'Id:',
		wxDefaultPosition,[24,-1]),0,$CV,0);
	$id_row->Add($this->{ctl_id},0,$CV,0);
	$id_row->AddSpacer(20);
	$id_row->Add($this->{ctl_show},0,$CV,0);

	# ROW 2 -- the name.  Free text, and the only field here with no
	# structural role at all.

	my $name_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$name_row->Add($this->{ctl_revert},0,$CV,0);
	$name_row->AddSpacer($COL - $BTN);
	$name_row->Add(Wx::StaticText->new($right,-1,'Name',
		wxDefaultPosition,[24,-1]),0,$CV,0);
	$name_row->Add($this->{ctl_name},0,$CV,0);

	# ROW 3 -- the three levels.  A subregion has zmax alone, and the
	# other two are disabled for it rather than hidden, so the shape of
	# the model stays visible.

	my $zoom_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$zoom_row->AddSpacer($PAD);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Zoom',
		wxDefaultPosition,[$COL - $PAD,-1]),0,$CV,0);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Author:',
		wxDefaultPosition,[48,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zauthor},0,$CV,0);
	$zoom_row->AddSpacer(14);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Min:',
		wxDefaultPosition,[30,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zmin},0,$CV,0);
	$zoom_row->AddSpacer(14);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Max:',
		wxDefaultPosition,[32,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zmax},0,$CV,0);

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
	$sizer->AddSpacer(8);
	$sizer->Add($this->{props},1,wxEXPAND|wxALL,4);
	$right->SetSizer($sizer);

	$this->SplitVertically($this->{tree},$right,320);
	$this->SetMinimumPaneSize(160);

	EVT_TREE_SEL_CHANGED($this,$this->{tree},\&onSelect);
	EVT_LEFT_DOWN($this->{tree},sub { $this->onTreeLeftDown($_[1]) });
	EVT_RIGHT_DOWN($this->{tree},sub { $this->onTreeRightDown($_[1]) });
	EVT_MENU($this,$_,\&onTreeMenu) for ($MENU_NEW_SET, $MENU_USE_SET,
		$MENU_NEW_REGION, $MENU_NEW_SUB, $MENU_DELETE, $MENU_EXPLORE,
		$MENU_RESCAN);
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

	$this->populate();
	return $this;
}


sub closeOK
	# Pub::WX::Window's close hook.  The timer MUST be stopped here: it
	# fires into populate(), and populate() touches a tree that is about
	# to be destroyed.
{
	my ($this) = @_;
	$this->{timer}->Stop() if $this->{timer};
	return 1;
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

	$this->_addNode($item,$root_id,$_,0) for @{$reg->{subregions}};
	$this->{tree}->Expand($item) if @{$reg->{subregions}};
	return $item;
}


sub populate
	# THE OUTER LEVEL IS THE REGION SET, and it is a real level rather than
	# the fake 'regions' root it replaces -- every node in this tree now
	# names something that exists on disk.  It is also where the active set
	# is chosen, by the same state-icon click winSources uses for a source,
	# so the two panes select a thing the same way.
	#
	# ONLY THE ACTIVE SET HAS CHILDREN.  dm_region loads one set at a time
	# by design, so the others are shown as what they are -- folders that
	# exist and could be made active -- rather than opened.  A set you are
	# not working in has nothing to say.
{
	my ($this) = @_;
	my $tree = $this->{tree};

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
			if !$have || ($have->{kind} || '') eq 'set' ||
				lc($have->{root_id} // '') ne lc($sel_region) ||
				lc($have->{id} // '') ne lc($want->{id});
	}

	$tree->DeleteAllItems();
	my $root   = $tree->AddRoot('sets');
	my $active = getActiveSet();
	my @names  = getSetNames();

	for my $name (@names)
	{
		my $item = $tree->AppendItem($root,
			_setLabel($name,$name eq $active));
		$tree->SetItemData($item,Wx::TreeItemData->new({
			kind	=> 'set',
			set		=> $name,
		}));
		$tree->SetItemState($item,$name eq $active ? 1 : 0);

		my $was = $this->{_restore};
		$this->{_restore_item} = $item
			if $was && ($was->{kind} || '') eq 'set' && $was->{set} eq $name;

		next if $name ne $active;
		$this->_addNode($item,$_,getRegion($_),1) for getRegionIds();
		$tree->Expand($item);
	}

	$tree->SelectItem($this->{_restore_item})
		if $this->{_restore_item} && $this->{_restore_item}->IsOk();
	$this->{_restore} = undef;

	$this->{seen_seq} = getStateSeq();
	display($dbg_win,0,"winRegions::populate() ".scalar(@names)." set(s), ".
		scalar(my @n = getRegionIds())." region(s) at state ".$this->{seen_seq});
	$this->showProperties();
}


sub onTimer
{
	my ($this,$event) = @_;
	return if getStateSeq() == $this->{seen_seq};

	# Never rebuild out from under an edit in progress.  A rebuild
	# reloads the controls from the model, which would throw away
	# whatever was half typed.  The change is picked up on the next tick
	# after Save.

	return if $this->{ctl_save}->IsEnabled();

	display($dbg_win,0,"winRegions: state changed to ".getStateSeq()." - rebuilding");
	$this->populate();
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

		# On a set, the icon is a radio: it makes that set the active one.
		# The whole tree is rebuilt afterwards, because changing the set
		# changes which regions exist.

		if ($node && ($node->{kind} || '') eq 'set')
		{
			return if $node->{set} eq getActiveSet();

			# CHANGING THE SET RELOADS THE WHOLE MODEL from another folder,
			# so an edit in flight would be aimed at an object that may not
			# exist afterwards.

			return if $this->_refuseIfLocked(
				"make '$node->{set}' active");

			display($dbg_win,0,"winRegions: active set '$node->{set}'");
			setActiveSet($node->{set});
			bumpState("active set is '$node->{set}'");
			$this->populate();
			return;
		}

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


sub onTreeRightDown
	# THE TREE IS WHERE THINGS COME INTO AND GO OUT OF EXISTENCE, and this
	# is that menu.  It deliberately does not draw: 'New region' creates the
	# object and leaves the map to offer its Draw banner, because a mode
	# must never be armed in a window the user is not looking at.
	#
	# See docs/design/editing_wx.md.
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
	my $kind = $node ? ($node->{kind} || 'region') : '';

	if (!$node)
	{
		$menu->Append($MENU_NEW_SET,'New region set...');
		$menu->AppendSeparator();
		$menu->Append($MENU_RESCAN,'Rescan');
	}
	elsif ($kind eq 'set')
	{
		$menu->Append($MENU_USE_SET,"Make '$node->{set}' active")
			if $node->{set} ne getActiveSet();
		$menu->Append($MENU_NEW_REGION,'New region...')
			if $node->{set} eq getActiveSet();
		$menu->AppendSeparator();
		$menu->Append($MENU_EXPLORE,'Open folder in Explorer');
		$menu->Append($MENU_RESCAN,'Rescan');
	}
	else
	{
		my $what = $node->{is_root} ? "region '$node->{root_id}'" :
			"subregion '$node->{id}'";
		$menu->Append($MENU_NEW_SUB,'New subregion...');
		$menu->AppendSeparator();
		$menu->Append($MENU_DELETE,"Delete $what...");
	}

	$this->{_menu_node} = $node;
	$this->PopupMenu($menu,$event->GetPosition());
}


sub onTreeMenu
{
	my ($this,$event) = @_;
	my $id   = $event->GetId();
	my $node = $this->{_menu_node};

	if ($id == $MENU_RESCAN)
	{
		rescanSets();
		rescanRegions();
		bumpState('rescanned');
		$this->populate();
		return;
	}
	if ($id == $MENU_EXPLORE)
	{
		my $dir = setDir($node->{set});
		$dir =~ s|/|\\|g;
		system(1,"explorer.exe \"$dir\"") if is_win();
		return;
	}
	if ($id == $MENU_USE_SET)
	{
		return if $this->_refuseIfLocked("make '$node->{set}' active");
		setActiveSet($node->{set});
		bumpState("active set is '$node->{set}'");
		$this->populate();
		return;
	}
	if ($id == $MENU_NEW_SET)
	{
		my $name = Wx::GetTextFromUser(
			"A set is a FOLDER of region files.\n".
			"Letters and digits only - it becomes the name of the folder\n".
			"copied to the card.",
			'New region set','',$this);
		return if !defined($name) || $name !~ /\S/;
		return if !newSet($name);
		bumpState("set '$name' created");
		$this->populate();
		return;
	}
	if ($id == $MENU_NEW_REGION)
	{
		return if $this->_refuseIfLocked('create a region');
		my $name = Wx::GetTextFromUser(
			"The region is created with NO geometry.\n".
			"Draw its outline on the map afterwards.",
			'New region','',$this);
		return if !defined($name) || $name !~ /\S/;

		# The zooms come from the regions already here, because every file
		# on one card must agree on zauthor and zmin.  Offering what already
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
	$this->showProperties();

	my $node = $this->selectedIds();
	if (!$node || ($node->{kind} || '') eq 'set')
	{
		setSelection('','');
	}
	else
	{
		setSelection($node->{root_id},
			$node->{is_root} ? '' : $node->{id});
	}
	$this->{seen_seq} = getStateSeq();
}


sub _selectedRegion
	# The region or subregion the tree is on, and its owning region.
{
	my ($this) = @_;
	my $node = $this->selectedIds();
	return (undef,undef,undef) if !$node;

	# A set node names a folder, not a region.  Every caller already
	# handles "nothing selected", so a set selects as nothing rather than
	# as a region with no fields, which is what would crash the panel.

	return (undef,undef,$node) if ($node->{kind} || '') eq 'set';

	my $root = getRegion($node->{root_id});
	return (undef,undef,$node) if !$root;
	return ($root,$root,$node) if $node->{is_root};
	my ($found) = findSubregion($root,$node->{id});
	return ($found,$root,$node);
}


sub _isDirty
{
	my ($this) = @_;
	my ($reg,undef,$node) = $this->_selectedRegion();
	return 0 if !$reg;
	return 1 if $this->{ctl_name}->GetValue() ne $reg->{name};
	return 1 if $this->{ctl_id}->GetValue() ne $reg->{id};
	return 1 if $this->{ctl_zmax}->GetValue() != $reg->{zmax};

	# A subregion has no authored level and no floor, so there is nothing
	# on those two controls that could be dirty.

	return 0 if $node && !$node->{is_root};
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
	# disagree about zauthor cannot be built onto one card - and a
	# disagreement has to be visible at a glance rather than found by
	# clicking five regions and remembering what each one said.  The tree
	# is the only surface that can show it; see docs/design/editing_wx.md.
{
	my ($reg,$is_root) = @_;

	my $empty = scalar(@{$reg->{geometry} || []}) ? '' : '  (no geometry)';

	return sprintf("%-14s      to z%-2d%s",$reg->{name},$reg->{zmax},$empty)
		if !$is_root;
	return sprintf("%-14s  %2d-%-2d \@%-2d%s",$reg->{name},
		$reg->{zmin},$reg->{zmax},$reg->{zauthor},$empty);
}


sub _setLabel
	# What a set row says, and it answers the card question outright rather
	# than leaving it to be inferred from the column below.
{
	my ($name,$active) = @_;
	my $dir = setDir($name);

	if (!$active)
	{
		my @files = glob("$dir/*.region");
		return sprintf("%-14s  %d region file(s)",$name,scalar(@files));
	}

	my @ids = getRegionIds();
	return sprintf("%-14s  empty",$name) if !@ids;

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
		$mixed = sprintf("  MIXED %s - %s",$what,
			join(', ',map { "$h->{$_} at z$_" } sort { $a <=> $b } keys %$h));
		last;
	}
	return sprintf("%-14s  %d region%s  %s",$name,$n,($n == 1 ? '' : 's'),
		$mixed ? $mixed :
			sprintf("z%d \@%d  all agree",(keys %zn)[0],(keys %za)[0]));
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

	my $is_root = $node && $node->{is_root};
	my $name    = $this->{ctl_name}->GetValue();
	my $new_id  = $this->{ctl_id}->GetValue();
	my $zmax    = $this->{ctl_zmax}->GetValue();

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
			return if !saveRegion($root);
		}
	}
	elsif (!saveRegion($root))
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
	# and take the selection with it.

	$this->{seen_seq} = getStateSeq();
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
	$this->{ctl_zmax}->Enable($on ? 1 : 0);

	# A subregion has zmax alone -- no authored level, no floor.  The
	# controls are disabled rather than hidden so the shape of the model
	# is visible from the pane.

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
	# What a region set is, said plainly, because the folder IS the answer
	# to "what is on the card" and the user should be able to read it here
	# rather than infer it.
	#
	# The active set is described from the loaded model; any other set is
	# described from its FOLDER, because its regions are not loaded and
	# counting the files is both cheap and exactly the right question.
{
	my ($this,$name) = @_;
	my $dir    = setDir($name);
	my $active = $name eq getActiveSet();

	my $text = '';
	$text .= sprintf("%-16s %s\n",'region set',$name);
	$text .= sprintf("%-16s %s\n",'folder',$dir);
	$text .= sprintf("%-16s %s\n",'active',$active ? 'yes' : 'no');

	if ($active)
	{
		my @ids = getRegionIds();
		my @on  = getWorkingSet();
		$text .= sprintf("%-16s %d\n",'regions',scalar(@ids));
		$text .= sprintf("%-16s %d of %d\n",'shown',scalar(@on),scalar(@ids));
		$text .= "\n";
		$text .= sprintf("    %s %-16s z%d-%d \@%d\n",
			isChecked($_) ? '[x]' : '[ ]',$_,
			getRegion($_)->{zmin},getRegion($_)->{zmax},
			getRegion($_)->{zauthor}) for @ids;
	}
	else
	{
		my @files = glob("$dir/*.region");
		$text .= sprintf("%-16s %d\n",'region files',scalar(@files));
		$text .= "\n    click the icon to make this the active set\n";
	}

	$text .= "\nEVERY region in a set is on the card it builds.  The files\n".
		"present in the folder ARE the set - there is no manifest, and\n".
		"hiding a region here does not take it off the card.\n";
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
		$this->_enableControls(0,0);
		$this->{loading} = 0;

		my $kind = $node ? ($node->{kind} || 'region') : '';
		if ($kind eq 'set')
		{
			$this->{props}->SetValue($this->_setProperties($node->{set}));
		}
		else
		{
			$this->{props}->SetValue($node ?
				"region '$node->{root_id}' is gone\n" : "nothing selected\n");
		}
		return;
	}

	# A subregion has no zauthor or zmin of its own.  The controls show
	# the PARENT'S, disabled -- blank fields would read as "zero" and a
	# stale value from the last selection would read as this node's.

	$this->{loading} = 1;
	$this->{ctl_name}->SetValue($reg->{name});
	$this->{ctl_id}->SetValue($reg->{id});
	$this->{ctl_zmax}->SetValue($reg->{zmax});
	$this->{ctl_zauthor}->SetValue($root->{zauthor});
	$this->{ctl_zmin}->SetValue($root->{zmin});
	$this->{ctl_show}->SetValue(isChecked($node->{root_id}) ? 1 : 0);

	# GREYED OUT WHILE THE MAP HOLDS IT.  Not merely advisory: an edit
	# committed from here would race the map's own commit.

	my $held = $this->_mapHolds($node);
	$this->_enableControls($held ? 0 : 1,$node->{is_root});
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
		$text .= sprintf("%-16s %s.rct\n",'card file',$reg->{id});
	}
	else
	{
		# The band starts at the IMMEDIATE parent's zmax + 1, which is not
		# the root's once subregions nest.

		my (undef,$parent) = findSubregion($root,$reg->{id});
		$parent ||= $root;
		$text .= sprintf("%-16s %d  (its band is z%d-%d)\n",'zmax',
			$reg->{zmax},$parent->{zmax}+1,$reg->{zmax});
	}
	$text .= sprintf("%-16s %s  (it is on the card either way)\n",'shown on map',
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
