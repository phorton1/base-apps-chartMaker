# chartMaker - Regions

**[Design](readme.md)** --
**Regions** --
**[Editing](editing.md)** --
**[Map Editing](editing_leaflet.md)** --
**[Tree Editing](editing_wx.md)** --
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
    region_version:   2
    id:               Bocas
    name:             Bocas del Toro
    notes:            free text
    zauthor:          15
    zmin:             10
    zmax:             16
    geometry:         [ <polygon>, <polygon>, ... ]
    subregions:
      - id:           Popa00
        name:         Popa anchorage
        zmax:         18
        geometry:     [ <polygon> ]
        subregions:   [ ... ]
```

| Field            | Meaning                                                               |
| ---------------- | --------------------------------------------------------------------- |
| `region_version` | Format version, so a future reader knows what it is holding.          |
| `id`             | Stable identifier. Referenced by sets; the file name; the card stem.  |
| `name`           | What a person calls it. Free to change at any time.                   |
| `notes`          | Free text. The format is JSON and JSON has no comments.               |
| `zauthor`        | The zoom at which this region's polygon meets the tile grid.          |
| `zmin`           | The overview floor - the coarsest level the region carries.           |
| `zmax`           | The finest level the region itself carries.                           |
| `geometry`       | One or more polygons in WGS84 decimal degrees.                        |
| `subregions`     | Zero or more detail areas nested inside this one, recursively.        |

**A subregion is NOT quite a region: it has `zmax` alone.** No `zauthor`, no `zmin`. A
region's authored level is the level its outline is cut at, and that outline is what the
plotter opens its aperture to. A subregion never cuts an outline - it sits inside an
aperture its parent already opened, purely to add resolution - so it has no authored level
to carry and no floor of its own. It quantises its own polygon at its own `zmax` and that
is the whole of it. Everything else is shared: same geometry rules, same recursion, so a
square nautical mile at z18 with a single dock inside it at z20 is expressible and nothing
special is needed to say it.

### The id is structural

**The id carries load and the name does not.** The id is the file name, the key every
[set](#sets) references, and the stem of the exported [card file](rct.md). It is therefore
restricted to `[A-Za-z0-9]` - no spaces, nothing that would have to be escaped somewhere,
and the somewhere is never all the places.

Ids are compared **case insensitively** but stored **with the case the author wrote**, which
is exactly what the filesystem underneath does. `PortBelo` and `portbelo` cannot be two
regions because they cannot be two files. The convention is CamelCase and short - `Bocas`,
`PanCanal`, `PortBelo`, `SanBlas`, `SanBlasE` - because eight characters keeps the card file
name a genuine FAT short name.

**The id is not derived from the name.** A new region and a KML import both *suggest* one by
CamelCasing the name, and the author is expected to shorten it. `SanBlasE` is not a slug of
"San Blas East"; it is a decision, and a field that can hold a decision is the only kind
that works. Changing an id afterwards moves three things that must move together - the file,
the key, and every set that names it - which is why it is one operation rather than an
edit.

The **name** is free text with no structural role at all. Renaming is the cheap operation.

**Subregion ids are unique within their file only.** Nothing outside a region file ever
refers to a subregion, so there is no global namespace to collide in and no renaming
required when two people exchange regions.

**A region's geometry is one or more polygons, and this is not a generalisation for its
own sake.** Bocas del Toro is a main body plus a detached area fifteen miles east; San Blas
has a separate sliver. They are one region because they are one thing to the person who
drew them. The alternatives both fail: separate regions lose the grouping, and subregions
lose the coverage outright, since a subregion at its parent's `zmax` has an empty band and
contributes nothing.

**There are no holes**, and not as a simplification. Coverage is a union and never
subtracts, so an inner ring could not mean anything. A KML import ignores them for exactly
that reason rather than as an omission.

**The geometry itself is zoom-independent.** A polygon is an outline on the earth, not a
set of tiles, and it is stored exactly as it was drawn - free coordinates in decimal
degrees, never snapped to anything.

### zauthor, zmin and zmax

`zauthor` is a number attached to that geometry rather than a property of it. It says
**where the polygon meets the grid**: the one zoom at which the outline is quantised into
tiles. Everything else chartMaker knows about this area's coverage is derived from that one
tile set.

It is the same single concept as the RCT header's `zoom_author` and the E-Series firmware's
`MASK_Z` - the level the plotter's reveal contour is cut at. Three names for one number,
because each matches the vocabulary of its own neighbours; they are not to be unified.

`zmin` and `zmax` bound what the region actually carries. **The region is complete over
`[zauthor..zmax]`**, and that completeness is not an optimisation to be traded away: the
plotter cuts its aperture at `zauthor` and paints at whatever level the view scale calls
for, so the painted set has to be a superset of the revealed set at every level on the card.
A partly populated level opens a hole onto ground nothing painted.

**Two of the three are properties of an output folder rather than of a region.** Every
`.RCT` on one card must agree on `zauthor` and `zmin`, because the firmware holds them on
the chartset rather than per file; only `zmax` varies freely. That does *not* make them
belong somewhere else - it makes them a **check at build time**, which given the convention
will almost never fire. See [Build](build.md).

**There is no target.** The region definition *is* the specification of what to build. An
earlier design put `zmax` and the output settings on a separate named target object; that
was one more persistent thing to manage, in exchange for nothing. A build cap prunes
arithmetically instead - a detail area whose band is entirely above the cap contributes
nothing, with no special case anywhere:

```
    build Bocas            z10-16, plus Popa00's z17-18
    build Bocas --zmax 16  z10-16.  The detail area is simply absent.
```

The editor shows the consequence rather than imposing it: **the tile footprint is drawn at
the zoom being viewed.** That keeps it legible, since a tile is about 256 pixels on the
screen at any zoom, and it keeps it honest, since the outline really is the coverage at the
zoom being looked at. Zoom in and the staircase along the boundary refines. It is the same
outline [preview](build.md#editor-and-preview-are-one-component-in-two-modes) clips to.

## How coverage is derived

The polygon is used exactly once, at `zauthor`, to produce a set of tiles. After that the
polygon is out of the picture and everything follows from the tile set.

**Coverage is the union of the included authored tiles, not the polygon.** That
distinction is the whole of what follows.

**Going coarser: the parents.** For any zoom above the authored one, coverage is the
parent tiles of the authored set. This happens to be identical to intersecting the polygon
at that zoom - a parent contains its child, so if the child meets the polygon the parent
does; and a coarse tile is exactly tiled by its descendants, so if it meets the polygon at
least one descendant does. The two rules cannot disagree, and taking parents is both
cheaper and makes the nested-fallback property self-evident.

The rule that has to be applied consistently is **positive-area intersection**. A polygon
edge lying exactly along a tile boundary is where two implementations of "does it intersect"
give different answers, and that is precisely where seam tiles go missing.

**Going finer: complete children, up to `zmax`.** Below the authored zoom, coverage is the
*complete* set of children of each included tile - not the tiles that intersect the polygon.
An authored tile is included because the polygon touches it, so the chart already claims
that whole tile; leaving out the children that miss the polygon would put a resolution
cliff inside an area the chart says it covers.

**Each level owns only the band its parent does not reach: `parent.zmax + 1` up to its own
`zmax`.** Equality at the start is the only value that neither gaps nor duplicates. Because
a subregion lies inside its parent, its tiles at the parent's `zmax` are already in the
parent's set, so it contributes nothing there or coarser:

```
    region     zauthor 15, zmax 16  ->  z16 and z15, and parents down to zmin
    subregion  zmax 18              ->  z18 and z17; z16 and coarser belong to the parent
    sub-sub    zmax 20              ->  z20, z19
```

**A subregion is authored at its own `zmax`, not filled down to it.** It quantises its
polygon at the finest level it carries and takes *parents* back to the band floor. Filling
instead - quantising coarse and taking complete children - would cost four times as many
tiles per level to describe the same ground, and it is unnecessary because the plotter
already falls back per tile. This is what makes a deep detail area cheap: Popa00 reaches
z18 for 182 tiles rather than 196.

Nothing enforces that partition - it falls out of containment. It is also why a subregion
whose `zmax` equals or undercuts its parent's is harmless: its band is empty, so it
contributes nothing, which is what "meaningless, not harmful" means arithmetically.

## Depth is requested here and capped at the build

`zmax` says what an area **deserves**, not what any particular build will contain. Three
things have an opinion about depth, and they are deliberately different kinds of thing:

| Source of the opinion | What it says                              | Force        |
| --------------------- | ----------------------------------------- | ------------ |
| the **region**        | carry this area to z18                    | a request    |
| the **build**         | this run stops at z16                     | a hard cap   |
| the **imagery**       | this source has real detail to about z16  | advisory     |

**The built depth is `min(region, cap)`.** The imagery's real resolution never enters
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

That does **not** require a second persistent object to hold the difference. It is one
region and a shorter command: the cap prunes the deep bands arithmetically, so `build Bocas`
and `build Bocas --zmax 16` produce the two cards from one definition, with no duplicated
geometry and nothing extra to keep in step.

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
subregions with the same `zmax` will produce the same parent tiles in their shared band,
and the union absorbs it.

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

**A shared boundary falls on a tile edge at the lesser of the two regions' authored
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

- **No source.** A region says where and how deep, never from what. The same region built
  from two sources is the same region.
- **No coded region name for the card.** The exported file's stem is the id, uppercased at
  export if it needs to be. Carrying a second machine-readable copy of the region's identity
  would only be one more thing to disagree with the first. See [RCT](rct.md).
- **No view state.** Whether a region is currently shown on the map is a fact about this
  machine, not about the region. See below.
- **No parent reference.** Nesting is expressed by the file structure, so a region file can
  never refer to a parent the recipient does not have.

## Sets are folders

chartMaker has **no project files and no File menu**. That follows directly from the region
being the unit of exchange: Open, Save As, recent files and unsaved-changes prompts exist to
move documents between people and places, and if the thing people exchange is a region file,
the container around it never needs to travel. The coverage model is refined over years - it
is a body of work, not a document.

A **set** is the answer to "what travels together" - and it is a **folder**:

```
    $data_dir/sources/*.tsd
    $data_dir/region_sets/<set>/*.region
```

**The files present ARE the set.** There is no index naming which regions belong to a card,
exactly as there is none on the card itself, where the renderer enumerates the folder and
merges every `.rct` it finds. A manifest is correct only by discipline and fails silently in
both directions - naming a region that is gone, and missing one that is there. Dropping in a
region somebody sent you is the whole of adding it, File Explorer is the set editor, and a
set is a folder you can zip and mail.

**One set is active at a time.** The map shows one set, and one set builds, because a
working set assembled across sets is one no card could express. It is also the scope in
which the containment and overlap rules matter, since that is the only time two regions'
tiles land in the same output.

**Ids are unique within a set, not globally.** A card is one folder; two sets that each
contain a `Bocas` are two cards, not a conflict.

**One output folder per set.** A build writes to `<raster>/<set>`, and that folder is what
is copied to the card - which makes the copy a copy rather than a decision about which files
belong together. See [RCT](rct.md) for the `\RASTER\` contract on the consumer side.

## Existence comes from the folder, selection comes from the ini

Everything above is discovered by scanning. What cannot be discovered is which of the things
found is *selected*, and there are exactly three such facts. None of them is data about the
model, all three are per-machine, and all three live in the application's ini file, written
on a clean exit alongside the frame rectangle and the open panes:

| Selection | Falls back to |
| --------- | ------------- |
| the active region set | the first set in tree order, then none |
| the display source | the official default TSD, then the first in tree order, then none |
| which regions are hidden | nothing hidden |

Each is a **pointer into folder contents, resolved on every read and never cached**, because
the folders are edited from outside the application by design. Deleting the active set's
folder quietly leaves you in another set; deleting the selected `.tsd` quietly leaves the map
on another source. A dangling pointer must degrade, never raise.

**Checked means shown on the map, and nothing more.** It is not membership: the set is the
folder, so every region in it is on the card whether or not you are currently looking at it.
Unchecking one is how you get it out of your way while working on another. This is also why
it is not a flag on the region file - one user's view state has no business inside a file
meant to be handed to somebody else - and why losing it costs nothing.

**The map's view is the browser's own state**, kept in `localStorage` rather than sent to
the application: the application cannot ask a closed browser where it was looking, and
nothing but the applet ever reads the answer. It falls back to the bounds of the regions on
the map, and then to a world view. No location is hardcoded anywhere in the applet.

## Selection and set management are editing concerns

Exactly one region or subregion is selected at a time, or none, and the selection is shared
by both authoring surfaces rather than owned by either. What a click selects where polygons
nest, and how a parent covered by its child is reached, belong to the editing interfaces -
see [Editing](editing.md) and [Map Editing](editing_leaflet.md).

Set management starts and ends with **File Explorer**: a set is a folder, so renaming,
deleting and copying one are things the operating system already does well. The application
creates a set and chooses the active one, and nothing more. Additional set handling is added
only if using Explorer for it turns out to hurt.

---

**Next:** [TSD](tsd.md)
