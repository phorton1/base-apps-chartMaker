# chartMaker - TSD

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**TSD** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

A **TSD** (*Tile Source Definition*, extension `.tsd`) describes exactly one imagery
source: a **remote XYZ tile service serving 256 pixel tiles in EPSG:3857**, which is the one
shape of source chartMaker reads. [Architecture](../architecture.md#tile-source-definition-tsd)
says why the format exists and what it refuses to be; this document is the field reference.

TSD files live in `$data_dir` and are found by scanning it, so installing a source somebody
sent you is a matter of putting the file in the folder.

## Field reference

```
    tsd_version:      1
    id:               a stable identifier, referenced by regions
    name:             what a person calls it
    notes:            free text
    cache_key:        which tiles this file addresses  (default: the file name)
    url:              the tile url template
    subdomains:       values substituted for {s}
    tile_format:      jpeg | png        (an expectation, not a guarantee)
    tile_size:        256
    crs:              EPSG:3857
    zoom:             { min, max }      PROTOCOL limits only
    attribution:      MANDATORY, non-empty
    terms_url:        where the terms of use are published
    license:          a short identifier or description
    redistributable:  yes | no | unknown          (default unknown)
    uses:             any of ["display","build","overlay"]
    credentials:      [ { slot, label, obtain_url } ]    SLOTS, never values
    policy:           { max_concurrency, min_interval_ms }
    absent_fingerprints:
                      [ { bytes, md5 } ]   a 200 that means 404
    absent_headers:   [ { name, value } ]  the same absence, said in a header
    displacement:     a named coordinate transform - ADVISORY, never acted on
```

| Field             | Notes                                                                      |
| ----------------- | -------------------------------------------------------------------------- |
| `tsd_version`     | Format version.                                                            |
| `id`              | Stable. Regions reference it; renaming the file does not change it.        |
| `cache_key`       | Which cached tiles this file addresses. Defaults to the file name.        |
| `url`             | Template. Substitutes only from the closed placeholder set below.          |
| `tile_format`     | What the source is expected to return. The actual format is detected.      |
| `tile_size`       | Must be 256. Anything else is rejected at import.                          |
| `crs`             | Must be `EPSG:3857`. Anything else is rejected at import.                  |
| `zoom.max`        | The highest zoom the **server will answer at all**, not where detail ends. |
| `attribution`     | Mandatory and non-empty. A file without it does not load.                  |
| `redistributable` | The author's assertion. Propagates into built output as metadata.          |
| `uses`            | What the source is FOR. Not "what it uses" - see below.                    |
| `absent_fingerprints` | The bytes a server sends INSTEAD of saying no. Read as absences.       |
| `absent_headers`  | The same statement made in a header rather than in the bytes.              |
| `displacement`    | A known displacement of the imagery. Recorded and shown, never acted on.   |
| `credentials`     | Names of secrets the source needs. Never the secrets themselves.           |
| `policy`          | Requested limits. The application clamps regardless of what is asked for.  |

The fields land almost exactly on Leaflet's `L.TileLayer` options, arrived at independently
over fifteen years of tiled maps. That convergence is a reasonable sign the shape is right.

## The closed placeholder set

A URL template may contain these and nothing else:

| Placeholder | Substitutes                                                        |
| ----------- | ------------------------------------------------------------------ |
| `{z}`       | Zoom level.                                                        |
| `{x}`       | Tile column.                                                       |
| `{y}`       | Tile row, counting from the north.                                 |
| `{-y}`      | Tile row, counting from the south - the TMS row flip.              |
| `{s}`       | One of the declared `subdomains`.                                  |
| `{q}`       | The quadkey - the same grid under a different encoding.            |
| `{slot}`    | The value stored for a credential slot the file itself declares.   |

`{-y}` is why there is no addressing-scheme enum: TMS is not a different grid, only a
different row origin. `{q}` is there for the same reason.

**Nothing else substitutes, and nothing is computed.** The format has no expressions, no
scripting, and no derived fields, so it is structurally unable to express a request
signature or a session-token derivation. That is a guarantee enforced by the validator
rather than a promise made in a document, and it is what makes a file received from a
stranger data being read rather than code being run.

## Validation

A TSD is **JSON**, and the rules below are the whole of validation. `dm_source` enforces
them, reading a file and either returning a source or reporting why it would not. They are
deliberately unforgiving, because these files circulate between people who do not know each
other and a file that is almost right is worse than one that is refused. They are also a
machine-checkable statement of what the format is *able* to say.

Rules that cause a file to be rejected:

- `attribution` missing or empty.
- `tile_size` other than 256, or `crs` other than `EPSG:3857`.
- A placeholder in `url` that is not in the closed set, or a credential placeholder for a
  slot the file does not declare.
- Any field the format does not define.

`notes` exists because JSON has no comments and these files are read by people.

## Protocol is declared, data is discovered

The rule that settles most format arguments before they start. A **protocol** fact is true
everywhere the source is reachable and belongs in the file. A **data** fact is local to a
place and is found out at runtime.

- **There is no `bounds` field and no declared coverage.** Every source is sparse, so a
  rectangle claims both more and less than the source holds, and the build must tolerate
  absence regardless. Coverage is discovered and cached - including the misses, which is
  what makes the picture accumulate for free. See [Build](build.md#the-cache).
- **`zoom.max` is a protocol limit only.** It says where the server starts refusing
  requests. Where *real* detail ends varies by location within a single source and is
  discovered. NASA GIBS is the declarable case, since each of its layers names a tile
  matrix set and the service refuses above it; a large commercial mosaic is the opposite
  case, upsampling indefinitely rather than answering "not found."
- **`tile_format` is an expectation.** Servers mix formats within one source, and at least
  one output format accepts only one of them, so the actual format is read from the image's
  magic bytes and a mismatch becomes a decision rather than a surprise.

## What a source is for

**`uses` means "what this source is FOR", not "what this source uses."** The name has
misled two readers already, which is enough to say so here rather than leave it to be
inferred from the values.

There are three, and a source may declare any combination:

| Value     | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| `display` | May be drawn on the map.                                                   |
| `build`   | May be named by a region and read by an exporter.                          |
| `overlay` | Drawn **over** a base layer rather than instead of one - names, boundaries. |

`overlay` is what separates a radio button from a checkbox: base layers are exclusive
because two of them means one hides the other, while overlays compose. Adding it to the
vocabulary invalidated no existing file, so `tsd_version` did not move.

A source that does not declare `build` never appears where a region's source is chosen.

The distinction does two jobs at once, which is usually the sign a field is drawn
correctly. It describes genuinely different traffic - browsing generates viewport-shaped
requests, building generates systematic ones - and it records the user's own assertion
about what a source is for. It is the user's assertion and not the application's legal
opinion, so it guards against accident rather than intent: against reaching for a backdrop
as a build source at two in the morning.

It is also simply practical. A street basemap is display-only because building a
nine-thousand-tile pyramid of one is pointless, not because of anybody's terms.

## `inherited` is a reserved id

A region names its source by id, and a **subregion** may use the value `inherited` to mean
"my parent's". That is one string field answering both questions, so no reader has to test
two things - and the cost is one id that cannot name a real source. A TSD claiming it is
refused at load, because a source called `inherited` could never be selected by anything and
would fail in a way nobody could diagnose.

## A 200 that means 404

A well behaved source answers **404** for a tile it does not hold. Some answer **200 with a
fixed image saying so in words**.

Nothing downstream can tell that from imagery. It is not a blurry tile, which at least
resembles the ground; it is a picture of a sentence, and a build will bake it into a card and
report success. That is the worst failure this application has, because every signal says it
worked.

`absent_fingerprints` is how a file says so:

```
    "absent_fingerprints": [
      { "bytes": 2521, "md5": "f27d9de7f80c13501f470595e327aa6d" }
    ]
```

**Length first, digest only on an exact match.** A source with no fingerprints - which is
most of them - pays one integer comparison per tile, so the check costs the map nothing.

**Checked on the way out of the cache as well as the way in**, so declaring a fingerprint
retroactively reclassifies tiles already on disk. Discovering one does not mean clearing the
cache. That check belongs to one place and every reader of the cache goes through it - a
second reader looking at the file directly is a second opinion about what a hit means, and the
one that got it wrong was the probe, on the surface whose whole job is to notice.

**The reclassification is recorded, and the image goes.** A tile cannot be both present and
absent, and the cache looks for an image before it looks for an absence marker - so a marker
written beside a picture is a file nothing ever reads, with the wrong answer winning. Only a
body this file *names* reaches that point, which is a person's assertion about the source, made
by hand; honouring it is the point of declaring it.

**A refusal and a sentinel stay distinguishable afterwards.** For anything that builds a card
they are the same thing - there is no tile either way - but they are not the same finding about
a service, and the finding is what a probe exists to make. The marker remembers which, because
the bytes are gone by the time anybody could work it out again. See [Build](build.md#the-probe).

**Declared, not detected.** It is a fact about a server, and this file is where facts about
servers live. A probe can *discover* one - fetch over ground known to be empty and watch for
byte-identical repeats - but the file is what remembers.

Note what this is **not**: it does not detect a source that magnifies its own imagery past
where real detail ends. That produces genuinely different bytes every time and is a fact
about ground rather than about a server. See [Build](build.md) on where that is measured.

### The same statement, made in a header

Some services do not vary the bytes at all and mark the absence in a response header
instead:

```
    "absent_headers": [ { "name": "X-VE-Tile-Info", "value": "no-tile" } ]
```

A match on any listed header, compared case-insensitively on the name and exactly on the
value, is read as an absence exactly as a fingerprint match is. It is a separate field
rather than a variant of `absent_fingerprints` because the two are checked at different
points - a header is known before the body is read, so it costs nothing and can skip the
body entirely, while a fingerprint needs the bytes in hand.

**The value must match exactly, and that direction is deliberate.** A substring rule would
let `no-tile` match a header saying `no-tile-here`, and a false absence is the expensive
error here: it caches a miss for a tile that exists, and nothing will ever ask again.
Failing to recognise an absence only costs a tile that looks wrong, which a person can see.

**Unlike a fingerprint, this cannot reach the cache.** Headers are not stored beside the
bytes, so there is nothing for an on-the-way-out check to test, and declaring one here
reclassifies nothing already on disk. A source taught to say no in a header only says it on
tiles fetched afterwards; tiles already cached keep whatever they were called. Clearing that
source's cache is the only way to revisit them, which is the one place these two fields
genuinely differ in what declaring them achieves.

Both are declared and neither is detected, for the same reason: they are facts about a
server, and this file is where facts about servers live.

## Displacement is recorded, never corrected

Some services publish imagery that is deliberately displaced from WGS 84. The best known
case is the transform Chinese regulation requires, which moves the pixels several hundred
metres and varies the offset with position. The tile grid is correct, the tiles align with
each other, and every structural check this format performs passes.

```
    "displacement": "GCJ-02"
```

**The field is named for the oddity it describes.** `registration` is the neutral term for
something every dataset has, so it reads as a field that ought to be filled in, and a blank
one reads as an omission. `displacement` reads as what it is: a rare statement that this
particular source is wrong on purpose. Almost no source declares it and none should feel
obliged to.

**The field is advisory and the application never acts on it.** It is not consulted when
fetching, not consulted when building, and no tile is ever moved. Absent means the imagery
is where it says it is; any value names a known transform.

Two reasons it is recorded rather than enforced. Correcting it would be a reprojection, and
this application does not resample or reproject anything. And the judgement is not the
application's to make: a consumer may apply its own offset, and a purpose may not be
navigation.

**It is said twice, and the second time is the one that matters.** The source list shows it
wherever a source is inspected, which is passive and depends on somebody looking. The build
preflight states it again as a cost of the build about to start, alongside what will be
overwritten, because that is the last moment before hours of fetching produce a chartset
that is quietly in the wrong place. Neither is a refusal.

What it buys is that the one failure nothing else can catch stops being invisible. A user
who would have discovered the displacement on the water reads it before the build instead.

## Credentials

**A TSD declares credential slots and never contains a credential value.** A slot names the
secret a source needs and where to obtain one:

```
    credentials: [ { slot: "api_key", label: "API key", obtain_url: "https://..." } ]
```

The value lives in the credential store, whose location is specified in
[Deployment](../deployment.md#the-credential-store). Two consequences follow, and
both are structural rather than procedural: a TSD is safe to share by construction, and no
secret can reach the browser, because the browser never contacts a tile server directly.
See [Build](build.md#everything-goes-through-the-proxy).

## Asking the service what it is

Most of what makes a hand-written TSD wrong is published by the service itself, and reading it
costs one request and no imagery. An ArcGIS MapServer answers `?f=json` with its levels of
detail, its scale limits, its tile format and its spatial reference; a WMTS answers
GetCapabilities with the layer, the tile matrix set that names its ceiling, its formats and its
access constraints. Between them that covers most services worth probing.

The probe settles, without fetching a tile: **is the url template right, is the row order
flipped, is a credential needed, what format is really served, and how deep does the service
admit to going.**

**The findings are shown beside what the file says, and disagreements are listed as
disagreements.** Nothing is applied. Several of them have a legitimate answer of "the file is
right and the service is being modest" - a `zoom.max` *below* the ceiling is a deliberate
choice, not an error - so the list is for a person to read. A probe that quietly rewrote the
file would make every TSD a cache of a server's current mood.

The one rule that makes an ArcGIS answer usable rather than merely present: **a `maxScale` of
zero, or one that resolves to the deepest level the cache holds, declares nothing.** Zero is
the unset sentinel and the other says only "as deep as I go". Any other value is a genuine
statement and is the answer.

**Row order is the failure that looks like success.** Every tile arrives, every tile is real
imagery, and the map is scrambled. Esri's REST convention is row before column; a WMTS
publishes its own template and the order can be read straight out of it.

**What no metadata document answers is whether there is imagery *here*.** Sparse coverage means
an honest ceiling of z12 does not imply a tile at every z12 square. That is a placed question
and a different act - see [Build](build.md). Where the ArcGIS family offers `/tilemap/`, it is
the cheapest form of that answer anywhere in the application: the presence of a whole block of
tiles in one request and no imagery, where asking tile by tile would be hundreds. A fully
covered block is answered by omitting the array and saying only `valid`, a compression that
reads as an *empty* block to anyone who did not know - which is the worst possible way to be
wrong about coverage.

## Authoring and testing a source

Sources rot. Endpoints move, terms change, and services retire, so the ability to find out
*which* source broke matters as much as the ability to add one.

**Authoring itself is [the editor](tsd_editor.md)**, which writes these fields and enforces
the validation rules above. A source can also begin from [the catalog](catalog.md), either
written straight to disk or handed to that same editor to be finished - and a service that
publishes a capabilities document can be asked for its own layer list rather than having one
transcribed. Both routes end at the editor's rules; neither is a second way to write a file.

What follows is what a source can be asked about a live service, which is a separate act and
is not a precondition of writing one.

**TEST_FETCH.** Paste a template, fetch one tile at the current view, look at it. This
turns "did I get the URL right" from a twenty-minute debugging session into two seconds.
Behind it: format detected from magic bytes, tile size read from the image header, and
failures distinguished from one another - 403 is not 404 is not 200-with-a-blank-tile.

For the single most common authoring error, TEST_FETCH renders `{z}/{x}/{y}` and
`{z}/{y}/{x}` side by side and lets the user click the coastline that looks right. Row and
column order is reversed between major services, and every guide on the internet has to
warn about it.

**The evaluator - "show me every source here."** Pick a location; chartMaker fetches one
tile from each known source at each source's declared ceiling and shows them side by side
with resolution and license. The user judges with their eyes, because "is this imagery
useful here" is a visual question that no metadata answers. It generalises TEST_FETCH, it
is neutral about what it evaluates, and it is the honest answer to a catalog of hundreds of
layers with no way to tell which one is worth anything in your bay.

**It is the one-tile version of what the probe does over an area.** The
[probe](build.md#the-probe) samples one source across a range of levels and reports whether it
answers, whether what it returns is imagery, and whether depth buys anything; the evaluator asks
the same of every source at one spot and one level, and shows the tiles rather than the counts.
Both exist because the same question has two useful shapes: **which source**, answered by eye
in a second, and **how deep**, answered by a survey that takes minutes.

The per-source result it produces - answered, refused, absent, blank - is the same status a
health pass over all sources writes, and it is shown in both the source list and the map's
layer palette.

## The cache is keyed by source

A tile coordinate means something different in every source, so the cache carries a source
dimension and the layout is specified in
[Deployment](../deployment.md#the-tile-cache-is-not-temporary). It is keyed by
**`cache_key`**, which defaults to the leaf name of the `.tsd` file rather than the `id`
inside it, so that a user looking at the cache in a file browser sees one folder per source
they have used and can delete exactly one of them.

**Three names, three jobs.** The `id` is what a region points at. The **filename** is the
container, and a container should be free to rename, copy and back up. `cache_key` names the
**tiles**, which are the expensive and persistent thing either of the other two refers to.
Until it could be declared it was only a shadow of the container, so renaming a file stranded
its tiles and every saved variant of one source began a fresh cache.

**Declaring one is an assertion** that these files address the same service - the same
species of statement as `uses` and `redistributable`. An edit in progress, a backup, or a
variant differing only in `uses` should all reach the same tiles.

**Two files sharing a key with different urls are refused at load**, and the later one
alphabetically does not become a source. This is the one assertion in the format that is
guarded rather than trusted, because getting it wrong produces exactly the failure the
cache's source dimension exists to prevent: tiles fetched through one file handed out as
though they came from the other, in a build that looks complete and contains the wrong
imagery. A warning would leave that possible.

The comparison is exact, so two spellings of one service - with and without `{s}`, or naming
a different subdomain host - are refused even though they would have agreed. That direction
is deliberate. A refusal costs one edit and states its reason; the other error silently
poisons a cache that nothing afterwards can tell is wrong.

## The rules live in one place

The validation rules in this document are enforced by `dm_source` and by nothing else. One
statement of what a TSD may be, in code, described here, so there is nothing maintained
alongside it that could drift out of agreement with it.

## What chartMaker ships

Four sources, with **`gibs_weld_annual` as the official default** - it is the imagery a new
region is born naming, and the source the tutorial and the demonstrations are built on.

| id | reaches | `uses` |
| ------------------- | ------------------------------------- | ---------------- |
| `gibs_bluemarble`   | z8                                    | display, build   |
| `gibs_weld_annual`  | z12                                   | display, build   |
| `esri_world_imagery`| answers to z23, real detail varies    | display          |
| `google_satellite`  | answers to z21, real detail varies    | display          |

The two GIBS sources satisfy the rule that chartMaker ships no source it is not entitled to
ship: both are US Government works, and their URL templates are verified by a test rather
than assumed. `gibs_weld_annual` is the default rather than Blue Marble because it reaches
z12 against z8, and depth is the whole point of a chartset.

**The other two ship for display only, and that split is the whole reason they can ship at
all.** Esri's terms grant anyone the right to view, download and copy their published
services for internal or noncommercial purposes, and separately govern bulk export into a
product through a different, authenticated service. Those are two distinct permissions and a
source file can sit squarely inside the first.

**Google's `/vt` occupies a different position, and its file says so rather than leaving it
to be assumed.** It is an undocumented endpoint that no published terms cover, and the
policies Google does publish for its map products forbid pre-fetching, bulk downloading and
offline use - a description of building a chartset rather than of drawing a map. So it ships
as `display` with `redistributable: no`, and its `notes` record what it is. Being
undocumented it carries no deprecation notice either, so one day it will fail as a 403, a
redirect or a placeholder rather than as an announcement.

**Shipping a TSD is not shipping imagery.** It is a URL and a set of field values describing
a public endpoint, and it conveys no right to anything to anybody. The terms bind whoever
operates the client, which is exactly what `uses` records - the shipped value states what a
file is shipped *for*, and a user who reads the terms differently changes one field and owns
that reading. The application does not hold a legal opinion on the user's behalf.

**So what ships now separates the two questions that used to be one.** Deep imagery is
visible out of the box; the sources that may be *built* from out of the box remain shallow.
That is the honest shape of the boundary rather than a limitation to apologise for: what
ships is a starting point that works, not a recommendation and not a ceiling. A tutorial set
still has to be authored well below the zooms the region editor offers by default.

`esri_world_imagery` is also the first shipped source to carry an
[`absent_fingerprints`](#a-200-that-means-404) entry. Past the depth it actually holds, the
service stops upsampling and returns a fixed grey "no data" image rather than a 404, so
without the fingerprint that picture would be cached as imagery and baked onto a card.

`google_satellite` is the opposite case and carries none, because none is possible. It
never answers 404 and never sends a fixed image, so it magnifies its own imagery
indefinitely and every tile is distinct. Nothing declared in a file can catch that, which
is why depth there is a matter for the eye and for [Build](build.md).

---

**Next:** [TSD Editor](tsd_editor.md)
