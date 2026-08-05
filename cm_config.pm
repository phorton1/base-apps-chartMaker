#!/usr/bin/perl
#---------------------------------------------
# cm_config.pm
#---------------------------------------------
# THE BUILD CONFIGURATION - what gets fetched and built, and where it goes.
#
#	$data_dir/region_sets/<set>/build.json
#
# IT IS NOT HIDDEN STATE, and that is the point of it existing at all.
# Before this, "what am I working on" lived only in the user's head and was
# re-decided at every invocation.  A configuration makes it durable,
# visible and editable, which is also what lets a Build menu item stop
# being a thing that silently starts a multi-hour process.
#
# IT LIVES IN THE SET FOLDER, and that is safe for a reason worth writing
# down: dm_region scans the folder with /\.region$/i (dm_region.pm:703) and
# derives dirtiness from the .region leaves present, so this file is
# invisible to both.  Editing the configuration therefore CANNOT mark the
# set dirty - which it must not, or changing the output folder would demand
# a save before a build could run, and the build refuses to run dirty.
#
# THERE IS NO FILE UNTIL SOMEBODY CONFIGURES SOMETHING.  Absence means
# defaults, exactly as chartMaker.prefs works: the file is a statement of
# what was CHANGED rather than a snapshot of everything.  A set handed to
# somebody else therefore carries no build.json at all unless its author
# deliberately made choices - and if it does, they can accept it or clear
# it with one button.
#
# ONE CONFIGURATION, NOT NAMED ONES.  Named configurations are how this
# kind of thing usually grows and they buy nothing here: a few checkboxes
# and a path, remembered.  If several are ever wanted, the file grows a
# list and this module grows a name; nothing above it needs to know yet.
#
# WHAT IS DELIBERATELY NOT IN IT: zmax, and anything else that changes what
# a build writes beyond WHICH regions.  Two people with the same
# region set must be able to get the same output - see w_prefs, which draws
# the same line for the same reason.

package cm_config;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON;
use Pub::Utils;
use cm_defs;
use dm_set;
use dm_region;
	# For getRegionIds() alone, so that configSelectedIds can answer
	# "which of the regions that EXIST does this select".  Not a cycle --
	# dm_region knows nothing about the build configuration, and must not:
	# a configuration is about a run, and a region is the user's work.


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		buildConfig
		saveBuildConfig
		defaultOutDir
		defaultMbtilesOutDir
		configSelectedIds
		configIsDefault
		effectiveInterval
	);
}


our $dbg_config:shared = 1;
	# 1 = quiet
	# 0 = load and save
	# -1 = the resolved contents


my $CONFIG_LEAF = 'build.json';


sub _path
{
	my ($set) = @_;
	$set = getActiveSet() if !defined $set;
	return undef if !$set;
	return setDir($set)."/$CONFIG_LEAF";
}


sub defaultOutDir
	# ONE OUTPUT FOLDER PER SET, and it is the folder you copy to the card.
	# \RASTER\ on the CF card is the CONSUMER's contract - one outer folder
	# holding exactly one region set - so the producer side wants one
	# folder per set for the copy to be a copy rather than a decision.
	#
	# It is now a SUGGESTION rather than a rule.  This is what the
	# configuration starts at and what Reset returns to.
{
	my ($set) = @_;
	$set = getActiveSet() if !defined $set;
	return '' if !$set;
	return rasterDir()."/$set";
}


sub defaultMbtilesOutDir
	# The same idea for the other output, and it is NOT CONFIGURABLE.
	#
	# The stored out_dir is the .rct OUTPUT folder - it is where the files
	# gets assembled, chosen once per set because that folder is copied
	# wholesale to a CF card.  A tree of region folders landing in the
	# middle of it would make that copy a decision instead of a copy.  So
	# mbtiles has one place it goes, and there is nothing to remember.
{
	my ($set) = @_;
	$set = getActiveSet() if !defined $set;
	return '' if !$set;
	return mbtilesDir()."/$set";
}


sub _default
{
	my ($set) = @_;
	return {
		regions		=> undef,		# undef = ALL, see configSelectedIds
		out_dir		=> '',			# '' = the default, resolved on read
		rates		=> {},			# source id => advisory min ms, 0 = none
	};
}


sub buildConfig
	# The configuration for one set, or the defaults if there is no file.
	# NEVER returns undef with a set open, and never writes anything.
{
	my ($set) = @_;
	$set = getActiveSet() if !defined $set;
	my $cfg = _default($set);
	my $path = _path($set);
	return $cfg if !$path || !-f $path;

	my $fh;
	if (!open($fh,'<',$path))
	{
		error("buildConfig could not read $path: $!");
		return $cfg;
	}
	binmode $fh;
	local $/;
	my $text = <$fh>;
	close $fh;

	my $got = eval { decode_json($text) };

	# A CORRUPT CONFIGURATION IS NOT AN ERROR THE USER MUST FIX.  It holds
	# preferences about a run, not their work, so the recoverable thing to
	# do is say so and carry on with defaults - refusing to open a set
	# because a convenience file is malformed would be absurd.

	if (!$got || ref($got) ne 'HASH')
	{
		warning(0,0,"$path is not readable as a build configuration - ".
			"using defaults");
		return $cfg;
	}

	$cfg->{regions} = (ref($got->{regions}) eq 'ARRAY') ?
		[ grep { defined && /\S/ } @{$got->{regions}} ] : undef;

	$cfg->{out_dir} = (defined($got->{out_dir}) && !ref($got->{out_dir})) ?
		$got->{out_dir} : '';

	$cfg->{rates} = (ref($got->{rates}) eq 'HASH') ? { %{$got->{rates}} } : {};
	$cfg->{rates}{$_} = int($cfg->{rates}{$_} || 0) for keys %{$cfg->{rates}};

	display($dbg_config,0,"buildConfig($set) read $path");
	return $cfg;
}


sub saveBuildConfig
	# Write it, and ONLY if it differs from what is already there.
	#
	# Called from the OK of the first preflight dialog rather than from the
	# Start of the second, so that the analysis dialog is a pure read of a
	# durable thing rather than a view onto state being shuttled between
	# two windows.  Backing out of the analysis therefore KEEPS the
	# selection, which is right: you still meant to select those regions,
	# you just did not like what it was going to cost.
	#
	# Returns 1 if it wrote, 0 if there was nothing to do, undef on error.
{
	my ($cfg,$set) = @_;
	$set = getActiveSet() if !defined $set;
	my $path = _path($set);
	return undef if !$path;

	# A CONFIGURATION THAT SAYS NOTHING LEAVES NO FILE.  If everything is
	# back at its default the file is removed rather than written full of
	# defaults, so Reset really does return the set to the state it would
	# have been handed over in.

	if (configIsDefault($cfg))
	{
		return 0 if !-f $path;
		unlink($path);
		display($dbg_config,0,"saveBuildConfig($set) removed $path - all default");
		return 1;
	}

	my $out = {
		config_version	=> 1,
		defined $cfg->{regions} ? ( regions => $cfg->{regions} ) : (),
		$cfg->{out_dir} ? ( out_dir => $cfg->{out_dir} ) : (),
		(%{$cfg->{rates} || {}}) ? ( rates => $cfg->{rates} ) : (),
	};

	my $text = JSON->new->pretty->canonical->encode($out);

	if (-f $path)
	{
		my $fh;
		if (open($fh,'<',$path))
		{
			binmode $fh;
			local $/;
			my $was = <$fh>;
			close $fh;
			return 0 if defined($was) && $was eq $text;
		}
	}

	my $fh;
	if (!open($fh,'>',$path))
	{
		error("saveBuildConfig could not write $path: $!");
		return undef;
	}
	binmode $fh;
	print $fh $text;
	close $fh;

	display($dbg_config,0,"saveBuildConfig($set) wrote $path");
	return 1;
}


sub effectiveInterval
	# The floor between two requests to one source, in ms.
	#
	# THE ADVISORY CAN ONLY EVER MAKE YOU SLOWER.  max(), never min() and
	# never a replacement: a source's declared min_interval_ms is a fact
	# about somebody else's server and stays authoritative, while the
	# advisory is a fact about how the user would like to behave tonight -
	# they may have all night and prefer slow and sure to fast and likely
	# to fail.  This one operator is the whole of what keeps a user
	# settable rate from becoming a way to violate a source's policy.
	#
	# It lives HERE rather than with the analysis because it is a question
	# about the configuration, and because the fill needs it too - putting
	# it in dm_analysis would make the fetch loop depend on the estimator.
{
	my ($src,$cfg) = @_;
	return 0 if !$src;
	my $declared = ($src->{policy} && $src->{policy}{min_interval_ms}) ?
		$src->{policy}{min_interval_ms} : 0;
	my $advisory = ($cfg && $cfg->{rates}) ?
		($cfg->{rates}{$src->{id}} || 0) : 0;
	return $declared > $advisory ? $declared : $advisory;
}


sub configIsDefault
{
	my ($cfg) = @_;
	return 1 if !$cfg;
	return 0 if defined $cfg->{regions};
	return 0 if $cfg->{out_dir};
	return 0 if grep { $cfg->{rates}{$_} } keys %{$cfg->{rates} || {}};
	return 1;
}


sub configSelectedIds
	# The ids this configuration selects, in the set's own order, with
	# anything that no longer exists dropped.
	#
	# UNDEF MEANS ALL, and it is not the same as a list that happens to
	# name every region.  A set with no configuration builds whole, and a
	# region added later joins it; once somebody has ticked a subset, a
	# region added later is NOT silently swept into their next build.  That
	# is the difference between a default and a choice, and it has to
	# survive in the file or the two become indistinguishable.
{
	my ($cfg,@available) = @_;
	@available = getRegionIds() if !@available;

	return @available if !$cfg || !defined $cfg->{regions};

	my %want = map { lc($_) => 1 } @{$cfg->{regions}};
	return grep { $want{lc($_)} } @available;
}


1;
