# chartMaker - Build

**[Design](readme.md)** --
**[Regions](regions.md)** --
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

## Editor and preview are one component in two modes

The same map, the same proxy, the same tile layer. Preview adds a clip and a cap:

**Source view** shows the build source everywhere, unclipped. This is the mode for deciding
where a region should extend to, because it shows what is out there beyond the boundary.

**Preview** shows what the chartset will actually contain:

```
    in coverage at this zoom  ->  the build source's tile
    beyond the region's depth ->  the coarser tile upscaled, as the plotter does
    outside coverage entirely ->  the context layer, visibly dimmed
```

The middle line is the one that is otherwise expensive to answer: it simulates the
plotter's fallback behaviour at a zoom the card does not carry, without a card, a boat, or
a trip to the water.

The context layer is **visually marked** - dimmed or desaturated, with the coverage
boundary drawn over it. A user who sees imagery and assumes it is in their chartset is
preview failing at its only job, and "colour means it is in the card" is a rule learned
once and never misread.

Preview generates viewport-shaped traffic exactly as browsing does. It never walks the
coverage; it fetches what is on the screen at the zoom being viewed.

## Still to specify

- **How preview renders an absent tile.** A tile the source does not have has to be
  conspicuous, and conspicuous against dark water specifically - a subtle marker over
  near-black sea is no marker at all. Not yet designed; the requirement is that a hole in
  the imagery reads as a hole at a glance.
- **The queue** - concurrency, interval limiting, retry policy, and the failure
  classification that distinguishes a rate limit from a missing tile from a dead source.
- **Resume** - a run of thousands of tiles that is interrupted must continue rather than
  restart. The cache makes this nearly free; what is missing is the specification of what a
  run records about itself.
- **Targets** - the named combination of a set, a source, depth caps, an exporter and a
  destination, which is what makes an output reproducible instead of a remembered set of
  flags. See [Regions](regions.md#depth-is-requested-here-and-capped-elsewhere).
- **The exporter seam** - what an output format has to implement, and where mbtiles stops
  being a file and starts being an interface.
- **Progress reporting** - the build is long-running and reports into the application
  without blocking it.

---

**Next:** [MBTiles](mbtiles.md)
