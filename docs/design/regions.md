# chartMaker - Regions

**[Design](readme.md)** --
**Regions** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

The coverage model is the product, and this is the coverage model on disk. It is a small
format on purpose: it has to survive being refined for years, handed to a stranger, and
read by a program that will be written after it.

## The region is the unit of exchange

**One region, one file.** A region file is entirely self-contained - it holds its own
geometry, its own identity, and all of its detail areas nested inside it. It refers to
nothing outside itself: no parent in another file, no imagery source, no path on the
author's disk.

That is what makes a region shareable without conditions. Handing someone a region file
hands them a complete, usable description of a piece of coastline and nothing else - not
your endpoint, not your credentials, not your checkbox state. It is also what makes the
alternative unattractive: a single large file describing every region would be one
author's document rather than a set of exchangeable pieces.

## The region file

```
    region_version:   1
    id:               bocas
    name:             Bocas del Toro
    notes:            free text
    canonical_zoom:   15
    geometry:         [ <polygon>, <polygon>, ... ]
    subregions:
      - id:             bocas_town
        name:           Bocas Town approaches
        canonical_zoom: 17
        geometry:       [ <polygon> ]
        subregions:     [ ... ]
```

| Field            | Meaning                                                               |
| ---------------- | --------------------------------------------------------------------- |
| `region_version` | Format version, so a future reader knows what it is holding.          |
| `id`             | Stable identifier. Referenced by sets; unaffected by renaming.        |
| `name`           | What a person calls it. Free to change at any time.                   |
| `notes`          | Free text. The format is JSON and JSON has no comments.               |
| `canonical_zoom` | The zoom at which this area's polygon meets the tile grid.            |
| `geometry`       | One or more polygons in WGS84 decimal degrees.                        |
| `subregions`     | Zero or more regions nested inside this one, recursively.             |

**A subregion is a region.** Same fields, same rules, nested. A subregion is simply a
smaller area within its parent that deserves more detail than the parent as a whole, and
there may be any number of them. Because the structure is recursive, a subregion may itself
contain a subregion - a square nautical mile at z17 with a single dock inside it at z20 is
unusual but expressible, and nothing special is needed to say it.

**Subregion ids are unique within their file only.** Nothing outside a region file ever
refers to a subregion, so there is no global namespace to collide in and no renaming
required when two people exchange regions.

**A region's geometry is one or more polygons, and this is not a generalisation for its
own sake.** Bocas del Toro is a main body plus a detached area fifteen miles east; San Blas
has a separate sliver. They are one region because they are one thing to the person who
drew them. The alternatives both fail: separate regions lose the grouping, and subregions
lose the coverage outright, since a subregion at its parent's canonical zoom has an empty
band and contributes nothing.

**There are no holes**, and not as a simplification. Coverage is a union and never
subtracts, so an inner ring could not mean anything. A KML import ignores them for exactly
that reason rather than as an omission.

**The geometry itself is zoom-independent.** A polygon is an outline on the earth, not a
set of tiles, and it is stored exactly as it was drawn - free coordinates in decimal
degrees, never snapped to anything.

`canonical_zoom` is a number attached to that geometry rather than a property of it. It
says **where the polygon meets the grid**: the one zoom at which the outline is quantised
into tiles. Everything else chartMaker knows about this area's coverage is derived from
that one tile set.

The editor shows the consequence rather than imposing it: **the tile footprint is drawn at
the zoom being viewed.** That keeps it legible, since a tile is about 256 pixels on the
screen at any zoom, and it keeps it honest, since the outline really is the coverage at the
zoom being looked at. Zoom in and the staircase along the boundary refines. It is the same
outline [preview](build.md#editor-and-preview-are-one-component-in-two-modes) clips to.

## How coverage is derived

The polygon is used exactly once, at `canonical_zoom`, to produce a set of tiles. After
that the polygon is out of the picture and everything follows from the tile set.

**Coverage is the union of the included canonical tiles, not the polygon.** That
distinction is the whole of what follows.

**Going coarser: the parents.** For any zoom above the canonical one, coverage is the
parent tiles of the canonical set. This happens to be identical to intersecting the polygon
at that zoom - a parent contains its child, so if the child meets the polygon the parent
does; and a coarse tile is exactly tiled by its descendants, so if it meets the polygon at
least one descendant does. The two rules cannot disagree, and taking parents is both
cheaper and makes the nested-fallback property self-evident.

The rule that has to be applied consistently is **positive-area intersection**. A polygon
edge lying exactly along a tile boundary is where two implementations of "does it intersect"
give different answers, and that is precisely where seam tiles go missing.

**Going finer: the fill.** Below the canonical zoom, coverage is the *complete* set of
children of each included tile - not the tiles that intersect the polygon. A canonical tile
is included because the polygon touches it, so the chart already claims that whole tile;
leaving out the children that miss the polygon would put a resolution cliff inside an area
the chart says it covers.

**Each level owns only the band its parent does not reach.** Because a subregion lies
inside its parent, the subregion's tiles at the parent's canonical zoom are already in the
parent's set, so the subregion contributes nothing there or coarser:

```
    region     canonical z15  ->  z15, and its parents up to the output's shallow limit
    subregion  canonical z17  ->  z16 and z17 only; z15 and coarser belong to the parent
    sub-sub    canonical z20  ->  z18, z19, z20
```

Nothing enforces that partition - it falls out of containment. It is also why a subregion
whose canonical zoom equals or undercuts its parent's is harmless: its band is empty, so it
contributes nothing, which is what "meaningless, not harmful" means arithmetically.

## Depth is requested here and capped elsewhere

`canonical_zoom` says what an area **deserves**, not what any particular output will
contain. Three things have an opinion about depth, and they are deliberately different
kinds of thing:

| Source of the opinion | What it says                              | Force        |
| --------------------- | ----------------------------------------- | ------------ |
| the **region**        | quantise this area at z17                 | a request    |
| the **target**        | this output stops at z15                  | a hard cap   |
| the **imagery**       | this source has real detail to about z16  | advisory     |

**The built depth is `min(region, target)`.** The imagery's real resolution never enters
that calculation. A source that upsamples past its native resolution still produces tiles
worth carrying - a plotter is perfectly happy with them, and the alternative is a chart
that stops abruptly at a boundary the user cannot see. So the application warns and builds.

What the imagery does affect is what actually lands in the output: a tile the source does
not have is simply absent. The model says which tiles are wanted, the source decides which
exist, and **preview is the only place those two meet before a build** - a tile missing in
preview is a tile that will be missing on the card.

The reason for the split is a requirement that no single number can express: the same
geography needs to be built at different depths for different destinations. A plotter with
a small card wants a shallow chartset of Bocas; a unit with room to spare wants a deep one.
One region, two targets, two cards, and no duplicated geometry.

It also produces a property worth stating out loud: **build deep once, export shallow as
often as you like.** The tiles are already in the cache, so the small card costs no
additional fetching at all.

Targets themselves are specified in [Build](build.md).

## Containment, overlap and the invariant they buy

**A subregion lies within its parent**, and the application maintains that rather than
merely checking it. Which side gives way depends on which side was edited:

- **Drag a subregion outside its parent** and the parent expands to contain it.
- **Shrink a region** and any subregion now outside it is clipped to the new boundary, or
  removed entirely if nothing of it remains inside.

Shrinking is uncommon and it destroys work, so it **asks first**, naming what will be
clipped and what will disappear. The rule applies at every level: a subregion that shrinks
clips its own children exactly as a region clips its subregions.

Containment is what the card format ultimately depends on. Because a subregion lies within
its parent, every tile the subregion covers has a coarser tile above it that the parent
already covers - the **nested-coverage invariant**, which is what lets a plotter fall back
gracefully from a detailed tile it does not have to one it does. It holds by construction
rather than by checking, which is why the geometric rule is worth enforcing at edit time
instead of validating at build time.

**Where regions overlap, ownership is a union rather than a contest.** A tile that two
regions both want appears in both. Duplicate tiles at a seam are harmless downstream - they
are byte-identical when the source is the same - and the alternative, deciding which region
owns a boundary tile, is how tiles go missing at precisely the boundaries where a mariner
is most likely to be looking.

Overlap between siblings needs no special handling for the same reason. Two adjacent
subregions at the same canonical zoom will produce the same parent tiles in their shared
band, and the union absorbs it.

### Regions that touch

Two regions that abut share a boundary, and the model has no opinion about it: each holds
its own copy of those vertices, and rasterisation puts the same tiles in both. Overlap is
free and a duplicate tile is harmless, so nothing needs to agree.

**Editing is where it stops being free.** If a shared boundary is two independent copies of
the same line, then dragging a vertex in one region opens a gap in the other - and a gap is
the one failure the union rule cannot absorb, because coverage that nobody claims simply
is not built. So the editor has to treat coincident vertices on touching regions as **one
vertex, moved in both regions at once**, and that means an edit is not always confined to
the region under the hand.

This is a requirement on the editor rather than on the format. Nothing is written into a
region file to record that a neighbour shares a vertex; the editor finds coincidence
geometrically at the time of the drag. Recording it would be a cross-file reference, and a
region that names its neighbours stops being self-contained - which is the one property the
whole format is built to preserve.

### Boundaries land on the grid

**A shared boundary falls on a tile edge at the lesser of the two regions' canonical
zooms.** A vertical boundary is one longitude, a horizontal one is one latitude, and that
value is a tile edge on the coarser of the two grids.

The reason it must be the *coarser* grid is that a tile edge at one zoom is also an edge at
every finer zoom. Align to the finer region and the boundary still cuts a coarse tile in
half, which is the thing being avoided.

What it buys is not correctness - union ownership prevents gaps wherever the boundary
falls. It is **duplication**: a boundary that runs through a tile puts that tile in both
regions, so it is fetched once but shipped twice, once in each output. On a card measured
in megabytes that is the difference worth having.

This does not contradict geometry being stored as drawn. That rule forbids the application
quantising a polygon behind the author's back; deciding to put a boundary on a grid line is
a drawing decision, and "snap this boundary to the grid" is an editor command like any
other.

**Welding a boundary never changes coverage.** Moving a shared line moves the division
between two regions, not the outer extent of their union, and the union is what reaches the
water.

**Open: three or more regions meeting at a point.** Each pair of them constrains the
junction to its own grid, and those constraints can be jointly unsatisfiable - a point
cannot sit on two different vertical tile edges at once. Nothing here solves that, and
nothing in the current model needs it.

## What a region file does not contain

Each of these is absent for a reason, and each was considered:

- **No `zmin`.** Overview levels are a property of an output - a card wants them, the
  mbtiles hub may not - so the shallow end of the range belongs to the target.
- **No source.** A region says where and how deep, never from what. The same region built
  from two sources is the same region.
- **No view state.** Whether a region is currently shown on the map is a fact about a
  workspace, not about the region. See below.
- **No parent reference.** Nesting is expressed by the file structure, so a region file can
  never refer to a parent the recipient does not have.

## The workspace

chartMaker has **no project files and no File menu**. There is one workspace, it is
`$data_dir`, and it is opened at startup.

That follows directly from the region being the unit of exchange. Open, Save As, recent
files and unsaved-changes prompts exist to move documents between people and places; if the
thing people exchange is a region file, the container around it never needs to travel, and
none of that machinery earns its place. The coverage model is refined over years - it is a
body of work, not a document.

**Existence comes from the folder.** `$data_dir` is scanned for region files exactly as it
is scanned for [TSD](tsd.md) files. Dropping a region somebody sent you into the folder is
how you add it. There is no index to keep in agreement with the disk, and therefore no
class of bug in which the two disagree.

The workspace index holds only what a folder scan cannot answer:

```
    sets:
      working:  [ bocas, popa00 ]
      helm:     [ bocas ]
    default_source:  <tsd id>
```

## Sets

A **set** is a named list of region ids - the answer to "what travels together." It is the
scope in which the containment and overlap rules matter, because that is the only time two
regions' tiles land in the same output.

**The working set is the one you are looking at.** The checkbox column in the region tree
is its membership, and nothing more: checking a region adds it to the working set, which
makes it visible on the map. Saving that as a named set is then a naming operation rather
than a new concept, and a target names a set rather than inventing its own idea of
membership.

This is why visibility is stored as membership in the workspace rather than as a flag on
the region. A flag on a region would allow exactly one possible view forever, and would put
one user's view state inside a file meant to be handed to somebody else. Membership in a
list generalises for free, and deleting a region removes its membership along with it -
there is no separate visibility store to reconcile, and nothing to prune.

A region found in the folder but named by no set is simply not in the working set. It
appears in the tree unchecked.

## Open questions

- **Targets** are named above but not yet specified. What a target contains, where it is
  stored, and how it is edited are open. See [Build](build.md).
- **How far the fill goes.** One level below the canonical zoom is what the predecessor
  did - z15 quantised, z16 filled. Whether that one level is a constant, a per-region
  number, or the target's business is the last place "how deep" is still ambiguous. The
  working assumption is one level, bounded by the target's cap.
- **Selection.** Exactly one region or subregion is selected at a time, or none, and it is
  view state rather than model. What a click on the map selects where polygons nest is open:
  innermost-containing is the obvious rule, but it leaves a parent unclickable wherever a
  child covers it, so there has to be a way to walk up.
- **Set management UX.** The working set needs none beyond the checkboxes. Named sets need
  save-as, rename and delete, which arrive with targets.

---

**Next:** [TSD](tsd.md)
