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

*The build act, its guards, the proxy, the cache and the preview modes are settled and
described below. The fetch engine and the exporter seam are not yet specified.*

## Nothing starts without a preflight

A menu item that silently begins a multi-hour process is the wrong shape, and so is a
confirmation dialog at the *end* of one - by then nobody is sitting there to answer it. So
both Fetch and Build go through two dialogs, and **every question a user could be asked is
asked before the first request goes out.**

**One - what, and where.** A checkbox list of the set's regions, and for a build, the output
folder. It is the *build configuration*, and it persists: `region_sets/<set>/build.json`.

**Two - what it will cost.** Tiles to fetch, already cached, and recorded absences, grouped
by source; the estimated time; the size of the card; which cards will be replaced; which
cards are in that folder and are *not* part of this build; and whether the chartset would
disagree with itself. Then Build, Back, or Cancel.

**The configuration is not hidden state, and that is the point of it.** Before it, "what am I
working on" lived only in the user's head and was re-decided at every invocation. Single
region work - which is the typical case, not the exception - becomes "the configuration
selects Bocas", and Build just runs.

**It is written on OK from the first dialog**, not on Start from the second. The analysis is
a read *of* the configuration, so persisting later would mean analysing something that
exists nowhere and shuttling unsaved state between two windows. The consequence is
deliberate: backing out of the analysis keeps the selection. You still meant to select those
regions; you just did not like what it was going to cost.

**There is no file until somebody configures something.** Absence means defaults, the same
rule the preferences file follows - a statement of what was *changed* rather than a snapshot
of everything. A set handed to somebody else carries no configuration unless its author made
choices, and if it does, they can accept it or clear it with one button.

It lives in the set folder, which is safe because the loader scans for `.region` and derives
dirtiness from the `.region` leaves present. The configuration is invisible to both -
**editing it cannot mark the set dirty**, which it must not, or changing the output folder
would demand a save before a build could run, and the build refuses to run dirty.

**What is deliberately not in it:** `zmax`, and anything else that changes what a build puts
on a card beyond *which regions*. Two people with the same region set must be able to get
the same card.

## The output folder is a suggestion

`<RASTER_DIR>/<set>` is where a build goes unless told otherwise, and it can be told
otherwise. That is what makes a trial build possible - somewhere other than the folder you
copy to the card - and it softens rebuilding, because the thing you are overwriting is a
choice rather than a fixed destination.

**The default is created as needed; a chosen one must already exist.** That asymmetry is the
application's standing rule - it creates only the folders it chose the location of - and it
is not pedantry: a nominated path that is not there is far more likely to be a typo, an
unmounted drive, or a configuration copied from another machine than an instruction to build
a tree somewhere unexpected, and building it would look like success while hiding the real
problem. The folder browser's own *Make New Folder* is what creates one, as a user action.

## The build is one act in three phases

```
    VALIDATE   fast, before anything expensive       ->  may refuse
    FILL       ask for every tile in coverage        ->  builds the LEDGER
    ---------  the refusal point  --------------------
    EXPORT     one .rct per region, temp + rename    ->  short
```

**The order is the point.** Everything that can refuse a build refuses before the long
phase, except the one thing that cannot be known until the long phase has run - whether any
tile failed. A build that dies four regions in on something knowable at the start has
already spent the expensive part.

**Fetching is part of building, and that is what makes the refusal honest.** The fill walks
the same enumerator the exporter walks and asks for every tile in it, cache first. So a tile
still missing at export time was never merely un-asked-for: it was asked for and the request
failed. Tiles left by browsing make a build *faster* and are never what makes it *correct* -
a build does not depend on anybody having looked at the region first.

Filling the cache remains available on its own, because it is the half that takes the hour:
an author can fill a region overnight and build in a minute the next morning. Running it
alone refuses nothing, since it writes no card.

## Present, absent, and failed

The cache answers three ways, and the difference exists only for as long as the build holds
it:

| cache says             | means                                | on the card        | the build |
| ---------------------- | ------------------------------------ | ------------------ | --------- |
| bytes                  | the tile                             | written            | fine      |
| a recorded absence     | the source **asserted** it has none  | miss bit, overzoom | reports   |
| nothing at all         | the fetch never succeeded            | miss bit, overzoom | refuses   |

**On the card the last two are indistinguishable.** Both set the miss bit, both make the
plotter magnify an ancestor, both look soft rather than broken. One of them is the truth
about the ground and is correct to ship; the other is a hole that should not be there. The
card can never tell them apart - the build can, and only at the moment the tile passes
through it.

So an asserted absence is **information, not a warning**. It is the normal edge of a
source's coverage, retrying will never change it, and calling it a warning teaches the user
to ignore warnings.

**The exporter does not decide any of this.** It still copies cached bytes without
inspecting them and still fetches nothing; it only counts the two kinds of missing
separately. The refusal lives in the build, which holds the ledger, because the format
tolerates a hole *because it must* and that tolerance is not a quality standard.

## What a refusal costs

Nothing, and that is deliberate. A build that refuses has written no card at all - not a
partial one, not an earlier region's. Every `.rct` is written to a temporary name and
renamed only on success, so a cancel, a crash or a full disk cannot leave a file that looks
like a card and is a fragment. A cancelled or refused build leaves the folder exactly as it
found it.

Both refusals that a user might legitimately disagree with - unsaved edits, and tiles that
never arrived - have an explicit override. They are the same act with a flag, not a second
code path, so what the override ships is exactly what was refused.

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

Six checks, all at the start, all named - because a build that fails hours in has already
wasted the expensive part. They belong to the build rather than to a region because none of
them is a property any single region can hold.

**The source checks apply per resolved source across the whole region tree**, not once per
region. A subregion may legitimately name a different source than its parent - that is the
whole point of the field being on both - so a check that ran per region would happily pass a
region whose detail box is built from something the card cannot carry.

**The model must be on disk.** A card built from unsaved edits cannot be rebuilt from the
set that is supposed to define it, and the entire claim of a region set is that it *is* the
recipe. On a surface with somebody to ask, this is a question with an obvious answer and is
asked rather than refused; on the console it refuses and names the flag.

**Every region in one output folder should agree on `zauthor` and `zmin`.** This is
structural, not stylistic: the E-Series firmware holds those two on the chartset - it fuses
every `.RCT` on a card into one pyramid and indexes it as `zdir[z - zmin]` - so they are
properties of the *set*. Each file carries the set's values redundantly, which is exactly
what lets a card be defined by which files are present rather than by a manifest, and lets
the consumer check agreement instead of trusting a declaration.

The failure it prevents is the one the format cannot absorb. The reveal aperture is cut at
the coarsest `zauthor` on the card; if that level is finer than some file's `zmin`, that
file has no tiles at the outline level, contributes no outline, and its imagery sits on the
card fully built and permanently invisible.

**It warns, and does not refuse.** Trying a new `zauthor` on one region before converting a
whole chartset is a legitimate thing to want, and a hard refusal makes it impossible. So the
preflight says so prominently and the author decides - which is the position this
application already takes about imagery depth, for the same reason.

**And it asks the folder, not only the build.** "Every file on one card" is a statement about
a *folder*, and a folder can hold cards built at other times, from other sets, or from a
region since renamed. So the check reads the `zauthor` and `zmin` out of the `.rct` headers
already there - 24 bytes each - as well as from the regions about to be written. That is the
case a check across the build alone cannot see: building one region at a new `zauthor` into a
folder of older cards, where the regions being built agree perfectly because there is only
one of them.

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

**And the declaration is checked against the evidence.** A source may declare JPEG and serve
PNG, which the first check cannot catch. The cache already records the format *detected from
the bytes* when a tile was fetched, so the exporter compares that per tile for the price of a
string comparison. This is not the image inspection this application refuses: it reads a
fact the cache established, decodes nothing, and no image ever enters the process.

**A source that may not build at all.** `uses` is the author's statement of what a source is
for, and it was consulted where a source is *chosen* and never where one is *used*. A set
carried from another machine can therefore name a display-only basemap, which would fail at
the only moment it mattered.

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

## Progress, and where the build runs

The build runs on a **worker thread**, watched by a dialog on the main one, and the only
thing that crosses between them is a shared record. The worker writes the counters and reads
a cancel flag; the dialog reads the counters and writes the cancel flag. Nothing else, in
either direction - no wx call is ever made from the worker and no model call from the
dialog. It is the same rule that made an observer unnecessary elsewhere: a callback firing
on another thread must not touch a widget, so nothing calls back and the dialog asks.

**Two bars, because the wait has two shapes.** The outer is regions - a number the user chose
and can predict. The inner is tiles within one region, which is thousands and is where the
hour actually goes. One bar for the whole build would sit at twenty percent for a quarter of
an hour and tell nobody whether anything was still happening.

**A cancel sets a flag and waits.** The worker notices within one request, finishes the tile
in hand and unwinds; killing it outright would leave a half-written card and a cache
mid-write. Nothing is poisoned by stopping, because an error is never cached - so running it
again resumes.

**The result comes back as text.** A report is a nest of hashes that cannot cross a thread
boundary as a reference, and shipping a copy back would be a second representation free to
drift from the first. So the worker renders it with the same function the console prints,
and both surfaces read the one rendering. A build ends in one of three ways - built, refused,
cancelled - and the report says which before it says anything else, because the detail of a
refusal and the detail of a success look alike at a glance and only one of them means there
is a card.

## What a run will cost, before committing to it

The preflight has to answer "how many tiles, and how long" fast enough to simply appear. The
obvious implementation asks the cache about each tile the way a fetch would - up to three
`stat` calls each. The one that works reads each `(source, zoom)` cache **directory** once
and intersects in memory. Measured against the real five-region Panama set, 25,500 tiles
over a 36,000 file cache:

```
    probing each tile        2.213s cold    2.185s warm
    reading each directory   0.127s cold    0.126s warm
```

Seventeen times, and the naive version is no faster warm because it is syscall bound rather
than disk bound - it would not improve on a faster drive either. A single region indexes in
about 0.12s. **The cost scales with the cache, not with the region**: it is proportional to
how many files sit in the directories touched.

**Everything is grouped by source**, and that is structural rather than presentational. A set
may use several - a subregion may name its own - and each has its own cache directory, its
own declared rate and its own achieved speed. A blended number could not be computed
correctly, and would not say which source is the long pole even if it could.

**The size estimate samples rather than weighs.** Totalling the bytes in a source's cache
costs 36,000 more syscalls - measured at 3.5s, thirty times the analysis it was decorating.
Twenty tiles per zoom is ample for a figure quoted to one decimal place in megabytes, and
per *zoom* because an ocean tile at z10 and a detail tile at z18 differ by an order of
magnitude.

**Time is the honest problem.** A source that declares an interval needs no measurement - its
floor is arithmetic, exact whether or not this machine has ever spoken to it. A source that
declares none is round-trip time and nothing else, unknowable until observed. So the fill
records what each source actually managed, in milliseconds per tile that really went out,
smoothed across runs and kept per machine in `$temp_dir`. Until there is such a record,
**the preflight shows the count and offers no time at all**, because an estimate wrong by a
factor of three is worse than none: it gets planned around.

## Rate limiting the user can raise

A TSD states facts about somebody else's server, and sources are read-only in the
application. How fast you personally want to go tonight is a fact about you - you may have
all night, and prefer slow and sure to fast and likely to fail. So the build configuration
carries an advisory interval, and the effective floor is:

```
    max(the source's declared min_interval_ms, the user's advisory)
```

**`max()`, never a replacement.** That one operator is the whole of what keeps a
user-settable rate from becoming a way to violate a source's declared policy: an advisory can
only ever make you slower.

The table is **derived, not authored**. It holds one row per source the set actually uses -
a list the build already computes for its guards - and the user types only the number beside
each row. Change a region's source and a row appears at the default; there is nothing to keep
in sync, and no way to configure a source the set does not use. For a set built entirely
from one source, it is one row.

## Still to specify

- **The queue** - concurrency, interval limiting, retry policy, and the failure
  classification that distinguishes a rate limit from a missing tile from a dead source.
  The fill is serial: it honours the interval a source declares and ignores the concurrency
  it declares, which is most of an order of magnitude of wall clock on new ground. What
  makes this a design conversation rather than a change to a loop is that concurrency turns
  pacing into a scheduler, and telling a rate limit from a dead source stops being optional
  the moment several requests are in flight at once. **Backing off on failure belongs here
  too, and composes in one direction only**: it may move below the user's advisory baseline,
  never above it, or a fast advisory would let the system accelerate back into the wall it
  just hit.
- **Resume** - a run of thousands of tiles that is interrupted must continue rather than
  restart. The cache makes this nearly free; what is missing is the specification of what a
  run records about itself.
- **The exporter seam** - what an output format has to implement. The boundary is settled
  (the coverage enumerator plus the cache, with [mbtiles](mbtiles.md) and
  [RCT](rct.md) as peers over it); what an exporter has to provide is not. RCT is still the
  only exporter, so there is nothing yet for the seam to be abstract against.
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
