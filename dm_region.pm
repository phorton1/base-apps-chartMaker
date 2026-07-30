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
use dm_set;
use dm_coverage;
	# For the polygon primitives only - outsideVertices, to enforce that a
	# subregion stays inside its parent.  dm_coverage knows nothing about
	# regions, so this is not a cycle: it owns the geometry, this owns the
	# model.


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		loadRegions
		findAnywhere
		rescanRegions
		getRegionIds
		getRegion
		saveRegion
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

		importKmlFile
		regionPolygonCount
		regionPointCount
	);
}


our $dbg_region:shared = 0;
	# 0  = the load summary
	# -1 = one line per file
	# -2 = geometry detail


my $REGION_VERSION		= 2;

my @REGION_FIELDS		= qw( region_version id name notes zauthor zmin zmax
							  geometry subregions );
my @SUBREGION_FIELDS	= qw( id name notes zmax geometry subregions );

my $UPGRADE_ZMIN		= 10;
	# The overview floor a version 1 file did not carry.  It lived in
	# dm_coverage as a default; a version 2 region states it, and a file
	# written before it existed is read as having meant the default.

my $scan_seq:shared	= 1;
my $my_seq			= 0;
my %regions;		# id => region hash, for the ACTIVE set only
my $loaded_set		= '';	# the set %regions was filled from

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
{
	my ($where,$reg,$depth) = @_;
	$depth ||= 0;

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

	my %seen;
	for my $sub (@{$reg->{subregions}})
	{
		return undef if !_validateRegion($where,$sub,$depth+1);

		# Ids need only be unique within the file - nothing outside one
		# ever refers to a subregion.

		return _err($where,"subregion id '$sub->{id}' appears twice under '$reg->{id}'")
			if $seen{ _foldId($sub->{id}) }++;

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

sub _upgradeRegion
	# Version 1 -> 2, in memory, at load.
	#
	# A version 1 file carried one zoom per level, canonical_zoom, and got
	# its floor and its depth from defaults living in dm_coverage: the
	# floor was 10 and exactly one level above canonical was filled.  So
	# the version 2 reading of a version 1 file is zauthor = canonical,
	# zmin = 10, zmax = canonical + 1, and a subregion -- which had the
	# same one-level fill -- becomes zmax = canonical + 1.
	#
	# THIS IS A READ, NOT A REWRITE.  Nothing is written back until the
	# region is saved for some other reason, so an upgrade that is wrong
	# about a file costs nothing until someone looks at it.  It is also
	# why no migration script has to touch the user's folder.
{
	my ($reg,$depth) = @_;
	return if ref($reg) ne 'HASH';
	$depth ||= 0;

	# Version 1 allowed [a-z0-9_-], so bocas_del_toro was a legal id and
	# is not one now.  Such a file must still LOAD -- rejecting it would
	# make every region anyone already has unreadable, and there would be
	# no way to fix it from inside the application.  The converted id is
	# a mechanical CamelCase of the old one and is expected to be
	# shortened by hand; see setRegionId.

	if (defined($reg->{id}) && !ref($reg->{id}) &&
		$reg->{id} !~ /^[A-Za-z0-9]+$/)
	{
		my $was = $reg->{id};
		$reg->{id} = _suggestId($was);
		warning(0,0,"region id '$was' is not valid in version $REGION_VERSION ".
			"- read as '$reg->{id}'")
			if $reg->{id} =~ /^[A-Za-z0-9]+$/;
	}

	if (defined $reg->{canonical_zoom})
	{
		my $c = delete $reg->{canonical_zoom};
		if ($depth)
		{
			$reg->{zmax} = $c + 1 if !defined $reg->{zmax};
		}
		else
		{
			$reg->{zauthor} = $c      if !defined $reg->{zauthor};
			$reg->{zmin}    = $UPGRADE_ZMIN if !defined $reg->{zmin};
			$reg->{zmax}    = $c + 1  if !defined $reg->{zmax};
		}
	}

	_upgradeRegion($_,$depth+1) for @{$reg->{subregions} || []};

	$reg->{region_version} = $REGION_VERSION if !$depth;
}


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

	_upgradeRegion($reg,0)
		if ref($reg) eq 'HASH' && _isInt($reg->{region_version}) &&
			$reg->{region_version} < $REGION_VERSION;

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
	# The folder of the ACTIVE set, or '' when there is none.  Every read
	# and every write goes through this, so "which folder" is answered in
	# exactly one place and changing the active set changes all of them.
{
	return setDir(getActiveSet());
}


sub loadRegions
{
	%regions = ();
	$loaded_set = getActiveSet();

	# NO ACTIVE SET IS A LEGITIMATE STATE, not an error.  It is what a
	# brand new installation looks like, and what deleting the last set
	# folder leaves behind.  Everything downstream sees an empty model,
	# which is exactly true.

	my $dir = _regionDir();
	if (!$dir)
	{
		display($dbg_region,0,"loadRegions() - no region set");
		$my_seq = $scan_seq;
		return 0;
	}

	my $dh;
	if (!opendir($dh,$dir))
	{
		error("could not read $dir: $!");
		$my_seq = $scan_seq;
		return 0;
	}
	my @leaves = sort grep { /\.region$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	display($dbg_region,0,"loadRegions() scanning $dir");
	_loadFile("$dir/$_",$_) for @leaves;

	my $found = scalar(keys %regions);
	display($dbg_region,1,"$found region".($found == 1 ? '' : 's').
		" loaded from ".scalar(@leaves)." file".(@leaves == 1 ? '' : 's').
		" in set '$loaded_set'");

	$my_seq = $scan_seq;
	return $found;
}


sub rescanRegions
{
	$scan_seq++;
	return loadRegions();
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
	# TWO reasons to be stale, not one.  The shared counter catches a
	# change another thread made to the files; $loaded_set catches a change
	# to WHICH FOLDER those files should come from, which the counter
	# cannot, because the active set lives in dm_set and its own counter is
	# not this one.  Comparing the names directly is cheaper than trying to
	# keep two counters in step, and cannot drift.
{
	loadRegions() if $my_seq != $scan_seq || $loaded_set ne getActiveSet();
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


sub saveRegion
{
	my ($reg) = @_;

	# Build the clean copy FIRST and validate that, not the in-memory
	# region.  A loaded region carries a 'file' field recording where it
	# came from, which is not part of the format -- validating the live
	# hash would reject every region that had ever been read from disk.
	# Validating what will actually be written is also the only version
	# of this check that means anything.

	my %out = map { $_ => $reg->{$_} } grep { defined $reg->{$_} } @REGION_FIELDS;
	$out{region_version} = $REGION_VERSION;

	# A REFUSAL RELOADS THE MODEL FROM DISK, and this is not belt and
	# braces.  Callers mutate a region hash in place and then ask for it to
	# be saved - and that hash is the SAME ONE %regions is holding, so a
	# rejected save leaves the in-memory model carrying geometry the
	# validator will not accept.  Every later save of that region then fails
	# too, for a reason that has nothing to do with what the user just did.
	#
	# Reloading costs one directory scan and restores the only state that
	# was ever authoritative: the files.

	if (!_validateRegion("save '".($reg->{id} // '?')."'",\%out,0) ||
		!_checkContainment("save '".($reg->{id} // '?')."'",\%out))
	{
		rescanRegions();
		return 0;
	}
	_numify(\%out);

	my $path = _regionPath($reg->{id});
	if (!$path)
	{
		error("saveRegion: there is no active region set to save '".
			($reg->{id} // '?')."' into");
		return 0;
	}
	my $text = JSON::PP->new->pretty->canonical->encode(\%out);
	return 0 if !_writeFile($path,$text);

	$reg->{file} = "$reg->{id}.region";
	$regions{ _foldId($reg->{id}) } = $reg;
	_touch();
	display($dbg_region,0,"saved $reg->{file}");
	return 1;
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
	$zauthor = 15 if !defined $zauthor;
	$zmin    = $UPGRADE_ZMIN if !defined $zmin;
	$zmax    = $zauthor + 1  if !defined $zmax;

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
		geometry		=> [],
		subregions		=> [],
	};
	return saveRegion($reg) ? $reg : undef;
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
	return saveRegion($reg);
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

	# WHERE IT CAME FROM, not where its id says it would be written.  An
	# upgraded file has already had its id rewritten in memory, so
	# _regionPath($old_id) names a file that never existed and the real
	# one would be left behind as a duplicate.

	my $old_path = $reg->{file} ?
		_regionDir()."/$reg->{file}" : _regionPath($old_id);
	$reg->{id} = $new_id;

	if (!saveRegion($reg))
	{
		$reg->{id} = $old_id;
		return 0;
	}

	# Only now is the new file safely on disk.  A case-only change wrote
	# THROUGH the old file, so there is nothing to remove.

	if (!$same)
	{
		delete $regions{ _foldId($old_id) };
		unlink($old_path) if -f $old_path;
		_renameChecked($old_id,$new_id);
		_touch();
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
	# Where it came from, for the same reason setRegionId uses it: an
	# upgraded file's leaf and its id need not agree.

	my $path = $reg->{file} ?
		_regionDir()."/$reg->{file}" : _regionPath($reg->{id});
	if (-f $path && !unlink($path))
	{
		error("deleteRegion: could not delete $path: $!");
		return 0;
	}
	delete $regions{ _foldId($reg->{id}) };
	_touch();

	# Visibility leaves with the region.  There is no separate store to
	# reconcile and nothing to prune.

	delete $unchecked{ _checkKey($reg->{id}) };

	display($dbg_region,0,"deleted $reg->{id}.region");
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
		geometry	=> [],
		subregions	=> [],
	};
	push @{$parent->{subregions}},$sub;

	return saveRegion($reg) ? $sub : undef;
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
	return saveRegion($reg);
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
{
	my ($id) = @_;
	return lc(getActiveSet())."|"._foldId($id);
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
# KML import
#---------------------------------------------

sub _kmlPolygons
	# Every Placemark's outer ring, as [[lon,lat],...].  KML coordinates
	# are lon,lat[,alt] and whitespace separated.  Inner rings are ignored
	# deliberately: coverage is a union and never subtracts, so a hole
	# cannot mean anything here.
{
	my ($xml) = @_;
	my @polys;
	while ($xml =~ m{<Placemark>(.*?)</Placemark>}gs)
	{
		my $pm = $1;
		my ($outer) = $pm =~ m{<outerBoundaryIs>(.*?)</outerBoundaryIs>}s;
		$outer = $pm if !defined $outer;
		my ($coords) = $outer =~ m{<coordinates>\s*(.*?)\s*</coordinates>}s;
		next if !defined $coords;

		my @pts;
		for my $tuple (split(/\s+/,$coords))
		{
			next if $tuple !~ /\S/;
			my ($lon,$lat) = split(/,/,$tuple);
			next if !_isNum($lon) || !_isNum($lat);
			push @pts,[ 0 + $lon, 0 + $lat ];
		}

		# KML closes its rings by repeating the first point.  The model
		# does not store the closing point; a polygon is implicitly closed.

		pop @pts if @pts > 1 &&
			$pts[0][0] == $pts[-1][0] && $pts[0][1] == $pts[-1][1];

		push @polys,\@pts if @pts >= 3;
	}
	return @polys;
}


sub importKmlFile
	# Each KML Folder becomes one region, and every Placemark inside it
	# becomes one of that region's polygons.  A Folder holding two
	# disjoint shapes is one region with two polygons, which is what the
	# format is for.
	#
	# Returns the list of region ids created.
{
	my ($path,$zauthor,$zmin,$zmax) = @_;
	$zauthor = 15 if !defined $zauthor;
	$zmin    = $UPGRADE_ZMIN if !defined $zmin;
	$zmax    = $zauthor + 1  if !defined $zmax;

	my $xml = _readFile($path);
	return () if !defined $xml;

	my @made;
	while ($xml =~ m{<Folder>(.*?)</Folder>}gs)
	{
		my $folder = $1;
		my ($raw) = $folder =~ m{<name>\s*(.*?)\s*</name>}s;
		$raw = 'unnamed' if !defined($raw) || $raw !~ /\S/;

		# Google Earth folder names here read 'BocasDelToro (Bocas del
		# Toro)' - the bare token then the display name in parentheses.
		# Take the parenthesised form when it is there; it is the one a
		# person wrote.

		my $name = $raw =~ /^\s*\S+\s*\((.+)\)\s*$/ ? $1 : $raw;

		my @polys = _kmlPolygons($folder);
		if (!@polys)
		{
			warning(0,0,"importKml: folder '$raw' holds no usable polygon - skipped");
			next;
		}

		# The KML's bare token is the closest thing it has to an id, and it
		# is already CamelCase where these files came from ('BocasDelToro
		# (Bocas del Toro)').  It is still only a suggestion: BocasDelToro
		# is twelve characters and the author will want Bocas.

		my $token = $raw =~ /^\s*(\S+)\s*\(/ ? $1 : $name;
		my $id = _suggestId($token);
		$id = _suggestId($name) if $id !~ /^[A-Za-z0-9]+$/;

		if ($id !~ /^[A-Za-z0-9]+$/)
		{
			warning(0,0,"importKml: folder '$raw' does not yield a usable id - skipped");
			next;
		}
		if (getRegion($id))
		{
			warning(0,0,"importKml: a region with id '$id' already exists - skipped");
			next;
		}

		my $reg = {
			region_version	=> $REGION_VERSION,
			id				=> $id,
			name			=> $name,
			notes			=> "imported from ".($path =~ m{([^/\\]+)$})[0],
			zauthor			=> $zauthor,
			zmin			=> $zmin,
			zmax			=> $zmax,
			geometry		=> \@polys,
			subregions		=> [],
		};

		if (saveRegion($reg))
		{
			push @made,$id;
			display($dbg_region,1,sprintf("%-16s %d polygon(s), %d points",
				$id,scalar(@polys),regionPointCount($reg)));
		}
	}
	return @made;
}


1;
