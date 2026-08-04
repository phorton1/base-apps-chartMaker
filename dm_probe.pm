#!/usr/bin/perl
#---------------------------------------------
# dm_probe.pm
#---------------------------------------------
# ASK THE SERVICE WHAT IT IS, rather than finding out one tile at a time.
#
# MOSTLY A METADATA PROBLEM, NOT A FETCHING ONE, which is the whole reason
# this is cheap.  An ArcGIS MapServer answers ?f=json with its levels of
# detail, its scale limits, its tile format and its spatial reference; a
# WMTS answers GetCapabilities with the layer, the tile matrix set that
# names its ceiling, its formats and its access constraints.  Between them
# that covers most services worth probing, at ONE REQUEST AND NO IMAGERY.
#
# What it settles, without fetching a single tile:
#
#	is the url template right
#	is the row order flipped
#	is a credential needed
#	what format is really served
#	how deep does the service admit to going
#	what does the service call itself, and who owns the imagery
#
# WHAT IT CANNOT SETTLE IS WHETHER THERE IS IMAGERY HERE.  Sparse coverage
# means an honest ceiling of z12 does not imply a tile at every z12 square,
# and no metadata document anywhere answers that.  That is the sampler's
# question and it is a PLACED one; this probe is placeless on purpose.  The
# one exception is probeTilemap below, which is placed, is a different act,
# and is called by something else.
#
# NOTHING HERE EVER EDITS A TSD.  The findings are shown to a person beside
# what their file currently says, and disagreements are listed as
# disagreements.  A human decides which of the two is wrong.  That is what
# keeps "declared, not detected" true while still making detection worth
# doing -- a probe that quietly rewrote the file would make every TSD a
# cache of a server's current mood.

package dm_probe;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON;
use Pub::Utils;
use cm_defs;
use cm_utils;
use dm_source;
use dm_fetch;
use dm_observe;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		probeSource
		probeTilemap
		probeLines
		serviceLayers
	);
}


our $dbg_probe:shared = 0;
	# 0  = one line per probe
	# -1 = the metadata url and what came back


my $PROBE_TIMEOUT = 45;
	# LONGER THAN A TILE'S.  A capabilities document is not a tile: NASA
	# GIBS answers with 5.3 MB describing every layer it publishes, and
	# twenty seconds is not always enough to receive it.  Measured, not
	# guessed.


#---------------------------------------------
# which family is this
#---------------------------------------------

sub _family
	# From the url template alone, because that is all a TSD has.  There is
	# no 'service_type' field and there should not be one: it would be a
	# second place to state something the url already says, free to
	# disagree with it.
{
	my ($url) = @_;
	return ('arcgis',$1) if $url =~ m{^(.*?/MapServer)/tile/}i;
	return ('wmts',$1,$2) if $url =~ m{^(https?://[^/]+/wmts/[^/]+/[^/]+)/([^/]+)/}i;
	return ('unknown');
}


#---------------------------------------------
# ArcGIS
#---------------------------------------------

sub _probeArcGIS
{
	my ($source,$base,$out) = @_;

	my $url = "$base?f=json";
	$out->{meta_url} = $url;

	my $got = fetchUrl($url,$PROBE_TIMEOUT);
	$out->{ms} = $got->{ms};
	if (!$got->{ok})
	{
		$out->{reason} = "the MapServer did not answer - $got->{reason}";
		return;
	}
	$out->{bytes} = length($got->{content});

	my $j = eval { decode_json($got->{content}) };
	if (!$j || ref($j) ne 'HASH')
	{
		$out->{reason} = "the MapServer answered, but not with JSON";
		return;
	}

	# A SERVICE THAT REPORTS ITS OWN ERROR WITH HTTP 200.  ArcGIS does this
	# for a token problem, which is exactly the case a probe is run to find.

	if ($j->{error})
	{
		$out->{reason} = "the service refused: ".
			($j->{error}{message} || 'no message').
			(($j->{error}{code} || 0) == 499 ? ' - a token is required' : '');
		$out->{needs_credential} = 1 if ($j->{error}{code} || 0) == 499;
		return;
	}

	$out->{ok} = 1;

	# THE SERVICE PATH, NOT mapName.  Esri leaves mapName at its authoring
	# default - World_Imagery reports "Layers", as does documentInfo.Title -
	# so the only reliably identifying name is the one in the url, which is
	# also the one a person would recognise.

	my $named = $base =~ m{/services/(.+)/MapServer$}i ? $1 : $base;
	push @{$out->{facts}},['service',$named];
	push @{$out->{facts}},['map name',$j->{mapName}]
		if $j->{mapName} && lc($j->{mapName}) ne 'layers';
	push @{$out->{facts}},['copyright',$j->{copyrightText}]
		if $j->{copyrightText};

	my $ti = $j->{tileInfo};
	if (!$ti || ref($ti->{lods}) ne 'ARRAY' || !@{$ti->{lods}})
	{
		# NO TILE CACHE AT ALL.  A dynamic MapServer renders on demand and
		# has no /tile/ endpoint, so a TSD pointed at one is wrong in a way
		# no amount of retrying fixes.

		push @{$out->{facts}},['tiles','this service publishes NO tile cache'];
		push @{$out->{disagree}},
			"the url uses /tile/, but this MapServer has no tile cache";
		return;
	}

	push @{$out->{facts}},['tile size',"$ti->{cols} x $ti->{rows}"];
	$out->{tile_size} = $ti->{cols};

	my $fmt = lc($ti->{format} || '');
	$out->{format} = $fmt =~ /jpe?g/ ? 'jpeg' : $fmt =~ /png/ ? 'png' : $fmt;
	push @{$out->{facts}},['format',$ti->{format} || '-'];

	my $wkid = $ti->{spatialReference}{latestWkid} ||
			   $ti->{spatialReference}{wkid} || 0;
	$out->{wkid} = $wkid;
	push @{$out->{facts}},['spatial ref',"wkid $wkid".
		($wkid == 3857 ? ' (web mercator)' : ' - NOT web mercator')];

	my @lods  = sort { $a->{level} <=> $b->{level} } @{$ti->{lods}};
	my $top   = $lods[-1]{level};
	my $floor = $lods[0]{level};
	$out->{zmin} = $floor;
	push @{$out->{facts}},['levels',"$floor to $top (".scalar(@lods)." lods)"];

	# THE maxScale RULE, and it is the one thing that makes an ArcGIS
	# answer usable rather than merely present.
	#
	# maxScale is meant to say "do not draw me past this scale", so it
	# would be the real ceiling if anybody set it.  Two values mean it was
	# never set: zero, which is the literal 'unset' sentinel, and a value
	# that resolves to the deepest level the cache holds, which says only
	# "as deep as I go" and is therefore no constraint at all.  Any OTHER
	# value is a genuine statement and is the answer.

	my $max_scale = $j->{maxScale} || 0;
	my $declared;
	if ($max_scale)
	{
		# The level whose scale is nearest the one named.
		my $best;
		for my $lod (@lods)
		{
			$best = $lod if !$best ||
				abs($lod->{scale} - $max_scale) < abs($best->{scale} - $max_scale);
		}
		$declared = $best->{level} if $best && $best->{level} != $top;
	}

	if (defined $declared)
	{
		$out->{zmax} = $declared;
		push @{$out->{facts}},['maxScale',
			"$max_scale - a real limit, at level $declared"];
	}
	else
	{
		$out->{zmax} = $top;
		push @{$out->{facts}},['maxScale',
			($max_scale ? "$max_scale, which is the deepest level anyway"
						: '0 (unset)').' - declares nothing'];
	}

	# THE CEILING IS A PROTOCOL LIMIT AND NOTHING MORE.  A service that
	# upsamples rather than refusing will answer at every level up to it
	# with something, and no part of this document distinguishes real
	# imagery from magnified imagery.  Saying so here is the difference
	# between a useful probe and a misleading one.

	push @{$out->{facts}},['depth',
		'where REAL detail ends varies by place and is not in this document'];

	my $caps = $j->{capabilities} || '';
	$out->{has_tilemap} = ($caps =~ /\bTilemap\b/i) ? 1 : 0;
	push @{$out->{facts}},['tilemap',$out->{has_tilemap} ?
		'offered - a whole block of coverage can be had in one request' :
		'not offered'];

	push @{$out->{facts}},['export tiles',
		$j->{exportTilesAllowed} ? 'allowed by the service' :
		'NOT allowed by the service']
		if exists $j->{exportTilesAllowed};

	# ESRI'S REST TILE CONVENTION IS ROW BEFORE COLUMN.  It is a property
	# of the family rather than of this service, and it is the single most
	# common way a hand written TSD is wrong: the tiles arrive, they are
	# real imagery, and they are in the wrong places.

	$out->{row_order} = 'row-before-column';
}


#---------------------------------------------
# WMTS
#---------------------------------------------

sub _probeWMTS
{
	my ($source,$base,$layer,$out) = @_;

	my $url = "$base/1.0.0/WMTSCapabilities.xml";
	$out->{meta_url} = $url;
	$out->{layer}    = $layer;

	my $got = fetchUrl($url,$PROBE_TIMEOUT);
	$out->{ms} = $got->{ms};
	if (!$got->{ok})
	{
		$out->{reason} = "GetCapabilities did not answer - $got->{reason}";
		return;
	}
	my $xml = $got->{content};
	$out->{bytes} = length($xml);

	# ONE LAYER OUT OF A DOCUMENT THAT DESCRIBES HUNDREDS.  GIBS publishes
	# 5.3 MB here, so everything below works on the ONE <Layer> block whose
	# identifier matches, found by scanning rather than by parsing the
	# whole document into a tree.  A real XML parse of five megabytes to
	# read four fields would be the wrong trade, and this format is
	# regular enough that it does not earn one.

	my $block;
	while ($xml =~ m{<Layer>(.*?)</Layer>}gs)
	{
		my $b = $1;
		next if index($b,"<ows:Identifier>$layer</ows:Identifier>") < 0;
		$block = $b;
		last;
	}

	if (!$block)
	{
		$out->{reason} = "this service publishes no layer called '$layer'";
		push @{$out->{disagree}},
			"the url names layer '$layer', which GetCapabilities does not list";
		return;
	}

	$out->{ok} = 1;

	push @{$out->{facts}},['layer',$layer];
	push @{$out->{facts}},['title',$1]
		if $block =~ m{<ows:Title[^>]*>(.*?)</ows:Title>}s;

	# ACCESS CONSTRAINTS ARE SERVICE LEVEL, so they come from outside the
	# layer block.  'none' is a real answer and worth showing: it is the
	# service saying so, which is a stronger statement than a TSD author
	# believing so.

	push @{$out->{facts}},['access',$1]
		if $xml =~ m{<ows:AccessConstraints>(.*?)</ows:AccessConstraints>}s;
	push @{$out->{facts}},['fees',$1]
		if $xml =~ m{<ows:Fees>(.*?)</ows:Fees>}s;

	my @formats = $block =~ m{<Format>(.*?)</Format>}gs;
	if (@formats)
	{
		push @{$out->{facts}},['formats',join(', ',@formats)];
		$out->{format} = $formats[0] =~ /jpe?g/i ? 'jpeg' :
						 $formats[0] =~ /png/i  ? 'png'  : $formats[0];
	}

	# THE TILE MATRIX SET NAMES THE CEILING, and for the GoogleMapsCompatible
	# family it names it IN THE IDENTIFIER.  That is a real declared limit
	# rather than a scale hint: the service refuses above it, which is the
	# case the TSD format calls declarable.

	if ($block =~ m{<TileMatrixSet>(.*?)</TileMatrixSet>}s)
	{
		my $tms = $1;
		$out->{tms} = $tms;
		push @{$out->{facts}},['tile matrix set',$tms];

		if ($tms =~ /Level(\d+)\s*$/)
		{
			$out->{zmax} = $1 + 0;
			push @{$out->{facts}},['ceiling',
				"z$out->{zmax}, named by the matrix set - the service ".
				"REFUSES above it"];
		}
		else
		{
			# COUNTED RATHER THAN NAMED.  A matrix set that does not carry
			# its depth in its name still lists one <TileMatrix> per level,
			# so the ceiling is the highest identifier in it.

			if ($xml =~ m{<TileMatrixSet>\s*(?:<[^>]+>\s*)*?<ows:Identifier>\Q$tms\E</ows:Identifier>(.*?)</TileMatrixSet>}s)
			{
				my $set = $1;
				my @lv = sort { $a <=> $b }
					grep { /^\d+$/ }
					($set =~ m{<ows:Identifier>(\d+)</ows:Identifier>}gs);
				if (@lv)
				{
					$out->{zmax} = $lv[-1];
					$out->{zmin} = $lv[0];
					push @{$out->{facts}},['ceiling',
						"z$out->{zmax}, counted from the matrix set's levels"];
				}
			}
		}
	}

	# THE RESOURCE URL IS THE TEMPLATE THE SERVICE ITSELF PUBLISHES, which
	# makes the row order question answerable from metadata rather than by
	# fetching a tile and looking at it.

	if ($block =~ m{<ResourceURL[^>]*template='([^']*\{TileMatrix\}[^']*)'}s)
	{
		my $tpl = $1;
		$out->{template} = $tpl;
		$out->{row_order} =
			$tpl =~ m{\{TileRow\}.*\{TileCol\}}s ? 'row-before-column' :
			$tpl =~ m{\{TileCol\}.*\{TileRow\}}s ? 'column-before-row'  : undef;
		push @{$out->{facts}},['row order',
			($out->{row_order} || 'not stated').
			($out->{row_order} && $out->{row_order} eq 'row-before-column' ?
				' - {z}/{y}/{x}' : '')];
	}

	# A DIMENSION WITH A DEFAULT IS A TRAP WORTH NAMING.  GIBS layers carry
	# a Time dimension whose default the service picks; a url that hardcodes
	# one date is asking for imagery that may not be the current default,
	# and neither the fetch nor the build would ever say so.

	if ($block =~ m{<Dimension>(.*?)</Dimension>}s)
	{
		my $dim = $1;
		my $id  = $dim =~ m{<ows:Identifier>(.*?)</ows:Identifier>}s ? $1 : '?';
		my $def = $dim =~ m{<Default>(.*?)</Default>}s ? $1 : '?';
		push @{$out->{facts}},[lc($id).' dimension',
			"default '$def' - the url must pin one, and this file's is below"];
		$out->{dimension_default} = $def;
	}
}


#---------------------------------------------
# the probe
#---------------------------------------------

sub probeSource
	# ONE request, no imagery.  Returns findings; never writes a TSD.
{
	my ($source) = @_;
	return { ok => 0, reason => 'no source' } if !$source;

	my $out = {
		id       => $source->{id},
		name     => $source->{name},
		ok       => 0,
		facts    => [],
		disagree => [],
	};

	my ($family,$base,$layer) = _family($source->{url} || '');
	$out->{family} = $family;

	if ($family eq 'arcgis')
	{
		_probeArcGIS($source,$base,$out);
	}
	elsif ($family eq 'wmts')
	{
		_probeWMTS($source,$base,$layer,$out);
	}
	else
	{
		# NOT A FAILURE.  Most tile services publish no machine readable
		# description at all, and saying "this one does not" is a true and
		# useful answer rather than an error.

		$out->{reason} = 'this url is not an ArcGIS MapServer or a WMTS, '.
			'and no metadata endpoint can be derived from it';
		return $out;
	}

	_compare($source,$out) if $out->{ok};
	_remember($source,$out) if $out->{ok};

	display($dbg_probe,0,"probeSource($source->{id}) $family -> ".
		($out->{ok} ? "ok, ".scalar(@{$out->{disagree}})." disagreement(s)"
					: "failed: $out->{reason}"));
	return $out;
}


sub _compare
	# WHAT THE SERVICE SAYS, BESIDE WHAT THE FILE SAYS.  This is the part
	# that is worth running: a fact on its own is trivia, and a fact that
	# contradicts the file in front of you is a thing to go and fix.
	#
	# EVERY ITEM IS PHRASED AS A DISAGREEMENT, NEVER AS A CORRECTION, and
	# nothing is applied.  Several of these have a legitimate answer of
	# "the file is right and the service is being modest" - a zoom.max
	# BELOW the ceiling is a deliberate choice, not an error - so the list
	# is for a person to read.
{
	my ($source,$out) = @_;

	if (defined($out->{zmax}) && defined($source->{zoom}{max}))
	{
		my ($said,$file) = ($out->{zmax},$source->{zoom}{max});
		push @{$out->{disagree}},
			"the service answers to z$said, and this file declares zoom.max ".
			"z$file - fetches above z$said will be refused"
			if $file > $said;
		push @{$out->{disagree}},
			"this file declares zoom.max z$file, below the z$said the ".
			"service offers - deliberate, or out of date?"
			if $file < $said;
	}

	push @{$out->{disagree}},
		"the service serves $out->{format}, and this file expects ".
		"$source->{tile_format} - the format is detected per tile, so this ".
		"is a documentation problem rather than a fetching one"
		if $out->{format} && $source->{tile_format} &&
		   $out->{format} ne $source->{tile_format};

	push @{$out->{disagree}},
		"the service publishes $out->{tile_size} pixel tiles, and this ".
		"application requires 256"
		if $out->{tile_size} && $out->{tile_size} != 256;

	push @{$out->{disagree}},
		"the service is in wkid $out->{wkid}, not 3857 - these tiles are ".
		"not on the grid this application builds on"
		if $out->{wkid} && $out->{wkid} != 3857;

	# ROW ORDER, WHICH IS THE FAILURE THAT LOOKS LIKE SUCCESS.  Every tile
	# arrives, every tile is real imagery, and the map is scrambled.  The
	# url is the only place the file states its choice.

	if ($out->{row_order})
	{
		my $url = $source->{url} || '';
		my $file_order =
			$url =~ m{\{z\}.*\{y\}.*\{x\}}s   ? 'row-before-column' :
			$url =~ m{\{z\}.*\{x\}.*\{y\}}s   ? 'column-before-row' :
			$url =~ m{\{z\}.*\{x\}.*\{-y\}}s  ? 'column-before-row' : undef;

		push @{$out->{disagree}},
			"the service addresses tiles $out->{row_order}, and this file's ".
			"url is $file_order - every tile would arrive, and the map would ".
			"be scrambled"
			if $file_order && $file_order ne $out->{row_order};
	}

	# A PINNED DIMENSION THAT IS NOT THE SERVICE'S DEFAULT.  The url has to
	# name one value, and naming a stale one is invisible everywhere else:
	# the tiles arrive, they are real, and they are of the wrong year.

	if ($out->{dimension_default})
	{
		my $def = $out->{dimension_default};
		push @{$out->{disagree}},
			"the service's current default is '$def', and this file's url ".
			"does not pin that - check which date it is actually asking for"
			if ($source->{url} || '') !~ /\Q$def\E/;
	}
}


sub _remember
	# INTO THE OBSERVATION RECORD, NOT INTO THE TSD.  These are discovered
	# facts about a server, which is precisely what that tier is for, and
	# keeping them means the source list can show what was learned without
	# probing again every time it repaints.
{
	my ($source,$out) = @_;
	obsNote($source,{
		meta_family    => $out->{family},
		meta_probed_at => int(time()),
		defined($out->{zmax})   ? ( meta_zmax   => $out->{zmax} )   : (),
		defined($out->{format}) ? ( meta_format => $out->{format} ) : (),
	});
	obsEwma($source,'rtt_ms',$out->{ms}) if $out->{ms};
	obsFlushAll();
}


#---------------------------------------------
# the placed one
#---------------------------------------------

sub probeTilemap
	# WHICH TILES ACTUALLY EXIST, FOR A WHOLE BLOCK, IN ONE REQUEST.
	#
	# THIS IS PLACED AND THE REST OF THIS MODULE IS NOT, which is why it is
	# a separate entry point rather than part of probeSource.  It is also
	# the cheapest coverage answer anywhere in this application: sixty four
	# tiles answered by one request and no imagery, where the sampler would
	# otherwise fetch sixty four times.
	#
	# ONLY THE ArcGIS FAMILY OFFERS IT, and only when its capabilities say
	# so, which probeSource records.  Returns { ok, present => [0|1,...],
	# rows, cols } with the block in row major order.
{
	my ($source,$z,$x,$y,$rows,$cols) = @_;
	$rows ||= 8;
	$cols ||= 8;

	my ($family,$base) = _family($source->{url} || '');
	return { ok => 0, reason => 'tilemap is an ArcGIS endpoint' }
		if $family ne 'arcgis';

	# NOTE THE ORDER: level, ROW, COLUMN - the same row-before-column
	# convention the tile endpoint uses, and the same trap.

	my $url = "$base/tilemap/$z/$y/$x/$rows/$cols";
	my $got = fetchUrl($url,$PROBE_TIMEOUT);
	return { ok => 0, reason => $got->{reason}, ms => $got->{ms} }
		if !$got->{ok};

	my $j = eval { decode_json($got->{content}) };
	return { ok => 0, reason => 'tilemap did not answer with JSON',
		ms => $got->{ms} }
		if !$j || ref($j) ne 'HASH';

	# A FULLY PRESENT BLOCK IS ANSWERED AS A BARE 'valid' WITH NO DATA
	# ARRAY, which is a compression rather than an error and reads as an
	# empty block if it is not handled.

	my $data = $j->{data};
	if (ref($data) ne 'ARRAY')
	{
		return { ok => 0, reason => 'tilemap returned no coverage array',
			ms => $got->{ms} }
			if !$j->{valid};
		$data = [ (1) x ($rows * $cols) ];
	}

	my $present = 0;
	$present += ($_ ? 1 : 0) for @$data;

	display($dbg_probe,0,"probeTilemap($source->{id},$z,$x,$y,$rows,$cols) ".
		"$present of ".scalar(@$data)." present");

	return { ok => 1, ms => $got->{ms}, rows => $rows, cols => $cols,
		present => [ map { $_ ? 1 : 0 } @$data ],
		count_present => $present, count_total => scalar(@$data) };
}


#---------------------------------------------
# rendering
#---------------------------------------------

sub probeLines
	# The findings as text, rendered ONCE for the console and the pane
	# alike, which is the same discipline the build report and the analysis
	# already follow.
{
	my ($out) = @_;
	my @lines;

	push @lines,"$out->{name}  ($out->{id})";
	push @lines,'';

	if (!$out->{ok})
	{
		push @lines,"family:  ".($out->{family} || 'unknown');
		push @lines,"probe:   $out->{reason}";
		push @lines,'';
		push @lines,'Nothing was changed. A probe only ever reports.';
		return \@lines;
	}

	push @lines,sprintf("%-16s %s",'family',$out->{family});
	push @lines,sprintf("%-16s %s",'metadata',$out->{meta_url});
	push @lines,sprintf("%-16s %d ms, %s",'answered',
		$out->{ms} || 0,_bytes($out->{bytes} || 0));
	push @lines,'';

	push @lines,sprintf("%-16s %s",$_->[0],$_->[1]) for @{$out->{facts}};

	push @lines,'';
	if (@{$out->{disagree}})
	{
		push @lines,"WHAT THE SERVICE SAYS AND THIS FILE DOES NOT:";
		push @lines,'';
		for my $d (@{$out->{disagree}})
		{
			# THE BULLET MARKS THE ITEM, NOT EVERY LINE OF IT.  Repeating
			# it on continuation lines turns one three-line finding into
			# what reads as three separate findings.

			my @wrapped = _wrap($d,66);
			push @lines,"  - ".shift(@wrapped);
			push @lines,"    $_" for @wrapped;
		}
		push @lines,'';
		push @lines,"Nothing was changed. Edit the .tsd yourself if you agree,";
		push @lines,"then press Rescan.";
	}
	else
	{
		push @lines,"This file agrees with everything the service says.";
	}

	return \@lines;
}


sub _wrap
	# MOVED TO cm_utils, because the catalog panel needed the same thing
	# and a second copy would be a second set of answers to "what happens
	# to a url that is longer than the column".  Kept as a name here so the
	# call site above still reads the way it did.
{
	my ($text,$width) = @_;
	return wrapText($text,$width);
}


sub _bytes
{
	my ($n) = @_;
	return sprintf("%.1f MB",$n/1048576) if $n >= 1048576;
	return sprintf("%.1f KB",$n/1024)    if $n >= 1024;
	return "$n bytes";
}




#---------------------------------------------
# WHAT DOES THIS SERVICE PUBLISH
#---------------------------------------------
# THE SAME DOCUMENTS, THE OTHER QUESTION.  Everything above finds the ONE
# layer a TSD names and reports on it.  This lists them ALL, so the
# catalog can offer what a service actually publishes today rather than
# the two or three that were surveyed.
#
# IT LIVES HERE AND NOT IN dm_catalog, which reads a shipped file and
# knows no protocols, and not in a module of its own, which would be a
# second set of rules for reading one XML document -- free to disagree
# with the set above about what a ceiling is or where a row order is
# declared.
#
# THE SERVICE'S OWN TEMPLATE IS THE POINT.  A WMTS publishes a ResourceURL
# per layer, so the url this produces is not a guess about how the service
# is addressed: it is what the service says. That is the whole difference
# between an entry somebody typed and an entry that came from the horse.
#
# ONLY WHAT chartMaker CAN READ IS RETURNED.  A service like GIBS
# publishes around a thousand layers, most of them science products and
# many of them on a grid this application structurally cannot address.
# Handing all of them to somebody to judge would waste the judgement the
# catalog exists to support -- so the rest are counted, and the count is
# reported WITH ITS REASON.  Silently dropping them would be the same lie
# as a truncated list.

my @GOOD_FORMATS = ( 'image/jpeg', 'image/jpg', 'image/png' );


sub _formatOf
{
	my ($mime) = @_;
	return 'jpeg' if $mime =~ m{jpe?g}i;
	return 'png'  if $mime =~ m{png}i;
	return '';
}


sub _tagIn
	# One simple element's text out of a block.  There is no general XML
	# here on purpose: see the note above _probeWMTS about five megabytes
	# and four fields.
{
	my ($block,$tag) = @_;
	return $block =~ m{<\Q$tag\E[^>]*>(.*?)</\Q$tag\E>}s ? $1 : undef;
}


sub _kvpGetTile
	# The KVP GetTile endpoint a capabilities document advertises.  A
	# RESTful service (GIBS) publishes a ResourceURL per layer and needs
	# none of this; a KVP-only service (IGN France, Spain IGN) publishes
	# no ResourceURL at all and has to be addressed through its operations
	# metadata instead.  Two shapes, both real, and a reader that knew
	# only the first would report the second as having nothing to offer.
{
	my ($xml) = @_;
	return undef if $xml !~ m{<ows:Operation\s+name=["']GetTile["'](.*?)</ows:Operation>}s;
	my $op = $1;
	return undef if $op !~ m{<ows:Get\s+xlink:href=["']([^"']+)["'](.*?)</ows:Get>}s;
	my ($href,$rest) = ($1,$2);
	return undef if $rest !~ m{<ows:Value>KVP</ows:Value>}s;
	$href =~ s/\?$//;
	return $href;
}


sub _restUrl
	# A layer's ResourceURL template, turned into a TSD url.
{
	my ($tpl,$tms,$time,$style) = @_;

	$tpl =~ s/\{TileMatrixSet\}/$tms/g;
	$tpl =~ s/\{Time\}/$time/g               if defined $time;
	$tpl =~ s/\{style\}/$style/gi            if defined $style;
	$tpl =~ s/\{TileMatrix\}/\{z\}/g;
	$tpl =~ s/\{TileRow\}/\{y\}/g;
	$tpl =~ s/\{TileCol\}/\{x\}/g;

	# ANY PLACEHOLDER LEFT IS ONE THIS READER DID NOT UNDERSTAND, and a url
	# carrying it would be refused by the TSD validator anyway.  Better to
	# hide the layer with a reason than to offer a template that cannot be
	# saved.

	return undef if $tpl =~ /\{(?!z\}|x\}|y\})/;
	return $tpl;
}


sub _kvpUrl
{
	my ($base,$layer,$tms,$mime,$style,$time) = @_;
	my $sep = ($base =~ /\?/) ? '&' : '?';
	my $url = $base.$sep.
		"SERVICE=WMTS&REQUEST=GetTile&VERSION=1.0.0".
		"&LAYER=$layer".
		"&STYLE=".(defined $style ? $style : '').
		"&TILEMATRIXSET=$tms".
		"&FORMAT=$mime";
	$url .= "&TIME=$time" if defined $time && $time =~ /\S/;
	$url .= "&TILEMATRIX={z}&TILEROW={y}&TILECOL={x}";
	return $url;
}


my $UNDECLARED_ZMAX = 23;
	# WHERE A SERVICE STATES NO CEILING.  The TSD format's zoom is a
	# PROTOCOL limit - where the server starts refusing - and 23 is what
	# the ArcGIS family declares when it is declaring nothing.  Where real
	# detail ends is a data fact and is the probe's question either way.


sub _ceilingOf
	# The zoom range a named tile matrix set covers, and whether the
	# service actually said so.  Returns (zmin,zmax,declared).
	#
	# THE IDENTIFIER SAYS IT OUTRIGHT for the GoogleMapsCompatible_LevelN
	# family.  Otherwise the set is DEFINED somewhere in the document with
	# one TileMatrix per level, and the range is counted from it.
	#
	# FINDING THAT DEFINITION IS THE WHOLE DIFFICULTY, because
	# <TileMatrixSet> is two elements with one name: inside a
	# TileMatrixSetLink it is a bare reference holding a name, and at the
	# top level it is the definition.  Scanning every block and keeping the
	# one that both names this set AND contains TileMatrix children tells
	# them apart by shape, which is the only thing that reliably does.
	#
	# An earlier version required the ows:Identifier to be the first
	# element with content, which held for GIBS and broke on Esri Wayback -
	# whose definition opens with a Title and an Abstract.  It then cached
	# the failure, so one unmatched document voided all 195 of its layers.
{
	my ($xml,$tms,$cache) = @_;
	return @{$cache->{$tms}} if $cache->{$tms};

	my @range = (0,$UNDECLARED_ZMAX,0);
	if ($tms =~ /Level(\d+)\s*$/)
	{
		@range = (0,$1 + 0,1);
	}
	else
	{
		while ($xml =~ m{<TileMatrixSet>(.*?)</TileMatrixSet>}gs)
		{
			my $set = $1;
			next if index($set,"<ows:Identifier>$tms</ows:Identifier>") < 0;
			next if index($set,'<TileMatrix>') < 0;

			my @lv = sort { $a <=> $b } grep { /^\d+$/ }
				($set =~ m{<ows:Identifier>(\d+)</ows:Identifier>}gs);
			@range = ($lv[0],$lv[-1],1) if @lv;
			last;
		}
	}
	$cache->{$tms} = \@range;
	return @range;
}


sub serviceLayers
	# ($kind,$url,$prog) -> a hash of what the service publishes.
	#
	#	ok      1, or 0 with a reason
	#	layers  [ { id, name, url, zmin, zmax, tile_format, tms, notes } ]
	#	hidden  { reason => count }
	#
	# $prog is optional and is the shared progress record; this is the one
	# thing here that knows it is being watched, and it only ever writes
	# counters and reads {cancelled}.
{
	my ($kind,$url,$prog) = @_;

	return { ok => 0, reason => "this reader does not know '$kind'" }
		if ($kind || '') ne 'wmts';

	if ($prog)
	{
		$prog->{phase}     = 'Asking the service what it publishes';
		$prog->{sub_label} = $url;
		$prog->{sub_total} = 0;
	}

	my $got = fetchUrl($url,$PROBE_TIMEOUT);
	return { ok => 0, reason => "GetCapabilities did not answer - $got->{reason}" }
		if !$got->{ok};

	# CANCEL MEANS ABANDON THE ANSWER, NOT STOP THE DOWNLOAD.  Nothing can
	# interrupt an LWP get once it is in flight, so the honest thing is to
	# check here, say nothing was kept, and not pretend the request was
	# called off.

	return { ok => 0, reason => 'cancelled' } if progressCancelled($prog);

	my $xml = $got->{content};
	my $kvp = _kvpGetTile($xml);

	my @blocks = ($xml =~ m{<Layer>(.*?)</Layer>}gs);
	display($dbg_probe,0,"serviceLayers($kind) ".scalar(@blocks).
		" layers in "._bytes(length $xml));

	if ($prog)
	{
		$prog->{phase}     = 'Reading the layers';
		$prog->{sub_total} = scalar(@blocks);
		$prog->{sub_done}  = 0;
		$prog->{done}      = 1;
	}

	my (@layers,%hidden,%tms_cache);
	for my $block (@blocks)
	{
		$prog->{sub_done}++ if $prog;
		return { ok => 0, reason => 'cancelled' } if progressCancelled($prog);

		my $id = _tagIn($block,'ows:Identifier');
		next if !defined $id || $id !~ /\S/;

		# WEB MERCATOR AT 256 PIXELS OR NOTHING, and for a WMTS that is a
		# statement about the tile matrix set rather than about the layer.
		# The GoogleMapsCompatible family IS that grid, by definition, and
		# a layer offering no such set cannot be addressed by this
		# application whatever else is true of it.

		my @sets = ($block =~ m{<TileMatrixSet>(.*?)</TileMatrixSet>}gs);
		my ($tms) = grep { /GoogleMapsCompatible/i } @sets;
		if (!$tms)
		{
			$hidden{'published on a grid this application cannot read'}++;
			next;
		}

		my @formats = ($block =~ m{<Format>(.*?)</Format>}gs);
		my ($mime)  = grep { my $f = lc $_;
							 grep { $f eq $_ } @GOOD_FORMATS } @formats;
		if (!$mime)
		{
			$hidden{'serves no jpeg or png'}++;
			next;
		}

		my $style = _tagIn($block,'ows:Identifier');
		if ($block =~ m{<Style[^>]*>(.*?)</Style>}s)
		{
			my $s = _tagIn($1,'ows:Identifier');
			$style = $s if defined $s;
		}

		my $time;
		if ($block =~ m{<Dimension>(.*?)</Dimension>}s)
		{
			$time = _tagIn($1,'Default');
		}

		my $tile_url;
		if ($block =~ m{<ResourceURL[^>]*template=["']([^"']*\{TileMatrix\}[^"']*)["']}s)
		{
			$tile_url = _restUrl($1,$tms,$time,$style);
		}
		elsif ($kvp)
		{
			$tile_url = _kvpUrl($kvp,$id,$tms,$mime,$style,$time);
		}

		if (!$tile_url)
		{
			$hidden{'publishes no template this reader can address'}++;
			next;
		}

		# AN UNDECLARED CEILING IS NOT A REASON TO HIDE A LAYER.  A service
		# that says nothing about its depth is the ORDINARY case - most of
		# the ArcGIS family says nothing - and hiding those would drop
		# exactly the sources whose depth has to be found by looking.  So a
		# default stands in, and the layer says that is what it is.

		my ($zmin,$zmax,$declared) = _ceilingOf($xml,$tms,\%tms_cache);

		my $title = _tagIn($block,'ows:Title');
		$title = $id if !defined $title || $title !~ /\S/;

		# ASCII, BECAUSE A TSD MUST BE.  A title carrying anything else
		# would be refused where it was saved rather than where it was
		# read, which is a long way from the cause.

		$title =~ s/[^\x20-\x7E]/ /g;
		$title =~ s/\s+/ /g;
		$title =~ s/^\s+|\s+$//g;

		my $notes = "Read from the service's own GetCapabilities. ".
			"Tile matrix set $tms.";
		$notes .= " THE SERVICE DECLARED NO ZOOM RANGE for that matrix set, ".
			"so the ceiling of z$zmax above is a default and not a ".
			"statement - probe it before trusting it."
			if !$declared;
		$notes .= " The url pins the '$time' value of this layer's time ".
			"dimension, which is the default the service published when ".
			"this was read." if defined $time && $time =~ /\S/;

		push @layers,{
			id          => $id,
			name        => $title,
			url         => $tile_url,
			zmin        => $zmin,
			zmax        => $zmax,
			tile_format => _formatOf($mime),
			tms         => $tms,
			notes       => $notes,
		};
	}

	display($dbg_probe,0,"serviceLayers kept ".scalar(@layers)." of ".
		scalar(@blocks));

	# DEEPEST FIRST, AND THAT IS GUIDANCE RATHER THAN A VERDICT.
	#
	# The structural filter above is necessary and it is nothing like
	# sufficient: GIBS publishes 1268 layers and 1132 of them are readable,
	# because nearly every science product it holds is served as PNG on
	# GoogleMapsCompatible.  Aerosol angstrom exponent is addressable by
	# this application and is of no use whatever under a boat.
	#
	# NOTHING HERE DECIDES THAT.  A usefulness filter would be this module
	# forming an opinion it is not entitled to, and the same reasoning that
	# keeps depth a human judgement everywhere else applies with more force
	# to a list somebody is reading in order to judge.  So the deepest are
	# put first, where a chart author looks, and the filter box does the
	# rest.  A z6 climate product sorts to the bottom without being hidden.

	# WHERE DEPTH TIES, THE SERVICE'S OWN ORDER STANDS.  Sorting those by
	# name imposes an order nobody chose, and it is wrong in the case that
	# made it visible: Esri Wayback publishes 195 releases at one depth,
	# newest first, and alphabetical put February 2014 at the top of a list
	# whose whole purpose is picking a date.

	my $i = 0;
	$_->{_ord} = $i++ for @layers;
	@layers = sort { $b->{zmax} <=> $a->{zmax} || $a->{_ord} <=> $b->{_ord} }
		@layers;
	delete $_->{_ord} for @layers;

	return {
		ok       => 1,
		layers   => \@layers,
		hidden   => \%hidden,
		total    => scalar(@blocks),
		bytes    => length($xml),
	};
}


sub layersWorker
	# THE WORKER SIDE, and the whole of what crosses the thread boundary.
	#
	# THE RESULT COMES BACK AS TEXT, for the reason the build's report
	# does: a nest of hashes and arrays cannot cross as a reference, and
	# shared_clone'ing it would make a second representation free to drift
	# from the first.  So it is encoded once here and decoded once there,
	# and there is exactly one shape of layer list in the application.
{
	my ($prog,$args) = @_;
	my ($kind,$url) = @$args;

	my $rslt = eval { serviceLayers($kind,$url,$prog) };
	$rslt = { ok => 0, reason => "the reader failed: $@" } if !$rslt;

	$prog->{json} = eval { encode_json($rslt) } || '';
	$prog->{ok}   = $rslt->{ok} ? 1 : 0;
	push @{$prog->{lines}},($rslt->{reason} // '') if !$rslt->{ok};
	$prog->{finished} = 1;
}

1;
