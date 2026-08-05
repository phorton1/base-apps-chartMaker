# chartMaker - Editing

**[Design](readme.md)** --
**[Regions](regions.md)** --
**Editing** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Key Store](key_store.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)** --
**[Cleanup](cleanup.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

Where [Regions](regions.md) describes what a region **is**, this document describes the
rules for **changing one** - and it describes them for no particular user interface.

Two surfaces author the same model: the region tree in the wx application, and the map in
the browser. Both are first class, and anything that can be authored can be authored from
either. That is only safe if there is one set of rules above both of them, and this is that
set. A disagreement between the two surfaces is then a bug against something written down,
rather than a matter of taste.

The interfaces themselves are described separately:

- **[Map Editing](editing_map.md)** - the Leaflet applet, where geometry is drawn
- **[Tree Editing](editing_tree.md)** - the wx region tree, where the whole set is visible

## The one invariant

> **Both surfaces are peers over one vocabulary and one validator.** Neither has a private
> path to the model. Every mutation either makes is the same verb, checked by the same
> rules, landing in the same file.

A surface may check something *earlier* than the validator does - warning about an id
collision as it is typed rather than on submit - but it may never be the only thing that
checks it. Early checking is a better error message, never a different rule.

## What can be edited

| Object | Created | Has geometry | Deleted |
| ------ | ------- | ------------ | ------- |
| region set | File - New Set | never | outside the application |
| region | named, empty | one or more polygons | removes its file |
| subregion | named, empty | one or more polygons | rewrites its parent's file |

**Named-and-empty is a legitimate state** for a region and a subregion, not a half-created
one, and it is what makes "create, then draw" recoverable: an interruption between the two
costs a drawing, never a named thing.

**The region file is the unit of persistence.** A subregion has no file of its own, so a
change to one is a change to its root region's whole file. Nothing written to disk can
therefore be finer-grained than a region, no matter which object is selected.

**And nothing is written until the set is saved** - see
[Regions](regions.md#a-set-is-a-document). The two ideas compose: what an edit changes is a
region, and what a Save writes is every region that changed.

# Modes

A mode answers exactly one question: **what does a click on the map do?** There are three,
and each carries a **target** - the object it is acting on.

Only the map has modes, because only the map has a pointer over geography. They are here
rather than in [Map Editing](editing_map.md) because the *tree* has to obey them, and a
rule one surface enforces on behalf of another belongs above both.

```
BROWSE    A click SELECTS whatever is under it.
          Target: none.

SHAPE     A click or drag manipulates the SELECTED POLYGON's vertices:
          move one, insert one at a segment midpoint, delete one.  Its
          handles are visible.  The polygon itself is never moved as a
          whole - a drag on the map is always a PAN.
          Target: one polygon.

DRAW      A click APPENDS a vertex to a polygon being created.  Ends by
          CLOSING (three vertices minimum) or by being ABANDONED.
          Closing leaves the new polygon selected in SHAPE; abandoning
          restores what was there and returns to BROWSE.
          Target: the object gaining a polygon.
```

**The target is a parameter, not a mode.** Drawing a region's outline and drawing a
subregion's are the same mode pointed at different objects; so are adjusting one polygon and
adjusting another. Splitting them would multiply the rules below without changing any of
them.

**Entering SHAPE is automatic on selecting a polygon.** Requiring a separate "edit this
shape" action would add a click to every single adjustment, to protect against a nudge that
Revert already undoes for free.

## Dirty is not a mode

Whether there are uncommitted changes is a **separate fact**, true or false in any mode:

- dirty in **BROWSE** - a region was renamed, or its zooms changed, and not yet saved
- clean in **SHAPE** - a polygon is selected with its handles up and nothing has moved
- dirty in **SHAPE** - the ordinary case, a vertex has been dragged
- dirty in **DRAW** - vertices have been placed but the ring is not closed

Conflating the two produces a model with nowhere to put vertex editing, which is the one
thing this whole document exists to describe.

## The mode is shared state, not the browser's private business

The mode, its target and the dirty flag are published by the application to everything that
displays the model, for one concrete reason: **the other surface can destroy what is being
edited.** Deleting a region in the tree while the map is drawing it, or switching the active
region set out from under a half-dragged vertex, are both reachable in one click otherwise.

So it is not an announcement, it is a constraint on both surfaces:

- The application knows the mode, its target, and whether that target is dirty.
- Every surface can see all three, and each is responsible for refusing what they forbid.
- A **dirty** object, and the polygon being built in DRAW, are **not rendered from the
  model** by anybody. The surface holding the edit draws from its own copy; every other
  surface leaves it alone. Without that rule a poll hands the old geometry back mid-drag and
  fights the user's hand.

A clean SHAPE needs none of that suppression: nothing has diverged from the model, so
everybody can draw it from the model.

## What is legal

**Dirty is what constrains, not the mode.** A clean SHAPE is as free as BROWSE: handles
being visible has never put anything at risk. DRAW is the exception, because it is holding
an unfinished ring that any other action would strand.

| Action | clean (BROWSE or SHAPE) | dirty (BROWSE or SHAPE) | DRAW |
| ------ | ----------------------- | ----------------------- | ---- |
| select something else | yes | **refused** | no |
| open, close or revert the set | yes | **asked**, naming what is lost | **asked** |
| edit properties of the dirty object | yes | yes - staged with the rest | no |
| delete the dirty object | yes | **refused** | no |
| delete some *other* object | yes | yes | no |
| create anything | yes | **refused** | no |
| build | yes | **refused** | no |

**Refused, not queued and not auto-saved.** The refusal names the object and the two ways
out - Save or Revert - because a user who cannot tell why the application stopped responding
to a click will conclude it is broken.

DRAW forbids the lot because it is transient and self-terminating: Close it or abandon it,
and both are one keystroke.

**Nothing is built from a dirty model.** The refusal is worth its irritation - a file
built from what is on disk while the screen shows something else is a discrepancy that only
turns up on the plotter, hours later, where it cannot be explained.

# What makes a shared boundary correct

Two regions in one set that meet along a boundary are the one case where editing one object
can silently damage another, so the rule belongs here rather than in either interface.

## Nothing is tracked, and nothing is repaired

There is **no stored relationship between regions** - no binding, no seam object, no list of
shared vertices. A region file refers to nothing outside itself, which is what makes it
mailable, and a cross-reference would take that away.

Nor is a boundary ever **rewritten** on the author's behalf. Geometry is stored exactly as
drawn, so a diagonal stays two vertices; converting it into a staircase would leave a seam
that could never be edited as a line again.

What replaces both is arithmetic: **two vertices snapped to the same grid intersection are
computed from the same integers, so they are identical to the last bit.** Coincidence is
exact rather than approximate, which is why nothing needs to detect, record or maintain it.
See [Map Editing](editing_map.md) for the snapping itself.

## Gaps and overlaps are not symmetrical

Both are the author's to be aware of and to control, and neither breaks anything downstream.
But coverage is a union and never subtracts, so they are not the same kind of untidiness:

- **A gap** - a strip of tiles that no region claims - is ground the chartset does not carry.
  On the plotter it shows as revealed water with nothing painted under it, and no amount of
  care further down can recover imagery that was never built.
- **An overlap** - a tile claimed by two regions - costs duplicated tiles in the output and
  means the two regions disagree about how deep that water goes. Wasteful and untidy, and
  every tile is still there.

Because the coverage predicate asks whether a polygon **intersects** a tile, an exactly
shared boundary can never produce a gap: every tile along it is claimed by both sides. Which
makes overlap the *safe* failure, and shared vertices sufficient for correctness even when
they are not sufficient for tidiness.

## Tidiness is the author's to choose

| Seam | Result |
| ---- | ------ |
| horizontal, vertical, or stair-stepped on the grid | **zero contested tiles** - the boundary lies along tile edges and enters no tile's interior |
| diagonal, both ends snapped | gap-free, but every tile the diagonal crosses is claimed by both |

Neither is forbidden. The first is worth preferring and worth being told about - a
*contested tile count* is a fact the application can report on demand, and zero is the
number a well-planned set produces.

## The tolerance this rests on

A tile-corner latitude is an irrational value stored as a double and written to JSON at the
platform's default precision, which loses the last few bits. The truncation is deterministic,
so two regions snapped to the same intersection still store the same value and still
coincide - but the stored value sits a fraction off the true tile edge, and with an
intersects predicate a polygon a hair over a boundary claims the tile beyond it.

The coverage predicate therefore carries an **explicit tolerance**: a boundary within about
1e-9 degrees of a tile edge counts as being *on* it. That is roughly four thousandths of an
inch - five orders of magnitude above the float error it absorbs, and seven below the tile it
protects. It also covers hand-edited files and KML imports, which are near-but-not-on the
grid and which snapping cannot help.

# Selection

**One object is selected at a time, or none, and the selection is shared by every surface.**
Selecting on one moves the other. It is application state for the same reason the mode is:
two surfaces cannot agree about what "delete" means if they each have their own idea of what
is selected.

Selection is not an edit. Selecting costs nothing, commits nothing, and can always be
undone by selecting something else - except while an object is dirty, where it is refused.

# Committing

## Three classes, and only three

| Class | What | Reaches the model | Reaches disk |
| ----- | ---- | ----------------- | ------------ |
| **Staged** | name, id, zauthor, zmin, zmax, geometry | on **Save** in the panel | on **Save** in the File menu |
| **Immediate** | show/hide on the map, active source | on the action | never - it is not model data |
| **Structural** | creating or deleting a region, subregion or polygon | the action IS the change | on **Save** in the File menu |

**TWO SAVES, AND THEY ARE NOT THE SAME ONE.** The panel's Save takes a half-typed object
into the document; the File menu's Save writes the document to the folder. The first is
about one object and happens constantly; the second is about the whole set and happens when
you decide it should.

Geometry and properties are staged together because they belong to one object: an object is
dirty or it is not, and **Save commits all of it**. There is never a half-saved object whose
two dirty states disagree.

Visibility is immediate because it is not a change to the model at all - it is a statement
about what is being looked at.

Structural actions reach the model immediately because there is nothing to stage: a region
that half-exists is not a state the model can hold. They reach the disk with everything
else.

## Save and Revert

**Save** writes the dirty object into the document. **Revert** discards it back to what the
document last accepted.

Revert is not a convenience. Staged geometry makes it necessary: after dragging five
vertices and deciding it was wrong, the only other way back is dragging them individually to
where they are guessed to have been. It is also what makes refusal-on-dirty a reasonable
answer instead of a trap, since both exits are always one action away.

Both appear on both surfaces and mean exactly the same thing.

# Context changes

| What happens | Result |
| ------------ | ------ |
| select another object while dirty | refused, naming Save and Revert |
| open, close or revert the set with unsaved work | asked, naming both kinds - what the document holds and what the map holds |
| the open set's folder is deleted underneath it | the document is unaffected; it is in memory, and Save recreates what it can |
| the map stops polling mid-edit | the edit is presumed gone, and the state it left is cleared |
| the application disappears mid-edit | the map ends the edit and clears, because a mode it cannot publish is a mode nobody owns |

# What the application must publish

Everything above reduces to three facts that every surface needs and none may own privately:

1. **the selection** - which object, or none
2. **the mode** - and, for DRAW and EDIT, which object it applies to
3. **the dirty flag** - so a surface that is not holding the edit still knows one exists

They travel in the same state document as the regions, the sources and the open set,
behind the same version counter, so no two surfaces can be out of step about them.

# Containment is enforced, not reported

**A subregion's geometry cannot leave its parent.** A vertex placed outside is refused - not
relocated to the boundary, and not accepted and complained about later.

The reason it can be this strict without fighting the author is that an out-of-parent area
is **not a subregion at all**. A subregion exists to add resolution inside an aperture its
parent already opened; ground outside that aperture has no parent detail to deepen, so
asking for it is not an edit that needs permitting. What the author wants in that case is
either **another polygon on the parent** - regions and subregions both carry as many as they
like - or **a separate region**. Both are one menu item away.

Refusing the placement rather than moving it matters: relocating a vertex silently overrides
where the author pointed, which is the one thing snapping is careful never to do.

# Undo is Revert

**Revert** restores the selected object to what is on disk, and that is the whole of undo.

Per-vertex undo *within* a drawing is the one exception, and it is the applet's own: the
drawing bar drops the last vertex placed, because an unfinished ring belongs to the surface
holding it and nothing has to be remembered to unwind one.

Stepping backwards through individual drags in SHAPE would need a history that nothing
keeps, and undoing a *committed* edit is a different thing again - it would mean journalling
what passes through the command dispatcher, which is the one place every mutation from every
surface already goes.

# Contested tiles are a build-time analysis

The contested-tile count is **not** a live readout and not a per-seam report. It is computed
where the other whole-set checks are computed: at build time, beside the check that every
region built together agrees on `zauthor` and `zmin`.

Both are reported and neither stops a build, but they are worth keeping straight:

- **Disagreeing `zauthor` or `zmin` matters only where files fuse.** On an E-Series card
  every `.RCT` is merged into one pyramid, so those two are properties of the chartset and
  the odd file out can be built and then never drawn - its imagery present in the file and
  permanently invisible. Where an output's files are independent charts there is nothing to
  agree about, and nothing is said.
- **Contested tiles are wasteful.** Duplicated imagery and two regions disagreeing about
  depth in the same water, from perfectly readable files.

Neither is refused, and the reason is the same in both cases: trying a new `zauthor` on one
region before converting a whole chartset is a legitimate thing to want, and the author is
the one who can tell an experiment from a mistake. See [Build](build.md).

That placement also means the answer costs nothing until it is worth knowing. Coverage is
already being enumerated for the whole set at that moment, which is the only time the
question is cheap to ask.

---

**Next:** [Map Editing](editing_map.md)
