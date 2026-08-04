#!/usr/bin/perl
#---------------------------------------------
# dm_catalog.pm
#---------------------------------------------
# THE SHIPPED CATALOG OF TILE SERVICES -- reading it, and turning one of
# its entries into the field hash a TSD is written from.
#
# IT IS APPLICATION MATERIAL, NOT USER DATA.  It is read from
# $resource_dir, which Pub::Utils resolves to the in-repo _res folder in
# development and to the bundled resource folder when packaged.  It is
# never copied into $data_dir, never edited in place, and never scanned
# for by dm_source.  That is the whole reason it can be presumed coherent
# with this code and with docs/notes/source_catalog.md: it ships and
# updates with them, where a copy-on-install would have gone stale the
# first time a service moved.
#
# IT KNOWS NOTHING ABOUT SOURCES.  Every rule about what a TSD may be, and
# every question about what is already installed, belongs to dm_source.
# This module produces a field hash and hands it over; it does not use
# dm_source and must not start.  catalogPlan is the one place the two
# meet, and it meets by being TOLD what is installed rather than by asking
# -- which is also what makes it testable with no folder anywhere.
#
# A NODE IS A GROUP OR AN ENTRY.  A node carrying 'nodes' is a group and a
# node carrying 'tsd' is an entry, and the tree nests to whatever depth
# the file uses rather than to a fixed two.  Services group the way the
# world groups them: GIBS over its layers, Esri over World Imagery and
# Clarity, and something added later will not group like either.
#
# WHAT A CHILD INHERITS is the provider-level statement -- the terms, the
# licence, the attribution, what it may be used for -- and what it never
# inherits is anything naming a particular layer: its id, its name, its
# cache_key, its url, its zoom range.  Without that a provider's terms
# would be repeated once per layer and would eventually disagree with
# itself.
#
# WHAT IT SHIPS IS A STARTING POINT, NOT A FACT.  Nothing here claims to
# be current.  A source created from an entry is UNTESTED by construction;
# the probe is the instrument that says whether it works, and the catalog
# does not pretend to answer a question it cannot ask without the network.
#
# AND IT CARRIES NO DATE.  It ships inside the installer, so the release
# already dates it more accurately than a hand-typed string ever did, and
# a precise date on a claim nobody re-checked reads as currency it has not
# got.  Where a service was last looked at is recorded once, per service,
# in docs/notes/source_catalog.md.
#
# NOTHING HERE GOES TO THE NETWORK.  Enumerating a provider's real layer
# list is a live read of a WMTS or ArcGIS metadata document, it is a
# separate act, and it is not in this phase.  Every node is therefore
# complete as shipped.

package dm_catalog;
use strict;
use warnings;
use JSON::PP;
use Pub::Utils;
use cm_defs;
use cm_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		loadCatalog
		catalogError
		catalogRoot
		catalogEntries
		catalogEntry
		catalogTsd
		catalogLeaf
		catalogLabel
		catalogMatches
		catalogLines
		catalogPlan
		catalogPlanLines
		catalogExpander
		catalogAttach
	);
}


our $dbg_catalog = 0;
	# 0  = the load summary
	# -1 = one line per node


my $CATALOG_VERSION = 1;

my @INHERIT_NODE = qw( moniker region cost buildable requires canonical );
	# THE PROVIDER-LEVEL STATEMENT.  Terms and reach belong to the service
	# and not to one of its layers, so they are said once.
	#
	# moniker IS THE JOIN COLUMN.  It names the SERVICE, and it is the same
	# string in the survey, in docs/notes/source_catalog.md and here, which
	# is what makes a claim at one end of the pipeline checkable at the
	# other.  It is inherited because a provider's layers are all the same
	# service; where a provider publishes several - Esri does - the child
	# says its own and the child's value wins outright.
	#
	# It is NOT the id.  An id names an entry and a moniker names the thing
	# the entry is an entry OF, so 'linz' publishes 'linz_aerial'.  Keeping
	# them identical would give a service a name that reads like a layer
	# the day it gains a second one.
	#
	# canonical IS ON THIS LIST BECAUSE WHERE A SERVICE HAS IMAGERY IS A
	# FACT ABOUT THE SERVICE.  Every layer NASA GIBS publishes covers the
	# same ground; asking each of them to name its own place would be a
	# thousand copies of one answer, free to disagree.

my $NUM = qr/^-?\d+(?:\.\d+)?$/;

my @INHERIT_TSD  = qw( tile_format attribution terms_url license
					   redistributable uses policy subdomains credentials );

my @NEVER_INHERIT_TSD = qw( name cache_key url zoom notes
							absent_fingerprints absent_headers displacement );
	# Documentation rather than code: everything not in @INHERIT_TSD is
	# already not inherited.  Listed so that adding a field to the TSD
	# format makes somebody decide which list it is on.


my $loaded  = 0;
my $error   = '';
my @root    = ();
my @entries = ();
my %by_id   = ();


#---------------------------------------------
# loading
#---------------------------------------------

sub catalogPath
{
	return "$resource_dir/catalog.json";
}


sub _err
{
	my ($why) = @_;
	$error = $why;
	error("catalog: $why");
	return $why;
}


sub _ascii
	# THE SAME RULE THE TSD FORMAT KEEPS, and kept here so that a
	# character which could not survive being written into a source is
	# refused where it was authored rather than where it is copied.
{
	my ($val) = @_;
	return 0 if !defined $val;
	return 0 if ref $val;
	return $val =~ /[^\x20-\x7E\r\n\t]/ ? 1 : 0;
}


sub _scanAscii
{
	my ($thing,$where) = @_;
	if (ref($thing) eq 'HASH')
	{
		for my $k (sort keys %$thing)
		{
			return "$where.$k" if _ascii($k);
			my $bad = _scanAscii($thing->{$k},"$where.$k");
			return $bad if $bad;
		}
		return '';
	}
	if (ref($thing) eq 'ARRAY')
	{
		for my $i (0 .. $#$thing)
		{
			my $bad = _scanAscii($thing->[$i],$where."[$i]");
			return $bad if $bad;
		}
		return '';
	}
	return _ascii($thing) ? $where : '';
}


sub _resolve
	# One raw node into a resolved one, carrying what it inherited.
	# Recursive, and the recursion is what makes the depth arbitrary.
{
	my ($raw,$parent,$path,$seen) = @_;

	return "a node is not an object" if ref($raw) ne 'HASH';

	my $id = $raw->{id};
	return "a node has no id" if !defined($id) || ref($id);
	return "node id '$id' must be lower case letters, digits, '_' or '-'"
		if $id !~ /^[a-z0-9_-]+$/;
	return "node id '$id' appears twice" if $seen->{$id}++;
	return "node '$id' has no name"
		if !defined($raw->{name}) || ref($raw->{name}) || $raw->{name} !~ /\S/;

	my $is_group = defined $raw->{nodes};
	my $is_entry = defined $raw->{tsd} && !$is_group;

	return "node '$id' is neither a group nor an entry - it needs 'nodes' or 'tsd'"
		if !$is_group && !$is_entry;

	my $node = {
		id       => $id,
		name     => $raw->{name},
		is_entry => $is_entry ? 1 : 0,
		path     => $path ? "$path / $raw->{name}" : $raw->{name},
		brief    => $raw->{brief},
		depth    => $raw->{depth},
		value    => $raw->{value},
		notes    => $raw->{notes},
		kids     => [],
	};

	# WHAT IT INHERITED, AND WHAT IT SAID FOR ITSELF.  The child's own
	# value wins outright rather than being merged into its parent's,
	# because a half-overridden policy or licence is a statement nobody
	# wrote.

	for my $k (@INHERIT_NODE)
	{
		$node->{$k} = defined $raw->{$k} ? $raw->{$k} :
			($parent ? $parent->{$k} : undef);
	}

	# THE CANONICAL POINT: ONE PLACE THIS SERVICE IS KNOWN TO HAVE IMAGERY.
	#
	# A SERVICE CANNOT BE ASKED ABOUT NOWHERE.  Every question worth putting
	# to a tile service is placed - is this url right, how deep does it go,
	# is that a tile or a blank - and the answer is only as good as the
	# place.  Measured: a service labelled 'Japan' serves real imagery over
	# Panama at z3 and z8 and nothing at z12, and one labelled 'France'
	# serves Bocas del Toro at z12, so the REGION prose predicts nothing and
	# neither does the middle of a bounding box.
	#
	# CHOSEN BY A PERSON, WHICH IS WHY IT IS IN THE CATALOG.  A point is a
	# judgement - somewhere this service certainly flew, on a coast, because
	# that is what this application is for - and judgements ship beside the
	# terms and the licence rather than being derived at runtime.
	#
	# 'at' MAY BE ABSENT, AND THAT IS AN ANSWER.  A service whose imagery is
	# nowhere near a coast is one this application cannot use, so having no
	# good point is a finding about its fit rather than a gap in the file.
	# Saying so out loud beats an empty field that reads as an oversight.
	#
	# IT IS NOT A MEASUREMENT AND CARRIES NO RESULT.  What the service
	# answers there is dm_verify's to find out and changes with the weather;
	# what is written here is only WHERE TO ASK.

	if (defined $raw->{canonical})
	{
		my $c = $raw->{canonical};
		return "node '$id' has a 'canonical' that is not an object"
			if ref($c) ne 'HASH';
		return "node '$id' canonical needs a 'where' and a 'why'"
			if !defined($c->{where}) || ref($c->{where}) ||
			   $c->{where} !~ /\S/ ||
			   !defined($c->{why}) || ref($c->{why}) || $c->{why} !~ /\S/;

		if (defined $c->{at})
		{
			return "node '$id' canonical 'at' must be [ lat, lon ]"
				if ref($c->{at}) ne 'ARRAY' || scalar(@{$c->{at}}) != 2;

			my ($lat,$lon) = @{$c->{at}};
			return "node '$id' canonical latitude '$lat' is not a number ".
					"between -85 and 85"
				if !defined($lat) || ref($lat) || $lat !~ $NUM ||
				   $lat < -85 || $lat > 85;
			return "node '$id' canonical longitude '$lon' is not a number ".
					"between -180 and 180"
				if !defined($lon) || ref($lon) || $lon !~ $NUM ||
				   $lon < -180 || $lon > 180;
		}
	}

	my %tsd;
	if ($parent && $parent->{tsd})
	{
		$tsd{$_} = $parent->{tsd}{$_}
			for grep { defined $parent->{tsd}{$_} } @INHERIT_TSD;
	}
	if (defined $raw->{tsd})
	{
		return "node '$id' has a 'tsd' that is not an object"
			if ref($raw->{tsd}) ne 'HASH';
		$tsd{$_} = $raw->{tsd}{$_} for keys %{$raw->{tsd}};
	}
	$node->{tsd} = \%tsd;

	if ($is_entry)
	{
		return "entry '$id' has no url"
			if !defined($tsd{url}) || $tsd{url} !~ /\S/;
		return "entry '$id' has no zoom range"
			if ref($tsd{zoom}) ne 'HASH';
		return "entry '$id' has no attribution"
			if !defined($tsd{attribution}) || $tsd{attribution} !~ /\S/;
		display($dbg_catalog+1,1,"entry $id");
	}
	else
	{
		return "group '$id' has a 'nodes' that is not an array"
			if ref($raw->{nodes}) ne 'ARRAY';

		# AN EMPTY GROUP IS ONLY LEGAL IF IT CAN FILL ITSELF.  Esri
		# Wayback publishes over a hundred archived releases and ships
		# none of them: pinning one here would mean choosing a release on
		# somebody's behalf and inventing an identifier that only the
		# service knows.  A provider whose whole content is what it
		# publishes live is a real shape, and it is the shape the expander
		# was built for.

		return "group '$id' is empty and declares no expander, so nothing ".
				"could ever appear under it"
			if !@{$raw->{nodes}} && !defined $raw->{expander};

		# ONLY A GROUP MAY DECLARE AN EXPANDER, because what comes back is
		# a LIST and a list has to hang under something.  An entry that
		# could expand would have to become a group on being asked, which
		# is a second shape for a node to be in and a second set of rules
		# for everything that walks the tree.
		#
		# THE CAPABILITIES URL IS STATED, NOT DERIVED.  GIBS publishes a
		# RESTful document at a path; IGN France and Spain IGN answer a
		# KVP query.  Deriving it from a tile url would work for the first
		# and silently fail for the others.

		if (defined $raw->{expander})
		{
			my $x = $raw->{expander};
			return "group '$id' has an 'expander' that is not an object"
				if ref($x) ne 'HASH';
			return "group '$id' expander needs a 'kind' and a 'url'"
				if !defined($x->{kind}) || !defined($x->{url});
			return "group '$id' declares expander kind '$x->{kind}', ".
					"which this application cannot read"
				if $x->{kind} ne 'wmts';
			$node->{expander} = { kind => $x->{kind}, url => $x->{url} };
		}
		display($dbg_catalog+1,1,"group $id");
		for my $kid (@{$raw->{nodes}})
		{
			my $rslt = _resolve($kid,$node,$node->{path},$seen);
			return $rslt if !ref($rslt);
			push @{$node->{kids}},$rslt;
		}
	}

	return $node;
}


sub _flatten
{
	my ($nodes) = @_;
	my @out;
	for my $n (@$nodes)
	{
		push @out,$n if $n->{is_entry};
		push @out,_flatten($n->{kids}) if @{$n->{kids}};
	}
	return @out;
}


sub loadCatalog
	# Returns '' or the one reason the catalog is not usable.
	#
	# A FAILURE HERE IS A BUG, NOT A USER ERROR.  This file ships with the
	# application, so nothing a user did can break it and no repair is
	# available to them - which is why it reports once, plainly, and the
	# dialog says the catalog is unavailable rather than offering to fix
	# anything.
{
	my ($force) = @_;
	return $error if $loaded && !$force;

	$loaded  = 1;
	$error   = '';
	@root    = ();
	@entries = ();
	%by_id   = ();

	my $path = catalogPath();
	return _err("not found at $path") if !-f $path;

	my $fh;
	return _err("could not read $path: $!") if !open($fh,'<',$path);
	binmode $fh;
	local $/ = undef;
	my $text = <$fh>;
	close $fh;

	my $cat = eval { JSON::PP->new->decode($text) };
	return _err("$path is not valid JSON: $@") if $@ || !$cat;
	return _err("catalog is not a JSON object") if ref($cat) ne 'HASH';

	my $bad = _scanAscii($cat,'catalog');
	return _err("$bad contains a character that is not plain ASCII") if $bad;

	my $ver = $cat->{catalog_version};
	return _err("catalog_version must be an integer")
		if !defined($ver) || $ver !~ /^\d+$/;
	return _err("catalog_version $ver is newer than this application ".
		"understands ($CATALOG_VERSION)") if $ver > $CATALOG_VERSION;

	return _err("catalog has no 'nodes' array")
		if ref($cat->{nodes}) ne 'ARRAY' || !@{$cat->{nodes}};

	my %seen;
	for my $raw (@{$cat->{nodes}})
	{
		my $node = _resolve($raw,undef,'',\%seen);
		return _err($node) if !ref($node);
		push @root,$node;
	}

	@entries = _flatten(\@root);
	$by_id{$_->{id}} = $_ for @entries;

	display($dbg_catalog,0,"loadCatalog() ".scalar(@root)." providers, ".
		scalar(@entries)." entries");
	return '';
}


sub catalogError   { return $error }

sub catalogRoot
{
	loadCatalog();
	return \@root;
}

sub catalogEntries
{
	loadCatalog();
	return \@entries;
}

sub catalogEntry
{
	my ($id) = @_;
	loadCatalog();
	return $by_id{$id};
}


#---------------------------------------------
# an entry as a TSD
#---------------------------------------------

sub catalogTsd
	# The field hash this entry would be written as.
	#
	# tsd_version, tile_size and crs are put in here rather than in the
	# file, for the reason the editor puts them back: each has exactly one
	# legal value, and a catalog able to state them is a catalog able to
	# state them wrongly.
{
	my ($node) = @_;
	return undef if !$node || !$node->{is_entry};

	my %tsd = %{$node->{tsd}};
	$tsd{tsd_version} = 1;
	$tsd{tile_size}   = 256;
	$tsd{crs}         = 'EPSG:3857';
	$tsd{id}          = $node->{id};

	# THE NAME THE FILE CARRIES IS THE FULL ONE.  In the tree an entry is
	# read under its provider, so its own name is short; on its own in a
	# source list it has to say whose imagery it is.  An entry may state
	# the whole name itself, and where it does not it is composed from the
	# path it was found at.

	$tsd{name} = $node->{path} if !defined $tsd{name} || $tsd{name} !~ /\S/;
	$tsd{name} =~ s{ / }{ - }g;

	return \%tsd;
}


sub catalogLeaf
	# THE FILE NAME THIS ENTRY SUGGESTS.  cache_key first, because that is
	# what the user will see as a folder in the tile cache and having the
	# two agree is worth more than having the file agree with the id.
{
	my ($node) = @_;
	return '' if !$node || !$node->{is_entry};
	my $base = $node->{tsd}{cache_key} || $node->{id};
	return "$base.tsd";
}


#---------------------------------------------
# what a person reads
#---------------------------------------------

sub catalogLabel
	# THE ONE LINE IN THE TREE.  A tree has no columns, so the two or
	# three facts that decide whether an entry is worth opening have to
	# travel in the label itself - depth, where, and what it costs.  They
	# are stated by the entry rather than composed here, because the
	# useful compression is different for each: a source with no ceiling
	# needs to say 'stated' or 'real', and an overlay has no depth at all.
{
	my ($node) = @_;
	return '' if !$node;
	return $node->{name} if !defined $node->{brief} || $node->{brief} !~ /\S/;
	return "$node->{name}   -   $node->{brief}";
}


sub catalogMatches
	# Whether the filter box's text picks this node out.  EVERYTHING A
	# PERSON CAN SEE ABOUT IT IS SEARCHED, including the sentence about
	# what it is worth: somebody hunting for 'reef' or 'Caribbean' is
	# searching the judgement rather than the identifier.
{
	my ($node,$text) = @_;
	return 1 if !defined $text || $text !~ /\S/;
	my $pat = lc $text;
	for my $k (qw( id name brief region cost depth value buildable requires ))
	{
		my $v = $node->{$k};
		next if !defined $v || ref $v;
		return 1 if index(lc $v,$pat) >= 0;
	}
	return 0;
}


my $WRAP = 72;
	# THE PANEL IS THE WIDTH OF THE DIALOG AT ITS DEFAULT SIZE, in
	# characters of the 8 point teletype face it is drawn in.  Measured off
	# the running dialog rather than derived: the panel is about 528 pixels
	# inside its border and that face runs a shade over 7 pixels a
	# character.
	#
	# A FIXED COLUMN AND NOT THE CONTROL'S CURRENT WIDTH, because this
	# module has no control and must not acquire one - the whole reason the
	# panel is rendered here is that a headless test can read it.  Somebody
	# who widens the dialog gets short lines rather than long ones, which
	# is the harmless direction to be wrong in.

my $LVAL = 16;
	# The label column every pair below is laid out on.


sub _para
	# A paragraph, wrapping back to the left margin.
{
	my ($out,$text) = @_;
	push @$out,wrapText($text,$WRAP);
}


sub _pair
	# A labelled value, wrapping to the VALUE's column rather than to the
	# margin.  A continuation that fell back to column zero would read as a
	# new unlabelled paragraph, which for a licence sitting under an
	# attribution is exactly the confusion worth avoiding.
	#
	# A value with no spaces - every url here - is longer than the column
	# and stays on one line, because wrapText does not break words.  That
	# overflows the panel and produces a horizontal scrollbar, which is the
	# right outcome: a url broken across lines cannot be copied.
{
	my ($out,$label,$val) = @_;
	return if !defined $val;

	my @w = wrapText($val,$WRAP - $LVAL - 1);
	push @$out,sprintf("%-*s %s",$LVAL,$label,(shift(@w) // ''));
	push @$out,(' ' x ($LVAL + 1)).$_ for @w;
}


sub catalogLines
	# The detail panel, as lines.  HERE RATHER THAN IN THE DIALOG for the
	# same reason the probe's rendering is in dm_sample: a panel that could
	# only be produced by a wx control is a panel no headless test can
	# read, and this is the text that decides whether somebody creates a
	# source.
{
	my ($node) = @_;
	return ['no entry selected'] if !$node;

	my @out;
	_para(\@out,$node->{path});
	push @out,'';

	if (!$node->{is_entry})
	{
		_pair(\@out,'group',
			scalar(@{$node->{kids}})." entr".
			(@{$node->{kids}} == 1 ? 'y' : 'ies')." below this");
		_pair(\@out,'expandable',
			"this service publishes a $node->{expander}{kind} ".
			"capabilities document - Expand asks it what layers it ".
			"holds today") if $node->{expander};
		push @out,'';
	}

	for my $f ( [ 'region','region' ], [ 'cost','cost' ],
				[ 'depth','real depth' ], [ 'buildable','buildable' ],
				[ 'requires','requires' ] )
	{
		my ($key,$label) = @$f;
		next if !defined $node->{$key} || $node->{$key} !~ /\S/;
		_pair(\@out,$label,$node->{$key});
	}

	# WHERE TO ASK IT, AND WHY THERE.  The reason is shown rather than kept,
	# because a bare pair of numbers in a list of licences reads as noise
	# and the whole point of the point is the judgement behind it.

	if (my $c = $node->{canonical})
	{
		_pair(\@out,'ask it at',defined $c->{at} ?
			sprintf("%s   %.4f, %.4f",$c->{where},@{$c->{at}}) :
			$c->{where});
		_pair(\@out,'why there',$c->{why});
	}

	if (defined $node->{value} && $node->{value} =~ /\S/)
	{
		push @out,'';
		_para(\@out,$node->{value});
	}

	if ($node->{is_entry})
	{
		my $tsd = catalogTsd($node);
		push @out,'';
		_pair(\@out,'id',$tsd->{id});
		_pair(\@out,'cache_key',$tsd->{cache_key})
			if defined $tsd->{cache_key};
		_pair(\@out,'file',catalogLeaf($node));
		_pair(\@out,'tile_format',$tsd->{tile_format} // 'jpeg');
		_pair(\@out,'zoom',sprintf("%d - %d",
			$tsd->{zoom}{min} // 0,$tsd->{zoom}{max} // 0));
		_pair(\@out,'uses',join(',',@{$tsd->{uses} || []}));
		_pair(\@out,'redistributable',$tsd->{redistributable} // 'unknown');

		# DISPLACEMENT IS ADVISORY AND SAYS SO IN THE SAME BREATH, exactly
		# as the Sources pane says it.  A panel that showed the field
		# without saying nothing acts on it would read as 'handled', and a
		# panel that omitted it - which this one did - would let somebody
		# create a knowingly misregistered source without ever being told.
		#
		# THIS IS THE POINT THE SURVEY NAMED for telling them: where a
		# displacement is known in advance, the moment a source is created
		# from a catalog entry is the moment to say so.

		if (defined $tsd->{displacement} && $tsd->{displacement} =~ /\S/)
		{
			_pair(\@out,'displacement',$tsd->{displacement});
			_pair(\@out,'','this imagery is displaced and chartMaker does '.
				'NOT correct it');
		}

		# A CREDENTIAL SLOT IS SAID OUT LOUD, and so is the fact that
		# nothing fills one yet.  A file written from a keyed entry is
		# well formed and will load; it will not fetch, and finding that
		# out from a failed build would be the worst place to learn it.

		if ($tsd->{credentials} && @{$tsd->{credentials}})
		{
			_pair(\@out,'credentials',
				join(',',map { $_->{slot} } @{$tsd->{credentials}}));
			_pair(\@out,'',
				'the credential store is not implemented - this source '.
				'will load but not fetch');
		}

		push @out,'';
		_pair(\@out,'attribution',$tsd->{attribution});
		_pair(\@out,'terms',$tsd->{terms_url})
			if defined $tsd->{terms_url};
		_pair(\@out,'licence',$tsd->{license})
			if defined $tsd->{license};
		push @out,'';
		_pair(\@out,'url',$tsd->{url});
		if (defined $tsd->{notes} && $tsd->{notes} =~ /\S/)
		{
			push @out,'';
			_para(\@out,$tsd->{notes});
		}
	}

	# THE DATE, LAST AND ALWAYS.  Nothing above claims to be current, and
	# an entry that did not say when it was looked at would be read as
	# though it did.

	if ($node->{fetched})
	{
		push @out,'';
		_para(\@out,'read from the service just now - current by '.
			'construction, and judged by nobody');
		return \@out;
	}

	push @out,'';
	_para(\@out,'surveyed by a person - a starting point for checking, '.
		'not a current fact. When each service was last looked at is '.
		'recorded in docs/notes/source_catalog.md');
	return \@out;
}


#---------------------------------------------
# what a service says it publishes
#---------------------------------------------
# WHAT SHIPS IS COMPLETE AS SHIPPED, and what a service actually publishes
# today is a live read.  The line between them is the rate at which a fact
# changes: terms and licences move on the scale of years and ship, a layer
# list moves on the scale of months and is fetched.
#
# NOTHING FETCHED IS EVER WRITTEN BACK.  These nodes live for as long as
# the dialog does.  Persisting them would recreate exactly the staleness
# that keeping the catalog out of $data_dir was meant to avoid, except
# worse, because a cached layer list looks identical to a current one.

sub catalogExpander
{
	my ($node) = @_;
	return $node ? $node->{expander} : undef;
}


my $FOLD_ID   = 'png_only';
my $FOLD_NAME = 'More - published only as PNG';


sub _isImagery
	# WHAT THE SERVICE ITSELF SAYS, RATHER THAN AN OPINION ABOUT WORTH.
	#
	# A service that publishes both photographs and data products publishes
	# them in different formats, because that is what the two formats are
	# for: a photograph is jpeg and a palette is png.  GIBS makes the point
	# at scale -- 56 of the 1151 layers this application can address serve
	# jpeg, and they are BlueMarble, Landsat, MODIS and VIIRS true colour,
	# while the other 1095 are aerosol depth, brightness temperature, soil
	# moisture and rain rate.  No GIBS layer offers both formats, so there
	# is nothing here to choose between.
	#
	# IT IS A PROXY AND IT LEAKS BOTH WAYS.  Landsat_WELD_NDVI is a jpeg
	# vegetation index, and GOES-West_ABI_GeoColor is a png photograph.
	# That is precisely why what follows FOLDS rather than filters: one
	# click wide, with the rule stated on the node it collapses into, so
	# being wrong about a layer costs the reader a click and never a
	# source.  A usefulness filter would be this module forming an opinion
	# it is not entitled to; reading the format the service published is
	# not one.
{
	my ($lay) = @_;
	return lc($lay->{tile_format} || '') eq 'jpeg' ? 1 : 0;
}


sub _foldNode
	# The group the non-imagery layers hang under, made once and found
	# again on a second expand.  It is a GROUP like any other, so the tree,
	# the filter and the big-group rule need to know nothing about it.
{
	my ($node) = @_;
	my $id = $node->{id}.'_'.$FOLD_ID;

	for my $kid (@{$node->{kids}})
	{
		return $kid if !$kid->{is_entry} && $kid->{id} eq $id;
	}

	my $fold = {
		id       => $id,
		name     => $FOLD_NAME,
		is_entry => 0,
		fetched  => 1,
		path     => $node->{path}.' / '.$FOLD_NAME,
		kids     => [],
	};
	$fold->{$_} = $node->{$_} for @INHERIT_NODE;
	$fold->{value} =
		'This service publishes these layers as PNG and its imagery as '.
		'JPEG, so they are collected here rather than listed among the '.
		'imagery. They are usually data products - a measurement drawn '.
		'through a colour palette rather than a photograph. The format is '.
		'the only thing separating them, and it is a good guide and not a '.
		'verdict, so anything here can be created exactly like anything '.
		'above it.';

	push @{$node->{kids}},$fold;
	return $fold;
}


sub _attachTo
	# ($service,$parent,$layers).  Everything a layer inherits comes from
	# the SERVICE and only where it hangs comes from the parent, so a
	# folded layer carries the same terms and licence as an unfolded one.
{
	my ($service,$parent,$layers) = @_;
	my $node = $service;

	my ($added,$skipped) = (0,0);
	for my $lay (@$layers)
	{
		my $id = lc($node->{id}.'_'.($lay->{id} // ''));
		$id =~ s/[^a-z0-9_-]/_/g;
		$id =~ s/_+/_/g;

		if ($by_id{$id})
		{
			$skipped++;
			next;
		}

		my %tsd = %{ $node->{tsd} || {} };
		$tsd{name}        = $node->{name}.' - '.$lay->{name};
		$tsd{cache_key}   = $id;
		$tsd{url}         = $lay->{url};
		$tsd{zoom}        = { min => $lay->{zmin} + 0, max => $lay->{zmax} + 0 };
		$tsd{tile_format} = $lay->{tile_format} if $lay->{tile_format};
		$tsd{notes}       = $lay->{notes};
		delete $tsd{credentials};

		my $kid = {
			id       => $id,
			name     => $lay->{name},
			is_entry => 1,
			fetched  => 1,
			path     => $parent->{path}.' / '.$lay->{name},
			brief    => "z$lay->{zmax}   read from the service",
			depth    => "z$lay->{zmax}, from the tile matrix set $lay->{tms}",
			tsd      => \%tsd,
			kids     => [],
		};
		$kid->{$_} = $node->{$_} for @INHERIT_NODE;

		# A FETCHED ENTRY WAS NOT SURVEYED, and the 'fetched' flag is what
		# says so.  It did not come from the survey and letting it borrow
		# the survey's voice would be the one lie this whole design is
		# arranged to avoid.

		$kid->{value}    = 'Listed by the service itself rather than '.
			'surveyed by a person, so nothing here says whether the '.
			'imagery is any good. Probe it.';

		push @{$parent->{kids}},$kid;
		push @entries,$kid;
		$by_id{$id} = $kid;
		$added++;
	}
	return ($added,$skipped);
}


sub catalogAttach
	# Hang a service's own layer list under the group that names it.
	# ($node,$layers) -> (added,skipped).  $layers is what dm_meta's
	# serviceLayers returned, and this module knows nothing about how it
	# was obtained -- which is what keeps the protocol reader out of here.
	#
	# A SHIPPED ENTRY WINS OVER A FETCHED ONE OF THE SAME NAME.  The
	# shipped one was curated: it carries a survey, a depth measured by a
	# person and a sentence about what it is worth, none of which a
	# capabilities document contains.  Replacing it with the machine's
	# version would be a downgrade that looked like an update.
	#
	# BOTH KINDS OR NEITHER.  A service publishing only one sort of thing
	# has nothing to fold, and putting its whole list behind a 'more' node
	# would hide everything while separating nothing.  The fold says THESE
	# ARE NOT THE SAME KIND OF THING, which is only worth saying when both
	# kinds arrived.  Esri Wayback's 195 releases are all jpeg and get no
	# fold; GIBS gets 56 layers and a fold holding 1095.
{
	my ($node,$layers) = @_;
	return (0,0) if !$node || ref($layers) ne 'ARRAY';

	my @img  = grep {  _isImagery($_) } @$layers;
	my @rest = grep { !_isImagery($_) } @$layers;

	my ($added,$skipped) = (0,0);
	if (@img && @rest)
	{
		my ($a1,$s1) = _attachTo($node,$node,\@img);
		my ($a2,$s2) = _attachTo($node,_foldNode($node),\@rest);
		($added,$skipped) = ($a1 + $a2,$s1 + $s2);
	}
	else
	{
		($added,$skipped) = _attachTo($node,$node,$layers);
	}

	display($dbg_catalog,0,
		"catalogAttach($node->{id}) $added added, $skipped already known".
		((@img && @rest) ? ", ".scalar(@rest)." folded" : ''));
	return ($added,$skipped);
}


#---------------------------------------------
# creating files
#---------------------------------------------

sub catalogPlan
	# WHAT CREATING THESE ENTRIES WOULD DO, decided before anything is
	# written.  ($nodes,$installed) where $installed is
	#
	#	{ ids => { id => leaf }, leaves => { leaf => 1 },
	#	  keys => { cache_key => { leaf => , url => } } }
	#
	# TOLD, NOT ASKED.  Everything in that hash is dm_source's to know and
	# this module does not use dm_source, which is also what lets the whole
	# of this be tested with no sources folder in existence.
	#
	# ONE APPROVED LIST RATHER THAN A PROMPT PER FILE.  The editor settles
	# uniqueness by asking a person, which is right for one file and
	# impossible for twenty.  The RULES here are the editor's, unchanged --
	# an id may not collide, and a cache_key may not be reused against a
	# different url - and only the resolution is different: it is decided,
	# shown, and approved once.
	#
	# A COLLIDING id IS A SKIP AND NEVER A RENAME.  The id is what a region
	# points at, so inventing a new one would silently produce a source
	# nothing refers to; and the collision almost always means the entry is
	# already installed, which is the answer the user wants.
	#
	# A COLLIDING cache_key IS A SKIP TOO, for the opposite reason: renaming
	# it WOULD work, and would quietly begin a second copy of a tile cache
	# that may already hold gigabytes.  That is precisely what cache_key
	# exists to prevent.
{
	my ($nodes,$installed) = @_;

	my %ids    = %{ $installed->{ids}    || {} };
	my %leaves = %{ $installed->{leaves} || {} };
	my %keys   = %{ $installed->{keys}   || {} };

	my @plan;
	for my $node (@$nodes)
	{
		next if !$node->{is_entry};
		my $tsd = catalogTsd($node);
		my $rec = { node => $node, id => $node->{id}, tsd => $tsd };

		if ($ids{$node->{id}})
		{
			$rec->{action} = 'skip';
			$rec->{why}    = "already installed as $ids{$node->{id}}";
			push @plan,$rec;
			next;
		}

		my $ck = $tsd->{cache_key};
		if (defined $ck && $keys{$ck} &&
			($keys{$ck}{url} // '') ne ($tsd->{url} // ''))
		{
			$rec->{action} = 'skip';
			$rec->{why}    = "cache_key '$ck' is used by $keys{$ck}{leaf}, ".
							 "which has a different url";
			push @plan,$rec;
			next;
		}

		# THE FILE NAME IS THE ONE THING THAT MAY BE INVENTED, because it
		# is the container and nothing points at it.

		my $leaf = catalogLeaf($node);
		if ($leaves{lc $leaf})
		{
			my $base = $leaf;
			$base =~ s/\.tsd$//;
			my $n = 2;
			$n++ while $leaves{lc "$base-$n.tsd"};
			$leaf = "$base-$n.tsd";
			$rec->{why} = "renamed - ".catalogLeaf($node)." is taken";
		}

		$rec->{action} = 'create';
		$rec->{leaf}   = $leaf;
		$ids{$node->{id}} = $leaf;
		$leaves{lc $leaf} = 1;
		$keys{$ck} = { leaf => $leaf, url => $tsd->{url} } if defined $ck;
		push @plan,$rec;
	}
	return \@plan;
}


sub catalogPlanLines
	# The plan as a person reads it, creations first.  What is skipped is
	# never omitted: a list that showed only what it would do would read
	# as though the rest had been done too.
{
	my ($plan) = @_;
	my @make = grep { $_->{action} eq 'create' } @$plan;
	my @skip = grep { $_->{action} ne 'create' } @$plan;

	my @out;
	if (@make)
	{
		push @out,scalar(@make)." source".(@make == 1 ? '' : 's')." to write:";
		push @out,'';
		for my $r (@make)
		{
			push @out,sprintf("    %-24s %s",$r->{leaf},$r->{node}{path});
			push @out,sprintf("    %-24s %s",'',$r->{why}) if $r->{why};
		}
	}
	else
	{
		push @out,'Nothing to write.';
	}

	if (@skip)
	{
		push @out,'';
		push @out,scalar(@skip)." skipped:";
		push @out,'';
		for my $r (@skip)
		{
			push @out,sprintf("    %-24s %s",$r->{node}{id},$r->{why});
		}
	}
	return \@out;
}


1;
