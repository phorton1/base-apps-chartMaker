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
{
	my ($text,$width) = @_;
	my @out;
	my $line = '';
	for my $word (split(/\s+/,$text))
	{
		if (length($line) + length($word) + 1 > $width)
		{
			push @out,$line;
			$line = $word;
		}
		else
		{
			$line = length($line) ? "$line $word" : $word;
		}
	}
	push @out,$line if length $line;
	return @out;
}


sub _bytes
{
	my ($n) = @_;
	return sprintf("%.1f MB",$n/1048576) if $n >= 1048576;
	return sprintf("%.1f KB",$n/1024)    if $n >= 1024;
	return "$n bytes";
}


1;
