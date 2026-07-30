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
| Scratch *   5 regions  z10 @15  |  [Save]    Id:   [ Bocas      ]    |
|                                 |  [Revert]  Name  [ Bocas del Toro ]|
| [x] Bocas       10-16 @15       |  Zoom      Author:[15] Min:[10]    |
|     . Popa00        to z18      |                        Max:[16]    |
| [x] PanCanal    10-16 @15       |  ----------------------------------|
| [x] PortBelo    10-16 @15       |  name            Bocas del Toro    |
|     . chichime      to z18      |  id              Bocas             |
| [x] SanBlas     10-16 @15       |  kind            region            |
| [ ] SanBlasE    10-16 @15       |  file            Bocas.region      |
|                                 |  zauthor         15  (the level    |
|                                 |                  the polygon is    |
|                                 |                  drawn at)         |
|                                 |  ...                               |
+---------------------------------+------------------------------------+
```

**THE SET IS THE DOCUMENT, NAMED ABOVE THE TREE RATHER THAN INSIDE IT.** A document is not
one of its own contents, and making it a node made it look like something you could have
five of at once. Which set is open is a File menu question - see
[Regions](regions.md#a-set-is-a-document) - and the title carries the two facts you read
constantly: which set, and whether it has unsaved changes.

Regions are therefore the outer level, with no line connecting them to a parent that no
longer exists. Two levels, each naming something on disk:

- **the region** - a file. Its checkbox is *shown on the map*, and nothing more; see
  [Editing](editing.md) on why that is not membership.
- **the subregion** - a node inside its parent's file. No checkbox, because it travels with
  its parent - it is part of what that region IS, not a thing to show or hide on its own.

## Zooms are columns, not a field you click to see

The numbers are in the row - `10-16 @15` is `zmin`-`zmax` at `zauthor` - in a monospaced
font so they line up down the column. That is the entire point: a set whose regions disagree
about `zauthor` cannot be built onto one card, and a disagreement has to be **visible**
rather than discovered by clicking five regions and remembering what each said.

The title states the answer outright, so nobody has to diff the column by eye:

```
    Scratch      5 regions   z10 @15
    Scratch *    5 regions   MIXED zauthor - 4 at z15, 1 at z14
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
  on the background          on a region / subregion
  ------------------------   ---------------------------
  New region...              New subregion...
  Open folder in Explorer    ---------------------------
  Revert all...              Commit 'Bocas'
                             Revert 'Bocas'...
                             ---------------------------
                             Delete region...
```

**Commit and Revert act on the REGION, whichever node was clicked.** A subregion has no file
of its own - it is part of the region that holds it - and a menu implying otherwise would be
offering to write something that does not exist. Both are disabled unless that region has
unsaved changes, and both name the region they will act on.

**Reverting a region that has never been saved removes it**, because its saved state is
absence. That one asks first.

**There is no Delete set, and no New set here.** A set is a folder of the user's own region
files: Explorer has the better claim on deleting one, and creating or opening one is a File
menu question. **Open folder in Explorer** makes the trip short; **Revert all** re-reads the
folder afterwards, and says what it is throwing away.

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
- the tree does not rebuild itself under the edit, even when the poll says the model changed
- anything that would throw the edit away - Open, Close, Revert, quitting - says so before
  it does, naming what the map is holding. Nothing is disabled, because a File menu that
  greys itself out during an edit leaves the user with no way to find out why.

The last one already holds and is worth keeping deliberately: a rebuild reloads the controls
from the model, which is exactly how a half-typed name gets thrown away.

## Which pane is in front is the user's decision

Nothing the application does on its own may change it - not a poll, not a rebuild, not a
selection made on another surface. It is not a piece of application state at all; it is where
the user is looking.

**A pane that is not showing does not touch its widgets.** That is what makes the rule hold
rather than merely stating it: filling a tree on a notebook page that is not on top drags the
notebook to that page, so a pane refreshing itself in the background moves the user. Every
selection - in the tree, on the map, from `/api/command` - bumps the state counter that every
pane polls, so this was every selection.

Nothing is lost by waiting. **What a pane shows is shared state, not anything of its own**, so
it is correct the moment it is built, and it is built on the way in: on opening, and on
activation. A pane that has been away has nothing to catch up on beyond reading the same
globals every other surface reads.

Activation on demand is a different thing, and belongs where every other deliberate action
lives - the [command vocabulary](../implementation.md), reachable from the console and
`/api/command` alike. That is what a test harness uses to put a pane in front on purpose. The
distinction is the whole point: on purpose, never as a side effect.

## Knowing whether the map is open

The application can tell whether one is there **from the timing of `/poll`** - the same way
navMate does it. A poll arrived within the last few seconds means an applet is running;
silence means it is not.

This does not give the server a session or a connected client. It records **one timestamp**,
which is a fact about the recent past rather than a relationship being maintained - so closing
and reopening the browser stays the non-event that [Implementation](../implementation.md)
describes, and nothing needs cleaning up when a window disappears.

It answers two questions that had no answer before. The hand-off items need a browser, and
offer to open one instead of handing off into nothing. And **an edit belongs to a browser**:
a map that has stopped polling is holding nothing, so the edit state it left behind is
cleared rather than left refusing deletes on account of a window that was closed an hour
ago.

## Deliberately not built

- **Multiple selection.** One object at a time, to begin with. A mixed set is repaired by
  editing each region's zooms in turn, which is a handful of edits on a fault that should be
  rare - and the tree now makes it visible rather than letting the build discover it.
- **Sorting and grouping.** Alphabetical by id, which is what the model already gives.

---

**Next:** [TSD](tsd.md)
