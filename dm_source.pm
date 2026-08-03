#!/usr/bin/perl
#---------------------------------------------
# dm_source.pm
#---------------------------------------------
# Tile Source Definitions -- reading, validating, and addressing.
#
# A TSD is a small JSON file describing exactly one imagery source: a
# REMOTE XYZ TILE SERVICE serving 256 pixel tiles in EPSG:3857, which is
# the only shape of source this application reads.  See docs/design/tsd.md.
# This module is the only thing in the application that knows the format;
# everything else asks for a source by id and gets back a validated hash.
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
# VALIDATION IS IN CODE.  _validate below is the whole of it -- one
# statement of what a TSD may be, with nothing maintained alongside it
# that could drift out of agreement with it.  docs/design/tsd.md
# describes the same rules in prose.
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

		getSourceFiles
		getRefused
		sourceFields
		checkSourceField
		checkSource
		readSourceFile
		writeSourceFile
		deleteSourceFile
	);
}


our $dbg_source:shared = 0;
	# 0  = the load summary
	# -1 = one line per file
	# -2 = field detail and every url built


my $TSD_VERSION = 1;

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
	tsd_version id name notes cache_key url subdomains tile_format tile_size
	crs zoom attribution terms_url license redistributable uses
	credentials policy absent_fingerprints absent_headers displacement );

# The closed placeholder set.  A url may contain these and the credential
# slots the file itself declares, and nothing else.  {-y} covers the TMS
# row flip so no scheme enum is needed; {q} covers quadkey addressing,
# which is the same grid under a different encoding.

my @PLACEHOLDERS = qw( z x y -y s q );


my $scan_seq:shared	= 1;	# bumped by rescanSources()
my $my_seq			= 0;	# the generation this thread has loaded
my %sources;				# id => validated source hash
my %refused;				# leaf => why it is not a source

# WHAT THE FOLDER HOLDS IS NOT WHAT LOADED, and both are needed.
#
# %sources is the set of things that can be SHOWN, FETCHED and BUILT, and
# keeping it pure is what makes a bad file structurally unable to reach a
# cache.  But a file that fails is exactly the file somebody has to open
# and repair, and it used to vanish from the only window that could do it.
# So the reason is kept beside the name and the source list shows FILES.
#
# Nothing in the data model reads %refused.  It exists for the editor.

my $default_source:shared = '';
	# The REMEMBERED id from the ini, not the resolved one.  Shared,
	# because it is set from whichever thread the user changed it on and
	# read by all of them.
my $subdomain_seq	= 0;	# round robin for {s}


#---------------------------------------------
# validation
#---------------------------------------------

my $quiet      = 0;		# checkSource() asks without reporting
my $last_error = '';	# the reason the most recent _err gave

sub _err
	# Every rule failure comes through here so that a rejected file
	# reports its own name and one specific reason.
	#
	# THE REASON IS KEPT, NOT ONLY LOGGED.  The editor asks whether a file
	# would load and has to say why it would not, next to the field that is
	# wrong, and a message that only ever reached the log could not be shown
	# to the person who could fix it.
{
	my ($file,$msg) = @_;
	$last_error = $msg;
	error("$file: $msg") if !$quiet;
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

	# THREE NAMES, THREE JOBS.  The id is what a REGION points at.  The
	# leaf filename is the CONTAINER, and a container should be free to
	# rename, copy and back up.  cache_key names the TILES, which are the
	# expensive and persistent thing either of the other two refers to,
	# and until it could be declared it was only a shadow of the filename
	# - so renaming a file stranded gigabytes and every SaveAs variant
	# started a fresh cache.
	#
	# DECLARING ONE IS AN ASSERTION that these files address the same
	# service, the same species of statement as 'uses' and
	# 'redistributable'.  It is not checked against the url, because two
	# templates can differ in ways that do not change which tiles come
	# back, and the application does not get to overrule the person who
	# wrote the file.
	#
	# It becomes a FOLDER NAME, so it is held to the same characters as
	# the id: lower case, which also means two keys cannot differ only in
	# case and collide on a Windows filesystem.

	return _err($file,"cache_key must be [a-z0-9_-]")
		if defined($tsd->{cache_key}) &&
		   (ref($tsd->{cache_key}) || $tsd->{cache_key} !~ /^[a-z0-9_-]+$/);

	# attribution is mandatory.  One rule, and every package chartMaker
	# emits can carry its provenance.

	return _err($file,"attribution is required and may not be empty")
		if !defined($tsd->{attribution}) || $tsd->{attribution} !~ /\S/;

	# ONE SHAPE OF SOURCE AND ONLY ONE: a remote XYZ tile service serving
	# 256 pixel tiles in Web Mercator, or rejected at import.  Tiles pass
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

	# DISPLACEMENT -- a known displacement of the imagery, recorded and
	# shown, NEVER acted on.  Named for the oddity it is: 'registration'
	# is what every dataset has, and reads as a field to go fill in.
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

	if (defined $tsd->{displacement})
	{
		return _err($file,"displacement must be a short name like 'GCJ-02'")
			if ref($tsd->{displacement}) ||
			   $tsd->{displacement} !~ /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$/;
	}

	# the url and its closed placeholder set

	return _err($file,"url is required")
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
		$why =~ s/\s+$//;
		error("$leaf: not valid JSON - $why");
		$refused{$leaf} = "not valid JSON - $why";
		return;
	}

	$tsd = _validate($leaf,$tsd);
	if (!$tsd)
	{
		$refused{$leaf} = $last_error;
		return;
	}

	# THE CACHE KEY DEFAULTS TO THE LEAF NAME, and a file that declares one
	# keeps it.  The default is what makes a cache folder recognisable to
	# somebody looking at it in a file browser; declaring one is what lets a
	# file be renamed, copied or edited into a variant without stranding the
	# tiles, which are the expensive thing here.  See _validate.

	$tsd->{file} = $leaf;
	if (!defined $tsd->{cache_key})
	{
		$tsd->{cache_key} = $leaf;
		$tsd->{cache_key} =~ s/\.tsd$//i;
	}

	# A COLLISION REFUSES BOTH SIDES, and that is a change from keeping
	# whichever file sorted first.  Picking a winner by lexical accident
	# says one of two indistinguishable files is the real one, and it hid
	# the collision behind a source that still worked - so the map went on
	# rendering from a file the user might not have meant while the other
	# was invisible.  Refusing both makes the collision the visible thing,
	# which is the only state from which it can be repaired.

	if (my $prev = $sources{$tsd->{id}})
	{
		my $why = "id '$tsd->{id}' is declared by both $prev->{file} ".
			"and $leaf - an id names one source";
		error("$leaf: $why");
		$refused{$leaf}        = $why;
		$refused{$prev->{file}} = $why;
		delete $sources{$tsd->{id}};
		return;
	}

	# A SHARED KEY WITH A DIFFERENT URL IS REFUSED, NOT REPORTED.
	#
	# Sharing a key is an assertion that two files address the same
	# service, which is the whole point of the field: an edit in progress,
	# a backup, or a variant differing only in 'uses' should reach the same
	# tiles.  If the urls differ then one of those files is wrong, and the
	# consequence is precisely the failure the cache's source dimension
	# exists to prevent -- tiles fetched through one file handed out as
	# though they came from the other, producing a build that looks
	# complete and contains the wrong imagery.  A warning would leave that
	# possible; refusing the file makes it structurally impossible.
	#
	# BOTH SIDES ARE REFUSED, for the reason the duplicate id above gives:
	# the two files disagree and nothing here can say which one is right.
	#
	# The comparison is exact and therefore strict: two spellings of one
	# service - with and without {s}, or a different subdomain host - are
	# refused even though they would have agreed.  That direction is
	# deliberate.  A refusal costs one edit and says why; the other error
	# silently poisons a cache that nothing afterwards can tell is wrong.

	for my $other (values %sources)
	{
		next if $other->{cache_key} ne $tsd->{cache_key};
		next if $other->{url} eq $tsd->{url};
		my $why = "cache_key '$tsd->{cache_key}' is shared by $other->{file} ".
			"and $leaf, which have different urls - sharing a key means ".
			"sharing tiles, so one of the two is wrong";
		error("$leaf: $why");
		$refused{$leaf}         = $why;
		$refused{$other->{file}} = $why;
		delete $sources{$other->{id}};
		return;
	}

	$sources{$tsd->{id}} = $tsd;
	display($dbg_source+1,1,"loaded $leaf as '$tsd->{id}' (".
		join(',',@{$tsd->{uses}}).", z$tsd->{zoom}{min}-$tsd->{zoom}{max})");
	return $tsd;
}


#---------------------------------------------
# what the editor reads and writes
#---------------------------------------------
# THE FORMAT STAYS IN ONE MODULE.  The editor colours one field at a time
# and therefore needs a rule per field, but putting those rules in a wx
# file would be a second rulebook that could drift from the one that
# decides whether a file loads.  So both live here: checkSourceField says
# whether one value is well formed, and checkSource is still the whole
# file's verdict and still the authority.

my @EDIT_FIELDS = (
	# name              kind        label
	[ 'id',             'text',     'Id' ],
	[ 'cache_key',      'text',     'Cache key' ],
	[ 'name',           'text',     'Name' ],
	[ 'url',            'big',      'Url' ],
	[ 'subdomains',     'text',     'Subdomains' ],
	[ 'tile_format',    'choice',   'Tile format' ],
	[ 'zoom.min',       'int',      'Zoom min' ],
	[ 'zoom.max',       'int',      'Zoom max' ],
	[ 'uses',           'uses',     'Uses' ],
	[ 'redistributable','choice',   'Redistributable' ],
	[ 'displacement',   'text',     'Displacement' ],
	[ 'attribution',    'big',      'Attribution' ],
	[ 'terms_url',      'text',     'Terms url' ],
	[ 'license',        'big',      'License' ],
	[ 'policy.max_concurrency','int','Max concurrent' ],
	[ 'policy.min_interval_ms','int','Min interval ms' ],
	[ 'notes',          'big',      'Notes' ],
);

sub sourceFields
	# The fields the editor offers, in the order it offers them.  tile_size
	# and crs are not here: they have exactly one legal value each, so an
	# editable control could only ever be used to make the file invalid.
{
	return @EDIT_FIELDS;
}


sub checkSourceField
	# ('') if the value is fine, or one reason it is not.  SYNTAX ONLY -
	# whether a url ANSWERS, and whether its row order is right, is not a
	# question a text box can settle.  That is the verification phase, and
	# it reports separately.
{
	my ($name,$val) = @_;
	$val = '' if !defined $val;

	# ASCII, ALWAYS.  These files are read by people, transported between
	# them, and their attribution reaches an RCT card as 7-bit bytes for a
	# firmware font renderer.  A character that cannot survive that trip
	# should be refused where it is typed, not silently mangled later.

	return "contains a character that is not plain ASCII"
		if $val =~ /[^\x20-\x7E\r\n\t]/;

	return "required, and may not be empty"
		if $val !~ /\S/ && grep { $_ eq $name }
			qw( id name url attribution uses zoom.min zoom.max );

	return "must be lower case letters, digits, '_' or '-'"
		if $name =~ /^(id|cache_key)$/ && $val =~ /\S/ && $val !~ /^[a-z0-9_-]+$/;
	return "'$SOURCE_INHERITED' is reserved - it is what a region says when ".
			"it has not chosen a source"
		if $name eq 'id' && $val eq $SOURCE_INHERITED;

	if ($name =~ /^(zoom\.min|zoom\.max|policy\.)/)
	{
		return "must be a whole number" if $val =~ /\S/ && $val !~ /^\d+$/;
		return "must be 0 to 24"
			if $name =~ /^zoom\./ && $val =~ /^\d+$/ && $val > 24;
	}

	return "must be jpeg or png"
		if $name eq 'tile_format' && $val =~ /\S/ && $val !~ /^(jpeg|png)$/;
	return "must be yes, no or unknown"
		if $name eq 'redistributable' && $val =~ /\S/ &&
		   $val !~ /^(yes|no|unknown)$/;
	return "must be a short name like 'GCJ-02'"
		if $name eq 'displacement' && $val =~ /\S/ &&
		   $val !~ /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,31}$/;

	if ($name eq 'url' && $val =~ /\S/)
	{
		my @used = _placeholdersOf($val);
		my %ok   = map { $_ => 1 } @PLACEHOLDERS;
		for my $ph (@used)
		{
			return "{$ph} is not a placeholder this format defines"
				if !$ok{$ph};
		}
		my %used = map { $_ => 1 } @used;
		return "must address a tile: {z}, {x} and {y} or {-y}, or else {q}"
			if !($used{q} || ($used{z} && $used{x} &&
				 ($used{y} || $used{'-y'})));
	}

	return '';
}


sub checkSource
	# Would this hash load?  Returns '' or the one reason it would not.
	# Asked WITHOUT reporting, because the editor shows the answer itself
	# and a log line per keystroke would be noise.
{
	my ($leaf,$tsd) = @_;
	my $copy = eval { JSON::PP->new->decode(JSON::PP->new->encode($tsd)) };
	return "could not be encoded as JSON" if $@ || !$copy;

	my $was = $quiet;
	$quiet      = 1;
	$last_error = '';
	my $ok = _validate($leaf,$copy);
	$quiet = $was;
	return $ok ? '' : ($last_error || 'refused, with no reason given');
}


sub getSourceFiles
	# Every .tsd in the folder, loaded or not, in tree order.  The editor
	# lists FILES; a refused one is exactly the one somebody has to open.
{
	_current();
	my $dir = sourcesDir();
	my $dh;
	return () if !opendir($dh,$dir);
	my @leaves = sort grep { /\.tsd$/i && -f "$dir/$_" } readdir($dh);
	closedir $dh;
	return @leaves;
}


sub getRefused
	# leaf => why.  A copy, so nothing outside can edit the reason.
{
	_current();
	return { %refused };
}


sub readSourceFile
	# The raw hash as it is on disk, unvalidated and with no defaults
	# filled in.  The editor shows what the FILE says, which for a refused
	# file is the only thing that could be shown at all.
{
	my ($leaf) = @_;
	my $text = _readFile(sourcesDir()."/$leaf");
	return undef if !defined $text;
	my $tsd = eval { JSON::PP->new->decode($text) };
	return $@ ? undef : $tsd;
}


sub writeSourceFile
	# Write one TSD.  Returns '' or the reason it did not.
	#
	# CANONICAL ORDER AND PRETTY PRINTED, because these files are read by
	# people and a hash's own order is whatever perl felt like.  The cost
	# is that saving a hand-written file reflows it, which is the honest
	# price of the application owning the format.
{
	my ($leaf,$tsd) = @_;

	my @order = qw( tsd_version id cache_key name url subdomains
		tile_format tile_size crs zoom uses redistributable displacement
		attribution terms_url license credentials policy
		absent_fingerprints absent_headers notes );

	# ONE VALUE AT A TIME, which is what keeps the field order canonical -
	# a whole-hash encode would emit perl's order or an alphabetical one,
	# and neither is the order a person reads a TSD in.  allow_nonref is
	# needed because most of the values ARE simple scalars.

	my $json = JSON::PP->new->allow_nonref->canonical->space_before(0);
	my $out = "{\n";
	my @lines;
	for my $key (@order)
	{
		next if !defined $tsd->{$key};

		# ZOOM IS WRITTEN MIN THEN MAX, against the canonical order, because
		# that is the order it is read in and the pair is meaningless
		# reversed.  It is the one place where being alphabetical is worse
		# than being right.

		my $val = $key eq 'zoom' ?
			sprintf('{ "min": %d, "max": %d }',
				$tsd->{zoom}{min} || 0,$tsd->{zoom}{max} || 0) :
			$json->encode($tsd->{$key});

		$val =~ s/\s+$//;
		if (ref($tsd->{$key}) && $key ne 'zoom')
		{
			$val =~ s/\n\s*/ /g;
			$val =~ s/","/", "/g;
			$val =~ s/":/": /g;
			$val =~ s/,"/, "/g;
		}
		push @lines,'  "'.$key.'": '.$val;
	}
	$out .= join(",\n",@lines)."\n}\n";

	my $path = sourcesDir()."/$leaf";
	my $fh;
	return "could not write $path: $!" if !open($fh,'>',$path);
	binmode $fh;
	print $fh $out;
	close $fh;
	display($dbg_source,0,"writeSourceFile($leaf) ".length($out)." bytes");
	return '';
}


sub deleteSourceFile
	# THE FILE AND NOTHING ELSE.  The cache is not touched: it is the
	# expensive thing, it is keyed by cache_key rather than by this file,
	# and another file may address it deliberately.  Deleting a definition
	# is not a statement about tiles.
{
	my ($leaf) = @_;
	my $path = sourcesDir()."/$leaf";
	return "no such file: $leaf" if !-f $path;
	return "could not delete $leaf: $!" if !unlink($path);
	display($dbg_source,0,"deleteSourceFile($leaf)");
	return '';
}


sub loadSources
	# Scan $data_dir/sources for .tsd files.  Called at startup, and again
	# by any thread that finds itself behind the shared generation counter.
{
	%sources = ();
	%refused = ();

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
