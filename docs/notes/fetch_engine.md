# chartMaker - the sampler and coverage mode

Working design for two things that have not been built. It is not a specification and is not
linked from any official document.

**A-D of this file have landed and their content has moved into the official docs.** The
engine, its composition rules, its failure classes and its backoff are in
`build.md#the-fetch-engine`; the observation record is in `deployment.md#the-observation-record`;
the metadata probe and the `maxScale` rule are in `tsd.md#asking-the-service-what-it-is`; and
`absent_headers` and `registration` were already specified in `tsd.md`.

**What remains here is E and F, which depend on the engine and not on each other.** When they
become a design they belong in `build.md` and `editing_map.md`, and this file should be deleted
rather than left to disagree with them.

## What exists to build on

- `getTile` is the engine's front door. Browsing, filling and probing are clients of one paced
  queue; interactive requests go to the head of it.
- `engineSubmit` / `engineCollect` keep several requests outstanding without the caller pacing
  anything, and work whether or not a worker pool is running.
- The observation record holds what has been learned about each server, bounded, one file per
  source.
- `probeTilemap` answers the presence of a whole block for the ArcGIS family in one request,
  which is the cheapest coverage answer available and should be preferred wherever it is offered.

## The sampler

**Metadata cannot answer "is there imagery here."** Sparse coverage means an honest
ceiling of z12 does not imply a tile at every z12 square. Neither can the cache: it
records what the user happened to look at, at the zoom they happened to look at it, so it
is a log of their own browsing rather than a survey.

Given a region or region set and a `zmin`..`zmax` range, sample tile availability at each
level.

- **Stratified, not uniform random.** Pure random draws clump, leaving areas untouched by
  chance, which is tolerable for a ratio and useless for a map. For level `z`, pick the
  ancestor level at which the region holds about N tiles and draw one `z` descendant
  inside each. The strata are ancestor tiles on the canonical grid, so there is no new
  geometry and the sample cannot disagree with the build about what is in the region.
- **Draw from `dm_coverage`'s enumerator**, so subregion shapes, the band rule and
  inherited sources come along for free.
- **Per node, not per region.** A subregion carries its own `zmax` and may name its own
  source. This is also the gap in the current build report, where a subregion's tiles are
  folded into its parent's counts, so a detail box that came back empty is
  indistinguishable from absences scattered along a coastline.
- **`min(num_samples[z], level size)`**, so a level smaller than its sample count is
  enumerated exhaustively and reports a count rather than an estimate.
- **Three outcomes: real, magnified, absent.** Network failures are not a third outcome;
  they must not enter the ratio.
- **Magnification, cheaply.** A magnified JPEG is smooth and compresses to a fraction of a
  real one, so byte length separates most cases with no decode. The upsample residual, an
  existing todo item, only has to run on the ambiguous middle.
- **Choose the points first, then resolve them.** Never sample from what the cache
  contains, which would survey the user's browsing history rather than the source. Random
  selection first, cache-first resolution second; hits then make a run cheaper without
  making it biased.
- **No early stopping.** A five percent hit rate at z19 is not "z19 is dead", it is five
  places a detail box could go, and that spatial answer is the product. The ratio is a
  summary of the map, not the other way round.
- A re-run draws fresh points, is mostly cheap because prior runs left their tiles behind,
  and two runs agreeing is the confidence signal.

**What it is for** is siting subregions. "Where can I reasonably reach z18 in here" is a
question the region editor exists to answer and currently cannot, and it cannot be
answered by looking, because that means panning across a whole region at a zoom nowhere
near the one on screen.

## A point is the degenerate case, and it answers the candidates question

**The mechanism needs no special case.** At a single point each level holds exactly one
tile, so `min(num_samples[z], level size)` collapses to 1, the strata collapse to one
cell, and the result is exhaustive by construction: a count rather than an estimate. The
point case falls out of the region case rather than sitting beside it.

**What differs is the source axis.** At region scope each node names one source and the
walk follows it. At point scope the survey runs **across every installed TSD at once**,
which is what turns it from a depth question into the candidates question: one column of
tiles per source, `zmin` to `zmax`, side by side.

That makes the evaluator already specified in `tsd.md` - "show me every source here" - a
preset of this rather than a separate feature. It is point scope with the zoom range
pinned to each source's declared ceiling. Widening the range to a span is what turns the
same act into the depth probe.

**A point column carries its own ancestor chain, which nothing else does.** Having
fetched z10 through z22 at the same coordinate, every tile's parent is in hand, so the
upsample residual is a direct comparison rather than an extra fetch. Scattered stratified
samples over a region do not have their parents. So the point column is the rigorous place
to measure magnification, and it answers two questions at once: how deep the imagery
really goes **here**, which is placed, and whether the source upsamples past its real
detail at all, which is placeless and belongs in the observation record.

**Presentation differs even though the engine does not.** Region scope produces marks on
the map. Point scope produces a grid of actual tile images, source down one axis and zoom
across the other, judged by eye, because "is this imagery useful here" is a visual
question no metadata answers.

**Cost is trivial for installed sources and is the one thing that could blow up for a
catalog.** Thirteen levels against a handful of TSDs is nothing. Thirteen levels against
hundreds of catalog entries is thousands of requests, so the catalog variant needs the
candidate list pruned first. **That is the legitimate role for the coverage geometry a
catalog carries and a TSD refuses to**: a prefilter that decides who is worth asking,
never an answer about whether a tile exists.

## Coverage mode in the map

A third mode beside source view and preview. **It is a mode that holds accumulated
results, not a single run that finishes.** A run happens inside it, the results stay on
screen, the user can add to them, and the mode ends only when it is cancelled or when a
different region or region set probe is selected. That is a longer life than a build, and
it is the point: the display is what a `zmax` decision gets made against.

**Triggered by the app and completed by the app.** The map picks no sample points, fetches
nothing directly and counts nothing; it renders what the app hands it. If the browser
decided any of this the marks would illustrate the analysis rather than be it, which is
the same reason preview does not decide coverage for itself.

**Three surfaces, one result set, each doing what it is good at.**

- **The dots, on the map.** Where. Inherently spatial and belongs nowhere else. All of
  them persist, across point probes and across levels.
- **A small overlay, in a corner of the map.** Deliberately not the whole table: it shows
  **the last probed region or region set, and the last probed point if there is one**.
  Two entries, so it stays readable at any window size and never competes with the map for
  space.
- **A wx window for the full table.** All nodes by all levels is thirty rows for a modest
  region set, which a map corner cannot hold and a grid handles easily. Modeless, so it
  can be dragged clear of the mainframe onto a second monitor, and refreshed `onIdle`,
  which is the same poll-rather-than-callback discipline the progress dialog already uses.

The table is the report being built in front of you rather than a second artefact: the
same `(node, level) -> samples, real, magnified, absent` rows the final text renders.

**Results publish per node and per zoom level.** Per tile is too chatty for a poll and per
run is too slow to watch, and the pair is already the unit the report rows use, so
finishing z16 for one node publishes thirty marks and one table row together.

**A point probe amends the set rather than replacing it**, and rides the queue's
interactive priority to the head so the user gets an answer now rather than after two
hundred samples. It is the two-class queue earning its keep for exactly the reason it
exists. Its dots join the others on the map and its rows join the wx table as their own
section, since a sample of a region and a fact about a spot are different claims and
clearing one should not clear the other. In the corner overlay it simply replaces whatever
point was there before, because that overlay reports the latest of each kind rather than a
history.

**The result set crosses threads as flat strings, not as a structure.** `build.md` already
settled this for the build report: a nest of hashes cannot cross a thread boundary as a
reference, and shipping a copy back would be a second representation free to drift from
the first. The same applies here and the existing shared-progress pattern in `cm_utils`
shows the shape. Two shared arrays do it - one of rendered table lines for the wx window,
one of marks in a compact `z/x/y/outcome` encoding for the browser to parse into dots -
and neither needs nested shared memory, which is the awkward part of Perl ithreads.

- The map **polls**, exactly as the progress dialog polls. No callback into the browser.
- Marks are drawn at the sampled tile's **true footprint**, so they are self-scaling: one
  pixel at the deepest level, four at the next, sixteen above. Size gives the level with
  no legend.
- At one pixel a shape says nothing, so **colour carries the outcome**.
- **All levels at once.** A tile at `z+1` is a quadrant of its parent, so centres never
  coincide and no two levels can occlude each other.
- **Marks outlive the run.** Completion is when they become useful, since the point is to
  look and then set a `zmax`.
- A cancel leaves a smaller sample, not a broken one, and the report says so.

## Preferences

The rate knobs exist and are specified in `build.md`. Two remain unbuilt:

| knob | tier | note |
| --- | --- | --- |
| finish-by budget | per set | a **computed** advisory, not a stop condition |
| `num_samples[z]` | installation | per zoom level, a table not a scalar |

**Rate knobs compose one way; the sample count does not.** Interval and concurrency may
only make the client gentler. Raising the sample count sends more requests but not faster,
because the sampler goes through the engine and the engine still paces it, so the two are
independent and `max()`/`min()` need not reach it.

"Finish by 6am" is best expressed as an advisory interval computed from remaining tiles
over remaining time, clamped by the same `max()`. It cannot become a way to go faster than
declared, and it is the honest version of what an overnight run means.

## Settled

- **The sampler gets its own report renderer, not the build's.** The build report is
  shaped around what was written - blocks, megabytes, paths - and the sampler writes
  nothing; its columns are samples, real, magnified, absent, and estimate-or-count. The
  disjoint columns would become a pile of conditionals, which is the same argument
  `build.md` already makes about branching the format differences. What is reused is the
  discipline: the worker renders text with the function the console prints, both surfaces
  read the one rendering, and the outcome is named before any detail.

## Not yet decided

- Whether the run record that survives a run is only the failed-tile list, which is what
  makes "retry the last run's failures" possible, or something larger. Resume itself
  should stay unspecified, since cache-first is already the checkpoint and that property
  is worth not spending.
- Whether `registration` is surfaced only in the source list, which is what it does now, or
  also warned about at the moment a region names such a source.
