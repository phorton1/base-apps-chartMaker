# chartMaker - Tree Editing

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_leaflet.md)** --
**Tree Editing** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

[Editing](editing.md) states the rules both authoring surfaces obey. This document is the
other surface: the region tree in the wx application, where the whole set is visible at once
and where everything that has no position lives.

## What the tree is for

The map can only show what is on screen, and only says one thing about an object at a time -
its outline. The tree answers the questions the map structurally cannot:

- **is this set internally consistent?** Every `.RCT` on one card must agree on `zauthor` and
  `zmin`, and that is a property of a *collection*, not of anything you can point at.
- **what is in this set that I cannot see?** A region with no geometry is nowhere on the map.
  So is a region whose water is three thousand miles from the current view.
- **what is this thing called, and what is its id?** Neither has a position.

None of this makes the tree a fallback. Anything it creates, the map can create, and the
other way round.

## The pane

```
+---------------------------------+------------------------------------+
| region sets                     |  name    [ Bocas del Toro       ]  |
|                                 |  id      [ Bocas      ]            |
| (o) Panama       5 regions       |  zauthor [15]  zmin [10] zmax [16] |
|     [x] Bocas     10-16 @15     |  [x] show on the map               |
|         . Popa00      18        |                                    |
|     [x] PanCanal  10-16 @15     |         [ Revert ]  [ Save ]       |
|     [x] PortBelo  10-16 @15     |  ----------------------------------|
|     [x] SanBlas   10-16 @15     |  name            Bocas del Toro    |
|     [ ] SanBlasE  10-16 @15     |  id              Bocas             |
| ( ) Caribbean    1 region       |  kind            region            |
|                                 |  file            Bocas.region      |
|                                 |  zauthor         15  (the level    |
|                                 |                  the polygon is    |
|                                 |                  drawn at)         |
|                                 |  ...                               |
+---------------------------------+------------------------------------+
```

Three levels, and every one of them names something on disk:

- **the region set** - a folder. Its icon is a radio: clicking it makes that set active.
- **the region** - a file. Its checkbox is *shown on the map*, and nothing more; see
  [Editing](editing.md) on why that is not membership.
- **the subregion** - a node inside its parent's file. No checkbox, because it travels with
  its parent - it is part of what that region IS, not a thing to show or hide on its own.

Only the active set has children. The others are shown as what they are: folders that exist
and could be made active.

## Zooms are columns, not a field you click to see

The numbers are in the row - `10-16 @15` is `zmin`-`zmax` at `zauthor` - in a monospaced
font so they line up down the column. That is the entire point: a set whose regions disagree
about `zauthor` cannot be built onto one card, and a disagreement has to be **visible**
rather than discovered by clicking five regions and remembering what each said.

The set row states the answer outright, so nobody has to diff the column by eye:

```
    (o) Panama       5 regions   z15 @10          all agree
    (o) Panama       5 regions   MIXED zauthor    4 at z15, 1 at z14
```

A mixed set is not an error - it is a perfectly good folder of regions that cannot be built
as one card yet. The build refuses it and says which region is the odd one out; the tree says
so earlier.

## An object with no geometry says so

```
    [x] BocasEast    10-16 @15   (no geometry)
```

The properties panel says the same thing and points at the map, which is the only place the
outline can come from. This is a normal state - creating an object and drawing it are two
steps by design - and it is exactly what the tree is for, because an empty region is
invisible on the other surface.

## Right-click

```
  on the background        on a set                  on a region / subregion
  --------------------     ---------------------     ---------------------------
  New region set...        Make active               New subregion...
  Rescan                   New region...             Add polygon        (on the map)
                           Open folder in Explorer   Edit polygon       (on the map)
                           ---------------------     ---------------------------
                           Rescan                    Delete region...
```

Two of those hand off rather than act: **Add polygon** and **Edit polygon** need the imagery,
so they select the object and put the map into the matching mode - or, if the browser is not
open, offer to open it. The tree does not draw.

**There is no Delete set.** A set is a folder of the user's own region files and Explorer has
the better claim; **Open folder in Explorer** makes that a short trip instead of a hunt. The
application picks the change up on **Rescan**, and rescans on its own when the window regains
focus, so coming back from Explorer shows the truth rather than a stale tree.

## Properties, staging, and Revert

The fields at the top are **staged**: typing in them changes nothing until **Save**. Applying
as they are typed would write the file on every spinner tick, and every write rebuilds the
tree, which destroys the item being edited.

**Revert** discards back to what is on disk. Save enables on the first edit; Revert enables
with it; both disable again when the object is clean. They are the same two actions the map's
edit bar offers, and they mean the same thing - one dirty object, one Save, one Revert.

The **show on the map** checkbox is deliberately not staged. It is not a change to the region;
it is a statement about what is being looked at, so it takes effect on the click.

The read-only panel below is a dump - the bounds, the polygon and point counts, the first few
vertices of each polygon, the subregions and their bands. It exists to answer "did the import
do what I think it did", and it is the reason a region can be inspected without the browser
running at all.

## Obeying the map

The mode, its target and the dirty flag are published by the application, so the tree can
see an edit it is not holding - see [Editing](editing.md). What that looks like here:

- the properties fields grey out, reading **being edited on the map**
- deleting that object is refused
- making a different set active is refused
- the tree does not rebuild itself under the edit, even when the poll says the model changed

The last one already holds and is worth keeping deliberately: a rebuild reloads the controls
from the model, which is exactly how a half-typed name gets thrown away.

## Knowing whether the map is open

The hand-off items need a browser, and the application can tell whether one is there **from
the timing of `/poll`** - the same way navMate does it. A poll arrived within the last few
seconds means an applet is running; silence means it is not, and the menu item offers to open
one instead of handing off into nothing.

This does not give the server a session or a connected client. It records **one timestamp**,
which is a fact about the recent past rather than a relationship being maintained - so closing
and reopening the browser stays the non-event that [Implementation](../implementation.md)
describes, and nothing needs cleaning up when a window disappears.

## Deliberately not built

- **Multiple selection.** One object at a time, to begin with. A mixed set is repaired by
  editing each region's zooms in turn, which is a handful of edits on a fault that should be
  rare - and the tree now makes it visible rather than letting the build discover it.
- **Sorting and grouping.** Alphabetical by id, which is what the model already gives.

---

**Next:** [TSD](tsd.md)
