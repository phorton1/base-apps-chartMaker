# chartMaker - MBTiles

**[Design](readme.md)** --
**[Regions](regions.md)** --
**[Editing](editing.md)** --
**[Map Editing](editing_map.md)** --
**[Tree Editing](editing_tree.md)** --
**[TSD](tsd.md)** --
**[TSD Editor](tsd_editor.md)** --
**[Catalog](catalog.md)** --
**[Key Store](key_store.md)** --
**[Build](build.md)** --
**MBTiles** --
**[RCT](rct.md)** --
**[Cleanup](cleanup.md)**

folders: **[Home](../readme.md)** --
**[Architecture](../architecture.md)** --
**Design** --
**[Implementation](../implementation.md)** --
**[Deployment](../deployment.md)**

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

- **Building `.rct` files does not require building an mbtiles first.** The two are independent
  outputs of the same model.
- **Each exporter owns its own encoding question.** A source that returns PNG is the RCT
  exporter's problem to transcode, because RCT is JPEG-only; mbtiles has no such constraint
  and stores what the source sent.

---

## One file per NODE, and that is the whole design

An MBTiles file carries **one `minzoom` and one `maxzoom` for the whole file**, and OpenCPN
derives the chart's scale from the maximum. There is nowhere in the format to say *this
depth, over here*.

That is what rules out a per-region file. Bocas covers z10-16 across the whole archipelago
and reaches z20 inside two boxes of a few hundred metres each. As one file it would announce
itself as a z20 chart over its entire extent, and chart selection would prefer it at scales
where it holds nothing but magnified z16.

RCT does not have this problem because depth is carried per **coverage block**, which is to
say **spatially**. MBTiles has no such structure, so the split has to happen in the
filesystem instead:

```
    <MBTILES_DIR>/<set>/<Region>/<Node>.mbtiles

    mbtiles/Panama/Bocas/Bocas.mbtiles      z10-16   the whole archipelago
                        /Popa00.mbtiles     z17-18   a detail box
                        /Marina.mbtiles     z19-20
                        /MyProp1.mbtiles    z17-18
                        /MyProp2.mbtiles    z19-20
```

Each file is one node's own band, internally uniform in depth, so the number it advertises
is true everywhere inside it. Overlapping charts at different scales are what a scale-aware
reader's quilting exists for.

**This is the same idea that was REJECTED for RCT**, and the difference is the consumer.
A separate `.rct` per detail area was refused because `INDEX.RCI` selects a file by bounds
and a Popa file sitting inside Bocas' bounds makes selection ambiguous - the E-Series
chooses by containment, not by scale. OpenCPN chooses by scale. The constraint that killed
the idea there does not exist here.

**One node is one source, so one file has one honest `format`.** MBTiles has a single
format field; a per-region file spanning two sources could not have filled it in truthfully.
The same is true of `attribution`. Both fall out of the split rather than being arranged.

**A tile claimed by two nodes is written into both files, deliberately.** Two sibling detail
areas can share a tile without their polygons touching, because a tile is a square both of
them clip - see [regions](regions.md#containment-overlap-and-the-invariant-they-buy). The
`.RCT` exporter resolves that, because everything it writes lands in one file. Here the
opposite is right: **each file has to stand alone over its own polygon**, so removing the
tile from one of them to spare the other a duplicate would punch a hole in a chart somebody
may open by itself. The duplicate costs a couple of kilobytes and the two copies are the
same image, since two nodes that disagreed about a source would have been refused before the
build ran.

**Names cannot collide, and that is enforced rather than hoped.** A node id is unique within
its whole region ([regions](regions.md)), so no two files in one folder can share a name; the
region folder keeps two regions' identically named detail boxes apart. The resulting path is
exactly the node's path, which is also how the source map keys it.

## What it writes

The MBTiles 1.3 schema, exactly - no extra tables and no extra columns. A
chartMaker-specific field in a standard container is how a format stops being the standard
one.

```sql
    metadata (name text, value text)
    tiles    (zoom_level integer, tile_column integer, tile_row integer, tile_data blob)
```

Metadata: `name`, `description`, `type`, `version`, `format`, `minzoom`, `maxzoom`,
`bounds`, `center`, `attribution`.

- **`format`** is `jpg` or `png`, from the source's declared tile format - and the exporter
  checks the format the **cache sniffed from the bytes** against it per tile, refusing if a
  source declares one and serves the other. No image is decoded; it reads a fact the cache
  already established.
- **`bounds`** is the union over **every** tile in the file, coarse levels included. A coarse
  tile covers more ground than the polygon that produced it and it really is in the file, so
  bounds describing only the finest level would be a claim the file itself contradicts.
- **`attribution`** carries the source's credit, in the key the format already has for it.
  An `.rct` carries the same text in its own blob; neither invents a place to put it.

**Row order is the one thing that fails silently.** MBTiles counts tile rows from the
**south**; every source chartMaker reads counts them from the north. One line converts it:

```perl
    tile_row = (1 << $z) - 1 - $y
```

Getting it wrong produces a file that is structurally perfect and vertically mirrored, which
is why the test checks a known tile against the arithmetic rather than against a second call
to the same code.

**Sparseness is by design.** Coverage is polygon-derived and never rectangular, so these
files are partially populated at every zoom. A tile that is absent - or that never arrived -
is simply not a row. A reader that assumes a full rectangle is wrong about this format
generally, not about us.

**No re-encoding, no watermarking, no reprojection.** Tiles pass through byte for byte,
which is what keeps a built tile identical to the cached one and an image stack out of the
installer.

## What it deliberately does not claim

**Byte reproducibility.** An `.rct` is byte-reproducible and that is an invariant the tests
enforce. A SQLite file carries page allocation state; rows are inserted in row-major order so
the *content* is deterministic, but two builds are not promised to be identical byte for
byte. Pretending otherwise would be a claim nobody had tested.

**A parent for every tile.** The nested-coverage invariant is an RCT one, because the E80
overzooms from a present ancestor. OpenCPN clamps requests to the levels present and
overzooms without needing that guarantee.

## Where it sits in the build

`build mbtiles <id|set|all> [zmax]` runs the same act `build rct` does - validate, fill,
refuse or export - because [the build](build.md) is one act and the output format is four
guards and a write call. What changes:

| | RCT | MBTiles |
|---|---|---|
| carries | JPEG | JPEG or PNG |
| converts | PNG, where a decoder is installed | nothing, it already holds both |
| files must agree on zauthor/zmin | yes, the E80 fuses them into one pyramid | no, each file is an independent chart |
| name check | an 8.3 stem | any valid id |
| default folder | `RASTER_DIR/<set>` | `MBTILES_DIR/<set>` |

**The fill is format-blind**, which is worth noticing rather than arranging: it asks the
coverage enumerator for every tile and the cache is keyed by source, so a set already built
to one format builds to the other without fetching anything at all.

**The configured output folder belongs to the `.rct` build.** It is where an E-Series card gets
assembled, chosen once and remembered per set; an mbtiles build has no business landing a
tree of region folders in the middle of it, so it takes its own default.

---

**Next:** [RCT](rct.md)
