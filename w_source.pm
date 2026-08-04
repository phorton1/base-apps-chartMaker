#!/usr/bin/perl
#---------------------------------------------
# w_source.pm
#---------------------------------------------
# THE TSD EDITOR.  New, Edit, Save, Save As, and Cancel.
#
# A DIALOG RATHER THAN A PANE, and the reason is not screen space.  The
# regions editor is a pane because a region is a spatial object edited
# against a spatial view: you need the map while you set a zmax.  A TSD has
# no geographic content at all, so the one thing a pane buys is the one
# thing this does not need.  What a dialog buys instead is a transaction:
# open, edit, Save or Cancel, with no question about what happens to
# half-typed text when somebody clicks another source in the tree.
#
# IT EDITS A FILE, NOT A SOURCE.  It is constructed from a plain field
# hash, which is what lets it open a file that does not load - the case
# that matters most, because a refused file is exactly the one somebody
# has to repair - and it is also how the catalog will fill it later
# without adding a second way in.
#
# THREE COLOURS AND A PRECEDENCE.  RED is a field this editor knows is
# wrong.  ORANGE is a field a web hit has PROVEN wrong, which nothing here
# can determine and which the verification phase will set.  PURPLE is a
# field changed since the last commit, and every field of a new file is
# purple.  Red beats orange beats purple.
#
# THERE IS NO 'UNPROVEN' STATE.  A purple field is taken to be correct
# until something proves otherwise, so nothing has to be stored, nothing
# goes stale, and the absence of a colour is not a claim that anything was
# checked.  The one piece of bookkeeping that follows is that an orange
# finding is dropped the moment its field is edited, because a refutation
# of a value that no longer exists is worse than no finding at all.
#
# SAVE IS BLOCKED WHILE ANYTHING IS RED.  An editor that can write a file
# the loader will refuse is an editor that can make its own work vanish
# from the list, and the reason it vanished would be in the log rather than
# in front of the person who caused it.
#
# EVERY RULE IT ENFORCES LIVES IN dm_source.  checkSourceField says whether
# one value is well formed and checkSource is the whole file's verdict.
# Duplicating either here would be a second rulebook that could disagree
# with the one that decides whether a file loads.

package w_source;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON EVT_TEXT EVT_CHOICE EVT_CHECKBOX EVT_CLOSE );
use JSON;
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_source;
use dm_verify;
use w_ini;
use w_progress;
use w_verify;
use w_blank;
use base qw(Wx::Dialog);


my $ID_SAVE		= 8901;
my $ID_SAVEAS	= 8902;
my $ID_CANCEL	= 8903;
my $ID_TEST		= 8904;
my $ID_FIRST	= 8910;		# one per field, in @EDIT_FIELDS order

my $RED		= Wx::Colour->new(200,0,0);
my $ORANGE	= Wx::Colour->new(190,110,0);
my $PURPLE	= Wx::Colour->new(120,0,160);
my $BLACK	= Wx::Colour->new(0,0,0);
my $GREY	= Wx::Colour->new(90,90,90);

my $LBL		= 108;			# label column width
my $X_LBL	= 12;
my $X_CTL	= 126;
my $X_ANN	= 566;			# the annotation column, empty in this phase
my $W_FULL	= 430;
my $W_HALF	= 176;
my $W_ANN	= 118;


# CHOSEN FOR THE SCREEN, not for the field list.  The fields scroll, so
# this is only a question of how much of them is worth seeing at once.

my $W_DLG	= 730;
my $H_DLG	= 660;

# SMALL ENOUGH TO BE USEFUL, NOT SO SMALL THAT THE WAY OUT DISAPPEARS.  The
# buttons are outside the scroller, so shrinking past this would start
# eating them rather than the fields.

my $W_MIN	= 520;
my $H_MIN	= 300;


sub _rowHeight
{
	my ($name,$kind) = @_;
	return 46 if $kind eq 'list';
	return 24 if $kind ne 'big';
	return 50 if $name eq 'license';
	return 80 if $name eq 'notes';
	return 46;
}


sub new
	# ($parent,$leaf,\%tsd,$is_new).  $leaf is the file name this will
	# write, or '' for a file that does not exist yet.
{
	my ($class,$parent,$leaf,$tsd,$is_new) = @_;

	# THE FIELDS SCROLL AND THE BUTTONS DO NOT.  Sized to fit the fields, the
	# dialog was 806 pixels tall and its Save button sat below the bottom
	# edge - the one layout fault a modal cannot survive, because there is no
	# way out of it and no way to see that there was supposed to be.  A
	# field list also grows: the two absence lists were added to it.  So the
	# height is chosen for the SCREEN, the fields scroll inside it, and the
	# way out is always visible.

	# WHERE IT WAS LEFT, AND HOW BIG IT WAS LEFT.  Moving and resizing a
	# dialog is the user saying where they want it; reopening in the middle
	# of the screen at a default size says that was not heard.  A remembered
	# rectangle is checked against the display it is about to appear on,
	# because a monitor that has been unplugged would otherwise put the
	# dialog somewhere with no way to reach it.

	my ($x,$y0,$w,$h) = (-1,-1,$W_DLG,$H_DLG);
	my $was = getSourceEditorRect();
	if ($was =~ /^(-?\d+),(-?\d+),(\d+),(\d+)$/)
	{
		my ($rx,$ry,$rw,$rh) = ($1,$2,$3,$4);

		# THE ON-SCREEN CHECK IS BEST EFFORT.  Wx::Display is not present in
		# every wxPerl build, and a dialog that refused to open because it
		# could not ask about monitors would be a far worse fault than one
		# that occasionally opens somewhere awkward.

		my $area = eval { Wx::Display->new(0)->GetClientArea() };
		my $ok = $rw >= $W_MIN && $rh >= $H_MIN;
		$ok &&= ($rx + $rw > $area->x + 60 && $ry + $rh > $area->y + 60 &&
				 $rx < $area->x + $area->width - 60 &&
				 $ry < $area->y + $area->height - 60) if $area;
		($x,$y0,$w,$h) = ($rx,$ry,$rw,$rh) if $ok;
	}

	my $this = $class->SUPER::new($parent,-1,
		$is_new ? 'New Source' : "Edit Source - $leaf",
		[$x,$y0],[$w,$h],
		wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);
	$this->SetMinSize([$W_MIN,$H_MIN]);

	$this->{leaf}    = $leaf // '';
	$this->{is_new}  = $is_new ? 1 : 0;
	$this->{orig}    = $tsd ? { %$tsd } : {};
	$this->{rows}    = [];
	$this->{proven}  = {};		# field => a web hit's refutation

	# WHAT IS NOT EDITED IS STILL CARRIED.  credentials has no control - it
	# is a list of slots, and a slot with no value in it is not a thing a
	# text box can usefully offer - and a file that lost it by passing
	# through the editor would be a file quietly damaged by being looked at.
	#
	# THE TWO ABSENCE LISTS ARE NO LONGER CARRIED.  They are rows now, so
	# they are visible, editable and DELETABLE, which is what a person needs
	# in order to turn a fingerprint off and see what the service really
	# serves.  Carrying an invisible field was also the reason accepting a
	# fingerprint could not mark the dialog dirty.

	$this->{carry} = {};
	for my $k (qw( credentials ))
	{
		$this->{carry}{$k} = $tsd->{$k} if defined $tsd->{$k};
	}

	# EVERY FIELD IS A CHILD OF THE SCROLLER, not of the dialog, which is
	# the whole of what makes them scroll.  The reason line and the buttons
	# are children of the dialog and therefore always in view.

	my $scroll = Wx::ScrolledWindow->new($this,-1,
		wxDefaultPosition,wxDefaultSize,wxVSCROLL);
	$scroll->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$this->{scroll} = $scroll;

	my $y = 12;
	my $n = 0;
	for my $f (sourceFields())
	{
		my ($name,$kind,$label) = @$f;
		my $id = $ID_FIRST + $n++;

		my $half = ($kind eq 'int' || $name eq 'tile_format' ||
					$name eq 'redistributable' || $name eq 'subdomains' ||
					$name eq 'displacement' || $name eq 'id' ||
					$name eq 'cache_key');
		my $w = $half ? $W_HALF : $W_FULL;
		my $h = _rowHeight($name,$kind);

		my $lbl = Wx::StaticText->new($scroll,-1,$label,[$X_LBL,$y+4],[$LBL,18]);

		my $ctl;
		if ($kind eq 'choice')
		{
			my @vals = $name eq 'tile_format' ?
				('jpeg','png') : ('yes','no','unknown');
			$ctl = Wx::Choice->new($scroll,$id,[$X_CTL,$y],[$w,24],\@vals);
			my $cur = $this->_get($tsd,$name) // '';
			my ($sel) = grep { $vals[$_] eq $cur } (0 .. $#vals);
			$ctl->SetSelection(defined $sel ? $sel : $#vals);
			EVT_CHOICE($this,$id,sub { $this->onEdit() });
		}
		elsif ($kind eq 'uses')
		{
			$ctl = {};
			my $x = $X_CTL;
			for my $u (qw( display build overlay ))
			{
				my $cb = Wx::CheckBox->new($scroll,$id,$u,[$x,$y+3],[86,18]);
				$cb->SetValue(
					(grep { $_ eq $u } @{ $tsd->{uses} || [] }) ? 1 : 0);
				EVT_CHECKBOX($this,$id,sub { $this->onEdit() });
				$ctl->{$u} = $cb;
				$x += 90;
			}
		}
		else
		{
			my $style = ($kind eq 'big') ?
				(wxTE_MULTILINE | wxTE_DONTWRAP) : 0;
			$style = wxTE_MULTILINE if $kind eq 'big' && $name ne 'url';

			# ONE ENTRY PER LINE, AND IT DOES NOT WRAP.  A wrapped md5 reads
			# as two entries, which is the one misreading this control must
			# not invite.

			$style = wxTE_MULTILINE | wxTE_DONTWRAP if $kind eq 'list';
			$ctl = Wx::TextCtrl->new($scroll,$id,
				$this->_get($tsd,$name) // '',[$X_CTL,$y],[$w,$h],$style);
			EVT_TEXT($this,$id,sub { $this->onEdit() });
		}

		# THE ANNOTATION SLOT, BUILT EMPTY.  Verification produces findings
		# that belong beside the field they are about, and a row with no
		# room for one would have to be rebuilt to gain it.  A few pixels
		# now is the whole cost of not doing that later.

		my $ann = Wx::StaticText->new($scroll,-1,'',[$X_ANN,$y+4],[$W_ANN,18]);
		$ann->SetForegroundColour($GREY);

		push @{$this->{rows}},{
			name  => $name,
			kind  => $kind,
			label => $lbl,
			ctl   => $ctl,
			ann   => $ann,
			orig  => $this->_valueOf($kind,$ctl),
		};

		$y += $h + 8;
	}

	# THE SCROLLED AREA IS AS TALL AS THE FIELDS ARE, and the window it sits
	# in is whatever the dialog can spare.  SetVirtualSize is what the
	# scrollbar measures itself against; without it the bar never appears
	# and the last field is simply unreachable.

	$scroll->SetVirtualSize([$X_ANN + $W_ANN + 12,$y]);
	$scroll->SetScrollRate(0,14);

	# ONE REASON LINE, and it is the only place a reason appears in this
	# dialog.  The colour on the field says WHICH, this says WHAT.

	$this->{why} = Wx::StaticText->new($this,-1,'');
	$this->{why}->SetForegroundColour($RED);

	$this->{save} = Wx::Button->new($this,$ID_SAVE,'Save',
		wxDefaultPosition,[100,26]);
	$this->{saveas} = Wx::Button->new($this,$ID_SAVEAS,'Save As...',
		wxDefaultPosition,[100,26]);
	my $saveas = $this->{saveas};
	my $cancel = Wx::Button->new($this,$ID_CANCEL,'Cancel',
		wxDefaultPosition,[100,26]);

	# TEST IS ON THE LEFT, AWAY FROM THE THREE THAT END THE DIALOG.  It is
	# the only button here that does not commit or dismiss anything, and
	# sitting it beside Save would invite the reading that it is a step on
	# the way to saving.  It is not: a test is a network act, a save is a
	# disk act, and neither is a precondition of the other.

	$this->{test} = Wx::Button->new($this,$ID_TEST,'Test',
		wxDefaultPosition,[100,26]);
	$this->{test}->SetToolTip('Ask the service about the values in this '.
		'dialog. Changes nothing, here or on disk.');

	my $brow = Wx::BoxSizer->new(wxHORIZONTAL);
	$brow->Add($this->{test},0,0,0);
	$brow->AddStretchSpacer(1);
	$brow->Add($this->{save},0,0,0);
	$brow->AddSpacer(8);
	$brow->Add($saveas,0,0,0);
	$brow->AddSpacer(8);
	$brow->Add($cancel,0,0,0);

	my $outer = Wx::BoxSizer->new(wxVERTICAL);
	$outer->Add($scroll,1,wxEXPAND,0);
	$outer->Add($this->{why},0,wxEXPAND|wxLEFT|wxRIGHT|wxTOP,10);
	$outer->Add($brow,0,wxEXPAND|wxALL,10);
	$this->SetSizer($outer);
	$this->Layout();

	EVT_BUTTON($this,$ID_SAVE,  \&onSave);
	EVT_BUTTON($this,$ID_SAVEAS,\&onSaveAs);
	EVT_BUTTON($this,$ID_TEST,  \&onTest);
	EVT_BUTTON($this,$ID_CANCEL,sub { $_[0]->done(wxID_CANCEL) });

	# THE TITLE BAR X IS A CLOSE LIKE ANY OTHER.  It is the exit people
	# actually use, so it has to be the one that records the geometry rather
	# than the one that loses it.

	EVT_CLOSE($this,sub { $_[0]->done(wxID_CANCEL) });

	# A NEW FILE IS ENTIRELY CHANGED, which is true and is also the most
	# useful thing it can say: every value in front of you is one you are
	# about to commit rather than one somebody already did.

	if ($this->{is_new})
	{
		$_->{orig} = undef for @{$this->{rows}};
	}

	$this->repaint();
	return $this;
}


#---------------------------------------------
# values
#---------------------------------------------

sub _get
	# One field out of a tsd hash, including the two dotted ones.
{
	my ($this,$tsd,$name) = @_;
	return undef if !$tsd;
	if ($name =~ /^(\w+)\.(\w+)$/)
	{
		return undef if !$tsd->{$1};
		my $v = $tsd->{$1}{$2};
		return defined $v ? "$v" : undef;
	}
	return join(',',@{$tsd->{$name}}) if $name eq 'subdomains' &&
		ref($tsd->{$name}) eq 'ARRAY';

	# THE ABSENCE LISTS ARE RENDERED BY THE MODULE THAT OWNS THEIR GRAMMAR,
	# so what appears in the box is exactly what its parser accepts back.

	return sourceListText($name,$tsd->{$name})
		if $name eq 'absent_fingerprints' || $name eq 'absent_headers';

	my $v = $tsd->{$name};
	return undef if !defined $v || ref $v;
	return "$v";
}


sub _valueOf
{
	my ($this,$kind,$ctl) = @_;
	return join(',',grep { $ctl->{$_}->GetValue() }
		qw( display build overlay )) if $kind eq 'uses';
	return $ctl->GetStringSelection() if $kind eq 'choice';
	my $v = $ctl->GetValue();
	$v =~ s/^\s+|\s+$//g if $kind ne 'big';
	return $v;
}


sub fieldValues
	# name => current string, for every row.
{
	my ($this) = @_;
	my %v;
	$v{$_->{name}} = $this->_valueOf($_->{kind},$_->{ctl})
		for @{$this->{rows}};
	return \%v;
}


sub tsd
	# The hash this dialog would write.  tile_size and crs are put back
	# because they have one legal value each and no control offers them.
{
	my ($this) = @_;
	my $v = $this->fieldValues();

	my $out = { %{$this->{carry}} };
	$out->{tsd_version} = 1;
	$out->{tile_size}   = 256;
	$out->{crs}         = 'EPSG:3857';

	for my $k (qw( id cache_key name url attribution terms_url license
				   notes displacement tile_format redistributable ))
	{
		$out->{$k} = $v->{$k} if defined $v->{$k} && $v->{$k} =~ /\S/;
	}

	$out->{zoom} = {
		min => int($v->{'zoom.min'} || 0),
		max => int($v->{'zoom.max'} || 0) };

	$out->{uses} = [ grep { $_ } split(/,/,$v->{uses} // '') ];

	my @subs = grep { /\S/ } split(/\s*,\s*/,$v->{subdomains} // '');
	$out->{subdomains} = \@subs if @subs;

	my %pol;
	for my $p (qw( max_concurrency min_interval_ms ))
	{
		$pol{$p} = int($v->{"policy.$p"})
			if defined $v->{"policy.$p"} && $v->{"policy.$p"} =~ /^\d+$/;
	}
	$out->{policy} = \%pol if %pol;

	# AN EMPTY BOX MEANS THE FIELD IS GONE, not that it is an empty array.
	# Clearing the text is how somebody turns a fingerprint off in order to
	# see what the service really serves, and writing "absent_fingerprints":
	# [] would leave a field behind that says nothing.

	for my $k (qw( absent_fingerprints absent_headers ))
	{
		next if !defined $v->{$k} || $v->{$k} !~ /\S/;
		my ($list) = sourceListParse($k,$v->{$k});
		$out->{$k} = $list if $list && @$list;
	}

	return $out;
}


#---------------------------------------------
# state and colour
#---------------------------------------------

sub onEdit
	# ANY EDIT DROPS THAT FIELD'S REFUTATION.  A web hit proved something
	# about a value, and this is no longer that value.
{
	my ($this) = @_;
	return if $this->{painting};
	for my $r (@{$this->{rows}})
	{
		my $now = $this->_valueOf($r->{kind},$r->{ctl});
		delete $this->{proven}{$r->{name}}
			if defined $r->{orig} && $now ne $r->{orig};
	}
	$this->repaint();
}


sub isDirty
{
	my ($this) = @_;
	for my $r (@{$this->{rows}})
	{
		return 1 if !defined $r->{orig};
		return 1 if $this->_valueOf($r->{kind},$r->{ctl}) ne $r->{orig};
	}
	return 0;
}


sub repaint
	# RED BEATS ORANGE BEATS PURPLE, on the label always and on the text of
	# an edit control where there is one to colour.
{
	my ($this) = @_;
	$this->{painting} = 1;

	my $first   = '';
	my $url_bad = 1;
	for my $r (@{$this->{rows}})
	{
		my $now = $this->_valueOf($r->{kind},$r->{ctl});

		# THE CARRIED credentials ARE PART OF THE QUESTION.  This dialog has
		# no control for them and passes them through untouched, but a url
		# may legally name a slot the file declares - so the field check has
		# to be told what is carried or it refuses what the loader accepts.

		my $bad = checkSourceField($r->{name},$now,
			$this->{carry}{credentials});
		my $col = $BLACK;
		$url_bad = $bad ? 1 : 0 if $r->{name} eq 'url';

		if ($bad)
		{
			$col = $RED;
			$first ||= "$r->{name}: $bad";
		}
		elsif ($this->{proven}{$r->{name}})
		{
			$col = $ORANGE;
			$first ||= "$r->{name}: ".$this->{proven}{$r->{name}};
		}
		elsif (!defined $r->{orig} || $now ne $r->{orig})
		{
			$col = $PURPLE;
		}

		$r->{label}->SetForegroundColour($col);
		$r->{label}->Refresh();
		if ($r->{kind} ne 'uses' && $r->{kind} ne 'choice')
		{
			$r->{ctl}->SetForegroundColour($col);
			$r->{ctl}->Refresh();
		}
	}

	# THE WHOLE FILE'S VERDICT, WHICH IS NOT THE SUM OF THE FIELDS.  A file
	# can have every field well formed and still be refused - a url naming a
	# credential slot it does not declare, for one - so the loader's own
	# answer is asked for even when nothing is red.

	if (!$first)
	{
		my $why = checkSource($this->{leaf} || 'new.tsd',$this->tsd());
		$first = $why if $why;
	}

	# SAVE NEEDS BOTH DIRTY AND COHERENT.  Coherent alone would let Save
	# rewrite a file nobody had changed, which is not harmless: the writer
	# reflows to canonical order, so an idle click would rewrite somebody's
	# hand-formatted file and move its timestamp for no change at all.
	#
	# SAVE AS NEEDS ONLY COHERENT, because copying an unchanged file to a
	# new name is a real thing to want and is how a variant begins.

	my $dirty = $this->isDirty();
	$this->{why}->SetLabel($first);
	$this->{save}->Enable(($first || !$dirty) ? 0 : 1);
	$this->{saveas}->Enable($first ? 0 : 1);

	# TEST NEEDS A COHERENT URL AND NOTHING ELSE.  It does not care whether
	# anything has changed, because asking the service the same question
	# twice is a legitimate thing to do, and it does not care whether the
	# rest of the file is well formed, because the fields it can refute are
	# not the ones that would be red.

	$this->{test}->Enable($url_bad ? 0 : 1);
	$this->{painting} = 0;
}


#---------------------------------------------
# committing
#---------------------------------------------

#---------------------------------------------
# verification
#---------------------------------------------
# THE HOOK, AND ONLY THE HOOK.  What a test DOES belongs to the phase that
# writes it; what this phase owes is a place for the answer to land that
# does not require the dialog to be rebuilt to gain one.
#
# THE WHOLE CONTRACT IS TWO CALLS.  A verifier proves a field wrong and
# says so, or it withdraws everything it previously claimed.  It never
# edits a value: nothing rewrites a TSD without a person, and a check that
# quietly corrected the file it was checking would make every source a
# cache of the service's current mood.
#
# WHAT IT MAY REFUTE is only what a fetch can actually settle - the url,
# the declared ceiling, the format really served.  A licence or an
# attribution is not a thing a server has an opinion about.

sub setProven
	# ($field,$why).  Marks one field orange, with the reason.
{
	my ($this,$field,$why) = @_;
	$this->{proven}{$field} = $why;
	$this->repaint();
}


sub clearProven
{
	my ($this) = @_;
	$this->{proven} = {};
	$this->repaint();
}


sub addFingerprint
	# ($bytes,$md5) INTO THE VISIBLE ROW, which is the whole reason that row
	# exists.  Nothing is written to disk: the user sees the pair appear in
	# the box, Save is enabled because a control really did change, and they
	# can delete it again if they change their mind.
	#
	# ALREADY THERE IS A NO-OP AND SAYS SO.  Accepting the same finding twice
	# is not an error and must not double the entry, which would then never
	# match anything the loader normalises.
{
	my ($this,$bytes,$md5) = @_;
	return 0 if !$bytes || !$md5;

	my ($row) = grep { $_->{name} eq 'absent_fingerprints' } @{$this->{rows}};
	return 0 if !$row;

	my $was = $row->{ctl}->GetValue();
	return 0 if $was =~ /\b\Q$md5\E\b/i;

	$was .= "\n" if $was =~ /\S/ && $was !~ /\n$/;
	$row->{ctl}->SetValue($was."$bytes ".lc($md5));

	$this->onEdit();
	return 1;
}


sub onTest
	# ASK THE SERVICE ABOUT THE VALUES IN THIS DIALOG, on a worker, under
	# the progress dialog.
	#
	# THE FIELDS AS THEY ARE NOW, NOT AS THEY WERE SAVED.  Testing the file
	# on disk would be testing something the user cannot see, and the whole
	# reason to press this button is that a value in front of them has just
	# been typed and they want to know whether it is true.
	#
	# EVERY PREVIOUS FINDING IS DROPPED FIRST.  Orange means the service
	# disproved this value, and a mark left over from a run that is being
	# replaced is a claim nothing currently supports.
	#
	# THE ANSWER LANDS TWICE, DELIBERATELY.  Fields it can name go orange
	# here, where they are edited; ALL of it goes in the dialog, because a
	# dialog is what somebody who pressed a button expects to be answered
	# by, and because the same rendering has to serve the catalog, where
	# there are no fields to paint.
{
	my ($this,$event) = @_;

	my $tsd = $this->tsd();
	$this->clearProven();

	my @places = verifyPlaces($tsd);

	my $prog = newProgress(2,'');
	$prog->{active} = 1;
	$prog->{phase}  = 'Starting';

	threads->create(\&dm_verify::verifyWorker,$prog,
		[ encode_json($tsd),encode_json(\@places),($this->{leaf} || '') ]
		)->detach();

	my $dlg = w_progress->new($this,
		'Test - '.($tsd->{name} || $tsd->{id} || 'source'),$prog);
	$dlg->run();

	# THE ANSWER CROSSES AS TEXT, decoded once here.  See verifyWorker.

	my $out = eval { decode_json($prog->{json} || '{}') };
	if (!$out || !$out->{verdict})
	{
		Wx::MessageBox('The test could not be completed.','Test',
			wxOK | wxICON_ERROR,$this);
		return;
	}

	$this->setProven($_->{field},$_->{why}) for @{$out->{refuted} || []};
	w_verify->show($this,$out);

	# AND THEN THE CANDIDATES, ONE AT A TIME, AFTER the summary rather than
	# instead of it.  The summary is the answer to what was asked; a
	# candidate is a separate question this run happens to be able to put,
	# and stacking it on top of the report would bury the report.

	# A DECLINE IS REMEMBERED HERE TOO.  Without it, testing the same source
	# twice in a row asks the same question twice, and the second asking is
	# how somebody learns to dismiss this dialog without reading it.

	my $added = 0;
	for my $c (verifyOffers($out))
	{
		if (!w_blank->show($this,$tsd,$c))
		{
			obsDeclineFingerprint($tsd,$c->{md5});
			next;
		}
		$added += $this->addFingerprint($c->{bytes},$c->{md5});
	}
	obsFlushAll();

	# AN UNSAVED CHANGE HAS TO SAY SO.  It is visible in its own row, but
	# that row may be scrolled off, and the change is the kind somebody
	# would be dismayed to lose by closing the dialog.

	$this->{why}->SetLabel($added == 1 ?
		'a fingerprint was added - Save to keep it' :
		"$added fingerprints were added - Save to keep them")
		if $added;
}


sub done
	# THE ONLY WAY OUT, so there is exactly one place that measures the
	# window - a second exit that forgot to would lose whatever the user
	# had just arranged, and only sometimes, which is the worst way for
	# something like this to be wrong.
{
	my ($this,$code) = @_;
	my ($x,$y) = $this->GetPositionXY();
	my ($w,$h) = $this->GetSizeWH();
	setSourceEditorRect("$x,$y,$w,$h");
	$this->EndModal($code);
}


sub _writeTo
{
	my ($this,$leaf) = @_;

	# UNIQUENESS IS SETTLED HERE, NOT DISCOVERED ON THE NEXT SCAN.  Writing
	# a file that collides would refuse BOTH files at load, so the id that
	# was fine a moment ago would stop working too.

	my $tsd = $this->tsd();
	for my $other (getSourceIds())
	{
		my $src = getSource($other);
		next if $src->{file} eq $leaf;
		if ($src->{id} eq ($tsd->{id} // ''))
		{
			$this->{why}->SetLabel(
				"id '$tsd->{id}' is already used by $src->{file}");
			return 0;
		}
		if (($src->{cache_key} // '') eq ($tsd->{cache_key} // '') &&
			($src->{url} // '') ne ($tsd->{url} // ''))
		{
			$this->{why}->SetLabel("cache_key '$tsd->{cache_key}' is used ".
				"by $src->{file}, which has a different url");
			return 0;
		}
	}

	my $err = writeSourceFile($leaf,$tsd);
	if ($err)
	{
		$this->{why}->SetLabel($err);
		return 0;
	}
	$this->{leaf} = $leaf;
	return 1;
}


sub onSave
{
	my ($this,$event) = @_;

	# A NEW FILE HAS NO NAME YET, so Save on one is Save As.

	return $this->onSaveAs() if !$this->{leaf};
	$this->done(wxID_OK) if $this->_writeTo($this->{leaf});
}


sub onSaveAs
	# SAVE AS TAKES A NEW FILE NAME, AND THE ID HAS TO BE NEW TOO.  Two
	# files claiming one id refuse each other, so the copy would break the
	# original - which is the opposite of what somebody making a variant
	# expects.  The id is theirs to change; this only refuses to write.
{
	my ($this,$event) = @_;

	my $v = $this->fieldValues();
	my $suggest = ($v->{id} // 'source');
	$suggest =~ s/[^a-z0-9_-]//g;

	my $dlg = Wx::TextEntryDialog->new($this,
		"File name for this source, without the .tsd",
		'Save Source As',$suggest);
	my $rslt = $dlg->ShowModal();
	my $leaf = $dlg->GetValue();
	$dlg->Destroy();
	return if $rslt != wxID_OK;

	$leaf =~ s/\.tsd$//i;
	$leaf =~ s/^\s+|\s+$//g;
	if ($leaf !~ /^[A-Za-z0-9_.-]+$/)
	{
		$this->{why}->SetLabel(
			"'$leaf' is not a usable file name - letters, digits, '_', '-' and '.'");
		return;
	}
	$leaf .= '.tsd';

	# ASKED OF dm_source RATHER THAN OF THE FILESYSTEM.  Where sources live
	# is not this dialog's business, and the one call that reached for the
	# folder directly needed a module this one does not use - which is
	# exactly the kind of thing a layering shortcut costs.

	my $exists = grep { lc($_) eq lc($leaf) } getSourceFiles();
	if ($exists && $leaf ne ($this->{leaf} // ''))
	{
		return if Wx::MessageBox("$leaf already exists.\n\nOverwrite it?",
			'Save Source As',wxYES_NO | wxICON_QUESTION,$this) != wxYES;
	}

	$this->done(wxID_OK) if $this->_writeTo($leaf);
}


sub savedAs
{
	my ($this) = @_;
	return $this->{leaf};
}


1;
