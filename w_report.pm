#!/usr/bin/perl
#---------------------------------------------
# w_report.pm
#---------------------------------------------
# WHAT THE BUILD DID, as a dialog.
#
# THREE OUTCOMES, NOT A MESSAGE BOX SAYING DONE.  A build ends one of
# three ways and they need different things from the user:
#
#	BUILT      here is what was written, and where it is
#	REFUSED    here is what to fix, and nothing was written
#	CANCELLED  you stopped it, and nothing was written
#
# The middle one is the reason this is a dialog at all.  A refusal names a
# source, a region and a fix, and that will not fit in a caption -- and it
# is exactly the moment a user most needs to be able to read, re-read and
# copy what they are being told.
#
# THE TEXT IS NOT COMPOSED HERE.  dm_build::buildReportLines renders it,
# the console prints the same lines, and the worker put them in the shared
# record.  One rendering, three surfaces, nothing to drift.
#
# SELECTABLE AND READ ONLY.  A refusal that names four tile coordinates is
# something a user will want to paste somewhere, and a static text cannot
# be selected.

package w_report;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON );
use Pub::Utils;
use cm_defs;
use base qw(Wx::Dialog);


my $ID_OK = 8811;


sub show
	# The whole of the interface.  $outcome is 'built' | 'refused' |
	# 'cancelled', $lines is an array ref of text.
{
	my ($class,$parent,$outcome,$lines) = @_;

	my %title = (
		built		=> 'Build complete',
		refused		=> 'Build refused',
		cancelled	=> 'Build cancelled',
		cleaned		=> 'Clean up',
	);

	my $this = $class->SUPER::new($parent,-1,
		$title{$outcome} || 'Build',[-1,-1],[620,440]);

	# A HEADLINE THAT SAYS WHICH OF THE THREE IT WAS, above the detail,
	# because the detail of a refusal and the detail of a success look
	# alike at a glance and only one of them means something was written.

	# A CLEANUP HAS ITS OWN, because the other three are all about whether
	# an output file exists and it is not about that at all.  What it did
	# is a list of counts, so the headline says what kind of act it was and
	# leaves the numbers to the lines below.

	my %headline = (
		built		=> 'The .rct files were written.',
		refused		=> 'Nothing was written.',
		cancelled	=> 'Stopped. Nothing was written.',
		cleaned		=> 'What the cleanup removed.',
	);

	my $head = Wx::StaticText->new($this,-1,
		$headline{$outcome} || '',[16,12],[580,20]);

	my $font = $head->GetFont();
	$font->SetWeight(wxFONTWEIGHT_BOLD);
	$head->SetFont($font);

	# READ ONLY, MONOSPACED and multiline.  The per-region lines are a
	# column layout built with sprintf and a proportional font turns them
	# back into a ragged list.

	my $text = Wx::TextCtrl->new($this,-1,join("\n",@{$lines || []}),
		[16,40],[580,320],
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);

	$text->SetFont(Wx::Font->new(9,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $ok = Wx::Button->new($this,$ID_OK,'OK',[500,370],[96,24]);
	EVT_BUTTON($this,$ID_OK,sub { $_[0]->EndModal(wxID_OK) });

	$ok->SetFocus();
	$this->ShowModal();
	$this->Destroy();
}


1;
