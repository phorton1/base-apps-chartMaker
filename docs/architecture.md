# chartMaker - Architecture

**[Home](readme.md)** --
**Architecture** --
**[Design](design/readme.md)** --
**[Implementation](implementation.md)** --
**[Deployment](deployment.md)**

## Primary Statement

**chartMaker is a curated coverage model with builders attached. The model - what your
chartset is, region by region, zoom by zoom - is the product. Imagery is a regenerable
build artifact, and the source of that imagery is supplied by the user, never by the
application.**

## Overview

chartMaker is a **wxPerl desktop application** built on the `Pub::`, `Pub::WX` and
`Pub::HTTP` libraries, following the same architecture as its companion application
[navMate](https://github.com/phorton1/base-apps-navMate/blob/master/docs/readme.md): a
native windowed program that also runs a **console** interface and an embedded **HTTP
server**, serving a **Leaflet** map applet to a browser window running alongside it. It is
packaged by **Cava Packager** into a versioned Windows installer that bundles its own Perl,
and is published as a GitHub Release asset.

The application takes two kinds of input and produces two kinds of output:

```
    regions ---------.                             .---> .mbtiles ---> OpenCPN
    (geometry,        \                           /
     nesting, the      \                         /
     levels each        +---> build engine -----+-----> .RCT
     area carries)     /      (queued, rate-     \      (E-Series card)
                      /        limited, cached)   \
    TSD -------------'                             '---> other exporters
    (the imagery
     source)
```

**The region definition IS the build specification.** There is no separate target object
holding which regions, how deep and which source; a region carries its own levels, a set
names what travels together, and a build cap prunes the rest arithmetically.

Four architectural facts account for most of what follows:

1. **The coverage model is durable and the tiles are not.** Regions are edited, nested and
   refined over years. A rebuild reproduces the imagery from the model.
2. **Sources are data, not code.** Every imagery source is described by a **TSD** file -
   one that ships with the app, or one the user supplies. chartMaker never ships tiles, and
   never ships keys.
3. **Depth is requested by a region and capped by a build.** The same coastline is built
   shallow for a small card and deep for a large one, from one description of where it is.
4. **Every output is an export, and none of them is the source.** The build engine's
   outputs are peers over one seam; no output format is produced by converting another.

## Who chartMaker Is For

Two audiences, with one bar between them.

**OpenCPN users** who want satellite imagery under their charts, offline, in a region
OpenCPN's chart sources do not cover well.

**Raymarine E-Series (E80/E120) owners** running the custom firmware built by navMate's
E-Series Firmware Builder, which adds an aerial photo overlay to a twenty-year-old plotter.
That overlay reads chartMaker's `.RCT` card.

The bar is deliberate and it is set at "a fighting chance", not at "turnkey": someone
capable of installing navMate and using it to build custom plotter firmware should be able
to install chartMaker, define regions, connect a source of their own, and get imagery onto
their plotter - without following five websites with twelve broken links describing three
toolchains that no longer exist. That is the whole ambition. It is not an app store app,
and the boundary in the next section is why it cannot be.

## Tile Source Definition (TSD)

### Why it exists

A tile source is a URL template, a set of limits, and a set of terms. Every application in
this space has had to decide whether to **ship** those - to publish a catalog of imagery
services with the software.

chartMaker ships only what it is entitled to ship. A **TSD** (*Tile Source Definition*,
extension `.tsd`) is a small declarative file that describes exactly one source, and the
application is a reader of TSD files rather than a holder of sources. Users author their
own, or exchange them, or use the definitions that come with the app - imagery in the
public domain or explicitly licensed for reuse, where the publisher intends this use. It
also ships a [catalog](design/catalog.md) of services a definition can be created from,
which is the same act at one remove and answers to the same rule.

This is a boundary, not a limitation, and it buys three concrete things:

- **The decision stays with the user.** Which service, under which terms, is the user's
  call to make and the user's call to be responsible for. What ships is a starting point,
  not a recommendation and not a limit.
- **A source can be shared without shipping anything private.** Credentials are never in a
  TSD (see below), so a definition is safe to hand to someone by construction.
- **Sources can be fixed without a release.** Tile services rot. A user whose source
  changed edits a text file rather than waiting for a new version of the application.

### What a TSD contains

A TSD is **JSON**, validated on load against rules that are deliberately unforgiving -
because these files will circulate between strangers, and those rules are both a validator
and a machine-checkable statement of what the format is *able* to say. A `notes` field
compensates for JSON's lack of comments.

It describes a source's addressing - a URL template, the grid, the tile size - along with
its protocol limits, its terms, what it may be used for, and the names of any keys it
needs. The full field reference, the validation rules and the authoring tools are in
[Design: TSD](design/tsd.md).

The URL template substitutes from a **closed set** of placeholders - `{z} {x} {y} {-y} {s}
{q}` plus any key names the file declares - and nothing else. `{-y}` covers the TMS
row-flip so no scheme enum is needed; `{q}` covers quadkey addressing, which is the same
grid under a different encoding.

The fields land almost exactly on Leaflet's `L.TileLayer` options, arrived at independently
over fifteen years of tiled maps. That convergence is a good sign the shape is right.

### The organising principle: the TSD declares the PROTOCOL, the runtime discovers the DATA

This is the rule that settles most format arguments before they start.

A **protocol** fact is true everywhere the source is reachable: the URL shape, the
addressing scheme, the tile size, the highest zoom the server will answer at all. These are
declarative and belong in the file.

A **data** fact is local: whether this particular source has anything at this particular
place, and at what real resolution. These are discovered at runtime and never declared:

- **No `bounds`, and no declared coverage.** Every source is sparse. A rectangle claims
  both more and less than the source actually holds, and the build has to tolerate absence
  regardless - so a declaration could only ever have been a hint.
- **No claim of real maximum detail.** Servers commonly upsample past their native
  resolution rather than returning "not found", and the depth of real detail varies by
  location within a single source. The *protocol* limit is declared; the *native* limit is
  discovered.
- **No guaranteed image type.** `tile_format` is an expectation. The actual format is
  detected from the image's magic bytes, because servers mix formats and at least one
  output format is picky about which it gets.

Coverage is therefore a **runtime artifact**. For local sources it is derived by inspection.
For remote sources it is discovered empirically and cached per source, which is what makes
the negative case worth storing too: caching the misses accumulates a real coverage picture
for free and stops every rebuild from re-requesting tiles known to be absent.

### What a TSD cannot express

**A TSD contains no executable content of any kind.** No script, no expression language, no
computed fields. The closed placeholder set is the entire vocabulary.

This is a structural guarantee rather than a promise: the format is unable to express a
signature computation or a session-token derivation, so no TSD can be authored that
performs one. The validator enforces this; a README could only ask for it. A file that arrives
from a stranger is data being read, not code being run.

### Display versus build

A TSD declares `uses` - whether the source may be used for **display** only, or for
**display and build**. A display-only source never appears in the build picker.

The distinction happens to do two jobs at once, which is usually the sign that a field is
correctly drawn. It reflects genuinely different traffic - browsing a map generates
viewport-shaped requests, while building a chartset generates systematic ones - and it
reflects the user's own assertion about what a given source is for. It guards against
accident rather than intent. It is also just practical: a street basemap is display-only
because building a nine-thousand-tile pyramid of one is pointless.

The same distinction governs the editor: **chartMaker never prefetches beyond what it is
displaying.** Cache reuse in both directions is free and sensible; speculative fetching is
not, and would erase the line between looking and building.

### Attribution and keys

**Attribution is mandatory and non-empty** - chartMaker refuses to load a TSD without it.
One validation rule, and every package chartMaker emits can carry its provenance.

**Keys are names, never values.** A TSD names what a source's url needs and where to
obtain one; the value lives in a per-user store outside the file, whose location is
described in [Deployment](deployment.md#the-key-store) and whose rules are in
[Design: Key Store](design/key_store.md). A file carrying a value is REFUSED at load, which
is what makes the consequence structural: no key can leak through a shared definition, and
none ever lands in a file that could be committed to a repository or served to a browser.

The mechanism is a named substitution rather than a credential system, because an API key,
a password and an archive release number are the same thing to a url and only some of them
are secret.

**Regions and targets reference sources by id and never embed them.** Sharing a coverage
model therefore never ships the author's source inside it. An unresolved id prompts the
recipient to supply their own - the right conversation to force at exactly that moment.

## The Tile Proxy

chartMaker has exactly one path from a tile coordinate to bytes, and everything uses it -
the map in the browser, the preview, the source evaluator and the build engine. **The
browser never contacts a tile server directly.** It asks the application, and the
application answers.

That single decision is load-bearing for four things that otherwise have nothing to do with
one another:

- **No key can reach the browser.** A source that needs a key is fetched by the
  application, which holds the key. Nothing in the page - and nothing in the page's network
  log - contains a secret. Without the proxy, the promise made just above could not be
  kept.
- **Displaying and building share one cache.** Looking at a region at a zoom it will be
  built at leaves those tiles where the build will find them, so nothing is fetched twice.
- **The refusal to prefetch becomes checkable.** One place counts every outbound request,
  which turns a claim in a document into a property that can be observed.
- **Rate limiting has one home,** where no code path can bypass it by accident.

It also collapses most of the build engine into something already written: **the build is
the same path driven by the coverage model instead of by a viewport.**

## Deliberate Boundaries

Several things chartMaker refuses to do are load-bearing. Each is recorded with what it
buys, because in a year each will look like an arbitrary limitation and the reason will
have been forgotten.

**Never ships tiles, and ships no source it is not entitled to ship.** chartMaker
distributes imagery under no circumstances - not one tile, ever. What it ships is
*definitions*, and only for sources whose publishers permit the use those definitions
declare. It ships a [catalog](design/catalog.md) of such services, and the same rule governs
every entry in it: an entry may state only a use its operator permits, so what the list
offers is never a way around somebody's terms. The user's choice stays the user's choice,
and the application holds no opinion it is not entitled to hold.

**Ships no keys.** Nothing to leak and nothing to revoke. Users supply their own values,
under the names a file declares.

**Web Mercator at 256 pixels, or rejected at import.** Tiles pass through byte-for-byte, so
no reprojection or image-processing stack is needed, so the installer is a single artifact
with no user-assembled toolchain behind it. Reprojection happens outside, in tools built
for it, and comes back as a local source.

**No coverage declared in a source.** Sources cannot lie about what they hold, because they
are not asked. Coverage is discovered.

**No executable content in a TSD.** The format structurally cannot compute a key.
Enforced by the validator rather than by trust.

**The editor never prefetches.** The line between displaying and building stays real.

**The browser never contacts a tile server.** Every request goes through the application,
which is what makes "no key can reach the browser" structural rather than merely
careful.

**Nothing is editable in two places.** Lists, names, structure and status are edited in the
native windows; geometry and imagery are edited on the map. Both surfaces show both kinds
of thing, but each thing has exactly one place it is changed - one model, one
implementation of every operation, and no way for two views to disagree.

**No project file.** The unit people exchange is a region and the container around it is a
folder, so there is nothing to write that describes which files belong together - see
[Regions](design/regions.md).

There *is* a File menu, and it earns its place for a reason the original refusal missed: a
**set is the document**, opened and saved as one. Only Save writes a region file, so killing
the application leaves the folder exactly as it was, a session of experiments can be thrown
away by closing without saving, and a test can drive the whole application against a fixture
without touching it. What was refused - and still is - is a project *file*: the folder is
the manifest.

**Not turnkey.** The corollary of the first two: the seam that keeps the decision with the
user is the same seam that prevents the application from making it for them.

What is **not** a refusal - the additive half, and the actual invention here - is the
curated coverage model maintained over time, and the pluggable exporter seam. Tile
downloaders exist. What does not exist is a tool that keeps a durable, refinable model of
what your chartset *is*.

## The Coverage Model

A **region** is an area of water you care about, described by a polygon. Inside it, any
number of **subregions** mark the smaller areas that deserve more detail - the approaches,
the anchorage, the pass. A subregion is itself a region and may contain subregions of its
own, so a square nautical mile at high detail with a single dock deeper still inside it is
expressible without any special case.

**One region is one file, and it is self-contained.** It holds its geometry, its identity
and all of its subregions, and it refers to nothing outside itself - no parent elsewhere,
no imagery source, no path on the author's disk. That is what makes a region the unit
people exchange: handing someone a region file hands them a complete description of a piece
of coastline and nothing else.

There is no project file. Regions live in a folder, and the application finds them by
looking; a **set** is that folder, and one set is open at a time - read into memory when it
is opened and written back when it is saved. The full format, and what being a document
buys, are in [Design: Regions](design/regions.md).

Three rules give the model its properties:

- **Depth is requested by a region and decided by a target.** A region says the anchorage
  deserves detail; a target says this particular card stops at a particular zoom, and the
  built depth is the lesser of the two. That is what lets one description of Bocas del Toro
  produce both a small card for a plotter with a small slot and a large one for a plotter
  without that limit - and, because the tiles are already cached, the second card costs no
  additional fetching at all. Real imagery resolution is a third opinion, and it only ever
  warns: a source that upsamples still yields tiles worth carrying.
- **A polygon meets the tile grid exactly once**, at the zoom that area is quantised at.
  Coarser levels are the parent tiles of that set and finer ones fill it in completely, so
  coverage is the union of those tiles rather than the polygon itself, and there is only
  ever one place geometry becomes tiles.
- **Subregions are geometrically contained in their parent.** Containment of polygons then
  implies containment of tiles - every tile a subregion covers has a coarser tile above it
  that the parent already covers - which is exactly the nested-coverage invariant the card
  format needs in order to fall back gracefully from a missing tile to a coarser one. It
  also means each level supplies only the zoom band its parent does not reach.
- **Where regions overlap, ownership is a union, not a contest.** A tile that two regions
  both want appears in both. Duplicate tiles at a seam are harmless downstream, and the
  alternative - deciding an owner - is how tiles go missing at exactly the boundaries where
  a mariner is most likely to be looking.

The **editor** and the **preview** are one component in two modes, not two pipelines: the
same map, the same tile proxy, a clip applied on top. Preview earns its place by answering
what the chartset will actually contain - what the *build* source looks like here before
committing to a nine-thousand-tile run, and how deep the card really goes at any point on
it, which is read off the map by zooming in until the imagery stops.

**It shows contents, not a client.** Consumers differ in how they cope with a zoom the card
does not carry - the E-Series magnifies the deepest tile it holds, OpenCPN permits
essentially unlimited overzoom from the deepest level in the file - and none of that is a
fact about the chartset. Rendering the card's own contents is the same answer whoever reads
it, so the mode stays true as consumers are added and needs no evidence about any of them.

What makes that more than an illustration is that **preview renders through the build's own
rasteriser.** Whether a tile is in coverage is asked once, of one implementation, whether
the asker is the screen or the build. A preview that looked right and a build that came out
wrong would be two answers to one question, and the place they would differ is the seams -
where it costs the most.

## Outputs

**Exporters are peers over one seam**, and the seam is the region's coverage enumerator plus
the tile cache - not a file. An output format is not built by converting another output
format.

**`.mbtiles`** is a standard container read directly by OpenCPN: well specified, with a
large ecosystem, and holding nothing chartMaker-specific. One file per **node** rather than
per region, because the format carries a single maximum zoom for a whole file and a reader
derives the chart's scale from it - so depth that an [RCT](design/rct.md) expresses
*spatially*, in per-block coverage, this format can only express in the filesystem.

**`.RCT` is exporter number one.** The aerial photo overlay in the custom E-Series firmware
reads a purpose-built on-card raster format - one `.RCT` file per region under `\RASTER\`,
with no manifest, because the set of files present *is* the set of regions. It is
regenerable: the card is a deployment artifact, not a source of truth.

Further exporters plug into the same seam, and it is now a real seam rather than an
intention: an output format declares what it can carry, what it can be named, where it goes
by default, and how it writes and un-writes itself. A KAP/BSB writer is the obvious third,
reaching a long tail of navigation software for very little work.

Both formats have their own specifications: [MBTiles](design/mbtiles.md) and
[RCT](design/rct.md).

## Distribution Path

1. **Source** - run from a command prompt under a stock Perl; the developer workflow.
2. **Public repository** - documentation and architecture, publishable before any installer.
3. **Windows installer** - a versioned, self-contained build published as a GitHub Release
   asset, bundling its own Perl so that nothing needs to be installed first.

chartMaker is shipped, documented and tested on **Windows only**. That is a distribution
choice rather than a code limitation: the source is portable Perl and wxPerl. Ports and
forks are welcome; the shipped surface stays deliberately narrow.

What an installation places, what it leaves behind, and what a release is made of are in
[Deployment](deployment.md).

## Code Organization

The repository follows the same layout as the other applications in this family:

| Path          | Holds                                                              |
| ------------- | ------------------------------------------------------------------ |
| `/`           | The application source modules.                                    |
| `/_res`       | Runtime resources bundled into the installer.                      |
| `/_res/site`  | The Leaflet applet - HTML, CSS, JavaScript - served by the embedded HTTP server. Not Perl. |
| `/_installer` | Packaging support for the Windows installer build.                 |
| `/releases`   | The release log. Installers themselves are Release assets, so the repository stays text-only and lean. |
| `/docs`       | These documents, and the design specifications in `/docs/design`.  |

Underscore-prefixed folders at the top level hold **separate executables** and build-time
material rather than application modules, keeping them visually and functionally distinct
from the source itself.

Within the source itself, modules carry a **lexical prefix marking their layer** - `cm_`,
`dm_`, `em_`, `w_` - so the prefixes sort in layer order in a file browser or a tab bar and
the listing is the architecture. A module may use anything above it and nothing below, and
everything above the wx layer must load and run with no wx at all. The layers and what that
rule buys are specified in [Implementation](implementation.md#the-modules-are-layered-and-the-layering-is-a-rule).

That rule is what makes the build engine's home a decision rather than a fork: a separate
executable can use the model, the cache and the exporters directly, sharing exactly the code
the GUI uses - no second implementation, and no IPC contract to maintain.

The `em_` layer has one more property worth stating: **`em_command` sits beneath every
front door.** The console reads a line, an HTTP client calls the command endpoint, and the
map applet posts an edit - all three hand the same dispatcher the same verb. One vocabulary,
three transports. That is also the test surface, since anything one door can do the others
can; and it is what would make an undo journal a matter of recording what already passes
through a single point, rather than a feature to be built.

---

**Next:** [Design](design/readme.md)
