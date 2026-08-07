# Detail Areas

**[Tutorial](readme.md)** --
**[Getting Started](getting_started.md)** --
**[The Map](the_map.md)** --
**[Zoom Levels](zoom_levels.md)** --
**[Your First Region](regions.md)** --
**Detail Areas** --
**[Choosing a Source](choosing_a_source.md)** --
**[Building](building.md)**

folders: **[Home](../readme.md)** --
**Tutorial** --
**[Reference](../reference/readme.md)**

Formentera is carried to zoom 16. That is a good coastal chart and it is nowhere near enough
to pick a sand patch out of a seagrass meadow. This chapter goes deeper where it matters, and
then makes the far more valuable point: **how you draw decides what your chartset costs.**

## Add a detail area

**Es Espalmador** is the small island at the north end of Formentera, and the sandbank
running up to it - Es Trucadors - is one of the most photographed anchorages in the western
Mediterranean. It is also entirely sand and seagrass, which is the point.

**Right-click inside Formentera** near Espalmador and choose **Add Subregion**. The panel
asks for less than a region did:

- **Name** - `Espalmador`
- **Id** - `Espalmador`. A detail area's id is only ever used inside its own region, so
  unlike a region's it has no length limit and nothing downstream is named for it. Letters and
  digits, and unique anywhere in this region's tree.
- **`zmax`** - `18`

**A detail area has `zmax` alone.** No `zauthor`, because it never cuts an outline - it sits
inside an aperture its parent already opened, purely to add resolution. And no `zmin`,
because its floor is decided for it.

Select it in the Regions pane and the properties panel says exactly that - and it is worth
comparing against the region you selected in
[Getting Started](getting_started.md#4-open-a-region-set). Here is one of the example set's
own detail areas, `Cala Xarraca`, selected the same way:

<a href="../images/tree.png" target="_blank"><img src="../images/tree.png" width="800" alt="The Regions pane with a detail area selected: zmax and Min only, and its source reading inherited"></a>

Three things differ from a region, and each is the rule rather than a shorthand:

- **Zoom** shows `Max` and a read-only `Min`. The Min is not yours to set - it is the parent's
  `zmax` plus one, which is the band explained below.
- **`show on map`** is greyed. A detail area is drawn when its region is; it has no
  visibility of its own.
- **Source** reads **`inherited`**, and the dump below spells out where from -
  `inherited (from 'Ibiza')`. That is a detail area's default and usually what you want.

Which brings us to the one rule worth understanding.

## The band

**A detail area supplies its parent's `zmax` plus one, up to its own `zmax`. Nothing else.**

```
    Formentera   zauthor 15, zmax 16   ->  z16, z15, and parents down to z10
    Espalmador   zmax 18               ->  z18 and z17 only
```

Espalmador contributes nothing at z16 or coarser, because it lies inside Formentera and
Formentera already carries that ground at those levels. Each level supplies exactly the band
the one above it does not reach - no gaps, no duplication, and nothing enforcing it. It falls
out of the fact that a detail area is *inside* its parent.

The immediate consequence: **a `zmax` at or below the parent's does nothing at all.** Set
Espalmador to 16 and its band is empty. That is harmless - coverage is a union and never
subtracts - but it is also pointless, and the panel tells you so as you change the number.

Detail areas nest without limit. A square mile at z18 with a single dock at z20 inside it is
expressible and needs no special case.

**Press Draw and click out a small box** around Espalmador and the sandbank. While you are
drawing, the parent's outline is emphasised and it is a **wall**: a click outside it places
nothing, and the bar says which parent you fell outside of. Ground outside the parent is not
a detail area - it is another polygon on the parent, or another region, and both are one
right-click away.

Confirm, then look at the info panel. A box round the island and the sandbank adds something
like two thousand tiles across its two levels, and about four fifths of them are at z18
alone. The next section is why.

## Reading the cost

Turn on **`tile footprint`** in the palette and run the spinner up and down.

<a href="../images/footprint.jpg" target="_blank"><img src="../images/footprint.jpg" width="800" alt="The footprint showing z16 tiles over Formentera with the info panel counts"></a>

Each rectangle is one actual tile that will be built. The count is the whole set at that
level, and the rectangles drawn are the ones you can see. Watch what happens as the level
goes up: **each level is four times the one above it.** That is the entire economics of this
program. Raising a `zmax` from 18 to 19 does not cost a bit more, it costs four times as
much, over the whole area you raised it on.

Which is why the answer is almost never "raise the `zmax`". It is "draw a smaller detail
area".

## Drawing for size

Now look at **Ibiza** in the example set, and turn its checkbox on if you hid it. Two things
about it are worth more than anything else in this chapter.

<a href="../images/two_polygons.jpg" target="_blank"><img src="../images/two_polygons.jpg" width="800" alt="The Ibiza region traced around the island's coastline in two polygons"></a>

**It is traced, not boxed.** The outline follows the coast the whole way round, in forty-odd
vertices, keeping a modest offing rather than a wide margin. It costs a couple of minutes
with the mouse, and here is what those minutes buy:

```
    the traced outline          4,316 tiles
    one box over the same water 10,639 tiles
```

**Two and a half times, for the same coastline.** All of the difference is open sea in the
corners of a rectangle - water you would cross on passage and never need a photograph of.
On an E-Series card, where space is genuinely scarce, that is the difference between carrying
one island and carrying three.

That is the single largest lever you have. Before you draw, ask where you would actually take
the boat, and outline *that*.

**It is two polygons, and they meet.** A region may hold as many polygons as you like -
they are one region because they are one thing to the person who drew them. Here the island
is split into a northern and a southern half along a seam, which is simply an easier thing to
draw and to go on refining than one ring of eighty vertices. Overlap along that seam costs
nothing: coverage is a union, and where two polygons both claim a tile it is built once.

**There are no holes.** You cannot cut the middle out of a polygon, because a union never
subtracts. If you did want the interior of an island left out - which is a reasonable thing
to want, and would save more still - you would draw two coastal bands that do not meet,
rather than one ring with a hole in it.

### The other boundary: where the imagery actually stops

Look at the sea around the island at a wide zoom, before you draw anything. The Spanish
orthophoto does not cover the whole Mediterranean - it stops, and the edge is **visible**, as
lighter rectangular patches of real sea against a darker flat fill beyond them.

The example region's outline is drawn **inside that edge**, deliberately. Extending past it
would add tiles that are not photographs of anything, and they cost exactly as much to fetch,
store and carry as real ones.

So it is worth a minute of panning around at zoom 10 or 11 before you commit to an outline.
Where a service's coverage ends is not written down anywhere - a source never declares where
it holds imagery, because every service is patchy and a declaration would be a claim rather
than a fact - so **looking is how you find out**. The [next chapter](choosing_a_source.md)
gives you an instrument for asking the same question properly.

### A traced outline is not always the right answer

Ibiza is one island with one coastline, so following it is obviously right. An archipelago is
often the opposite case: a scatter of small cays with navigable water throughout, where the
water *between* the islands is exactly what you want photographed. There, one larger regular
polygon over the whole group is both easier to draw and more useful than a dozen careful
tracings, and the tiles it adds are not waste.

The question is never "trace or box". It is **where would I take the boat** - and then draw
the smallest shape that contains the answer.

## Snapping to the grid

Turn on **`grid`**. Small grey dots appear at tile-grid intersections and vertices now
land on them; the number in the row is the level being snapped to.

**That level follows what is selected.** For a region it is its `zauthor`. For a detail area
it is **one finer than its parent's `zmax`** - the coarsest level the detail area itself
supplies, which for Ibiza's bays is z17. It is not the detail area's own `zmax`, and the
difference is the whole use of the grid here: tile grids nest, so a boundary put on a z17
intersection is on a z18 one as well, while a boundary put on a z18 intersection can still cut
a z17 tile in half. Snapping at the coarser level is what makes two neighbouring detail areas
land on different tiles rather than sharing one.

It is off by default, because a constraint you did not ask for is indistinguishable from a
bug the first time a vertex lands somewhere other than where you clicked. Hold a modifier to
suspend it for one vertex.

Two reasons to use it.

**Whole tiles instead of slivers.** A boundary that runs through the middle of a tile still
pulls that whole tile in. Snapping means your outline and the tiles agree.

**Two regions that meet.** This is the real one. If you later add a region for Ibiza's east
coast that abuts one of these bands, draw both boundaries onto **the same grid
intersections**. The two vertices are then computed from the same integers and are identical
to the last bit - so the seam is exact, with nothing recorded, nothing linked and nothing to
get out of date. That matters because of an asymmetry:

- A **gap** between two regions is water your chartset does not carry. On the plotter it is
  revealed sea with nothing painted under it, and no care later recovers imagery that was
  never built.
- An **overlap** costs some duplicated tiles. Untidy, and completely harmless.

Exactly shared boundaries cannot produce a gap. Horizontal and vertical seams - and the
stair-steps you make of them - cost nothing at all; a diagonal seam is gap-free but every
tile it crosses is claimed by both sides. Neither is forbidden, and chartMaker never rewrites
your line.

## Containment

A detail area cannot leave its parent, and you will feel the rule rather than read about it.
Drag a vertex towards the parent's edge and the outline follows you until the boundary, then
stops while your cursor carries on. Nothing is moved somewhere you did not put it, and nothing
is announced. The wall is simply there.

Two more things are refused the same way, and both are put back where you picked them up,
with a line in the bar saying which:

- **an edge that would cross another polygon** - the parent's outline, another detail area, or
  another part of this one
- **a polygon that would cross itself**

Two detail areas may **touch**, and a detail area may sit hard against its parent's boundary.
Neither is an overlap. If you want them to share a line exactly, switch the grid on and put
both vertices on the same intersection.

The reason all of this can be strict without fighting you is that ground outside the parent
was never a detail area in the first place. What you want there is another polygon on the
region, or another region.

Save the set - `File - Save`.

---

**Next:** [Choosing a Source](choosing_a_source.md)
