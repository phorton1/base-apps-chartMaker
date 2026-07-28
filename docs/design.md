# chartMaker - Design

**[Home](readme.md)** --
**[Architecture](architecture.md)** --
**Design** --
**[Implementation](implementation.md)**

*This document is not yet written.*

Where [Architecture](architecture.md) says what chartMaker is and why it is shaped the way
it is, this document will say how it is actually built - the level at which decisions stop
being philosophy and start being data structures.

Intended scope:

- **The TSD in detail** - the full field reference, the JSON Schema, validation rules,
  the closed placeholder set, the credential store, and how a source is authored and
  tested.
- **The project file** - what a coverage model contains on disk, how regions and
  subregions are represented, and what makes one shareable.
- **The build engine** - the queue, rate limiting, the tile cache and its keying, negative
  caching, and how a run is resumed rather than restarted.
- **The exporter seam** - what an output format has to implement, and where mbtiles stops
  being a file and starts being an interface.
- **Module layering** - the lexical prefix convention, which layer may import from which,
  and where the Leaflet applet's boundary falls.

---

**Next:** [Implementation](implementation.md)
