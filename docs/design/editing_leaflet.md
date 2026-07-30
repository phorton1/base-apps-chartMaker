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
|  [+]                                     set        Scratch        |
|  [-]                                        size    215 MB         |
|  [x] grid       z15                      region     Bocas          |
|  [x] autozoom                               z15     1,800   15 MB  |
|  [ ] footprint  [16]                        z16     7,200   62 MB  |
|                                             total   9,967   84 MB  |
|          ~~~ imagery ~~~                 subregion  Popa00         |
|              Bocas          (yellow)        z17        49  400 KB  |
|                 Popa00      (cyan, inside it, WHITE when selected) |
|              . . . . . .    (grid dots, when snap is on)           |
|                                                                    |
|  zoom 12  9.3312N 82.2411W                                         |
+--------------------------------------------------------------------+
```

**EVERYTHING YOU SET IS ON THE LEFT; EVERYTHING THE MAP REPORTS IS ON THE RIGHT.** A
control that also answers a question has to be read in one place and operated in another,
and the two get in each other's way - the grid's checkbox was wanted mid-edit while its
level was wanted at a glance, and one badge could not be both.

- **left, under Leaflet's own zoom buttons** - the palette: a checkbox, a label, and a
  value that is text on one row and a control on another. The whole row is the switch.
- **top right** - the info panel: the set, what is selected, its zooms, and what it would
  cost by level. Nothing there is operable.
- **bottom left** - `#cm-coords`, the zoom and cursor position.

The palette is a Leaflet control at `topleft` rather than a box positioned by hand, so it
stacks under the zoom buttons by itself at any window size.

## Right-click is the whole of the interface

Everything that CHANGES something begins with a right-click on the thing you mean, which is
what keeps the map a chart rather than an application with a chart in it. The palette is not
a counter-example: it holds no verbs, only three switches and a level.

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
every segment midpoint. Dragging a midpoint inserts a vertex there. **Nothing moves the
polygon as a whole** - a press anywhere but on a handle is a map PAN, and the work polygon
is drawn non-interactive so it cannot swallow one. A region spans more than a screenful;
panning to reach its far side is the commonest gesture in an edit, and a whole-polygon
translate is not an edit that is ever wanted.

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
a region, `zmax` for a subregion, and the open set's `zauthor` when nothing is selected
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
someone picked.

**What decides is the spacing on screen, not the level.** Dots are dropped until they are at
least **64 pixels apart**, which is where the grid reads as a reference rather than as a haze
over the imagery - the z15 grid at map zoom 13, and the z18 grid at map zoom 16, are both
exactly that spacing. Half of it is busy and a quarter of it obscures the chart, which is
what a rule that thins only at the point of unreadability produces at wide views.

**The palette row is one word and one number** - the level being *snapped to*, and nothing
else. Not the drawn level: which dots were dropped is the display's own business, the density
on screen already says it, and every dot drawn is an intersection of the named level whether
or not any were dropped. A second field that changes on every zoom reads as a state to keep
track of when there is nothing to do about it.

**The level is shown whether the grid is on or off**, and goes on tracking the selection
either way. It is a property of what is selected, not of the switch - and watching it move
while the dots are off is how the two stop being confused for each other, because the dots
thin out with the view and this number does not.

**The row is reachable mid-edit, which is why it exists.** The right-click menu offers the
same toggle and is out of reach exactly when it is most wanted: in the middle of shaping a
polygon, where the pointer belongs to the vertices and a right-click means something else.
Turning the grid off for one awkward vertex and back on for the next should cost one click at
a fixed place. The checkbox displays the flag rather than holding a state of its own, so the
menu, the palette and the dots can never disagree.

**Holding a modifier suspends the snap** for one vertex, for the case that wants a free
placement without toggling the mode off and back.

### Autozoom

A palette switch. When the selection changes, the map frames that object's own polygons with
a margin, never deeper than its `zmax` - a small subregion framed at a zoom no card carries
imagery for would be a worse answer than none.

**It fires only for a selection that arrived from somewhere else.** Zooming to an object the
user just clicked on the map would move the ground out from under the click that chose it;
arriving from the tree, where there is no map to lose your place on, it is the whole point.
The applet remembers the selection it sent and treats anything else as foreign, which also
covers a `select` typed at the console.

**The memory outlives the page**, stored beside the remembered view. Without it, opening the
browser could not tell "the tree moved the selection while I was closed" from "this is what I
was already looking at", and had to refuse to act on either - making a page load the one
event autozoom never saw.

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

Two answers to the same question, and they are not redundant: the **footprint** draws one
level on the ground, the **info panel** does every level as arithmetic.

**The footprint's level is chosen, not inherited.** It was tied to the view zoom, and that
made it unreadable - the number changed every time the map moved, and comparing two levels
meant zooming away from what you were looking at. It is a spinner in the palette instead,
bounded by the work rather than by the protocol: the region's `zmin` at the bottom, the
deepest `zmax` anywhere inside it at the top, since no level outside that holds any tiles.
The rectangles are still clipped to the view - an answer about tiles nobody can see is of no
use - while the count is the whole set at that level.

**The panel nests the way the model does.** The set is the top line with what the whole card
would cost; the region names its levels and totals **itself and everything inside it**; a
selected subregion adds a block below carrying only the band it supplies. The blocks are
disjoint by construction, so they read down the panel as addition, and each level of nesting
has its own colour - at three deep the word "subregion" has stopped telling them apart.

**Nothing here follows a drag.** Geometry only reaches the model on commit, so the table is
still through an edit without a rule saying so, and it is recomputed when the regions
document or the selection changes - not on every poll. Recomputing coverage under the hand
would cost far more than it tells anybody.

## What the map refuses

The rules are in [Editing](editing.md); the applet's part is to say so rather than to
silently ignore a click. While an object is dirty, selecting something else is refused, and
the refusal names the object and points at Confirm and Cancel - both of which are on screen,
in the bar, at that moment.

## The application owns the mode

The applet publishes what it is doing, and **obeys what comes back**. A document that says
`browse`, or one in which the object under the hand is no longer present, ends the edit -
which is how Open, Close and Revert are safe without disabling anything: they publish
`browse` and the map lets go on its next poll.

It waits for its own publish to be reflected before obeying, or a `/state` built a moment
before the edit began would arrive and cancel it.

**A missing application is the same case.** After a few seconds of failed polls the regions
and the footprint are cleared, any edit ends, and the panel says so - because a chartset
drawn with nothing behind it is a picture of something that may no longer be true. The
imagery layer is left alone: its tiles come through the application too, so it simply stops
loading. Reconnecting resyncs everything.

Geometry held in the browser goes with the edit. It was never in the model, it cannot be
committed with nothing to commit to, and holding it would only defer losing it until the
application came back in `browse` and ended it anyway.

## Left click selects

In browse mode a click selects the innermost object under it, and open water clears the
selection. Selecting costs nothing and commits nothing, which is what makes clearing it on a
stray click harmless rather than destructive.

**No hit cycling here.** Stepping outward through the nesting is a gesture for choosing what
a *menu* will act on; a click that quietly selected the parent because it was the second one
in the same spot would be a click that lies.

**Selection is one fact shared by both surfaces**, so this moves the tree, and the tree moves
this. The selected object draws **white**, outranking yellow for a region and cyan for a
subregion: what kind of thing it is can be read off the tree or the info panel, but which one
is under discussion cannot be read anywhere else on the map.

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
