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

**`.mbtiles` is the hub.** The build engine writes tiles into a standard MBTiles container
and nothing else; every other output chartMaker produces is a converter reading from one.
It is read directly by OpenCPN, it is a well-specified format with a large ecosystem behind
it, and making it the only thing the build engine knows how to write is what keeps the
exporter seam honest.

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
