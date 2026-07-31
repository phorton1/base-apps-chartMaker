#!/usr/bin/perl
#---------------------------------------------
# dm_region.pm
#---------------------------------------------
# The coverage model on disk.  See docs/design/regions.md.
#
#	$data_dir/region_sets/<set>/<id>.region		one region, self contained
#
# EXISTENCE COMES FROM THE FOLDER.  Regions are found by scanning, exactly
# as sources are, so dropping in a region somebody sent you is how you add
# one.  There is no index and nothing to keep in step with the folder.
#
# ONE SET AT A TIME IS LOADED -- the active one, from dm_set.  Ids
# therefore need only be unique WITHIN a set, which is more correct than
# the alternative: a card is one folder, and two sets that both contain a
# Bocas are two cards, not a conflict.  Changing the active set advances
# the shared counter, so every thread reloads from the new folder.
#
# CHECKED MEANS SHOWN ON THE MAP, and nothing more.  It is not what
# builds: the SET is what builds, because the set is a folder and the
# files present in it are the card.  Checking is a per-machine view
# convenience, held in memory here and written to the ini on clean exit
# by the application layer -- it is deliberately NOT durable data, and
# there is no file in the user's folder that can disagree with the
# folder itself.
#
# A REGION'S GEOMETRY IS ONE OR MORE POLYGONS.  Not one.  Bocas del Toro
# is a main body plus a detached area fifteen miles east, and San Blas has
# a separate sliver; they are one region because they are one thing to the
# person who drew them, and expressing them as separate regions or as
# subregions would either lose the grouping or lose the coverage.
#
# NO HOLES, and not as a simplification: coverage is a union and never
# subtracts, so an inner ring could not mean anything.
#
# THE ID IS STRUCTURAL AND THE NAME IS NOT.  The id is the file name, the
# key every set references, and the stem of the exported card file, so it
# is restricted to [A-Za-z0-9] -- no spaces, nothing needing an escape.
# The name is free text and carries no load at all.  Ids are compared
# case insensitively (the id IS a Windows file name, and PortBelo and
# portbelo cannot be two regions) but stored with the case the author
# wrote, which is what a CamelCase id is for.
#
# ZAUTHOR, ZMIN, ZMAX.  zauthor is the level the polygon is quantised at
# -- the same number as the RCT header's zoom_author and the firmware's
# MASK_Z.  The region is COMPLETE from zauthor up to zmax, which is what
# lets the plotter's reveal mask be cut at zauthor safely.  zmin is the
# overview floor.  A SUBREGION HAS ZMAX ONLY: it never cuts a contour, it
# sits inside an aperture its parent already opened, so it quantises its
# own polygon at its own zmax and there is no second authored level.
#
# THREADS.  Same shared generation counter as dm_source -- each thread
# reloads when it notices it is behind, so a change made at the console is
# seen by every server thread on its next request.
#
# This module holds no control flow.  It reads, writes and validates; it
# does not decide when any of that should happen.

package dm_region;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP;
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_set;
use dm_source;
	# For one question only: which source a region is born naming.  A
	# region may not inherit, so something has to answer at creation, and
	# dm_source is what knows which sources can build.  Not a cycle --
	# dm_source knows nothing about regions.
use dm_coverage;
	# For the polygon primitives only - outsideVertices, to enforce that a
	# subregion stays inside its parent.  dm_coverage knows nothing about
	# regions, so this is not a cycle: it owns the geometry, this owns the
	# model.


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		openSet
		closeSet
		revertSet
		saveSet
		saveSetAs
		setIsOpen
		openSetName

		isSetDirty
		isRegionDirty
		dirtyRegionIds
		commitRegion
		revertRegion

		findAnywhere
		getRegionIds
		getRegion
		stageRegion
		newRegion
		renameRegion
		setRegionId
		deleteRegion
		suggestRegionId

		getWorkingSet
		isChecked
		setChecked
		getUncheckedIds
		setUncheckedIds

		addSubregion
		deleteSubregion
		findSubregion

		regionPolygonCount
		regionPointCount

		regionSourceMap
		mergedCoverageSources
	);
}


our $dbg_region:shared = 0;
	# 0  = the load summary
	# -1 = one line per file
	# -2 = geometry detail


my $REGION_VERSION		= 1;
	# THE COUNTER WAS RESTARTED, deliberately.  The format went through
	# two earlier shapes entirely inside development and no file outside
	# this machine ever held either of them, so what was carried as
	# "version 3" was two upgrade paths for a population of files that
	# does not exist.  The current shape is version 1 and there is no
	# upgrade code at all: a file claiming a higher version is refused as
	# newer than this application understands, which is the whole job.

my @REGION_FIELDS		= qw( region_version id name notes zauthor zmin zmax
							  source source_name geometry subregions );
my @SUBREGION_FIELDS	= qw( id name notes zmax source source_name
							  geometry subregions );

# SOURCE IS A REFERENCE AND SOURCE_NAME IS A SOUVENIR.  The id is what
# resolves; the name is a snapshot of what that id was CALLED when this
# region was authored, carried so that a set arriving on a machine without
# that TSD can still say where its tiles were meant to come from.
#
# Nothing ever resolves by name, and the two are allowed to disagree - a
# name that has drifted is stale information, not a broken file, and the
# only moment it is shown in preference to the live one is when the id
# resolves to nothing at all.  Deliberate denormalisation, kept honest by
# the rule that one field is read by code and the other only by people.

# THE LEVELS A NEW REGION STARTS WITH are preferences, read at creation
# and never afterwards.  They are seeds: changing one never touches a
# region that exists, which is the only reason a zoom may be a preference
# at all.  A set built on the shipped GIBS sources, which stop at z12,
# needs different seeds from one built on a commercial aerial source, and
# correcting three spinners on every new region is how you find that out
# the slow way.

#---------------------------------------------
# THE OPEN DOCUMENT
#---------------------------------------------
# A SET IS A DOCUMENT: opened, edited in memory, and written on Save.
# Nothing else writes a .region file.  That is what makes killing the
# application a real choice rather than an accident - the folder stands as
# it was - and it is what lets a test drive the whole application against
# a fixture and leave the fixture byte for byte identical.
#
# WHICH SET IS OPEN IS NOT THE SAME QUESTION AS WHICH SET IS ACTIVE.
# dm_set's active set is a pointer remembered in the ini and resolved
# against the folder on every read, so it falls through to some other set
# when the one it names is gone - the right answer for "what should we
# open at startup" and the wrong one for "what is open now", which must be
# able to say NOTHING.  $doc_set answers the second, and it is the only
# thing that decides where a region is read from or written to.
#
# THE MODEL TRAVELS BETWEEN THREADS AS A DOCUMENT, NOT AS A FOLDER.  Every
# thread holds its own copy and learns it is stale from the shared
# counter, exactly as before - but it refills from $doc_json rather than
# from disk, because the disk no longer holds what the user is looking at.
# Publishing is a serialise of a few tens of kilobytes on the thread that
# made the change; the alternative, a deeply shared structure, is not
# something Perl does well.
#
# TWO PREVIOUS STATES ARE KEPT PER REGION, and they are not the same one.
# BASELINE is what was last SAVED, and it is what Revert goes back to.
# ACCEPTED is what was last taken into the document, and it is what a
# refused edit goes back to - because a caller mutates the region hash in
# place before asking for it to be staged, so by the time the validator
# says no, the model is already holding what it refused.
#
# Falling back to the baseline instead would be wrong for a region that
# has never been saved: it has no baseline, and one bad edit would delete
# an hour of work that was never in question.  Both travel in the document,
# so a refusal on an HTTP thread restores what the wx thread would have.

my $scan_seq:shared	= 1;
my $my_seq			= 0;
my %regions;		# folded id => region hash, for the OPEN set only
my %baseline;		# folded id => the region as it was last saved
my %accepted;		# folded id => the region as it was last staged
my $loaded_set		= '';	# the set %regions was filled from

my $doc_json:shared	= '';	# regions + baseline, as every thread sees them
my $doc_set:shared	= '';	# the open set, '' when none is
my %dirty:shared;			# folded id => 1
my @open_files:shared;		# the .region leaves present when it was opened

my %unchecked:shared;
	# "<set>|<folded id>" => 1 for the regions NOT shown on the map.
	#
	# The UNCHECKED ones are stored, not the checked ones, and the
	# difference matters: a region dropped into the folder by hand appears
	# CHECKED, which is what someone who just put it there expects.  Had
	# the checked list been stored, every new region would arrive invisible
	# and the folder would look broken.
	#
	# Keyed by set as well as id, because two sets may each hold a region
	# with the same id and they are not the same region.


#---------------------------------------------
# small helpers
#---------------------------------------------

sub _err
{
	my ($where,$msg) = @_;
	error("$where: $msg");
	return undef;
}


sub _isInt
{
	my ($val) = @_;
	return defined($val) && !ref($val) && $val =~ /^-?\d+$/;
}


sub _foldId
	# The key an id is stored and compared under.  Every lookup, every
	# uniqueness test and every set membership test goes through this, so
	# there is exactly one answer to "are these the same region".
{
	my ($id) = @_;
	return lc($id // '');
}


sub _suggestId
	# A CamelCase candidate from a name, for the field the user then edits.
	# It is a SUGGESTION and nothing more -- SanBlasEast is eleven
	# characters and the author will want SanBlasE, which is precisely why
	# the id is a field of its own rather than something derived.
{
	my ($name) = @_;
	$name = '' if !defined $name;
	$name =~ s/^\s+|\s+$//g;

	# ALREADY AN ID -- leave it exactly alone.  Lowercasing and
	# re-capitalising would turn the KML's own 'BocasDelToro' into
	# 'Bocasdeltoro', destroying case the author put there on purpose.

	return $name if $name =~ /^[A-Za-z0-9]+$/;

	my @words = grep { /\S/ } split(/[^A-Za-z0-9]+/,$name);
	return join('',map { ucfirst(lc($_)) } @words);
}


sub suggestRegionId
	# _suggestId, for whoever is filling in the field the user will edit.
{
	my ($name) = @_;
	return _suggestId($name);
}


sub _isNum
{
	my ($val) = @_;
	return defined($val) && !ref($val) && $val =~ /^-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?$/;
}


sub _readFile
{
	my ($path) = @_;
	my $fh;
	if (!open($fh,'<',$path))
	{
		error("could not open $path: $!");
		return undef;
	}
	binmode $fh;
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text;
}


sub _writeFile
	# Through a temporary name and then renamed, so a reader never sees a
	# half written region.
{
	my ($path,$text) = @_;
	my $tmp = "$path.$$.tmp";
	my $fh;
	if (!open($fh,'>',$tmp))
	{
		error("could not write $tmp: $!");
		return 0;
	}
	binmode $fh;
	print $fh $text;
	close $fh;

	unlink $path if -f $path;
	if (!rename($tmp,$path))
	{
		error("could not rename $tmp to $path: $!");
		unlink $tmp;
		return 0;
	}
	return 1;
}


sub _numify
	# Force every number in a structure back to a number before encoding.
	# See the long note in em_server.pm: a scalar acquires its string flag
	# from any regex match or interpolation, and JSON::PP then encodes it
	# as a string, which downstream JavaScript takes literally and
	# disastrously.  The only place the guarantee holds is the encoder.
{
	my ($thing) = @_;
	if (ref($thing) eq 'ARRAY')
	{
		_numify($_) for @$thing;
		for my $i (0..$#$thing)
		{
			$thing->[$i] = 0 + $thing->[$i]
				if !ref($thing->[$i]) && _isNum($thing->[$i]);
		}
	}
	elsif (ref($thing) eq 'HASH')
	{
		for my $key (keys %$thing)
		{
			if (ref($thing->{$key}))
			{
				_numify($thing->{$key});
			}
			elsif ($key eq 'zauthor' || $key eq 'zmin' || $key eq 'zmax' ||
				   $key eq 'region_version')
			{
				$thing->{$key} = 0 + $thing->{$key} if _isNum($thing->{$key});
			}
		}
	}
	return $thing;
}


#---------------------------------------------
# validation
#---------------------------------------------

sub _newRegionSource
	# THE SOURCE A REGION IS BORN NAMING.  What the map is currently
	# showing, if that source can build; otherwise the shipped default.
	#
	# The fallback is a plain string and does not have to resolve to
	# anything installed -- an id naming a source this machine does not
	# have is a condition the format already tolerates, and is exactly
	# what a set arriving from somebody else looks like.  So this always
	# has an answer and a region is never left without one.
{
	my $id  = getDefaultSource();
	my $src = $id ? getSource($id) : undef;
	return $id
		if $src && grep { $_ eq 'build' } @{$src->{uses} || []};
	return $DEFAULT_SOURCE_ID;
}


sub _validatePolygon
{
	my ($where,$poly,$n) = @_;

	return _err($where,"polygon $n is not an array")
		if ref($poly) ne 'ARRAY';
	return _err($where,"polygon $n has only ".scalar(@$poly).
			" point(s) - a polygon needs at least 3")
		if @$poly < 3;

	my $i = 0;
	for my $pt (@$poly)
	{
		return _err($where,"polygon $n point $i is not a [lon,lat] pair")
			if ref($pt) ne 'ARRAY' || @$pt != 2;
		return _err($where,"polygon $n point $i has a non-numeric coordinate")
			if !_isNum($pt->[0]) || !_isNum($pt->[1]);
		return _err($where,"polygon $n point $i longitude $pt->[0] is out of range")
			if $pt->[0] < -180 || $pt->[0] > 180;

		# Web Mercator cannot represent the poles, and a chart of them
		# would be no use to a boat in any case.

		return _err($where,"polygon $n point $i latitude $pt->[1] is outside Web Mercator")
			if $pt->[1] < -85.05113 || $pt->[1] > 85.05113;
		$i++;
	}
	return 1;
}


sub _validateRegion
	# Validates a region or, recursively, a subregion.  A subregion IS a
	# region: same fields, same rules, one level down.
	#
	# $seen carries the ids already used ANYWHERE IN THIS REGION, and it is
	# threaded down the recursion rather than made fresh at each level.
	# See the uniqueness check below for why the scope had to widen.
{
	my ($where,$reg,$depth,$seen) = @_;
	$depth ||= 0;
	$seen  ||= {};

	return _err($where,"not a JSON object")
		if ref($reg) ne 'HASH';
	return _err($where,"nested more than 8 deep - this is almost certainly a cycle")
		if $depth > 8;

	my %known = map { $_ => 1 } ($depth ? @SUBREGION_FIELDS : @REGION_FIELDS);
	for my $key (sort keys %$reg)
	{
		return _err($where,"unknown field '$key'")
			if !$known{$key};
	}

	if (!$depth)
	{
		return _err($where,"region_version must be an integer")
			if !_isInt($reg->{region_version});
		return _err($where,"region_version $reg->{region_version} is newer than ".
				"this application understands ($REGION_VERSION)")
			if $reg->{region_version} > $REGION_VERSION;
	}

	# The id is a file name and a card file stem.  Anything outside
	# [A-Za-z0-9] would have to be escaped somewhere, and the somewhere is
	# never all the places.

	return _err($where,"id is required and must be [A-Za-z0-9]")
		if !defined($reg->{id}) || $reg->{id} !~ /^[A-Za-z0-9]+$/;
	return _err($where,"name is required and may not be empty")
		if !defined($reg->{name}) || $reg->{name} !~ /\S/;

	# AN ID IS UNIQUE WITHIN ITS WHOLE REGION, not merely among its
	# siblings, and this used to be enforced only among siblings while
	# three other things already assumed the stronger rule.  addSubregion
	# has always refused a duplicate anywhere in the tree; regionSourceMap
	# keys nodes by their PATH, and two nodes with the same path are one
	# entry; and an exporter that writes a file per node needs a name that
	# cannot collide with another node's.  So the loader now agrees with
	# what the rest of the model already believed.
	#
	# The region's own id is in the same namespace as its subregions',
	# because a node is a node - 'Bocas' containing a subregion 'Bocas' has
	# the same collision as two subregions called 'Bocas'.

	return _err($where,"id '$reg->{id}' is used more than once in this region ".
			"- an id must be unique within the whole region, not merely ".
			"among its siblings")
		if $seen->{ _foldId($reg->{id}) }++;

	if ($depth)
	{
		return _err($where,"subregion '$reg->{id}' zmax must be an integer from 0 to 24")
			if !_isInt($reg->{zmax}) || $reg->{zmax} < 0 || $reg->{zmax} > 24;
	}
	else
	{
		for my $field (qw( zauthor zmin zmax ))
		{
			return _err($where,"$field must be an integer from 0 to 24")
				if !_isInt($reg->{$field}) ||
					$reg->{$field} < 0 || $reg->{$field} > 24;
		}

		# zmin <= zauthor <= zmax is not a style rule.  The reveal mask is
		# cut at zauthor and the painted set must be a superset of it, so a
		# zauthor outside the built range would open an aperture onto
		# ground nothing painted.

		return _err($where,"zmin $reg->{zmin} is above zauthor $reg->{zauthor}")
			if $reg->{zmin} > $reg->{zauthor};
		return _err($where,"zauthor $reg->{zauthor} is above zmax $reg->{zmax}")
			if $reg->{zauthor} > $reg->{zmax};
	}

	# A SUBREGION MAY INHERIT AND A REGION MAY NOT.  An inherited build
	# source at the top would make what a set produces depend on the
	# machine it is built on, and a set is meant to travel -- handed to
	# somebody else it would build something its author never saw.  So
	# the region names a source outright.  A subregion inheriting its
	# parent's answer stays completely determined, which is why the value
	# survives there and is the default there.
	#
	# The charset is the TSD's own, so an id that could not name a source
	# is refused here rather than at build time.  An id that is merely NOT
	# INSTALLED is accepted: that is the normal condition of a set that
	# arrived from somebody else, and the recipient has to be able to open
	# it to find out what it wants.

	$reg->{source} = $depth ? $SOURCE_INHERITED : _newRegionSource()
		if !defined $reg->{source};
	return _err($where,"source must be [a-z0-9_-]")
		if $reg->{source} !~ /^[a-z0-9_-]+$/;
	return _err($where,"a region may not have source '$SOURCE_INHERITED' ".
			"- only a subregion may inherit, because a set that inherits ".
			"its build source builds differently in different hands")
		if !$depth && $reg->{source} eq $SOURCE_INHERITED;

	$reg->{source_name} = '' if !defined $reg->{source_name};
	return _err($where,"source_name must be a string")
		if ref($reg->{source_name});

	# geometry is a LIST of polygons.  A region with no geometry at all is
	# allowed -- that is what a newly created one looks like before
	# anything has been drawn.

	$reg->{geometry} ||= [];
	return _err($where,"geometry must be an array of polygons")
		if ref($reg->{geometry}) ne 'ARRAY';
	my $n = 0;
	for my $poly (@{$reg->{geometry}})
	{
		return undef if !_validatePolygon("$where [$reg->{id}]",$poly,$n);
		$n++;
	}

	$reg->{subregions} ||= [];
	return _err($where,"subregions must be an array")
		if ref($reg->{subregions}) ne 'ARRAY';

	for my $sub (@{$reg->{subregions}})
	{
		# The id check is at the TOP of this sub and the %seen hash is
		# threaded through, so a duplicate is caught wherever in the tree
		# it appears rather than only between two siblings.

		return undef if !_validateRegion($where,$sub,$depth+1,$seen);

		# A subregion's band runs from its parent's zmax + 1 up to its own
		# zmax, so a zmax at or below the parent's is an EMPTY band.
		# Harmless, because coverage is a union and never subtracts, but it
		# is doing no work and the author should know.

		warning(0,0,"$where: subregion '$sub->{id}' has zmax $sub->{zmax}, ".
			"at or below its parent '$reg->{id}' ($reg->{zmax}) - ".
			"it contributes nothing")
			if $sub->{zmax} <= $reg->{zmax};
	}

	return $reg;
}


sub _checkContainment
	# A SUBREGION'S GEOMETRY MAY NOT LEAVE ITS PARENT, and this is where
	# that is enforced rather than merely reported.  A subregion adds
	# resolution inside an aperture its parent already opened; ground
	# outside that aperture has no parent detail to deepen, so asking for
	# it is not an edit that needs permitting.  What the author wants there
	# is another polygon on the parent, or another region.
	#
	# Checked PER VERTEX, which is exactly the rule the editor holds the
	# user to as they click.  A stricter test would reject shapes the
	# interface allowed them to build.
	#
	# A parent with NO geometry contains nothing, so its subregions cannot
	# be checked yet - and must not be rejected either, since creating the
	# parent and drawing it are two steps.  An empty subregion is likewise
	# vacuously contained.
{
	my ($where,$reg,$depth) = @_;
	$depth ||= 0;

	my $mine = $reg->{geometry} || [];
	for my $sub (@{$reg->{subregions} || []})
	{
		my $theirs = $sub->{geometry} || [];
		if (@$mine && @$theirs)
		{
			my @out = outsideVertices($mine,$theirs);
			if (@out)
			{
				my $first = $out[0];
				return _err($where,"subregion '$sub->{id}' has ".scalar(@out).
					" vertex(es) outside '$reg->{id}' - the first is polygon ".
					"$first->[0] point $first->[1] at ".
					sprintf("%.6f,%.6f",$first->[2],$first->[3]));
			}
		}
		return undef if !_checkContainment($where,$sub,$depth+1);
	}
	return 1;
}


#---------------------------------------------
# loading
#---------------------------------------------


sub _loadFile
{
	my ($path,$leaf) = @_;

	my $text = _readFile($path);
	return if !defined $text;

	my $reg = eval { JSON::PP->new->decode($text) };
	if ($@)
	{
		my $why = $@;
		$why =~ s/\s+at\s+.*//s;
		error("$leaf: not valid JSON - $why");
		return;
	}

	$reg = _validateRegion($leaf,$reg,0);
	return if !$reg;

	my $key = _foldId($reg->{id});
	if ($regions{$key})
	{
		error("$leaf: id '$reg->{id}' is already defined by ".
			$regions{$key}{file}." - ignoring $leaf");
		return;
	}

	$reg->{file} = $leaf;
	$regions{$key} = $reg;
	display($dbg_region+1,1,"loaded $leaf as '$reg->{id}' (z$reg->{zauthor}, ".
		"z$reg->{zmin}-$reg->{zmax}, ".
		regionPolygonCount($reg)." polygon(s), ".
		scalar(@{$reg->{subregions}})." subregion(s))");
	return $reg;
}


sub _regionDir
	# The folder of the OPEN set, or '' when none is open.  Every read and
	# every write goes through this, so "which folder" is answered in
	# exactly one place.
{
	return setDir($doc_set);
}


sub openSetName
{
	return $doc_set;
}


sub setIsOpen
{
	return $doc_set ne '' ? 1 : 0;
}


sub openSet
	# Read a set off the disk and make it the document.  Everything the
	# previous document held is gone, which is why every caller asks
	# isSetDirty() first - this module refuses nothing and destroys what it
	# is told to destroy.
	#
	# NO SET OPEN IS A LEGITIMATE STATE, not an error.  It is what a brand
	# new installation looks like, what Close leaves behind, and what
	# deleting the last set folder means.  Everything downstream sees an
	# empty model, which is exactly true.
{
	my ($name) = @_;
	$name = '' if !defined $name;

	%regions    = ();
	%baseline   = ();
	%accepted   = ();
	%dirty      = ();
	@open_files = ();
	$doc_set    = $name;
	$loaded_set = $name;

	my $dir = _regionDir();
	if (!$dir)
	{
		display($dbg_region,0,"openSet() - no set");
		_publish();
		return 0;
	}

	my $dh;
	if (!opendir($dh,$dir))
	{
		error("could not read $dir: $!");
		$doc_set = '';
		_publish();
		return 0;
	}
	my @leaves = sort grep { /\.region$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	display($dbg_region,0,"openSet('$name') scanning $dir");
	_loadFile("$dir/$_",$_) for @leaves;

	# WHAT WAS THERE WHEN IT WAS OPENED, so that Save can remove the file
	# of a region that has since been deleted - and remove nothing else.
	# A .region that appeared underneath us belongs to somebody else.

	@open_files = @leaves;
	%baseline = map { $_ => _copy($regions{$_}) } keys %regions;
	%accepted = map { $_ => _copy($regions{$_}) } keys %regions;

	my $found = scalar(keys %regions);
	display($dbg_region,1,"$found region".($found == 1 ? '' : 's').
		" loaded from ".scalar(@leaves)." file".(@leaves == 1 ? '' : 's').
		" in set '$name'");

	_publish();
	return $found;
}


sub closeSet
	# The document is gone and nothing is open.  Unsaved work is discarded,
	# which is the caller's decision to have made.
{
	%regions    = ();
	%baseline   = ();
	%accepted   = ();
	%dirty      = ();
	@open_files = ();
	$doc_set    = '';
	$loaded_set = '';
	display($dbg_region,0,"closeSet()");
	_publish();
	return 1;
}


sub revertSet
	# Every region back to what is on disk, in one step.  The same thing as
	# closing without saving and opening again, which is exactly how it is
	# implemented.
{
	return openSet($doc_set);
}


sub _copy
	# A deep copy, by the shortest route that is certainly deep.  Regions
	# are a few kilobytes of plain data; this is not a hot path.
{
	my ($thing) = @_;
	return undef if !defined $thing;
	return JSON::PP->new->decode(JSON::PP->new->encode($thing));
}


sub _regionText
	# One region as the bytes that would be written for it - the only
	# comparison that answers "would saving this change the file".
{
	my ($reg) = @_;
	my %out = map { $_ => $reg->{$_} } grep { defined $reg->{$_} } @REGION_FIELDS;
	$out{region_version} = $REGION_VERSION;
	_numify(\%out);
	return JSON::PP->new->canonical->encode(\%out);
}


sub _publish
	# Hand this thread's model to every other thread, and advance the
	# counter that tells them to take it.
{
	$doc_json = JSON::PP->new->canonical->encode({
		regions  => \%regions,
		baseline => \%baseline,
		accepted => \%accepted });
	_touch();
}


sub _thaw
	# Take the published document.  Numbers are forced back to numbers for
	# the reason _numify() gives: a JSON round trip is one more place a
	# zoom can come back as a string, and every arithmetic use of one is
	# downstream of here.
{
	my $doc = $doc_json ? eval { JSON::PP->new->decode($doc_json) } : undef;
	%regions  = ();
	%baseline = ();
	%accepted = ();
	if ($doc)
	{
		%regions  = %{ _numify($doc->{regions}  || {}) };
		%baseline = %{ _numify($doc->{baseline} || {}) };
		%accepted = %{ _numify($doc->{accepted} || {}) };
	}
	$loaded_set = $doc_set;
	$my_seq     = $scan_seq;
}


sub _touch
	# EVERY MUTATION MUST CALL THIS.  A write updates this thread's copy
	# of the model and the file on disk, but every other thread is
	# holding its own copy and has no way to find out.  Advancing the
	# shared counter is that way: the next time another thread reads
	# anything, _current() sees it is behind and reloads from disk.
	#
	# $my_seq is advanced too, because the thread doing the writing
	# already has the new data and re-reading it would be pure waste.
	#
	# Forgetting this is invisible in a single-threaded test and total in
	# the running application: the console and the wx pane see the change
	# and the map never does.
{
	$scan_seq++;
	$my_seq = $scan_seq;
}


sub _current
	# ONE reason to be stale now: somebody published a newer document.
	# Which folder it came from is part of the document rather than a
	# second thing to keep in step, because opening a different set
	# publishes it like any other change.
{
	_thaw() if $my_seq != $scan_seq || $loaded_set ne $doc_set;
}


sub getRegionIds
	# The AUTHORED ids, not the folded keys -- everything that displays or
	# writes an id wants the case the author chose.
	#
	# Returns a real array rather than 'sort keys' directly, because the
	# behaviour of sort in scalar context is undefined in Perl -- so
	# scalar(getRegionIds()) would be garbage rather than the count that
	# any caller writing it would expect.
{
	_current();
	my @ids = sort { lc($a) cmp lc($b) }
		map { $regions{$_}{id} } keys %regions;
	return @ids;
}


sub getRegion
{
	my ($id) = @_;
	_current();
	return $regions{ _foldId($id) };
}


sub regionPolygonCount
{
	my ($reg) = @_;
	my $n = scalar(@{$reg->{geometry} || []});
	$n += regionPolygonCount($_) for @{$reg->{subregions} || []};
	return $n;
}


sub regionPointCount
{
	my ($reg) = @_;
	my $n = 0;
	$n += scalar(@$_) for @{$reg->{geometry} || []};
	$n += regionPointCount($_) for @{$reg->{subregions} || []};
	return $n;
}


#---------------------------------------------
# writing
#---------------------------------------------

sub _regionPath
{
	my ($id) = @_;
	my $dir = _regionDir();
	return '' if !$dir;
	return "$dir/$id.region";
}


sub stageRegion
	# ACCEPT A CHANGE INTO THE DOCUMENT.  Every mutation ends here, and
	# nothing here touches the disk: the region is validated, taken into
	# the model, marked dirty, and published to the other threads.
	#
	# VALIDATION HAPPENS NOW RATHER THAN AT SAVE, so a refusal lands on the
	# action that caused it.  A Save that reported the geometry of an edit
	# made twenty minutes ago would be a report nobody could act on.
{
	my ($reg) = @_;

	if (!$doc_set)
	{
		error("stageRegion: no region set is open");
		return 0;
	}

	# Build the clean copy FIRST and validate that, not the in-memory
	# region.  A loaded region carries a 'file' field recording where it
	# came from, which is not part of the format -- validating the live
	# hash would reject every region that had ever been read from disk.
	# Validating what will actually be written is also the only version
	# of this check that means anything.

	my %out = map { $_ => $reg->{$_} } grep { defined $reg->{$_} } @REGION_FIELDS;
	$out{region_version} = $REGION_VERSION;

	# A REFUSAL PUTS THE REGION BACK, and this is not belt and braces.
	# Callers mutate a region hash in place and then ask for it to be
	# staged - and that hash is the SAME ONE %regions is holding, so a
	# rejected change leaves the model carrying geometry the validator will
	# not accept, and every later save of that region fails too, for a
	# reason that has nothing to do with what the user just did.
	#
	# It goes back to the LAST ACCEPTED state, which for a region that has
	# been saved is at worst its file, and for one that has not is the work
	# done since it was created.  Only a region that has never been
	# accepted at all can be dropped, and dropping it is right: it was
	# never in the document.

	my $key = _foldId($reg->{id} // '');
	if (!_validateRegion("edit '".($reg->{id} // '?')."'",\%out,0) ||
		!_checkContainment("edit '".($reg->{id} // '?')."'",\%out))
	{
		if ($accepted{$key})
		{
			# Dirty is then whether what came back differs from the file,
			# asked rather than remembered - the flag before the refusal
			# described the geometry that was just thrown away.

			$regions{$key} = _copy($accepted{$key});
			if ($baseline{$key} &&
				_regionText($accepted{$key}) eq _regionText($baseline{$key}))
			{
				delete $dirty{$key};
			}
			else
			{
				$dirty{$key} = 1;
			}
		}
		else
		{
			delete $regions{$key};
			delete $dirty{$key};
		}
		_publish();
		return 0;
	}
	_numify(\%out);

	$out{file}      = $reg->{file} || "$reg->{id}.region";
	$regions{$key}  = \%out;
	$accepted{$key} = _copy(\%out);
	$dirty{$key}    = 1;

	_publish();
	display($dbg_region,0,"staged '$reg->{id}'");
	return 1;
}


#---------------------------------------------
# dirt, and writing it out
#---------------------------------------------

sub isRegionDirty
{
	my ($id) = @_;
	_current();
	return $dirty{ _foldId($id // '') } ? 1 : 0;
}


sub dirtyRegionIds
	# The authored ids of the regions with unsaved changes.
{
	_current();
	return sort { lc($a) cmp lc($b) }
		map { $regions{$_}{id} } grep { $dirty{$_} && $regions{$_} } keys %regions;
}


sub _modelLeaves
{
	return sort map { lc("$regions{$_}{id}.region") } keys %regions;
}


sub isSetDirty
	# UNSAVED EDITS OR A DIFFERENT SET OF FILES.  A created region is
	# dirty on its own account - none of it is on disk - but a DELETED one
	# leaves nothing behind to carry a flag, and an id change leaves a file
	# that no longer belongs to anybody.  Both show up here as the folder
	# no longer matching the model: derived rather than tracked, so it
	# cannot drift out of step with what Save would actually do.
{
	_current();
	return 0 if !$doc_set;
	return 1 if keys %dirty;

	my @now  = _modelLeaves();
	my @then = sort map { lc($_) } @open_files;
	return 1 if scalar(@now) != scalar(@then);
	for my $i (0..$#now)
	{
		return 1 if $now[$i] ne $then[$i];
	}
	return 0;
}


sub _writeRegion
	# One region to its file.  The only writer of a .region file.
{
	my ($reg) = @_;

	my %out = map { $_ => $reg->{$_} } grep { defined $reg->{$_} } @REGION_FIELDS;
	$out{region_version} = $REGION_VERSION;
	_numify(\%out);

	my $path = _regionPath($reg->{id});
	if (!$path)
	{
		error("_writeRegion: no region set is open");
		return 0;
	}
	my $text = JSON::PP->new->pretty->canonical->encode(\%out);
	return 0 if !_writeFile($path,$text);

	my $key = _foldId($reg->{id});
	$reg->{file}    = "$reg->{id}.region";
	$baseline{$key} = _copy($reg);
	$accepted{$key} = _copy($reg);
	delete $dirty{$key};

	display($dbg_region,0,"wrote $reg->{file}");
	return 1;
}


sub commitRegion
	# One region written now, the rest of the document left alone.  A
	# partial Save, and the other half of the pair with revertRegion().
{
	my ($id) = @_;
	_current();

	my $reg = getRegion($id);
	if (!$reg)
	{
		error("commitRegion: no region with id '$id'");
		return 0;
	}
	return 0 if !_writeRegion($reg);

	# The file list has to learn about a region that had never been written
	# before, or Save would delete what was just committed.

	my $leaf = lc("$reg->{id}.region");
	push @open_files,"$reg->{id}.region"
		if !grep { lc($_) eq $leaf } @open_files;

	_publish();
	return 1;
}


sub revertRegion
	# Back to what is on disk.  A region that has never been written has no
	# saved state to go back to, and its absence IS its saved state - so
	# reverting it removes it.  The caller is told which of the two
	# happened, because one of them wants a confirmation and the other
	# does not.
	#
	# Returns 'reverted', 'removed', or '' for no such region.
{
	my ($id) = @_;
	_current();

	my $reg = getRegion($id);
	if (!$reg)
	{
		error("revertRegion: no region with id '$id'");
		return '';
	}
	my $key = _foldId($reg->{id});

	if ($baseline{$key})
	{
		$regions{$key}  = _copy($baseline{$key});
		$accepted{$key} = _copy($baseline{$key});
		delete $dirty{$key};
		display($dbg_region,0,"reverted '$reg->{id}'");
		_publish();
		return 'reverted';
	}

	delete $regions{$key};
	delete $accepted{$key};
	delete $dirty{$key};
	delete $unchecked{ _checkKey($reg->{id}) };
	display($dbg_region,0,"'$reg->{id}' had never been saved - removed");
	_publish();
	return 'removed';
}


sub saveSet
	# THE FOLDER IS MADE EQUAL TO THE MODEL.  Every dirty region is
	# written, and then the file of every region that is no longer in the
	# model is removed - which is how a delete and an id change reach the
	# disk without either being tracked as an operation of its own.
	#
	# ONLY FILES THAT WERE THERE WHEN IT WAS OPENED are removed.  A
	# .region that appeared underneath us is somebody else's, and Save is
	# not the thing that deletes it.
{
	_current();
	if (!$doc_set)
	{
		error("saveSet: no region set is open");
		return 0;
	}

	my $written = 0;
	for my $key (sort keys %regions)
	{
		next if !$dirty{$key};
		return 0 if !_writeRegion($regions{$key});
		$written++;
	}

	my %keep = map { lc("$regions{$_}{id}.region") => 1 } keys %regions;
	my $dir  = _regionDir();
	my $removed = 0;
	for my $leaf (@open_files)
	{
		next if $keep{ lc($leaf) };
		my $path = "$dir/$leaf";
		next if !-f $path;
		if (!unlink($path))
		{
			error("saveSet: could not delete $path: $!");
			return 0;
		}
		display($dbg_region,0,"removed $leaf");
		$removed++;
	}

	@open_files = map { "$regions{$_}{id}.region" } sort keys %regions;
	%dirty = ();
	_publish();

	display($dbg_region,0,"saved set '$doc_set' - $written written, ".
		"$removed removed");
	return 1;
}


sub saveSetAs
	# The same document in a new folder, which then becomes the open one.
	# Every region is written whether it was dirty or not: the new folder
	# has nothing in it, and half a set is not a set.
{
	my ($name) = @_;

	if (!$doc_set)
	{
		error("saveSetAs: no region set is open");
		return 0;
	}
	return 0 if !newSet($name);

	$doc_set    = $name;
	$loaded_set = $name;
	@open_files = ();
	$dirty{ _foldId($regions{$_}{id}) } = 1 for keys %regions;

	return saveSet();
}


sub newRegion
	# A new region has no geometry and the levels the caller asks for.
	# Drawing comes later.
	#
	# The id is SUGGESTED from the name when the caller does not give one.
	# It is a starting point, not a derivation the model relies on -- the
	# author is expected to shorten it, and setRegionId is how.
{
	my ($name,$zauthor,$zmin,$zmax,$id) = @_;
	$zauthor = prefVal($PREF_NEW_ZAUTHOR)	if !defined $zauthor;
	$zmin    = prefVal($PREF_NEW_ZMIN)		if !defined $zmin;
	$zmax    = prefVal($PREF_NEW_ZMAX)		if !defined $zmax;

	$id = _suggestId($name) if !defined($id) || $id !~ /\S/;
	if ($id !~ /^[A-Za-z0-9]+$/)
	{
		error("newRegion: '$name' does not yield a usable id");
		return undef;
	}
	if (getRegion($id))
	{
		error("newRegion: a region with id '$id' already exists");
		return undef;
	}

	my $reg = {
		region_version	=> $REGION_VERSION,
		id				=> $id,
		name			=> $name,
		zauthor			=> $zauthor,
		zmin			=> $zmin,
		zmax			=> $zmax,
		source			=> _newRegionSource(),
		source_name		=> '',
		geometry		=> [],
		subregions		=> [],
	};
	return stageRegion($reg) ? $reg : undef;
}


sub renameRegion
	# The NAME changes; the id does not.  The name is free text with no
	# structural role, so this is the cheap operation -- see setRegionId
	# for the other one.
{
	my ($id,$name) = @_;
	my $reg = getRegion($id);
	if (!$reg)
	{
		error("renameRegion: no region with id '$id'");
		return 0;
	}
	if (!defined($name) || $name !~ /\S/)
	{
		error("renameRegion: a name may not be empty");
		return 0;
	}
	$reg->{name} = $name;
	return stageRegion($reg);
}


sub setRegionId
	# Changing the id moves three things that must move together: the file
	# on disk, the key this module holds the region under, and whether it
	# is hidden on the map.  Doing any one without the others leaves a
	# region under the wrong name, or one that quietly reappears.
	#
	# A CASE-ONLY CHANGE IS NOT A RENAME ON WINDOWS.  PortBelo.region and
	# portbelo.region are the same file, so the id inside the file changes
	# and the folder entry keeps whatever case it already had.  That is
	# cosmetic and deliberately not corrected: the id in the file is the
	# truth, and nothing reads the leaf.
{
	my ($id,$new_id) = @_;

	my $reg = getRegion($id);
	if (!$reg)
	{
		error("setRegionId: no region with id '$id'");
		return 0;
	}
	if (!defined($new_id) || $new_id !~ /^[A-Za-z0-9]+$/)
	{
		error("setRegionId: an id must be [A-Za-z0-9] - '".
			($new_id // '')."' is not");
		return 0;
	}

	my $old_id = $reg->{id};
	my $same   = _foldId($old_id) eq _foldId($new_id);

	if (!$same && getRegion($new_id))
	{
		error("setRegionId: a region with id '$new_id' already exists");
		return 0;
	}

	# THE FILE IS NOT TOUCHED HERE.  The id moves in the model, and Save
	# reconciles the folder against it - writing <new id>.region and
	# removing the file the region was opened from, because that file is
	# no longer one the model accounts for.

	$reg->{id}   = $new_id;
	$reg->{file} = "$new_id.region";

	if (!stageRegion($reg))
	{
		$reg->{id} = $old_id;
		return 0;
	}

	if (!$same)
	{
		delete $regions{ _foldId($old_id) };
		delete $dirty{ _foldId($old_id) };
		_renameChecked($old_id,$new_id);
		_publish();
	}

	display($dbg_region,0,"region '$old_id' is now '$new_id'");
	return 1;
}


sub deleteRegion
{
	my ($id) = @_;
	my $reg = getRegion($id);
	if (!$reg)
	{
		error("deleteRegion: no region with id '$id'");
		return 0;
	}
	# OUT OF THE MODEL, NOT OFF THE DISK.  The file goes when the set is
	# saved, which is also what makes this undoable by closing without
	# saving.

	delete $regions{ _foldId($reg->{id}) };
	delete $dirty{ _foldId($reg->{id}) };
	delete $baseline{ _foldId($reg->{id}) };
	delete $accepted{ _foldId($reg->{id}) };

	# Visibility leaves with the region.  There is no separate store to
	# reconcile and nothing to prune.

	delete $unchecked{ _checkKey($reg->{id}) };

	_publish();
	display($dbg_region,0,"deleted region '$reg->{id}'");
	return 1;
}


#---------------------------------------------
# subregions
#---------------------------------------------

sub findSubregion
	# Depth first, by id, anywhere beneath a region.  Returns the
	# subregion and its parent, because most callers need both.
{
	my ($reg,$id) = @_;
	my $key = _foldId($id);
	for my $sub (@{$reg->{subregions} || []})
	{
		return ($sub,$reg) if _foldId($sub->{id}) eq $key;
		my ($found,$parent) = findSubregion($sub,$id);
		return ($found,$parent) if $found;
	}
	return (undef,undef);
}


sub _boxAround
	# A square box on the ground, from a centre and a half extent in
	# nautical miles.  A minute of latitude IS a nautical mile, which is
	# the whole of the latitude arithmetic; longitude converges with the
	# cosine, so the box stays square on the water rather than on the
	# chart.
	#
	# The corners are stored as drawn.  Nothing is snapped here: geometry
	# is stored as intent, and the tile grid is applied when coverage is
	# rasterised.
{
	my ($lat,$lon,$half_nm) = @_;
	my $dlat = $half_nm / 60.0;
	my $coslat = cos($lat * 3.14159265358979 / 180.0);
	$coslat = 0.01 if $coslat < 0.01;
	my $dlon = $half_nm / 60.0 / $coslat;

	return [[
		[ $lon - $dlon, $lat - $dlat ],
		[ $lon + $dlon, $lat - $dlat ],
		[ $lon + $dlon, $lat + $dlat ],
		[ $lon - $dlon, $lat + $dlat ],
	]];
}


sub addSubregion
	# A detail area: the small piece of a region that deserves to go
	# deeper than the rest of it.
	#
	# CREATED NAMED AND EMPTY.  Its geometry arrives from the map, like
	# every other polygon.  Nothing generates a shape on the author's
	# behalf - a box from a centre and an extent is a plausible-looking
	# guess at an anchorage and is never the polygon anybody wanted.
	#
	# The zmax it is given is also the level its own polygon quantises at.
	# A subregion has no second authored level: it sits inside an aperture
	# its parent already opened.
	#
	# $parent_id may name a SUBREGION, not only a region - the model nests
	# without limit, so 'add a subregion to this' has to work at any depth.
{
	my ($parent_id,$name,$zmax) = @_;

	my ($reg,$parent) = _findAnywhere($parent_id);
	if (!$reg)
	{
		error("addSubregion: nothing with id '$parent_id'");
		return undef;
	}
	if (!defined($name) || $name !~ /\S/)
	{
		error("addSubregion: a name is required");
		return undef;
	}
	if (!_isInt($zmax) || $zmax < 0 || $zmax > 24)
	{
		error("addSubregion: zmax must be an integer from 0 to 24");
		return undef;
	}

	my $id = _suggestId($name);
	if ($id !~ /^[A-Za-z0-9]+$/)
	{
		error("addSubregion: '$name' does not yield a usable id");
		return undef;
	}
	if ((findSubregion($reg,$id))[0] || _foldId($reg->{id}) eq _foldId($id))
	{
		error("addSubregion: '$reg->{id}' already contains '$id'");
		return undef;
	}

	my $sub = {
		id			=> $id,
		name		=> $name,
		zmax		=> $zmax,
		source		=> $SOURCE_INHERITED,
		source_name	=> '',
		geometry	=> [],
		subregions	=> [],
	};
	push @{$parent->{subregions}},$sub;

	return stageRegion($reg) ? $sub : undef;
}


sub _findAnywhere
	# Given an id that may name a region OR a subregion at any depth,
	# return its ROOT region and the node itself.  Everything that writes
	# needs the root, because the root is the file.
{
	my ($id) = @_;
	my $reg = getRegion($id);
	return ($reg,$reg) if $reg;

	for my $key (keys %regions)
	{
		my $root = $regions{$key};
		my ($found) = findSubregion($root,$id);
		return ($root,$found) if $found;
	}
	return (undef,undef);
}


sub findAnywhere
{
	my ($id) = @_;
	_current();
	return _findAnywhere($id);
}


sub deleteSubregion
{
	my ($parent_id,$id) = @_;
	my $reg = getRegion($parent_id);
	if (!$reg)
	{
		error("deleteSubregion: no region with id '$parent_id'");
		return 0;
	}
	my (undef,$parent) = findSubregion($reg,$id);
	if (!$parent)
	{
		error("deleteSubregion: '$parent_id' has no subregion '$id'");
		return 0;
	}
	$parent->{subregions} = [ grep { $_->{id} ne $id } @{$parent->{subregions}} ];
	return stageRegion($reg);
}


#---------------------------------------------
# what is shown on the map
#---------------------------------------------
# CHECKED IS A VIEW, NOT A MEMBERSHIP.  The set is the folder; every
# region in it is part of the card.  Unchecking one hides it from the
# map while you work on another, and that is all it does.
#
# There is deliberately no file behind this.  A stored membership list
# was the last durable thing in workspace.json, and it was exactly the
# kind of index that can disagree with the folder -- naming regions that
# are gone, missing regions that are there.  What is left is per-machine
# view state, which the application layer reads from and writes to the
# ini around a session, and which costs nothing if it is lost.

sub _checkKey
	# Keyed by the OPEN set, not the active one.  Checked-ness is a fact
	# about the document on screen, and the active set is only a pointer to
	# what the next Open would land on - which is a different set for as
	# long as it takes to open it.
{
	my ($id) = @_;
	return lc($doc_set)."|"._foldId($id);
}


sub _renameChecked
	# Visibility follows a region through a rename.  A hidden region that
	# reappeared because it was renamed would be a small mystery every
	# time, and the fix is two lines.
{
	my ($old_id,$new_id) = @_;
	my $old = _checkKey($old_id);
	return if !$unchecked{$old};
	delete $unchecked{$old};
	$unchecked{ _checkKey($new_id) } = 1;
}


sub getWorkingSet
	# The regions currently shown on the map, in id order.
{
	_current();
	return grep { !$unchecked{ _checkKey($_) } } getRegionIds();
}


sub isChecked
{
	my ($id) = @_;
	return $unchecked{ _checkKey($id) } ? 0 : 1;
}


sub setChecked
{
	my ($id,$on) = @_;
	my $reg = getRegion($id);
	if (!$reg)
	{
		error("setChecked: no region with id '$id'");
		return 0;
	}
	if ($on)
	{
		delete $unchecked{ _checkKey($reg->{id}) };
	}
	else
	{
		$unchecked{ _checkKey($reg->{id}) } = 1;
	}
	_touch();
	return 1;
}


sub getUncheckedIds
	# For the application layer to hand to the ini on a clean exit.  The
	# HIDDEN ones, not the shown ones -- see the note on %unchecked.
{
	_current();
	return grep { $unchecked{ _checkKey($_) } } getRegionIds();
}


sub setUncheckedIds
	# The other half, at startup.  Ids that name nothing are kept rather
	# than dropped: a region temporarily moved out of the set folder and
	# put back should come back hidden, as the user left it.
{
	my (@ids) = @_;
	my $prefix = lc(getActiveSet())."|";
	for my $key (keys %unchecked)
	{
		delete $unchecked{$key} if index($key,$prefix) == 0;
	}
	$unchecked{ _checkKey($_) } = 1 for grep { defined && /\S/ } @ids;
	_touch();
	return 1;
}


#---------------------------------------------
# which source each node is built from
#---------------------------------------------

sub regionSourceMap
	# Every node in a region tree mapped to the source it is to be built
	# from, with '$SOURCE_INHERITED' already followed.  Keys are the node's
	# PATH - 'Bocas', 'Bocas/Popa00' - which is the shape the coverage walk
	# reports nodes in.
	#
	# THE CHAIN ALWAYS TERMINATES.  A subregion inherits its parent's
	# answer and a region that inherits falls through to $fallback -- so one
	# pass down the tree resolves every node, and no reader has to walk back
	# up to find out what it got.
	#
	# It lives here, on the model, because more than one thing needs the
	# same answer: the cache filler fetches by it and the preview renders by
	# it, and the two disagreeing would make preview a picture of something
	# that is not what would be built.  The build will be the third.
	#
	# KEYED BY PATH rather than by walk order.  The coverage walk skips a
	# node whose whole band sits above a build's cap, so the two sequences
	# are not the same length and pairing them positionally would silently
	# shift every source by one.
	#
	# It was keyed "<depth>:<id>" until 2026-07-31, on the reasoning that
	# an id is unique only among siblings so depth had to be part of it.
	# That reasoning was right and the key was still wrong: two subregions
	# of DIFFERENT parents at the same depth may share an id, and both
	# landed on one entry, so one of them was built from the other's
	# source. The path is the only thing that identifies a node.
{
	my ($reg,$fallback,$map,$path) = @_;
	$map  ||= {};
	$path = $reg->{id} if !defined($path);

	my $mine = $reg->{source} // $SOURCE_INHERITED;
	$mine = $fallback if $mine eq $SOURCE_INHERITED;
	$map->{$path} = $mine;

	regionSourceMap($_,$mine,$map,"$path/$_->{id}")
		for @{$reg->{subregions} || []};

	return $map;
}


sub mergedCoverageSources
	# These regions' coverage merged into one structure per zoom, VALUED BY
	# THE SOURCE each tile would be built from rather than by 1.
	#
	# INNERMOST WINS where two nodes claim the same tile at the same zoom,
	# and it falls out of the walk order rather than being enforced: nodes
	# arrive outermost first, so a deeper node's answer overwrites its
	# parent's.  That is the rule the design states for overlapping
	# polygons, arrived at by construction.
	#
	# Callers that only ask whether a key is present are unaffected by the
	# value, which is why there is one merged coverage here rather than a
	# plain one and a sourced one that could drift apart.
{
	my ($regs,$fallback) = @_;
	my $merged = {};

	for my $reg (@$regs)
	{
		next if !$reg;
		my $srcs = regionSourceMap($reg,$fallback);
		my ($cov,$nodes) = regionCoverageNodes($reg);

		for my $node (@$nodes)
		{
			my $src = $srcs->{$node->{path}} || $fallback;
			for my $z (keys %{$node->{levels}})
			{
				$merged->{$z} ||= {};
				$merged->{$z}{$_} = $src for keys %{$node->{levels}{$z}};
			}
		}
	}
	return $merged;
}


1;
