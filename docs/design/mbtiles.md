# chartMaker - MBTiles

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**MBTiles** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

*This document is not yet written.*

**`.mbtiles` is an output, not a hub.** It is one of the formats chartMaker writes: read
directly by OpenCPN, well specified, with a large ecosystem behind it. It is not an
intermediate that other exporters read.

**Exporters are peers over one boundary.** That boundary is the region's own coverage
enumerator and the tile cache - not a file:

```
    region + coverage enumerator + cache  --->  mbtiles
                                          --->  RCT
```

An earlier version of this design made mbtiles the hub, with every other output a converter
reading from one. The tell that it was wrong is what it would have cost: an RCT needs the
region's authored level and the polygon expressed at that level, and neither is a fact about
a container of tiles. Recovering them downstream would have meant writing chartMaker-specific
fields into a standard format's metadata table so a converter could read back what the
upstream step already had in its hand. Going to the cache directly means the presence
information an [RCT](rct.md) carries *is* the coverage set, by construction, rather than
inferred from what a container happened to contain.

Two consequences worth stating because they are easy to miss:

- **Building a card does not require building an mbtiles first.** The two are independent
  outputs of the same model.
- **Each exporter owns its own encoding question.** A source that returns PNG is the RCT
  exporter's problem to transcode, because RCT is JPEG-only; mbtiles has no such constraint
  and stores what the source sent.

Intended scope:

- **What chartMaker writes** - the `tiles` and `metadata` tables as this application uses
  them, and the row-order convention, since MBTiles counts tile rows from the south while
  the sources chartMaker reads from count from the north.
- **The metadata that carries provenance** - attribution, source id, license and
  `redistributable`, propagated from the [TSD](tsd.md) so that a built chartset can always
  say where its imagery came from and under what terms.
- **What is deliberately absent** - no re-encoding, no watermarking, no reprojection.
  Tiles pass through byte for byte, which is what keeps a built tile identical to the
  cached one and keeps an image-processing stack out of the installer.
- **Sparseness** - coverage is polygon-derived and never rectangular, so an mbtiles file
  chartMaker writes is partially populated at every zoom by design, and readers have to be
  expected to tolerate that.

---

**Next:** [RCT](rct.md)
