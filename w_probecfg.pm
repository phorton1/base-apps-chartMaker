#!/usr/bin/perl
#---------------------------------------------
# w_probecfg.pm
#---------------------------------------------
# WHAT TO PROBE, AND HOW DEEP.  The dialog that starts one.
#
# THE THREE THINGS IT ASKS ARE THE THREE THINGS A PROBE IS.  A source, an
# area, and a zoom range - and none of them is inferred from the region.
# Once a region names its own source and levels the build answers coverage
# exactly, so a probe that took them from the region would be re-deriving a
# known thing.  What is actually hard is choosing which of twenty-five
# services to specify in the first place, and that question has no region
# in it at all.
#
# EVERY INSTALLED SOURCE IS OFFERED, display-only ones included.  A source
# that cannot be built from can still be worth evaluating, and refusing to
# probe it would make the one list a user most wants to compare across
# incomplete.
#
# THE RANGE OPENS ON THE NODE'S OWN BAND, and never on the source's.  A
# .tsd can lie in both directions - promising more than the service
# delivers, and hiding depth it actually has - and finding that out is half
# the reason to probe, so the spinners reach z0-24 whatever a source
# declares and the run reports when it went past what was declared.
#
# BUT THE REGION KNOWS WHAT IT WANTS.  A region declares zmin..zmax and a
# subregion adds a band above its parent, and that band is precisely the
# range you are about to ask a source to satisfy.  Opening on it means the
# common case needs no thought at all, and it beats a preference somebody
# set once and now has to remember to change per node.
#
# THAT IS NOT THE PROBE CONSULTING THE REGION.  What is sampled is whatever
# these spinners say when OK is pressed; nothing clamps to the region and
# nothing derives from it.  A default is a guess at what was meant, and this
# is a better guess.
#
# THE SOURCE IS REMEMBERED FOR THE SESSION.  Comparing several services over
# one area means opening this repeatedly, and re-picking from the top of the
# list every time is the kind of friction that stops somebody running the
# third and fourth probe.

package w_probecfg;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON EVT_CHOICE );
use Pub::Utils;
use cm_defs;
use cm_prefs;
use cm_state;
use dm_source;
use dm_region;
use dm_sample;
use base qw(Wx::Dialog);


my $ID_OK		= 8851;
my $ID_CANCEL	= 8852;
my $ID_SOURCE	= 8853;


# WHAT THE LAST PROBE ACCEPTED, for the rest of this run of the application.
# Not a preference: it is a convenience about what you are doing right now,
# and writing it to disk would make one afternoon's comparison the permanent
# default months later.

my $last_source = '';
my ($last_lo,$last_hi);


sub new
	# THE AREA IS NOT ASKED FOR.  It is whatever was right-clicked, in the
	# tree or on the map, so this dialog asks the two things the gesture did
	# not say: which source, and how deep.  Offering a list of areas here
	# would be a second way to choose one, disagreeing with the node the
	# user already pointed at.
{
	my ($class,$parent,$label,$scope) = @_;

	my $this = $class->SUPER::new($parent,-1,
		'Probe over '.($label // '?'),[-1,-1],[440,300]);

	my @ids = getSourceIds();
	$this->{ids} = \@ids;

	my $y = 14;

	Wx::StaticText->new($this,-1,'Source',[16,$y+3],[70,18]);
	$this->{source} = Wx::Choice->new($this,$ID_SOURCE,[92,$y],[318,24],
		[ map { my $s = getSource($_);
				sprintf("%s  (z%d-%d)",$_,$s->{zoom}{min},$s->{zoom}{max}) }
		  @ids ]);

	# THE ONE PROBED LAST, if it is still installed.  A rescan can remove a
	# source between two probes, so the remembered id is looked up rather
	# than trusted.

	my ($was) = grep { $ids[$_] eq $last_source } (0 .. $#ids);
	$this->{source}->SetSelection(defined $was ? $was : 0) if @ids;
	$y += 34;

	# THE NODE'S OWN BAND, or the last range accepted if the node has none.
	# A region gives zmin..zmax; a subregion gives the band it adds above its
	# parent, which is exactly the range about to be asked of a source.

	my ($lo,$hi) = $scope ? sampleBand($scope) : ();
	($lo,$hi) = ($last_lo,$last_hi) if !defined($lo) && defined($last_lo);
	$lo = int(prefVal($PREF_PROBE_ZMIN) // 10) if !defined $lo;
	$hi = int(prefVal($PREF_PROBE_ZMAX) // 22) if !defined $hi;

	Wx::StaticText->new($this,-1,'Zoom',[16,$y+3],[70,18]);
	$this->{zmin} = Wx::SpinCtrl->new($this,-1,'',[92,$y],[64,24],
		wxSP_ARROW_KEYS,0,24,$lo);
	Wx::StaticText->new($this,-1,'to',[164,$y+3],[20,18]);
	$this->{zmax} = Wx::SpinCtrl->new($this,-1,'',[188,$y],[64,24],
		wxSP_ARROW_KEYS,0,24,$hi);
	$y += 26;

	# WHERE THE RANGE CAME FROM, said out loud.  A number that appeared by
	# itself is a number nobody trusts or corrects; one that says it is the
	# node's own band is a number you can agree with at a glance.

	$this->{band} = Wx::StaticText->new($this,-1,
		$scope && defined((sampleBand($scope))[0]) ?
			"the levels $label is built at" : '',
		[92,$y],[318,16]);
	$this->{band}->SetForegroundColour(Wx::Colour->new(90,90,90));
	$y += 18;

	# What the FILE says, beside what is about to be asked - so a range past
	# it is a visible choice rather than a surprise in the report.

	$this->{declared} = Wx::StaticText->new($this,-1,'',[92,$y],[318,16]);
	$this->{declared}->SetForegroundColour(Wx::Colour->new(90,90,90));
	$y += 24;

	# MEASURING DEPTH IS OPTIONAL AND SAYS WHY WHEN IT CANNOT.  For a
	# source that refuses tiles it does not have, the absent column alone
	# is the whole answer and this buys nothing; for one that never
	# refuses, it is the only instrument there is.

	# ON BY DEFAULT NOW, AND THAT IS A CHANGE.  It was off because the
	# statistic behind it was not validated - measured against a real
	# service it ranked a level that is certainly blown up ABOVE levels
	# that are real.  It is a different measure now and it is validated:
	# a manufactured magnification reads 1.00 to two decimals and real
	# imagery reads 1.5 to 5.  See dm_image for the run.
	#
	# What remains is a COST, not a doubt, so it stays a checkbox and the
	# cost is what the line beneath it now says.

	# TWO LINES, because it does not fit on one and a wxCheckBox does not
	# wrap: the box carries a short label and the caveat is its own text
	# beneath.  The caveat is the important half and must not be the half
	# that runs off the edge of the dialog.

	$this->{depth} = Wx::CheckBox->new($this,-1,
		'Measure whether depth buys anything',[92,$y],[318,18]);
	$this->{depth}->SetValue(1);
	$y += 18;

	my $warn = Wx::StaticText->new($this,-1,
		'Doubles the fetches - each sample is compared with',[110,$y],[300,16]);
	$warn->SetForegroundColour(Wx::Colour->new(140,80,0));
	$y += 15;
	my $warn2 = Wx::StaticText->new($this,-1,
		'its own parent - and costs about 0.1s of cpu each.',[110,$y],[300,16]);
	$warn2->SetForegroundColour(Wx::Colour->new(140,80,0));
	$y += 22;

	my $can = eval { require dm_image; dm_image::imageCan() };
	if (!$can)
	{
		$this->{depth}->SetValue(0);
		$this->{depth}->Enable(0);
		my $t = Wx::StaticText->new($this,-1,
			'unavailable: '.eval { dm_image::imageWhyNot() },[92,$y],[318,18]);
		$t->SetForegroundColour(Wx::Colour->new(140,80,0));
	}
	$y += 30;

	Wx::Button->new($this,$ID_OK,'Probe',[218,$y],[90,26]);
	Wx::Button->new($this,$ID_CANCEL,'Cancel',[318,$y],[90,26]);

	EVT_BUTTON($this,$ID_OK,    sub { $_[0]->EndModal(wxID_OK) });
	EVT_BUTTON($this,$ID_CANCEL,sub { $_[0]->EndModal(wxID_CANCEL) });
	EVT_CHOICE($this,$ID_SOURCE,\&onSource);

	$this->onSource();
	return $this;
}


sub onSource
	# THE RANGE FOLLOWS THE FILE.  Picking a source retargets the spinners
	# to what that source declares, because a range carried over from the
	# previous choice would be silently clamped and the user would be
	# reading a number the probe did not use.
{
	my ($this,$event) = @_;
	my $id = $this->{ids}[ $this->{source}->GetSelection() ] or return;
	my $src = getSource($id) or return;

	# The label follows the source; the VALUES do not.  What the user set in
	# preferences is what they meant, and retargeting the spinners at every
	# source change would quietly overwrite it.

	$this->{declared}->SetLabel(sprintf(
		"%s declares z%d-%d",$id,$src->{zoom}{min},$src->{zoom}{max}));
}


sub chosen
	# ($source_id,\%opts), or nothing.  The area is the caller's - it is
	# the node that was right-clicked.
{
	my ($this) = @_;
	my $id = $this->{ids}[ $this->{source}->GetSelection() ] or return ();

	my ($lo,$hi) = ($this->{zmin}->GetValue(),$this->{zmax}->GetValue());
	($lo,$hi) = ($hi,$lo) if $lo > $hi;

	# REMEMBERED ON ACCEPT, not on every keystroke: what was ACCEPTED is
	# what was meant, and a cancelled dialog said nothing.

	($last_source,$last_lo,$last_hi) = ($id,$lo,$hi);

	return ($id,{
		zmin	=> $lo,
		zmax	=> $hi,
		depth	=> $this->{depth}->GetValue() ? 1 : 0,
	});
}


1;
