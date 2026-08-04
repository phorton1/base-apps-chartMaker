#!/usr/bin/perl
#---------------------------------------------
# w_blank.pm
#---------------------------------------------
# LOOK AT THE TILE AND SAY WHETHER IT IS A BLANK.
#
# THE PICTURE IS THE WHOLE POINT.  A candidate is a byte count, an md5 and
# a number of sightings, and none of that can settle the one question that
# matters: is this a server saying 'nothing here', or is it snow, or deep
# water, or a cloud?  A person answers that in half a second by looking,
# and by no statistic at all - which is why nothing in this application
# accepts a fingerprint on its own.
#
# THE TILE IS NOT KEPT ANYWHERE.  A candidate carries z/x/y, and the tile
# is already in the cache, so this reads it from there.  If the cache has
# been pruned, or the service has since served something real at that
# coordinate, ONE tile is refetched - and the md5 is checked either way,
# because a picture that is not the candidate would be the worst possible
# thing to show at this moment.
#
# IT DECIDES NOTHING AND WRITES NOTHING.  It returns accepted or not, and
# the caller does the one thing it is entitled to do: the editor puts the
# pair in its visible row, and a report with no editor open writes the file
# directly.  A dialog that wrote for both would have to know which case it
# was in, which is exactly the knowledge it should not have.

package w_blank;
use strict;
use warnings;
use Digest::MD5 qw( md5_hex );
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON );
use Pub::Utils;
use cm_defs;
use cm_state;
use dm_source;
use dm_cache;
use dm_observe;
use dm_fetch;
use dm_verify;
use base qw(Wx::Dialog);


our $dbg_blank:shared = 0;
	# 0 = one line per fingerprint declared


my $ID_YES = 8831;
my $ID_NO  = 8832;

my $GREY = Wx::Colour->new(120,120,120);
my $RED  = Wx::Colour->new(200,0,0);


sub _bytesFor
	# The candidate's own tile, from the cache or from one refetch.
	# Returns (\$data,$where) or (undef,$why).
{
	my ($source,$c) = @_;

	my $got = cacheGet($source,$c->{z},$c->{x},$c->{y});
	if ($got && ($got->{status} // '') eq 'ok' && $got->{bytes})
	{
		return ($got->{bytes},'from the cache')
			if md5_hex(${$got->{bytes}}) eq $c->{md5};
	}

	# NOT THERE, OR NOT IT ANY MORE.  Either is ordinary: the cache is
	# prunable, and a service may well have started serving real imagery at
	# that coordinate since.  One request settles it.

	my $busy = Wx::BusyCursor->new();
	my $now  = eval { fetchTile($source,$c->{z},$c->{x},$c->{y}) };
	undef $busy;

	return (undef,'the tile could not be fetched') if !$now;
	return (undef,"the service answered: ".($now->{reason} // 'nothing'))
		if ($now->{status} // '') ne 'ok' || !$now->{bytes};

	return ($now->{bytes},'refetched just now')
		if md5_hex(${$now->{bytes}}) eq $c->{md5};

	return (undef,'the service now serves something different there, so '.
		'this candidate cannot be shown');
}


sub _bitmapOf
	# Tile bytes to a bitmap.  Returns ($bmp,$why) and $why is the reason
	# there is no bitmap - never swallowed, because a dialog whose whole
	# job is to show a picture must say why it could not.
	#
	# THROUGH A FILE, BECAUSE THIS wxPerl HAS NO MEMORY STREAM.  Wx 0.9927
	# publishes no Wx::MemoryInputStream, so Wx::Image cannot be built from
	# bytes in hand and the only loader it offers takes a path.
	#
	# IT IS A SCRATCH FILE AND NOT AN EXEMPLAR.  One fixed name, overwritten
	# by whoever looks next, and unlinked the moment the pixels are decoded -
	# the bitmap holds them from then on.  That is a different thing from
	# the per-candidate copies this design removed: nothing accumulates,
	# nothing needs reaping, and losing it costs nothing at all.
	#
	# THE HANDLERS ARE LOADED ON DEMAND.  This is the only place in the
	# application that renders a fetched image, and a dialog nobody opens
	# should not cost every run its image handlers.
{
	my ($dataref,$fmt) = @_;
	return (undef,'there are no bytes to show') if !$dataref;

	Wx::InitAllImageHandlers();

	my $path = "$temp_dir/blank_preview.".($fmt || 'jpeg');
	if (!open(my $fh,'>',$path))
	{
		return (undef,"could not write $path to decode it: $!");
	}
	else
	{
		binmode $fh;
		print $fh $$dataref;
		close $fh;
	}

	my $img = Wx::Image->new($path,wxBITMAP_TYPE_ANY);
	my $ok  = ($img && $img->Ok()) ? 1 : 0;
	my $bmp = $ok ? Wx::Bitmap->new($img) : undef;

	unlink $path;

	return ($bmp,'') if $bmp;
	return (undef,'the bytes are not an image this build of wx can decode');
}


sub show
	# ($parent,$source,$candidate) -> 1 if the user accepted it.
{
	my ($class,$parent,$source,$c) = @_;

	my $this = $class->SUPER::new($parent,-1,
		'Is this a blank?',[-1,-1],[520,470]);

	my ($dataref,$where) = _bytesFor($source,$c);
	my $bmp;
	my $why = $where;
	($bmp,$why) = _bitmapOf($dataref,$source->{tile_format}) if $dataref;

	# THE TILE AT ITS OWN SIZE, because a tile IS 256 pixels and scaling it
	# would invent detail or destroy it, and the question being asked is
	# precisely about what detail is there.

	if ($bmp)
	{
		Wx::StaticBitmap->new($this,-1,$bmp,[16,16],[256,256]);
	}
	else
	{
		# THE REASON, AND THE REAL ONE.  'Cannot be shown' with no cause is
		# the least useful sentence a dialog can print, and the cause is the
		# only thing that tells somebody whether to try again or to give up.

		my $txt = Wx::StaticText->new($this,-1,
			"The tile cannot be shown.\n\n".($why // ''),
			[16,16],[256,256]);
		$txt->SetForegroundColour($RED);
	}

	my $head = Wx::StaticText->new($this,-1,
		"Seen $c->{count} times",[288,16],[210,20]);
	my $font = $head->GetFont();
	$font->SetWeight(wxFONTWEIGHT_BOLD);
	$head->SetFont($font);

	my $det = Wx::StaticText->new($this,-1,
		"$c->{bytes} bytes\n".
		"md5 $c->{md5}\n\n".
		"first seen at\nz$c->{z}/$c->{x}/$c->{y}\n\n".
		($bmp ? ($where // '') : ''),
		[288,44],[210,180]);
	$det->SetForegroundColour($GREY);

	# THE QUESTION IN WORDS, because the two buttons are only unambiguous
	# to somebody who already knows what is being asked.

	my $ask = Wx::StaticText->new($this,-1,
		"If this is the service's way of saying it has no tile here, ".
		"declaring it stops this application from treating it as imagery. ".
		"If it is real - snow, cloud, deep water - say no: declaring it ".
		"would make genuine tiles disappear.",
		[16,288],[482,72]);

	my $yes = Wx::Button->new($this,$ID_YES,
		'Yes, it is a blank',[240,376],[150,28]);
	my $no  = Wx::Button->new($this,$ID_NO,'No',[400,376],[96,28]);

	$yes->Enable($bmp ? 1 : 0);
	$yes->SetToolTip('Add this to absent_fingerprints. Nothing is written '.
		'until you save.');

	EVT_BUTTON($this,$ID_YES,sub { $_[0]->EndModal(wxID_OK) });
	EVT_BUTTON($this,$ID_NO, sub { $_[0]->EndModal(wxID_CANCEL) });

	$no->SetFocus();
	my $rslt = $this->ShowModal();
	$this->Destroy();

	return ($rslt == wxID_OK) ? 1 : 0;
}


#---------------------------------------------
# the landing points
#---------------------------------------------
# WHERE AN OFFER IS MADE, and it is never in the middle of anything.  A
# build is thousands of tiles over hours and a probe is hundreds; a modal
# question arriving in the middle of either is the thing this application
# refuses everywhere else.  So the offer waits for the END of an act, when
# the person is standing in front of a report and the work is over.
#
# ONE DRIVER FOR EVERY CALLER, because the difference between them is only
# WHO IS HOLDING THE FILE.  With an editor open the pair goes into its
# visible row and Save writes it; with no editor open there is nothing to
# race and it is written here.  A dialog that decided which case it was in
# would need to know things it should not.
#
# A DECLINE IS REMEMBERED.  Without that, every build of a source with real
# imagery that happens to repeat would ask the same question again forever.

sub offerFor
	# ($parent,\@sources) -> how many fingerprints were written.
	# Every source is asked about; most have nothing.
{
	my ($class,$parent,$sources) = @_;
	my $wrote = 0;

	for my $src (@{$sources || []})
	{
		next if !$src || !$src->{file};

		for my $c (verifyNewCandidates($src))
		{
			if (!$class->show($parent,$src,$c))
			{
				obsDeclineFingerprint($src,$c->{md5});
				next;
			}
			$wrote++ if _writeInto($src,$c);
		}
	}

	if ($wrote)
	{
		rescanSources();
		bumpState('a fingerprint was declared');
	}
	obsFlushAll();
	return $wrote;
}


sub _writeInto
	# THE FILE ON DISK, READ AND REWRITTEN, never the loaded source hash.
	# The loaded hash carries fields the loader added and the file does not
	# have, and writing it back would put them there.
{
	my ($src,$c) = @_;

	my $leaf = $src->{file} or return 0;
	my $tsd  = readSourceFile($leaf);
	if (!$tsd)
	{
		error("could not read $leaf to declare a fingerprint");
		return 0;
	}

	my $fps = $tsd->{absent_fingerprints} ||= [];
	for my $fp (@$fps)
	{
		return 0 if lc($fp->{md5} // '') eq $c->{md5};
	}
	push @$fps,{ bytes => $c->{bytes} + 0, md5 => $c->{md5} };

	my $why = writeSourceFile($leaf,$tsd);
	if ($why)
	{
		error("could not write $leaf: $why");
		return 0;
	}

	display($dbg_blank,0,"declared $c->{bytes}:$c->{md5} in $leaf");
	return 1;
}


1;
