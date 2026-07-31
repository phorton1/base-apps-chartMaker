# chartMaker - Build

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_leaflet.md)** --
**[Tree Editing](editing_wx.md)** --
**[TSD](tsd.md)** --
**Build** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

*This document is partially written. The tile proxy, the cache and the preview modes are
settled and described below. The queue, resume and the exporter seam are not yet
specified.*

## Everything goes through the proxy

chartMaker has exactly one path from a tile coordinate to bytes, and every part of the
application uses it - the map in the browser, the preview, the evaluator, and the build:

```
    requester ---> proxy ---> cache ---> fetch ---> the source
```

The browser never contacts a tile server directly. It asks the application for
`/tile/<source>/<z>/<x>/<y>` and the application answers, which is what makes four
otherwise unrelated properties true at once:

- **No credential ever reaches the browser.** A source that needs a key is fetched by the
  application, which holds the key. Nothing in the page, and nothing in the page's network
  log, contains a secret. See [TSD](tsd.md#credentials).
- **Display and build share one cache.** Looking at a region at a zoom it will be built at
  puts those tiles in the cache the build will read. Nothing is fetched twice.
- **The refusal to prefetch becomes observable.** One place counts and logs every outbound
  request, so "chartMaker never fetches beyond what it is displaying" is a property that
  can be checked rather than a claim in a document.
- **Rate limiting has one home.** Concurrency and interval limits are applied where every
  request passes, so no code path can bypass them by accident.

**Cache reuse is not prefetching.** Previewing a region fills cache entries the build will
later read, and that is deliberate. The distinction the application maintains is that
nothing is ever fetched which was not displayed; the cache simply remembers what was.

## The cache

The layout, its keying by source, and why the source dimension is not optional are
specified in [Implementation](../implementation.md#temp_dir---everything-regenerable).

Two rules belong here rather than there:

**Misses are cached too.** A tile that a source does not have is recorded as absent. This
is what accumulates a real coverage picture for a remote source over time at no cost, and
it stops every rebuild from re-requesting tiles already known to be missing. It is also
why coverage never has to be declared in a source.

**Absence is not always an error code.** Some services answer a request for a tile they do
not have with a uniform blank image and HTTP 200. Hashing tiles catches that case, which
matters because the alternative is a chartset full of grey squares that the application
believed were imagery.

## Rasterisation has two entry points

The coverage model answers "which tiles" in two different shapes, and both come from the
same computation over the same region geometry:

| Entry point    | Question                                    | Used by   |
| -------------- | ------------------------------------------- | --------- |
| **predicate**  | is tile z/x/y in coverage at this zoom?     | preview   |
| **enumerator** | list every tile in coverage, in build order | the build |

Keeping them one implementation is what makes preview meaningful. If the browser decided
coverage for itself, preview would be an illustration of the build rather than a test of
it, and the two would disagree at exactly the seams where disagreement is most expensive.

## Filling the cache is a separate act from building

The exporter fetches nothing. An uncached tile is simply absent from the card: the miss bit
is set and the plotter overzooms from a present ancestor, which is exactly the behaviour the
format is designed around. That is right for the exporter and wrong as a way to acquire
imagery, because the failure it produces is invisible. Reshaping an existing area rebuilds
happily from what browsing already cached; **new ground at depth has never been fetched**, so
the card comes back with holes that the plotter papers over. It looks soft rather than
broken, which reads on the water as "the imagery is bad there" instead of "we never fetched
it."

So filling the cache is its own command - it walks the same enumerator the build walks and
asks for each tile in turn - and the build remains a pure read of whatever is there. Two
properties come out of keeping them apart:

**Resume is free, and therefore unspecified.** The request path is cache first, so a run that
is interrupted asks the network only for what the previous run did not reach. Nothing has to
record where it got to.

**Errors are never cached, so a failure is not permanent.** An absence the source asserted is
recorded and never asked for again; a timeout or a refused connection is not, because it says
nothing about whether the tile exists. What that costs is the possibility of a dead source
producing thousands of identical failures, so a run stops after a small number of consecutive
errors rather than working through the whole region. Stopping poisons nothing - running it
again after fixing the source resumes.

**Each node is filled from the source it will be built from**, with `inherited` already
followed: a subregion that names its own source has its tiles fetched from that source, not
from its parent's and not from whatever the map happens to be displaying. Filling from the
displayed source would fill entries the build will never read, which is the same invisible
hole by a different route.

This is not the queue. It is serial, it has no concurrency and no retry policy, and it
honours only the interval a source declares. The engine specified below replaces it.

## Editor and preview are one component in two modes

The same map, the same proxy, the same tile layer. Preview adds a clip and a cap:

**Source view** shows the build source everywhere, unclipped. This is the mode for deciding
where a region should extend to, because it shows what is out there beyond the boundary.

**Preview** shows what the chartset will actually contain:

```
    in coverage at this zoom  ->  the build source's tile
    not carried at this zoom  ->  nothing - the context layer shows through
    outside coverage entirely ->  the context layer, visibly dimmed
```

**The middle line has no fallback, and that is the design rather than an omission.** A
plotter answers a request for a tile the card does not hold by magnifying the deepest
ancestor it has, and preview reproduced that at first. It made the built edge unreadable:
real imagery and magnified imagery look alike, so the card appeared to extend a long way
past where it actually stopped - a halo of progressively coarser imagery, one tile wider at
each level, which is genuinely what a plotter shows and is useless for deciding anything.

What an author needs is the opposite. **Zooming in until the imagery stops is the answer to
"how deep did I build here"**, read directly off the map, and it only works if the imagery
actually stops.

**And it is client independent, which is the stronger reason.** A fallback render is a model
of one consumer's behaviour: the E-Series magnifies the deepest tile it holds, OpenCPN allows
essentially unlimited overzoom from the deepest level in the file, and neither is a fact
about the chartset. What the card *contains* is the same answer whoever reads it - so this
mode stays true as consumers are added, and needs no evidence about any of them to be
trusted. A simulation would need to be validated against every client it claimed to
simulate, and would be quietly wrong the moment one changed.

**Depth is spatial, not a number.** A detail area is carried several levels deeper than the
ground around it, so at one zoom the same screen shows imagery inside the detail area and
bare context outside it. That difference IS the information.

**The tile footprint comes with it.** Filled tiles alone do not say where a tile ends, and
the edge of the built area is what preview is for - so preview turns the footprint on and
pins it to the map's zoom, and the two answer the same question at the same level: the
outlines say which tiles are on the card, the fill says what is in them.

**A tile the source does not have is drawn as a hole**: a muted orange rectangle with a pale
outline. Orange because it has to be findable at a glance against dark water; muted because a
region that has never been fetched is a screen full of them and a bright colour would be
unreadable; outlined because fill alone disappears into brown coastline at low zoom. It is
deliberately the most conspicuous thing preview can show, since a hole in a card is invisible
on the plotter - it overzooms an ancestor and simply looks soft.

The context layer is **visually marked** - dimmed or desaturated, with the coverage
boundary drawn over it. A user who sees imagery and assumes it is in their chartset is
preview failing at its only job, and "colour means it is in the card" is a rule learned
once and never misread.

Preview generates viewport-shaped traffic exactly as browsing does. It never walks the
coverage; it fetches what is on the screen at the zoom being viewed.

## What the build validates before it runs

Two checks belong to the build rather than to a region, because neither is a property any
single region can hold.

**Every region in one output folder must agree on `zauthor` and `zmin`.** This is
structural, not stylistic: the E-Series firmware holds those two on the chartset - it fuses
every `.RCT` on a card into one pyramid and indexes it as `zdir[z - zmin]` - so they are
properties of the *set*. Each file carries the set's values redundantly, which is exactly
what lets a card be defined by which files are present rather than by a manifest, and lets
the consumer check agreement instead of trusting a declaration.

The failure it prevents is the one the format cannot absorb. The reveal aperture is cut at
the coarsest `zauthor` on the card; if that level is finer than some file's `zmin`, that
file has no tiles at the outline level, contributes no outline, and its imagery sits on the
card fully built and permanently invisible. So the build reports which region disagrees and
with what, rather than producing a card that is silently wrong. Given the convention it will
almost never fire.

`zmax` is genuinely per-region and must not be forced to match.

**The exported card file name must be a genuine 8.3 short name.** Asserted at export, for
reasons that are only visible from this side of the boundary - see
[RCT](rct.md#two-constraints-only-chartmaker-can-see).

**The tiles must be in a format the exporter can carry.** RCT holds JPEG. A source may
legitimately declare `png`, and nothing stops such a source declaring `build` in its
`uses` - so the combination is reachable without anybody doing anything wrong.

The exporter copies cached bytes into the blob table without inspecting them, which is
what keeps an image stack out of the build and is worth keeping. The consequence is that
a PNG source yields a structurally valid card full of bytes the plotter cannot decode:
built, reported as successful, and blank on the water. That is the worst failure this
application can produce, because every signal says it worked.

So the build refuses, naming the source and its format, rather than writing that card.
The check survives format conversion arriving later - it becomes the place a format that
still cannot be carried is refused, instead of the place every non-JPEG is refused.

## Block decomposition is a budget, not an optimisation

The [RCT](rct.md) exporter groups each zoom's tiles into rectangular coverage blocks, and
how it groups them is not free in either direction.

Splitting saves disk: a block pays an index entry and a presence bit for every cell of its
rectangle, present or not, so one block spanning two distant clusters pays for the empty
span between them. Splitting costs elsewhere, and the expensive one is not disk. The
firmware builds its reveal aperture as a list of screen rectangles closing one run per tile
row, **closing runs at block edges as well as at absent cells**, out of a fixed budget
shared across every file on the card. Fragmenting a zoom into many blocks spends that budget
on seams rather than on coverage, and exhausting it makes the overlay reveal the whole
plane - imagery spilling past the polygon at wide views.

So the rule is **few, large blocks**, and a deep-detail area is one block rather than
several. The disk cost of an empty cell is eight bytes; the cost of an exhausted rectangle
budget is the aperture ceasing to mean anything.

## Still to specify

- **The queue** - concurrency, interval limiting, retry policy, and the failure
  classification that distinguishes a rate limit from a missing tile from a dead source.
- **Resume** - a run of thousands of tiles that is interrupted must continue rather than
  restart. The cache makes this nearly free; what is missing is the specification of what a
  run records about itself.
- **The exporter seam** - what an output format has to implement. The boundary is settled
  (the coverage enumerator plus the cache, with [mbtiles](mbtiles.md) and
  [RCT](rct.md) as peers over it); what an exporter has to provide is not.
- **Progress reporting** - the build is long-running and reports into the application
  without blocking it.
- **Format conversion at the exporter seam** - decoding and re-encoding one tile, which is
  an encoder and not the image-processing stack this application refuses: no resampling, no
  reprojection, no compositing. It carries a quality preference, and that preference is a
  legitimate user-level setting precisely because it changes the bytes without changing what
  the card asserts - the same ground, the same zooms, the same source. Anything that changed
  *those* would belong to the region, not to a preference.
- **Build analysis, and the dry run that produces it.** A build already reads every tile it
  will write, so the facts worth knowing are free at the moment they pass through. Three of
  them are known to be worth collecting: repeated byte-identical tiles, which is how a
  server that serves a "no data here" placeholder instead of a 404 confesses (Esri does this;
  its grey tile is one fixed image); the depth at which a level stops carrying information
  its parent did not already have; and the resulting deepest genuinely-resolved zoom, per
  region rather than per source, because it is a fact about ground and not about a server.

  The output is feedback rather than a decision: it tells the author which zooms are worth
  building, and the author sets `zmax`. What it must also be able to do is act on its own
  findings against the cache - pruning levels that carry nothing, so that disk is not held
  by tiles that will never be written to a card.

  Overzoom is worth stating plainly, because it is easy to read as a defect and is also a
  choice: magnified imagery is not *wrong*, it is the provider's resampling instead of the
  plotter's, and one may legitimately prefer it. What must not happen is shipping it
  unknowingly, at four times the tiles per level, on a card whose space is the binding
  constraint.
- **Source probing** - what a TSD can be *measured* for rather than asserted to be:
  reachability, the format actually served, real depth as against declared `zoom.max`, the
  fingerprints of any placeholder tile, and whether the addressing order is right. The last
  is testable rather than eyeballed - correlating one low-zoom tile against a source already
  trusted collapses if rows and columns are transposed. Deliberately excluded: probing for
  where a server begins refusing, which is the behaviour that earns a permanent refusal.
- **Build notes in the card.** The RCT format can carry a record of how a card was made -
  source, zoom range, encoding, date. chartMaker is upstream of both the specification and
  the renderer, so this is a decision available to be taken rather than a constraint to work
  within.

---

**Next:** [MBTiles](mbtiles.md)
