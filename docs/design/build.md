# chartMaker - Build

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Key Store](key_store.md)** --
**Build** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)** --
**[Cleanup](cleanup.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

A build turns a coverage model into files. This document is the act itself - what is asked
before it starts, what it refuses, the proxy and cache every tile passes through, and how
preview answers the same question the build will.

## Nothing starts without a preflight

A menu item that silently begins a multi-hour process is the wrong shape, and so is a
confirmation dialog at the *end* of one - by then nobody is sitting there to answer it. So
both Fetch and Build go through two dialogs, and **every question a user could be asked is
asked before the first request goes out.**

**One - what, and where.** A checkbox list of the set's regions, and for a build, the output
folder. It is the *build configuration*, and it persists: `region_sets/<set>/build.json`.

**Two - what it will cost.** Tiles to fetch, already cached, and recorded absences, grouped
by source; the estimated time; the size of the output; which files will be replaced; which
files are in that folder and are *not* part of this build; and whether the build would
disagree with itself. Then Build, Back, or Cancel.

**Half of that second dialog is about the OUTPUT FOLDER, not about building.** Replacement, foreign
files in the folder, and chartset agreement are all questions about one fused E-Series
pyramid; an output whose files are independent charts has no chartset to disagree with and
no headers to survey. So the analysis is told which format it is for and does not compute
them - and the preflight does not display a warning about nothing, which is how a real
warning gets trained out of being read. What is left is common to both: what will be
fetched, what it will cost, and where it is going.

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
beyond *which regions*. Two people with the same region set must be able to get
the same output.

## The output folder is a suggestion

`<RASTER_DIR>/<set>` is where a build goes unless told otherwise, and it can be told
otherwise. That is what makes a trial build possible - somewhere other than the folder you
copy onto a card - and it softens rebuilding, because the thing you are overwriting is a
choice rather than a fixed destination.

**The default is created as needed; a chosen one must already exist.** That asymmetry is the
application's standing rule - it creates only the folders it chose the location of - and it
is not pedantry: a nominated path that is not there is far more likely to be a typo, an
unmounted drive, or a configuration copied from another machine than an instruction to build
a tree somewhere unexpected, and building it would look like success while hiding the real
problem. The folder browser's own *Make New Folder* is what creates one, as a user action.

**That choice belongs to the `.rct` build, and only to it.** The remembered `out_dir` is where an
E-Series card gets assembled - the folder copied wholesale to CF - so an
[mbtiles](mbtiles.md) build landing a tree of region folders in the middle of it would make
that copy a decision instead of a copy. MBTiles therefore has one destination and nothing to
configure, which is why its half of the preflight asks *what* and not *where*.

## The build is one act in three phases

```
    VALIDATE   fast, before anything expensive       ->  may refuse
    FILL       ask for every tile in coverage        ->  builds the LEDGER
    ---------  the refusal point  --------------------
    EXPORT     per region, temp + rename             ->  short
```

**One act, several formats.** `build rct` and `build mbtiles` are the same act; what an
output format changes is four of the guards and the write call, and those are declared in
one table rather than branched on at each of the five sites. The reason is not tidiness: a
fifth difference added as a branch is a guard that silently stops running for the other
format, and a guard that does not run looks exactly like a guard that passed.

| | RCT | MBTiles |
|---|---|---|
| carries | JPEG | JPEG or PNG |
| converts | PNG, where a decoder is installed | nothing - one file, one declared format |
| files must agree on `zauthor`/`zmin` | yes - the E-Series fuses them into one pyramid | no - each file is an independent chart |
| name check | an 8.3 stem | any valid id |
| default folder | `RASTER_DIR/<set>` | `MBTILES_DIR/<set>` |

**The middle phase is format-blind, so a second output is nearly free.** The fill asks the
coverage enumerator for every tile and the cache is keyed by source, not by destination - so
a set already built to one format builds to the other without fetching anything at all.

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
alone refuses nothing, since it writes no output.

## Present, absent, and failed

The cache answers three ways, and the difference exists only for as long as the build holds
it:

| cache says             | means                                | in the file        | the build |
| ---------------------- | ------------------------------------ | ------------------ | --------- |
| bytes                  | the tile                             | written            | fine      |
| a recorded absence     | the source **asserted** it has none  | miss bit, overzoom | reports   |
| nothing at all         | the fetch never succeeded            | miss bit, overzoom | refuses   |

**In the file the last two are indistinguishable.** Both set the miss bit, both make the
plotter magnify an ancestor, both look soft rather than broken. One of them is the truth
about the ground and is correct to ship; the other is a hole that should not be there. The
file can never tell them apart - the build can, and only at the moment the tile passes
through it.

So an asserted absence is **information, not a warning**. It is the normal edge of a
source's coverage, retrying will never change it, and calling it a warning teaches the user
to ignore warnings.

**The exporter does not decide any of this.** It still copies cached bytes without
inspecting them and still fetches nothing; it only counts the two kinds of missing
separately. The refusal lives in the build, which holds the ledger, because the format
tolerates a hole *because it must* and that tolerance is not a quality standard.

## What a refusal costs

Nothing, and that is deliberate. A build that refuses has written no file at all - not a
partial one, not an earlier region's. Every `.rct` is written to a temporary name and
renamed only on success, so a cancel, a crash or a full disk cannot leave a file that looks
complete and is a fragment. A cancelled or refused build leaves the folder exactly as it
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

- **No key ever reaches the browser.** A source that needs one is fetched by the
  application, which holds the key. Nothing in the page, and nothing in the page's network
  log, contains a key. See [Key Store](key_store.md).
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

## The fetch engine

The one home rate limiting has. It sits **below the callers of the tile path, not above the
fill**: browsing, filling and sampling are three clients of one engine with different
priorities, rather than three pieces of code each being polite on their own account and none
of them knowing about the others.

The position is the whole design. Putting the engine at or above the fill would leave the map
proxy unpaced - panning is unbounded traffic aimed at somebody else's server - and would let
anything added later bypass the limiter by not going through the fill.

```
    proxy (interactive)   fill (bulk)   sampler (bulk)
              \               |              /
               +--------------+-------------+
                              |
                         THE ENGINE
             queue, two priorities, per-source gate,
             concurrency, classification, backoff
                              |
                      the tile path (cache first)
```

**Composition, one operator per axis:**

```
    interval    = max( the source's min_interval_ms, the installation floor,
                       the set's advisory, any live backoff )
    concurrency = min( the source's max_concurrency, the pool size,
                       ceil(round-trip / interval) )
```

Slowest wins, fewest wins. Every knob at every tier can only make the client **gentler**, and
no combination of settings anywhere goes faster than the TSD declared. Backoff is in the same
`max()` for exactly that reason: it is one more voice that can only slow things down, and a
fifth contributor later costs nothing.

**Concurrency is latency cover, and that bounds it.** At interval `I` and round trip `R`,
serial gets one tile per `max(I,R)`, so the useful worker count is `ceil(R/I)` and beyond that
they idle. The engine computes that from the **measured** round trip in the observation record
rather than believing `max_concurrency`. The gate is **per source** - one shared
next-allowed-time - not per worker, which is the only arrangement that yields one request per
interval however many workers are pushing.

**The pool is the global ceiling and lives for the program's lifetime.** Perl's threads clone
the interpreter at spawn: measured, a thread costs 5 ms against a small interpreter and 44 ms
once about 20 MB is loaded. So it is spawned at startup before the frame exists, a source's
declared concurrency is a permit count within it rather than a way to enlarge it, and changing
the pool size requires a restart.

**Interactive queues ahead of bulk; it does not preempt.** A tile the map is waiting for goes
to the head of the queue rather than behind a fill's backlog. The wait is therefore bounded by
the shortest request already in flight rather than by the backlog, which is the property that
matters and is far cheaper to provide.

**Failure has five classes because each one has exactly one consequence:**

| class | example | consequence |
| --- | --- | --- |
| `rate_limited` | 429, or 503 with `Retry-After` | back off this source; obey `Retry-After` |
| `auth` | 401, 403 | stop; retrying cannot supply a key |
| `unresolved` | none - no request was made | stop; a {key_name} has no value, and this is NEVER cached |
| `transport` | timeout, refused, TLS failure | retry a few times |
| `server` | 5xx without `Retry-After` | retry a few times |
| `garbage` | 200 that is not an image | do not retry; it will not become one |

A 503 carrying `Retry-After` is rate limiting wearing a different number: a service under load
and a service telling you to slow down are indistinguishable from the client, and the header is
the tell.

**Backoff applies to the source, not to the tile.** A 429 slows everything aimed at that
source; it does not mean retry this coordinate sooner. It doubles on repetition, decays by
halving on success rather than clearing outright - clearing sends the next burst straight back
into the limit - and never makes the client faster than the settings already allow.

**What a response MEANS is decided where the request lands, not by whoever asked.** The
sentinel check that turns a "200 that means 404" into an absence, and the cache write, both
happen at the engine's own fetch, so every route to the network gets them: the map proxy, a
fill, a build's fill phase, a probe. Anything hanging off "the only route to the network" has
to live there rather than in one of its callers, which is the same argument that put the
observation record there.

**The engine governs when a request goes out, never when a result is stored.** Tiles still
commit one at a time, on arrival, in every mode. Resume being nearly free and the coverage
picture accumulating from ordinary use both depend on that, and neither is the engine's to
spend.

**It is optional, and the application works without it.** With no pool started, a fetch happens
on the calling thread through the same gate. That is not a safety fallback: the console fills a
cache with no frame anywhere and every headless test runs this way, so a path that only worked
with a pool running would be a path that could not be tested.

## The cache

The layout, its keying by source, and why the source dimension is not optional are
specified in [Deployment](../deployment.md#the-tile-cache-is-not-temporary).

Two rules belong here rather than there:

**Misses are cached too.** A tile that a source does not have is recorded as absent. This
is what accumulates a real coverage picture for a remote source over time at no cost, and
it stops every rebuild from re-requesting tiles already known to be missing. It is also
why coverage never has to be declared in a source.

**Absence is not always an error code.** Some services answer a request for a tile they do
not have with a uniform blank image and HTTP 200. Hashing tiles catches that case, which
matters because the alternative is a chartset full of grey squares that the application
believed were imagery.

Nothing here ever removes anything. What a build leaves behind, and what browsing to find a
region leaves beside it, is dealt with by [Cleanup](cleanup.md) and only when asked.

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

The exporter fetches nothing. An uncached tile is simply absent from the file: the miss bit
is set and the plotter overzooms from a present ancestor, which is exactly the behaviour the
format is designed around. That is right for the exporter and wrong as a way to acquire
imagery, because the failure it produces is invisible. Reshaping an existing area rebuilds
happily from what browsing already cached; **new ground at depth has never been fetched**, so
the output comes back with holes that the plotter papers over. It looks soft rather than
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
producing thousands of identical failures, so a run gives up when **the last twenty requests
that actually went out all failed**. Stopping poisons nothing - running it again after fixing
the source resumes.

That predicate replaced a count of consecutive failures, which could not survive requests
being in flight at once. "Consecutive" is not a property results have when four of them are
outstanding and they finish in whatever order the network returns them; and counting across
classes meant a flaky server that failed one request in three aborted a run identically to a
dead host. Cache hits do not enter the window, or a resumed run over cached ground would fill
it with successes that never touched the network.

**Each node is filled from the source it will be built from**, with `inherited` already
followed: a subregion that names its own source has its tiles fetched from that source, not
from its parent's and not from whatever the map happens to be displaying. Filling from the
displayed source would fill entries the build will never read, which is the same invisible
hole by a different route.

**The fill is a client of the fetch engine, not a fetcher.** It keeps several requests
outstanding and lets the engine decide when each one leaves; it does no pacing of its own and
sleeps nowhere. A cache hit still short-circuits everything and never reaches the engine, so a
resumed run over cached ground goes at local disk speed.

## The probe

**A probe is about a SOURCE.** It asks whether a service is any good here and how deep it
holds up, so that choosing among a folder of candidate `.tsd` files stops being guesswork.

A region contributes its polygons and **nothing else** - not `zmin`, not `zmax`, not
`zauthor`, and above all not the source it is assigned. The zoom range is asked for, not
derived. Any installed source may be probed, including a display-only one.

**It is started by right-clicking the node to probe** - in the tree, or on the map - and never
from a menu that would have to ask for an area it was not told. The gesture says where; the
dialog then asks the two things it did not, which are the source and the range. Nothing picks a
source on the user's behalf: the source is the subject, and choosing it silently would answer
the only question being asked.

**The dialog opens on the node's own band**, and that is a default rather than a derivation. A
region gives its `zmin`..`zmax`; a subregion gives the band it adds above its parent, starting
at that parent's `zmax + 1` - which is the region model's own definition and the reason a
subregion carries only a `zmax`. Those are exactly the levels a source is about to be asked to
satisfy, so it is a better opening guess than a preference somebody set once and now has to
change per node. **Nothing clamps to it.** What is sampled is whatever the spinners say, and
they reach z0-24 whatever the region or the file declares.

**The source and the range are remembered for the session** - in the application and in the
browser, separately, neither being the other's state to change. Comparing several services over
one area means opening this repeatedly, and re-picking from the top of the list every time is
the friction that stops somebody running the third and fourth probe. Not written to disk: it is
about what is being done now, not about what was meant last month.

**Why it cannot be about a region.** Once a region names its source and its levels, the build
already answers coverage exactly within those constraints; sampling it would re-derive
something already known precisely. The expensive question is the other one: with
twenty-five candidate services, which are worth specifying at all? That question has no
region in it, and the geometry is only where you stand to look.

### Three questions, in falling order of certainty

| question | how | cost |
| --- | --- | --- |
| does it **answer** here | a refusal | free, and exact |
| does it **admit** it has nothing | a declared no-data body | free, and exact |
| is what it returns **imagery** | a flat fill is neither | one decode |
| does **depth** buy anything | against the sample's own parent | a second fetch and two decodes |

**A refusal and a sentinel are not the same finding.** A 404 is a service saying "I have
nothing here". A 200 carrying a known no-data image is a service *declining to say so* - you
only know because somebody fingerprinted it, and until they did, every one of those counted as
imagery. The second is a worse property of a service and it is exactly what a candidate
evaluation should surface, so the two are reported separately rather than folded into one
`absent`.

**The first is often the whole answer.** A source that refuses tiles it does not have
declares its own ceiling by refusing: three quarters of a level coming back absent is not a
subtle statistic. A source that never refuses anything at any depth declares nothing, and for
that class the depth test is the only instrument there is. Both regimes are real, and the
report says which one it is looking at rather than leaving it to be inferred from a column of
zeroes.

**Caching a blown-up tile is worse than not having it.** A z18 magnified from z15 costs
sixty-four times the storage and sixty-four times the fetches of its ancestor, and the plotter
would have overzoomed a pixel-identical result from that ancestor for nothing - which is what
the RCT format is built to do. So the depth answer is not curiosity about a service's honesty.
It is the level past which you are paying for tiles the device fakes for free.

### Stratified, on the canonical grid

For each level the sampler takes the **coarsest set of cells that holds enough of them**,
quantised against the polygons at each step, and draws one descendant inside each. Pure random
draws clump, which is tolerable for a ratio and useless for a map.

**Quantised at each level, never descended arithmetically.** The children of a covering tile
include every child that lies inside the tile and outside the area, so descending from a coarse
level over a small one produces a set that is mostly nowhere near it. Quantising directly costs
the area's bounding box in tiles *at that level*, and the search stops the moment there are
enough cells - so the most expensive call is bounded by the sample count rather than by the
depth being probed, and a z19 sample never enumerates z19.

It also self-balances. A large area has enough cells while they are still coarse, and a coarse
cell of a large area is mostly interior; a small area keeps going until its cells are small
relative to it. Either way a descendant drawn inside a cell is usually on the ground, and it is
checked against the same geometry the build walks rather than a cheaper test.

**`min(num_samples[z], level size)`.** A level holding fewer tiles than the sample count is
enumerated exhaustively, and its row says `all` rather than `sampled`. Nothing is extrapolated:
a row reports what came back.

**Choose the points, then resolve them.** Selection never consults the cache. Resolution is
cache first like every other request, so earlier runs make a run cheaper without making it
biased - which is the whole reason they are separate steps.

**A network failure is not an outcome** and never enters the ratio. A timeout says nothing
about whether a tile exists, so counting it as an absence would report a bad connection as
missing imagery. Failures are counted and named separately.

### The sample arrives with its parent

Answering "does depth buy anything" means comparing a tile against the level above it, and a
sample drawn independently at each level has neither its children nor reliably its parents. So
each sample's parent is **fetched alongside it**. That costs about twice the requests and keeps
every level's draws statistically independent, which sampling a chain from the deepest level
would not.

**The control is a tile, not a number.** Comparing a tile's detail against an absolute number
cannot work: uniform ground and invented pixels are both smooth, and no threshold separates
them - which is exactly why a compression-ratio test was tried and abandoned. Comparing it
against its parent magnified does not work either, because a service magnifies and then
re-encodes, and the encoder puts ringing back as high-frequency content a parent magnified in
memory has none of.

So the false answer is **manufactured, per sample, and divided out**. The parent's own quadrant
is magnified and encoded to the length in bytes the child actually arrived in - which is the
tile the service would have sent had it held nothing at this level. Same ground, same parent,
same encoder, same compression. The question stops being "how much detail is this" and becomes
"how much more than that", and everything that defeated the earlier measures is present on both
sides of the division.

**What is reported is a number per level, not a verdict per tile**: the median of that ratio.
1.0 means the level is indistinguishable from the one above blown up, and real imagery runs
about 1.5 to 5. **Read where it falls, not what it is** - the fall is where depth stops being
worth fetching, and it is legible even when no single tile crosses any threshold.

That deliberately does not distinguish "the service invented these pixels" from "the ground has
no detail at this scale". For deciding what to build those are the same answer, and the second
is not knowable anyway. It also **cannot see through sharpening**: a service that magnifies and
then sharpens has invented fine detail, and invented fine detail is fine detail. It catches the
naive magnification, which is the case that costs sixty-four times the storage for nothing, and
it guides a person choosing a `zmax` rather than deciding for them.

**It is measured, and it has a fixed point.** A known magnification fed in as the child reads
1.00 - which is the test the previous measure would have failed, and the reason it is worth
printing where that one was not.

**And it has been checked against a human eye exactly once.** Over one property, a service's
column fell 3.19, 2.36, 1.51 across three levels and the real imagery genuinely stops where the
fall is. That is one confirmed case on one service in one place, which is enough to print a
column and nowhere near enough to draw a conclusion from. The report says so in those words, and
**there is no per-tile verdict anywhere** - a threshold on this fired on open water at a coarse
level, where a blow-up costs a handful of tiles and nobody would choose differently, and stayed
silent at the depth where the enlargement is visible without any instrument at all.

For a service that refuses what it does not have - which is most of a shipped catalog - none of
this is needed and the free columns are the whole answer.

Everything else here stands on its own: **absent against found needs no pixels at all**, and
for a service that refuses what it does not have that is the entire answer.

### It needs a decoder, and works without one

Pixels are reached through one narrow seam that decodes a tile and encodes one - the same seam
the exporter uses to turn a png source into a jpeg for an `.rct`. Neither consumer resamples
output, reprojects or composites.

**With no decoder installed the probe still runs**, reports samples, found and absent, and
leaves the depth columns blank rather than zero. Blank reads as *not measured*; a zero would
read as *none of these were blow-ups*, which is a claim. The same rule covers ground with no
variation to divide by: no number, rather than an accusation. For a source that refuses what it
does not have, the free columns are the whole answer regardless.

**Measuring depth is asked for and can be declined**, and what it costs is a second fetch per
sample plus about a tenth of a second of processing. That is a price, not a doubt, and it is
stated where it is chosen.

### What is remembered, and what is not

**Nothing placed survives the probe.** Coverage findings live for as long as probe mode does
and then they are gone. There is no result file and no spatial index: a placed finding has no
home in the observation record by that record's own rule, and re-running is cheap because the
tiles a run fetched are in the cache.

**Two placeless facts do persist**, both about the server rather than about a place:

- **rate statistics**, as every other act already contributes.
- **candidate fingerprints.** A body that comes back byte-identical at several different
  coordinates is offered as a possible "no tile" marker. **The probe does not find these** -
  they are learned in [the fetch path](tsd_editor.md#every-fetch-teaches), where every tile
  passes, so a sample contributes to the same record a build and a verify do rather than
  being one of several detectors free to disagree. What is recorded is a coordinate rather
  than a copy of the image, because the tile is already in the cache. **Never acted on** - a
  source that legitimately serves identical tiles, open ocean or a uniform icecap, would have
  real imagery declared missing and nothing downstream could tell. A person looks at the tile
  and promotes it into the `.tsd`.

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
plotter answers a request for a tile the file does not hold by magnifying the deepest
ancestor it has, and preview reproduced that at first. It made the built edge unreadable:
real imagery and magnified imagery look alike, so the chartset appeared to extend a long way
past where it actually stopped - a halo of progressively coarser imagery, one tile wider at
each level, which is genuinely what a plotter shows and is useless for deciding anything.

What an author needs is the opposite. **Zooming in until the imagery stops is the answer to
"how deep did I build here"**, read directly off the map, and it only works if the imagery
actually stops.

**And it is client independent, which is the stronger reason.** A fallback render is a model
of one consumer's behaviour: the E-Series magnifies the deepest tile it holds, OpenCPN allows
essentially unlimited overzoom from the deepest level in the file, and neither is a fact
about the chartset. What the file *contains* is the same answer whoever reads it - so this
mode stays true as consumers are added, and needs no evidence about any of them to be
trusted. A simulation would need to be validated against every client it claimed to
simulate, and would be quietly wrong the moment one changed.

**Depth is spatial, not a number.** A detail area is carried several levels deeper than the
ground around it, so at one zoom the same screen shows imagery inside the detail area and
bare context outside it. That difference IS the information.

**The tile footprint comes with it.** Filled tiles alone do not say where a tile ends, and
the edge of the built area is what preview is for - so preview turns the footprint on and
pins it to the map's zoom, and the two answer the same question at the same level: the
outlines say which tiles get built, the fill says what is in them.

**A tile the source does not have is drawn as a hole**: a muted orange rectangle with a pale
outline. Orange because it has to be findable at a glance against dark water; muted because a
region that has never been fetched is a screen full of them and a bright colour would be
unreadable; outlined because fill alone disappears into brown coastline at low zoom. It is
deliberately the most conspicuous thing preview can show, since a hole in a file is invisible
on the plotter - it overzooms an ancestor and simply looks soft.

The context layer is **visually marked** - dimmed or desaturated, with the coverage
boundary drawn over it. A user who sees imagery and assumes it is in their chartset is
preview failing at its only job, and "colour means it gets built" is a rule learned
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
region whose detail box is built from something the output cannot carry.

**The model must be on disk.** A file built from unsaved edits cannot be rebuilt from the
set that is supposed to define it, and the entire claim of a region set is that it *is* the
recipe. On a surface with somebody to ask, this is a question with an obvious answer and is
asked rather than refused; on the console it refuses and names the flag.

**Every region in one output folder should agree on `zauthor` and `zmin`.** This is
structural, not stylistic: the E-Series firmware holds those two on the chartset - it fuses
every `.RCT` on a card into one pyramid and indexes it as `zdir[z - zmin]` - so they are
properties of the *set*. Each file carries the set's values redundantly, which is exactly
what lets a chartset be defined by which files are present rather than by a manifest, and lets
the consumer check agreement instead of trusting a declaration.

The failure it prevents is the one the format cannot absorb. The reveal aperture is cut at
the coarsest `zauthor` present; if that level is finer than some file's `zmin`, that
file has no tiles at the outline level, contributes no outline, and its imagery sits on the
file fully built and permanently invisible.

**It warns, and does not refuse.** Trying a new `zauthor` on one region before converting a
whole chartset is a legitimate thing to want, and a hard refusal makes it impossible. So the
preflight says so prominently and the author decides - which is the position this
application already takes about imagery depth, for the same reason.

**And it asks the folder, not only the build.** "Every `.rct` that will be read together" is a statement about
a *folder*, and a folder can hold files built at other times, from other sets, or from a
region since renamed. So the check reads the `zauthor` and `zmin` out of the `.rct` headers
already there - 24 bytes each - as well as from the regions about to be written. That is the
case a check across the build alone cannot see: building one region at a new `zauthor` into a
folder of older files, where the regions being built agree perfectly because there is only
one of them.

`zmax` is genuinely per-region and must not be forced to match.

**The exported file name must be a genuine 8.3 short name.** Asserted at export, for
reasons that are only visible from this side of the boundary - see
[RCT](rct.md#two-constraints-only-chartmaker-can-see).

**The tiles must be in a format the exporter can carry, or one it can convert.** RCT holds
JPEG and re-encodes a PNG on the way in; MBTiles holds both and converts nothing, because
one file names one format in its own metadata. A source may legitimately declare `png` and
nothing stops such a source declaring `build` in its `uses`, so the combination is reachable
without anybody doing anything wrong.

What a PNG source must never produce is a structurally valid file full of bytes the plotter
cannot decode: built, reported as successful, and blank on the water. That is the worst
failure this application can produce, because every signal says it worked.

**The declaration is a hint, and this guard is the only place it is asked to predict
anything.** `tile_format` states what a `.tsd` *expects*; the truth arrives per tile from the
magic bytes. So a refusal here can only ever be an early warning, and it is worth having
precisely because the alternative is failing at tile four thousand of a run that has already
spent an hour. It refuses only what no outcome can rescue: a source that declares a format
this machine has no decoder to convert. A PNG source on a machine that *can* convert is not
refused, and never should have been.

**The evidence is checked where the bytes are.** The cache records the format detected from
the bytes when a tile was fetched, so the exporter reads that per tile - which makes a source
that declares JPEG and serves PNG the same case as one that honestly declares PNG, and
settles both by one string comparison. A tile the output cannot carry is converted there, and
refused there if it will not decode.

This is where an image enters the process, and it is worth being exact about what enters:
one tile, decoded and written straight back out. Nothing is resampled, reprojected or
composited, and the cached bytes are not touched. See
[RCT](rct.md#jpeg-only-and-png-converted-into-it).

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
in hand and unwinds; killing it outright would leave a half-written file and a cache
mid-write. Nothing is poisoned by stopping, because an error is never cached - so running it
again resumes.

**The result comes back as text.** A report is a nest of hashes that cannot cross a thread
boundary as a reference, and shipping a copy back would be a second representation free to
drift from the first. So the worker renders it with the same function the console prints,
and both surfaces read the one rendering. A build ends in one of three ways - built, refused,
cancelled - and the report says which before it says anything else, because the detail of a
refusal and the detail of a success look alike at a glance and only one of them means there
something was written.

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
carries an advisory interval, and it composes into the engine's `max()` above alongside two
installation-wide preferences:

| knob | tier | note |
| --- | --- | --- |
| requests at once | installation | the pool size; **requires a restart** |
| slowest interval | installation | a floor under every source |
| advisory interval | per set | in the build configuration, per source the set uses |
| `num_samples[z]` | installation | how many tiles the sampler draws per level; a table, not a scalar |
| finish-by budget | per set | a **computed** advisory interval, never a stop condition |

**`max()`, never a replacement.** That one operator is the whole of what keeps a
user-settable rate from becoming a way to violate a source's declared policy: every one of
these can only ever make you slower. The pool size is the mirror image - a `min()`, so it can
only ever make you narrower - and a client-wide cap is the only limiter measured in the right
unit anyway, because a ban is per client rather than per source and several services share
infrastructure.

**Rate knobs compose one way and the sample count does not.** Interval and concurrency may only
make the client gentler, which is what `max()` and `min()` enforce. Raising `num_samples[z]`
sends more requests but not faster ones, because the sampler goes through the engine and the
engine still paces it, so the two are independent and neither operator has to reach the sample
count.

**"Finish by 6am" is an interval, not a deadline.** It is computed from remaining tiles over
remaining time and enters the same `max()` as everything else, so it can only ever make a run
slower than declared. Expressed that way it cannot become a way to go faster, and it is the
honest version of what an overnight run means: a run that has not finished by six is a run
with fewer samples, not a run that sped up to make the time.

The installation knobs are preferences because a user's connection, conscience and patience
genuinely differ. That is the test: the observation record's flush interval is a constant
rather than a preference precisely because no user has a basis on which to choose it and no
outcome differs if they choose badly.

The table is **derived, not authored**. It holds one row per source the set actually uses -
a list the build already computes for its guards - and the user types only the number beside
each row. Change a region's source and a row appears at the default; there is nothing to keep
in sync, and no way to configure a source the set does not use. For a set built entirely
from one source, it is one row.

---

**Next:** [MBTiles](mbtiles.md)
