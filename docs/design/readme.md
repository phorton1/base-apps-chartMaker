# chartMaker - Design

**Design** --
**[Regions](regions.md)** --
**[TSD](tsd.md)** --
**[Build](build.md)** --
**[MBTiles](mbtiles.md)** --
**[RCT](rct.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)**

Where [Architecture](../architecture.md) says what chartMaker is and why it is shaped the
way it is, these documents say how it is actually built - the level at which decisions stop
being philosophy and start being data structures, file formats and rules a program can
check.

Two of them describe things a user can hold in their hand and hand to somebody else - a
**region** and a **source**. Two describe things chartMaker writes - an **mbtiles** file
and an **RCT card**. The fifth describes what happens in between.

## The documents

- **[Regions](regions.md)** -
  The coverage model on disk: the region file and its nested subregions, how depth is
  requested and where it is capped, the containment and overlap rules, and the workspace
  that holds regions without being a project file.

- **[TSD](tsd.md)** -
  The Tile Source Definition in full: every field, the closed placeholder set, the
  validation rules, how a credential slot resolves to a stored secret, and how a source is
  authored, tested and evaluated.

- **[Build](build.md)** -
  The tile proxy that every request passes through, the cache and its keying, negative
  caching, the queue and its rate limiting, how a run resumes rather than restarts, and the
  seam an exporter has to implement.

- **[MBTiles](mbtiles.md)** -
  The hub format: what chartMaker writes into a standard MBTiles container, and the
  metadata that carries provenance into everything downstream.

- **[RCT](rct.md)** -
  The E-Series card format: what chartMaker guarantees a card, the nested coverage the
  format depends on, and the two constraints only the producer can see.

---

**Next:** [Regions](regions.md)
