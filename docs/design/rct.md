# chartMaker - RCT

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**RCT**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

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

## Still to specify

- **JPEG only** - and therefore what happens when a source returns a PNG. The transcode is
  the exporter's, not the cache's: the cache stores what the source sent.
- **Which source a region builds from.** The exporter reads whichever source is active,
  which is right for one card from one provider and wrong the moment a detail area needs a
  different one. The model says a region and a subregion each carry a `source`; the field
  is not implemented yet.
- **Why the card is smaller than the model** - depth caps are applied at export, so one
  deeply built region produces cards of several sizes with no additional fetching.

---

**Next:** [Implementation](../implementation.md)
