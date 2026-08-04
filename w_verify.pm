#!/usr/bin/perl
#---------------------------------------------
# w_verify.pm
#---------------------------------------------
# WHAT THE SERVICE SAID, as a dialog.
#
# THE HEADLINE IS THE WHOLE POINT OF IT BEING MODAL.  Somebody pressing
# Test wants one answer before they want any detail, and the detail of a
# working source and a broken one look alike at a glance: both are a column
# of levels with numbers beside them.  So the verdict is said in words, in
# bold, above everything, and it is the first thing read.
#
# THREE OUTCOMES AND NOT TWO, which is the whole reason this is not a
# message box:
#
#	IT WORKS         a tile arrived where this service should have imagery
#	NOTHING PROVED   it answered, and little was settled - the honest
#	                 result for a service that publishes no metadata and
#	                 has no canonical point, and NOT a pass
#	PROBLEMS         something was disproved, and here is what
#
# THE REFUTED FIELDS ARE LISTED HERE AS WELL AS PAINTED IN THE EDITOR.  The
# editor is not always there: the catalog tests an entry that has never been
# written to disk, and a list of colours nobody can see is not a report.  So
# the dialog names the fields and says where they are fixed.
#
# THE TEXT IS NOT COMPOSED HERE.  dm_verify::verifyLines renders it, the
# console prints the same lines, and a headless test reads them.  One
# rendering, three surfaces, nothing to drift.

package w_verify;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON );
use Pub::Utils;
use cm_defs;
use dm_verify;
use base qw(Wx::Dialog);


my $ID_OK = 8821;

my $GREEN = Wx::Colour->new(0,120,0);
my $RED   = Wx::Colour->new(200,0,0);
my $BLACK = Wx::Colour->new(0,0,0);


sub show
	# The whole of the interface.  $out is what dm_verify::verifySource
	# returned.
{
	my ($class,$parent,$out) = @_;

	my %title = (
		verified  => 'Test - it works',
		unrefuted => 'Test - nothing disproved',
		problems  => 'Test - problems found',
		cancelled => 'Test - stopped',
	);
	my $verdict = $out->{verdict} || 'problems';

	my $this = $class->SUPER::new($parent,-1,
		$title{$verdict} || 'Test',[-1,-1],[640,520]);

	# COLOUR FOLLOWS THE VERDICT AND THE WORDS SAY IT TOO.  A dialog that
	# distinguished its three outcomes by colour alone would say nothing
	# at all to somebody who cannot tell the two apart.

	my %col = (
		verified  => $GREEN,
		unrefuted => $BLACK,
		problems  => $RED,
		cancelled => $BLACK,
	);

	my $head = Wx::StaticText->new($this,-1,verifyHeadline($out),
		[16,12],[600,22]);
	my $font = $head->GetFont();
	$font->SetWeight(wxFONTWEIGHT_BOLD);
	$font->SetPointSize($font->GetPointSize() + 2);
	$head->SetFont($font);
	$head->SetForegroundColour($col{$verdict} || $BLACK);

	# READ ONLY, MONOSPACED, AND IT DOES NOT WRAP.  The levels are a column
	# layout built with sprintf, and a proportional font turns them back
	# into a ragged list.  Selectable because the fingerprint offer at the
	# bottom is a line somebody pastes into a file.

	my $text = Wx::TextCtrl->new($this,-1,
		join("\n",@{verifyLines($out)}),[16,44],[600,392],
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);

	$text->SetFont(Wx::Font->new(9,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	my $ok = Wx::Button->new($this,$ID_OK,'OK',[520,446],[96,26]);
	EVT_BUTTON($this,$ID_OK,sub { $_[0]->EndModal(wxID_OK) });

	$ok->SetFocus();
	$this->ShowModal();
	$this->Destroy();
}


1;
