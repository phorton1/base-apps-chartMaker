# chartMaker - TSD

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**TSD** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

A **TSD** (*Tile Source Definition*, extension `.tsd`) describes exactly one imagery
source. [Architecture](../architecture.md#tile-source-definition-tsd) says why the format
exists and what it refuses to be; this document is the field reference.

TSD files live in `$data_dir` and are found by scanning it, so installing a source somebody
sent you is a matter of putting the file in the folder.

## Field reference

```
    tsd_version:      1
    id:               a stable identifier, referenced by regions
    name:             what a person calls it
    notes:            free text
    kind:             remote_xyz | local_mbtiles | local_dir | wms
    url:              template, for the remote kinds
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
```

| Field             | Notes                                                                      |
| ----------------- | -------------------------------------------------------------------------- |
| `tsd_version`     | Format version.                                                            |
| `id`              | Stable. Regions reference it; renaming the file does not change it.        |
| `kind`            | Determines which of the remaining fields apply.                            |
| `url`             | Template. Substitutes only from the closed placeholder set below.          |
| `tile_format`     | What the source is expected to return. The actual format is detected.      |
| `tile_size`       | Must be 256. Anything else is rejected at import.                          |
| `crs`             | Must be `EPSG:3857`. Anything else is rejected at import.                  |
| `zoom.max`        | The highest zoom the **server will answer at all**, not where detail ends. |
| `attribution`     | Mandatory and non-empty. A file without it does not load.                  |
| `redistributable` | The author's assertion. Propagates into built output as metadata.          |
| `uses`            | What the source is FOR. Not "what it uses" - see below.                    |
| `absent_fingerprints` | The bytes a server sends INSTEAD of saying no. Read as absences.       |
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
signature or a session-token derivation. That is a guarantee enforced by the schema rather
than a promise made in a document, and it is what makes a file received from a stranger
data being read rather than code being run.

## Validation

A TSD is **JSON with a published JSON Schema**, chosen over a looser format precisely
because these files circulate between people who do not know each other. The schema is both
a validator and a machine-checkable statement of what the format is *able* to say.

Rules that cause a file to be rejected:

- `attribution` missing or empty.
- `tile_size` other than 256, or `crs` other than `EPSG:3857`.
- A placeholder in `url` that is not in the closed set, or a credential placeholder for a
  slot the file does not declare.
- Any field the schema does not define.

`notes` exists because JSON has no comments and these files are read by people.

## Protocol is declared, data is discovered

The rule that settles most schema arguments before they start. A **protocol** fact is true
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
cache.

**Declared, not detected.** It is a fact about a server, and this file is where facts about
servers live. A probe can *discover* one - fetch over ground known to be empty and watch for
byte-identical repeats - but the file is what remembers.

Note what this is **not**: it does not detect a source that magnifies its own imagery past
where real detail ends. That produces genuinely different bytes every time and is a fact
about ground rather than about a server. See [Build](build.md) on where that is measured.

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

## Authoring and testing a source

Sources rot. Endpoints move, terms change, and services retire, so the ability to find out
*which* source broke matters as much as the ability to add one.

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

The per-source result it produces - answered, refused, absent, blank - is the same status a
health pass over all sources writes, and it is shown in both the source list and the map's
layer palette.

## The cache is keyed by source

A tile coordinate means something different in every source, so the cache carries a source
dimension and the layout is specified in
[Deployment](../deployment.md#the-tile-cache-is-not-temporary). It is keyed by
the **leaf name of the `.tsd` file** rather than the `id` inside it, so that a user looking
at the cache in a file browser sees one folder per source they have used and can delete
exactly one of them.

## The schema is the code

**There is no published JSON Schema artefact.** The validation rules in this document are
the schema, enforced by `dm_source`, and nothing is maintained alongside them that could
disagree with them.

## What chartMaker ships

Two NASA GIBS sources, with **`gibs_weld_annual` as the official default** - it is the
imagery a new region is born naming, and the source the tutorial and the demonstrations are
built on. Both satisfy the rule that chartMaker ships no source it is not entitled to ship:
both are US Government works, and their URL templates are verified by a test rather than
assumed.

`gibs_weld_annual` is the default rather than Blue Marble because it reaches **z12** against
Blue Marble's **z8**, and depth is the whole point of a chartset. Both are far shallower than
a commercial mosaic, which is the honest shape of the boundary: what ships is a starting
point that works, not a recommendation and not a limit. It also means a tutorial set has to
be authored well below the zooms the region editor offers by default.

---

**Next:** [Build](build.md)
