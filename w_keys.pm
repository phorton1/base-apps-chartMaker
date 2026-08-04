#!/usr/bin/perl
#---------------------------------------------
# w_keys.pm
#---------------------------------------------
# THE KEY STORE, SEEN AND EDITED.  Two dialogs, and the difference between
# them is the difference between answering a question and looking at a list.
#
# ASK  is the prompt: one key_name, asked at the moment something needs it,
#      with the place to get one as a link.  It is raised from the surfaces
#      where a PERSON is authoring - the catalog, a test - and never from
#      the mechanical ones.  A build runs on a worker thread under a modal
#      progress dialog, and a prompt there would block that thread and
#      ambush somebody who walked away from a two hour run.
#
# SHOW is the standing list: what is bound, what is not, what references
#      each name, and what references nothing.  It is the only place an
#      ORPHAN becomes visible, and an orphan is the only way a mistyped
#      key_name is ever noticed - it sits there bound to a value while the
#      source that meant to use it will not fetch.
#
# NEITHER DIALOG SHOWS A VALUE IT DID NOT JUST RECEIVE.  The list says SET
# or NOT SET and the length; it does not print the key.  Somebody looking
# over a shoulder at a chart is not somebody who should be reading a key,
# and a value that is genuinely wanted back is in the file, in plain text,
# by design.

package w_keys;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw( EVT_BUTTON EVT_LIST_ITEM_SELECTED );
use Pub::Utils;
use cm_defs;
use cm_prefs;
use dm_keys;
use dm_source;
use base qw(Wx::Dialog);


our $dbg_keys_ui:shared = 0;
	# 0 = a value set or cleared from the ui


my $ID_OK      = 8851;
my $ID_CANCEL  = 8852;
my $ID_EDIT    = 8853;
my $ID_DELETE  = 8854;
my $ID_CLOSE   = 8855;
my $ID_NEW     = 8856;
my $ID_LIST    = 8857;

my $GREY = Wx::Colour->new(120,120,120);
my $RED  = Wx::Colour->new(200,0,0);


#---------------------------------------------
# what references what
#---------------------------------------------

sub _referencesOf
	# key_name => [ source ids that declare it ].  ASKED OF THE INSTALLED
	# SOURCES rather than remembered, because a source can be deleted with
	# a file manager and a remembered list would keep vouching for it.
{
	my %refs;
	for my $id (getSourceIds())
	{
		my $src = getSource($id);
		next if !$src || !$src->{keys};
		for my $key (@{$src->{keys}})
		{
			push @{$refs{$key->{key_name} // ''}},$id;
		}
	}
	return \%refs;
}


#---------------------------------------------
# ASK - one key, at the moment it is needed
#---------------------------------------------

sub editKey
	# NEW AND EDIT ARE ONE DIALOG, because they are one act on an lval-rval
	# pair: name on the left, value on the right.  Edit arrives with the
	# name filled in and locked, since changing a name is not editing a
	# binding - it is deleting one and making another, and the url that
	# referred to the old name would silently stop resolving.
	#
	# THIS IS NOT THE PROMPT.  The prompt exists to answer one service's
	# question at the moment it is asked and says so in those words; this is
	# a store being maintained, and dressing it in "this service needs a
	# key" was simply wrong.  Nothing here mentions a service, because at
	# this window nothing has asked.
{
	my ($class,$parent,$name) = @_;

	my $editing = (defined($name) && $name =~ /\S/) ? 1 : 0;
	my $old     = $editing ? (getKeyValue($name) // '') : '';

	my $this = $class->SUPER::new($parent,-1,
		$editing ? "Edit key" : 'New key',[-1,-1],[460,250]);

	Wx::StaticText->new($this,-1,
		"A key_name is what a url contains, in braces. A url reading\n".
		"...?api={my_key} needs a key_name of my_key.",
		[16,16],[420,40]);

	Wx::StaticText->new($this,-1,'key_name',[16,68],[80,20]);
	my $nctl = Wx::TextCtrl->new($this,-1,$editing ? $name : '',
		[100,64],[336,24],$editing ? wxTE_READONLY : 0);

	Wx::StaticText->new($this,-1,'value',[16,104],[80,20]);
	my $vctl = Wx::TextCtrl->new($this,-1,$old,[100,100],[336,24]);

	my $hint = Wx::StaticText->new($this,-1,
		$editing ? 'the name cannot be changed - delete it and make another'
				 : '',
		[100,130],[336,20]);
	$hint->SetForegroundColour($GREY);

	Wx::Button->new($this,$ID_OK,$editing ? 'Save' : 'Add',[228,176],[96,28]);
	Wx::Button->new($this,$ID_CANCEL,'Cancel',[336,176],[96,28]);

	EVT_BUTTON($this,$ID_OK,    sub { $_[0]->EndModal(wxID_OK) });
	EVT_BUTTON($this,$ID_CANCEL,sub { $_[0]->EndModal(wxID_CANCEL) });

	$editing ? $vctl->SetFocus() : $nctl->SetFocus();
	my $rslt = $this->ShowModal();
	my $got  = $nctl->GetValue();
	my $val  = $vctl->GetValue();
	$this->Destroy();

	return '' if $rslt != wxID_OK;

	$got = '' if !defined $got;
	$got =~ s/^\s+|\s+$//g;

	# WHITESPACE IS STRIPPED FROM THE VALUE TOO, and that is not fussiness.
	# A key is almost always pasted, and a pasted key brings a trailing
	# newline often enough that the first failure of a brand new feature
	# would otherwise be a 400 nobody could see the cause of.

	$val = '' if !defined $val;
	$val =~ s/^\s+|\s+$//g;

	# THE BRACES ARE ACCEPTED AND STRIPPED.  Somebody reading a url and
	# copying what they see there types {my_key}, and refusing that would be
	# refusing the most natural thing to do.

	$got =~ s/^\{|\}$//g;

	if ($got !~ /^[a-z0-9_]+$/)
	{
		error("a key_name must be lower case letters, digits or '_'");
		return '';
	}

	my $err = setKeyValue($got,$val);
	if ($err)
	{
		error($err);
		return '';
	}
	display($dbg_keys_ui,0,($editing ? "edited" : "added")." {$got}");
	return $got;
}


sub ask
	# ($parent,$key_name,$label,$obtain_url) -> 1 if a value was bound.
	#
	# THE PROMPT IS ALWAYS LAUNCHED FROM A DECLARATION.  A source or a
	# catalog entry says it needs this name and hands it here; nobody types
	# a name free hand on THIS path.  Inventing one is a deliberate act and
	# has its own door, editKey above.
{
	my ($class,$parent,$name,$label,$obtain) = @_;
	return 0 if !$name;

	$label ||= $name;

	my $this = $class->SUPER::new($parent,-1,
		'A key is needed',[-1,-1],[520,300]);

	my $head = Wx::StaticText->new($this,-1,
		"This service needs a key",[16,16],[480,20]);
	my $font = $head->GetFont();
	$font->SetWeight(wxFONTWEIGHT_BOLD);
	$head->SetFont($font);

	Wx::StaticText->new($this,-1,
		"$label\n\nIt is stored under the name {$name}, which is what the ".
		"source's url contains. The value is kept in the key store and ".
		"never in the .tsd file, so the file stays safe to hand to ".
		"somebody else.",
		[16,44],[480,80]);

	my $ctl = Wx::TextCtrl->new($this,-1,'',[16,132],[480,24]);

	my $note = Wx::StaticText->new($this,-1,
		$obtain ? "Get one at: $obtain" : '',
		[16,164],[480,20]);
	$note->SetForegroundColour($GREY);

	my $store = Wx::StaticText->new($this,-1,
		"stored in ".keysFile(),[16,188],[480,20]);
	$store->SetForegroundColour($GREY);

	my $ok = Wx::Button->new($this,$ID_OK,'Set',[280,224],[96,28]);
	my $no = Wx::Button->new($this,$ID_CANCEL,'Not now',[388,224],[96,28]);

	$ok->SetToolTip('Write this value into the key store');
	$no->SetToolTip('Leave it unset. The source will load and will not fetch.');

	EVT_BUTTON($this,$ID_OK,    sub { $_[0]->EndModal(wxID_OK) });
	EVT_BUTTON($this,$ID_CANCEL,sub { $_[0]->EndModal(wxID_CANCEL) });

	$ctl->SetFocus();
	my $rslt = $this->ShowModal();
	my $val  = $ctl->GetValue();
	$this->Destroy();

	return 0 if $rslt != wxID_OK;
	return 0 if !defined($val) || $val !~ /\S/;

	# WHITESPACE IS STRIPPED, and this is not fussiness.  A key is almost
	# always pasted, and a pasted key brings a trailing newline with it
	# often enough that the first failure of a brand new feature would
	# otherwise be a 400 that nobody could see the cause of.

	$val =~ s/^\s+|\s+$//g;

	my $err = setKeyValue($name,$val);
	if ($err)
	{
		error($err);
		return 0;
	}
	display($dbg_keys_ui,0,"ask() bound {$name}");
	return 1;
}


#---------------------------------------------
# SHOW - the standing list
#---------------------------------------------

sub _fill
{
	my ($this) = @_;
	my $list = $this->{list};
	$list->DeleteAllItems();

	my $refs = _referencesOf();
	my %seen;

	# EVERY NAME ANYTHING KNOWS ABOUT, from both directions.  A name a
	# source declares and nothing is bound to is the ordinary "you need to
	# paste a key" case; a name bound to a value that no source declares is
	# an ORPHAN, and is the only visible symptom of a typo.

	my @names = sort keys %{{ map { $_ => 1 }
		(getKeyNames(),keys %$refs) }};

	my $row = 0;
	for my $name (@names)
	{
		my $val   = getKeyValue($name);
		my $set   = (defined($val) && $val =~ /\S/) ? 1 : 0;
		my $who   = $refs->{$name} || [];

		$list->InsertStringItem($row,$name);
		$list->SetItem($row,1,$set ? 'set, '.length($val).' chars' : 'NOT SET');
		$list->SetItem($row,2,@$who ? join(', ',@$who) : 'nothing yet');

		# RED IS FOR THE ONE STATE THAT IS ALWAYS WRONG: a name something
		# declares with nothing bound to it.  A bound name that no source
		# uses is NOT flagged, because inventing a key before writing the
		# source that needs it is an ordinary order of work - it is only
		# suspicious in combination with a source that will not fetch, and
		# that combination is visible in this list without being coloured.

		$list->SetItemTextColour($row,$RED) if !$set;

		$this->{names}[$row] = $name;
		$row++;
	}

	$this->{count}->SetLabel(
		$row ? "$row key ".($row == 1 ? 'name' : 'names') :
			   "no keys yet - New... adds one, and installed sources that ".
			   "need a key list themselves here");
}


sub _selected
{
	my ($this) = @_;
	my $idx = $this->{list}->GetNextItem(-1,wxLIST_NEXT_ALL,wxLIST_STATE_SELECTED);
	return undef if $idx < 0;
	return $this->{names}[$idx];
}


sub show
	# ($parent).  Modal, and it writes as it goes: there is no Save here
	# and no Cancel, because every act in this dialog is one row and is
	# already reversible by its own opposite.  A dialog that batched a key
	# store would have to explain what discarding meant.
{
	my ($class,$parent) = @_;

	my $this = $class->SUPER::new($parent,-1,
		'Key Store',[-1,-1],[620,440]);

	my $head = Wx::StaticText->new($this,-1,
		"Values for the {key_names} that source urls contain",
		[16,12],[580,20]);
	my $font = $head->GetFont();
	$font->SetWeight(wxFONTWEIGHT_BOLD);
	$head->SetFont($font);

	$this->{count} = Wx::StaticText->new($this,-1,'',[16,36],[580,18]);
	$this->{count}->SetForegroundColour($GREY);

	my $list = Wx::ListCtrl->new($this,$ID_LIST,[16,60],[580,240],
		wxLC_REPORT | wxLC_SINGLE_SEL);
	$list->InsertColumn(0,'key_name');
	$list->InsertColumn(1,'value');
	$list->InsertColumn(2,'used by');
	$list->SetColumnWidth(0,160);
	$list->SetColumnWidth(1,120);
	$list->SetColumnWidth(2,280);
	$this->{list}  = $list;
	$this->{names} = [];

	my $where = Wx::StaticText->new($this,-1,
		"stored in ".keysFile()."\n".
		"in plain text, and deliberately: a key this application uses ".
		"unattended has to be recoverable by it. Move the folder in ".
		"Preferences to put it on an encrypted volume.",
		[16,308],[580,48]);
	$where->SetForegroundColour($GREY);

	my $new   = Wx::Button->new($this,$ID_NEW,   'New...', [16,368],[96,28]);
	my $edit  = Wx::Button->new($this,$ID_EDIT,  'Edit...',[124,368],[96,28]);
	my $del   = Wx::Button->new($this,$ID_DELETE,'Delete', [232,368],[96,28]);
	my $close = Wx::Button->new($this,$ID_CLOSE, 'Close',  [500,368],[96,28]);

	$new->SetToolTip('Add a key_name and its value');
	$edit->SetToolTip('Change the value of the selected key_name');
	$del->SetToolTip('Remove the binding. A name a source declares stays listed, unset.');

	EVT_BUTTON($this,$ID_NEW,sub {
		$_[0]->_fill() if w_keys->editKey($_[0],'');
	});

	# NOTHING SELECTED IS A REASON, NOT A NO-OP.  A button that silently
	# does nothing is indistinguishable from a broken one, and with an empty
	# store there is nothing to select in the first place - which is exactly
	# when somebody presses this and concludes the feature does not work.

	EVT_BUTTON($this,$ID_EDIT,sub {
		my $name = $_[0]->_selected();
		if (!$name)
		{
			error(scalar(@{$_[0]->{names}}) ?
				"select a key_name in the list first" :
				"there are no keys yet - use New... to add one");
			return;
		}
		w_keys->editKey($_[0],$name);
		$_[0]->_fill();
	});

	EVT_BUTTON($this,$ID_DELETE,sub {
		my $name = $_[0]->_selected();
		if (!$name)
		{
			error("select a key_name in the list first");
			return;
		}
		my $err = deleteKeyValue($name);
		error($err) if $err;
		display($dbg_keys_ui,0,"deleted {$name}");
		$_[0]->_fill();
	});

	EVT_BUTTON($this,$ID_CLOSE,sub { $_[0]->EndModal(wxID_OK) });

	$this->_fill();
	$this->ShowModal();
	$this->Destroy();
	return 1;
}


1;
