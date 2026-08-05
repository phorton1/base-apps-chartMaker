# chartMaker - RCT

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Key Store](key_store.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**RCT**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

**`.RCT` is exporter number one.** The aerial photo overlay in the custom E-Series firmware
built by [navMate](https://github.com/phorton1/base-apps-navMate/blob/master/docs/readme.md)
reads a purpose-built on-card raster format: one `.RCT` file per region, under `\RASTER\` on
a CF card. A card is a deployment artifact rather than a source of truth - it is
regenerated, never edited.

**The byte format is not specified here.** It is specified by its own document, in the
repository that owns the consumer, and that document is normative. This page says only what
is *chartMaker's* side of the contract: which guarantees the build makes, how the exporter
decides what to emit, and the two constraints that are visible from the producer's side and
from nowhere else.

## The set is the file set

There is no manifest and no index file. The renderer enumerates `\RASTER\` for `*.RCT` and
merges every file it finds into one fused pyramid keyed by zoom level, so a region is not
something the plotter selects between - after the merge, only tiles and their zoom levels
remain.

Two consequences for the exporter, and both are liberating rather than restricting:

- **Adding coverage is a filesystem act.** Any subset of the files is a valid card. There
  is nothing to keep in sync and nothing to regenerate when a region is added or removed.
- **Blocks from different files may overlap, and will.** Two regions covering adjacent
  ground carry identical coarse parents at shared levels by construction. The exporter must
  not try to make them disjoint; the duplication is expected, and the renderer resolves it
  by testing presence rather than by finding the block whose rectangle contains a tile.

Within *one* file at one zoom, blocks must not overlap. That is the exporter's obligation
and it is the only disjointness anyone needs.

## What the build guarantees

The producer contracts in the format spec are not extra work: they are the model in
[Regions](regions.md#zauthor-zmin-and-zmax) restated from the consumer's side.

| The spec asks for | The region model already says |
| ----------------- | ----------------------------- |
| parents complete from `zoom_min` to `zoom_author` | coverage derives coarser levels as parents of the authored set, down to `zmin` |
| children complete from `zoom_author` to `zoom_max` | the region is complete over `[zauthor..zmax]` |
| a sub-region fills from the parent's `zoom_max + 1` | the band rule - a level supplies `parent.zmax + 1` up to its own `zmax` |

The one thing worth restating in the consumer's own terms is **why** completeness over
`[zauthor..zmax]` cannot be traded away. The plotter cuts its reveal aperture from the
polygon at `zauthor` and paints at whatever level the view scale calls for. The painted set
must therefore be a superset of the revealed set at every level the card carries. A
partially populated level opens an aperture onto ground that nothing painted.

## Two constraints only chartMaker can see

Neither of these appears in the format spec, and neither is an omission there: both are
facts about the producer's side of the boundary, which the consumer has no window onto.

**The reveal aperture is a rectangle budget, and it is card-wide.** The firmware describes
the aperture as a list of screen rectangles, closing one run per tile row with no vertical
merging - and it builds that list over the *fused* set, so every file's blocks at the
authored level draw on the same budget. Overflow is not a crash: the overlay reveals the
whole plane, which spills imagery past the polygon at wide views. Two things follow. `z15`
is the authored level with comfortable margin for regions of this size, measured rather than
guessed. And because runs are closed at block edges as well as at absent cells, **block
fragmentation spends rectangles out of the same budget as the polygon's own raggedness** -
so the exporter emits few, large blocks, and a deep-detail area is one block rather than
several.

That pulls against the spec's own decomposition economics, which say a split pays whenever
it removes more than about six empty cells. Where the two disagree, prefer fewer blocks: the
disk cost of an empty cell is eight bytes and the cost of an exhausted rectangle budget is
the whole feature degrading to its pre-aperture behaviour.

**The card file name must be a genuine 8.3 short name.** The renderer's mount scan accepts
an entry whose name ends in `.RCT`, relying on the filesystem reader handing back an
upper-cased name - which is true of names that are valid FAT short names. Whether a longer
or mixed-case name survives that path is a property of how the file was *written to the
card*, on the other side of a boundary the firmware cannot see. chartMaker is the only party
in a position to guarantee it, so the exporter asserts it: the stem is the region id, at
most eight characters, alphanumeric. A build that cannot satisfy that fails rather than
producing a card whose file names depend on Windows' `~1` numbering.

This is also why the region id is restricted to `[A-Za-z0-9]` and is a field of its own
rather than a slug of the name - see [Regions](regions.md#the-id-is-structural).

## How blocks are chosen - there is no clustering heuristic

The budget above wants few, large blocks wrapping real clusters of tiles, and the obvious
reading is that something has to *find* those clusters. It does not. The authoring
structure already knows them:

**One block per node, per zoom.** The region contributes one block at each level of its own
band; each subregion contributes one at each level of the band only it reaches. Since a
subregion's band starts above its parent's `zmax`, the two never appear at the same level,
and a level that only a detail area reaches contains only that area's small rectangle.

That falls out of the [band rule](regions.md#how-coverage-is-derived) rather than being
imposed on top of it, which is why the coverage enumerator reports each node's own tiles
separately as well as merged - the merge is what a build walks, and the per-node answer is
what the exporter needs. Both come from one walk, so they cannot disagree.

The consequence worth stating: **block structure is an authoring decision, not an
algorithm.** If a region ends up with an expensive block, the fix is a subregion, in the
same place a person would have drawn one anyway.

## One block is one node, so one block has one source

A region and each of its subregions may name a different source, and the exporter honours
that without any per-tile bookkeeping: a coverage block *is* one node's tiles at one zoom,
so the source a cell is read from is a property of the block. A detail box built from a
different provider than the ground around it costs one field on the block and no lookup in
the loop that runs nine thousand times.

The exporter is handed **resolved source objects**, keyed by depth and id, and never turns
an id into a source itself. Whether a source is installed, whether it may build, and whether
this format can carry its tiles are three questions the build answers before the exporter
runs - see [Build](build.md#what-the-build-validates-before-it-runs).

## The attribution blob

Each `.rct` carries the credit text for the imagery in it, located by `attrib_offset`
(`0x38`) and `attrib_length` (`0x3C`) and written after the tile data. The byte-level
contract is normative in `Pub/Ray/docs/e80_firmware/deployment/raster_chart_format.md`; what
belongs here is what the *producer* decides.

**It is per file, not per card** - the one place it differs from `zauthor` and `zmin`. Those
are properties of the chartset because the firmware fuses every file into one pyramid; a
credit is a property of the imagery in this region, and a region may legitimately be built
from a different source than the one beside it. So each file carries the distinct credits of
the sources its own tiles came from, in walk order, deduplicated.

**Placing it last is what makes it free.** Variable-length data anywhere earlier would move
the zoom directory, whose position is a compiled-in constant in the consumer. At the end,
nothing else in the layout moves - which is demonstrable rather than merely argued: adding
it to the Bocas card grew the file by exactly the length of the credit and changed **five
bytes** of the original 70 MB, all of them inside the `0x38` field.

`0`/`0` means no attribution, which is also exactly what a card written before the field
existed reads as, since `0x38` was reserved-zero. That indistinguishability is why the
format version does not move.

**chartMaker transliterates rather than strips.** The blob is 7-bit ASCII plus LF because
the eventual consumer is a firmware font renderer, and a credit that arrives as UTF-8 has to
become ASCII somewhere. Dropping the offending bytes is worse than it looks - a stripped
copyright sign leaves `Imagery  Google`, and a stripped accent turns `Jose` into `Jos` - so
the symbols are spelled out (`(c)`, `(r)`, `(tm)`) and accented letters fall back to their
base forms. A credit line is the one piece of text on a card somebody may have a legal
interest in being legible.

## JPEG only, and PNG converted into it

An `.RCT` carries JPEG. A card full of bytes the plotter cannot decode would report success
and be blank on the water, which is the worst failure this application can produce, so what
goes into the file is checked per tile against the format the cache **detected from the
bytes** rather than against anything a `.tsd` declared.

A tile that arrives as PNG is **decoded and written back out as JPEG on the way in**. That
is an encoder, not the image-processing stack this application refuses: the same 256 pixels
of the same ground, in a container the plotter can read. Nothing is resampled, reprojected
or composited, and no pixel is examined.

**The conversion belongs to the exporter and not the cache.** The cache stores what the
source sent, and the format a card needs is a property of the card. A build that wrote
converted bytes back would turn the cache into a record of what was last built rather than
of what was served, and a second output format would then inherit the first one's
compromises.

**Quality is a preference, and it reaches only converted tiles.** A tile that arrived as
JPEG is copied byte for byte and no setting can touch it. The default is 90; measured
against a service that answers the same ground as both formats, that writes a card about
1.5x the size a natively-JPEG source produces, with byte-for-byte parity near 80. A PNG
also costs about 7.5x the JPEG on the wire and in the cache, for identical ground, which
is worth knowing when a service offers a choice of address. It is a preference because it
changes the bytes without changing what the card asserts - the same ground, the same zooms,
the same source. Anything that changed those would belong to the region.

**The decoder is optional and a card is not.** Conversion needs an image decoder installed;
where there is none, a source that declares PNG is refused before a build starts rather
than an hour into one, and a source that declares JPEG and turns out to serve PNG is
refused by the per-tile check. Both refusals name the format and say that nothing could
convert it. See [Build](build.md#what-the-build-validates-before-it-runs).

## The card is smaller than the model, and costs nothing extra

Depth caps are applied at export, so one deeply built region produces cards of several sizes
from one set of tiles. Building shallow after building deep fetches nothing at all.

---

**Next:** [Implementation](../implementation.md)
