# chartMaker - Map Editing

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**Map Editing** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

[Editing](editing.md) states the rules both authoring surfaces obey. This document is one
of those surfaces: the Leaflet applet, where geometry is drawn and where anything with a
position is reached by pointing at it.

## The screen

Nothing below is modal until you ask for it. With nothing being edited the map is a chart
you can pan, with four pieces of furniture.

- **left, under Leaflet's own zoom buttons** - the palette, one row each for the grid,
  autozoom, shading the selection, the footprint and preview: a checkbox, a label, and a value
  that is text on one row and a control on another. The whole row is the switch.
- **top right** - the info panel: the set and its total, then the selected region and the
  selected subregion, each naming its levels with a tile count and a size against every one.
  Nothing there is operable.
- **bottom left** - the map zoom and the cursor position.
- **bottom right, and only in probe mode** - the probe palette, one row per probed source.

**A control that also answers a question is split across two places.** The grid's checkbox is
wanted mid-edit while its level is wanted at a glance, and one badge could not be both, so the
row carries the switch and the value separately. That is a fact about those rows and not a
rule about which side of the screen anything belongs on.

Regions draw yellow and subregions cyan, and whichever is selected draws white over both.

**The selected object is also washed, and that can be switched off.** The white outline already
outranks every other colour on the map and the info panel names the object in words, so the
fill is a third signal - and what it adds is a haze over the imagery, on the one object you are
looking hardest at. It is worst while drawing or editing, with the ground under a vertex being
judged. So `shade selection` is a switch rather than a smaller number: it defaults on, it
covers the object under edit as well as the selected one, and it is remembered in the browser
like autozoom, because turning it off after every reload is the friction the switch exists to
remove.

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

Over open water it offers **Create Region** and nothing else. Over an object it names that
object at the top - a subregion also naming the parent it belongs to - and then offers three
groups: **Edit Polygon**, **Add Polygon**, **Add Subregion** and **Properties**, then **Delete
Polygon** and **Delete** for the object itself, then **Probe**.

**Probe opens a dialog, and it asks which source.** The right-click says *where*; it does not
say what to probe. Using whichever source happened to be displayed was wrong for the reason the
feature exists: the source is the **subject**, and the point of a probe is to judge services you
are not currently looking at. The dialog asks the two things the gesture did not - a source and
a zoom range - and does not ask for an area, because that is what was pointed at.

**Over a subregion there are two entries**, the detail area and the region containing it, and
they are not the same question - probing a detail area alone is a far more intimate answer than
probing the ground around it, which is exactly the judgement somebody siting one is making.
Over a plain region there is only the one.

**They stay available while a probe is showing**, because the mode holds results from several
sources at once so they can be compared, so adding to what is on screen is ordinary rather than
a special case. Two runs at the same time are refused, since they would publish into one result
set.

The menu over a region and the menu over a subregion are **identical in structure**, because
a region and a subregion are the same object at different depths. A subregion can hold a
subregion; the model nests without limit and so does this menu.

## Dialogs

**Create Region...** and **Add Subregion...** open a small panel over the map, near where
the click landed. They are the only dialogs in the applet.

A new region asks for a name, an id, and all three of `zauthor`, `zmin` and `zmax`. A new
subregion asks for a name, an id and `zmax` alone, because those are the fields it has - see
[Regions](regions.md). Each ends in Cancel and **Draw**.

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

A bar across the top of the map names the object being drawn and counts the vertices placed
so far, and carries **Undo vertex**, **Close** and **Cancel**.

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
to do. The drawing bar says so as it happens, naming the parent the click fell outside of, so
a refused vertex is never a click that simply did nothing.

Ground outside the parent is not a subregion; it is another polygon on the parent, or another
region. Both are a right-click away. See [Editing](editing.md).

The same wall applies to dragging a vertex of an existing subregion in the editing bar.

## Editing a polygon

The same bar names the object under the hand and states the three gestures - drag a vertex,
drag a midpoint to insert one, right-click a vertex to delete one - and carries **Delete
Polygon**, **Confirm** and **Cancel**.

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

## Probe mode

A third mode beside source view and preview, showing what the probe found. The act itself is
specified in [Build](build.md#the-probe); this is what the map does with it.

**It holds accumulated results rather than being a run that finishes.** A run happens inside
the mode, the results stay on screen, and the mode ends only when it is closed. That is a
longer life than a build has, and it is the point: nobody chooses a `zmax` from a number that
vanished.

**Every run adds, and only Clear takes anything away.** Two services' marks sit on the same
ground and can be compared - and running the *same* service again adds to itself rather than
replacing itself, which is the case that used to be the exception.

Selection draws different points every time, so a second run over the same ground is not a
repeat of the first: it is more of the same sample. Running it again is how a scatter of a few
dozen dots becomes dense enough to read a pattern off, and replacing the earlier run threw away
exactly the accumulation that made running it twice worth doing. It also made the two cases
behave differently with nothing on screen saying which was about to happen.

**Triggered by the application and completed by the application.** The map picks no sample
points, fetches nothing and counts nothing; it renders what it is handed. If the browser
decided any of it the marks would illustrate the analysis rather than be it, which is the same
reason preview does not work out coverage for itself.

### The marks are small, and that is deliberate

A mark is a dot at the **exact centre of the sampled tile**, and **its size says which level it
came from** - larger for coarser. Reading a spread of marks means knowing which level each one
is about, and a legend cannot carry that for a hundred dots at once.

**The centre is exact and nothing may move it.** A tile centre at level z is `(2x+1)/2^(z+1)` of
the world - an odd numerator over a power of two - so no two levels can ever produce the same
point, and every one of them is a vertex of every finer grid. That is what lets one level's
samples read as **its own lattice**, distinct from every other level's, once enough of them
accumulate on the same ground. The mark was briefly clipped to the area's bounding box, on the
argument that a z0 tile's true centre is a point in the Atlantic. True, and about levels nobody
probes; what it actually did was move every edge tile at every level, which over a small polygon
is most of them. A mark is a claim about a **tile**, and a tile that overlaps the region does
extend into open water.

Two versions of the *size* were wrong before it. Drawing each sample at the **true footprint** of
its tile made size mean level exactly, and produced a quilt of opaque rectangles in which one
coarse sample buried every finer one inside it and hid the imagery being judged. Correcting that
to a **fixed-size dot** threw the level away entirely, so a green and a red mark in the same
place said nothing about which depth had failed.

**Two jobs, two separate numbers**, and conflating them was the third mistake:

- **which level is this** - a fixed geometric ramp, about 12.5% a level, anchored so z10 is the
  largest dot and z21 the smallest. Geometric because the eye judges size by *ratio*: equal
  ratios give equal perceptual steps, while equal pixel steps are obvious at the small end and
  invisible at the large one. Decided ahead of time and never from the marks currently on
  screen - a scale computed from "what has been probed so far" is a running average, and
  because the probe publishes levels in ascending order it made every dot visibly **grow** as
  the run descended.
- **can I see it at all** - one multiplier applied to every dot, from the map's own zoom,
  doubling every four levels. Ratios between levels are untouched at every zoom, so nothing
  becomes more or less distinguishable; what you gain is that zooming in to inspect makes the
  small ones big enough to read a colour off.

**Not proportional to the tile's own screen size**, which is the geometrically honest version.
That doubles per level exactly, and the usable range for a dot is about 5 to 30 pixels - six to
one. Two-to-one per level burns that in two and a half levels, so three levels would look right
and the other ten would sit pinned at a floor or a ceiling. That is arithmetic, not tuning.

**No outline.** The dot was ringed in a per-source hue so two services could be told apart at a
glance, and on a small dot that ring is most of the dot - at radius 2 a one-pixel stroke is over
half the area. The outcome colour, which is the whole point of the mark, was being reported by a
few pixels in the middle while the source hue owned the edge; the fifth source's tint is a
lavender that read as the purple `flat` outcome outright. **A dot has one colour and it says
what came back.** Telling two sources apart is what the palette's checkboxes are for.

**Coarsest drawn first**, so fine marks land on top of large ones. A coarse mark is also more
transparent, because it covers more chart and is making a vaguer claim about where it applies -
and that transparency comes from its **level**, not its drawn size, or a dot would fade as you
zoomed into it.

**Colour carries the outcome**, because a small dot has no room for a shape:

| | |
| --- | --- |
| green | found |
| red | absent - the service refused |
| amber | no-data - it answered with its declared blank instead of refusing |
| purple | a flat fill - something came back and there is nothing in it |

A per-source hue rings the dot and fills the palette swatch, so two services are distinguishable
before anybody reads a name.

**No-data is amber and was a deep pink.** Putting it in the red family because it is also an
absence was reasoning about meaning rather than about eyes: at these sizes it read as red, and a
distinction nobody can see is not a distinction.

**There is no "no detail" mark.** It was a per-tile verdict from a threshold, and measured against
real ground it went wrong in both directions - firing on open water at z11, where a blow-up costs
a handful of tiles and nobody would decide differently, and staying silent on a service enlarging
its own imagery at z21 where the eye can see it. How much detail a **level** holds is not a
property any single tile has. The number survives as a column in the report; the dot does not,
and a tile that scored low is drawn as what it is, which is found.

### The probe palette

Bottom right, in the translucent grey box, titled **Probe**. One row per source probed: a
swatch, its name, and a checkbox that hides its marks so another's can be seen underneath.
Below them, one line per source saying what it found, then a colour key and one line naming the
range the sizes span. **The size rule is said in words** because a legend can show four colours
and cannot show twelve sizes, and a size that means something nobody was told means nothing.

**The swatch is a row token and nothing on the map is coloured by source.** It was the hue that
ringed each dot, and it stopped being that when the outlines came off; it is kept so a source
can be found in a list of six. Isolating one source's marks is what its checkbox does.

It **replaces** an earlier two-line overlay rather than sitting beside it. The pane owns the
columns of numbers; what the map still needs to say is which source these marks belong to and
what the marks mean, and that is what a palette is.

It also carries **Halt run** and **Clear all**. Halt stops the run and leaves the marks, because
they are the product and they become useful when they stop changing; Clear takes them away.
Halt is dead when nothing is running, so it cannot read as an offer to undo a run that already
finished. The pane carries the same two, and it can be on another monitor - a mode with no way
out from the surface it is drawn on is not a mode, it is a trap.

### The results are a pane

The table lives in the application, as a **pane** beside the tree and the sources: docked, torn
off, or shut, and every one of those the user's decision. It was a modeless frame first, and a
floating window is wrong in the ordinary way - it comes up behind the application, and the only
cure for that is "always on top", which is obnoxious. Docking is also the arrangement that was
wanted: the whole reason to look at the table is to compare it with the map, and a pane docked
on the left of a maximised application does that with nothing overlapping anything.

**Closing the pane ends probe mode**, which is the only thing that does, so the mode always has
an exit on a surface that shows it. **It is not restored at startup**, unlike every other pane:
the others are views of things that are still there next time, and this one is the view of a
mode that is not.

**Everything describing the run as a whole sits above the scroll and the column heading does not
move.** One source over twenty-three levels is twenty-three rows before a second source is
added, so a heading carried as the first line of the scrolling control is off screen essentially
always, and eight columns of unlabelled integers is not a table. For the same reason a total
belongs with the other summary lines rather than at the bottom of a scroll where nobody arrives.

**The rows are the report being written**, not a second rendering of it - the pane, the written
report and the console print the same header and the same row, from the same two calls, so they
cannot disagree about a number or label it differently.

### The result set crosses threads as flat strings

A nest of hashes cannot cross a thread boundary as a reference, and shipping a copy back would
be a second representation free to drift from the first. [Build](build.md) already settles this
for the build report and the same applies here.

Two shared arrays do it: rendered table rows for the pane, and marks encoded
`source z/x/y/outcome/lat/lon` for the browser. The source rides **inside the string** rather
than in a parallel structure keyed the same way twice, which would be two things free to
disagree.

- The map **polls**, exactly as everything else here polls. Nothing calls into the browser.
- **`/poll` carries the probe's own sequence**, beside the state version. A running probe
  publishes while the state document is unchanged, so anything waiting on the state version
  would never learn a mark had arrived - and `/poll` is where "has anything changed" is already
  asked every cycle. Carrying it separately means the applet goes straight to the marks without
  refetching a document that did not move.
- Results publish per **source and level** - per tile is too chatty for a poll, per run too slow
  to watch, and that pair is already the unit the table rows use.
- **Marks outlive the run**, because completion is when they become useful.
- They are **bounded**: a mode left open across many runs would otherwise grow without limit, so
  at the cap the oldest go and the count is reported. Silent truncation is the only version of
  this worth refusing.

**Nothing placed outlives the mode.** There is no result file and no spatial index. What a run
learns that is *placeless* - rate statistics, and candidate fingerprints for a human to judge -
goes to the observation record, where facts about servers already live.

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

**Next:** [Tree Editing](editing_tree.md)
