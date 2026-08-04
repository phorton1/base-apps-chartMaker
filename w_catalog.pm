#!/usr/bin/perl
#---------------------------------------------
# w_catalog.pm
#---------------------------------------------
# THE TILE SOURCE CATALOG, and the two ways out of it.
#
# IT IS THE SOURCES PANE IN A DIALOG, deliberately.  A tree on the left
# and what the selection says on the right is the shape somebody already
# reads sources in, and reusing it means the catalog needs no new reading
# habit and no control this application does not already use.
#
# A DIALOG RATHER THAN A PANE for the reason the editor is one: browsing a
# catalog and creating from it is a transaction with an end, not a view
# that sits beside the map.  There is nothing spatial in it.
#
# TWO EXITS, AND THEY ARE NOT ALTERNATIVES.
#
#	CREATE writes files.  Every instrument this application has takes a
#	TSD FILE - the map shows one, the probe measures one, the source list
#	lists them - so writing them is the on-ramp to all of it and not a
#	shortcut past it.  Judging twenty services means first having twenty
#	files.
#
#	EDIT opens one in the source editor.  That is for the entry somebody
#	has already decided about, and it is where a value only a person can
#	supply gets typed.
#
# ONE APPROVED LIST RATHER THAN A PROMPT PER FILE.  The editor settles
# uniqueness by asking, which is right for one file and impossible for
# twenty.  Create uses the same RULES - dm_catalog::catalogPlan enforces
# the editor's id and cache_key constraints exactly - and differs only in
# resolving them up front, showing the whole outcome, and taking one
# answer.  What it would SKIP is shown as prominently as what it would
# write, because a list that showed only the writes would read as though
# the rest had happened too.
#
# NOTHING HERE GOES TO THE NETWORK.  A created source is untested by
# construction and the dialog says so; the probe is the instrument that
# finds out.  That also means this opens instantly and works with no
# connection at all, which for a window whose whole content ships inside
# the application is the only defensible behaviour.

package w_catalog;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON EVT_TEXT EVT_TREE_SEL_CHANGED EVT_CLOSE );
use JSON;
use Pub::Utils;
use cm_defs;
use cm_state;
use cm_utils;
use dm_source;
use dm_keys;
use dm_catalog;
use dm_meta;
use dm_verify;
use w_keys;
use w_source;
use w_progress;
use w_verify;
use w_ini;
use base qw(Wx::Dialog);


our $dbg_catwin = 1;
	# 1 = quiet
	# 0 = what was written


my $ID_CREATE	= 8951;
my $ID_EDIT		= 8952;
my $ID_CLOSE	= 8953;
my $ID_FILTER	= 8954;
my $ID_EXPAND	= 8955;
my $ID_TEST		= 8956;

my $BIG_GROUP = 40;
	# Above this many children a group stays shut and says how many it has.

my $W_DLG	= 980;
my $H_DLG	= 640;
my $W_MIN	= 700;
my $H_MIN	= 440;

my $RED		= Wx::Colour->new(200,0,0);
my $BLACK	= Wx::Colour->new(0,0,0);
my $GREY	= Wx::Colour->new(120,120,120);


sub new
{
	my ($class,$parent) = @_;

	# WHERE IT WAS LEFT, checked against the display it is about to appear
	# on.  Wx::Display is not in every wxPerl build and a dialog that
	# refused to open because it could not ask about monitors would be a
	# far worse fault than one that opens somewhere awkward.

	my ($x,$y,$w,$h) = (-1,-1,$W_DLG,$H_DLG);
	my $was = getCatalogRect();
	if ($was =~ /^(-?\d+),(-?\d+),(\d+),(\d+)$/)
	{
		my ($rx,$ry,$rw,$rh) = ($1,$2,$3,$4);
		my $area = eval { Wx::Display->new(0)->GetClientArea() };
		my $ok = $rw >= $W_MIN && $rh >= $H_MIN;
		$ok &&= ($rx + $rw > $area->x + 60 && $ry + $rh > $area->y + 60 &&
				 $rx < $area->x + $area->width - 60 &&
				 $ry < $area->y + $area->height - 60) if $area;
		($x,$y,$w,$h) = ($rx,$ry,$rw,$rh) if $ok;
	}

	my $this = $class->SUPER::new($parent,-1,'Tile Source Catalog',
		[$x,$y],[$w,$h],wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);
	$this->SetMinSize([$W_MIN,$H_MIN]);

	$this->{created} = [];
	$this->{err}     = loadCatalog();

	# WHAT THIS IS, ABOVE EVERYTHING.  A list of services inside an
	# application reads as a recommendation unless it says otherwise, and
	# the one thing every row here has in common is that nobody has
	# checked it today.

	my $intro = Wx::StaticText->new($this,-1,
		'Tile services known to chartMaker.  Every entry is a starting '.
		'point for checking and not a current fact - services move, '.
		'endpoints retire, and terms change without the endpoint changing.  '.
		'Creating a source writes an UNTESTED definition - probe it to find '.
		'out whether it works.');
	$intro->SetForegroundColour($GREY);

	# A StaticText DOES NOT WRAP, it clips - and what it clipped was the
	# end of the sentence, which is the half that says the thing is
	# untested.  Wrapped at the NARROWEST the dialog can be rather than at
	# its current width, so shrinking it never truncates this again.

	$intro->Wrap($W_MIN - 40);

	my $split = Wx::SplitterWindow->new($this,-1);

	#---------------------------------------------
	# left: the filter and the tree
	#---------------------------------------------
	# THE FILTER IS ABOVE THE TREE AND NOT BESIDE IT.  A provider with a
	# hundred layers is not scannable, and the box that makes it scannable
	# has to be the first thing in the pane it acts on.

	my $left = Wx::Panel->new($split,-1);
	$this->{filter} = Wx::TextCtrl->new($left,$ID_FILTER,'');
	$this->{filter}->SetToolTip(
		'Show only entries matching this - the name, the region, the cost, '.
		'or what it is worth');

	$this->{tree} = Wx::TreeCtrl->new($left,-1,
		wxDefaultPosition,wxDefaultSize,
		wxTR_HAS_BUTTONS | wxTR_HIDE_ROOT | wxTR_MULTIPLE |
		wxTR_LINES_AT_ROOT);

	my $lsz = Wx::BoxSizer->new(wxVERTICAL);
	$lsz->Add($this->{filter},0,wxEXPAND|wxALL,4);
	$lsz->Add($this->{tree},1,wxEXPAND|wxALL,4);
	$left->SetSizer($lsz);

	#---------------------------------------------
	# right: what the selection says
	#---------------------------------------------

	$this->{props} = Wx::TextCtrl->new($split,-1,'',
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{props}->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	$split->SplitVertically($left,$this->{props},430);
	$split->SetMinimumPaneSize(200);

	#---------------------------------------------
	# the foot
	#---------------------------------------------

	$this->{why} = Wx::StaticText->new($this,-1,'');

	$this->{create} = Wx::Button->new($this,$ID_CREATE,'Create Sources',
		wxDefaultPosition,[130,26]);
	$this->{create}->SetToolTip('Write a .tsd for every entry selected. '.
		'Shows what it would do first.');
	$this->{edit} = Wx::Button->new($this,$ID_EDIT,'Edit as New Source...',
		wxDefaultPosition,[150,26]);
	$this->{edit}->SetToolTip('Open this entry in the source editor, '.
		'where nothing is written until you save it.');
	# EXPAND IS ON THE LEFT, AWAY FROM THE TWO THAT WRITE FILES.  It is the
	# only button here that goes to the network and the only one that
	# changes what the list contains rather than what the folder contains.

	$this->{expand} = Wx::Button->new($this,$ID_EXPAND,'Expand',
		wxDefaultPosition,[100,26]);
	$this->{expand}->SetToolTip('Ask this service what layers it publishes '.
		'today. One request, no imagery, and nothing is written.');

	# TEST SITS BESIDE EXPAND for the same reason Expand sits apart: both
	# go to the network, neither writes a file, and neither ends the
	# dialog.
	#
	# IT TESTS AN ENTRY THAT DOES NOT EXIST YET, which is the whole value
	# of it being here.  Judging twenty candidates by creating twenty files
	# and testing each one is the long way round to a decision that can be
	# made before anything is written.

	$this->{test} = Wx::Button->new($this,$ID_TEST,'Test',
		wxDefaultPosition,[100,26]);
	$this->{test}->SetToolTip('Ask the service whether this entry is true, '.
		'without creating it. Nothing is written.');

	my $close = Wx::Button->new($this,$ID_CLOSE,'Close',
		wxDefaultPosition,[100,26]);

	my $brow = Wx::BoxSizer->new(wxHORIZONTAL);
	$brow->Add($this->{expand},0,0,0);
	$brow->AddSpacer(8);
	$brow->Add($this->{test},0,0,0);
	$brow->AddSpacer(24);
	$brow->Add($this->{create},0,0,0);
	$brow->AddSpacer(8);
	$brow->Add($this->{edit},0,0,0);
	$brow->AddStretchSpacer(1);
	$brow->Add($close,0,0,0);

	my $outer = Wx::BoxSizer->new(wxVERTICAL);
	$outer->Add($intro,0,wxEXPAND|wxALL,10);
	$outer->Add($split,1,wxEXPAND|wxLEFT|wxRIGHT,6);
	$outer->Add($this->{why},0,wxEXPAND|wxLEFT|wxRIGHT|wxTOP,10);
	$outer->Add($brow,0,wxEXPAND|wxALL,10);
	$this->SetSizer($outer);
	$this->Layout();

	EVT_TEXT($this,$ID_FILTER,sub { $_[0]->populate() });
	EVT_TREE_SEL_CHANGED($this,$this->{tree},\&onSelect);
	EVT_BUTTON($this,$ID_CREATE,\&onCreate);
	EVT_BUTTON($this,$ID_EDIT,  \&onEdit);
	EVT_BUTTON($this,$ID_EXPAND,\&onExpand);
	EVT_BUTTON($this,$ID_TEST,  \&onTest);
	EVT_BUTTON($this,$ID_CLOSE, sub { $_[0]->done() });
	EVT_CLOSE($this,sub { $_[0]->done() });

	$this->populate();
	return $this;
}


sub done
	# THE ONLY WAY OUT, so there is one place that measures the window.
{
	my ($this) = @_;
	my ($x,$y) = $this->GetPositionXY();
	my ($w,$h) = $this->GetSizeWH();
	setCatalogRect("$x,$y,$w,$h");
	$this->EndModal(wxID_OK);
}


sub created
	# The leaves this dialog wrote, for a caller that has a list to
	# refresh.  Rescanning has already happened; what the caller owns is
	# its own view of the folder.
{
	my ($this) = @_;
	return $this->{created};
}


sub _say
{
	my ($this,$text,$is_err) = @_;
	$this->{why}->SetForegroundColour($is_err ? $RED : $BLACK);
	$this->{why}->SetLabel($text // '');
}


#---------------------------------------------
# what is already installed
#---------------------------------------------

sub _installed
	# THE THREE THINGS catalogPlan NEEDS, gathered here because this is the
	# layer that is allowed to know both modules.  dm_catalog is told; it
	# does not ask, and it does not use dm_source.
{
	my ($this) = @_;
	my (%ids,%leaves,%keys);

	$leaves{lc $_} = 1 for getSourceFiles();

	for my $id (getSourceIds())
	{
		my $src = getSource($id);
		next if !$src;
		$ids{$id} = $src->{file};
		$keys{$src->{cache_key}} = {
			leaf => $src->{file},
			url  => $src->{url} } if defined $src->{cache_key};
	}
	return { ids => \%ids, leaves => \%leaves, keys => \%keys };
}


#---------------------------------------------
# the tree
#---------------------------------------------

sub _addNodes
	# A GROUP APPEARS ONLY IF SOMETHING UNDER IT DOES.  Filtering that left
	# empty providers standing would make a search look like it had found
	# something every time.
	#
	# RETURNS TWO COUNTS, AND CONFLATING THEM WAS A BUG.  'Is there
	# anything under this at all' is a question about every descendant;
	# 'is this too big to open' is a question about the rows that would
	# appear directly beneath it.  Expanding Esri Wayback took its parent
	# from two descendants to 197, which crossed the big-group threshold
	# and shut the Esri group - so the node that had just been filled
	# vanished from the user's point of view, inside a parent that closed
	# itself.
{
	my ($this,$parent,$nodes,$text,$inst) = @_;
	my $tree  = $this->{tree};
	my $added = 0;		# entries anywhere below here
	my $here  = 0;		# rows appended directly under $parent

	for my $node (@$nodes)
	{
		if ($node->{is_entry})
		{
			next if !catalogMatches($node,$text);

			# INSTALLED IS MARKED RATHER THAN HIDDEN.  On a second visit
			# the point of the list is largely to see what you already
			# have, and an entry that vanished once taken would make that
			# impossible to read.

			# THE MARK IS SHORT BECAUSE IT IS LAST.  A tree label is clipped
			# at the pane edge, so whatever goes on the end is the first
			# thing to disappear - and '[installed as some_long_name.tsd]'
			# disappeared exactly when the labels were longest.  Which file
			# holds it is in the panel, where there is room for it.

			my $have = $inst->{ids}{$node->{id}};
			my $item = $tree->AppendItem($parent,catalogLabel($node).
				($have ? '   [installed]' : ''));
			$tree->SetItemData($item,Wx::TreeItemData->new($node));
			$tree->SetItemTextColour($item,$GREY) if $have;
			$added++;
			$here++;
			next;
		}

		my $item = $tree->AppendItem($parent,$node->{name});
		$tree->SetItemData($item,Wx::TreeItemData->new($node));
		$tree->SetItemBold($item,1);
		my ($kids,$kids_here) = $this->_addNodes($item,$node->{kids},$text,$inst);
		if (!$kids)
		{
			# A GROUP THAT SHIPS NOTHING AND FILLS ITSELF MUST STILL SHOW.
			# The rule above - a provider appears only if something under
			# it does - was written before an empty expandable group could
			# exist, and it deleted the one node whose entire purpose is to
			# be expanded.  Esri Wayback was in the catalog, loaded, and
			# invisible.
			#
			# It still has to earn its place against the filter, on its own
			# text, since it has no children to match on its behalf.

			if (!catalogExpander($node) || !catalogMatches($node,$text))
			{
				$tree->Delete($item);
				next;
			}
			$tree->SetItemText($item,
				"$node->{name}   (ships nothing - Expand to list it)");
			$here++;
			next;
		}

		# A PROVIDER OPENS UNLESS OPENING IT WOULD BURY EVERYTHING ELSE.
		# Expanding GIBS attaches over a thousand layers, and a tree that
		# unrolled all of them would hide every other service in the
		# catalog behind a scrollbar.  So a large group states its size and
		# waits to be opened, which is also the moment the filter box above
		# becomes the thing to reach for.
		#
		# JUDGED ON ITS OWN ROWS, not on everything beneath it.  Esri holds
		# three things and one of them holds 195, and Esri is not big.

		if ($kids_here > $BIG_GROUP)
		{
			$tree->SetItemText($item,"$node->{name}   ($kids entries)");
		}
		else
		{
			$tree->Expand($item);
		}
		$added += $kids;
		$here++;
	}
	return ($added,$here);
}


sub populate
{
	my ($this) = @_;
	my $tree = $this->{tree};

	$tree->Freeze();
	$tree->DeleteAllItems();
	my $root = $tree->AddRoot('catalog');

	if ($this->{err})
	{
		$tree->Thaw();
		$this->{props}->SetValue(
			"The shipped catalog could not be read.\n\n$this->{err}\n\n".
			"This file ships with the application, so this is a fault in ".
			"the installation rather than anything you did.\n");
		$this->_say("catalog unavailable - $this->{err}",1);
		$this->{create}->Enable(0);
		$this->{edit}->Enable(0);
		$this->{expand}->Enable(0);
		return;
	}

	my $text  = $this->{filter}->GetValue();
	my $inst  = $this->_installed();
	my ($count) = $this->_addNodes($root,catalogRoot(),$text,$inst);

	# LAND ON WHAT WAS JUST FILLED.  A rebuild loses the selection, and an
	# Expand that returned 195 layers and then showed the user an unchanged
	# tree is indistinguishable from one that did nothing.

	$this->_reveal($this->{reveal}) if $this->{reveal};
	$tree->Thaw();

	$this->{props}->SetValue($count ?
		"Select an entry to see what it is.\n" :
		"Nothing matches '$text'.\n");
	$this->_enable();
}


sub _reveal
	# Put one node back in front of the user after a rebuild, by its id.
	# Walked rather than remembered, because every tree item was destroyed
	# and recreated and a held Wx::TreeItemId would name nothing.
{
	my ($this,$id) = @_;
	my $tree = $this->{tree};

	my $walk;
	$walk = sub {
		my ($item) = @_;
		my ($kid,$cookie) = $tree->GetFirstChild($item);
		while ($kid && $kid->IsOk())
		{
			my $d = $tree->GetItemData($kid);
			my $n = $d ? $d->GetData() : undef;
			return $kid if $n && $n->{id} eq $id;
			my $found = $walk->($kid);
			return $found if $found;
			($kid,$cookie) = $tree->GetNextChild($item,$cookie);
		}
		return undef;
	};

	my $item = $walk->($tree->GetRootItem());
	return if !$item;
	$tree->Expand($item);
	$tree->EnsureVisible($item);
	$tree->SelectItem($item);
}


sub _selected
	# Every ENTRY selected, in tree order.  A group can be selected and
	# means nothing, which is better than making groups unselectable: a
	# provider is a legitimate thing to click on to read its terms.
{
	my ($this) = @_;
	my $tree = $this->{tree};
	my @out;
	for my $item ($tree->GetSelections())
	{
		next if !$item || !$item->IsOk();
		my $d = $tree->GetItemData($item);
		my $n = $d ? $d->GetData() : undef;
		push @out,$n if $n && $n->{is_entry};
	}
	return @out;
}


sub _expandable
	# The GROUP an expand would act on.  A group with an expander is the
	# obvious case; an ENTRY whose provider has one counts too, because
	# somebody looking at one GIBS layer and wanting the rest should not
	# have to work out that the answer is attached to the line above.
{
	my ($this) = @_;
	my $tree = $this->{tree};
	my @items = $tree->GetSelections();
	return undef if scalar(@items) != 1;

	my $item = $items[0];
	return undef if !$item || !$item->IsOk();

	my $d = $tree->GetItemData($item);
	my $n = $d ? $d->GetData() : undef;
	return undef if !$n;
	return $n if catalogExpander($n);

	# WALKED UP RATHER THAN LOOKED UP ONCE.  A layer can sit inside the
	# fold group its own service made for it, which puts a node with no
	# expander between the layer and the service that has one.  Looking
	# exactly one level up made Expand go dead for precisely the layers
	# most likely to prompt somebody to press it.

	my $up = $tree->GetItemParent($item);
	while ($up && $up->IsOk() && $up != $tree->GetRootItem())
	{
		my $pd = $tree->GetItemData($up);
		my $pn = $pd ? $pd->GetData() : undef;
		return $pn if $pn && catalogExpander($pn);
		$up = $tree->GetItemParent($up);
	}
	return undef;
}


sub _enable
{
	my ($this) = @_;
	return if $this->{err};
	my @sel = $this->_selected();
	$this->{create}->Enable(scalar(@sel) ? 1 : 0);
	$this->{edit}->Enable(scalar(@sel) == 1 ? 1 : 0);
	$this->{expand}->Enable($this->_expandable() ? 1 : 0);

	# TEST TAKES EXACTLY ONE, because its answer is a column of levels at a
	# place and there is no way to read twenty of those at once.

	$this->{test}->Enable(scalar(@sel) == 1 ? 1 : 0);
}


sub onSelect
{
	my ($this,$event) = @_;
	my $tree = $this->{tree};

	# THE LAST THING CLICKED IS WHAT IS SHOWN, which for a multiple
	# selection is the only answer that is not arbitrary.

	my $item = $event->GetItem();
	my $node;
	if ($item && $item->IsOk())
	{
		my $d = $tree->GetItemData($item);
		$node = $d ? $d->GetData() : undef;
	}
	my @lines = $node ? @{catalogLines($node)} : ();

	# WHERE IT IS INSTALLED, HIGH UP.  The tree can only afford the fact
	# that it is; the file holding it is what somebody wants next, and
	# dm_catalog cannot say because it does not know what a source folder
	# is.  This is the layer that knows both.

	if ($node && $node->{is_entry})
	{
		my $have = $this->_installed()->{ids}{$node->{id}};
		splice(@lines,1,0,'',"installed as $have") if $have;
	}

	$this->{props}->SetValue(@lines ? join("\n",@lines)."\n" : '');
	$this->_say('');
	$this->_enable();
}


#---------------------------------------------
# create
#---------------------------------------------

sub _confirm
	# THE PLAN, AND ONE ANSWER.  Modal over the catalog, because what it
	# asks about is the selection sitting behind it.
{
	my ($this,$lines,$ok_label) = @_;

	my $dlg = Wx::Dialog->new($this,-1,'Create Sources',
		wxDefaultPosition,[620,420],
		wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

	my $text = Wx::TextCtrl->new($dlg,-1,join("\n",@$lines)."\n",
		wxDefaultPosition,wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$text->SetFont(Wx::Font->new(8,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $ok = Wx::Button->new($dlg,wxID_OK,$ok_label,
		wxDefaultPosition,[120,26]);
	my $no = Wx::Button->new($dlg,wxID_CANCEL,'Cancel',
		wxDefaultPosition,[100,26]);

	my $row = Wx::BoxSizer->new(wxHORIZONTAL);
	$row->AddStretchSpacer(1);
	$row->Add($ok,0,0,0);
	$row->AddSpacer(8);
	$row->Add($no,0,0,0);

	my $sz = Wx::BoxSizer->new(wxVERTICAL);
	$sz->Add($text,1,wxEXPAND|wxALL,10);
	$sz->Add($row,0,wxEXPAND|wxALL,10);
	$dlg->SetSizer($sz);
	$dlg->Layout();

	my $rslt = $dlg->ShowModal();
	$dlg->Destroy();
	# THE PARENTHESES ARE LOAD BEARING.  wxID_OK is a bareword sub call and
	# this perl still honours ?PATTERN? as a match operator, so without
	# them the '?' opens a pattern that runs on to the next '?' twenty
	# lines below and every error is reported somewhere else entirely.

	return ($rslt == wxID_OK) ? 1 : 0;
}


sub onCreate
{
	my ($this,$event) = @_;
	my @sel = $this->_selected();
	return $this->_say('select one or more entries to create',1) if !@sel;

	my $plan = catalogPlan(\@sel,$this->_installed());
	my @make = grep { $_->{action} eq 'create' } @$plan;

	my @lines = @{catalogPlanLines($plan)};
	push @lines,'';
	push @lines,'Nothing here has been checked against its service.  Each';
	push @lines,'file is written exactly as the catalog states it, and the';
	push @lines,'probe is what says whether it answers.';

	return $this->_say(
		'nothing to write - everything selected is already installed',0)
		if !@make;

	return if !$this->_confirm(\@lines,
		'Write '.scalar(@make).' file'.(@make == 1 ? '' : 's'));

	my ($wrote,@bad) = (0);
	for my $r (@make)
	{
		my $err = writeSourceFile($r->{leaf},$r->{tsd});
		if ($err)
		{
			push @bad,"$r->{leaf}: $err";
			next;
		}
		display($dbg_catwin,0,"catalog wrote $r->{leaf}");
		push @{$this->{created}},$r->{leaf};
		$wrote++;
	}

	# RESCAN BEFORE REPOPULATING, so the [installed] marks the user is
	# about to look at are the truth about the folder and not this
	# dialog's memory of what it just did.
	#
	# AND BUMP THE STATE, WHICH IS WHAT TELLS EVERYTHING ELSE.  Rescanning
	# updates the MODEL and nothing watches the model - the Sources pane
	# watches the state counter on a timer, and the browser polls it.
	# Without this the files existed, loaded and were addressable the
	# instant they were written, and the one place a person was looking
	# went on showing the old list until this dialog closed.

	rescanSources();
	bumpState('sources created from the catalog');
	$this->populate();

	my $said = "wrote $wrote source".($wrote == 1 ? '' : 's');
	$said .= ", ".scalar(@bad)." failed: ".join('; ',@bad) if @bad;
	$this->_say($said,scalar(@bad) ? 1 : 0);
}


#---------------------------------------------
# expand
#---------------------------------------------

sub _askForKeys
	# Every key_name a field hash declares, asked for once if nothing is
	# bound to it.  Returns 1 to go ahead, 0 if the user declined.
	#
	# ONE OF THE TWO SURFACES THAT MAY PROMPT AT ALL.  A person is sitting
	# here and has just clicked something; the entry names the key and where
	# to get one; and the alternative is a network act that fails for a
	# reason this dialog already knew. The mechanical surfaces - build,
	# probe, the map - report and stop instead.
	#
	# DECLINING IS AN ANSWER AND IS RESPECTED.  It does not ask twice in one
	# act, and it does not proceed to make the request anyway.
{
	my ($this,$tsd) = @_;
	return 1 if !$tsd || ref($tsd->{keys}) ne 'ARRAY';

	for my $key (@{$tsd->{keys}})
	{
		my $name = $key->{key_name} // '';
		next if !length $name;

		my $val = getKeyValue($name);
		next if defined($val) && $val =~ /\S/;

		return 0 if !w_keys->ask($this,$name,
			$key->{label} || $name,$key->{obtain_url} || '');
	}
	return 1;
}


sub onExpand
	# ASK THE SERVICE WHAT IT PUBLISHES, on a worker, under the progress
	# dialog.
	#
	# THE PROGRESS DIALOG IS HOW THE WORKER IS MODALIZED.  A 5 MB
	# GetCapabilities can take most of a minute, and the alternatives are
	# both worse: on the main thread it freezes this dialog with no way
	# out, and as a background task it would finish at some unpredictable
	# moment and rearrange a list the user was reading.  The dialog gives
	# the act a beginning, a visible middle, an end, and somewhere for
	# Cancel to live.
	#
	# CANCEL ABANDONS THE ANSWER RATHER THAN STOPPING THE REQUEST, which
	# the worker says for itself.  Nothing can interrupt a GET in flight.
{
	my ($this,$event) = @_;

	my $node = $this->_expandable();
	return $this->_say('select a service that publishes a layer list',1)
		if !$node;

	my $x = catalogExpander($node);

	# THE THIRD SEAM, AND THE ONE NOBODY EXPECTS.  A keyed service's
	# CAPABILITIES DOCUMENT IS KEYED TOO - LINZ answers 400 without a key -
	# so the expander url carries a {key_name} exactly as a tile url does,
	# and it has to be resolved before the worker is given it.
	#
	# THE CHICKEN AND EGG THIS SETTLES.  To expand a keyed provider you
	# need the key; to have anywhere to put the key you would, under any
	# design where a value hangs off an installed source, need a source you
	# do not have yet.  The store being a free standing map of name to
	# value is what makes this possible at all, and asking here is what
	# makes it painless.

	my $group = $node->{tsd} || {};
	return if !$this->_askForKeys({ %$group, url => $x->{url} });

	my $url = $x->{url};
	my $bad;
	($url,$bad) = keyResolve($url,[ keyNamesOf($url,[ sourcePlaceholders() ]) ]);
	return $this->_say("unresolved token {$bad} - url unusable",1)
		if !defined $url;

	my $prog = newProgress(2,'');
	$prog->{active} = 1;
	$prog->{phase}  = 'Starting';

	threads->create(\&dm_meta::layersWorker,$prog,
		[ $x->{kind},$url ])->detach();

	my $dlg = w_progress->new($this,"Expand - $node->{name}",$prog);
	$dlg->run();

	# THE ANSWER CROSSES AS TEXT, decoded once here.  See layersWorker for
	# why it is not a shared structure.

	my $rslt = eval { decode_json($prog->{json} || '{}') };
	if (!$rslt || !$rslt->{ok})
	{
		my $why = ($rslt && $rslt->{reason}) ? $rslt->{reason} :
			($prog->{cancelled} ? 'cancelled' : 'the service could not be read');
		return $this->_say("expand failed - $why",
			$prog->{cancelled} ? 0 : 1);
	}

	my ($added,$known) = catalogAttach($node,$rslt->{layers});
	$this->{reveal} = $node->{id};

	# WHAT WAS LEFT OUT, AND WHY.  A filtered list that did not say it was
	# filtered would read as the whole of what the service holds, and the
	# number hidden here is usually far larger than the number shown.

	my @said;
	push @said,"$added new";
	push @said,"$known already listed" if $known;
	my $hid = $rslt->{hidden} || {};
	my $total_hidden = 0;
	$total_hidden += $hid->{$_} for keys %$hid;
	if ($total_hidden)
	{
		my ($worst) = sort { $hid->{$b} <=> $hid->{$a} } keys %$hid;
		push @said,"$total_hidden of $rslt->{total} not shown ".
			"(mostly: $worst)";
	}

	$this->populate();
	$this->_say(join(', ',@said),0);
}


#---------------------------------------------
# test
#---------------------------------------------

sub onTest
	# ASK THE SERVICE ABOUT AN ENTRY THAT HAS NEVER BEEN WRITTEN.
	#
	# THE SAME VERIFIER THE EDITOR USES, given the same kind of field hash.
	# A catalog entry becomes one by exactly the path Create would take, so
	# what is tested here is what would be written and not an approximation
	# of it.
	#
	# THE ENTRY CARRIES ITS OWN CANONICAL POINT and hands it over, because
	# nothing on disk names this entry yet - dm_verify finds a point by
	# matching a saved source's url against the catalog, and there is no
	# saved source to match.
{
	my ($this,$event) = @_;

	my @sel = $this->_selected();
	return $this->_say('select exactly one entry to test',1)
		if scalar(@sel) != 1;

	my $node   = $sel[0];
	my $tsd    = catalogTsd($node);

	# A KEY IS ASKED FOR HERE, WHERE A PERSON IS PRESENT.  This is one of
	# the two surfaces that may prompt: somebody just clicked Test, the
	# entry itself says which key_name it needs and where to get one, and
	# the alternative is a test that fails with a 400 for a reason the
	# dialog already knew.  Build and probe never do this - they run on a
	# worker thread under a modal progress dialog, and a prompt there would
	# ambush somebody who walked away.

	return if !$this->_askForKeys($tsd);

	my @places = verifyPlaces($tsd,$node->{canonical});

	my $prog = newProgress(2,'');
	$prog->{active} = 1;
	$prog->{phase}  = 'Starting';

	threads->create(\&dm_verify::verifyWorker,$prog,
		[ encode_json($tsd),encode_json(\@places),catalogLeaf($node) ]
		)->detach();

	my $dlg = w_progress->new($this,"Test - $node->{name}",$prog);
	$dlg->run();

	my $out = eval { decode_json($prog->{json} || '{}') };
	return $this->_say('the test could not be completed',1)
		if !$out || !$out->{verdict};

	w_verify->show($this,$out);

	# AND SAID IN THE FOOT AS WELL, because the dialog is dismissed and the
	# question 'which of these did I already try' outlives it.

	my %said = (
		verified  => 'it works',
		unrefuted => 'nothing disproved, and little proved',
		problems  => 'problems found',
		cancelled => 'stopped',
	);
	$this->_say("$node->{name} - ".($said{$out->{verdict}} || ''),
		$out->{verdict} eq 'problems' ? 1 : 0);
}


#---------------------------------------------
# edit
#---------------------------------------------

sub onEdit
	# STRAIGHT INTO THE EDITOR, with a leaf of '' so the editor treats it
	# as a file that does not exist yet: every field purple, Save behaving
	# as Save As, and its own rules deciding the name and the uniqueness.
	# Nothing is written unless the person saves it, which is exactly what
	# this exit is for.
{
	my ($this,$event) = @_;
	my @sel = $this->_selected();
	return $this->_say('select exactly one entry to edit',1)
		if scalar(@sel) != 1;

	my $node = $sel[0];
	my $inst = $this->_installed();
	if (my $have = $inst->{ids}{$node->{id}})
	{
		# SAID, NOT REFUSED.  Making a variant of something installed is a
		# legitimate thing to do; what is not legitimate is doing it by
		# accident, and the editor will refuse the duplicate id anyway.

		$this->_say("note: '$node->{id}' is already installed as $have - ".
			"the editor will need a new id",0);
	}

	my $dlg = w_source->new($this,'',catalogTsd($node),1);
	my $rslt = $dlg->ShowModal();
	my $leaf = $dlg->savedAs();
	$dlg->Destroy();

	return if $rslt != wxID_OK || !$leaf;

	display($dbg_catwin,0,"catalog edited into $leaf");
	push @{$this->{created}},$leaf;
	rescanSources();
	bumpState('source written from the catalog');
	$this->populate();
	$this->_say("wrote $leaf",0);
}


1;
