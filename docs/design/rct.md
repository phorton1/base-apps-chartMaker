# chartMaker - RCT

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**RCT**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

*This document is not yet written.*

**`.RCT` is exporter number one.** The aerial photo overlay in the custom E-Series firmware
built by [navMate](https://github.com/phorton1/base-apps-navMate/blob/master/docs/readme.md)
reads a purpose-built on-card raster format: an `.RCT` file per region, plus an `INDEX.RCI`
that selects among them. A converter generates them from a region's
[mbtiles](mbtiles.md), which makes a card a deployment artifact rather than a source of
truth - it is regenerated, never edited.

Intended scope:

- **The `.RCT` file layout** - header, zoom directory, tile storage, and the metadata
  section that carries attribution and provenance onto the card.
- **`INDEX.RCI`** - how the plotter chooses which card file applies where.
- **The nested-coverage requirement** - the format falls back from a missing detailed tile
  to a coarser one, which is the property the [region](regions.md#containment-overlap-and-the-invariant-they-buy)
  containment rules exist to guarantee.
- **JPEG only** - and therefore what happens when a source returns a PNG.
- **Why the card is smaller than the mbtiles** - depth caps are applied at export, so one
  deeply built model produces cards of several sizes with no additional fetching.

---

**Next:** [Implementation](../implementation.md)
