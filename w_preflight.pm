#!/usr/bin/perl
#---------------------------------------------
# w_preflight.pm
#---------------------------------------------
# PREFLIGHT TWO - what it will cost, and what it will overwrite.
#
# THE LAST MOMENT BEFORE ANYTHING IRREVERSIBLE, and everything that has to
# be asked is asked HERE.  Nothing may be deferred to the end of the run:
# firing off a process that may take hours and then sitting on a
# confirmation dialog nobody is there to answer is the failure this whole
# dialog exists to prevent.
#
# It is a pure read - directories and .rct headers, no network, nothing
# written.  Measured at about 0.12 seconds for a single region against a
# 36,000 file cache, which is why it can simply appear rather than arrive
# behind a spinner.
#
# WHAT IT SHOWS, in the order it matters:
#
#	how many tiles, per SOURCE, and how long
#	whether any source declares a DISPLACEMENT
#	which cards it will REPLACE
#	which cards are in that folder and are NOT part of this build
#	whether the card would disagree with itself about zauthor / zmin
#
# The fourth is the one nobody asks for and is the more dangerous: a card
# left from an earlier set or a renamed region is still read by the
# plotter, still contributes to the pyramid, and is invisible everywhere
# else.
#
# The fifth WARNS AND DOES NOT REFUSE.  Trying a new zauthor on one
# region before converting a whole chartset is a legitimate thing to want,
# and a refusal makes it impossible.  The author decides - which is the
# same position this application takes about imagery depth.

package w_preflight;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON );
use Pub::Utils;
use cm_defs;
use cm_config;
use dm_set;
use dm_analysis;
use base qw(Wx::Dialog);


my $ID_START	= 8831;
my $ID_BACK		= 8832;
my $ID_CANCEL	= 8833;


sub new
{
	my ($class,$parent,$what,$an,$out_dir) = @_;
	$what ||= 'build';

	# $is_card gates what is true of an E-SERIES CHARTSET; $writes gates
	# what is true of anything that produces files.  They were one flag
	# until there was a second output - see w_frame::onLongAct.

	my $is_card = ($what eq 'build');
	my $writes  = ($what ne 'fetch');

	my $this = $class->SUPER::new($parent,-1,
		$writes ? 'Build - what this will cost' : 'Fetch - what this will cost',
		[-1,-1],[640,560]);

	$this->{an} = $an;

	my $y = 12;

	Wx::StaticText->new($this,-1,
		$is_card	? "Cards will be written to:"	:
		$writes		? "Charts will be written to:"	:
					  "Tiles will be fetched for:",
		[16,$y],[260,18]);
	$y += 20;

	# SAY WHEN THE FOLDER IS NOT THERE YET.  It is about to be created,
	# which is correct for the default and is exactly the moment somebody
	# should notice they are writing somewhere new.

	my $where = $writes ? $out_dir :
		sprintf("%d region(s) of '%s'",
			scalar(@{$an->{regions}}),getActiveSet() // '');
	$where .= '   (will be created)' if $writes && !-d $out_dir;

	my $wc = Wx::StaticText->new($this,-1,$where,[16,$y],[600,18]);
	my $bold = $wc->GetFont();
	$bold->SetWeight(wxFONTWEIGHT_BOLD);
	$wc->SetFont($bold);
	$y += 30;

	# ---- the numbers, monospaced because they are columns

	my $text = Wx::TextCtrl->new($this,-1,
		join("\n",@{analysisLines($an,$what)}),
		[16,$y],[600,150],
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$text->SetFont(Wx::Font->new(9,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));
	$y += 162;

	# ---- everything that wants saying before somebody commits

	my @notes = _notes($an,$is_card,$writes,$out_dir);

	my $nc = Wx::TextCtrl->new($this,-1,join("\n",@notes),
		[16,$y],[600,190],
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$nc->SetFont(Wx::Font->new(9,wxFONTFAMILY_TELETYPE,
		wxFONTSTYLE_NORMAL,wxFONTWEIGHT_NORMAL));

	# RED WHEN THERE IS SOMETHING TO SAY, and only then.  A panel that is
	# always coloured is a panel nobody reads.

	$nc->SetForegroundColour(Wx::Colour->new(170,0,0))
		if $an->{zagree} || @{$an->{overwrite}} || @{$an->{foreign}} ||
		   @{$an->{missing_src}} || @{$an->{displaced}};
	$y += 200;

	# ---- START IS NOT THE DEFAULT BUTTON.  The whole dialog exists
	# because this action was too easy to start by accident.

	my $back = Wx::Button->new($this,$ID_BACK,'< Back',[330,$y],[85,26]);
	Wx::Button->new($this,$ID_START,
		$writes ? 'Build' : 'Fetch',[423,$y],[100,26]);
	Wx::Button->new($this,$ID_CANCEL,'Cancel',[531,$y],[85,26]);

	EVT_BUTTON($this,$ID_START, sub { $_[0]->EndModal(wxID_OK) });
	EVT_BUTTON($this,$ID_BACK,  sub { $_[0]->EndModal(wxID_BACKWARD) });
	EVT_BUTTON($this,$ID_CANCEL,sub { $_[0]->EndModal(wxID_CANCEL) });

	$back->SetFocus();
	return $this;
}


sub _notes
{
	my ($an,$is_card,$writes,$out_dir) = @_;
	my @n;

	if (@{$an->{missing_src}})
	{
		push @n,"THESE SOURCES ARE NOT INSTALLED and the build will refuse:";
		push @n,"  $_" for @{$an->{missing_src}};
		push @n,'';
	}

	if (@{$an->{displaced}})
	{
		# THE FAILURE NO STRUCTURAL CHECK CAN CATCH.  The tiles are valid,
		# the grid is right, they align with each other, and they are in
		# the wrong place on the earth.  Said here because the source list
		# only tells whoever goes looking, and this is the last moment
		# before hours of fetching.  A WARNING, NOT A REFUSAL - a consumer
		# may apply its own offset and the purpose may not be navigation.

		push @n,"WARNING - displaced imagery. This build will NOT align with GPS.";
		push @n,sprintf("  %-20s %s",$_->{name},$_->{displacement})
			for @{$an->{displaced}};
		push @n,"  chartMaker records the displacement and does NOT correct it.";
		push @n,'';
	}

	if ($an->{zagree})
	{
		# THE WARNING THAT IS NOT A REFUSAL.  Stated at length because the
		# consequence is invisible: the imagery is built, it is on the
		# card, and it is never drawn.

		push @n,"WARNING - the cards on this chartset would not agree.";
		for my $field (qw( zauthor zmin ))
		{
			my $h = $an->{zagree}{$field} or next;
			push @n,"  $field:";
			push @n,"    $_ : ".join(', ',@{$h->{$_}}) for sort keys %$h;
		}
		push @n,"  The E-Series holds these on the CHARTSET, not per file, and";
		push @n,"  cuts the reveal aperture at the coarsest zauthor present. A";
		push @n,"  file finer than that is built and PERMANENTLY INVISIBLE.";
		push @n,"  This is a warning, not a refusal - build it if you mean to.";
		push @n,'';
	}

	if ($is_card && @{$an->{overwrite}})
	{
		push @n,scalar(@{$an->{overwrite}})." card(s) will be REPLACED:";
		push @n,sprintf("  %-14s  z%d-%-2d  %.1f MB",
			$_->{leaf},$_->{zoom_min},$_->{zoom_max},$_->{bytes}/1048576)
			for @{$an->{overwrite}};
		push @n,'';
	}

	if ($is_card && @{$an->{foreign}})
	{
		push @n,scalar(@{$an->{foreign}})." card(s) are in this folder and are ".
			"NOT part of this build:";
		push @n,sprintf("  %-14s  z%d-%-2d  zauthor %d",
			$_->{leaf},$_->{zoom_min},$_->{zoom_max},$_->{zauthor})
			for @{$an->{foreign}};
		push @n,"  They will be left alone - and the plotter will still read";
		push @n,"  them as part of this chartset.";
		push @n,'';
	}

	if (!@n)
	{
		push @n,$is_card ?
			"Nothing in the output folder will be disturbed." :
			$writes ?
			"One .mbtiles per region and per detail area, in a folder per\n".
			"region.  Existing charts of the same name will be REPLACED." :
			"Nothing will be written - this only fills the tile cache.";
	}
	elsif ($writes && !$is_card)
	{
		# SAID EVEN WHEN THERE IS SOMETHING ELSE TO SAY, because "what is
		# about to be overwritten" is the question the card build answers
		# here with a list, and this output cannot answer it with one - it
		# would mean opening every database in the tree to say what is in
		# it, which is a survey nobody asked for.

		push @n,"Existing charts of the same name will be REPLACED.";
	}

	return @n;
}


1;
