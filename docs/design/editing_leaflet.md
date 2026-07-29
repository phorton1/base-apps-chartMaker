# chartMaker - Map Editing

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**Map Editing** --
**[Tree Editing](editing_wx.md)** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

[Editing](editing.md) states the rules both authoring surfaces obey. This document is one
of those surfaces: the Leaflet applet, where geometry is drawn and where anything with a
position is reached by pointing at it.

## The screen

Nothing below is modal until you ask for it. With nothing being edited the map is a chart
you can pan, with three pieces of furniture:

```
+--------------------------------------------------------------------+
|                                          [x] tile footprint        |
|                                          1,234 of 9,931 at z12     |
|                                                                    |
|          ~~~ imagery ~~~                                           |
|              Bocas          (yellow outline)                       |
|                 Popa00      (cyan, inside it)                      |
|              . . . . . .    (grid dots, when snap is on)           |
|                                                                    |
|                                                                    |
|  zoom 12  9.3312N 82.2411W          grid on  z15                   |
+--------------------------------------------------------------------+
```

- **top right** - the tile footprint toggle and its count, already built
- **bottom left** - `#cm-coords`, the zoom and cursor position, already built
- **bottom right** - the grid readout, mirroring `#cm-coords` across the window and sitting
  above Leaflet's attribution

## Right-click is the whole of the interface

There is no toolbar and no palette. Everything begins with a right-click on the thing you
mean, which is what keeps the map a chart rather than an application with a chart in it.

**The target is the polygon whose filled area is under the pointer**, innermost first where
a subregion sits inside its parent. The outline is not the target - hitting a one-pixel line
with a mouse is a game, and the line is exactly what tends to be off screen when you need
it. Repeated right-clicks in the same spot walk outward through the nesting, so a parent
covered by its child is still reachable.

The menu titles itself with what it is about to act on, because being one polygon off is
otherwise silent and destructive:

```
  open water              on Bocas                  on Popa00
  ------------------      ---------------------     ---------------------------
  Create Region...        Bocas                     Popa00  (sub of Bocas)
                          ---------------------     ---------------------------
                          Edit Polygon              Edit Polygon
                          Add Polygon               Add Polygon
                          Add Subregion...          Add Subregion...
                          Properties...             Properties...
                          ---------------------     ---------------------------
                          Delete Polygon            Delete Polygon
                          Delete Region...          Delete Subregion...
```

The two menus on the right are **identical in structure**, because a region and a subregion
are the same object at different depths. A subregion can hold a subregion; the model nests
without limit and so does this menu.

## Dialogs

**Create Region...** and **Add Subregion...** open a small panel over the map, near where
the click landed. They are the only dialogs in the applet.

```
    +-----------------------------------------------+     +---------------------------+
    |  New region                                   |     |  New subregion of Bocas   |
    |  name    [ Bocas East           ]             |     |  name  [ Popa anchorage ] |
    |  id      [ BocasEast  ]  ok                   |     |  id    [ Popa00    ]  ok  |
    |  zauthor [ 15 ] zmin [ 10 ] zmax [ 16 ]       |     |  zmax  [ 18 ]  band z17-18|
    |          agrees with this set                 |     |                           |
    |                          [ Cancel ] [ Draw ]  |     |    [ Cancel ] [ Draw ]    |
    +-----------------------------------------------+     +---------------------------+
```

Both say something as you type that the model would otherwise only tell you later:

- the **id** is suggested from the name and flagged the moment it collides with one already
  in the set
- the **zooms** say whether they agree with the regions already there, which is the
  condition for this region sharing a card with its siblings
- a subregion's **band** runs from its parent's `zmax` + 1 to its own, so a `zmax` at or
  below the parent's contributes nothing at all, and the panel says so as the number changes

None of this is a rule of its own - the validator enforces all of it regardless. It is the
same rule said earlier, which is the applet's whole advantage over a message in a log.

**Draw** creates the object and begins its outline in one motion. The pointer is already
where the object goes, which is why creating from the map never needs a second gesture.

## Drawing

```
+--------------------------------------------------------------------+
|  drawing BocasEast - 3 vertices placed                             |
|                            [ Undo vertex ]  [ Close ]  [ Cancel ]  |
+--------------------------------------------------------------------+
```

Each click places a vertex. **Close** finishes the ring and is dead below three vertices,
because fewer is not a polygon; double-click and Enter do the same thing and are dead under
the same condition. **Cancel** and Esc abandon the drawing.

**Closing does not save.** It hands the finished ring straight to the editing bar with its
handles live, so the vertex you fumbled is fixable before anything reaches disk.

Abandoning a drawing costs only the drawing. If the object was created moments ago it stays
in the tree, named and empty, and the map offers to draw it again - which is why creating
before drawing is worth the two seconds it costs.

### Drawing a subregion stays inside its parent

The parent's outline is emphasised for the duration, and it is a **wall**: a click outside it
places nothing. The vertex is refused rather than moved to the boundary - relocating it would
silently override where the pointer was, which is the one thing this applet is careful never
to do - and the banner says why:

```
+--------------------------------------------------------------------+
|  drawing Popa00 - outside Bocas, not placed                        |
|                            [ Undo vertex ]  [ Close ]  [ Cancel ]  |
+--------------------------------------------------------------------+
```

Ground outside the parent is not a subregion; it is another polygon on the parent, or another
region. Both are a right-click away. See [Editing](editing.md).

The same wall applies to dragging a vertex of an existing subregion in the editing bar.

## Editing a polygon

```
+--------------------------------------------------------------------+
|  Bocas - drag a vertex, drag a midpoint to insert,                 |
|  right-click a vertex to delete                                    |
|                        [ Delete Polygon ]  [ Confirm ]  [ Cancel ] |
+--------------------------------------------------------------------+
```

Handles follow the navMate idiom: a solid square on every vertex, a smaller hollow one at
every segment midpoint. Dragging a midpoint inserts a vertex there. Dragging inside the
polygon moves the whole thing.

**Confirm** writes; **Cancel** restores what is on disk. Nothing else in this bar touches a
file.

While a polygon is being drawn or edited it is **drawn from the applet's own copy and not
from the application**, and every other surface leaves it alone. Without that the next poll
hands the old geometry back in the middle of a drag.

## Snap to grid

A toggle, and the reason the boundary problem has no machinery behind it.

**It defaults to off**, and its state lives in the browser's `localStorage` beside the map
view - the same reasoning applies, since it is a per-machine working preference that only the
applet reads. Off is the default because snapping is a constraint, and a constraint the user
did not ask for is indistinguishable from a bug the first time a vertex lands somewhere other
than where it was clicked.

**With snap on, a vertex lands on the tile grid of the object's own level** - `zauthor` for
a region, `zmax` for a subregion, and the active set's `zauthor` when nothing is selected
yet, which is well defined because every region on one card must agree on it.

That is the whole of the shared-boundary mechanism. Two regions meet exactly because a
person put both their vertices on the same intersection, and those two coordinates are
**computed from the same integers**, so they are identical to the last bit. There is no
binding relationship, no proximity search, no prompt, and nothing that moves a vertex in a
polygon the user did not select.

### Snapping happens in tile coordinates, never in pixels

```
    mouse pixel -> lat/lng -> fractional tile coords at level L
                -> round to integer -> back to lat/lng
```

The answer depends only on an integer and a level, so it is the same at any map zoom, at any
window size, and in any region. Snap in screen space instead and a vertex shifts slightly
every time it is re-dragged at a different zoom, and exact coincidence quietly dies.

Pixels are rounded only for **drawing** the dots, so they stay crisp at fractional zooms.
That rounding never travels back into the model.

### Showing the grid

Small grey dots, one or two pixels, at grid intersections. Lines would be noise over
imagery, and the intersections are what a vertex actually lands on.

**The display thins out as you zoom away, and the grid does not.** Because tile grids nest
in powers of two, showing every eighth z15 dot *is* the z12 grid, and every dot drawn is
still a real z15 intersection - so the thinning is exact rather than a decimation factor
someone picked. The readout says what it is doing:

```
    grid on   z15                    the grid, drawn at its own level
    grid on   z15  showing z12       thinned - every dot is still a z15 point
    grid on   z18  Popa00            a subregion is driving the level
    grid off
```

Naming the object matters when the level changes: selecting a subregion changes the pitch
underfoot, and unexplained is indistinguishable from broken.

**Holding a modifier suspends the snap** for one vertex, for the case that wants a free
placement without toggling the mode off and back.

### Seams, and what the grid buys

Draw both regions' vertices onto the same intersections and the seam is exact. Beyond that
there is a preference rather than a rule:

- **horizontal and vertical seams** - and stair-stepped combinations of them, which is all
  an L or a Z is - produce **zero contested tiles**. The boundary lies along tile edges and
  passes through no tile's interior.
- **a diagonal seam** is gap-free, because both regions carry the identical line, but every
  tile the diagonal crosses is claimed by **both** regions. It is an overlap at the grid
  level, chosen knowingly.

Neither is forbidden and nothing is rewritten. A polygon is stored exactly as it was drawn -
see [Regions](regions.md) - so a diagonal stays two vertices and stays editable as a line
forever, which is the thing a stair-stepping post-process would take away permanently.

## Tile counts are asked for, not watched

The footprint and its count answer for the model, on demand - the existing toggle, and a
recompute when asked. **They do not follow a drag.** Recomputing coverage under the hand
would cost far more than it tells anybody, and the question a zoom level answers is worth
asking deliberately, once, when the shape is settled.

## What the map refuses

The rules are in [Editing](editing.md); the applet's part is to say so rather than to
silently ignore a click. While an object is dirty, selecting something else and changing the
active region set are both refused, and the refusal names the object and points at Confirm
and Cancel - both of which are on screen, in the bar, at that moment.

## A seam is drawn twice, by hand

There is **no seam tool**. Nothing selects a neighbour's edge and follows it, and nothing
copies vertices from one region into another.

Both regions are drawn manually, and they meet because the author zoomed in far enough to
see the grid, then clicked the same intersections in each. That is the whole mechanism, and
it is enough precisely because snapping makes the two coordinates identical rather than
merely close - the accuracy comes from the grid, not from the care taken with the mouse.

What the author supplies is the *intent* that two boundaries be the same. Nothing in the
application infers it, stores it, or maintains it, which is why there is no seam to get out
of date. See [Editing](editing.md) on why gaps are the failure that matters and why exact
sharing cannot produce one.

## Not considered

**Touch and pen input.** Nothing in this document is designed for them, and no attempt is
made to accommodate them.

---

**Next:** [TSD](tsd.md)
