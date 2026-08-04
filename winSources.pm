#!/usr/bin/perl
#---------------------------------------------
# winSources.pm
#---------------------------------------------
# The tile sources: what is installed, which one the map is showing, and
# what each one actually says.
#
# SOURCES ARE A RADIO, REGIONS ARE CHECKBOXES.  Two imagery layers at
# once means one hides the other, so exactly one source is displayed and
# choosing another replaces it.  Leaflet's own layer control draws the
# same distinction between base layers and overlays, for the same reason.
#
# The fields are READ ONLY.  chartMaker is a reader of TSD files; a user
# who wants to change one edits the file, and the application notices.
# Authoring a source in the application is a later feature and a much
# larger one than a text field.
#
# Unlike the browser, this pane may show a source's url -- this is the
# process that holds it. What must never learn the url is the page.

package winSources;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw( EVT_TREE_SEL_CHANGED EVT_LEFT_DOWN EVT_RIGHT_DOWN
				  EVT_TIMER EVT_BUTTON EVT_MENU );
use Pub::Utils;
use Pub::WX::Window;
use cm_defs;
use cm_state;
use dm_source;
use dm_cache;
use dm_probe;
use w_source;
use w_catalog;
use base qw(Wx::SplitterWindow Pub::WX::Window);


our $dbg_win:shared = 1;
	# 1 = quiet
	# 0 = selection changes


my $TIMER_MS = 500;

my $MENU_NEW	= 10521;
my $MENU_EDIT	= 10522;
my $MENU_DELETE	= 10523;
my $MENU_CATALOG = 10524;

my $RED = Wx::Colour->new(200,0,0);


sub _makeRadioBitmap
	# A dot rather than a tick, because only one can be on.
{
	my ($on) = @_;
	my $bmp = Wx::Bitmap->new(13,13);
	my $dc  = Wx::MemoryDC->new();
	$dc->SelectObject($bmp);
	$dc->SetBackground(Wx::Brush->new(Wx::Colour->new(255,255,255),wxSOLID));
	$dc->Clear();
	$dc->SetPen(Wx::Pen->new(Wx::Colour->new(100,100,100),1,wxSOLID));
	$dc->SetBrush(Wx::Brush->new(Wx::Colour->new(255,255,255),wxSOLID));
	$dc->DrawEllipse(1,1,11,11);
	if ($on)
	{
		$dc->SetPen(Wx::Pen->new(Wx::Colour->new(0,0,180),1,wxSOLID));
		$dc->SetBrush(Wx::Brush->new(Wx::Colour->new(0,0,180),wxSOLID));
		$dc->DrawEllipse(4,4,5,5);
	}
	$dc->SelectObject(wxNullBitmap);
	return $bmp;
}


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	$this->MyWindow($frame,$book,$id,'Sources',$data);

	$this->{tree} = Wx::TreeCtrl->new($this,-1,wxDefaultPosition,wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT);

	my $imgs = Wx::ImageList->new(13,13);
	$imgs->Add(_makeRadioBitmap(0));
	$imgs->Add(_makeRadioBitmap(1));
	$this->{tree}->SetStateImageList($imgs);
	$this->{_imgs} = $imgs;

	my $right = Wx::Panel->new($this,-1);
	$right->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));

	my $CV  = wxALIGN_CENTER_VERTICAL;
	my $LBL = 90;

	$this->{ctl_use} = Wx::Button->new($right,-1,'Show',
		wxDefaultPosition,[$LBL,-1]);
	$this->{ctl_use}->Enable(0);
	$this->{ctl_rescan} = Wx::Button->new($right,-1,'Rescan',
		wxDefaultPosition,[$LBL,-1]);

	# ASK THE SERVICE WHAT IT IS.  One request and no imagery, so it is a
	# button rather than anything that needs confirming -- but it does go
	# to the network, which is why it says so and why it is not run on
	# selection.

	$this->{ctl_probe} = Wx::Button->new($right,-1,'Probe',
		wxDefaultPosition,[$LBL,-1]);
	$this->{ctl_probe}->SetToolTip(
		'Ask the service what it says about itself - one request, no imagery');
	$this->{ctl_probe}->Enable(0);

	$this->{ctl_edit} = Wx::Button->new($right,-1,'Edit',
		wxDefaultPosition,[$LBL,-1]);
	$this->{ctl_edit}->SetToolTip(
		'Edit this source definition - also on the right-click menu');
	$this->{ctl_edit}->Enable(0);

	# THE CATALOG IS ALWAYS AVAILABLE, unlike everything else on this row.
	# The other four act on a selection and a first run has none - which is
	# exactly the moment somebody most needs a list of what exists.

	$this->{ctl_catalog} = Wx::Button->new($right,-1,'Catalog',
		wxDefaultPosition,[$LBL,-1]);
	$this->{ctl_catalog}->SetToolTip(
		'The tile services chartMaker knows about - create sources from them');

	# WHAT THE SELECTION IS, ON ITS OWN LINE UNDER THE BUTTONS.  It sat at
	# the end of the button row, where it had whatever width was left over
	# and ran off the right edge: 'this is the source the map is' with the
	# word that carried the meaning cut off.  A line of prose in a row of
	# fixed-width controls is always the thing that gets clipped, and the
	# longest thing it says - what the probe put there - was the worst hit.

	$this->{ctl_what} = Wx::StaticText->new($right,-1,'');

	# WHY A FILE IS NOT A SOURCE, IN RED, AND UP HERE.  The properties
	# control below is a plain wxTextCtrl and cannot colour a line, so a
	# refusal put there would read as one more property among twenty.  This
	# is the one thing on the pane that has to be impossible to miss.

	$this->{ctl_why} = Wx::StaticText->new($right,-1,'');
	$this->{ctl_why}->SetForegroundColour(Wx::Colour->new(200,0,0));

	my $row = Wx::BoxSizer->new(wxHORIZONTAL);
	$row->Add($this->{ctl_use},0,$CV,0);
	$row->AddSpacer(10);
	$row->Add($this->{ctl_rescan},0,$CV,0);
	$row->AddSpacer(10);
	$row->Add($this->{ctl_probe},0,$CV,0);
	$row->AddSpacer(10);
	$row->Add($this->{ctl_edit},0,$CV,0);
	$row->AddSpacer(10);
	$row->Add($this->{ctl_catalog},0,$CV,0);

	$this->{props} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{props}->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(8);
	$sizer->Add($row,0,wxLEFT|wxRIGHT,8);
	$sizer->AddSpacer(6);
	$sizer->Add($this->{ctl_what},0,wxEXPAND|wxLEFT|wxRIGHT,8);
	$sizer->Add($this->{ctl_why},0,wxEXPAND|wxLEFT|wxRIGHT,8);
	$sizer->AddSpacer(6);
	$sizer->Add($this->{props},1,wxEXPAND|wxALL,4);
	$right->SetSizer($sizer);

	$this->SplitVertically($this->{tree},$right,320);
	$this->SetMinimumPaneSize(160);

	EVT_TREE_SEL_CHANGED($this,$this->{tree},\&onSelect);
	EVT_LEFT_DOWN($this->{tree},sub { $this->onTreeLeftDown($_[1]) });
	EVT_RIGHT_DOWN($this->{tree},sub { $this->onTreeRightDown($_[1]) });
	EVT_MENU($this,$_,\&onTreeMenu)
		for ($MENU_NEW, $MENU_CATALOG, $MENU_EDIT, $MENU_DELETE);
	EVT_BUTTON($this,$this->{ctl_use},\&onUse);
	EVT_BUTTON($this,$this->{ctl_rescan},\&onRescan);
	EVT_BUTTON($this,$this->{ctl_probe},\&onProbe);
	EVT_BUTTON($this,$this->{ctl_edit},sub { $this->editSelected() });
	EVT_BUTTON($this,$this->{ctl_catalog},sub { $this->catalogDialog() });

	$this->{seen_seq} = -1;
	$this->{timer} = Wx::Timer->new($this,-1);
	EVT_TIMER($this,-1,\&onTimer);
	$this->{timer}->Start($TIMER_MS);

	$this->{built} = 1;
	$this->populate();
	return $this;
}


sub closeOK
{
	my ($this) = @_;
	$this->{timer}->Stop() if $this->{timer};
	return 1;
}


#---------------------------------------------
# the list
#---------------------------------------------

sub _activeId
	# The source the map is showing.  dm_source both holds the choice and
	# resolves it against what the folder holds, so there is nothing left
	# to decide here and no second fallback order that could disagree with
	# what /state says.
{
	return getDefaultSource();
}


sub populate
{
	my ($this) = @_;

	# NOT RE-ENTRANT - see winRegions::populate().  Filling the tree
	# raises focus events, and the frame turns those into activations that
	# ask for another rebuild.

	return if $this->{populating};
	$this->{populating} = 1;

	my $tree = $this->{tree};
	my $was  = $this->selectedLeaf();

	# FROZEN FOR THE WHOLE REBUILD, exactly as winRegions::populate is and
	# for the same reason: nothing is drawn until the item list is
	# finished, so the control lays itself out once from a structure that
	# has stopped changing.
	#
	# THE CASE IT LOSES IS A REBUILD UNDER AN OVERLAPPING WINDOW.  onTimer
	# repopulates whenever the state counter has moved, and the counter is
	# bumped from everywhere - a region selection, the map, the browser
	# polling - so a rebuild can land at any moment, including while a
	# modal dialog is sitting over this pane.  An unfrozen tree repainting
	# in pieces underneath one leaves rows on screen that no longer exist,
	# which is what a 'ghost' source is.
	#
	# That was always possible and was rare.  Creating sources from the
	# catalog now bumps the state deliberately, so the rebuild-under-a-
	# modal path is no longer occasional but certain, and these two changes
	# belong together.

	$tree->Freeze();

	$tree->DeleteAllItems();
	my $root   = $tree->AddRoot('sources');
	my $active = _activeId();
	my $sel;

	# THE LIST IS OF FILES, NOT OF SOURCES, and that is the whole reason a
	# broken TSD can be repaired at all.  A file that fails to load is
	# exactly the file somebody has to open, and while this listed only what
	# loaded, it was the one file the application could not show them.

	my %byleaf;
	for my $id (getSourceIds())
	{
		my $src = getSource($id);
		$byleaf{$src->{file}} = $src;
	}
	my $refused = getRefused();

	for my $leaf (getSourceFiles())
	{
		my $src = $byleaf{$leaf};
		my $item = $tree->AppendItem($root,$src ?
			sprintf("%s   z%d-%d",$src->{name},
				$src->{zoom}{min},$src->{zoom}{max}) :
			"$leaf   - REFUSED");

		$tree->SetItemData($item,Wx::TreeItemData->new({
			leaf => $leaf,
			id   => $src ? $src->{id} : undef,
			why  => $src ? undef : ($refused->{$leaf} // 'not loaded') }));

		# RED IN THE LIST, AND THE REASON IN THE PANEL.  A colour says which
		# file, and it is the only signal a tree item can carry; the sentence
		# that says what is wrong needs somewhere it can be read.

		$tree->SetItemTextColour($item,$RED) if !$src;
		$tree->SetItemState($item,
			($src && $active && $src->{id} eq $active) ? 1 : 0);

		$sel = $item if $was ? ($was eq $leaf) :
			($src && $active && $src->{id} eq $active);
	}

	# With nothing previously selected, land on the source the map is
	# showing.  An empty properties panel on open is a wasted pane.

	$tree->SelectItem($sel) if $sel && $sel->IsOk();

	$tree->Thaw();

	$this->{seen_seq} = getStateSeq();
	$this->showProperties();
	$this->{populating} = 0;
}


sub onTimer
{
	my ($this,$event) = @_;

	# NOT UNTIL THE PANE EXISTS.  MyWindow() puts the page into the
	# notebook, which makes it the current one, which the frame turns
	# into an activation -- and all of that happens BEFORE the widgets
	# below it are created.  The activation arrives at a $this whose tree
	# is still undef, and populate() dies on it.
	#
	# It stayed hidden because the guard below used to catch it by
	# accident: seen_seq was undef, undef == 0 is true, and the state
	# counter is 0 only until the first selection.  So it fired on
	# reopening a pane and never on a fresh start.

	return if !$this->{built};
	return if getStateSeq() == $this->{seen_seq};

	# A PANE THAT IS NOT ON TOP DOES NOT TOUCH ITS WIDGETS - see the same
	# rule in winRegions::onTimer.  This pane is where it showed: every
	# selection anywhere bumps the state counter, the counter brought this
	# tree to life behind the user's back, and filling it took the
	# notebook with it.  Which pane is in front is the user's decision.

	return if !$this->IsShown();
	$this->populate();
}


sub onActivate
	# Pub::WX::Frame calls this as the pane becomes the current one, which
	# is where a pane that sat out a change catches up - see the note in
	# winRegions::onActivate about why this and not pending_populate.
{
	my ($this) = @_;
	$this->onTimer();
}


sub selectedNode
	# { leaf, id, why }.  id is undef for a file that did not load, which
	# is the case every caller here has to think about.
{
	my ($this) = @_;
	my $item = $this->{tree}->GetSelection();
	return undef if !$item || !$item->IsOk();
	my $d = $this->{tree}->GetItemData($item);
	return $d ? $d->GetData() : undef;
}


sub selectedId
{
	my ($this) = @_;
	my $n = $this->selectedNode();
	return $n ? $n->{id} : undef;
}


sub selectedLeaf
{
	my ($this) = @_;
	my $n = $this->selectedNode();
	return $n ? $n->{leaf} : undef;
}


#---------------------------------------------
# events
#---------------------------------------------

sub _use
{
	my ($this,$id) = @_;
	return if !$id || !getSource($id);
	return if _activeId() && $id eq _activeId();
	display($dbg_win,0,"winSources: showing '$id'");
	setDefaultSource($id);
	$this->{seen_seq} = getStateSeq();
	$this->populate();
}


sub onTreeLeftDown
{
	my ($this,$event) = @_;
	my ($item,$flags) = $this->{tree}->HitTest($event->GetPosition());
	if ($item && $item->IsOk() && ($flags & wxTREE_HITTEST_ONITEMSTATEICON))
	{
		my $d = $this->{tree}->GetItemData($item);
		$this->_use($d->GetData()->{id}) if $d;
		return;
	}
	$event->Skip();
}


sub onUse
{
	my ($this,$event) = @_;
	$this->_use($this->selectedId());
}


sub onRescan
{
	my ($this,$event) = @_;
	delete $this->{probed};
	my $found = rescanSources();
	display(0,0,"winSources: rescan found $found source".($found == 1 ? '' : 's'));
	bumpState("sources rescanned");
	$this->{seen_seq} = getStateSeq();
	$this->populate();
}


sub onTreeRightDown
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
	$menu->Append($MENU_NEW,'New source...');
	$menu->Append($MENU_CATALOG,'Tile source catalog...');
	if ($node)
	{
		$menu->AppendSeparator();
		$menu->Append($MENU_EDIT,"Edit '$node->{leaf}'...");
		$menu->Append($MENU_DELETE,"Delete '$node->{leaf}'...");
	}
	$this->PopupMenu($menu,$event->GetPosition());
}


sub onTreeMenu
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	return $this->newSource()    if $id == $MENU_NEW;
	return $this->catalogDialog() if $id == $MENU_CATALOG;
	return $this->editSelected() if $id == $MENU_EDIT;
	return $this->deleteSelected() if $id == $MENU_DELETE;
}


sub _afterWrite
	# One rescan, one state bump, one repopulate.  Everything that changes
	# the folder goes through here so no caller has to remember the order.
{
	my ($this,$leaf) = @_;
	rescanSources();
	bumpState('sources edited');
	$this->{seen_seq} = getStateSeq();
	delete $this->{probed};
	$this->populate();

	# LAND ON WHAT WAS JUST WRITTEN.  A save that dropped the selection
	# somewhere else would make the next edit start with a hunt.

	if ($leaf)
	{
		my $tree = $this->{tree};
		my ($item,$cookie) = $tree->GetFirstChild($tree->GetRootItem());
		while ($item && $item->IsOk())
		{
			my $d = $tree->GetItemData($item);
			if ($d && $d->GetData()->{leaf} eq $leaf)
			{
				$tree->SelectItem($item);
				last;
			}
			($item,$cookie) = $tree->GetNextChild($tree->GetRootItem(),$cookie);
		}
	}
	$this->showProperties();
}


sub newSource
	# A NEW FILE STARTS EMPTY RATHER THAN AS A COPY.  Copying whatever
	# happened to be selected would put somebody else's attribution and
	# licence into a file the user is about to call their own, and those are
	# the two fields least likely to be re-read.
{
	my ($this) = @_;
	my $dlg = w_source->new($this,'',{
		tsd_version => 1,
		tile_size   => 256,
		crs         => 'EPSG:3857',
		zoom        => { min => 0, max => 18 },
		uses        => ['display'],
	},1);
	my $rslt = $dlg->ShowModal();
	my $leaf = $dlg->savedAs();
	$dlg->Destroy();
	$this->_afterWrite($leaf) if $rslt == wxID_OK;
}


sub editSelected
	# WHAT THE FILE SAYS, NOT WHAT LOADED.  A refused file has no loaded
	# hash at all, and for one that did load the defaults filled in at load
	# are not what its author wrote.
{
	my ($this) = @_;
	my $node = $this->selectedNode() or return;

	my $tsd = readSourceFile($node->{leaf});
	if (!$tsd)
	{
		# BROKEN JSON IS THE ONE THING THIS CANNOT OPEN.  There are no
		# fields to show, so saying so is the whole of the help available.

		Wx::MessageBox("$node->{leaf} is not valid JSON and cannot be ".
			"opened in the editor.\n\nIt has to be repaired, or deleted ".
			"and written again.",'Edit Source',wxOK | wxICON_ERROR,$this);
		return;
	}

	my $dlg = w_source->new($this,$node->{leaf},$tsd,0);
	my $rslt = $dlg->ShowModal();
	my $leaf = $dlg->savedAs();
	$dlg->Destroy();
	$this->_afterWrite($leaf) if $rslt == wxID_OK;
}


sub catalogDialog
	# THE CATALOG, AND WHATEVER IT WROTE.
	#
	# The dialog rescans as it goes, because it shows what is installed and
	# has to be right about that while it is still open.  What is left for
	# here is this pane's own view of the folder, and _afterWrite is asked
	# for it only if something was actually written - a browse that created
	# nothing should not move the selection.
{
	my ($this) = @_;
	my $dlg = w_catalog->new($this);
	$dlg->ShowModal();
	my $made = $dlg->created();
	$dlg->Destroy();

	# LAND ON THE LAST ONE WRITTEN.  With one file that is the file, and
	# with twenty it is the end of the list, which is where somebody
	# looking at what just happened would start.

	$this->_afterWrite($made->[-1]) if @$made;
}


sub deleteSelected
	# THE FILE, AND NEVER THE CACHE.  Tiles are the expensive thing, they
	# are keyed by cache_key rather than by this file, and another file may
	# address them deliberately.  Deleting a definition says nothing about
	# imagery.
{
	my ($this) = @_;
	my $node = $this->selectedNode() or return;

	my $warn = "Delete $node->{leaf}?\n\n".
		"The cached tiles are NOT deleted.\n";
	$warn .= "\nAny region naming '$node->{id}' will stop resolving until ".
		"a source declares that id again.\n" if $node->{id};

	return if Wx::MessageBox($warn,'Delete Source',
		wxYES_NO | wxICON_QUESTION,$this) != wxYES;

	my $err = deleteSourceFile($node->{leaf});
	if ($err)
	{
		Wx::MessageBox($err,'Delete Source',wxOK | wxICON_ERROR,$this);
		return;
	}
	$this->_afterWrite('');
}


sub onSelect
{
	my ($this,$event) = @_;

	# A NEW SELECTION DROPS THE PROBE RESULT.  The findings are about ONE
	# source, and leaving them on screen under a different source's name
	# is the kind of thing somebody acts on before they notice.

	delete $this->{probed};
	$this->showProperties();
}


sub onProbe
	# ON THE MAIN THREAD, ON PURPOSE.  Every other network act in this
	# application is on a worker with a progress dialog, because a fill is
	# thousands of requests over hours.  This is ONE request, and the two
	# measured cases are 0.7s for ArcGIS and 7.8s for the 5.3 MB GIBS
	# capabilities document -- long enough to want the cursor to say so,
	# nowhere near long enough to earn a thread, a cancel button and a
	# progress record.
	#
	# The busy cursor is therefore the whole of the UX here, and it is
	# honest: the window really is unresponsive for those seconds.
{
	my ($this,$event) = @_;
	my $id  = $this->selectedId();
	my $src = $id ? getSource($id) : undef;
	return if !$src;

	$this->{ctl_probe}->Enable(0);
	$this->{ctl_what}->SetLabel('asking the service...');
	$this->{props}->SetValue("asking $src->{name}...\n");
	$this->{props}->Update();

	my $busy = Wx::BusyCursor->new();
	my $found = probeSource($src);
	undef $busy;

	$this->{probed} = $found;
	$this->showProperties();
}


#---------------------------------------------
# properties
#---------------------------------------------

sub showProperties
{
	my ($this) = @_;
	my $node = $this->selectedNode();
	my $id   = $node ? $node->{id} : undef;
	my $src  = $id ? getSource($id) : undef;

	if (!$node)
	{
		$this->{ctl_use}->Enable(0);
		$this->{ctl_probe}->Enable(0);
		$this->{ctl_edit}->Enable(0);
		$this->{ctl_what}->SetLabel('');
		$this->{ctl_why}->SetLabel('');
		$this->{props}->SetValue("no source selected\n");
		return;
	}

	# A FILE THAT DID NOT LOAD IS STILL SELECTABLE AND STILL EDITABLE.  It
	# cannot be shown on the map, fetched from or probed, because it is not
	# a source; what it can be is opened and fixed, which is the only thing
	# anybody wants from it.

	if (!$src)
	{
		$this->{ctl_use}->Enable(0);
		$this->{ctl_probe}->Enable(0);
		$this->{ctl_edit}->Enable(1);
		$this->{ctl_what}->SetLabel('');
		$this->{ctl_why}->SetLabel("REFUSED - ".($node->{why} // ''));

		my $raw = readSourceFile($node->{leaf});
		$this->{props}->SetValue("$node->{leaf} is not loaded as a source.\n\n".
			($raw ?
				"Edit it to see and repair its fields.\n" :
				"It is not valid JSON, so it has no fields to show.\n"));
		return;
	}

	$this->{ctl_why}->SetLabel('');
	$this->{ctl_edit}->Enable(1);
	my $active = _activeId();
	my $is_on  = ($active && $id eq $active) ? 1 : 0;
	$this->{ctl_use}->Enable($is_on ? 0 : 1);
	$this->{ctl_probe}->Enable(1);
	$this->{ctl_what}->SetLabel($is_on ? 'shown on the map' : '');

	# THE PROBE'S FINDINGS REPLACE THE PANEL RATHER THAN JOINING IT, and
	# that is deliberate.  What the file declares and what the service
	# answers are two different claims, and interleaving them makes it
	# impossible to see which is which -- which is exactly the confusion
	# the disagreement list exists to resolve.  Selecting anything, or
	# rescanning, brings the file's own properties back.

	if ($this->{probed})
	{
		$this->{ctl_what}->SetLabel('what the SERVICE says - select again '.
			'for what the FILE says');
		$this->{props}->SetValue(join("\n",@{probeLines($this->{probed})})."\n");
		return;
	}

	my $text = '';
	for my $key (qw( id name file cache_key tile_format tile_size crs
					 redistributable license terms_url notes ))
	{
		$text .= sprintf("%-16s %s\n",$key,$src->{$key})
			if defined $src->{$key};
	}
	$text .= sprintf("%-16s %s\n",'uses',join(',',@{$src->{uses}}));
	$text .= sprintf("%-16s %d - %d\n",'zoom',
		$src->{zoom}{min},$src->{zoom}{max});
	$text .= sprintf("%-16s %s\n",'subdomains',join(',',@{$src->{subdomains}}))
		if $src->{subdomains};
	if ($src->{policy})
	{
		$text .= sprintf("%-16s %s\n","policy.$_",$src->{policy}{$_})
			for sort keys %{$src->{policy}};
	}
	if ($src->{credentials})
	{
		$text .= sprintf("%-16s %s\n",'credentials',
			join(',',map { $_->{slot} } @{$src->{credentials}}));
	}

	# HOW THIS SOURCE SAYS NO.  Counts rather than the values themselves:
	# a digest and a header token are not things a person reads, and what
	# is worth knowing here is whether the source has been taught to say
	# it at all -- an Esri source showing no fingerprints is a source that
	# will bake grey 'not yet available' tiles into a card.

	my $fps  = $src->{absent_fingerprints} || [];
	my $hdrs = $src->{absent_headers} || [];
	$text .= sprintf("%-16s %d fingerprint%s, %d header%s\n",'says absent',
		scalar(@$fps),  scalar(@$fps)  == 1 ? '' : 's',
		scalar(@$hdrs), scalar(@$hdrs) == 1 ? '' : 's')
		if @$fps || @$hdrs;

	# DISPLACEMENT IS ADVISORY AND SAYS SO IN THE SAME BREATH.  The field
	# is a statement that this imagery is knowingly displaced -- GCJ-02 is
	# off by a few hundred metres -- and the application does not correct
	# it.  Showing the name without showing that nothing acts on it would
	# read as "handled", which is the one impression it must not give.

	if (defined $src->{displacement})
	{
		$text .= "\n".sprintf("%-16s %s\n",'displacement',$src->{displacement});
		$text .= sprintf("%-16s %s\n",'',
			'this imagery is displaced and chartMaker does NOT correct it');
	}

	$text .= "\n".sprintf("%-16s %s\n",'attribution',$src->{attribution});
	$text .= "\n".sprintf("%-16s %s\n",'url',$src->{url}) if $src->{url};

	# What this source has actually cost so far.  Absences are counted
	# separately because they are knowledge, not failure -- a tile the
	# source does not have, recorded so it is never asked for again.

	my $stats = cacheStats($src);
	$text .= "\n".sprintf("%-16s %d tiles, %d absent, %s\n",'cache',
		$stats->{total_tiles},$stats->{total_misses},
		prettyBytes($stats->{total_bytes}));
	for my $z (sort { $a <=> $b } keys %{$stats->{zooms}})
	{
		my $zs = $stats->{zooms}{$z};
		$text .= sprintf("    z%-2d  %6d tiles  %6d absent  %9s\n",
			$z,$zs->{tiles},$zs->{misses},prettyBytes($zs->{bytes}));
	}

	$this->{props}->SetValue($text);
}


1;
