#!/usr/bin/perl
#---------------------------------------------
# dm_restore.pm
#---------------------------------------------
# Putting the SHIPPED MATERIAL back: the .tsd files and the example region
# set that live in $resource_dir/user_data.
#
# WHY THIS EXISTS AT ALL.  The installer copies _res/user_data into the
# user's folders under an existence guard, and until now that was the ONLY
# path to it -- so a deleted source cost a reinstall, and a development
# copy could not be seeded with the shipped bundle at all.  The user manual
# tells its reader to open the example set and break it, which is only
# honest if there is a way back.
#
# ONE BUNDLE, ONE ACT.  The sources and the example set are restored
# together because they are one thing the application ships, and somebody
# who deleted "the examples" means both.
#
# IT NEVER REMOVES ANYTHING.  A region the user drew sits in the same
# folder as the shipped one, so restoring writes the shipped leaves and
# touches nothing else.  That is also why this is not "reset the set":
# there is no state to reset, only files to put back.
#
# THE SURVEY IS THE PREFLIGHT, exactly as it is for the cleanup.  Nothing
# here decides anything - it reports what is missing, what is identical and
# what has been changed, and something above it takes the answer.  A
# CHANGED file is the only one that can lose work, so it is the one that
# arrives unticked.
#
# NO WX.  Everything here runs headless, which is what lets the shipped
# bundle be tested without building an installer.

package dm_restore;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_set;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		shippedDir
		surveyShipped
		restoreShipped
	);
}

our $dbg_restore = 0;


sub shippedDir
	# $resource_dir, NOT $app_dir/_res -- Pub::Utils resolves the first to
	# the in-repo folder in development and to the bundled resources when
	# packaged, and only one of those is right in both.
{
	return "$resource_dir/user_data";
}


sub _slurp
{
	my ($path) = @_;
	my $fh;
	return undef if !open($fh,'<',$path);
	binmode $fh;
	local $/ = undef;
	my $data = <$fh>;
	close $fh;
	return $data;
}


# THE SHIPPED TREE MIRRORS THE DEFAULT DATA DIR, one top-level folder per
# tree the application reads:
#
#	_res/user_data/sources/*.tsd
#	_res/user_data/region_sets/<set>/*.region
#
# So the layout IS the mapping, and adding a third shipped tree is a folder
# and one row here rather than another branch.
#
# IT IS STILL A MAPPING AND NOT A RECURSIVE COPY, and that is the whole
# reason this table exists.  Every one of those trees is a PREFERENCE and
# may have been pointed somewhere else entirely, so a blind copy into
# $data_dir would put a shipped source where a user who moved SOURCES_DIR
# would never see it.  What the mirrored layout buys is that in the common
# case - nobody moved anything - the destination is identical to the
# source, which is what lets an installer do the simple thing.

my %SHIPPED_TREES = (
	sources		=> { want => qr/\.tsd$/i,    dir => \&sourcesDir,     kind => 'source' },
	region_sets	=> { want => qr/\.region$/i, dir => \&regionSetsDir,  kind => 'region' },
);


sub _scanTree
	# Every file matching the tree's pattern, at any depth beneath it, as a
	# path relative to shippedDir().
{
	my ($top,$sub) = @_;
	my $spec = $SHIPPED_TREES{$top};
	my $rel  = defined $sub && $sub ne '' ? "$top/$sub" : $top;
	my $path = shippedDir()."/$rel";
	my (@out,$dh);

	return @out if !-d $path || !opendir($dh,$path);
	my @entries = sort grep { !/^\./ } readdir($dh);
	closedir $dh;

	for my $e (@entries)
	{
		if (-d "$path/$e")
		{
			push @out,_scanTree($top,defined $sub && $sub ne '' ? "$sub/$e" : $e);
		}
		elsif ($e =~ $spec->{want})
		{
			push @out,"$rel/$e";
		}
	}
	return @out;
}


sub _scan
{
	return map { _scanTree($_,'') } sort keys %SHIPPED_TREES;
}


sub _destOf
	# WHERE A SHIPPED LEAF LANDS.  The first path element names the tree
	# and the rest is carried through unchanged, so a set folder arrives
	# with its own name intact.
{
	my ($rel) = @_;
	return undef if $rel !~ m|^([^/]+)/(.+)$|;
	my $spec = $SHIPPED_TREES{$1};
	return undef if !$spec;
	return $spec->{dir}->()."/$2";
}


sub _kindOf
{
	my ($rel) = @_;
	return '' if $rel !~ m|^([^/]+)/|;
	my $spec = $SHIPPED_TREES{$1};
	return $spec ? $spec->{kind} : '';
}


sub surveyShipped
	# One row per shipped leaf:
	#
	#	rel     the path within the shipped tree
	#	kind    'source' or 'region'
	#	set     the set name, for a region
	#	src     where it ships from
	#	dst     where it goes
	#	state   'missing' | 'same' | 'changed'
	#	do      what a caller would default to doing about it
	#
	# 'do' is set here rather than by the dialog so that the console and the
	# dialog cannot default differently about a file that can lose work.
{
	my @rows;

	for my $rel (_scan())
	{
		my $dst = _destOf($rel);
		next if !$dst;

		my $src   = shippedDir()."/$rel";
		my $state = 'missing';

		if (-f $dst)
		{
			my $a = _slurp($src);
			my $b = _slurp($dst);
			$state = (defined($a) && defined($b) && $a eq $b) ?
				'same' : 'changed';
		}

		my $kind = _kindOf($rel);
		my $set  = $rel =~ m|^region_sets/([^/]+)/| ? $1 : '';

		push @rows, {
			rel		=> $rel,
			kind	=> $kind,
			set		=> $set,
			src		=> $src,
			dst		=> $dst,
			state	=> $state,

			# MISSING IS TICKED AND CHANGED IS NOT.  Restoring something
			# absent cannot lose anything; overwriting something the user
			# edited can, and that asymmetry is the same one the cleanup
			# makes between deleting a cache and deleting a definition.

			do		=> $state eq 'missing' ? 1 : 0,
		};

		display($dbg_restore+1,1,"shipped $rel is $state");
	}

	display($dbg_restore,0,"surveyShipped() found ".scalar(@rows)." leaves");
	return \@rows;
}


sub restoreShipped
	# Writes every row with do=>1 and returns ($written,$failed,\@errors).
	# Creates the folders it writes into, which is legal here for the
	# reason the application's standing rule allows: these are folders the
	# application chose the location of, not paths somebody typed.
{
	my ($rows) = @_;
	my $written = 0;
	my $failed  = 0;
	my @errors;

	for my $row (@$rows)
	{
		next if !$row->{do};

		my $dst = $row->{dst};
		my $dir = $dst;
		$dir =~ s|/[^/]+$||;
		my_mkdir($dir) if !-d $dir;

		my $data = _slurp($row->{src});
		if (!defined $data)
		{
			$failed++;
			push @errors,"cannot read $row->{rel}";
			next;
		}

		my $fh;
		if (!open($fh,'>',$dst))
		{
			$failed++;
			push @errors,"cannot write $dst - $!";
			next;
		}
		binmode $fh;
		print $fh $data;
		close $fh;

		$written++;
		display($dbg_restore,1,"restored $row->{rel}");
	}

	display($dbg_restore,0,"restoreShipped() wrote $written, failed $failed");
	return ($written,$failed,\@errors);
}


1;
