# Sources and TSD Files

**[Reference](readme.md)** --
**Sources and TSD Files** --
**[The Catalog](catalog.md)** --
**[Preferences and Keys](preferences_keys.md)** --
**[Housekeeping](housekeeping.md)**

folders: **[Home](../readme.md)** --
**[Tutorial](../tutorial/readme.md)** --
**Reference**

A **TSD** - *Tile Source Definition*, extension `.tsd` - is a small text file describing
exactly one imagery service. They live in your `sources` folder, they are ordinary editable
files, and chartMaker is a *reader* of them rather than a holder of sources.

That is the boundary the whole program is built around: **the decision about which service to
use, and on what terms, stays with you.** What ships is a starting point, not a
recommendation and not a limit.

## What is in one

A TSD is JSON. The fields you will actually touch:

| Field | What it is |
| ----- | ---------- |
| `id` | How a region refers to this source. Lower case, digits, `_` and `-`. |
| `name` | What you see in a list. |
| `url` | The tile address template. |
| `min_zoom`, `max_zoom` | The levels the **server** will answer at all. Not how deep the imagery is good - that is what [probing](../tutorial/choosing_a_source.md) is for. |
| `uses` | `display`, or `display` and `build`. |
| `attribution` | Mandatory and non-empty. A file without it will not load. |
| `license`, `terms_url` | What the publisher permits, and where they said so. |
| `cache_key` | Which cache folder its tiles go in. Defaults to the file's own name. |
| `min_interval_ms`, `max_concurrency` | How gently to treat this server. **Present only when the operator publishes a figure** - of everything chartMaker ships, one source does. Absent means chartMaker's own limit applies, which you set in Preferences. |
| `keys` | The **names** of any values the url needs. Never the values. |
| `notes` | Free text. JSON has no comments. |

### The url template

The url substitutes from a **closed set** of placeholders and nothing else:

```
    {z} {x} {y}     the tile coordinate
    {-y}            the same row, counted from the other end (TMS)
    {s}             one of the subdomains the file lists
    {q}             quadkey addressing - the same grid, encoded differently
    {any_key_name}  a value from the key store
```

**There is no expression language, no computed field, and no script.** That is a structural
guarantee rather than a promise: the format is simply unable to express a signature
computation or a session token, so no TSD can be written that performs one. A file that
arrives from a stranger is **data being read, not code being run** - which is what makes
handing one to somebody a safe thing to do.

### Two rules worth knowing

**Web Mercator, 256 pixel tiles, or it is refused.** Tiles pass through chartMaker
byte-for-byte, so there is no reprojection or image-processing machinery inside it - which is
why the installer is one file with no toolchain behind it. Anything in another projection is
converted outside, by tools built for it, and comes back as a local source.

**A source never declares where it has imagery.** No bounding box, no coverage. Every service
is patchy, a rectangle claims both more and less than the truth, and chartMaker has to cope
with absence regardless - so coverage is *discovered* as you use it and remembered, which is
also why the misses are cached.

## Writing one

**`Edit - New Source`** opens the source editor on an empty file. **`Edit - Tile Source
Catalog`** is usually the better start - see [The Catalog](catalog.md) - because it fills in
the fields from something already known.

The editor validates as you go and is deliberately unforgiving, because these files circulate
between strangers and a file that loads but is subtly wrong fails later, against somebody
else's server, in a way that says nothing about the cause.

### Test

**Test** asks the service whether the file is true, without building anything. It fetches over
a place the service is known to hold imagery, reports which fields the answer refutes, and
says where each is fixed.

Test tells you the **address works**. It does not tell you the **imagery is any good over your
water** - that is what a [probe](../tutorial/choosing_a_source.md) is for. The two are
different questions and both are worth asking.

## Keys

Some services will not answer without a value you have to obtain yourself. **A TSD declares
the *name* of that value and never the value**, and a file containing one is refused at load,
naming itself and saying where the value belongs.

That refusal is what makes "safe to share" a property rather than a hope: no key can leak
through a definition you passed on, and none ever lands in a file you might commit to a
repository. Where the values live is in
[Preferences and Keys](preferences_keys.md#the-key-store).

The mechanism is a **named substitution**, not a credential system - an API key, a password
and an archive release number are the same thing to a url, and only some of them are secret.
It reaches the url and nothing else, so a service needing a header, a bearer token or a
handshake is outside what a TSD can describe.

## Sharing

**Regions name a source by id and never contain it.** So handing somebody a region, or a
whole set, never ships your endpoint or your credentials inside it.

If they do not have that source, the set still opens - that is the normal condition of a set
that arrived from somebody else, and they have to be able to open it to find out what it
wants. It is the **build** that refuses, which is the first moment it matters, and by then the
conversation to have is obvious.

The full field reference, with the validation rules, is in
[Design: TSD](../../docs/design/tsd.md).

---

**Next:** [The Catalog](catalog.md)
