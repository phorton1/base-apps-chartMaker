#!/usr/bin/perl
#---------------------------------------------
# dm_source.pm
#---------------------------------------------
# Tile Source Definitions -- reading, validating, and addressing.
#
# A TSD is a small JSON file describing exactly one imagery source.  See
# docs/design/tsd.md.  This module is the only thing in the application
# that knows the format; everything else asks for a source by id and gets
# back a validated hash.
#
# ONLY $data_dir/sources IS SCANNED.  Sources that ship with the
# application are copied into the user's data dir by the installer under
# an existence guard, which makes a shipped source an ordinary editable
# file like any other.  There is no second search path and no shadowing
# rule.
#
# EXISTENCE COMES FROM THE FOLDER, SELECTION COMES FROM THE INI, exactly
# as for region sets.  getDefaultSource resolves a remembered id that may
# no longer name anything; see the note there for why the fallback is
# what it is.
#
# VALIDATION IS IN CODE.  The format is specified as JSON with a published
# schema, but no JSON Schema validator is present in this Perl and adding
# one is not worth a dependency for a dozen rules.  The rules below ARE
# the schema until the format stops moving.
#
# THREADS.  The HTTP server answers on several threads, and each thread
# receives its own copy of this module's data when it is spawned.  Rather
# than share the source hashes -- which would mean flattening every nested
# structure into shared containers -- a shared generation counter is
# bumped on rescan, and each thread reloads when it notices it is behind.
# A read costs one integer comparison, and a rescan issued at the console
# is picked up by every server thread on its next request.

package dm_source;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP;
use Pub::Utils;
use cm_defs;
use cm_state;
use dm_set;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		loadSources
		rescanSources
		getSourceIds
		getBuildSourceIds
		getSource
		sourceTileUrl
		getDefaultSource
		setDefaultSource
	);
}


our $dbg_source:shared = 0;
	# 0  = the load summary
	# -1 = one line per file
	# -2 = field detail and every url built


my $TSD_VERSION = 1;

my @KINDS			= qw( remote_xyz local_mbtiles local_dir wms );
my @IMPLEMENTED		= qw( remote_xyz );
my @USES			= qw( display build overlay );
	# OVERLAY is a third PURPOSE, not a third kind of thing.  A source
	# that declares it is drawn over a base layer rather than instead of
	# one - place names, boundaries - which is the difference between a
	# radio button and a checkbox, and nothing else about the file
	# changes.  Adding a value to a vocabulary invalidates no existing
	# file, so tsd_version does not move.
my @REDISTRIBUTABLE	= qw( yes no unknown );
my @FORMATS			= qw( jpeg png );

my @FIELDS = qw(
	tsd_version id name notes kind url subdomains tile_format tile_size
	crs zoom attribution terms_url license redistributable uses
	credentials policy absent_fingerprints absent_headers registration );

# The closed placeholder set.  A url may contain these and the credential
# slots the file itself declares, and nothing else.  {-y} covers the TMS
# row flip so no scheme enum is needed; {q} covers quadkey addressing,
# which is the same grid under a different encoding.

my @PLACEHOLDERS = qw( z x y -y s q );


my $scan_seq:shared	= 1;	# bumped by rescanSources()
my $my_seq			= 0;	# the generation this thread has loaded
my %sources;				# id => validated source hash

my $default_source:shared = '';
	# The REMEMBERED id from the ini, not the resolved one.  Shared,
	# because it is set from whichever thread the user changed it on and
	# read by all of them.
my $subdomain_seq	= 0;	# round robin for {s}


#---------------------------------------------
# validation
#---------------------------------------------

sub _err
	# Every rule failure comes through here so that a rejected file
	# reports its own name and one specific reason.
{
	my ($file,$msg) = @_;
	error("$file: $msg");
	return undef;
}


sub _isInt
{
	my ($val) = @_;
	return defined($val) && !ref($val) && $val =~ /^-?\d+$/;
}


sub _placeholdersOf
	# Every {...} in a url template, in order of appearance.
{
	my ($url) = @_;
	my @found;
	while ($url =~ /\{([^{}]*)\}/g)
	{
		push @found,$1;
	}
	return @found;
}


sub _validate
	# Returns the source hash, or undef having reported the reason.
	# The rules are deliberately unforgiving: these files circulate
	# between people who do not know each other, and a file that is
	# almost right is worse than one that is refused.
{
	my ($file,$tsd) = @_;

	return _err($file,"not a JSON object")
		if ref($tsd) ne 'HASH';

	# unknown fields are an error, not a warning -- the format is
	# supposed to be a statement of what it is ABLE to say

	my %known = map { $_ => 1 } @FIELDS;
	for my $key (sort keys %$tsd)
	{
		return _err($file,"unknown field '$key'")
			if !$known{$key};
	}

	return _err($file,"tsd_version must be an integer")
		if !_isInt($tsd->{tsd_version});
	return _err($file,"tsd_version $tsd->{tsd_version} is newer than this application understands ($TSD_VERSION)")
		if $tsd->{tsd_version} > $TSD_VERSION;

	return _err($file,"id is required and must be [a-z0-9_-]")
		if !defined($tsd->{id}) || $tsd->{id} !~ /^[a-z0-9_-]+$/;

	# '$SOURCE_INHERITED' IS SPOKEN FOR.  Regions name their source by id
	# and use that one word to mean "not my decision", so a source
	# actually called that could never be selected by anything.  Refusing
	# the file says so, where accepting it would produce a source that
	# quietly does not work.

	return _err($file,"id '$SOURCE_INHERITED' is reserved - it is what a ".
			"region says when it has not chosen a source")
		if $tsd->{id} eq $SOURCE_INHERITED;
	return _err($file,"name is required and may not be empty")
		if !defined($tsd->{name}) || $tsd->{name} !~ /\S/;

	# attribution is mandatory.  One rule, and every package chartMaker
	# emits can carry its provenance.

	return _err($file,"attribution is required and may not be empty")
		if !defined($tsd->{attribution}) || $tsd->{attribution} !~ /\S/;

	my $kind = $tsd->{kind} // '';
	return _err($file,"kind must be one of ".join('|',@KINDS))
		if !grep { $_ eq $kind } @KINDS;
	return _err($file,"kind '$kind' is not implemented yet")
		if !grep { $_ eq $kind } @IMPLEMENTED;

	# Web Mercator at 256 pixels, or rejected at import.  Tiles pass
	# through byte for byte, which is what keeps an image processing
	# stack out of the installer.

	$tsd->{tile_size} = 256 if !defined $tsd->{tile_size};
	return _err($file,"tile_size must be 256")
		if !_isInt($tsd->{tile_size}) || $tsd->{tile_size} != 256;

	$tsd->{crs} = 'EPSG:3857' if !defined $tsd->{crs};
	return _err($file,"crs must be EPSG:3857")
		if $tsd->{crs} ne 'EPSG:3857';

	# tile_format is an EXPECTATION.  The actual format is detected from
	# the image's magic bytes, because servers mix them.

	$tsd->{tile_format} = 'jpeg' if !defined $tsd->{tile_format};
	return _err($file,"tile_format must be one of ".join('|',@FORMATS))
		if !grep { $_ eq $tsd->{tile_format} } @FORMATS;

	$tsd->{redistributable} = 'unknown' if !defined $tsd->{redistributable};
	return _err($file,"redistributable must be one of ".join('|',@REDISTRIBUTABLE))
		if !grep { $_ eq $tsd->{redistributable} } @REDISTRIBUTABLE;

	my $uses = $tsd->{uses};
	return _err($file,"uses is required and must be a non-empty array")
		if ref($uses) ne 'ARRAY' || !@$uses;
	for my $use (@$uses)
	{
		return _err($file,"uses may only contain ".join('|',@USES))
			if !grep { $_ eq $use } @USES;
	}

	# zoom carries PROTOCOL limits only -- where the server starts
	# refusing.  Where real detail ends is a data fact, discovered.

	my $zoom = $tsd->{zoom};
	return _err($file,"zoom must be an object with min and max")
		if ref($zoom) ne 'HASH';
	$zoom->{min} = 0 if !defined $zoom->{min};
	return _err($file,"zoom.min and zoom.max must be integers")
		if !_isInt($zoom->{min}) || !_isInt($zoom->{max});
	return _err($file,"zoom must satisfy 0 <= min <= max <= 24")
		if $zoom->{min} < 0 || $zoom->{max} < $zoom->{min} || $zoom->{max} > 24;

	# credentials are SLOTS, never values

	my %slots;
	if (defined $tsd->{credentials})
	{
		return _err($file,"credentials must be an array")
			if ref($tsd->{credentials}) ne 'ARRAY';
		for my $cred (@{$tsd->{credentials}})
		{
			return _err($file,"each credential must be an object with a slot")
				if ref($cred) ne 'HASH' || !defined($cred->{slot});
			return _err($file,"credential slot '$cred->{slot}' must be [a-z0-9_]")
				if $cred->{slot} !~ /^[a-z0-9_]+$/;
			return _err($file,"credential slot '$cred->{slot}' is declared twice")
				if $slots{$cred->{slot}}++;
		}
	}

	if (defined $tsd->{policy})
	{
		return _err($file,"policy must be an object")
			if ref($tsd->{policy}) ne 'HASH';
		for my $key (qw( max_concurrency min_interval_ms ))
		{
			return _err($file,"policy.$key must be a non-negative integer")
				if defined($tsd->{policy}{$key}) &&
				   (!_isInt($tsd->{policy}{$key}) || $tsd->{policy}{$key} < 0);
		}
	}

	# ABSENT FINGERPRINTS -- the bytes a server sends INSTEAD of saying no.
	#
	# A well behaved source answers 404 for a tile it does not hold.  Some
	# answer 200 with a fixed image saying so in words: Esri's "Map data
	# not yet available" is one image, 2521 bytes, byte for byte identical
	# every time.  Nothing downstream can tell that from imagery, so a
	# build bakes grey tiles into a card and reports success - the worst
	# failure this application has, because every signal says it worked.
	#
	# Declared rather than detected, because it is a fact about a server
	# and this format is where facts about servers live.  The probe can
	# discover them; the file is what remembers.
	#
	# BOTH FIELDS, and in that order: length is a free comparison and the
	# digest is only computed when a length actually matches, so the
	# common case - no fingerprints, or no match - costs one integer test
	# per tile.

	if (defined $tsd->{absent_fingerprints})
	{
		return _err($file,"absent_fingerprints must be an array")
			if ref($tsd->{absent_fingerprints}) ne 'ARRAY';
		for my $fp (@{$tsd->{absent_fingerprints}})
		{
			return _err($file,"each absent_fingerprint must be an object")
				if ref($fp) ne 'HASH';
			return _err($file,"absent_fingerprint bytes must be a positive integer")
				if !_isInt($fp->{bytes}) || $fp->{bytes} < 1;
			return _err($file,"absent_fingerprint md5 must be 32 hex digits")
				if !defined($fp->{md5}) || $fp->{md5} !~ /^[0-9a-fA-F]{32}$/;
			$fp->{md5} = lc($fp->{md5});
		}
	}

	# ABSENT HEADERS -- the same absence, said in a header rather than in
	# the bytes.  Virtual Earth's 'X-VE-Tile-Info: no-tile' is the known
	# case: a 200 carrying a real image that the server is simultaneously
	# telling you is not imagery.
	#
	# CHEAPER AND STRICTER THAN A FINGERPRINT, and it has to be, because
	# it is checked on every 200.  A header lookup on a name that is not
	# present is a hash miss, where a fingerprint at least has to measure
	# the body.  So the match is EXACT after trimming: a substring rule
	# would make 'no-tile' match a header that said 'no-tile-here', and a
	# false absence is the one error in this direction that is expensive --
	# it caches a miss for a tile that exists.
	#
	# IT CANNOT REACH THE CACHE, which is the asymmetry with fingerprints.
	# Headers are not stored beside the bytes, so getTile's on-the-way-out
	# recheck has nothing to test and declaring a header here reclassifies
	# nothing already on disk.  That is why the check lives in fetchTile
	# rather than beside _isDeclaredAbsent.

	if (defined $tsd->{absent_headers})
	{
		return _err($file,"absent_headers must be an array")
			if ref($tsd->{absent_headers}) ne 'ARRAY';
		for my $hdr (@{$tsd->{absent_headers}})
		{
			return _err($file,"each absent_header must be an object")
				if ref($hdr) ne 'HASH';

			# RFC 7230 token, which is what a header name may contain.
			# Lowercased on the way in: lookup is case insensitive, so
			# storing one case means two files declaring the same header
			# differently produce the same structure.

			return _err($file,"absent_header name is required and must be a header token")
				if !defined($hdr->{name}) || ref($hdr->{name}) ||
				   $hdr->{name} !~ /^[A-Za-z0-9!#\$%&'*+.^_`|~-]+$/;
			return _err($file,"absent_header value is required and may not be empty")
				if !defined($hdr->{value}) || ref($hdr->{value}) ||
				   $hdr->{value} !~ /\S/;

			$hdr->{name}  = lc($hdr->{name});
			$hdr->{value} =~ s/^\s+|\s+$//g;
		}
	}

	# REGISTRATION -- a known displacement of the imagery, recorded and
	# shown, NEVER acted on.
	#
	# China's GCJ-02 is the case that names the field: imagery published
	# on a deliberately offset datum, off by a few hundred metres in a way
	# that varies with position.  A user aiming a region at a harbour is
	# entitled to know before they build, and the honest thing to tell
	# them is that the source says so, not a correction this application
	# invented.
	#
	# NO VOCABULARY, deliberately.  Advisory means the value is for a
	# human to read, and an enum would reject a true statement about a
	# datum nobody had thought of -- which for a field that changes no
	# behaviour is a pure loss.  The pattern only keeps it a short printable
	# name, so that showing it cannot wreck a layout.

	if (defined $tsd->{registration})
	{
		return _err($file,"registration must be a short name like 'GCJ-02'")
			if ref($tsd->{registration}) ||
			   $tsd->{registration} !~ /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$/;
	}

	# the url and its closed placeholder set

	return _err($file,"url is required for kind '$kind'")
		if !defined($tsd->{url}) || $tsd->{url} !~ /\S/;

	my %allowed = map { $_ => 1 } (@PLACEHOLDERS, keys %slots);
	my @used    = _placeholdersOf($tsd->{url});
	my %used    = map { $_ => 1 } @used;

	for my $ph (@used)
	{
		return _err($file,"url contains '{$ph}', which is not a placeholder this format defines")
			if !$allowed{$ph};
	}

	return _err($file,"url must address a tile: either {z}, {x} and {y} or {-y}, or else {q}")
		if !($used{q} || ($used{z} && $used{x} && ($used{y} || $used{'-y'})));

	if ($used{s})
	{
		my $subs = $tsd->{subdomains};
		$subs = [ split(//,$subs) ] if defined($subs) && !ref($subs);
		return _err($file,"url uses {s} but no subdomains are declared")
			if ref($subs) ne 'ARRAY' || !@$subs;
		$tsd->{subdomains} = $subs;
	}

	return $tsd;
}


#---------------------------------------------
# loading
#---------------------------------------------

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


sub _loadFile
{
	my ($path,$leaf) = @_;

	my $text = _readFile($path);
	return if !defined $text;

	my $tsd = eval { JSON::PP->new->decode($text) };
	if ($@)
	{
		my $why = $@;
		$why =~ s/\s+at\s+.*//s;
		error("$leaf: not valid JSON - $why");
		return;
	}

	$tsd = _validate($leaf,$tsd);
	return if !$tsd;

	# The cache is keyed by the LEAF NAME of the file rather than the id
	# inside it, so that a user looking at the cache in a file browser
	# sees one folder per source they have used.  Renaming a TSD orphans
	# its cache directory, which costs a refetch and nothing else.

	$tsd->{file} = $leaf;
	$tsd->{cache_key} = $leaf;
	$tsd->{cache_key} =~ s/\.tsd$//i;

	if ($sources{$tsd->{id}})
	{
		error("$leaf: id '$tsd->{id}' is already defined by ".
			$sources{$tsd->{id}}{file}." - ignoring $leaf");
		return;
	}

	$sources{$tsd->{id}} = $tsd;
	display($dbg_source+1,1,"loaded $leaf as '$tsd->{id}' (".
		join(',',@{$tsd->{uses}}).", z$tsd->{zoom}{min}-$tsd->{zoom}{max})");
	return $tsd;
}


sub loadSources
	# Scan $data_dir/sources for .tsd files.  Called at startup, and again
	# by any thread that finds itself behind the shared generation counter.
{
	%sources = ();

	my $dir = sourcesDir();
	my $dh;
	if (!opendir($dh,$dir))
	{
		error("could not read $dir: $!");
		return;
	}
	my @leaves = sort grep { /\.tsd$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;

	display($dbg_source,0,"loadSources() scanning $dir");
	_loadFile("$dir/$_",$_) for @leaves;

	my $found = scalar(keys %sources);
	my $seen  = scalar(@leaves);
	display($dbg_source,1,"$found source".($found == 1 ? '' : 's').
		" loaded from $seen file".($seen == 1 ? '' : 's'));

	$my_seq = $scan_seq;
	return $found;
}


sub rescanSources
	# Re-read from disk, and tell every other thread to do the same.
{
	$scan_seq++;
	return loadSources();
}


sub _current
	# Every read goes through here.  One integer comparison in the
	# common case; a reload only when this thread is behind.
{
	loadSources() if $my_seq != $scan_seq;
}


sub getSourceIds
	# A real array rather than 'sort keys' directly: sort in scalar
	# context is undefined in Perl, so scalar(getSourceIds()) would be
	# garbage instead of the count a caller would expect.
{
	_current();
	my @ids = sort keys %sources;
	return @ids;
}


sub getBuildSourceIds
	# The sources a REGION may name.  'uses' is the author's statement of
	# what a source is for, and a source that does not say 'build' is not
	# offered as one -- a display-only basemap chosen as a build source
	# would fail at the only moment it mattered, hours in.
{
	# A real array for the reason getSourceIds gives: sort in scalar
	# context is undefined, so a caller counting the result would get
	# garbage rather than a count.

	_current();
	my @ids = sort grep {
		grep { $_ eq 'build' } @{$sources{$_}{uses}}
	} keys %sources;
	return @ids;
}


sub getDefaultSource
	# The remembered source if it still exists, else the official default
	# if IT exists, else the first source in tree order, else ''.
	#
	# RESOLVED ON EVERY READ, never cached, for the reason dm_set's
	# getActiveSet gives: the remembered id is a pointer into folder
	# contents, and the folder is edited from outside this application.
	# Deleting a .tsd should quietly leave the map on something else, not
	# leave it on nothing with no way to say so.
{
	my @ids = getSourceIds();
	return '' if !@ids;

	return $default_source if $default_source && $sources{$default_source};
	return $DEFAULT_SOURCE_ID if $sources{$DEFAULT_SOURCE_ID};
	return $ids[0];
}


sub setDefaultSource
	# Remembered, not resolved -- an id is stored even when it names
	# nothing, because the ini is read before the first scan.
{
	my ($id) = @_;
	$id //= '';
	return 1 if $id eq $default_source;
	$default_source = $id;
	bumpState("source is now '$id'");
	return 1;
}


sub getSource
{
	my ($id) = @_;
	_current();
	return $sources{$id // ''};
}


#---------------------------------------------
# addressing
#---------------------------------------------

sub _quadKey
	# Bing style addressing: the same grid, interleaved into one string.
{
	my ($z,$x,$y) = @_;
	my $key = '';
	for (my $i = $z; $i > 0; $i--)
	{
		my $digit = 0;
		my $mask  = 1 << ($i - 1);
		$digit++    if $x & $mask;
		$digit += 2 if $y & $mask;
		$key .= $digit;
	}
	return $key;
}


sub sourceTileUrl
	# The url for one tile, or undef if this source cannot answer for it.
	#
	# Undef is a DEFINITE ABSENCE rather than an error: a zoom outside the
	# source's declared protocol range is a question the server would
	# refuse, so there is no point in asking it.
{
	my ($source,$z,$x,$y) = @_;
	return undef if !$source;

	if ($z < $source->{zoom}{min} || $z > $source->{zoom}{max})
	{
		display($dbg_source+2,0,
			"sourceTileUrl($source->{id},$z) outside declared zoom ".
			"$source->{zoom}{min}-$source->{zoom}{max}");
		return undef;
	}

	if ($source->{credentials} && @{$source->{credentials}})
	{
		warning(0,0,"source '$source->{id}' declares credentials, ".
			"and the credential store is not implemented yet");
		return undef;
	}

	my $url = $source->{url};
	my $max = (1 << $z) - 1;

	$url =~ s/\{z\}/$z/g;
	$url =~ s/\{x\}/$x/g;
	$url =~ s/\{y\}/$y/g;
	$url =~ s/\{-y\}/$max - $y/ge;
	$url =~ s/\{q\}/_quadKey($z,$x,$y)/ge;

	if ($url =~ /\{s\}/)
	{
		my $subs = $source->{subdomains};
		my $sub  = $subs->[ $subdomain_seq++ % scalar(@$subs) ];
		$url =~ s/\{s\}/$sub/g;
	}

	display($dbg_source+2,0,"sourceTileUrl($source->{id},$z,$x,$y) = $url");
	return $url;
}


1;
