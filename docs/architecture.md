# chartMaker - Architecture

**[Home](readme.md)** --
**Architecture** --
**[Design](design.md)** --
**[Implementation](implementation.md)**

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
    project file  ---.                             .---> .mbtiles  (the hub)
    (the coverage      \                          /          |
     model: regions,     +---> build engine -----+           +---> OpenCPN
     zooms, detail      /      (queued, rate-      \         |
     areas)            /        limited, cached)    \        '---> other exporters
                      /                              \
    TSD  ------------'                                '---> .RCT + INDEX.RCI
    (one or more tile source definitions)                   (E-Series card)
```

Three architectural facts account for most of what follows:

1. **The coverage model is durable and the tiles are not.** Regions are edited, nested and
   refined over years. A rebuild reproduces the imagery from the model.
2. **Sources are data, not code.** Every imagery source is described by a **TSD** file -
   one that ships with the app, or one the user supplies. chartMaker never ships tiles, and
   never ships credentials.
3. **mbtiles is the hub and the card is an export.** Everything the build engine produces
   lands in `.mbtiles` first; every other output format is a converter reading from there.

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
public domain or explicitly licensed for reuse, where the publisher intends this use.

This is a boundary, not a limitation, and it buys three concrete things:

- **The decision stays with the user.** Which service, under which terms, is the user's
  call to make and the user's call to be responsible for. What ships is a starting point,
  not a recommendation and not a limit.
- **A source can be shared without shipping anything private.** Credentials are never in a
  TSD (see below), so a definition is safe to hand to someone by construction.
- **Sources can be fixed without a release.** Tile services rot. A user whose source
  changed edits a text file rather than waiting for a new version of the application.

### What a TSD contains

A TSD is **JSON with a published JSON Schema** - chosen over a looser format precisely
because these files will circulate between strangers, and a schema is both a validator and
a machine-checkable statement of what the format is *able* to say. A `notes` field
compensates for JSON's lack of comments.

```
tsd_version, id, name
kind:         remote_xyz | local_mbtiles | local_dir | wms
url           (template), subdomains, tile_format, tile_size, crs
zoom:         { min, max }                     <- PROTOCOL limits only
attribution   (MANDATORY), terms_url, license
redistributable:  yes | no | unknown           (default unknown)
uses:         ["display"] | ["display","build"]
credentials:  [ { slot, label, obtain_url } ]  <- SLOTS, never values
policy:       { max_concurrency, min_interval_ms }
```

The URL template substitutes from a **closed set** of placeholders - `{z} {x} {y} {-y} {s}
{q}` plus any credential slots the file declares - and nothing else. `{-y}` covers the TMS
row-flip so no scheme enum is needed; `{q}` covers quadkey addressing, which is the same
grid under a different encoding.

The fields land almost exactly on Leaflet's `L.TileLayer` options, arrived at independently
over fifteen years of tiled maps. That convergence is a good sign the shape is right.

### The organising principle: the TSD declares the PROTOCOL, the runtime discovers the DATA

This is the rule that settles most schema arguments before they start.

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
performs one. A schema enforces this; a README could only ask for it. A file that arrives
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

### Attribution and credentials

**Attribution is mandatory and non-empty** - chartMaker refuses to load a TSD without it.
One validation rule, and every package chartMaker emits can carry its provenance.

**Credentials are slots, never values.** A TSD names the credential a source needs and
where to obtain one; the actual secret lives in a per-user store outside the file, whose
location is described in [Implementation](implementation.md). The consequence is that no
key can leak through a shared definition, and no secret ever lands in a file that could be
committed to a repository or served to a browser.

**Project files reference sources by id and never embed them.** Sharing a coverage model
therefore never ships the author's source inside it. An unresolved id prompts the recipient
to supply their own - the right conversation to force at exactly that moment.

## Deliberate Boundaries

Several things chartMaker refuses to do are load-bearing. Each is recorded with what it
buys, because in a year each will look like an arbitrary limitation and the reason will
have been forgotten.

**Never ships tiles, and ships no source it is not entitled to ship.** chartMaker
distributes imagery under no circumstances - not one tile, ever. What it ships is
*definitions*, and only for sources whose publishers permit the use those definitions
declare. It does not catalog, link to, or hint at a source whose terms it would be working
around. The user's choice stays the user's choice, and the application holds no opinion it
is not entitled to hold.

**Ships no credentials.** Nothing to leak and nothing to revoke. Users supply their own
into declared slots.

**Web Mercator at 256 pixels, or rejected at import.** Tiles pass through byte-for-byte, so
no reprojection or image-processing stack is needed, so the installer is a single artifact
with no user-assembled toolchain behind it. Reprojection happens outside, in tools built
for it, and comes back as a local source.

**No coverage declared in a source.** Sources cannot lie about what they hold, because they
are not asked. Coverage is discovered.

**No executable content in a TSD.** The format structurally cannot compute a credential.
Enforced by a schema rather than by trust.

**The editor never prefetches.** The line between displaying and building stays real.

**Not turnkey.** The corollary of the first two: the seam that keeps the decision with the
user is the same seam that prevents the application from making it for them.

What is **not** a refusal - the additive half, and the actual invention here - is the
curated coverage model maintained over time, and the pluggable exporter seam. Tile
downloaders exist. What does not exist is a tool that keeps a durable, refinable model of
what your chartset *is*.

## The Coverage Model

A **project** holds **regions**, which may contain **subregions**, in a containment
hierarchy. Each level carries the zoom range it deserves: broad coverage at coarse zooms
for the whole cruising area, deep detail on the approaches and anchorages where a metre
matters.

Two rules give the model its properties:

- **Subregions are geometrically contained in their parent**, and coverage is rasterised
  by intersection. Containment of polygons then implies containment of tiles - a tile's
  parent necessarily intersects any polygon the child intersects - which is exactly the
  nested-coverage invariant the card format needs in order to fall back gracefully from a
  missing tile to a coarser one.
- **Where regions overlap, ownership is a union, not a contest.** A tile that two regions
  both want appears in both. Duplicate tiles at a seam are harmless downstream, and the
  alternative - deciding an owner - is how tiles go missing at exactly the boundaries where
  a mariner is most likely to be looking.

The **editor** and the **preview** are one component in two modes, not two pipelines: the
same map, the same local tile proxy, a different source and overlay. Preview earns its
place by answering two questions that are otherwise expensive - what the *build* source
actually looks like here, before committing to a nine-thousand-tile run; and how the
plotter's fallback behaves at a zoom the card does not carry, without a card, a boat, or a
trip to the water.

## Outputs

**`.mbtiles` is the hub.** The build engine writes tiles into a standard MBTiles container
and nothing else. It is read directly by OpenCPN, it is a well-specified format with a
large ecosystem, and it is the input to every other output chartMaker produces.

**`.RCT` is exporter number one.** The aerial photo overlay in the custom E-Series firmware
reads a purpose-built on-card raster format - an `.RCT` file per region plus an `INDEX.RCI`
selector - which a converter generates from a region's mbtiles. It is regenerable: the card
is a deployment artifact, not a source of truth.

Further exporters plug into the same seam. A KAP/BSB writer is the obvious second, reaching
a long tail of navigation software for very little work.

Both formats get their own specification documents alongside this one.

## Distribution Path

1. **Source** - run from a command prompt under a stock Perl; the developer workflow.
2. **Public repository** - documentation and architecture, publishable before any installer.
3. **Windows installer** - a versioned, self-contained build published as a GitHub Release
   asset, bundling its own Perl so that nothing needs to be installed first.

chartMaker is shipped, documented and tested on **Windows only**. That is a distribution
choice rather than a code limitation: the source is portable Perl and wxPerl. Ports and
forks are welcome; the shipped surface stays deliberately narrow.

## Code Organization

The repository follows the same layout as the other applications in this family:

| Path          | Holds                                                              |
| ------------- | ------------------------------------------------------------------ |
| `/`           | The application source modules.                                    |
| `/_res`       | Runtime resources bundled into the installer.                      |
| `/_res/site`  | The Leaflet applet - HTML, CSS, JavaScript - served by the embedded HTTP server. Not Perl. |
| `/_installer` | Packaging support for the Windows installer build.                 |
| `/releases`   | The release log. Installers themselves are Release assets, so the repository stays text-only and lean. |
| `/docs`       | These documents.                                                   |

Underscore-prefixed folders at the top level hold **separate executables** and build-time
material rather than application modules, keeping them visually and functionally distinct
from the source itself.

Within the source itself, modules carry a **lexical prefix marking their layer**. The
prefixes sort in layer order in a file browser or a tab bar, so the listing is the
architecture:

| Prefix       | Layer               | Modules (all `.pm`)                                                      |
| ------------ | ------------------- | ------------------------------------------------------------------------ |
| `chartMaker` | entry point         | application object, startup, wiring                                      |
| `cm_`        | foundational        | `cm_defs`, `cm_utils`, `cm_prefs`                                        |
| `dm_`        | data subsystems     | `dm_region`, `dm_source`, `dm_cache`, `dm_fetch`, `dm_mbtiles`, `dm_rct` |
| `em_`        | active subsystems   | `em_command`, `em_console`, `em_server`                                  |
| `w_`         | wx-aware, not panes | `w_resources`, `w_frame`, `w_dialogs`                                    |
| `win`        | panes and subpanes  | `winMap`, `winRegions`, `winSources`, `winMonitor`                       |

`chartMaker.pm` breaks the ordering deliberately, as the entry point that sits above every
layer. Three rules govern the rest:

**No module imports from a layer above it.** The usual rule, and the one that keeps the
listing honest.

**`cm_` and `dm_` must load without wx.** This is checkable in a single line from a console
script, and it is what makes the build engine's eventual home a decision rather than a
fork: a separate executable in an underscore-prefixed folder can use `dm_fetch`, `dm_cache`,
`dm_region` and `dm_mbtiles` directly, sharing exactly the code the GUI uses - no second
implementation, no IPC contract to maintain.

**`dm_` holds no control flow of its own.** `dm_fetch` retrieves *one* tile from one source
and reports bytes or a definite absence; the queue, the rate limiting, the retries and the
resume all live at `em_` or in that separate executable. The same split puts region
geometry, source definitions and the output writers below anything that decides *when* to
act.

The `em_` layer has one more property worth stating: **`em_command` sits beneath both front
doors.** The console reads a line, the HTTP server reads a request, and both hand the same
dispatcher the same verb - one command vocabulary, two transports. That is also the test
surface, since anything the console can do, an HTTP client can do.

---

**Next:** [Design](design.md)
