# chartMaker - things we never did

Ideas that were written down as though they were the program, and are not. Each one is here
because a design document described it in the present tense and nothing implemented it -
which is worse than an idea nobody recorded, because a reader has no way to tell.

**The reasons are the point.** An abandoned idea filed with no reason attached is how it gets
proposed again in two years by somebody who cannot see what was already weighed.

**This is not a backlog.** Nothing here is scheduled, and being written down is not a claim
that it should happen.

---

## Containment maintained rather than refused

`regions.md` said, in the present tense, that the application *maintains* a subregion inside
its parent rather than merely checking it, and described both directions:

- dragging a subregion outside its parent expanded the parent to contain it
- shrinking a region clipped its subregions to the new boundary, or removed the ones with
  nothing left inside, **asking first** and naming what would be lost

None of it was ever built. What the application actually did was refuse the edit and roll the
region back to its last accepted state.

**Decided against 2026-08-07, and the reason is cost against benefit.** Maintaining
containment means real polygon boolean operations - `child := child AND parent` for the
clip, `parent := parent OR child` for the grow - and they would be needed **twice**, once in
Perl for the model and once in JavaScript for the applet, agreeing exactly. There is no
polygon boolean library in this Perl. Refusing needs one primitive, *do these two segments
cross*, which is thirty lines and the same thirty lines in both languages.

And the benefit is smaller than it looks. A refusal the author can see and correct is not
worse than an automatic edit to a drawing they did not ask for - it is arguably better, since
the alternative silently reshapes work while they are looking somewhere else.

**What replaced it** is a refusal that is now accurate rather than approximate: vertices and
edges instead of vertices alone, plus siblings, plus a node's own polygons, plus
self-intersection. See `regions.md`.

## A "snap this boundary to the grid" editor command

`regions.md` described putting a shared boundary on a tile edge as *"an editor command like
any other"*. There was no such command, in the console or the tree or the applet.

**Not built, and superseded rather than abandoned.** The useful half of the idea arrived by a
different route: the snap grid, which is per object and now lands at the object's own authored
level - `zauthor` for a region, `parent.zmax + 1` for a subregion. With it switched on, every
placement is on an intersection, so a boundary put on a grid line is put there by the person
drawing it rather than by a command applied afterwards. Alt suspends it for one placement.

A command would still be a reasonable thing to want for an *existing* boundary drawn before
the grid was switched on. Nothing needs it yet.

---

## Not here, and deliberately

**Coincident vertices welded across touching regions** is not in this file. It is not an
abandoned idea - it is a **real, unaddressed problem**: drag a vertex on a shared boundary and
a gap opens in the neighbour, and a gap is the one failure the union rule cannot absorb. It is
stated as an open problem in `regions.md` itself, where somebody looking at that machinery
will meet it, rather than filed here where it would read as closed.
