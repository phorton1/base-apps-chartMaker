# chartMaker - plan: overlap, sources and polygon constraints

**TEMPORARY. Claude's working plan, not a document. Delete when the work is done.**
It exists because the work spans more context than one conversation holds, and because
several of the findings underneath it took hours to establish and must not be re-derived.

Written 2026-08-07, from the session that began with a packaged build failing to write
`Ibiza.rct`.

---

## The findings this rests on

**`aerial.c` does not need disjoint rectangles.** `block_for` scans every block at a zoom
and tests `block_has`, which is range AND presence in one test, so overlapping rectangles
are legal. Blocks from every `.RCT` are fused into one `zoomdir_t` at mount, so within-file
overlap is indistinguishable from the cross-file overlap every card already has. `draw_level`
iterates the view rather than the blocks, so a cell is drawn once however many blocks hold
it. `build_mask` says overlap "would be correct but wasted", and clamps its cut to
`zauthor`, so overlap finer than that costs nothing at all. **The Ibiza build we refused
would have worked.**

**What it does need is that duplicates be the same imagery.** Two blocks that both mark a
tile present are chosen between by array order, which comes from FAT directory order in
`\RASTER`. Identical bytes make that a don't-care; different sources make it silent and
arbitrary. The 48-byte descriptor is fully consumed - there is no priority field, so a
preference cannot be expressed without a format change.

**The per-node coverage sets are a COVER, not a partition.** `_walk` builds each node's set
from its own polygon and nothing ever compares two nodes. Ibiza's Xarraca and Portinatx have
zero polygon intersection and still share 2 tiles at z17 and 1 at z18, because a tile is a
square both polygons clip. Innermost-wins exists but resolves parent-versus-child source on
the MERGED view; there has never been a rule for sibling versus sibling.

**Within a file, coverage should be a partition; across files it is deliberately a cover.**
A parent and its child never share a zoom (bands), so inside one file only siblings and
cousins can collide, and that collision is pure discretisation noise. Across files, adjacent
regions share identical coarse parents by construction and must, or a single `.rct` could
not stand alone. That one is made safe by the source rule, not by geometry.

**Blocking is CLOSED, not deferred.** Measured on Ibiza z17: one block per node = 253 cells
over 4 blocks; connected components = 296 over 3 (worse); one union block = 6,120 (24x
worse). Index overhead is 460 bytes against ~1.6 MB of JPEG at that level, 0.03%. Panama
duplicates 43 tiles of 25,843 across five files, 0.2%. The authoring tree is a better
clustering heuristic than either generic algorithm, because a human drew each cluster. The
one configuration where the number would not be small is a single node holding two distant
polygons; the cheap response to that is a preflight line saying a block is 12% full, not an
optimizer.

**Per-vertex containment is not containment, and it is defeatable by an ordinary gesture.**
`outsideVertices` tests vertices only and says so. Patrick reproduced it: cut a concave notch
into a region, then drag a subregion vertex around the notch. Every vertex is inside, an edge
is outside, and the applet, `_checkContainment` and the commit all accept it. What it breaks:
the nested-coverage invariant, so `my_test_rct.pl`'s "every present tile has a present parent"
would report orphans; and on the E80 that imagery is written and can never be revealed,
because the aperture is cut at `zauthor` from the region's own blocks.

**A subregion's authored level is `parent.zmax + 1`.** Derived, not stored, which is why it
keeps getting lost. It is the floor of the node's band and therefore the coarsest level the
node occupies, which makes it the level that matters wherever two nodes can collide - tile
grids are nested, so a boundary aligned there is aligned at every finer level too.

---

## The decisions taken

1. **Refuse, do not maintain.** Containment is enforced by refusal, not by clipping children
   or growing parents. That was the documented design and it was never built; building it
   needs polygon booleans in both Perl and JS. Refusing needs only segment intersection.
2. **Two constraints, two behaviours.** A POSITION constraint (is this vertex allowed to be
   here) is point-in-polygon, tested every drag event, refused by not writing the position -
   the wall you slide along, which already exists and stays. A TOPOLOGY constraint (would
   this edit make an edge cross something) is segment intersection, tested once at the drop,
   refused by putting the vertex back where it was grabbed, with a message.
3. **Geometry is for the user; tiles are for the walk.** They are different arithmetics and
   neither implies the other. Disjoint polygons still share tiles. So the walk must subtract
   regardless of how clean the drawing is.
4. **Warn, never refuse, on source conflicts.** Same precedent as the `zauthor`/`zmin` guard,
   which Patrick chose as a warning deliberately.
5. **Check geometry on edit and on build, never on load.**
6. **Tolerance: quantise the comparison, never the data.** Round to 9 decimal places for the
   topology test only. A pixel at `MAP_MAX_ZOOM` 22 is 3.4e-7 degrees; 1e-9 is ~340x finer
   than that and ~1e7 coarser than double noise. Geometry stays stored as drawn.

---

## Work, in order

### 1. Unfail the build - `dm_rct.pm`

`_checkDisjoint` stops refusing on overlapping rectangles. It refuses only two blocks holding
one tile from **different sources**. After item 2 that can no longer happen by accident.

### 2. Make the tile sets a partition - `dm_rct.pm`, NOT `dm_coverage.pm`

Subtract in walk order so no tile is claimed by two nodes. Silent, never reported, provably
never worse in bytes (subtracting can only shrink a bounding box), and it removes the
duplicate blobs `writeRct` currently writes. Sibling tiebreak is walk order.

**IT MUST NOT GO IN `_walk`, AND MBTILES IS THE REASON.** `dm_mbtiles::writeMbtiles` calls
the same `regionCoverageNodes` and writes **one file per node**. Subtracting in the shared
walk would take a tile out of one node's file while its sibling keeps it - so an individual
`.mbtiles` would no longer be complete over its own polygon, and a user opening that one file
alone would have a hole in it. In an RCT the same subtraction is pure gain, because every
block lands in one file and the plotter fuses them anyway.

So the two formats want opposite things and both are right:

- **RCT: partition.** One file, and two blocks claiming one tile is the condition worth
  refusing. Subtract in `_planBlocks`, where the one-file constraint actually lives.
- **MBTiles: keep the cover.** Each file stands alone over its node's polygon. Two files
  holding one identical tile costs a couple of KB and OpenCPN picks either.

`dm_coverage` keeps telling the truth - each node covers what its polygon covers - and the
exporter with the constraint is the one that resolves it. That is the same argument that put
the sentinel check and the cache write in `dm_engine` rather than in a caller.

### 3. The source-conflict check - new, plus `dm_build.pm` / `dm_analysis.pm`

One question over the open set: does any tile at any zoom resolve to more than one source.
Pure geometry plus the source map, milliseconds, no fetching. Reported as a WARNING in the
preflight and in `analyse`, in the author's vocabulary - names the two nodes, the levels, the
count, the consequence. Never refuses.

Measured already: Panama is clean (all five on `esri_world_imagery`). The `Example` set in
`base_data` has Ibiza on `ign_es_pnoa` and Formentera with NO source, sharing 8 tiles at
z10-z13 - not a live conflict, because an unsourced region refuses to build, but the set the
manual teaches is one source assignment away from it.

### 4. The polygon constraints - `_res/site/cmEdit.js` and `dm_region.pm`

One primitive, segment-versus-segment, four uses: the bowtie (a ring against itself), two
polygons of one node, two siblings, and true containment (child edges against parent edges,
plus one point-in-polygon to rule out "entirely outside").

- Applet: position test per drag event as now; topology test at the drop. Needs the pre-drag
  position captured on `dragstart` - `moveVertex` overwrites `working` on every drag event,
  so by mouseup the original is gone. For a midpoint drag, "put it back" means removing the
  inserted vertex.
- `dm_region::_checkContainment` becomes the same edge test. It is the backstop for the
  console, the tree and files that arrive from elsewhere. Same rule, two implementations,
  same tolerance constant - they must agree, and if they drift the applet lets something
  through and Confirm refuses it, which is the right failure direction.
- Also asked at build, because a file that arrived from elsewhere was never edited here.

### 5. The grid level - `_res/site/cmEdit.js`

`snapLevelFor` returns `node.zauthor` when there is one and falls back to `node.zmax`. Only
regions carry `zauthor`, so a subregion snaps to its own `zmax` - one or more levels finer
than the floor where siblings actually collide. It should be `parent.zmax + 1`. This is a
convention the user may use, not an enforcement, and it does nothing unless the grid is on.
Alt already suspends snapping.

---

## Docs - and the demotion is half the job

**WHAT IS INCLUDES THE WORK ABOVE.** Not being implemented today is not the test - the docs
will describe the program as it will be when this lands. The test is judgement: is this
something we are building, something we decided against, or something we claimed and never
enforced and are not going to. Three different answers, three different destinations, and
none of them arrived at by grep.

**`docs/design/regions.md`** - the containment section is rewritten rather than demoted. The
INVARIANT survives untouched: a subregion lies within its parent. What changes is the
mechanism, from maintained to refused, and from vertices to edges.

Decided against, so demote to `docs/notes/things_we_never_did.md`:

- *"the application **maintains** that rather than merely checking it"*, with the two bullets
  - the parent expanding to contain a dragged subregion, and shrinking a region clipping or
  removing subregions and **asking first**. We chose refusal, and the reason belongs with it:
  maintaining needs polygon booleans in Perl AND in JS, agreeing exactly, while refusing needs
  only segment intersection, and a refusal the user can see and fix is not worse than an
  automatic edit to their drawing.
- *"'snap this boundary to the grid' is an editor command like any other"* - stated as a fact
  about a command that does not exist and that nothing plans to build. Item 5 makes the grid
  land at the right level, which is the useful half of the same idea.

**Known and unaddressed, which is NOT the same as never did** - do not file it as closed:

- *"the editor has to treat coincident vertices on touching regions as one vertex, moved in
  both regions at once"*. Phrased as a requirement, and it is a real one: without it, dragging
  a shared boundary in one region opens a gap in its neighbour, and a gap is the one failure
  the union rule cannot absorb. It is not built and this work does not build it. It should be
  stated as an open problem in `regions.md` itself rather than moved to a file of abandoned
  ideas.

**What regions.md gets right and only needs extending:** it already says *"Overlap between
siblings needs no special handling... the union absorbs it"* and *"duplicate tiles at a seam
are harmless downstream - they are byte-identical when the source is the same"*. The design
was right and the exporter contradicted it. It needs the tile-level resolution and the
different-sources case.

**`docs/design/rct.md`** - the disjointness finding, plus one correction I owe it: its
prefer-fewer-blocks argument rests on the reveal aperture's 128-rect budget, and `build_mask`
clamps its cut to `zauthor`, so that argument applies at `zauthor` and coarser only. Block
counts finer than that cost the budget nothing.

**`docs/design/build.md`** - the source-conflict check as one of the questions the preflight
asks.

**`docs/design/editing_map.md`** - the position/topology split, and what the applet refuses.

**The format spec**, `Pub/Ray/docs/e80_firmware/deployment/raster_chart_format.md` - PROPOSE
to Patrick, do not write. His wording: any two blocks that both mark a tile present must serve
identical imagery, at any zoom, within one file or across every file on a card. Identical
imagery rather than same source, because a provider can serve different bytes for one
`z/x/y` on different days. See memory `rct-tile-identity-rule`.

## User manual

One user-facing rule in the whole of this: **regions near each other should use the same
source**, because they share their coarse imagery and the plotter picks one unpredictably.
`tutorial/choosing_a_source.md`.

`tutorial/detail_areas.md` gains nothing, and that is the point - a detail area has no rule
to obey. The sibling tile collision is a machine problem, resolved silently, and a user
cannot be told about it usefully: "do not overlap" was already true of Ibiza and did not
help, and "do not let your polygons touch the same tile" is not a rule a person can follow.

---

## Settled

- **Sibling tiebreak is walk order.** Deterministic and reproducible, and where it matters
  the two nodes share a source anyway.
- **`things_we_never_did.md` carries the reasons, not just the claims.** And after today it
  is Patrick's, like `todo.md` - I create it as part of this work and then it is not mine to
  maintain, extend or treat as a backlog.

## The per-vertex containment hole does NOT go in memory

It is real and it is recorded above. But it is a defect this plan removes, so a memory of it
would be stale the day item 4 lands and would then sit there being read as though it were
current. The durable part is already in memory where it belongs: `chartmaker-region-model`
carries that a subregion's authored level is `parent.zmax + 1`, and that is the fact that
keeps getting lost. The bug is not.
