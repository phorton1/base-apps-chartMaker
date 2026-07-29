#!/usr/bin/perl
#---------------------------------------------
# w_frame.pm
#---------------------------------------------
# The chartMaker application frame.
#
# Pub::WX::FrameBase invariantly creates the content notebook, so an
# application with no panes comes up as an empty notebook under the menu
# bar.  There are no panes yet.

package w_frame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_MENU);
use Pub::Utils;
use Pub::WX::Frame;
use Pub::WX::AppConfig;
use cm_defs;
use cm_utils;
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

	EVT_MENU($this, $COMMAND_OPEN_MAP, \&onCommand);
	EVT_MENU($this, $WIN_REGIONS,     \&onCommand);
	EVT_MENU($this, $WIN_SOURCES,     \&onCommand);

	return $this;
}


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
}


1;
