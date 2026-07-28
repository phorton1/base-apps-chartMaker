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
use cm_defs;
use cm_utils;
use w_resources;
use base qw(Pub::WX::Frame);


our $dbg_frame:shared = 0;	# 0=wip; -1=menu commands


sub new
{
	my ($class,$parent) = @_;
	my $rect = Wx::Rect->new(200,100,1100,800);

	Pub::WX::Frame::setHowRestore($Pub::WX::Frame::RESTORE_MAIN_RECT);

	my $this = $class->SUPER::new($parent,$rect);

	EVT_MENU($this, $COMMAND_OPEN_MAP, \&onCommand);

	return $this;
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
}


1;
