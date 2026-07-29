#!/usr/bin/perl
#---------------------------------------------
# dm_region.pm
#---------------------------------------------
# The coverage model on disk.  See docs/design/regions.md.
#
#	$data_dir/<id>.region		one region, self contained
#	$data_dir/workspace.json	sets, and the defaults that are not a region's business
#
# EXISTENCE COMES FROM THE FOLDER.  Regions are found by scanning, exactly
# as sources are, so dropping in a region somebody sent you is how you add
# one.  The workspace holds only what a scan cannot answer.
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


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		loadRegions
		rescanRegions
		getRegionIds
		getRegion
		saveRegion
		newRegion
		renameRegion
		deleteRegion

		getWorkingSet
		isChecked
		setChecked
		getDefaultSource
		setDefaultSource

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


my $REGION_VERSION		= 1;
my $WORKSPACE_VERSION	= 1;
my $WORKSPACE_FILE		= 'workspace.json';

my @REGION_FIELDS		= qw( region_version id name notes canonical_zoom
							  geometry subregions );
my @SUBREGION_FIELDS	= qw( id name notes canonical_zoom geometry subregions );

my $scan_seq:shared	= 1;
my $my_seq			= 0;
my %regions;		# id => region hash
my $workspace;		# the decoded workspace, or undef until loaded


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
			elsif ($key eq 'canonical_zoom' || $key eq 'region_version' ||
				   $key eq 'workspace_version')
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

	return _err($where,"id is required and must be [a-z0-9_-]")
		if !defined($reg->{id}) || $reg->{id} !~ /^[a-z0-9_-]+$/;
	return _err($where,"name is required and may not be empty")
		if !defined($reg->{name}) || $reg->{name} !~ /\S/;

	return _err($where,"canonical_zoom must be an integer from 0 to 24")
		if !_isInt($reg->{canonical_zoom}) ||
			$reg->{canonical_zoom} < 0 || $reg->{canonical_zoom} > 24;

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
			if $seen{$sub->{id}}++;

		# A subregion at or below its parent's canonical zoom contributes
		# an empty band.  Harmless, because coverage is a union and never
		# subtracts, but it is doing no work and the author should know.

		warning(0,0,"$where: subregion '$sub->{id}' has canonical_zoom ".
			"$sub->{canonical_zoom}, at or below its parent '$reg->{id}' ".
			"($reg->{canonical_zoom}) - it contributes nothing")
			if $sub->{canonical_zoom} <= $reg->{canonical_zoom};
	}

	return $reg;
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

	if ($regions{$reg->{id}})
	{
		error("$leaf: id '$reg->{id}' is already defined by ".
			$regions{$reg->{id}}{file}." - ignoring $leaf");
		return;
	}

	$reg->{file} = $leaf;
	$regions{$reg->{id}} = $reg;
	display($dbg_region+1,1,"loaded $leaf as '$reg->{id}' (z$reg->{canonical_zoom}, ".
		regionPolygonCount($reg)." polygon(s), ".
		scalar(@{$reg->{subregions}})." subregion(s))");
	return $reg;
}


sub loadRegions
{
	%regions = ();

	my $dh;
	if (!opendir($dh,$data_dir))
	{
		error("could not read $data_dir: $!");
		return 0;
	}
	my @leaves = sort grep { /\.region$/i && -f "$data_dir/$_" } readdir($dh);
	closedir $dh;

	display($dbg_region,0,"loadRegions() scanning $data_dir");
	_loadFile("$data_dir/$_",$_) for @leaves;

	my $found = scalar(keys %regions);
	display($dbg_region,1,"$found region".($found == 1 ? '' : 's').
		" loaded from ".scalar(@leaves)." file".(@leaves == 1 ? '' : 's'));

	_loadWorkspace();

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
{
	loadRegions() if $my_seq != $scan_seq;
}


sub getRegionIds
	# Returns a real array rather than 'sort keys' directly, because the
	# behaviour of sort in scalar context is undefined in Perl -- so
	# scalar(getRegionIds()) would be garbage rather than the count that
	# any caller writing it would expect.
{
	_current();
	my @ids = sort keys %regions;
	return @ids;
}


sub getRegion
{
	my ($id) = @_;
	_current();
	return $regions{$id // ''};
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
	return "$data_dir/$id.region";
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

	return 0 if !_validateRegion("save '".($reg->{id} // '?')."'",\%out,0);
	_numify(\%out);

	my $path = _regionPath($reg->{id});
	my $text = JSON::PP->new->pretty->canonical->encode(\%out);
	return 0 if !_writeFile($path,$text);

	$reg->{file} = "$reg->{id}.region";
	$regions{$reg->{id}} = $reg;
	_touch();
	display($dbg_region,0,"saved $reg->{file}");
	return 1;
}


sub newRegion
	# A new region has an id derived from its name, no geometry, and the
	# canonical zoom the caller asks for.  Drawing comes later.
{
	my ($name,$zoom) = @_;
	$zoom = 15 if !defined $zoom;

	my $id = lc($name);
	$id =~ s/[^a-z0-9]+/_/g;
	$id =~ s/^_+|_+$//g;
	if ($id eq '')
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
		canonical_zoom	=> $zoom,
		geometry		=> [],
		subregions		=> [],
	};
	return saveRegion($reg) ? $reg : undef;
}


sub renameRegion
	# The NAME changes; the id does not.  The id is what sets reference
	# and what the file is called, and a rename that moved it would break
	# every set that named it.
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


sub deleteRegion
{
	my ($id) = @_;
	my $reg = getRegion($id);
	if (!$reg)
	{
		error("deleteRegion: no region with id '$id'");
		return 0;
	}
	my $path = _regionPath($id);
	if (-f $path && !unlink($path))
	{
		error("deleteRegion: could not delete $path: $!");
		return 0;
	}
	delete $regions{$id};
	_touch();

	# Membership leaves with the region.  There is no separate visibility
	# store to reconcile and nothing to prune.

	_loadWorkspace();
	for my $set (keys %{$workspace->{sets}})
	{
		$workspace->{sets}{$set} =
			[ grep { $_ ne $id } @{$workspace->{sets}{$set}} ];
	}
	_saveWorkspace();

	display($dbg_region,0,"deleted $id.region");
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
	for my $sub (@{$reg->{subregions} || []})
	{
		return ($sub,$reg) if $sub->{id} eq $id;
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
	# deeper than the rest of it.  Given as a centre, a half extent in
	# nautical miles and the zoom it should be quantised at - which is how
	# anyone actually thinks about an anchorage or a pass.
{
	my ($parent_id,$name,$lat,$lon,$half_nm,$zoom) = @_;

	my $reg = getRegion($parent_id);
	if (!$reg)
	{
		error("addSubregion: no region with id '$parent_id'");
		return undef;
	}
	if (!defined($name) || $name !~ /\S/)
	{
		error("addSubregion: a name is required");
		return undef;
	}
	if (!_isNum($lat) || !_isNum($lon) || !_isNum($half_nm) || $half_nm <= 0)
	{
		error("addSubregion: lat, lon and a positive half_nm are required");
		return undef;
	}
	if (!_isInt($zoom) || $zoom < 0 || $zoom > 24)
	{
		error("addSubregion: canonical_zoom must be an integer from 0 to 24");
		return undef;
	}

	my $id = lc($name);
	$id =~ s/[^a-z0-9]+/_/g;
	$id =~ s/^_+|_+$//g;
	if ($id eq '')
	{
		error("addSubregion: '$name' does not yield a usable id");
		return undef;
	}
	if ((findSubregion($reg,$id))[0])
	{
		error("addSubregion: '$parent_id' already has a subregion '$id'");
		return undef;
	}

	my $sub = {
		id				=> $id,
		name			=> $name,
		canonical_zoom	=> $zoom,
		geometry		=> _boxAround($lat,$lon,$half_nm),
		subregions		=> [],
	};
	push @{$reg->{subregions}},$sub;

	return saveRegion($reg) ? $sub : undef;
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
# the workspace
#---------------------------------------------

sub _workspacePath
{
	return "$data_dir/$WORKSPACE_FILE";
}


sub _loadWorkspace
{
	$workspace = {
		workspace_version	=> $WORKSPACE_VERSION,
		sets				=> { working => [] },
		default_source		=> '',
	};

	my $path = _workspacePath();
	return $workspace if !-f $path;

	my $text = _readFile($path);
	return $workspace if !defined $text;

	my $got = eval { JSON::PP->new->decode($text) };
	if ($@ || ref($got) ne 'HASH')
	{
		error("$WORKSPACE_FILE is not valid JSON - using an empty workspace");
		return $workspace;
	}

	$workspace->{sets} = $got->{sets}
		if ref($got->{sets}) eq 'HASH';
	$workspace->{sets}{working} ||= [];
	$workspace->{default_source} = $got->{default_source}
		if defined $got->{default_source};

	return $workspace;
}


sub _saveWorkspace
{
	_loadWorkspace() if !$workspace;
	my %out = %$workspace;
	$out{workspace_version} = $WORKSPACE_VERSION;
	_numify(\%out);
	my $ok = _writeFile(_workspacePath(),
		JSON::PP->new->pretty->canonical->encode(\%out));
	_touch() if $ok;
	return $ok;
}


sub getWorkingSet
{
	_current();
	_loadWorkspace() if !$workspace;

	# A set may name a region whose file is gone.  The folder is the
	# authority on existence, so a stale name is simply not returned.

	return grep { $regions{$_} } @{$workspace->{sets}{working}};
}


sub isChecked
{
	my ($id) = @_;
	return scalar(grep { $_ eq $id } getWorkingSet()) ? 1 : 0;
}


sub setChecked
{
	my ($id,$on) = @_;
	if (!getRegion($id))
	{
		error("setChecked: no region with id '$id'");
		return 0;
	}
	_loadWorkspace() if !$workspace;

	my @set = grep { $_ ne $id } @{$workspace->{sets}{working}};
	push @set,$id if $on;
	$workspace->{sets}{working} = \@set;
	return _saveWorkspace();
}


sub getDefaultSource
{
	_loadWorkspace() if !$workspace;
	return $workspace->{default_source} || '';
}


sub setDefaultSource
{
	my ($id) = @_;
	_loadWorkspace() if !$workspace;
	$workspace->{default_source} = $id // '';
	return _saveWorkspace();
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
	my ($path,$zoom) = @_;
	$zoom = 15 if !defined $zoom;

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

		my $id = lc($name);
		$id =~ s/[^a-z0-9]+/_/g;
		$id =~ s/^_+|_+$//g;

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
			canonical_zoom	=> $zoom,
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
