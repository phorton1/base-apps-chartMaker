#!/usr/bin/perl
#---------------------------------------------
# dm_verify.pm
#---------------------------------------------
# ASK A SERVICE WHETHER A TSD IS TRUE, and say what came back.
#
# TWO HALVES, AND ONLY ONE OF THEM HAS A PLACE.
#
#	UNPLACED  the file's own coherence, plus the service's metadata where
#	          it publishes any.  This half can only ever REFUTE - a
#	          malformed url, a credential slot the file does not declare,
#	          the wrong grid, the wrong row order, a ceiling below what is
#	          claimed.  It never confirms imagery and is never worded as
#	          though it had.
#
#	PLACED    a COLUMN of tiles over one point, every level from the
#	          declared floor to the declared ceiling, classified from the
#	          BODY rather than from the status.
#
# THE PLACE IS NEVER DERIVED.  Measured against the live services on
# 2026-08-04: a service labelled 'Japan' serves real imagery over Bocas del
# Toro at z3 and z8 and nothing at z12; one labelled 'France' serves Bocas
# del Toro at z12, the same ground as Esri World Imagery pixel for pixel;
# and 'Spain' answers outside Spain with a 200 carrying a blank JPEG.
# Region prose predicts nothing, a declared extent is where a service is
# ENTITLED to hold imagery rather than where it does, and the middle of a
# bounding box is water as often as not.  So a point comes from the
# catalog, where a person chose it, or from the user, and from nowhere
# else.
#
# TWO COLUMNS, DOING DIFFERENT JOBS.
#
#	THE CANONICAL COLUMN is somewhere the service is known to have
#	imagery, so an empty answer there is about the SERVICE.  It is the
#	only column entitled to say the source works.
#
#	YOUR COLUMN is wherever the user is looking, and it has nothing to be
#	compared against, so it is DESCRIPTIVE and can never fail.  A service
#	with nothing at Bocas del Toro is not a broken service, and reporting
#	it as one would be the single most misleading thing this could do.
#
# THE COLUMN IS WALKED IN FULL AND NEVER STOPS AT THE FIRST HIT.  Measured:
# Japan GSI over Tokyo answers z2 to z18 unbroken and refuses z0 and z1,
# and over Panama it answers only z3 to z8.  Present in the MIDDLE of the
# column, with no floor to climb from and no ceiling to descend from.
# Stop-at-first-hit would have called that a pass and said nothing about
# the levels a chart is actually built at.
#
# STATUS IS NOT THE ANSWER, THE BODY IS.  Of twelve services measured, four
# returned a 200 for something that was not imagery: a JSON refusal
# carrying 'Token Required', a 929 byte blank JPEG, a 334 byte transparent
# PNG, and a white world with one blue speck of New South Wales painted on
# it.  A verifier that read the status code would have passed all four.
#
# NOTHING HERE EVER WRITES A TSD.  What it finds is shown beside what the
# file says, and a suspected blank is OFFERED as an absent_fingerprint
# rather than added.  That is the same rule the probe keeps and for the
# same reason: a checker that quietly corrected the file it was checking
# would make every source a cache of a server's current mood.

package dm_verify;
use strict;
use warnings;
use threads;
use threads::shared;
use Digest::MD5 qw( md5_hex );
use JSON;
use Pub::Utils;
use cm_defs;
use cm_utils;
use cm_state;
use dm_source;
use dm_region;
use dm_catalog;
use dm_observe;
use dm_fetch;
use dm_meta;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		verifySource
		verifyLines
		verifyHeadline
		verifyOffers
		verifyNewCandidates
		verifyPlaces
		verifyWorker
	);
}


our $dbg_verify:shared = 0;
	# 0  = one line per verify and one per column
	# -1 = one line per level


my $PI = 3.14159265358979;

my $MAX_LEVELS = 24;
	# A DECLARED RANGE AND NOT A BUDGET.  z0 to z23 is the widest any TSD
	# may state, so this bounds a runaway rather than sampling a column:
	# nothing is ever silently left unasked.

my $OFFER_AT = 2;
	# TWICE IS THE LEAST THAT MEANS ANYTHING.  One sighting of a body is a
	# tile; the same body at two unrelated coordinates is the beginning of
	# evidence.  The same number dm_fetch reports at, restated here because
	# this module decides what to SHOW and that is a different decision
	# from what to record.


#---------------------------------------------
# the grid
#---------------------------------------------

sub _tileAt
	# lat/lon to the tile containing it, at one level.  Here rather than
	# borrowed, because dm_coverage's converter is part of a polygon
	# rasteriser and this is one point.
{
	my ($lat,$lon,$z) = @_;
	my $n = 2 ** $z;

	my $x = int(($lon + 180) / 360 * $n);
	my $r = $lat * $PI / 180;
	my $y = int((1 - log(sin($r)/cos($r) + 1/cos($r)) / $PI) / 2 * $n);

	$x = 0 if $x < 0;  $x = $n - 1 if $x > $n - 1;
	$y = 0 if $y < 0;  $y = $n - 1 if $y > $n - 1;
	return ($x,$y);
}


#---------------------------------------------
# where to ask
#---------------------------------------------

sub _canonicalFor
	# THE CATALOG'S POINT FOR THIS SOURCE, FOUND BY ITS URL.
	#
	# BY URL AND NOT BY id, because the id is the one thing Create is free
	# to change: a user making a second variant renames it, and the url is
	# what actually says which service this is.  cache_key is the fallback
	# for a url somebody has since edited.
	#
	# A LOOKUP RATHER THAN A COUPLING.  dm_catalog knows nothing about
	# sources and dm_source knows nothing about the catalog; this module
	# is above both and is allowed to ask each of them a question.
{
	my ($source) = @_;
	return undef if !$source;

	my $url = $source->{url} // '';
	my $key = $source->{cache_key} // '';

	my $by_key;
	for my $e (@{catalogEntries()})
	{
		next if !$e->{canonical};
		return $e->{canonical} if ($e->{tsd}{url} // '') eq $url;
		$by_key ||= $e->{canonical}
			if $key ne '' && ($e->{tsd}{cache_key} // '') eq $key;
	}
	return $by_key;
}


sub _centreOf
	# The centre of a node's bounding box.
	#
	# A BOX CENTRE CAN FALL OUTSIDE AN L SHAPED POLYGON, and that is
	# tolerable here in a way it would not be anywhere else: this is the
	# user's OWN area, this column is descriptive and can never fail, and
	# the answer names the place it asked so a surprising one reads as a
	# surprising place rather than as a broken service.
{
	my ($node) = @_;
	my ($w,$s,$e,$n);
	for my $poly (@{$node->{geometry} || []})
	{
		for my $pt (@$poly)
		{
			my ($lon,$lat) = @$pt;
			next if !defined $lon || !defined $lat;
			$w = $lon if !defined $w || $lon < $w;
			$e = $lon if !defined $e || $lon > $e;
			$s = $lat if !defined $s || $lat < $s;
			$n = $lat if !defined $n || $lat > $n;
		}
	}
	return () if !defined $w;
	return (($s + $n) / 2,($w + $e) / 2);
}


sub _selectionPlace
	# WHAT IS SELECTED IN THE TREE, as a point.  A region, or a subregion
	# beneath one, whichever the selection names.
	#
	# THE FULL DECLARED BAND IS STILL WALKED, and the node's own zmin and
	# zmax are deliberately not consulted.  A test is about the SERVICE;
	# the region is only supplying an additional 'here'.  Walking the
	# node's band would answer a different question and would answer it
	# differently for each node, which is the opposite of a baseline.
{
	my ($region_id,$sub_id) = getSelection();
	return undef if !$region_id;

	my $reg = getRegion($region_id);
	return undef if !$reg;

	my $node = $reg;
	my $what = "the region $reg->{name}";
	if ($sub_id)
	{
		my ($sub) = findSubregion($reg,$sub_id);
		($node,$what) = ($sub,"the subregion $sub->{name}") if $sub;
	}

	my ($lat,$lon) = _centreOf($node);
	return undef if !defined $lat;

	return {
		kind  => 'here',
		where => $what,
		at    => [ $lat,$lon ],
		why   => 'the centre of what is selected, because the map is not open',
	};
}


sub verifyPlaces
	# WHERE THIS SOURCE WOULD BE ASKED, decided on the main thread before
	# any worker starts, because both answers come from state a worker has
	# no business reading and one of them is a dialog's argument.
	#
	# ($source,$given) -> a list of { kind, where, at, why }.
	#
	# $given is an optional place from the caller - the catalog dialog
	# passes the entry's own, since a catalog entry has not been written
	# to disk and cannot be found by url.
{
	my ($source,$given) = @_;
	my @out;

	my $can = $given || _canonicalFor($source);
	push @out,{
		kind  => 'canonical',
		where => $can->{where},
		at    => $can->{at},
		why   => $can->{why},
	} if $can && $can->{at};

	# THE USER'S OWN POINT, AND THE MAP WINS WHEN THERE IS ONE.  Where
	# somebody is looking right now is a more current statement of where
	# they care than a tree selection they made at some point, and it is
	# the one they can change in a second if the answer surprises them.
	#
	# WITH NO MAP, WHAT IS SELECTED.  A region or a subregion is a real
	# place the user chose, and it is the only other thing in this
	# application that is one.
	#
	# AND THERE IS NO THIRD SOURCE.  A place this application invented
	# would be exactly the derived point the whole design refuses.

	my ($lat,$lon,$z) = getMapView();
	if (defined $lat)
	{
		push @out,{
			kind  => 'here',
			where => 'where you are looking',
			at    => [ $lat,$lon ],
			why   => "the map's centre at z$z",
		};
	}
	elsif (my $sel = _selectionPlace())
	{
		push @out,$sel;
	}

	return @out;
}


#---------------------------------------------
# one column
#---------------------------------------------

sub _classify
	# ONE LEVEL, FROM THE BODY.  The status decides almost nothing here.
{
	my ($source,$got) = @_;

	if ($got->{status} eq 'ok')
	{
		my $len = length(${$got->{bytes}});

		# THE FILE'S OWN DECLARATION FIRST, and asked of dm_fetch rather
		# than measured here - see fetchDeclaredAbsent.

		return { state => 'blank', bytes => $len, format => $got->{format},
			why => 'the bytes match an absent_fingerprint this file declares' }
			if fetchDeclaredAbsent($source,$got->{bytes});

		return { state => 'tile', bytes => $len, format => $got->{format},
			md5 => md5_hex(${$got->{bytes}}) };
	}

	return { state => 'none', http => $got->{http}, why => $got->{reason} }
		if $got->{status} eq 'absent';

	# AND WHAT THE SERVER SAID, CARRIED WHOLE.  It is the only part of a
	# failure that explains itself, and this module does not paraphrase it.

	my $said = $got->{said};
	my $class = $got->{class} // '';

	return { state => 'refused', http => $got->{http},
		why => $got->{reason}, ($said ? ( said => $said ) : ()) }
		if $class eq 'auth';
	return { state => 'garbage', http => $got->{http},
		why => $got->{reason}, ($said ? ( said => $said ) : ()) }
		if $class eq 'garbage';

	return { state => 'error', http => $got->{http},
		why => $got->{reason}, ($said ? ( said => $said ) : ()) };
}


sub _column
	# EVERY LEVEL THE FILE DECLARES, at one point, in order.
{
	my ($source,$place,$prog) = @_;

	my $lo = $source->{zoom}{min};
	my $hi = $source->{zoom}{max};
	$hi = $lo + $MAX_LEVELS - 1 if $hi - $lo + 1 > $MAX_LEVELS;

	my $col = { %$place, levels => [], zmin => $lo, zmax => $hi };

	for my $z ($lo .. $hi)
	{
		return undef if progressCancelled($prog);

		if ($prog)
		{
			$prog->{sub_label} = "$place->{where} - z$z";
			$prog->{sub_done}++;
		}

		my ($x,$y) = _tileAt($place->{at}[0],$place->{at}[1],$z);
		my $got    = fetchTile($source,$z,$x,$y);
		my $lev    = _classify($source,$got);

		$lev->{z} = $z;
		$lev->{tile} = "$z/$x/$y";
		$lev->{ms} = $got->{ms};
		push @{$col->{levels}},$lev;

		display($dbg_verify+1,1,"$place->{where} z$z $lev->{state}".
			(defined $lev->{bytes} ? " $lev->{bytes} bytes" : ''));
	}

	_suspect($source,$col);
	display($dbg_verify,0,"column at $place->{where}: ".
		(_span($col) || 'nothing at any declared level'));
	return $col;
}


sub _suspect
	# WHAT THE OBSERVATION RECORD ALREADY KNOWS, MARKED ON THE COLUMN.
	#
	# NOTHING IS COMPUTED HERE.  Repeated bodies are learned in dm_fetch,
	# where every tile this application receives passes, so a second rule
	# in this module would be a second opinion about the same evidence and
	# free to disagree with it on screen.
	#
	# IT STILL WORKS ON A SERVICE NEVER FETCHED BEFORE, which was the one
	# reason to keep a local rule: this column's OWN fetches went through
	# dm_fetch on the way here.  Esri's fill answers four levels of a
	# column, so it reaches the record's threshold during the run that is
	# about to report it.
	#
	# AND SIZE ALONE MARKS NOTHING.  A nearly uniform tile compresses to a
	# few hundred bytes whether it is a server's blank or the Caribbean,
	# and this application is pointed at water more than at anything else.
	# Measured: Esri at Bocas del Toro answers z14 to z18 with 865 to 1089
	# byte tiles against a column middle of 8259, and every one of them is
	# real imagery of the sea.
{
	my ($source,$col) = @_;

	my %known = map { $_->{md5} => $_ } verifyNewCandidates($source);
	return if !%known;

	for my $lev (@{$col->{levels}})
	{
		next if $lev->{state} ne 'tile';
		my $c = $known{$lev->{md5} // ''} or next;
		$lev->{flag}  = 'poss sentinel';
		$lev->{offer} = $c;
	}
}


sub _sameAll
	# WHETHER EVERY LEVEL ANSWERED THE SAME WAY, and what it said.
	#
	# THE LEVELS ARE STILL ALL PRINTED.  A column of twenty lines is read
	# at a glance by a person and collapsing it would take away the shape,
	# which is the thing worth seeing.  What a uniform column needs is not
	# fewer lines but ONE SENTENCE saying it was uniform and what the
	# service said, since twenty repetitions of 'not a recognised image'
	# answer nothing and the sentence answers everything.
{
	my ($col) = @_;
	my @lev = @{$col->{levels}};
	return undef if scalar(@lev) < 3;

	my $first = $lev[0];
	for my $l (@lev)
	{
		return undef if $l->{state} ne $first->{state};
		return undef if ($l->{why} // '') ne ($first->{why} // '');
		return undef if ($l->{said} // '') ne ($first->{said} // '');
	}
	return undef if $first->{state} eq 'tile';
	return $first;
}


sub _span
	# Which levels held a tile, or '' if none did.  The PHRASE is the
	# caller's, because a log line and a report say it differently and
	# neither should have to unpick the other's wording.
{
	my ($col) = @_;
	my @have = map { $_->{z} } grep { $_->{state} eq 'tile' } @{$col->{levels}};
	return '' if !@have;

	my @runs;
	my ($from,$prev) = ($have[0],$have[0]);
	for my $z (@have[1 .. $#have])
	{
		if ($z == $prev + 1) { $prev = $z; next; }
		push @runs,($from == $prev ? "z$from" : "z$from-z$prev");
		($from,$prev) = ($z,$z);
	}
	push @runs,($from == $prev ? "z$from" : "z$from-z$prev");
	return join(', ',@runs);
}


#---------------------------------------------
# the unplaced half
#---------------------------------------------

sub _fieldValue
	# A field name may be dotted - zoom.max, policy.min_interval_ms - and
	# the editor names them that way, so the same names have to reach it
	# back or nothing it is told can be painted.
	#
	# AND TWO OF THEM ARE LISTS.  checkSourceField takes the TEXT a person
	# would type, so handing it the stored array stringifies a reference
	# into the check and refuses every well formed file that declares a
	# fingerprint - which is every file this feature is about.
{
	my ($source,$name) = @_;

	return sourceListText($name,$source->{$name})
		if $name eq 'absent_fingerprints' || $name eq 'absent_headers';

	return $source->{$name} if $name !~ /\./;
	my ($a,$b) = split(/\./,$name,2);
	return ref($source->{$a}) eq 'HASH' ? $source->{$a}{$b} : undef;
}


sub _unplaced
	# WHAT CAN BE SETTLED WITHOUT ASKING ANYWHERE.
	#
	# MALFORMED AND REFUTED ARE NOT THE SAME FINDING and are never mixed.
	# A malformed field is wrong on its own terms and nobody had to ask; a
	# refuted one is well formed and the service disagrees with it.  The
	# editor already paints the first in red before this runs, and the
	# second is what it has orange for.
{
	my ($source,$leaf,$out) = @_;

	# THE FILE'S OWN COHERENCE, ASKED OF THE MODULE THAT OWNS THE RULES.
	# A second opinion about what a TSD may be is a second rulebook.

	for my $f (sourceFields())
	{
		my ($name) = @$f;
		my $bad = checkSourceField($name,_fieldValue($source,$name),
			$source->{credentials});
		push @{$out->{malformed}},{ field => $name, why => $bad } if $bad;
	}

	my $why = checkSource($leaf || 'source.tsd',$source);
	push @{$out->{notes}},$why
		if $why && !@{$out->{malformed}};

	# AND WHAT THE SERVICE SAYS ABOUT ITSELF, where it says anything.  Most
	# tile services publish no machine readable description at all, and
	# 'this one does not' is a true answer rather than a failure.

	my $found = metaSource($source);
	$out->{family} = $found->{family};
	$out->{facts}  = $found->{facts} || [];

	if (!$found->{ok})
	{
		push @{$out->{notes}},$found->{reason} if $found->{reason};
		return;
	}

	# A DISAGREEMENT IS ATTACHED TO A FIELD WHERE ONE OWNS IT, because the
	# editor can only paint what it can name.  The rest are read.

	for my $said (@{$found->{disagree}})
	{
		my $field =
			$said =~ /zoom\.max|z\d+ - fetches/ ? 'zoom.max' :
			$said =~ /\bformat\b/               ? 'tile_format' :
			$said =~ /addresses tiles|this file's url/ ? 'url' :
			                                      '';

		if ($field)
		{
			push @{$out->{refuted}},{ field => $field, why => $said };
		}
		else
		{
			push @{$out->{notes}},$said;
		}
	}
}


#---------------------------------------------
# the verdict
#---------------------------------------------

sub _verdict
	# THREE OUTCOMES AND NOT TWO.
	#
	#	problems   something was refuted, or the service refused
	#	verified   a tile arrived at the canonical point and is imagery
	#	unrefuted  it answered and little was proven - which is the honest
	#	           result for a service that publishes no metadata and has
	#	           no canonical point, and is NOT a pass
	#
	# ONLY THE CANONICAL COLUMN CAN VERIFY.  Your column has nothing to be
	# compared against, so an empty one there is a finding about a place
	# and never about the source.
{
	my ($out) = @_;

	return 'problems' if @{$out->{refuted}} || @{$out->{malformed}};

	my ($can) = grep { $_->{kind} eq 'canonical' } @{$out->{columns}};

	if ($can)
	{
		my @bad = grep { $_->{state} eq 'refused' || $_->{state} eq 'garbage' }
			@{$can->{levels}};
		return 'problems' if @bad;

		my @have = grep { $_->{state} eq 'tile' } @{$can->{levels}};
		return 'verified' if @have;
		return 'problems';
	}

	# NO CANONICAL POINT.  Anything that refused anywhere is still a
	# problem; anything else is simply unproven.

	for my $col (@{$out->{columns}})
	{
		return 'problems'
			if grep { $_->{state} eq 'refused' || $_->{state} eq 'garbage' }
				@{$col->{levels}};
	}
	return 'unrefuted';
}


sub verifySource
	# ($source,$places,$prog) -> the finding.  $places is what
	# verifyPlaces returned; passing none makes this the unplaced half
	# alone, which is a legitimate thing to want and is what a source with
	# nowhere to be asked gets.
{
	my ($source,$places,$prog,$leaf) = @_;

	my $out = {
		id        => $source->{id},
		name      => $source->{name},
		malformed => [],
		refuted   => [],
		notes     => [],
		columns   => [],
		facts     => [],
	};

	# NOWHERE TO WALK WITHOUT A RANGE.  A file whose zoom is not two
	# integers cannot have a column asked of it, and saying so beats
	# dying inside the loop on a hash the editor is halfway through.

	my $zok = ref($source->{zoom}) eq 'HASH' &&
		defined($source->{zoom}{min}) && $source->{zoom}{min} =~ /^\d+$/ &&
		defined($source->{zoom}{max}) && $source->{zoom}{max} =~ /^\d+$/ &&
		$source->{zoom}{min} <= $source->{zoom}{max};
	$places = [] if !$zok;

	if ($prog)
	{
		$prog->{phase}     = 'Reading the file and asking the service about itself';
		$prog->{total}     = 1 + scalar(@{$places || []});
		$prog->{done}      = 0;
		$prog->{sub_total} = 0;
	}

	_unplaced($source,$leaf,$out);
	$prog->{done} = 1 if $prog;

	for my $place (@{$places || []})
	{
		last if progressCancelled($prog);

		if ($prog)
		{
			$prog->{phase} = $place->{kind} eq 'canonical' ?
				"Asking at $place->{where}, where it should have imagery" :
				"Asking at $place->{where}";
			$prog->{sub_total} = $source->{zoom}{max} - $source->{zoom}{min} + 1;
			$prog->{sub_done}  = 0;
		}

		my $col = _column($source,$place,$prog);
		last if !$col;
		push @{$out->{columns}},$col;
		$prog->{done}++ if $prog;
	}

	$out->{cancelled} = 1 if progressCancelled($prog);
	$out->{verdict}   = $out->{cancelled} ? 'cancelled' : _verdict($out);

	display($dbg_verify,0,"verifySource($out->{id}) $out->{verdict}, ".
		scalar(@{$out->{refuted}})." refuted, ".
		scalar(@{$out->{columns}})." column(s)");
	return $out;
}


#---------------------------------------------
# rendering
#---------------------------------------------
# ONE RENDERING, THREE SURFACES - the dialog, the console and a headless
# test read exactly the same lines.  The same reason dm_meta renders its
# own findings: text only a wx control can produce is text no test can
# read, and this is the text somebody decides on.

my %HEADLINE = (
	verified  => 'It works.',
	unrefuted => 'Nothing was disproved, and little was proved.',
	problems  => 'There are problems.',
	cancelled => 'Stopped. Nothing was decided.',
);

my %MARK = (
	tile    => 'tile',
	blank   => 'BLANK',
	none    => '-',
	refused => 'REFUSED',
	garbage => 'NOT AN IMAGE',
	error   => 'error',
);


sub verifyNewCandidates
	# ($source) -> the candidates worth putting in front of somebody.
	#
	# THREE THINGS DISQUALIFY ONE, and they are the whole of the filter:
	# seen once, because one sighting of a body is a tile; already declared,
	# because the file has answered that question; and already declined,
	# because asking somebody something they have answered is the fastest
	# way to make them stop reading dialogs.
	#
	# HERE RATHER THAN IN EACH SURFACE.  The editor asks it after a Test, a
	# build report asks it at the end of a build, and the probe pane asks it
	# when a run stops.  Three copies of this would be three chances to
	# offer something one of them should not have.
{
	my ($source) = @_;
	return () if !$source;

	my %declared = map { lc($_->{md5} // '') => 1 }
		@{ $source->{absent_fingerprints} || [] };
	my %declined = map { $_ => 1 } obsDeclined($source);

	return grep { $_->{count} >= $OFFER_AT &&
				  !$declared{$_->{md5}} &&
				  !$declined{$_->{md5}} } obsCandidates($source);
}


sub verifyOffers
	# The candidates this finding touched, highest count first.  ONE walk,
	# here, because the dialog offers them, the editor accepts them and the
	# report prints them, and three walks would be three chances to differ.
{
	my ($out) = @_;
	return () if !$out;

	my %seen;
	for my $col (@{$out->{columns} || []})
	{
		for my $lev (@{$col->{levels} || []})
		{
			$seen{$lev->{offer}{md5}} = $lev->{offer} if $lev->{offer};
		}
	}
	return sort { $b->{count} <=> $a->{count} } values %seen;
}


sub verifyHeadline
{
	my ($out) = @_;
	return '' if !$out;
	return $HEADLINE{ $out->{verdict} // _verdict($out) } || '';
}


sub verifyLines
{
	my ($out) = @_;
	return ['nothing was verified'] if !$out;

	my @l;
	push @l,($out->{name} // $out->{id} // 'this source');
	push @l,'';

	if (@{$out->{malformed}})
	{
		push @l,'THIS FILE IS NOT WELL FORMED, AND NOBODY HAD TO ASK:';
		push @l,'';
		for my $r (@{$out->{malformed}})
		{
			push @l,wrapText("  $r->{field} - $r->{why}",76);
		}
		push @l,'';
	}

	if (@{$out->{refuted}})
	{
		push @l,'DISPROVED BY THE SERVICE:';
		push @l,'';
		for my $r (@{$out->{refuted}})
		{
			push @l,wrapText("  $r->{field} - $r->{why}",76);
		}
		push @l,'';
	}

	push @l,'Those fields are shown in the source editor, where they can be',
		'corrected. Nothing here has been changed.',''
		if @{$out->{malformed}} || @{$out->{refuted}};

	for my $n (@{$out->{notes}})
	{
		push @l,wrapText("  $n",76);
		push @l,'';
	}

	# THE COLUMNS, EACH SAYING WHERE IT WAS ASKED AND WHY THERE.  A column
	# without its place is a table of numbers about nowhere.

	for my $col (@{$out->{columns}})
	{
		push @l,($col->{kind} eq 'canonical' ?
			"AT $col->{where} - where this service should have imagery" :
			"AT $col->{where}");
		push @l,sprintf("   %.4f, %.4f",@{$col->{at}});
		push @l,map { "   $_" } wrapText($col->{why},73)
			if defined $col->{why} && $col->{why} =~ /\S/;
		push @l,'';

		for my $lev (@{$col->{levels}})
		{
			my $mark = $MARK{$lev->{state}} // $lev->{state};
			my $said = $lev->{state} eq 'tile' ?
				sprintf("%s, %d bytes",$lev->{format},$lev->{bytes}) :
				($lev->{why} // '');
			$said .= "   $lev->{flag}" if $lev->{flag};
			push @l,sprintf("   z%-3d %-13s %s",$lev->{z},$mark,$said);
		}

		push @l,'';

		my $span = _span($col);
		push @l,($span ? "   imagery at $span"
					   : '   no imagery at any declared level');

		# ONE SENTENCE FOR A COLUMN THAT ANSWERED THE SAME WAY THROUGHOUT,
		# and the service's own words under it.  Twenty repetitions of
		# 'not a recognised image' say nothing; the four words the server
		# actually sent say all of it.

		my $same = _sameAll($col);
		if ($same)
		{
			push @l,sprintf("   every one of the %d levels answered the ".
				"same way",scalar(@{$col->{levels}}));
			push @l,map { "   $_" }
				wrapText("the service said: $same->{said}",73)
				if $same->{said};
		}

		push @l,map { "   $_" } wrapText('Nothing here is a fault in the '.
			'source: this is where you were looking, and a service may '.
			'simply hold nothing here.',73)
			if $col->{kind} ne 'canonical' && !$span;
		push @l,'';
	}

	# THE OFFER, LAST, AND IT IS AN OFFER.

	# THE CANDIDATES THIS SOURCE HAS ACCUMULATED, which are a fact about
	# the service rather than about this run - so the count is what is
	# shown, and it can be far larger than anything this column saw.

	my @offers = verifyOffers($out);
	if (@offers)
	{
		push @l,'A BLANK THIS FILE DOES NOT DECLARE:';
		push @l,'';
		push @l,wrapText('  One image is answering unrelated places, which '.
			'no imagery does. Declaring it as an absent_fingerprint would '.
			'let every part of this application tell that tile from '.
			'imagery. Nothing has been declared.',76);
		push @l,'';
		for my $s (@offers)
		{
			push @l,sprintf("    %d bytes, md5 %s",$s->{bytes},$s->{md5});
			push @l,sprintf("    seen %d times, first at z%d/%d/%d",
				$s->{count},$s->{z},$s->{x},$s->{y});
		}
		push @l,'';
	}

	if (!@{$out->{columns}})
	{
		push @l,'NOWHERE TO ASK.';
		push @l,'';
		push @l,wrapText('  Nothing was fetched, because this source has no '.
			'canonical point in the catalog and the map is not open to '.
			'supply one. Nothing above was learned from a tile. Open the '.
			'map somewhere this service covers and test again.',76);
		push @l,'';
	}

	push @l,'Nothing was written, here or on disk.';
	return \@l;
}


#---------------------------------------------
# the worker
#---------------------------------------------

sub verifyWorker
	# ON A WORKER, ALWAYS, AND NOT BECAUSE OF THE COUNT.  A dead host burns
	# the whole timeout before anything at all is known, and that is exactly
	# the case where somebody most needs to see that it is asking rather
	# than hung.
	#
	# THE ANSWER CROSSES AS TEXT, for the reason the expander's does: a nest
	# of hashes cannot cross as a reference, and cloning it into shared
	# memory would make a second representation free to drift from the
	# first.
{
	my ($prog,$args) = @_;
	my ($json,$places_json,$leaf) = @$args;

	my $source = eval { decode_json($json) };
	my $places = eval { decode_json($places_json || '[]') };

	my $out = $source ?
		eval { verifySource($source,$places,$prog,$leaf) } :
		{ verdict => 'problems', refuted => [], malformed => [],
		  notes => [ 'the source could not be read' ],
		  columns => [], facts => [] };

	$out ||= { verdict => 'problems', refuted => [], malformed => [],
		notes => [ "the verifier failed: $@" ], columns => [], facts => [] };

	$prog->{json}     = eval { encode_json($out) } || '';
	$prog->{ok}       = ($out->{verdict} eq 'problems') ? 0 : 1;
	$prog->{finished} = 1;
}


1;
