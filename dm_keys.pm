#!/usr/bin/perl
#---------------------------------------------
# dm_keys.pm
#---------------------------------------------
# THE KEY STORE.  A map of key_name to key_value, and nothing else.
#
# A url may contain {some_key_name}, a file declares the names it uses, and
# this holds the values.  That is the whole mechanism: a named, literal,
# one-level substitution with no computation anywhere in it, which is what
# lets a .tsd stay data rather than becoming code.
#
# IT IS NOT ABOUT SECRETS, and the naming says so deliberately.  An API
# key, a password, a subscription instance id and an archive release number
# are the same mechanism wearing different clothes, and only some of them
# are confidential.  'credential' was the narrow word and it was narrowing
# the design with it.
#
# IT IS FREE STANDING, NOT A PROJECTION OF WHAT IS INSTALLED.  Three
# separate facts forced that and any one of them would have been enough:
#
#	ONE VALUE SERVES MANY FILES.  LINZ publishes 138 layers behind one key.
#	Keying this by file, or by cache_key, would mean pasting the same
#	string 138 times.
#
#	A CAPABILITIES DOCUMENT NEEDS THE KEY TOO.  Expanding a keyed provider
#	is a fetch, so the value has to exist BEFORE any file does - and if a
#	value could only live against an installed source, a keyed provider
#	could never be expanded at all.  That is circular and it is not
#	theoretical.
#
#	A VALUE MAY OUTLIVE EVERY FILE THAT USED IT.  Deleting a source should
#	not silently discard a key somebody had to ask a government for.
#
# WHAT IT DOES NOT DO is decide whether a name is the RIGHT name.  A user
# may use a name the catalog reserves, correctly or incorrectly, and
# detecting that is beyond anything this application can honestly claim.
# What it can do is make the state visible: which installed files reference
# a name, and which names are bound to nothing.  A typo shows up there as
# an orphan sitting beside a source that will not fetch, which is a
# person's inference to draw.
#
# PLAIN TEXT, AND THE REASON SAID OUT LOUD.  A key the application uses
# unattended has to be recoverable by the application, so encrypting it
# under a key kept beside it is theatre.  The real answer is the FOLDER,
# which is a preference: put it on removable media or an encrypted volume
# and the question is settled properly rather than decoratively.

package dm_keys;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP;
use Pub::Utils;
use cm_defs;
use cm_prefs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		keysFile
		loadKeys
		getKeyNames
		getKeyValue
		setKeyValue
		deleteKeyValue
		saveKeys

		keyNamesOf
		keyResolve
		keyRedact
		keyUnresolved
	);
}


our $dbg_keys:shared = 0;
	# 0  = a value set or deleted
	# -1 = the load, and every resolution

# ONE FILE, AND ITS NAME IS A CONSTANT.  The preference names the FOLDER,
# so there is never a second setting for one thing.
#
# It is namespaced by the application the way chartMaker.prefs is, and for
# a reason that only appears once the folder has been moved: the whole
# point of the preference is to let this file live on an encrypted volume
# or a USB stick, which are exactly the places something else has already
# left a keys.json.

my $KEYS_LEAF = "$appName.keys.json";

my $loaded = 0;
my %keys   = ();


#---------------------------------------------
# the file
#---------------------------------------------

sub keysFile
	# THROUGH prefDir AND NOT getPref.  A folder preference exists in the
	# prefs file only when somebody set one, so a raw read returns undef for
	# every user who never moved it - which is nearly all of them.  prefDir
	# is the one place that knows a folder has a computed default.
{
	return prefDir($PREF_KEYS_DIR)."/$KEYS_LEAF";
}


sub loadKeys
	# '' or the reason it would not load.  A MISSING FILE IS NOT AN ERROR:
	# a user with no keyed source never makes one, and reporting its
	# absence would be reporting the ordinary case as a fault.
{
	my ($force) = @_;
	return '' if $loaded && !$force;

	$loaded = 1;
	%keys   = ();

	my $file = keysFile();
	if (!-f $file)
	{
		display($dbg_keys+1,0,"loadKeys() no key store at $file");
		return '';
	}

	my $text = '';
	if (open(my $fh,'<',$file))
	{
		local $/ = undef;
		$text = <$fh>;
		close $fh;
	}
	else
	{
		return "cannot read $file: $!";
	}

	my $json = eval { JSON::PP->new->decode($text) };
	return "$KEYS_LEAF is not valid JSON: $@" if $@ || !$json;
	return "$KEYS_LEAF must be a JSON object of key_name to key_value"
		if ref($json) ne 'HASH';

	for my $name (sort keys %$json)
	{
		my $val = $json->{$name};

		# A NAME THAT COULD NEVER BE SUBSTITUTED IS REFUSED HERE rather
		# than sitting in the file looking bound.  The placeholder grammar
		# is [a-z0-9_], so anything else can never match a {token}.

		if ($name !~ /^[a-z0-9_]+$/)
		{
			warning(0,0,"key store: ignoring '$name' - a key_name must be ".
				"lower case letters, digits or '_'");
			next;
		}
		if (ref($val) || !defined($val))
		{
			warning(0,0,"key store: ignoring '$name' - a key_value must ".
				"be a string");
			next;
		}
		$keys{$name} = $val;
	}

	display($dbg_keys,0,"loadKeys() ".scalar(keys %keys)." keys from $file");
	return '';
}


sub saveKeys
	# '' or the reason it could not be written.  Written whole, sorted, so
	# a person can read it and a diff means something.
{
	my $dir = prefDir($PREF_KEYS_DIR);
	if (!-d $dir)
	{
		mkdir($dir) or return "cannot create $dir: $!";
	}

	my $file = keysFile();
	my $json = JSON::PP->new->pretty->canonical->encode(\%keys);

	open(my $fh,'>',$file) or return "cannot write $file: $!";
	print $fh $json;
	close $fh;

	display($dbg_keys,0,"saveKeys() ".scalar(keys %keys)." keys to $file");
	return '';
}


#---------------------------------------------
# the map
#---------------------------------------------

sub getKeyNames
	# A LIST, BUILT EXPLICITLY.  'return sort keys %h' hands back the last
	# element in scalar context rather than a count, which is a quiet way to
	# be wrong at every call site that wanted a number.
{
	loadKeys();
	my @out = sort keys %keys;
	return @out;
}


sub getKeyValue
	# undef where nothing is bound, which is DIFFERENT from an empty
	# string.  An empty binding is a person having deliberately cleared
	# one; no binding is a question nobody has answered.
{
	my ($name) = @_;
	loadKeys();
	return $keys{$name};
}


sub setKeyValue
{
	my ($name,$value) = @_;
	return "a key_name must be lower case letters, digits or '_'"
		if !defined($name) || $name !~ /^[a-z0-9_]+$/;
	$value = '' if !defined $value;

	loadKeys();
	$keys{$name} = $value;
	display($dbg_keys,0,"setKeyValue($name) = ".
		(length($value) ? length($value)." chars" : "empty"));
	return saveKeys();
}


sub deleteKeyValue
{
	my ($name) = @_;
	loadKeys();
	return '' if !exists $keys{$name};
	delete $keys{$name};
	display($dbg_keys,0,"deleteKeyValue($name)");
	return saveKeys();
}


#---------------------------------------------
# substitution
#---------------------------------------------
# THE ONE PLACE A key_value EVER ENTERS A URL, and the one place it is
# taken back out again.  Everything that fetches goes through keyResolve,
# and everything that REPORTS goes through keyRedact, which is what keeps a
# value out of a log, an error message, a probe report and a build report
# without each of those having to remember.

sub keyNamesOf
	# The {tokens} in a template that are not part of the closed
	# placeholder set - which is to say, the key_names it uses.
	#
	# It takes the reserved set as an argument rather than importing
	# dm_source, because dm_source is the module that owns that list and a
	# second copy of it here would be a second rulebook.
{
	my ($url,$reserved) = @_;
	return () if !defined $url;

	my %skip = map { $_ => 1 } @{ $reserved || [] };
	my %seen;
	my @out;
	while ($url =~ /\{([^{}]+)\}/g)
	{
		my $tok = $1;
		next if $skip{$tok};
		next if $seen{$tok}++;
		push @out,$tok;
	}
	return @out;
}


sub keyResolve
	# ($url, \@key_names) -> ($resolved, $unresolved_name)
	#
	# EITHER EVERY NAME RESOLVES OR NONE OF IT IS USABLE.  A half
	# substituted url is not a lesser url, it is a request to somebody
	# else's server with a literal brace in it, and the one thing that must
	# never happen is that it gets sent.  So the second return value is the
	# first name that had no value, and the caller has no way to use the
	# first without checking it.
{
	my ($url,$names) = @_;
	return (undef,undef) if !defined $url;
	loadKeys();

	for my $name (@{ $names || [] })
	{
		my $val = $keys{$name};
		return (undef,$name) if !defined($val) || $val !~ /\S/;
		$url =~ s/\{\Q$name\E\}/$val/g;
	}
	display($dbg_keys+1,0,"keyResolve -> ".keyRedact($url));
	return ($url,undef);
}


sub keyRedact
	# EVERY VALUE THIS STORE HOLDS, TAKEN BACK OUT OF A STRING.
	#
	# It works on VALUES rather than on url shapes, which is what makes it
	# safe to call on anything: a log line, an error message a server sent
	# back, a capabilities document, a report. Nothing has to know where in
	# the text a key might have ended up, only that this ran.
	#
	# The name goes back in place of the value, so what a person reads is
	# the template they wrote rather than a row of asterisks that could be
	# anything.
{
	my ($text) = @_;
	return $text if !defined($text) || $text !~ /\S/;
	loadKeys();

	for my $name (sort { length($keys{$b}) <=> length($keys{$a}) } keys %keys)
	{
		my $val = $keys{$name};
		next if !defined($val) || length($val) < 4;
			# A SHORT VALUE IS NOT REDACTED, because a two character key
			# would match half the words in a sentence and turn a readable
			# message into confetti.  Nothing worth protecting is that
			# short, and a store that mangled every log line would simply
			# be turned off.

		$text =~ s/\Q$val\E/{$name}/g;
	}
	return $text;
}


sub keyUnresolved
	# The first key_name a template needs and has no value for, or ''.
	# A PROPERTY OF THE TEMPLATE, not of a coordinate: a url that cannot be
	# substituted cannot be substituted anywhere, so this is asked once and
	# not once per tile.
{
	my ($url,$reserved) = @_;
	loadKeys();
	for my $name (keyNamesOf($url,$reserved))
	{
		my $val = $keys{$name};
		return $name if !defined($val) || $val !~ /\S/;
	}
	return '';
}


1;
