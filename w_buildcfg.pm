#!/usr/bin/perl
#---------------------------------------------
# w_buildcfg.pm
#---------------------------------------------
# PREFLIGHT ONE - what, and where.
#
# The first of the two dialogs that stand between a menu item and a
# possibly multi-hour process.  It edits the build configuration for the
# open set: which regions, and for a build, which folder.
#
# IT WRITES ON OK, not on Start and not per click.  The second dialog is
# an ANALYSIS OF the configuration, so if this had not persisted yet that
# one would be analysing something that exists nowhere and Back would have
# to shuttle unsaved state between two windows.  Persisting here makes the
# analysis a pure read of a durable thing - which is also what the
# progress dialog and the report then refer to.
#
# The consequence is deliberate: CANCELLING THE ANALYSIS KEEPS THE
# SELECTION.  You ticked all five, saw it was four hours and backed out -
# you still meant to select all five, and next time it is still ticked.
# Persisting only on Start would throw the exploration away and make you
# re-tick to ask the same question again.
#
# RESET EDITS THE FIELDS; OK COMMITS THEM.  So Reset followed by Cancel
# changes nothing on disk, and Reset is not a destructive button with no
# undo.
#
# THE DEFAULT FOLDER IS CREATED AS NEEDED; A CHOSEN ONE MUST ALREADY
# EXIST.  That asymmetry is the application's standing rule - it creates
# only the folders it chose the location of - and the browser's own
# "Make New Folder" is what creates a new one, as a user action.  The
# application still never does.

package w_buildcfg;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON );
use Cwd;
use Pub::Utils;
use cm_defs;
use cm_config;
use dm_set;
use dm_region;
use w_resources;
use w_ini;
use base qw(Wx::Dialog);


my $ID_ALL		= 8821;
my $ID_NONE		= 8822;
my $ID_BROWSE	= 8823;
my $ID_DEFAULT	= 8824;
my $ID_RESET	= 8825;
my $ID_OK		= 8826;
my $ID_CANCEL	= 8827;


sub new
{
	my ($class,$parent,$what) = @_;
	$what ||= 'build';

	# THE FOLDER SECTION IS THE CARD'S, not every build's.  An mbtiles
	# build has one destination and nothing to choose, so this dialog is
	# 'what' for it exactly as it is for a fetch - see
	# cm_config::defaultMbtilesOutDir.  It is still a BUILD, which is what
	# the labels below say.

	my $is_build = ($what eq 'build');
	my $writes   = ($what ne 'fetch');

	my $title =
		$what eq 'build'	? 'Build - what and where'	:
		$what eq 'mbtiles'	? 'Build MBTiles - what'	: 'Fetch - what';
	my $h = $is_build ? 470 : 380;

	my $this = $class->SUPER::new($parent,-1,$title,[-1,-1],[520,$h]);

	$this->{what}		= $what;
	$this->{is_build}	= $is_build;
	$this->{cfg}		= buildConfig();
	$this->{ids}		= [ getRegionIds() ];

	my $set = getActiveSet() // '';

	Wx::StaticText->new($this,-1,
		"Region set '$set' - ".scalar(@{$this->{ids}})." region(s)",
		[16,12],[480,18]);

	Wx::StaticText->new($this,-1,
		$writes ? 'Build these regions:' : 'Fetch tiles for these regions:',
		[16,38],[300,18]);

	# A CHECK LIST, NOT THE REGION TREE.  What is on the card and what is
	# on the map are different questions and have to look different - the
	# tree's own checkboxes mean show-on-map and always have.

	$this->{list} = Wx::CheckListBox->new($this,-1,[16,60],[480,180],
		$this->{ids});

	Wx::Button->new($this,$ID_ALL, 'All', [16,248],[70,24]);
	Wx::Button->new($this,$ID_NONE,'None',[94,248],[70,24]);

	my $y = 288;
	if ($is_build)
	{
		Wx::StaticText->new($this,-1,'Output folder:',[16,$y],[100,18]);

		# READ ONLY rather than disabled: a disabled control reads as
		# "not available", and this one is very much available - it is
		# simply not typed into, because a typo is exactly the failure
		# the browse-only rule exists to prevent.

		$this->{dir_ctrl} = Wx::TextCtrl->new($this,-1,'',
			[16,$y+20],[480,22],wxTE_READONLY);

		$this->{dir_note} = Wx::StaticText->new($this,-1,'',
			[16,$y+48],[480,18]);

		Wx::Button->new($this,$ID_BROWSE, 'Browse...',[16,$y+70],[90,24]);
		Wx::Button->new($this,$ID_DEFAULT,'Default',  [114,$y+70],[90,24]);
		$y += 100;
	}

	Wx::Button->new($this,$ID_RESET, 'Reset All',[16,$y+8], [90,24]);
	Wx::Button->new($this,$ID_OK,    'Next >',   [316,$y+8],[85,24]);
	Wx::Button->new($this,$ID_CANCEL,'Cancel',   [409,$y+8],[85,24]);

	EVT_BUTTON($this,$ID_ALL,	 \&onAll);
	EVT_BUTTON($this,$ID_NONE,	 \&onNone);
	EVT_BUTTON($this,$ID_BROWSE, \&onBrowse);
	EVT_BUTTON($this,$ID_DEFAULT,\&onDefault);
	EVT_BUTTON($this,$ID_RESET,	 \&onReset);
	EVT_BUTTON($this,$ID_OK,	 \&onOk);
	EVT_BUTTON($this,$ID_CANCEL, sub { $_[0]->EndModal(wxID_CANCEL) });

	$this->_show($this->{cfg});
	return $this;
}


sub _show
	# Push a configuration into the controls.  Used by the constructor and
	# by Reset, which is why Reset needs no separate code path.
{
	my ($this,$cfg) = @_;

	my %on = map { lc($_) => 1 } configSelectedIds($cfg,@{$this->{ids}});
	my $i = 0;
	for my $id (@{$this->{ids}})
	{
		$this->{list}->Check($i,$on{lc($id)} ? 1 : 0);
		$i++;
	}

	$this->_showDir($cfg->{out_dir}) if $this->{is_build};
}


sub _showDir
{
	my ($this,$dir) = @_;
	$this->{out_dir} = $dir // '';

	my $shown = $this->{out_dir} || defaultOutDir();
	$this->{dir_ctrl}->SetValue($shown);

	# THE STATE OF THAT PATH IS SAID OUT LOUD, because the two folders
	# behave differently and the difference is invisible otherwise: the
	# default will be made if it is missing, a chosen one will not.

	my ($note,$colour);
	if (!$this->{out_dir})
	{
		$note = '(the default - it will be created if it does not exist)';
		$colour = Wx::Colour->new(90,90,90);
	}
	elsif (-d $this->{out_dir})
	{
		$note = '(a folder you chose)';
		$colour = Wx::Colour->new(90,90,90);
	}
	else
	{
		$note = 'THIS FOLDER DOES NOT EXIST - create it in Browse, or use Default';
		$colour = Wx::Colour->new(200,0,0);
	}
	$this->{dir_note}->SetLabel($note);
	$this->{dir_note}->SetForegroundColour($colour);
	$this->{dir_note}->Refresh();
}


sub onAll
{
	my ($this) = @_;
	$this->{list}->Check($_,1) for (0..$#{$this->{ids}});
}


sub onNone
{
	my ($this) = @_;
	$this->{list}->Check($_,0) for (0..$#{$this->{ids}});
}


sub _nativeDir
	# A path the Windows shell can actually resolve: a drive letter, and
	# backslashes.  Anything already absolute is left alone.
{
	my ($path) = @_;
	return '' if !defined($path) || $path !~ /\S/;

	if ($path =~ m{^[/\\]} && $path !~ m{^[A-Za-z]:})
	{
		# Whatever drive the application itself is running from, which is
		# the same one Windows would have resolved the path against.
		my $cwd = Cwd::getcwd();
		my ($drive) = $cwd =~ m{^([A-Za-z]:)};
		$path = ($drive || 'C:').$path;
	}
	$path =~ s{/}{\\}g;
	return $path;
}


sub onBrowse
	# WITHOUT wxDD_DIR_MUST_EXIST, so that Windows' own "Make New Folder"
	# button is offered.  That is the pretty solution to the asymmetry: the
	# DIALOG creates a folder as a user action, and chartMaker still never
	# creates one it did not choose the location of.
{
	my ($this) = @_;
	# A NATIVE ABSOLUTE PATH, OR THE BROWSER OPENS AT "This PC".
	#
	# $data_dir is '/base_data/data/chartMaker' - no drive letter, because
	# Pub::Utils builds it that way and Windows resolves it against the
	# current drive for file operations.  Wx::DirDialog does not: it hands
	# the string to the shell's folder picker, which cannot resolve a
	# drive-less path and silently falls back to the top of the namespace.
	# So the default folder was offered as "navigate down from This PC",
	# which is the one thing a default is supposed to prevent.

	my $start = $this->{out_dir} || defaultOutDir();
	$start = getLastBrowseDir() || rasterDir() if !-d $start;
	$start = rasterDir() if !-d $start;
	$start = _nativeDir($start);

	my $dlg = Wx::DirDialog->new($this,
		'Choose a folder for the .rct card files',$start);
	my $rslt = $dlg->ShowModal();
	my $path = $dlg->GetPath();
	$dlg->Destroy();
	return if $rslt != wxID_OK || !$path;

	$path =~ s{\\}{/}g;

	# REMEMBER WHERE THEY WERE, EVEN WHEN THE PICK IS BAD.
	#
	# Windows' folder picker has a trap: create a folder, type a name,
	# press Return - and Return both commits the rename AND fires the
	# default button, so the dialog closes returning the name the folder
	# had BEFORE the rename ("New Folder").  That path does not exist,
	# which is reported correctly and is no help at all, because reopening
	# the browser used to start from scratch and the whole descent had to
	# be walked again.
	#
	# So the parent is remembered whether the pick was good or not, and
	# the retry starts one click away.

	my $parent = $path;
	$parent =~ s{/[^/]+$}{};
	setLastBrowseDir(-d $path ? $path : $parent);

	# CHOOSING THE DEFAULT IS NOT A CHOICE.  If they browse to exactly the
	# folder the default resolves to, store nothing - otherwise renaming
	# the set later would leave the configuration pinned to the old name's
	# folder, which is the least expected thing it could do.

	$this->_showDir($path eq defaultOutDir() ? '' : $path);
}


sub onDefault
{
	my ($this) = @_;
	$this->_showDir('');
}


sub onReset
{
	my ($this) = @_;

	my $dlg = Wx::MessageDialog->new($this,
		"Clear the build configuration for this set back to its defaults?\n\n".
		"Every region selected, and the default output folder.",
		$$resources{app_title},wxYES_NO | wxICON_QUESTION);
	my $answer = $dlg->ShowModal();
	$dlg->Destroy();
	return if $answer != wxID_YES;

	# The FIELDS only.  Nothing is written until OK, so Reset then Cancel
	# leaves the file exactly as it was.

	$this->_show({ regions => undef, out_dir => '', rates => {} });
}


sub onOk
{
	my ($this) = @_;

	my @on;
	my $i = 0;
	for my $id (@{$this->{ids}})
	{
		push @on,$id if $this->{list}->IsChecked($i);
		$i++;
	}

	if (!@on)
	{
		Wx::MessageBox("Nothing is selected - there is nothing to ".
			$this->{what}.".",$$resources{app_title},
			wxOK | wxICON_INFORMATION,$this);
		return;
	}

	# ALL TICKED IS RECORDED AS 'ALL', not as a list that happens to name
	# everything.  They are different statements: a set with no selection
	# builds whole and a region added later joins it, while a deliberate
	# subset must NOT silently acquire a region added next week.  Storing
	# the list either way would collapse the two.

	my $cfg = $this->{cfg};
	$cfg->{regions} = (scalar(@on) == scalar(@{$this->{ids}})) ? undef : \@on;
	$cfg->{out_dir} = $this->{is_build} ? ($this->{out_dir} // '') : $cfg->{out_dir};

	saveBuildConfig($cfg);

	$this->{result} = { cfg => $cfg, ids => \@on };
	$this->EndModal(wxID_OK);
}


sub result
	# { cfg, ids } after an OK, undef after a Cancel.
{
	my ($this) = @_;
	return $this->{result};
}


1;
