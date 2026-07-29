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
use Wx::Event qw( EVT_TREE_SEL_CHANGED EVT_LEFT_DOWN EVT_TIMER EVT_BUTTON );
use Pub::Utils;
use Pub::WX::Window;
use cm_defs;
use cm_state;
use dm_source;
use dm_cache;
use base qw(Wx::SplitterWindow Pub::WX::Window);


our $dbg_win:shared = 1;
	# 1 = quiet
	# 0 = selection changes


my $TIMER_MS = 500;


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
	$this->{ctl_what} = Wx::StaticText->new($right,-1,'');

	my $row = Wx::BoxSizer->new(wxHORIZONTAL);
	$row->Add($this->{ctl_use},0,$CV,0);
	$row->AddSpacer(10);
	$row->Add($this->{ctl_rescan},0,$CV,0);
	$row->AddSpacer(16);
	$row->Add($this->{ctl_what},0,$CV,0);

	$this->{props} = Wx::TextCtrl->new($right,-1,'',
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{props}->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $sizer = Wx::BoxSizer->new(wxVERTICAL);
	$sizer->AddSpacer(8);
	$sizer->Add($row,0,wxLEFT|wxRIGHT,8);
	$sizer->AddSpacer(8);
	$sizer->Add($this->{props},1,wxEXPAND|wxALL,4);
	$right->SetSizer($sizer);

	$this->SplitVertically($this->{tree},$right,320);
	$this->SetMinimumPaneSize(160);

	EVT_TREE_SEL_CHANGED($this,$this->{tree},\&onSelect);
	EVT_LEFT_DOWN($this->{tree},sub { $this->onTreeLeftDown($_[1]) });
	EVT_BUTTON($this,$this->{ctl_use},\&onUse);
	EVT_BUTTON($this,$this->{ctl_rescan},\&onRescan);

	$this->{seen_seq} = -1;
	$this->{timer} = Wx::Timer->new($this,-1);
	EVT_TIMER($this,-1,\&onTimer);
	$this->{timer}->Start($TIMER_MS);

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
	# The source the map is showing.  cm_state holds the choice and this
	# module knows the choices, so the fallback lives here -- the same
	# order /state uses, or the two surfaces would disagree about which
	# source is active before anyone has picked one.
{
	my @ids = getSourceIds();
	my $active = getActiveSource();
	return $active if $active && getSource($active);
	for my $id (@ids)
	{
		return $id if grep { $_ eq 'build' } @{getSource($id)->{uses}};
	}
	return $ids[0];
}


sub populate
{
	my ($this) = @_;
	my $tree = $this->{tree};
	my $was  = $this->selectedId();

	$tree->DeleteAllItems();
	my $root   = $tree->AddRoot('sources');
	my $active = _activeId();
	my $sel;

	for my $id (getSourceIds())
	{
		my $src  = getSource($id);
		my $item = $tree->AppendItem($root,
			sprintf("%s   z%d-%d",$src->{name},
				$src->{zoom}{min},$src->{zoom}{max}));
		$tree->SetItemData($item,Wx::TreeItemData->new({ id => $id }));
		$tree->SetItemState($item,($active && $id eq $active) ? 1 : 0);
		$sel = $item if $was ? ($was eq $id) : ($active && $id eq $active);
	}

	# With nothing previously selected, land on the source the map is
	# showing.  An empty properties panel on open is a wasted pane.

	$tree->SelectItem($sel) if $sel && $sel->IsOk();
	$this->{seen_seq} = getStateSeq();
	$this->showProperties();
}


sub onTimer
{
	my ($this,$event) = @_;
	return if getStateSeq() == $this->{seen_seq};
	$this->populate();
}


sub selectedId
{
	my ($this) = @_;
	my $item = $this->{tree}->GetSelection();
	return undef if !$item || !$item->IsOk();
	my $d = $this->{tree}->GetItemData($item);
	return $d ? $d->GetData()->{id} : undef;
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
	setActiveSource($id);
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
	my $found = rescanSources();
	display(0,0,"winSources: rescan found $found source".($found == 1 ? '' : 's'));
	bumpState("sources rescanned");
	$this->{seen_seq} = getStateSeq();
	$this->populate();
}


sub onSelect
{
	my ($this,$event) = @_;
	$this->showProperties();
}


#---------------------------------------------
# properties
#---------------------------------------------

sub showProperties
{
	my ($this) = @_;
	my $id  = $this->selectedId();
	my $src = $id ? getSource($id) : undef;

	if (!$src)
	{
		$this->{ctl_use}->Enable(0);
		$this->{ctl_what}->SetLabel('');
		$this->{props}->SetValue("no source selected\n");
		return;
	}

	my $active = _activeId();
	my $is_on  = ($active && $id eq $active) ? 1 : 0;
	$this->{ctl_use}->Enable($is_on ? 0 : 1);
	$this->{ctl_what}->SetLabel($is_on ?
		'this is the source the map is showing' : '');

	my $text = '';
	for my $key (qw( id name kind file cache_key tile_format tile_size crs
					 redistributable license terms_url notes ))
	{
		$text .= sprintf("%-16s %s\n",$key,$src->{$key})
			if defined $src->{$key};
	}
	$text .= sprintf("%-16s %s\n",'uses',join(',',@{$src->{uses}}));
	$text .= sprintf("%-16s %d - %d  (protocol limits)\n",'zoom',
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

	$text .= "\n".sprintf("%-16s %s\n",'attribution',$src->{attribution});
	$text .= "\n".sprintf("%-16s %s\n",'url',$src->{url}) if $src->{url};

	# What this source has actually cost so far.  Absences are counted
	# separately because they are knowledge, not failure -- a tile the
	# source does not have, recorded so it is never asked for again.

	my $stats = cacheStats($src);
	$text .= "\n".sprintf("%-16s %d tiles, %d absent, %d bytes\n",'cache',
		$stats->{total_tiles},$stats->{total_misses},$stats->{total_bytes});
	for my $z (sort { $a <=> $b } keys %{$stats->{zooms}})
	{
		my $zs = $stats->{zooms}{$z};
		$text .= sprintf("    z%-2d  %6d tiles  %6d absent  %9d bytes\n",
			$z,$zs->{tiles},$zs->{misses},$zs->{bytes});
	}

	$this->{props}->SetValue($text);
}


1;
