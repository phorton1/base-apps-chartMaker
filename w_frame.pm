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
use cm_prefs;
use cm_state;
use cm_utils;
use cm_config;
use em_server;
use dm_set;
use dm_source;
use dm_region;
use dm_fill;
use dm_analysis;
use dm_build;
use dm_sample;
use w_resources;
use w_ini;
use w_keys;
use w_clean;
use w_restore;
use w_prefs;
use w_progress;
use w_probe;
use w_probecfg;
use w_report;
use w_blank;
use w_buildcfg;
use w_preflight;
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
	EVT_MENU($this, $COMMAND_NEW_SOURCE,  \&onCommand);
	EVT_MENU($this, $COMMAND_CATALOG,     \&onCommand);
	EVT_MENU($this, $COMMAND_KEYS,        \&onCommand);
	EVT_MENU($this, $COMMAND_CLEAN,       \&onCommand);
	EVT_MENU($this, $COMMAND_PREFS,       \&onCommand);
	EVT_MENU($this, $COMMAND_FETCH,       \&onCommand);
	EVT_MENU($this, $COMMAND_BUILD_RCT,   \&onCommand);
	EVT_MENU($this, $COMMAND_BUILD_MBTILES, \&onCommand);
	EVT_MENU($this, $COMMAND_HELP_MANUAL,   \&onCommand);
	EVT_MENU($this, $COMMAND_REGEN_EXAMPLES,\&onCommand);
	EVT_MENU($this, $COMMAND_ABOUT,         \&onCommand);

	# A MENU ITEM ANSWERS FOR ITSELF rather than being switched on and off
	# by whatever last changed the state.  There is no list of places that
	# have to remember to update the menus, and no way for one of them to
	# be missed.

	EVT_UPDATE_UI($this, $COMMAND_SET_SAVE,   \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_SET_SAVEAS, \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_SET_REVERT, \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_SET_CLOSE,  \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_NEW_REGION, \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_FETCH,      \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_BUILD_RCT,  \&onUpdateUI);
	EVT_UPDATE_UI($this, $COMMAND_BUILD_MBTILES, \&onUpdateUI);

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

	# COVERAGE MODE IS ENTERED FROM THE CONSOLE TOO, and the argument above
	# applies to it unchanged.  em_command cannot open the pane itself -
	# a worker thread touching a wx window is the one thing that reliably
	# takes this application down - so wx notices the mode the way it
	# notices everything else, by polling for it.
	#
	# WITHOUT THIS, 'sample' TYPED AT THE CONSOLE PUTS THE APPLICATION IN A
	# MODE NOTHING CAN LEAVE: the marks are on the map, the mode is on, and
	# the only surface carrying an off switch never opened.  That is not a
	# missing convenience, it is a state with no exit.

	$this->createPane($WIN_PROBE)
		if probeIsOn() && !$this->findPane($WIN_PROBE);

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
	return w_probe->new($this,$book,$id,$data)    if $id == $WIN_PROBE;

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


#---------------------------------------------
# the long acts
#---------------------------------------------
# FETCH AND BUILD ARE THE SAME MACHINERY, and building it twice is how the
# two end up behaving differently.  One worker launcher, one dialog, one
# report; the two entry points differ only in which function the worker
# calls and what the report says.
#
# THE WORKER IS A DETACHED THREAD carrying a shared record, which is the
# pattern Pub::Ray::NET::f_CFWRITE already uses from navMate's GUI.  It is
# spawned from the main thread AFTER wx exists, unlike the server and
# console threads which are spawned before it -- that is the one thing
# here without a precedent inside this application, and f_CFWRITE is the
# precedent outside it.
#
# NOTHING WX CROSSES INTO THE WORKER.  It is handed a shared hash and the
# ids to work on, and it touches the model, the cache and the filesystem
# and nothing else.  Everything it wants to say comes back as text in the
# record -- see cm_utils::newProgress on why the report is rendered on the
# worker rather than shipped back as a structure.

sub _buildWorker
	# Runs on the worker thread.  Everything it can say has to fit in the
	# shared record, so it says it the same way the console does.
{
	my ($prog,$ids,$opts) = @_;

	my $report = buildOutput($ids,{ %$opts, progress => $prog },
		$opts->{format} || 'rct');

	$prog->{ok}    = $report->{ok} ? 1 : 0;
	$prog->{guard} = $report->{guard} // '';
	push @{$prog->{lines}},@{buildReportLines($report)};

	# LAST, AND ON ITS OWN.  The dialog stops the moment it sees this, so
	# anything written after it might never be read.

	$prog->{finished} = 1;
}


sub _fetchWorker
{
	my ($prog,$ids,$opts) = @_;

	my $stats = fillCoverage($ids,{ %$opts, progress => $prog });

	# FETCH REFUSES NOTHING, because it writes no output.  A tile that never
	# arrived is worth reporting and is not a failure of this act -- the
	# whole point of a separate Fetch is to chip away at a big region over
	# several sessions, and errors are never cached, so running it again
	# is the retry.

	my @lines;
	push @lines,$stats->{cancelled} ?
		"Stopped." : "Finished.";
	push @lines,'';
	push @lines,sprintf("  %-22s %d",'tiles walked',$stats->{tiles});
	push @lines,sprintf("  %-22s %d",'fetched',$stats->{tiles} - $stats->{cached});
	push @lines,sprintf("  %-22s %d",'already cached',$stats->{cached});
	push @lines,sprintf("  %-22s %d",'absent at the source',$stats->{absent} || 0);
	push @lines,sprintf("  %-22s %d",'failed',$stats->{error} || 0);
	push @lines,sprintf("  %-22s %.0fs",'took',$stats->{secs});

	if ($stats->{aborted})
	{
		push @lines,'';
		push @lines,"GAVE UP - the source stopped answering.";
		push @lines,"Nothing was cached as missing, so fixing the source";
		push @lines,"and running this again resumes where it stopped.";
	}
	elsif ($stats->{error})
	{
		push @lines,'';
		push @lines,"$stats->{error} tile(s) never arrived.  Errors are never";
		push @lines,"cached, so running this again retries exactly those.";

		# A COUNT FIRST, NEVER A COMPUTED SLICE.  @list[0..9] on a list of
		# three yields three values and seven undefs, and the list is
		# short exactly when something has gone wrong - so the naive
		# version fails only in the case it exists to serve.

		my @failed = @{$stats->{failed_tiles} || []};
		my $show = @failed > 10 ? 10 : scalar(@failed);
		if ($show)
		{
			push @lines,'';
			push @lines,@failed[0..$show-1];
			push @lines,"... and ".($stats->{error} - $show)." more"
				if $stats->{error} > $show;
		}
	}

	$prog->{ok} = ($stats->{aborted} || $stats->{error}) ? 0 : 1;
	push @{$prog->{lines}},@lines;
	$prog->{finished} = 1;
}


sub runLongAct
	# Launch one, watch it, and show what it did.  Returns nothing; the
	# report is the outcome.
{
	my ($this,$what,$fn,$ids,$opts) = @_;

	my $prog = w_progress->runWorker($this,$what,$fn,$ids,$opts);

	# THE WORKER MAY STILL BE FINISHING.  run() returns when {finished} is
	# set, so by here it is done -- but a cancel returns as soon as the
	# worker acknowledges, and it sets {finished} last, so this is not a
	# race: there is nothing to wait for that has not already happened.

	my $outcome = $prog->{cancelled} && !$prog->{ok} ? 'cancelled' :
				  $prog->{ok} ? 'built' : 'refused';

	w_report->show($this,$outcome,[ @{$prog->{lines}} ]);

	# AND THEN WHAT THE ACT TAUGHT, AFTER the report rather than inside it.
	# The report is what the user asked for; a candidate blank is a separate
	# question this act happened to be able to raise, and stacking it into
	# the report would bury the report.
	#
	# EVERY INSTALLED SOURCE IS ASKED ABOUT, not only the ones this act
	# touched.  A candidate is a fact about a service rather than about a
	# run, and one learned earlier and never shown is still worth showing.
	# Nothing repeats: a decline is remembered, and a declared fingerprint
	# stops being a candidate.

	w_blank->offerFor($this,[ map { getSource($_) } getSourceIds() ]);
}


sub onCommand
{
	my ($this,$event) = @_;
	my $id = $event->GetId();
	display($dbg_frame+1,0,"w_frame::onCommand($id)");

	if ($id == $COMMAND_OPEN_MAP)
	{
		# THE MAP CANNOT OPEN WITHOUT THE SERVER, and saying so here is
		# what stops a dismissed startup warning from turning into a menu
		# item that silently does nothing.  A warning nobody can act on is
		# how a real warning gets trained out of being read.

		if (!em_server::serverOk())
		{
			my $port = getPref($PREF_HTTP_PORT);
			my $dlg = Wx::MessageDialog->new($this,
				"The map is served by $appName itself, and the http ".
				"server is not running - port $port could not be opened ".
				"at startup.\n\n".
				"The port can be changed in Preferences, and takes effect ".
				"on the next start.",
				"No map",
				wxOK | wxICON_EXCLAMATION);
			$dlg->ShowModal();
			$dlg->Destroy();
			return;
		}
		openMapBrowser();
	}
	elsif ($id == $COMMAND_PREFS)
	{
		# Modal, and nothing is asked of the model.  Every folder change
		# is deferred to the next start, so there is no open document to
		# reconcile and nothing here can fail halfway.

		my $dlg = w_prefs->new($this);
		$dlg->ShowModal();
		$dlg->Destroy();
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
	elsif ($id == $COMMAND_NEW_SOURCE)
	{
		# THE PANE IS OPENED IF IT IS NOT ALREADY, because a new source has
		# to appear somewhere the moment it is written, and a first run has
		# no reason to have visited the Sources pane yet.

		my $pane = $this->findPane($WIN_SOURCES);
		$pane = $this->createPane($WIN_SOURCES) if !$pane;
		$pane->newSource() if $pane;
	}
	elsif ($id == $COMMAND_CATALOG)
	{
		# THROUGH THE PANE, for the reason New Source goes through it:
		# whatever the catalog writes has to appear somewhere the moment
		# it exists, and the pane is what refreshes itself around it.

		my $pane = $this->findPane($WIN_SOURCES);
		$pane = $this->createPane($WIN_SOURCES) if !$pane;
		$pane->catalogDialog() if $pane;
	}
	elsif ($id == $COMMAND_KEYS)
	{
		# NOT THROUGH THE PANE.  The catalog and New Source go through it
		# because they WRITE FILES the pane has to show; this writes no
		# file and creates no source.  What it changes is whether sources
		# that already exist can fetch, so the pane is refreshed after
		# rather than being the thing that opened the dialog.

		w_keys->show($this);

		my $pane = $this->findPane($WIN_SOURCES);
		$pane->populate() if $pane && $pane->can('populate');
	}
	elsif ($id == $COMMAND_CLEAN)
	{
		# NOT THROUGH THE PANE EITHER, and for a reason of its own: the
		# cleanup may delete .tsd files, so the pane has to catch up
		# afterwards - but it must also be reachable with no Sources pane
		# open at all.  It bumps the state counter itself, which is what
		# every pane already watches, so there is nothing to do here.

		w_clean->show($this,{});
	}
	elsif ($id == $COMMAND_FETCH || $id == $COMMAND_BUILD_RCT ||
		   $id == $COMMAND_BUILD_MBTILES)
	{
		$this->onLongAct($id);
	}
	elsif ($id == $COMMAND_HELP_MANUAL)
	{
		Wx::LaunchDefaultBrowser($USER_MANUAL_URL);
	}
	elsif ($id == $COMMAND_REGEN_EXAMPLES)
	{
		# IT DOES NOT CARE WHETHER A SET IS OPEN, and it must not touch
		# one.  Restoring writes files; what the open document holds is
		# the user's, possibly unsaved, and File - Open Set is how they
		# choose to go and look at what came back.

		w_restore->show($this);
	}
	elsif ($id == $COMMAND_ABOUT)
	{
		$this->_doAbout();
	}
}


sub _appVersion
	# CAVA STAMPS A VERSION INTO A PACKAGED BUILD and there is none in a
	# development one, so it says 'dev' rather than inventing a number.
	# That word in an About box is the one honest way to tell the two
	# builds apart on screen.
{
	my $ver = '';
	eval { $ver = Cava::Packager::GetAppVersion() }
		if $Cava::Packager::PACKAGED;
	return $ver ? $ver : "$appVersion (dev)";
}


sub _doAbout
	# A small modal: the name, the version, one line about what this is,
	# the project link, and the notice that governs everything it builds.
{
	my ($this) = @_;

	my $dlg = Wx::Dialog->new($this,-1,"About $appName",
		wxDefaultPosition,wxDefaultSize,wxDEFAULT_DIALOG_STYLE);

	# SetClientSize, NOT a size passed to the constructor.  Everything
	# below is positioned in CLIENT coordinates, and a constructor size is
	# the WINDOW - so the title bar and the borders came off the bottom and
	# took the OK button with them.  Asking for the client area states what
	# is actually meant and does not depend on guessing the chrome.

	$dlg->SetClientSize(470,266);

	my $title_font = Wx::Font->new(14,wxFONTFAMILY_DEFAULT,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);
	my $name = Wx::StaticText->new($dlg,-1,$appName,[20,18]);
	$name->SetFont($title_font);

	Wx::StaticText->new($dlg,-1,'Version: '._appVersion(),[20,52]);
	Wx::StaticText->new($dlg,-1,
		'Offline satellite chartsets for OpenCPN and Raymarine E-Series '.
		'plotters.',[20,80],[420,36]);

	Wx::HyperlinkCtrl->new($dlg,-1,$REPO_URL,$REPO_URL,[20,124]);
	Wx::StaticText->new($dlg,-1,'Copyright (c) 2026 Patrick Horton',[20,150]);

	# THE NOTICE BELONGS HERE.  A chartset is a photograph rather than a
	# chart, and the About box is the one place in the application that is
	# about the application rather than about the work.

	Wx::StaticText->new($dlg,-1,
		'Chartsets built with this program are an aid to navigation only, '.
		'never a substitute for official charts. See NOTICE_TO_MARINERS.txt.',
		[20,178],[420,44]);

	my $ok = Wx::Button->new($dlg,wxID_OK,'OK',[370,222],[80,28]);
	$ok->SetDefault();

	$dlg->ShowModal();
	$dlg->Destroy();
}


sub onLongAct
	# THE TWO-DIALOG PREFLIGHT.
	#
	#	1  what and where   - w_buildcfg, persisted on OK
	#	2  what it costs    - w_preflight, and the only place anything is
	#	                      confirmed
	#	   the work
	#
	# NOTHING IS ASKED AFTER THE WORK STARTS.  Every question a user could
	# be asked - unsaved edits, overwriting files, a chartset that would
	# disagree with itself - is answered before the first request goes out,
	# because a confirmation dialog at the end of a three hour fetch is one
	# nobody is sitting there to answer.
	#
	# Back returns to dialog one with the selection already persisted, so
	# the loop costs nothing and loses nothing.
{
	# THREE MODES, NOT A BOOLEAN, and the third is what turned the boolean
	# into a liar.  'is_build' used to mean four different things at once -
	# writes something, has an output folder, may overwrite a file, needs
	# the chartset to agree - and they stopped being the same question the
	# moment a second output existed.  So:
	#
	#	$what     which act this is: fetch, build (rct), or mbtiles
	#	$writes   it produces files, so it has a destination to show
	#	$is_rct   the output is .rct, so the chartset rules apply
	#
	# Only $is_rct gates the .rct-shaped questions, and that is the whole
	# of what an mbtiles build skips.

	my ($this,$id) = @_;

	my $what =
		$id == $COMMAND_BUILD_RCT		? 'build'	:
		$id == $COMMAND_BUILD_MBTILES	? 'mbtiles'	: 'fetch';
	my $writes   = ($what ne 'fetch');
	my $is_rct  = ($what eq 'build');
	my $is_build = $writes;

	my $verb = $writes ? 'build' : 'fetch';

	if (!getRegionIds())
	{
		Wx::MessageBox("There is nothing in '".openSetName()."' to $verb.",
			$$resources{app_title},wxOK | wxICON_INFORMATION,$this);
		return;
	}

	my $fallback = getDefaultSource();
	if (!$fallback)
	{
		Wx::MessageBox("No source is selected.\n\n".
			"Choose one in the Sources window first - it is what a region ".
			"that inherits its source resolves to.",
			$$resources{app_title},wxOK | wxICON_EXCLAMATION,$this);
		return;
	}

	# THE DIRTY QUESTION COMES FIRST, before anything is configured or
	# analysed: saving changes the model, and an analysis of the old one
	# would be stale before it was read.  On this surface there IS somebody
	# to ask, so it asks - dm_build still enforces it either way.

	my $allow_dirty = 0;
	if ($is_build && isSetDirty())
	{
		my $dlg = Wx::MessageDialog->new($this,
			"'".openSetName()."' has unsaved changes.\n\n".
			"A file built from edits that are not on disk cannot be rebuilt ".
			"from the set that is supposed to define it.\n\n".
			"Save it first?",
			$$resources{app_title},wxYES_NO | wxCANCEL | wxICON_EXCLAMATION);
		my $answer = $dlg->ShowModal();
		$dlg->Destroy();

		return if $answer == wxID_CANCEL;
		if ($answer == wxID_YES)
		{
			return if !$this->saveDocument();
		}
		else
		{
			$allow_dirty = 1;
		}
	}

	while (1)
	{
		my $cfg_dlg = w_buildcfg->new($this,$what);
		my $rslt = $cfg_dlg->ShowModal();
		my $chosen = $cfg_dlg->result();
		$cfg_dlg->Destroy();
		return if $rslt != wxID_OK || !$chosen;

		my $cfg = $chosen->{cfg};
		my $ids = $chosen->{ids};

		# THE BLANKS FIRST, BEFORE ANYTHING IS COUNTED OR FETCHED.
		#
		# This dialog chain's own rule is that everything is asked before the
		# work starts, and a candidate blank belongs to it: a fingerprint
		# declared here removes those tiles from the fetch and from the
		# output, and one declared afterwards removes them from the NEXT
		# build while this one carries them.  IGN over Guadeloupe is the
		# case that showed it - a solid white fill and a solid navy sea fill
		# across a large part of the region, and a build of 21,511 tiles
		# that would have stored every one of them as imagery.
		#
		# BEFORE THE ANALYSIS AND NOT BETWEEN IT AND THE PREFLIGHT.
		# Declaring a fingerprint reclassifies what is already on disk - see
		# dm_fetch::fetchCacheHit - so the cached and to-fetch counts change
		# underneath it, and the preflight's whole job is to be the true
		# statement of what the run will cost.
		#
		# EVERY INSTALLED SOURCE, for the reason the end-of-run offer gives:
		# a candidate is a fact about a service rather than about this act,
		# and one learned by an earlier probe and never shown is exactly the
		# one worth showing now.  Nothing repeats - a decline is remembered
		# and a declared fingerprint stops being a candidate - so the
		# ordinary case is that this asks nothing and costs a hash lookup
		# per source.
		#
		# THE OFFER AT THE END OF THE RUN STAYS.  A build fetches thousands
		# of tiles and is the richest teacher of these there is, and what it
		# learns has nowhere else to be put in front of anybody.

		w_blank->offerFor($this,[ map { getSource($_) } getSourceIds() ]);

		# TWO DIFFERENT THINGS, and conflating them was a real bug.
		#
		#   $out_dir  the RESOLVED path - for showing, and for surveying
		#             what is already in it
		#   $cfg->{out_dir}  the CHOICE - empty means "the default"
		#
		# Only the choice may go to dm_build.  It distinguishes a default
		# folder, which it creates as needed, from a nominated one, which
		# must already exist - so handing it the resolved default made
		# every default-folder build refuse the first time, on the one
		# path a user is most likely to take.

		# MBTILES HAS ONE PLACE IT GOES and the configuration says nothing
		# about it - see cm_config::defaultMbtilesOutDir.  So this is the
		# resolved path for SHOWING, and there is no choice to pass on.

		my $out_dir =
			$is_rct	? ($cfg->{out_dir} || defaultOutDir())	:
			$writes		? defaultMbtilesOutDir()				: '';

		# THE ANALYSIS IS A PURE READ and takes about a tenth of a second,
		# so it happens between the two dialogs with nothing to look at in
		# between.  A busy cursor rather than a progress bar: anything that
		# needs a progress bar to report its own progress does not belong
		# in front of a dialog.

		my $busy = Wx::BusyCursor->new();
		my $an = analyseFetch($ids,{
			fallback => $fallback,
			config   => $cfg,
			format   => ($is_rct ? 'rct' : 'mbtiles'),
			$writes ? ( out_dir => $out_dir ) : (),
		});
		undef $busy;

		my $pre = w_preflight->new($this,$what,$an,$out_dir);
		my $go = $pre->ShowModal();
		$pre->Destroy();

		next   if $go == wxID_BACKWARD;
		return if $go != wxID_OK;

		my $opts = {
			fallback => $fallback,
			config   => $cfg,
			allow_dirty => $allow_dirty,
			format   => ($is_rct ? 'rct' : 'mbtiles'),
			$is_rct ? ( out_dir => $cfg->{out_dir} ) : (),
		};

		return $this->runLongAct(
			$what eq 'build'	? 'Building RCT'	:
			$what eq 'mbtiles'	? 'Building MBTiles'	: 'Fetching Tiles',
			$writes ? \&_buildWorker : \&_fetchWorker,
			$ids,$opts);
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
	if ($id == $COMMAND_FETCH || $id == $COMMAND_BUILD_RCT ||
		$id == $COMMAND_BUILD_MBTILES)
	{
		# A set with regions in it, and a source for the ones that inherit.
		# Both acts read the cache through a source, so neither has
		# anything to do without one.

		$event->Enable(setIsOpen() && getRegionIds() && getDefaultSource()
			? 1 : 0);
		return;
	}
	$event->Enable(setIsOpen() ? 1 : 0);
}


1;
