#!/usr/bin/perl
#---------------------------------------------
# w_frame.pm
#---------------------------------------------
# The chartMaker application frame.
#
# THE FRAME OWNS THE DOCUMENT.  A region set is opened, saved and closed
# here, because those are questions about the application rather than
# about any one pane - and because the panes come and go while the
# document does not.
#
# The Regions pane is the document's VIEW.  Opening a set opens it,
# closing the set closes it, and it is not something to be shown and
# hidden on its own, which is why it is not in the View menu.

package w_frame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_MENU EVT_UPDATE_UI);
use Pub::Utils;
use Pub::WX::Frame;
use Pub::WX::AppConfig;
use cm_defs;
use cm_state;
use cm_utils;
use dm_set;
use dm_region;
use w_resources;
use w_ini;
use winRegions;
use winSources;
use base qw(Pub::WX::Frame);


our $dbg_frame:shared = 0;	# 0=wip; -1=menu commands


sub new
{
	my ($class,$parent) = @_;
	my $rect = Wx::Rect->new(200,100,1100,800);

	# RESTORE_ALL, not just the window rectangle: the panes you had open
	# come back.  createPane() is what makes this work -- the ini stores
	# pane ids and the frame asks for them again at startup.

	Pub::WX::Frame::setHowRestore($Pub::WX::Frame::RESTORE_ALL);

	my $this = $class->SUPER::new($parent,$rect);

	EVT_MENU($this, $COMMAND_OPEN_MAP,    \&onCommand);
	EVT_MENU($this, $WIN_REGIONS,         \&onCommand);
	EVT_MENU($this, $WIN_SOURCES,         \&onCommand);
	EVT_MENU($this, $COMMAND_SET_OPEN,    \&onCommand);
	EVT_MENU($this, $COMMAND_SET_NEW,     \&onCommand);
	EVT_MENU($this, $COMMAND_SET_SAVE,    \&onCommand);
	EVT_MENU($this, $COMMAND_SET_SAVEAS,  \&onCommand);
	EVT_MENU($this, $COMMAND_SET_REVERT,  \&onCommand);
	EVT_MENU($this, $COMMAND_SET_CLOSE,   \&onCommand);
	EVT_MENU($this, $COMMAND_NEW_REGION,  \&onCommand);

	# A MENU ITEM ANSWERS FOR ITSELF rather than being switched on and off
	# by whatever last changed the state.  There is no list of places that
	# have to remember to update the menus, and no way for one of them to
	# be missed.

	EVT_UPDATE_UI($this, $COMMAND_SET_SAVE,   \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_SET_SAVEAS, \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_SET_REVERT, \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_SET_CLOSE,  \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_NEW_REGION, \&onUpdateUI);

	$this->{shown_title} = '';
	$this->{title_timer} = Wx::Timer->new($this,-1);
	Wx::Event::EVT_TIMER($this,-1,\&onTimer);
	$this->{title_timer}->Start(500);

	$this->showDocument();
	return $this;
}


#---------------------------------------------
# the document
#---------------------------------------------

sub showDocument
	# THE TITLE BAR IS WHERE A DOCUMENT SAYS WHAT IT IS, and the asterisk
	# is where it says it has not been saved.  Both are read constantly and
	# neither is worth a click to find out.
{
	my ($this) = @_;
	my $title = $$resources{app_title};
	if (setIsOpen())
	{
		$title .= '  -  '.openSetName().(isSetDirty() ? ' *' : '');
	}
	else
	{
		$title .= '  -  no region set open';
	}
	return if $title eq $this->{shown_title};
	$this->{shown_title} = $title;
	$this->SetTitle($title);
}


sub onTimer
	# The document changes from the console and from the browser as well as
	# from this menu bar, so the title follows the same poll every other
	# surface does rather than being told by whoever happened to change it.
	#
	# AN EDIT OUTLIVES THE BROWSER THAT WAS DOING IT unless somebody
	# notices, and only a timer can notice a silence.  A map that has
	# stopped polling is holding nothing, so the state that says otherwise
	# is cleared - which is what stops the tree refusing a delete on
	# account of an edit in a window that was closed an hour ago.
{
	my ($this,$event) = @_;

	clearEditState()
		if !mapIsOpen() && getEditState()->{mode} ne $EDIT_BROWSE;

	$this->showDocument();
}


sub okToDiscard
	# THE ONE PLACE THAT ASKS.  Every path that would lose unsaved work -
	# Open, New, Close, closing the Regions pane, quitting - comes through
	# here, so the question is worded once and cannot be forgotten by one
	# of them.
	#
	# Returns 1 to go ahead, 0 to abandon what the caller was doing.
{
	my ($this,$why) = @_;

	# TWO KINDS OF UNSAVED WORK, and they are not the same thing.  The
	# document holds changes that are staged and not written; the MAP may
	# be holding geometry that is not even in the document.  A prompt that
	# mentioned only the first would be true and still misleading.
	#
	# The second cannot be saved from here - only the map can finish an
	# edit - so it is reported rather than offered.  Nothing is disabled:
	# the user is told what they are about to lose and decides.

	my $busy = editInProgress();
	my $dirt = setIsOpen() && isSetDirty();
	return 1 if !$busy && !$dirt;

	my $text = '';
	$text .= "'".openSetName()."' has changes that have not been saved.\n"
		if $dirt;
	$text .= ucfirst($busy).", and it will be discarded.\n" if $busy;
	$text .= "\n".($dirt ? "Save the set before $why?" : "$why anyway?");

	my $flags = $dirt ? (wxYES_NO | wxCANCEL) : (wxYES_NO);
	my $dlg = Wx::MessageDialog->new($this,$text,
		$$resources{app_title},$flags | wxICON_EXCLAMATION);
	my $answer = $dlg->ShowModal();
	$dlg->Destroy();

	return 0 if $answer == wxID_CANCEL;
	return 0 if !$dirt && $answer != wxID_YES;
	return 1 if $answer == wxID_NO;
	return $dirt ? $this->saveDocument() : 1;
}


sub saveDocument
{
	my ($this) = @_;
	return 0 if !setIsOpen();
	if (!saveSet())
	{
		Wx::MessageBox("'".openSetName()."' could not be saved.\n\n".
			"See the log for what stopped it.",
			$$resources{app_title},wxOK | wxICON_ERROR,$this);
		return 0;
	}
	bumpState("set '".openSetName()."' saved");
	$this->showDocument();
	return 1;
}


sub openDocument
	# Opening a set opens its window: the pane is the view of the document,
	# so having one without the other is a state with nothing to say.
{
	my ($this,$name) = @_;

	# THE MAP IS TOLD FIRST, by the only channel there is: the published
	# mode.  An applet holding a polygon for an object in the set being
	# closed obeys browse on its next poll and lets it go - which is the
	# same path it takes when the application disappears entirely.

	clearEditState();

	setActiveSet($name);
	openSet($name);
	bumpState("set '$name' opened");

	my $pane = $this->findPane($WIN_REGIONS);
	$this->createPane($WIN_REGIONS) if !$pane;
	$this->showDocument();
}


sub closeDocument
{
	my ($this) = @_;
	my $was = openSetName();
	clearEditState();
	closeSet();
	bumpState("set '$was' closed");
	$this->showDocument();
}


#---------------------------------------------
# panes
#---------------------------------------------

sub createPane
	# Pub::WX::FrameBase calls this to instantiate a pane by id, both
	# from the View menu and when restoring the previous session.
{
	my ($this,$id,$book,$data) = @_;
	return error("no id in createPane()") if !$id;
	$book ||= $this->{book};
	display($dbg_frame+1,0,"w_frame::createPane($id)");

	return winRegions->new($this,$book,$id,$data) if $id == $WIN_REGIONS;
	return winSources->new($this,$book,$id,$data) if $id == $WIN_SOURCES;

	return $this->SUPER::createPane($id,$book,$data);
}


sub saveState
	# AFTER the base class, not before, and this is not a style choice.
	# Pub::WX::Frame::saveState() begins by calling clearConfigFile(),
	# which empties the whole config -- anything written during the session
	# would be erased by the act of saving.  So the selections are written
	# once the frame has rewritten its own state, and the file is saved a
	# second time to take them.
{
	my ($this) = @_;
	$this->SUPER::saveState();
	writeIniSelections();
	Pub::WX::AppConfig::save();
}


#---------------------------------------------
# commands
#---------------------------------------------

sub _chooseSet
	# Which set, from the folders that exist.  A list rather than a file
	# dialog: a set is a folder in one known place, and browsing the disk
	# for it would offer to open things that are not sets.
{
	my ($this,$title) = @_;
	my @names = getSetNames();
	if (!@names)
	{
		Wx::MessageBox("There are no region sets in\n\n".regionSetsDir().
			"\n\nUse New Set to make one.",
			$$resources{app_title},wxOK | wxICON_INFORMATION,$this);
		return '';
	}
	# THE COMPARISON IS PARENTHESISED, and it has to be: wxID_OK is an
	# imported sub, so Perl reads the ? that follows a bare one as the
	# start of a ?PATTERN? match and the whole line stops making sense.

	my $dlg = Wx::SingleChoiceDialog->new($this,'Region set:',$title,\@names);
	my $name = ($dlg->ShowModal() == wxID_OK) ?
		$names[$dlg->GetSelection()] : '';
	$dlg->Destroy();
	return $name;
}


sub _askName
	# A set name is a folder name, so the rule it has to keep is the
	# folder's, and it is said before the attempt rather than after.
{
	my ($this,$title) = @_;
	while (1)
	{
		my $dlg = Wx::TextEntryDialog->new($this,
			"Name (letters and digits only):",$title,'');
		my $name = ($dlg->ShowModal() == wxID_OK) ? $dlg->GetValue() : '';
		$dlg->Destroy();
		return '' if $name !~ /\S/;

		$name =~ s/^\s+|\s+$//g;
		return $name if $name =~ /^[A-Za-z0-9]+$/ && !setExists($name);

		Wx::MessageBox($name !~ /^[A-Za-z0-9]+$/ ?
			"'$name' is not a usable set name - letters and digits only." :
			"There is already a set named '$name'.",
			$$resources{app_title},wxOK | wxICON_EXCLAMATION,$this);
	}
}


sub onCommand
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	display($dbg_frame+1,0,"w_frame::onCommand($id)");

	if ($id == $COMMAND_OPEN_MAP)
	{
		openMapBrowser();
	}
	elsif ($id == $WIN_REGIONS || $id == $WIN_SOURCES)
	{
		# One instance each.  Bring the existing one forward rather than
		# opening a second view of the same thing.

		my $pane = $this->findPane($id);
		$this->createPane($id) if !$pane;
	}
	elsif ($id == $COMMAND_SET_OPEN)
	{
		return if !$this->okToDiscard('opening another set');
		my $name = $this->_chooseSet('Open Region Set');
		$this->openDocument($name) if $name;
	}
	elsif ($id == $COMMAND_SET_NEW)
	{
		return if !$this->okToDiscard('creating a new set');
		my $name = $this->_askName('New Region Set');
		return if !$name;
		return if !newSet($name);
		$this->openDocument($name);
	}
	elsif ($id == $COMMAND_SET_SAVE)
	{
		$this->saveDocument();
	}
	elsif ($id == $COMMAND_SET_SAVEAS)
	{
		my $name = $this->_askName('Save Region Set As');
		return if !$name;
		if (!saveSetAs($name))
		{
			Wx::MessageBox("Could not save as '$name' - see the log.",
				$$resources{app_title},wxOK | wxICON_ERROR,$this);
			return;
		}
		setActiveSet($name);
		bumpState("set saved as '$name'");
		$this->showDocument();
	}
	elsif ($id == $COMMAND_SET_REVERT)
	{
		# NOT the same question as okToDiscard.  That one offers to save,
		# because what follows it is something the user asked for and the
		# loss is incidental.  Losing the work IS this command, so it asks
		# once, plainly, and offers nothing else.

		my $busy = editInProgress();
		my $dlg = Wx::MessageDialog->new($this,
			"Throw away every unsaved change to '".openSetName()."'\n".
			"and re-read the folder?".
			($busy ? "\n\n".ucfirst($busy).", and it will be discarded." : ''),
			$$resources{app_title},wxYES_NO | wxICON_EXCLAMATION);
		my $answer = $dlg->ShowModal();
		$dlg->Destroy();
		return if $answer != wxID_YES;

		clearEditState();
		revertSet();
		bumpState("set reverted");
		$this->showDocument();
	}
	elsif ($id == $COMMAND_SET_CLOSE)
	{
		return if !$this->okToDiscard('closing it');
		$this->closeDocument();
	}
	elsif ($id == $COMMAND_NEW_REGION)
	{
		my $pane = $this->findPane($WIN_REGIONS);
		$pane->newRegionDialog() if $pane;
	}
}


sub onUpdateUI
{
	my ($this,$event) = @_;
	my $id = $event->GetId();

	if ($id == $COMMAND_NEW_REGION)
	{
		# A region needs a set to go in and a window to appear in, and the
		# window has to be the one in front - a menu that acts on something
		# out of sight is a menu that acts by surprise.

		my $pane = $this->findPane($WIN_REGIONS);
		$event->Enable(setIsOpen() && $pane && $pane->IsShown() ? 1 : 0);
		return;
	}
	if ($id == $COMMAND_SET_SAVE || $id == $COMMAND_SET_REVERT)
	{
		# Both act on unsaved changes, so with none there is nothing for
		# either of them to do.

		$event->Enable(setIsOpen() && isSetDirty() ? 1 : 0);
		return;
	}
	$event->Enable(setIsOpen() ? 1 : 0);
}


1;
