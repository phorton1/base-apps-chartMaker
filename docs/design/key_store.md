# chartMaker - Key Store

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**Key Store** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

Some tile services will not answer without a value the user has to obtain for themselves.
The **key store** is where those values live. A url contains `{a_key_name}`, a `.tsd`
declares the names it uses, and this holds `key_name` to `key_value` and nothing else.

## It is a named substitution, not a credential system

**The value is a literal string, put in exactly where the name appears, once, with nothing
computed on either side.** That is not incidental. It is the property that keeps a `.tsd`
data rather than code: the format has no expressions and no derived fields, so a key can be
substituted into a template and can never be used to construct a request signature or
derive a session token. See [TSD](tsd.md#the-closed-placeholder-set).

**And it is deliberately not called a credential.** An API key, a password, a subscription
instance id and an archive release number are the same mechanism wearing different clothes,
and only some of them are confidential. "Credential" is the narrow word, and it was
narrowing the design: it made the mechanism sound like it was about secrecy when it is
about substitution.

**What it does not reach is a header.** This is a url mechanism, so HTTP Basic, a bearer
token and a signed request are outside it - not impossible to specify one day, but a
different mechanism with its own name rather than a wider reading of this one. A
**handshake** is outside it permanently and for a structural reason: making one request in
order to construct another is exactly what a declarative file cannot do.

## The store is free standing

**It is a map of name to value, not a projection of what is installed.** Three separate
facts force that, and any one of them would have been enough.

**One value serves many files.** LINZ publishes 138 layers behind a single key. Keying the
store by file, or by `cache_key`, would mean pasting the same string once per layer.

**A capabilities document needs the key too.** Expanding a keyed provider is a fetch, so
the value has to exist *before* any file does. If a value could only live against an
installed source, a keyed provider could never be expanded at all - you would need a source
to get a key and a key to get the source. That circularity is not hypothetical; it is
exactly what LINZ presents.

**A value may outlive every file that used it.** Deleting a source should not silently
discard something a user had to ask a government agency for.

## Plain text, and the reason said out loud

**A key this application uses unattended has to be recoverable by this application**, so
encrypting it under another key stored beside it is theatre. The store is a JSON object in
plain text and the dialog says so.

**The real answer is the folder, and it is a preference.** `chartMaker.keys.json` lives in
`$data_dir` by default, beside the user's own material where it will not be lost. But
`$data_dir` is backed up and frequently cloud synced, so a user who does not want their
keys copied to a sync service can point the store at removable media or an encrypted
volume without giving up the default for anything else. See
[Deployment](../deployment.md#the-key-store).

**The file name is a constant** so that there is never a second setting for one thing, and
it is namespaced by the application because the whole point of the preference is to let it
sit somewhere that already has a `keys.json` in it.

## Three seams, not one

A `key_value` enters a url in exactly three places, and missing any of them produces a
failure that reads like a broken endpoint.

| Seam | What it fetches |
| --- | --- |
| `dm_source::sourceTileUrl` | a tile |
| `dm_meta::metaSource` | the service's own capabilities or `?f=json` |
| the [catalog](catalog.md)'s Expand | a provider's layer list |

**The second and third exist because a keyed service's metadata is keyed too.** LINZ
answers `400` on its capabilities document without a key, exactly as it does on a tile. A
design that resolved keys only on the tile path would leave Expand and the probe failing
with a status code that says nothing about the cause.

## Nothing unresolved ever becomes a request

**If a url cannot be fully substituted it is either an unbound key or a typo, and in
neither case may it reach the network.** A request carrying a literal `{brace}` is a
malformed question asked of somebody else's server.

**It is a property of the source, not of a tile.** A url that cannot be substituted cannot
be substituted at any coordinate, so it is asked once - when a list is drawn, when a build
is preflighted - and never once per tile.

**And it is an error, not an absence.** This distinction is load bearing. An absence is a
fact about the *service* and is cached, because it will still be true tomorrow; an
unresolved key is a fact about the *user's own configuration*. Caching it would write
permanent miss markers over everywhere somebody happened to look before pasting their key,
and nothing would ever ask again. See [Build](build.md#the-cache).

**Nor is it retried.** The other unretried classes describe a server's reply; this one says
no request was made at all.

## Prompt where a person is authoring, fail where the act is mechanical

**The catalog and Test may ask.** Somebody is sitting there, they have just clicked
something, the entry names the key it needs and carries `obtain_url` as the place to get
one, and the alternative is a network act that fails for a reason the dialog already knew.
Declining is an answer: it does not ask again and it does not proceed anyway.

**Build, the probe and the map report and stop.** A build runs on a worker thread under a
modal progress dialog, and a prompt there would block that thread and ambush somebody who
walked away from a two hour run. The map is the case in between and belongs on this side of
the line: browsing is interactive, but nobody clicked "use this source" at the moment a
tile was requested, and a pan should not raise a dialog.

**A build meets it at preflight**, alongside what will be overwritten and what is
displaced, which is the last moment it can be said cheaply.

## The prompt answers, the store invents

A source or a catalog entry says it needs `linz_api_key` and **the prompt** fills that one
in. Nobody types a name free hand on that path: a name invented in answer to a question
about a different name would create a binding that reads nowhere.

**Inventing a name is an ordinary thing to want and has its own door.** The store is a
generic map, so a user may add `my_password` or `some_service_key` before any file mentions
it - because they are about to write a source by hand, or because the url is one nobody
else has seen. That is `New...` in the standing dialog, which is where a deliberate act
belongs and where the consequences of a typo are also visible.

**The standing dialog earns its place by doing what a prompt cannot**: showing what is
bound, clearing one, adding one, and showing which installed sources reference each name.

**A name nothing references is not flagged as an error**, because inventing a key before
writing the source that needs it is a normal order of work. What is flagged is the state
that is always wrong: a name something declares with nothing bound to it. A typo shows up
as the combination - a bound name nothing uses, sitting in the same list as a source that
will not fetch - which is a person's inference to draw rather than the machine's.

**Neither dialog displays a value it did not just receive.** The list says set or not set
and how long it is. Somebody looking over a shoulder is not somebody who should be reading
a key, and a value that is genuinely wanted back is in the file, in plain text, by design.

## Redaction works on values, not on shapes

Everything that reports goes through one function that takes **every value the store holds**
back out of a string and puts the name in its place. It works on values rather than on url
patterns, which is what makes it safe to call on anything - a log line, an error a server
sent back, a capabilities document, a build report. Nothing has to know where in the text a
key might have ended up.

**A very short value is not redacted**, because a two character key would match half the
words in a sentence and turn every message into confetti. Nothing worth protecting is that
short, and a store that mangled the log would simply be turned off.

## Expand strips a key back out

**A keyed service's capabilities document hands back templates with the live key baked into
them.** Not a placeholder - the value that was just used to fetch it. LINZ does exactly
this.

So what comes off the wire has every known `key_value` turned back into its `{key_name}`
before anything is written. Without that step, every entry Expand produced would carry a
working secret in the one field the format promises is safe to hand to a stranger, and the
file would look completely ordinary.

The declaration is kept where the stripped url still names a key and dropped where it does
not, because a url containing `{linz_api_key}` with no matching declaration is a file
[`dm_source`](tsd.md#validation) refuses to load.

## What a `.tsd` says, and what it may never say

```
    "keys": [
      { "key_name": "linz_api_key",
        "label": "LINZ API key",
        "obtain_url": "https://basemaps.linz.govt.nz" }
    ]
```

**A `key_value` in a `.tsd` is refused at load**, naming the file and saying where a value
belongs. That refusal is what makes "safe to share by construction" a property rather than
a promise.

**The declaration is kept rather than inferred from the url**, and that is a deliberate
choice with a cost. A rule of "anything in braces is a key_name" would be simpler, and it
would turn every typo - `{Z}`, `{yy}`, `{tilerow}` - into an unbound key that loads
perfectly and then fails against somebody else's server. Declaring costs one line and buys
two things: the typo is caught at load, and a file handed to a stranger tells them what
they must supply *before* they try it.

## Reserved names are a convention and cannot be a mechanism

The [catalog](catalog.md) uses service-prefixed names - `linz_api_key` rather than
`api_key` - so that two services cannot collide on something generic. A user may use those
names well or badly, and the application has no standing to have an opinion about which.

What it can do is make the state visible rather than detect the error, which is what the
orphan row is for.

---

**Next:** [Build](build.md)
