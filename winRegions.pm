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
use Wx::Event qw( EVT_TREE_SEL_CHANGED EVT_LEFT_DOWN EVT_TIMER
				  EVT_TEXT EVT_TEXT_ENTER EVT_SPINCTRL EVT_CHECKBOX
				  EVT_BUTTON );
use Pub::Utils;
use Pub::WX::Window;
use cm_defs;
use cm_state;
use dm_region;
use base qw(Wx::SplitterWindow Pub::WX::Window);


our $dbg_win:shared = 1;
	# 1 = quiet
	# 0 = rebuilds and checkbox clicks


my $TIMER_MS = 500;


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
	my $LBL = 90;

	$this->{ctl_name} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,[220,-1],wxTE_PROCESS_ENTER);
	$this->{ctl_zoom} = Wx::SpinCtrl->new($right,-1,'',
		wxDefaultPosition,[70,-1],wxSP_ARROW_KEYS,0,24,15);
	$this->{ctl_show} = Wx::CheckBox->new($right,-1,'show on the map');
	$this->{ctl_save} = Wx::Button->new($right,-1,'Save',
		wxDefaultPosition,[$LBL,-1]);
	$this->{ctl_save}->Enable(0);

	# Save sits in the label column, where 'Name' would otherwise be: a
	# text field holding a name needs no label to say so, and this lines
	# the button up with the zoom label below it.

	my $name_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$name_row->Add($this->{ctl_save},0,$CV,0);
	$name_row->Add($this->{ctl_name},0,$CV,0);

	my $zoom_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$zoom_row->Add(Wx::StaticText->new($right,-1,'Canonical zoom',
		wxDefaultPosition,[$LBL,-1]),0,$CV,0);
	$zoom_row->Add($this->{ctl_zoom},0,$CV,0);
	$zoom_row->AddSpacer(20);
	$zoom_row->Add($this->{ctl_show},0,$CV,0);

	$this->{props} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{props}->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(8);
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
	# Name and zoom are STAGED and committed by Save.  Applying them as
	# they were typed meant saving the file on every spinner tick, and
	# each save rebuilt the tree, which destroyed the very item being
	# edited.  'show on the map' stays immediate - it is not an edit to
	# the region, it is what you are looking at.

	EVT_TEXT($this,$this->{ctl_name},\&onEdited);
	EVT_TEXT_ENTER($this,$this->{ctl_name},\&onSave);
	EVT_SPINCTRL($this,$this->{ctl_zoom},\&onEdited);
	EVT_BUTTON($this,$this->{ctl_save},\&onSave);
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

	my $label = sprintf("%s   z%d",$reg->{name},$reg->{canonical_zoom});
	my $item  = $this->{tree}->AppendItem($parent_item,$label);

	$this->{tree}->SetItemData($item,Wx::TreeItemData->new({
		root_id	=> $root_id,
		id		=> $reg->{id},
		is_root	=> $is_root ? 1 : 0,
	}));

	# Remember the item that matches what was selected before a rebuild.
	# Matching on BOTH ids is what makes this work for a subregion --
	# matching only the region would silently drop the selection every
	# time the tree was rebuilt with a subregion selected.

	my $was = $this->{_restore};
	$this->{_restore_item} = $item
		if $was && $was->{root_id} eq $root_id && $was->{id} eq $reg->{id};

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
{
	my ($this) = @_;
	my $tree = $this->{tree};

	# Remember what was selected so a rebuild does not move the user.
	$this->{_restore}      = $this->selectedIds();
	$this->{_restore_item} = undef;

	$tree->DeleteAllItems();
	my $root = $tree->AddRoot('regions');

	$this->_addNode($root,$_,getRegion($_),1) for getRegionIds();

	$tree->SelectItem($this->{_restore_item})
		if $this->{_restore_item} && $this->{_restore_item}->IsOk();
	$this->{_restore} = undef;

	$this->{seen_seq} = getStateSeq();
	display($dbg_win,0,"winRegions::populate() ".
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


sub onSelect
{
	my ($this,$event) = @_;
	$this->showProperties();
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


sub _isDirty
{
	my ($this) = @_;
	my ($reg) = $this->_selectedRegion();
	return 0 if !$reg;
	return 1 if $this->{ctl_name}->GetValue() ne $reg->{name};
	return 1 if $this->{ctl_zoom}->GetValue() != $reg->{canonical_zoom};
	return 0;
}


sub onEdited
	# Nothing is written here.  The controls hold a staged edit and Save
	# lights up; that is the whole of it.
{
	my ($this,$event) = @_;
	return if $this->{loading};
	$this->{ctl_save}->Enable($this->_isDirty() ? 1 : 0);
}


sub _relabelSelected
	# Update the one tree label in place.  Rebuilding the tree here is
	# what destroyed the selection and the focus, and there is no reason
	# for it: one item changed.
{
	my ($this,$reg) = @_;
	my $item = $this->{tree}->GetSelection();
	return if !$item || !$item->IsOk();
	$this->{tree}->SetItemText($item,
		sprintf("%s   z%d",$reg->{name},$reg->{canonical_zoom}));
}


sub onSave
{
	my ($this,$event) = @_;
	return if $this->{loading};
	my ($reg,$root,$node) = $this->_selectedRegion();
	return if !$reg;

	my $name = $this->{ctl_name}->GetValue();
	my $zoom = $this->{ctl_zoom}->GetValue();

	if ($name !~ /\S/)
	{
		warning(0,0,"winRegions: a name may not be empty");
		$this->{loading} = 1;
		$this->{ctl_name}->SetValue($reg->{name});
		$this->{loading} = 0;
		$this->{ctl_save}->Enable($this->_isDirty() ? 1 : 0);
		return;
	}

	# The NAME changes; the id never does.  The id is what the file is
	# called and what sets refer to.

	my $why = "'$reg->{id}'";
	$why .= " renamed to '$name'"		if $name ne $reg->{name};
	$why .= " zoom $zoom"				if $zoom != $reg->{canonical_zoom};
	$reg->{name}			= $name;
	$reg->{canonical_zoom}	= $zoom;

	return if !saveRegion($root);
	display($dbg_win,0,"winRegions: saved $why");

	# Tell the map, then move this pane's own idea of the version
	# forward, so the next timer tick does not rebuild the tree over a
	# change made here and take the selection with it.

	bumpState($why);
	$this->{seen_seq} = getStateSeq();

	$this->_relabelSelected($reg);
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


sub _enableControls
{
	my ($this,$on,$is_root) = @_;
	$this->{ctl_name}->Enable($on ? 1 : 0);
	$this->{ctl_zoom}->Enable($on ? 1 : 0);

	# Only a whole region can be shown or hidden.  A subregion travels
	# with its parent.

	$this->{ctl_show}->Enable(($on && $is_root) ? 1 : 0);

	# Save is enabled by an edit, never by a selection.
	$this->{ctl_save}->Enable(0);
}


sub showProperties
{
	my ($this) = @_;
	my ($reg,$root,$node) = $this->_selectedRegion();

	if (!$reg)
	{
		$this->{loading} = 1;
		$this->{ctl_name}->SetValue('');
		$this->{ctl_show}->SetValue(0);
		$this->_enableControls(0,0);
		$this->{loading} = 0;
		$this->{props}->SetValue($node ?
			"region '$node->{root_id}' is gone\n" : "no region selected\n");
		return;
	}

	$this->{loading} = 1;
	$this->{ctl_name}->SetValue($reg->{name});
	$this->{ctl_zoom}->SetValue($reg->{canonical_zoom});
	$this->{ctl_show}->SetValue(isChecked($node->{root_id}) ? 1 : 0);
	$this->_enableControls(1,$node->{is_root});
	$this->{loading} = 0;

	my $text = '';
	$text .= sprintf("%-16s %s\n",'name',$reg->{name});
	$text .= sprintf("%-16s %s\n",'id',$reg->{id});
	$text .= sprintf("%-16s %s\n",'kind',
		$node->{is_root} ? 'region' : "subregion of $node->{root_id}");
	$text .= sprintf("%-16s %s\n",'file',$root->{file});
	$text .= sprintf("%-16s %d\n",'canonical_zoom',$reg->{canonical_zoom});
	$text .= sprintf("%-16s %d  (the fill level)\n",'fill zoom',
		$reg->{canonical_zoom} + 1);
	$text .= sprintf("%-16s %s\n",'checked',
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
			$text .= sprintf("    %-16s z%-2d  %d polygon(s)",
				$sub->{id},$sub->{canonical_zoom},scalar(@{$sub->{geometry}}));
			$text .= sprintf("   lon %.6f..%.6f  lat %.6f..%.6f",@$sb) if $sb;
			$text .= "\n";
		}
	}

	$this->{props}->SetValue($text);
}


1;
