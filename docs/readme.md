# chartMaker - Satellite Chart Builder for Mariners

**Home** --
**[Architecture](architecture.md)** --
**[Design](design/readme.md)** --
**[Implementation](implementation.md)** --
**[Deployment](deployment.md)**

**chartMaker** is a desktop application for building **offline satellite chartsets** for
use aboard a boat. You draw the regions you care about on a map, say how much detail each
one deserves, connect an imagery source of your own choosing, and chartMaker fetches,
assembles and packages the result - as **`.mbtiles`** for [**OpenCPN**](https://opencpn.org/),
and as **`.RCT` files** for the aerial photo overlay on Raymarine E-Series plotters.

The reason to want such a thing is simple. Official charts are surveyed, authoritative and
frequently wrong about the last hundred metres: the reef that grew, the sandbar that moved,
the unmarked pass that every local uses and no chart shows. Satellite imagery shows what is
actually there. Once it is on the boat, it is there when the internet is not - which, in the
places where it matters most, is nearly always.

chartMaker **never ships imagery** - not one tile, ever. What it ships is a handful of
*source definitions*, and only for sources whose publishers permit the use. Beyond those it
works with any XYZ tile service on the Web Mercator grid at 256 pixels; which service you
point it at, and on what terms, is your decision. A source is described to chartMaker by a
small declarative text file - a **TSD**, or *Tile Source Definition* - which you author, or
are given, or pick from the ones that come with the app. This is a deliberate boundary
rather than a missing feature, and more of the architecture follows from it than from any
other single decision.

What chartMaker keeps between sessions, and what makes it more than a downloader, is the
**coverage model**: a durable, editable description of what your chartset *is* - the
regions, how they nest, the zoom levels each deserves, the small areas worth going deeper
on. Imagery is rebuilt from that model whenever you like. The model is the thing you refine
over years; the tiles are a build artifact.

chartMaker is a Windows application, distributed as a versioned installer with no
prerequisites to install. It is not turnkey, and does not pretend to be - it asks you to
bring a source and make a decision or two - but everything after that is meant to just work.

## Documentation Outline

- **[Architecture](architecture.md)** -
  What chartMaker is and how it is put together: the coverage model, the Tile Source
  Definition and why it exists, the mbtiles and RCT outputs, the UI layers, deliberate
  boundaries, and the distribution path.

- **[Design](design/readme.md)** -
  The formats and subsystems in detail, each in its own document: the
  [region](design/regions.md) file and the coverage model on disk, the
  [TSD](design/tsd.md) field reference, the [build](design/build.md) engine and the tile
  proxy, and the [mbtiles](design/mbtiles.md) and [RCT](design/rct.md) output
  specifications.

- **[Implementation](implementation.md)** -
  How the modules are layered and what that layering buys, the HTTP surface between the
  browser and the program, and the threads it runs.

- **[Deployment](deployment.md)** -
  The program as an installed artifact: where it keeps the user's material and its own, the
  two executables, what an uninstall leaves behind, and what a release is made of. The
  packaging procedure itself is in [Installer](installer.md).

## Credits

chartMaker stands on these projects:

- [**Perl**](https://www.perl.org/) and [**wxPerl**](https://metacpan.org/dist/Wx) over
  [**wxWidgets**](https://www.wxwidgets.org/) - the application, its native UI, and its
  portability.
- [**Leaflet**](https://leafletjs.com/) - the map canvas on which regions are drawn and
  chartsets are previewed.
- [**SQLite**](https://www.sqlite.org/) and the
  [**MBTiles specification**](https://github.com/mapbox/mbtiles-spec) - the container the
  built chartsets live in.
- [**Cava Packager**](http://www.cavapackager.com/) and
  [**Inno Setup**](https://jrsoftware.org/isinfo.php) - the tools that turn a Perl program
  into a Windows installer.
- [**OpenCPN**](https://opencpn.org/) - the open source chart plotter that reads what
  chartMaker builds, and the bench on which it is developed.

## License

This program, project, and repository is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License Version 3 as published by
the Free Software Foundation.

These materials are distributed in the hope that they will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR ANY PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

Please see [LICENSE.TXT](../LICENSE.TXT) for more information.

## Please Also See

- [**navMate**](https://github.com/phorton1/base-apps-navMate/blob/master/docs/readme.md) -
  the companion application: a lifelong, device-independent home for your waypoints,
  routes and tracks. chartMaker makes the *charts* you carry; navMate manages the
  *navigation data* you carry. navMate is also the E-Series Firmware Builder, which is what
  puts the aerial photo overlay - the feature chartMaker's `.RCT` files feed - on the
  plotter in the first place.

- [**base-Pub**](https://github.com/phorton1/base-Pub) - the shared Perl library that
  provides chartMaker's application framework, wx window management, and embedded HTTP
  server.

- [**Ray Library**](https://github.com/phorton1/base-Pub-Ray/blob/master/docs/readme.md) -
  the reverse-engineered Raymarine protocols, file formats and E-Series firmware internals
  that the RCT format was built against.

---

**Next:** [Architecture](architecture.md)
